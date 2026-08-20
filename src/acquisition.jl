"""
acquisition.jl

Data acquisition worker tasks: Playback, Realtime, and Save modes. Folder
resolution and channel grouping live in tiff_source.jl; the ratio and
concentration math lives in ratio_analysis.jl; serial port discovery lives in
serial.jl; protocol schedule math lives in protocol.jl.

The three modes share most of their logic (sliding-window image binning,
per-region reduction to ratios, PI command computation, channel emission) via
`run_acquisition_loop!`. They differ only in how the next instance to process
is chosen, what time base its timestamps use, and what happens after a result
is emitted:

- **Playback** — round-robins a fixed list of complete instances on a
  fixed-frequency schedule; timestamps are instance indices.
- **Realtime** — waits for a new acquisition session to appear, then
  assembles instances from files as they are written; timestamps are
  wall-clock seconds.
- **Save** — iterates the fixed instance list once, reporting progress via a
  callback; timestamps are instance indices.

The unit of work is a *frame instance* — one file per channel, grouped by the
acquisition's global `T###` counter — rather than a single file. See
tiff_source.jl's header for why that grouping is derived from the counter
rather than from file ordering.
"""

using Base.Threads
using Statistics: median

# =============================================================================
# ROI SLOT TRACKING (missed-file repair)
# =============================================================================

"""
    roi_scan_period_s(protocol::ProtocolSettings)::Float64

Nominal wall-clock delay between two consecutive acquisition files, in
seconds: one ROI's scan (`protocol.scan_time`) plus the galvo settle/shift
onto the next one (`protocol.shift_time`), both in ms. These are the very
numbers `build_and_send_roi_trigger_buffer!` (roi.jl) programs the trigger
box's playback timing from, so this is the cadence the hardware is actually
running at rather than a guess — good enough to seed `RoiSlotTracker`, which
then refines it against what the files really do. `NaN` if they don't add up
to a usable period.
"""
function roi_scan_period_s(protocol::ProtocolSettings)::Float64
    period_ms = Float64(protocol.scan_time) + Float64(protocol.shift_time)
    return (isfinite(period_ms) && period_ms > 0.0) ? period_ms / 1000.0 : NaN
end

# Gap-history window `next_roi_slot!` re-estimates the file period from. A
# median over this many recent gaps: robust to the occasional doubled gap a
# missed file produces (that's the whole point — those must not drag the
# estimate up toward 1.5x and start hiding further misses), while short
# enough to follow a genuine cadence change within a run.
const ROI_SLOT_GAP_WINDOW = 25

# Gaps to observe before trusting the measured period over the nominal one.
# The nominal period is what the trigger box was programmed with, so it's
# right about the hardware; the measured one also absorbs whatever per-file
# overhead the source acquisition adds on top, which is what actually sets
# the spacing on disk.
const ROI_SLOT_WARMUP_GAPS = 5

# How far the measured period is allowed to drift from the nominal one
# before it's treated as nonsense (wrong protocol values, files copied in
# bulk, clock skew) and clamped. Wide on purpose: the point is to reject
# absurdity, not to second-guess a real cadence.
const ROI_SLOT_PERIOD_SANITY_FACTOR = 4.0

# |gap/period - round(gap/period)| above this and the gap sits too close to
# halfway between two slot counts for the rounding to mean much — the file
# is still assigned (rounding is the maximum-likelihood call either way),
# but the caller is told so it can surface it.
const ROI_SLOT_AMBIGUITY_TOLERANCE = 0.35

# Upper bound on a single advance, purely to keep a garbage timestamp (mtime
# of 1970, a file dated next century) from reaching `round(Int, ...)` with a
# value it can't represent. Far above any real gap.
const ROI_SLOT_MAX_STEP = 10_000

"""
    RoiSlotTracker(nominal_period_s)

Rolling state for `next_roi_slot!`: maps the stream of files an acquisition
reads onto the physical ROI-scan *slots* that produced them, so round-robin
ROI assignment survives a scan that wrote no file at all.

Holds the nominal file period (`roi_scan_period_s`, from the protocol
settings the trigger box was programmed with), a running estimate refined
from the last `ROI_SLOT_GAP_WINDOW` observed gaps, the previous file's
timestamp and sequence number, and the current slot.

One instance per acquisition run, owned by `consumer_loop` (runtime.jl) —
its state is a rolling history, so it must not be shared across runs.
"""
mutable struct RoiSlotTracker
    nominal_period_s::Float64
    period_est_s::Float64
    recent_gaps_s::Vector{Float64}
    last_time_s::Float64
    last_sequence::Union{Int, Nothing}
    slot::Int
    skipped_total::Int
end

function RoiSlotTracker(nominal_period_s::Real)
    period = Float64(nominal_period_s)
    usable = (isfinite(period) && period > 0.0) ? period : NaN
    return RoiSlotTracker(usable, usable, Float64[], NaN, nothing, 0, 0)
end

"""
    update_roi_slot_period!(tracker)

Refresh `tracker.period_est_s` from its gap history: the median of the
recent gaps once there are `ROI_SLOT_WARMUP_GAPS` of them, clamped to within
`ROI_SLOT_PERIOD_SANITY_FACTOR` of the nominal period when one is known.

Median rather than mean specifically because missed files are what this
whole mechanism exists for: they only ever make gaps *longer*, so a mean
would be dragged upward by exactly the events being detected, and a period
estimate biased high is what turns a real 2x gap back into "1" and lets the
misalignment through. The median is unmoved as long as missed files stay a
minority of the window.
"""
function update_roi_slot_period!(tracker::RoiSlotTracker)
    if length(tracker.recent_gaps_s) < ROI_SLOT_WARMUP_GAPS
        return nothing
    end

    observed = median(tracker.recent_gaps_s)
    if !(isfinite(observed) && observed > 0.0)
        return nothing
    end

    nominal = tracker.nominal_period_s
    tracker.period_est_s = if isfinite(nominal) && nominal > 0.0
        clamp(observed, nominal / ROI_SLOT_PERIOD_SANITY_FACTOR, nominal * ROI_SLOT_PERIOD_SANITY_FACTOR)
    else
        observed
    end

    return nothing
end

"""
    next_roi_slot!(tracker, file_time_s, sequence_number)
        -> (slot::Int, skipped::Int, ambiguous::Bool)

Advance `tracker` by one file and return the ROI-scan slot that file belongs
to — the number `consumer_loop` (runtime.jl) takes `mod1(slot, n_rois)` of.
`skipped` is how many slots were passed over (0 in the normal case),
`ambiguous` flags a gap that didn't land convincingly on any whole number of
periods.

The advance is `max` of two independent estimates of how many scans happened
since the previous file, because each catches a hole the other is blind to:

* **the sequence numbers** — `sequence_number - previous` covers a file that
  exists (or existed) in the source's own numbering but never reached this
  app;
* **the elapsed time** — `round(gap / period)` covers the case those numbers
  cannot express at all, a scan that produced no file and therefore consumed
  no number, leaving the numbering consecutive across the hole (see
  `AcquisitionSample`'s docstring, data_types.jl).

`max`, not a choice between them: each is a lower bound on the true advance
(neither mechanism can invent scans that didn't happen), so the larger one
is the better estimate and agreement is the normal case.

Rounding to the nearest whole period is deliberate rather than
tolerance-gated. Both errors here are equally bad — a missed detection and a
phantom one each shift every subsequent file by one ROI for the rest of the
run — so there's no safe side to bias toward, and nearest-integer is simply
the likeliest slot count for the gap. Gaps that fall too near halfway come
back with `ambiguous = true` instead of being silently resolved.

The one exception is the warmup, before there are enough gaps to have
checked the nominal period against reality: there, an ambiguous gap is
declined rather than rounded. Early on, a gap that sits nowhere near a whole
number of periods is far more likely to mean the period itself is off (the
source adds per-file overhead the protocol values don't account for) than to
mean scans went missing — and rounding 1.5x-nominal gaps up to "2" would
manufacture a phantom skip on *every* file until the measured period takes
over. Once the estimate is backed by `ROI_SLOT_WARMUP_GAPS` real
observations that reading no longer applies and nearest-integer wins again.

The first file establishes the origin: its slot *is* its sequence number, so
a run with no missed files reproduces the plain `mod1(sequence_number,
n_rois)` assignment this replaced, exactly.
"""
function next_roi_slot!(tracker::RoiSlotTracker, file_time_s::Float64, sequence_number::Int)
    if tracker.last_sequence === nothing
        tracker.slot = sequence_number
        tracker.last_sequence = sequence_number
        tracker.last_time_s = file_time_s
        return (tracker.slot, 0, false)
    end

    # Never negative: files can arrive out of order (a sorted backlog after
    # a numbering wrap), and going backwards would corrupt the alignment far
    # worse than treating it as one plain step.
    sequence_step = max(1, sequence_number - tracker.last_sequence)

    time_step = 1
    ambiguous = false
    gap = file_time_s - tracker.last_time_s

    if isfinite(gap) && gap > 0.0
        push!(tracker.recent_gaps_s, gap)
        if length(tracker.recent_gaps_s) > ROI_SLOT_GAP_WINDOW
            popfirst!(tracker.recent_gaps_s)
        end
        update_roi_slot_period!(tracker)

        period = tracker.period_est_s
        if isfinite(period) && period > 0.0
            ratio = gap / period
            if ratio >= ROI_SLOT_MAX_STEP
                time_step = ROI_SLOT_MAX_STEP
                ambiguous = true
            else
                rounded = max(1, round(Int, ratio))
                ambiguous = abs(ratio - rounded) > ROI_SLOT_AMBIGUITY_TOLERANCE
                warming_up = length(tracker.recent_gaps_s) < ROI_SLOT_WARMUP_GAPS
                time_step = (ambiguous && warming_up) ? 1 : rounded
            end
        end
    end

    step = max(sequence_step, time_step)
    tracker.slot += step
    tracker.skipped_total += step - 1
    # Assigned even when non-finite: that resets the time reference so the
    # *next* gap is measured from a known point rather than spanning two
    # files and being misread as a skip.
    tracker.last_time_s = file_time_s
    tracker.last_sequence = sequence_number

    return (tracker.slot, step - 1, ambiguous)
end


# =============================================================================
# IMAGE FRAME BUFFER (temporal binning)
# =============================================================================

"""
    ImageFrameBuffer{T}

One channel's sliding-window binning state: a circular buffer of whole frames
plus the running sum over the active window.

# Why whole frames, and what it costs

The FLIM pipeline buffered 256-bin histograms, so depth was free. Buffering
images is not: at 1024x1024 across three channels, 50 frames is ~157 MB of
8-bit samples. Three things keep that in hand:

- **native sample type** — frames are kept as they were read (`UInt8` today,
  `UInt16` if the camera is switched), never widened to `Float64`, which
  alone is a 4-8x saving over the obvious implementation;
- **lazy allocation** — nothing is allocated until the first frame reveals
  the real geometry, so a smaller acquisition simply uses less;
- **incremental sum** — the window sum is maintained by adding the arriving
  frame and subtracting the departing one, never by re-summing the window.

`sum_image` is `UInt32`: 50 frames of 16-bit samples reach ~3.3 million,
past `UInt16`, while `UInt64` would double the resident size of the one array
touched on every reduction.

# Why the sum is worth keeping at all

For the "ratio of means" reduction, binning the *scalars* would give
bit-identical results for a fraction of this memory. The images are buffered
anyway because the image plot renders the *binned* frame, and because a
per-pixel ratio map has no scalar equivalent to reconstruct from.

`summed` tracks how many frames `sum_image` currently holds. It is carried
explicitly rather than inferred from `filled` and `window`: those two agree
with the sum only in the steady state, and reconstructing "is there a frame
to evict yet" from them is exactly the kind of off-by-one that would corrupt
every mean silently, since an over- or under-counted window still produces
plausible-looking numbers.

`frames` holds `depth + 1` slots for a maximum window of `depth`. The spare
slot is what makes the incremental update possible at the largest window: the
frame leaving the window has to be *subtracted* from the sum, so it must
still be readable at the moment the arriving frame is stored. With exactly
`depth` slots the two collide — the arriving frame lands on the very slot
holding the outgoing one — and the update silently subtracts the new frame
instead of the old, an error that leaves the sum plausible-looking and wrong
for the rest of the run. Caught by testing the buffer against a naive
re-summation across window sizes, not by reading the code.
"""
mutable struct ImageFrameBuffer{T<:Unsigned}
    frames::Array{T, 3}
    sum_image::Matrix{UInt32}
    width::Int
    height::Int
    depth::Int
    write_pos::Int
    filled::Int
    window::Int
    summed::Int
end

"""
    ImageFrameBuffer{T}(width, height, depth)

Allocate a buffer supporting windows up to `depth` frames of `width` x
`height` samples of type `T`. `depth` is clamped to at least 1 and at most
`MAX_FRAME_BUFFER_DEPTH`; `depth + 1` slots are allocated, for the reason
given in the struct docstring.
"""
function ImageFrameBuffer{T}(width::Integer, height::Integer, depth::Integer) where {T<:Unsigned}
    d = clamp(Int(depth), 1, MAX_FRAME_BUFFER_DEPTH)
    return ImageFrameBuffer{T}(
        Array{T, 3}(undef, Int(width), Int(height), d + 1),
        zeros(UInt32, Int(width), Int(height)),
        Int(width), Int(height), d,
        0, 0, 0, 0
    )
end

frame_length(buffer::ImageFrameBuffer) = buffer.width * buffer.height

# Physical slot count, one more than the largest usable window.
slot_count(buffer::ImageFrameBuffer) = size(buffer.frames, 3)

"""
    push_frame!(buffer, pixels, requested_window) -> Int

Fold a newly-read frame into `buffer` and return how many frames the window
now sums — the divisor `region_mean` needs.

`requested_window` is the user's binning setting, re-read every frame so a
live edit takes effect immediately. It is clamped to the buffer depth and to
how many frames have actually been seen, so an early frame with binning set
to 50 averages over what exists rather than over uninitialized memory.

The window sum is maintained incrementally in the steady state (add the
arriving frame, subtract the one leaving the window). It is only rebuilt from
scratch when the requested window *changes*, since the set of frames in the
window then changes by more than one element and there is nothing to
subtract.
"""
function push_frame!(buffer::ImageFrameBuffer{T}, pixels::AbstractVector{T}, requested_window::Integer) where {T<:Unsigned}
    length(pixels) == frame_length(buffer) ||
        throw(ArgumentError("Frame of $(length(pixels)) samples does not fit a $(buffer.width)x$(buffer.height) buffer"))

    slots = slot_count(buffer)
    buffer.write_pos = mod1(buffer.write_pos + 1, slots)
    buffer.filled = min(buffer.filled + 1, slots)

    frames_flat = reshape(buffer.frames, frame_length(buffer), slots)
    @inbounds copyto!(view(frames_flat, :, buffer.write_pos), pixels)

    window = clamp(Int(requested_window), 1, min(buffer.depth, buffer.filled))
    sum_flat = vec(buffer.sum_image)

    if window != buffer.window
        # Window changed: the sum's membership changed by more than the single
        # frame that just arrived, so there is nothing to subtract and it has
        # to be rebuilt from the last `window` frames.
        fill!(sum_flat, UInt32(0))
        @inbounds for k in 0:(window - 1)
            pos = mod1(buffer.write_pos - k, slots)
            column = view(frames_flat, :, pos)
            @simd for i in eachindex(sum_flat)
                sum_flat[i] += UInt32(column[i])
            end
        end
        buffer.window = window
        buffer.summed = window
        return window
    end

    # Steady state: add the arriving frame...
    @inbounds @simd for i in eachindex(sum_flat)
        sum_flat[i] += UInt32(pixels[i])
    end
    buffer.summed += 1

    # ...then drop whatever that pushed out of the window. A loop, not an
    # `if`: `summed` can exceed `window` by more than one when the window was
    # just narrowed to a value the buffer already held frames for.
    @inbounds while buffer.summed > window
        evicted_pos = mod1(buffer.write_pos - buffer.summed + 1, slots)
        evicted = view(frames_flat, :, evicted_pos)
        @simd for i in eachindex(sum_flat)
            sum_flat[i] -= UInt32(evicted[i])
        end
        buffer.summed -= 1
    end

    return window
end

"""
    ChannelReader

Per-channel scratch for the acquisition loop: the pixel buffer each frame is
read into, and the binning buffer it is folded into.

Both are allocated on the first frame, once its geometry and sample type are
known, and reused for every frame afterwards — the acquisition loop performs
no per-frame pixel allocation at all.
"""
mutable struct ChannelReader{T<:Unsigned}
    pixels::Vector{T}
    buffer::ImageFrameBuffer{T}
end

function ChannelReader{T}(width::Integer, height::Integer, depth::Integer) where {T<:Unsigned}
    return ChannelReader{T}(
        Vector{T}(undef, Int(width) * Int(height)),
        ImageFrameBuffer{T}(width, height, depth)
    )
end

# =============================================================================
# PREVIEW
# =============================================================================

"""
    preview_stride(width, height) -> Int

Subsampling factor bringing the longer edge of a frame down to at most
`PREVIEW_MAX_DIMENSION`.
"""
function preview_stride(width::Integer, height::Integer)::Int
    longest = max(Int(width), Int(height))
    longest <= PREVIEW_MAX_DIMENSION && return 1
    return cld(longest, PREVIEW_MAX_DIMENSION)
end

"""
    build_preview(readers, window, combination_label) -> FramePreview

Build the downsampled snapshot the image plot renders, from the current
binned sum of each channel.

Strided subsampling rather than block averaging: the image plot is a
qualitative view of the field, the binning window has already done the noise
reduction that matters, and averaging would cost a full-resolution pass per
channel on a path that runs while the acquisition is live.

The ratio map is computed on the downsampled grid — see `FramePreview`
(data_types.jl). Pixels whose denominator is zero become `NaN`, which Makie
renders as a gap rather than as a spurious extreme value.
"""
function build_preview(readers::Vector{<:ChannelReader}, window::Int, combination_label::AbstractString,
                       channel_numbers::AbstractVector{Int})::FramePreview
    first_buffer = readers[1].buffer
    width = first_buffer.width
    height = first_buffer.height
    stride = preview_stride(width, height)

    xs = 1:stride:width
    ys = 1:stride:height
    out_w = length(xs)
    out_h = length(ys)

    divisor = Float32(max(window, 1))
    images = Vector{Matrix{Float32}}(undef, length(readers))

    for (c, reader) in enumerate(readers)
        source = reader.buffer.sum_image
        target = Matrix{Float32}(undef, out_w, out_h)
        @inbounds for (jj, y) in enumerate(ys), (ii, x) in enumerate(xs)
            target[ii, jj] = Float32(source[x, y]) / divisor
        end
        images[c] = target
    end

    num_channel, den_channel = parse_ratio_combination(combination_label)
    num_idx = findfirst(==(num_channel), channel_numbers)
    den_idx = findfirst(==(den_channel), channel_numbers)
    ratio_map = Matrix{Float32}(undef, out_w, out_h)

    if num_idx !== nothing && den_idx !== nothing && num_idx <= length(images) && den_idx <= length(images)
        numerator = images[num_idx]
        denominator = images[den_idx]
        @inbounds for i in eachindex(ratio_map)
            d = denominator[i]
            ratio_map[i] = d > 0 ? numerator[i] / d : NaN32
        end
    else
        fill!(ratio_map, NaN32)
    end

    return FramePreview(images, ratio_map, stride)
end

# =============================================================================
# PER-INSTANCE PROCESSING
# =============================================================================

"""
    PidChannelState

The PI controller's own accumulators, kept per controller output rather than
per acquisition channel.

Under FLIM each TCSPC channel was fit independently and drove its own
controller. Ratiometry produces a *single* ratio per instance, so both
outputs regulate on that one error signal with their own gains — which is
exactly what the FLIM pipeline already did whenever a file carried only one
channel (see `pid_command_from_state` below).

`kalman` filters the raw per-instance ratio before the error terms are
computed from it. This is what let the controller drop its `D` term (PID ->
PI): a raw discrete derivative amplifies measurement noise badly, while the
observer's velocity state tracks the signal's trend from a model of its
dynamics instead of differentiating a noisy series. It matters more here than
it did for lifetimes — an 8-bit ratio is noisier than a fitted lifetime.
"""
mutable struct PidChannelState
    I_error::Float64
    old_error::Float64
    kalman::KalmanState
end

PidChannelState() = PidChannelState(0.0, 0.0, KalmanState())

"""
    pid_command_from_state(state, setpoint, P, I, inv, on)::Float64

Apply one controller's P/I gains to `state`'s current error terms
(`state.old_error` holds the latest P_error, `state.I_error` the integral
term). `NaN` setpoint, or a disabled output, yields `NaN` — the "no command"
sentinel the serial layer and the Command plot both understand.

`setpoint` is in ratio units: protocol setpoints are expressed directly as
ratios, with no Hill conversion between the schedule and the error signal.
"""
function pid_command_from_state(state::PidChannelState, setpoint::Float64, P::Float64, I::Float64, inv::Bool, on::Bool)::Float64
    if isnan(setpoint)
        return NaN
    end

    command = P * state.old_error + I * state.I_error
    if inv
        command = -command
    end

    return on ? clamp(command, 0.0, 100.0) : NaN
end

"""
    update_pid_error!(state, ratio, setpoint, dt, smooth_level)

Fold one instance's ratio into `state`'s error accumulators, returning the
Kalman-filtered ratio the error was computed from.

A `NaN` setpoint (no active protocol) resets the accumulators rather than
letting the integral term keep winding on a stale error — the same policy the
FLIM loop used.
"""
function update_pid_error!(state::PidChannelState, ratio::Float64, setpoint::Float64, dt::Float64, smooth_level::Int)
    filtered = kalman_update!(state.kalman, ratio, dt, smooth_level)

    if isnan(setpoint) || isnan(filtered)
        state.I_error = 0.0
        state.old_error = 0.0
    else
        error = setpoint - filtered
        state.I_error += error * dt
        state.old_error = error
    end

    return filtered
end

"""
    reduce_regions(readers, masks, window, combination_label) -> Vector{RegionFrame}

Reduce one instance's binned channel images to a `RegionFrame` per region.

This is the whole of the ratiometric "analysis": a masked sum per channel per
region, a division by pixel and frame count to get a mean, one division to
form the ratio, and the Hill inversion for the concentration. Compare
`vec_to_lifetime`'s iterative MLE reconvolution fit, which this replaces.
"""
function reduce_regions(readers::Vector{<:ChannelReader}, masks::Vector{RegionMask},
                        window::Int, combination_label::AbstractString,
                        channel_numbers::AbstractVector{Int})::Vector{RegionFrame}
    n_channels = length(readers)
    frames = Vector{RegionFrame}(undef, length(masks))

    for (r, mask) in enumerate(masks)
        means = Vector{Float64}(undef, n_channels)
        for c in 1:n_channels
            means[c] = region_mean(vec(readers[c].buffer.sum_image), mask, window)
        end

        ratio = ratio_from_means(means, combination_label, channel_numbers)
        frames[r] = RegionFrame(means, ratio, hill_ratio_to_concentration(ratio))
    end

    return frames
end

# =============================================================================
# SHARED ACQUISITION LOOP
# =============================================================================

"""
    make_channel_readers(instance, depth) -> Vector{ChannelReader}

Allocate one `ChannelReader` per channel, sized from `instance`'s first file.

Geometry and sample type are taken from the data rather than assumed, which
is what lets the same build serve an 8-bit 1024x1024 acquisition today and a
16-bit or differently-sized one later. Every channel is required to agree
with the first: a ratio between images of different sizes is meaningless, and
silently reducing over mismatched regions would produce plausible numbers
from unrelated pixels.
"""
function make_channel_readers(instance::FrameInstance, depth::Integer)
    reference = BigTiffFile.read_info(instance.paths[1])
    T = BigTiffFile.sample_type(reference)

    for path in instance.paths[2:end]
        info = BigTiffFile.read_info(path)
        (info.width == reference.width && info.height == reference.height) ||
            error("Channel images disagree on size: $(basename(instance.paths[1])) is $(reference.width)x$(reference.height), $(basename(path)) is $(info.width)x$(info.height)")
        info.bits_per_sample == reference.bits_per_sample ||
            error("Channel images disagree on bit depth: $(basename(instance.paths[1])) is $(reference.bits_per_sample)-bit, $(basename(path)) is $(info.bits_per_sample)-bit")
    end

    if reference.bits_per_sample == 8
        @info "Acquisition is 8-bit: only 256 grey levels per channel, which limits ratio precision. A 16-bit camera setting would improve it." size=(reference.width, reference.height)
    end

    return [ChannelReader{T}(reference.width, reference.height, depth) for _ in instance.paths]
end

"""
    run_acquisition_loop!(ch, running, layout, controller, next_instance!, emit!; kwargs...)

Shared body for all three acquisition modes. Repeatedly calls
`next_instance!(n)` (with `n` the current, pre-increment frame counter) to
obtain the next `FrameInstance` to process — or `nothing` to stop the loop,
which each mode uses to encode its own pacing/waiting/termination policy. For
each instance it reads every channel's image, folds it into that channel's
binning buffer, reduces the result over each region, and computes the PI
commands. Then calls `emit!(sample, n)` — which each mode uses to `put!` onto
`ch` plus its own post-emit policy (extra pacing, progress reporting) —
returning `false` to stop the loop.

# Time base

`use_wall_clock` selects between the two time bases the modes need:

- **Realtime** (`true`) — timestamps are seconds elapsed since the first
  instance was processed, so the x-axis reflects the acquisition's real
  cadence and the PI integral term accumulates in real seconds.
- **Playback / Save** (`false`) — timestamps are the instance counter and
  `dt` is exactly 1. Replaying files as fast as the disk allows has no
  meaningful wall-clock cadence to report, and pacing the PI by it would make
  the integral term depend on disk speed.

# Region masks

Masks cannot be built until the first image reveals the geometry, so they are
built on the first instance and reused. They are *not* rebuilt when the ROI
set changes mid-run: the series vectors downstream are sized to match the
mask count at START, and growing one without the other would misalign every
subsequent sample.

Must be called from within the caller's own `try/catch/finally` so that path
validation failures and cleanup (closing `ch`, clearing `running[]`) are
handled by the specific mode wrapper.
"""
function run_acquisition_loop!(
        ch::Channel{AcquisitionSample},
        running::Threads.Atomic{Bool},
        layout::LayoutSettings,
        controller::ControllerSettings,
        next_instance!::Function,
        emit!::Function;
        protocol::Union{Nothing, ProtocolSettings, Observables.AbstractObservable},
        rois::Vector{RoiCoordinates},
        use_spatial_masks::Bool,
        use_wall_clock::Bool,
        channel_numbers::Vector{Int},
        preview_enabled::Bool = true
    )
    n = UInt32(0)
    timestamps = 0.0

    # PI setpoint fallback used when no protocol is active, in ratio units.
    fallback_setpoint = 1.0

    pid1 = PidChannelState()
    pid2 = PidChannelState()

    readers = nothing
    masks = RegionMask[]
    start_time_s = NaN
    previous_timestamp = 0.0
    last_preview_s = -Inf

    while running[]
        instance = next_instance!(n)
        if instance === nothing
            break
        end

        if readers === nothing
            readers = make_channel_readers(instance, MAX_FRAME_BUFFER_DEPTH)
            masks = build_region_masks(rois, readers[1].buffer.width, readers[1].buffer.height;
                                       use_spatial_masks=use_spatial_masks)
            @info "Acquisition geometry resolved" size=(readers[1].buffer.width, readers[1].buffer.height) channels=length(readers) regions=length(masks) spatial_masks=use_spatial_masks
        end

        length(instance.paths) == length(readers) ||
            error("Instance $(instance.instance_index) has $(length(instance.paths)) channels, expected $(length(readers))")

        window = 1
        for (c, reader) in enumerate(readers)
            BigTiffFile.read_frame!(reader.pixels, instance.paths[c])
            window = push_frame!(reader.buffer, reader.pixels, layout.binning)
        end

        # Time base. Wall-clock timestamps are measured from the first
        # processed instance rather than from START, so a Realtime run that
        # waited minutes for its session folder still begins its x-axis at 0.
        now_s = time()
        if use_wall_clock
            isnan(start_time_s) && (start_time_s = now_s)
            timestamps = now_s - start_time_s
        else
            timestamps = Float64(n) + 1.0
        end
        dt = max(timestamps - previous_timestamp, eps(Float64))
        previous_timestamp = timestamps

        current_protocol = resolve_protocol_config(protocol)
        protocol_active = current_protocol !== nothing && current_protocol.active
        setpoint = protocol_active ? protocol_setpoint_at(current_protocol, timestamps) : fallback_setpoint

        # Distinct from `setpoint`: PI control keeps regulating toward the
        # fallback even without an active protocol, but the plotted series and
        # highlight should only reflect a genuine schedule — otherwise the
        # Ratio plot shows a spurious line and vspan whenever the protocol is
        # off.
        plot_setpoint = protocol_active ? setpoint : NaN

        regions = reduce_regions(readers, masks, window, layout.ratio_combination, channel_numbers)

        # Both controllers regulate on the same ratio, with their own gains.
        # In spatial-mask mode several regions are produced per instance and
        # the first is the one the hardware loop follows — there is only one
        # physical output pair, so it cannot track all of them at once.
        control_ratio = isempty(regions) ? NaN : regions[1].ratio
        smooth_level = series_smooth_level(layout)

        update_pid_error!(pid1, control_ratio, setpoint, dt, smooth_level)
        update_pid_error!(pid2, control_ratio, setpoint, dt, smooth_level)

        command1 = pid_command_from_state(pid1, setpoint, controller.P1, controller.I1, controller.ch1_inv, controller.ch1_on)
        command2 = pid_command_from_state(pid2, setpoint, controller.P2, controller.I2, controller.ch2_inv, controller.ch2_on)

        preview = nothing
        if preview_enabled && (now_s - last_preview_s) >= PREVIEW_MIN_INTERVAL_S
            preview = build_preview(readers, window, layout.ratio_combination, channel_numbers)
            last_preview_s = now_s
        end

        # UInt32(1), not the literal 1 (Int64): mixed UInt32/Int64 addition
        # promotes to Int64, which would break dispatch on the strictly-typed
        # UInt32 frame counter downstream.
        n += UInt32(1)

        if !(isopen(ch) && running[])
            break
        end

        sample = AcquisitionSample(
            regions, preview, command1, command2, timestamps, plot_setpoint,
            n, instance.instance_index, copy(instance.paths),
            copy(instance.sequence_numbers), instance.file_time
        )

        if !emit!(sample, n)
            break
        end
    end

    return nothing
end

# =============================================================================
# PLAYBACK MODE
# =============================================================================

"""
    start_playback(ch, running, layout, controller; kwargs...)

Worker task for Playback mode: round-robins over every complete instance in
the selected acquisition folder on a fixed-frequency schedule
(`target_frequency`).

`target_frequency` is a live `Threads.Atomic{Float64}` (typically
`app_run.target_frequency`), re-read every cycle rather than captured once, so
editing the target-frequency textbox (GUI.jl/handlers.jl) re-paces the
schedule immediately, mid-run.

Timestamps are instance indices, not wall-clock seconds — see
`run_acquisition_loop!`.
"""
function start_playback(
        ch::Channel{AcquisitionSample},
        running::Threads.Atomic{Bool},
        layout::LayoutSettings,
        controller::ControllerSettings;
        protocol::Union{Nothing, ProtocolSettings, Observables.AbstractObservable} = nothing,
        paused::Union{Nothing, Threads.Atomic{Bool}} = nothing,
        rois::Vector{RoiCoordinates} = RoiCoordinates[],
        use_spatial_masks::Bool = true,
        preview_enabled::Bool = true,
        dt::Float64 = 0.0001,
        target_frequency::Threads.Atomic{Float64} = Threads.Atomic{Float64}(DEFAULT_PLAYBACK_TARGET_FREQUENCY_HZ)
    )
    try
        @info "Playback worker started on thread $(threadid())"

        path = get_data_root_path()
        layout_dirs = resolve_channel_layout(path)
        if layout_dirs === nothing
            @error "No Bliq VMS channel folders found under $path"
            return nothing
        end

        instances = group_instances(layout_dirs)
        nb_instances = length(instances)

        if nb_instances == 0
            @error "No complete frame instances found under $(layout_dirs.root)"
            return nothing
        end

        channel_numbers_for_run = layout_dirs.channel_numbers

        @info "Playback ready" instances=nb_instances channels=layout_dirs.channel_names numbering=layout_dirs.numbering

        next_analysis_ns = Ref(time_ns())

        next_instance! = function (n)
            while running[]
                # Re-read every cycle (not captured once) so a live edit to
                # the target-frequency textbox re-paces the schedule
                # immediately instead of only on the next worker restart.
                target_period_ns = round(Int, 1e9 / max(target_frequency[], 0.01))

                if paused !== nothing && paused[]
                    next_analysis_ns[] = time_ns() + target_period_ns
                    sleep(min(dt, 0.02))
                    continue
                end

                now_ns = time_ns()
                if now_ns < next_analysis_ns[]
                    remaining_s = (next_analysis_ns[] - now_ns) / 1e9
                    sleep(min(dt, remaining_s))
                    continue
                end

                # Keep a fixed schedule when possible; if we are late, restart from now.
                next_analysis_ns[] += target_period_ns
                if next_analysis_ns[] < now_ns
                    next_analysis_ns[] = now_ns + target_period_ns
                end

                return instances[mod1(Int(n) + 1, nb_instances)]
            end
            return nothing
        end

        emit! = function (sample, n)
            try
                put!(ch, sample)
            catch e
                isa(e, InvalidStateException) && return false
                rethrow()
            end
            return true
        end

        run_acquisition_loop!(ch, running, layout, controller, next_instance!, emit!;
                              protocol=protocol, rois=rois, use_spatial_masks=use_spatial_masks,
                              use_wall_clock=false, channel_numbers=channel_numbers_for_run, preview_enabled=preview_enabled)
    catch e
        @error "Playback worker error" exception=(e, catch_backtrace())
        rethrow()
    finally
        running[] = false
        try
            close(ch)
        catch
            # Ignore if already closed
        end
        @info "Playback worker finished"
    end

    return nothing
end

# =============================================================================
# REALTIME MODE
# =============================================================================

"""
    start_realtime(ch, running, layout, controller; kwargs...)

Worker task for Realtime mode: waits for a new acquisition session to appear
under the selected folder, then processes instances as the acquisition writes
them.

Unlike Playback, this does not fail when the folder holds no data yet — at
START the session directory generally does not exist, because the acquisition
software creates it when *it* starts. `wait_for_session_layout`
(tiff_source.jl) blocks until one appears, which is what lets the user arm
this app before triggering the microscope.

Instances are assembled by `InstanceCollector`, which holds a partially
arrived instance until every channel has contributed and abandons it once it
is overdue by a multiple of the observed cadence.

Timestamps are wall-clock seconds since the first processed instance.
"""
function start_realtime(
        ch::Channel{AcquisitionSample},
        running::Threads.Atomic{Bool},
        layout::LayoutSettings,
        controller::ControllerSettings;
        protocol::Union{Nothing, ProtocolSettings, Observables.AbstractObservable} = nothing,
        paused::Union{Nothing, Threads.Atomic{Bool}} = nothing,
        rois::Vector{RoiCoordinates} = RoiCoordinates[],
        use_spatial_masks::Bool = true,
        preview_enabled::Bool = true,
        nominal_period_s::Float64 = NaN,
        dt::Float64 = 0.0001,
        poll_interval_s::Float64 = 0.05
    )
    try
        @info "Real-time worker started on thread $(threadid())"

        path = get_data_root_path()
        if !isdir(path)
            @error "Data folder not found: $path"
            return nothing
        end

        known = existing_session_dirs(path)
        channel_layout = wait_for_session_layout(path, running; poll_interval_s=0.25, known_before=known)

        if channel_layout === nothing
            @info "Stopped before an acquisition session appeared"
            return nothing
        end

        channel_numbers_for_run = channel_layout.channel_numbers

        @info "Real-time mode active" root=channel_layout.root channels=channel_layout.channel_names numbering=channel_layout.numbering

        collector = InstanceCollector(channel_layout; nominal_period_s=nominal_period_s)
        pending = FrameInstance[]
        next_scan_at = Ref(0.0)

        next_instance! = function (n)
            while running[]
                if paused !== nothing && paused[]
                    sleep(min(dt, 0.05))
                    continue
                end

                if !isempty(pending)
                    return popfirst!(pending)
                end

                now_t = time()
                if now_t < next_scan_at[]
                    sleep(min(dt, max(1e-4, next_scan_at[] - now_t)))
                    continue
                end
                next_scan_at[] = now_t + poll_interval_s

                scan_new_files!(collector, now_t)
                append!(pending, take_ready_instances!(collector, now_t))

                isempty(pending) && sleep(poll_interval_s)
            end
            return nothing
        end

        emit! = function (sample, n)
            try
                put!(ch, sample)
            catch e
                isa(e, InvalidStateException) && return false
                rethrow()
            end
            sleep(dt)
            return true
        end

        run_acquisition_loop!(ch, running, layout, controller, next_instance!, emit!;
                              protocol=protocol, rois=rois, use_spatial_masks=use_spatial_masks,
                              use_wall_clock=true, channel_numbers=channel_numbers_for_run, preview_enabled=preview_enabled)
    catch e
        @error "Real-time worker error" exception=(e, catch_backtrace())
        rethrow()
    finally
        running[] = false
        try
            close(ch)
        catch
            # Ignore if already closed
        end
        @info "Real-time worker finished"
    end

    return nothing
end

# =============================================================================
# SAVE MODE
# =============================================================================

"""
    start_save(ch, running, layout, controller; kwargs...)

Worker task for Save mode: processes every complete instance in the selected
folder once, reporting progress via `progress_cb(pct)`, then stops naturally.

Shares Playback's instance-index time base — the run is a batch reduction of
files already on disk, so there is no live cadence to reflect.
"""
function start_save(
        ch::Channel{AcquisitionSample},
        running::Threads.Atomic{Bool},
        layout::LayoutSettings,
        controller::ControllerSettings;
        protocol::Union{Nothing, ProtocolSettings, Observables.AbstractObservable} = nothing,
        paused::Union{Nothing, Threads.Atomic{Bool}} = nothing,
        rois::Vector{RoiCoordinates} = RoiCoordinates[],
        use_spatial_masks::Bool = true,
        preview_enabled::Bool = false,
        dt::Float64 = 0.0000001,
        progress_cb::Union{Nothing, Function} = nothing
    )
    try
        @info "Save worker started on thread $(threadid())"

        path = get_data_root_path()
        layout_dirs = resolve_channel_layout(path)
        if layout_dirs === nothing
            @error "No Bliq VMS channel folders found under $path"
            return nothing
        end

        instances = group_instances(layout_dirs)
        nb_instances = length(instances)

        if nb_instances == 0
            @error "No complete frame instances found under $(layout_dirs.root)"
            return nothing
        end

        channel_numbers_for_run = layout_dirs.channel_numbers

        @info "Save ready" instances=nb_instances channels=layout_dirs.channel_names numbering=layout_dirs.numbering

        last_progress_pct = Ref(-1)

        if progress_cb !== nothing
            try
                progress_cb(0)
                last_progress_pct[] = 0
            catch e
                @warn "Save progress callback failed" error=string(e)
                progress_cb = nothing
            end
        end

        instance_idx = Ref(0)

        next_instance! = function (n)
            running[] || return nothing

            while running[] && paused !== nothing && paused[]
                sleep(min(dt, 0.05))
            end

            running[] || return nothing

            instance_idx[] += 1
            instance_idx[] > nb_instances && return nothing

            return instances[instance_idx[]]
        end

        emit! = function (sample, n)
            try
                put!(ch, sample)
            catch e
                isa(e, InvalidStateException) && return false
                rethrow()
            end

            if progress_cb !== nothing
                progress_pct = clamp(floor(Int, (Int(n) * 100) / nb_instances), 0, 100)
                if progress_pct > last_progress_pct[]
                    for pct in (last_progress_pct[] + 1):progress_pct
                        try
                            progress_cb(pct)
                        catch e
                            @warn "Save progress callback failed" error=string(e)
                            progress_cb = nothing
                            break
                        end
                    end
                    last_progress_pct[] = progress_pct
                end
            end

            dt > 0.0 && sleep(dt)

            return true
        end

        run_acquisition_loop!(ch, running, layout, controller, next_instance!, emit!;
                              protocol=protocol, rois=rois, use_spatial_masks=use_spatial_masks,
                              use_wall_clock=false, channel_numbers=channel_numbers_for_run, preview_enabled=preview_enabled)
    catch e
        @error "Save worker error" exception=(e, catch_backtrace())
        rethrow()
    finally
        running[] = false
        try
            close(ch)
        catch
            # Ignore if already closed
        end
        @info "Save worker finished"
    end

    return nothing
end
