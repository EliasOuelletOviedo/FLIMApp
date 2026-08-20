"""
data_types.jl

Core data structures for the ratiometric TIFF application.

This module defines the primary structures for application state:
- AppState: Persistent configuration that is serialized to disk
- AppRun: Runtime transient state with observables and background tasks
- RegionFrame / RoiSeries: one region's per-frame results and runtime
  observables, so per-region logic is written once and instantiated per
  region instead of duplicated per-channel copies

# Why the series hierarchy is region-major

Under FLIM, every TCSPC channel was fit independently and produced its own
lifetime, so the natural shape was *channel* -> per-ROI series, and the app
held `ch1_rois` / `ch2_rois`.

Ratiometry inverts that. A ratio is formed *across* channels, so it belongs
to a region, not to a channel — there is exactly one ratio per region per
frame no matter how many channels feed it. The per-channel quantity that
survives is the mean intensity, which is now the innermost level. Hence
`RoiSeries` (per region: ratio, concentration, timestamps) containing
`RoiChannelIntensity` (per region *and* channel: mean intensity).
"""

using Observables
using Base.Threads
using LibSerialPort: SerialPort

# =============================================================================
# ACQUISITION SAMPLES (worker -> consumer payload)
# =============================================================================

"""
    RegionFrame

One region's results for a single frame instance: each channel's mean
intensity over that region, the ratio formed from two of them, and the
concentration that ratio calibrates to.

`channel_means` is indexed by acquisition channel (1 = C1, 2 = C2, ...) and
is always `channel_count` long. `ratio` is `NaN` when the selected
combination names a channel the acquisition does not provide, or when the
denominator is zero — see `ratio_from_means` in ratio_analysis.jl. `NaN` is
the pipeline's uniform "no value" sentinel, handled by the plots, the Kalman
smoother and the PI controller alike.
"""
struct RegionFrame
    channel_means::Vector{Float64}
    ratio::Float64
    concentration::Float64
end

"""
    RegionFrame(channel_count)

The "no measurement" frame: `NaN` everywhere, sized for `channel_count`
channels. Emitted for a region whose reduction could not be computed.
"""
RegionFrame(channel_count::Integer) = RegionFrame(fill(NaN, channel_count), NaN, NaN)

"""
    FramePreview

A downsampled snapshot of one instance, for the image plot.

Deliberately not the full-resolution frame. The image plot exists to let the
user see what the microscope is looking at, at a display size of a few
hundred pixels; shipping a megapixel copy per channel per frame through the
acquisition channel would allocate tens of megabytes per second at 60 Hz to
render something no larger than this. `stride` records the subsampling factor
so coordinates can be mapped back to the full frame.

`ratio_map` is computed on the downsampled grid rather than at full
resolution and then reduced — a per-pixel division over a megapixel costs
more than the entire rest of the frame's work, and the result would be
thrown away by the downsampling anyway.

Built only when the image plot is actually selected, and throttled — see
`build_preview` in acquisition.jl.
"""
struct FramePreview
    channel_images::Vector{Matrix{Float32}}
    ratio_map::Matrix{Float32}
    stride::Int
end

"""
    AcquisitionSample

One frame instance's worth of acquisition results, emitted onto the
acquisition channel by `run_acquisition_loop!` (acquisition.jl) and consumed
by `consumer_loop` (runtime.jl). A struct rather than a positional tuple —
too many fields to destructure positionally without risking a
silently-mismatched order.

`regions` holds one `RegionFrame` per region mask. Its length depends on the
ROI mode in force (see `build_region_masks`, ratio_analysis.jl): in spatial
mode there is one entry per drawn ROI and all of them are filled from this
instance; in round-robin mode there is a single entry, and which ROI it
belongs to is decided downstream by `next_roi_slot!`.

Three fields together identify *which* ROI scan produced this instance — the
whole point being that none of them is reliable alone:

`frame_index` is this app's own count of instances it has read so far this
run — it advances by exactly 1 per instance regardless of what the source
acquisition actually produced, so an instance the upstream hardware/software
never wrote (e.g. a lag spike at the source) is invisible to it and it
silently drifts out of sync with the real physical sequence from that point
on.

`instance_index` is the instance's own position in the acquisition's global
sequence, recovered from the `T###` counter as `cld(T, channel_count)` — see
tiff_source.jl's header. Unlike `frame_index` it leaves a hole rather than
shifting when the acquisition drops files, which is exactly what makes a
missed scan detectable.

`file_time` is the newest modification time across the instance's files
(unix seconds, `NaN` if none could be stat'ed) — when the source finished
writing the group, not when this app got around to reading it, so it stays
meaningful when the reader is backlogged. It's what makes a *silent* hole
detectable: consecutive ROI scans are `scan_time + shift_time` ms apart by
construction (the trigger box is programmed with exactly those numbers,
roi.jl), so a gap of ~2x that period means one scan produced no instance.
See `RoiSlotTracker`/`next_roi_slot!` (acquisition.jl), which `consumer_loop`
(runtime.jl) drives to keep round-robin ROI assignment aligned through such
holes.
"""
struct AcquisitionSample
    regions::Vector{RegionFrame}
    preview::Union{Nothing, FramePreview}
    command1::Float64
    command2::Float64
    timestamps::Float64
    protocol_setpoint::Float64
    frame_index::UInt32
    instance_index::Int
    source_files::Vector{String}
    sequence_numbers::Vector{Int}
    file_time::Float64
end

# =============================================================================
# APPLICATION STATE SETTINGS GROUPS
# =============================================================================
#
# Base.@kwdef gives each struct a zero-argument default constructor (e.g.
# LayoutSettings()) that doubles as "get the defaults" — no separate
# get_default_*() function needed. Typed fields mean a typo'd key or a
# wrong-typed value is a compile-time/construction-time error instead of a
# silent Dict lookup returning `nothing` at some unrelated call site.

"""
    LayoutSettings

Display settings: time range, binning, smoothing, which series each plot
shows, and per-plot channel toggles.

`ratio_combination` is the ordered channel pair the ratio is formed from —
one of `RATIO_COMBINATION_OPTIONS` (ratio_analysis.jl), stored as its label
so the persisted value stays readable and survives a change in channel count.

`plot1_ch3`/`plot2_ch3` extend the per-plot channel toggles to a third
channel; they are inert when the acquisition writes only two.
"""
Base.@kwdef mutable struct LayoutSettings
    time_range::Int = 60
    binning::Int = 1
    smoothing::Int = 0
    plot1::String = "Ratio"
    plot2::String = "Concentration"
    plot1_ch1::Bool = false
    plot1_ch2::Bool = false
    plot1_ch3::Bool = false
    plot2_ch1::Bool = false
    plot2_ch2::Bool = false
    plot2_ch3::Bool = false
    ratio_combination::String = "C1/C2"
end

"""
    ControllerSettings

Hardware controller configuration for the two PI output channels. No `D`
gain: the derivative term was dropped in favor of a Kalman observer
(`KalmanState`/`kalman_update!`, smoothing.jl) feeding the P/I error terms a
filtered lifetime instead of the raw fit — see `process_frame!`
(acquisition.jl).
"""
Base.@kwdef mutable struct ControllerSettings
    ch1_inv::Bool = false
    ch1_on::Bool = false
    ch1_out::String = "Out 1"
    ch1_mode::String = "Digital"
    freq::Int = 1000
    P1::Float64 = 0.0
    I1::Float64 = 0.0
    ch2_inv::Bool = false
    ch2_on::Bool = false
    ch2_out::String = "Out 2"
    ch2_mode::String = "Digital"
    P2::Float64 = 0.0
    I2::Float64 = 0.0
end

"""
    ProtocolSettings

Experimental protocol schedule: `times`/`setpoints` are parallel vectors of
`PROTOCOL_STEP_COUNT` per-step durations and setpoints.

`points_per_roi`/`spiral_turns`/`scan_time`/`shift_time` are the
ROI trigger-box scan-buffer parameters (roi.jl), editable from the Protocol
panel (handlers_protocol.jl) — see `roi_trigger_buffer`/
`build_and_send_roi_trigger_buffer!` in roi.jl for how they're used.
"""
Base.@kwdef mutable struct ProtocolSettings
    active::Bool = false
    repeats::Int = 1
    delay::Int = 0
    times::Vector{Float64} = fill(NaN, PROTOCOL_STEP_COUNT)
    setpoints::Vector{Float64} = fill(NaN, PROTOCOL_STEP_COUNT)
    PWM_frequency::Int = 1000
    points_per_roi::Int = 100
    spiral_turns::Int = 10
    scan_time::Int = 950
    shift_time::Int = 50
end

"""
    RoiSettings

ROI panel settings. `v_min_x`/`v_max_x`/`v_min_y`/`v_max_y` are the ROI
trigger-box galvo voltage range (mV) for each axis, editable from the ROI
popup — see `roi_trigger_buffer` (roi.jl) for how they're used.
"""
Base.@kwdef mutable struct RoiSettings
    active::Bool = false
    v_min_x::Int64 = -1000
    v_max_x::Int64 = 1000
    v_min_y::Int64 = -1000
    v_max_y::Int64 = 1000
end

"""
    ConsoleSettings

Console/logging settings (no fields yet).
"""
Base.@kwdef mutable struct ConsoleSettings end

# =============================================================================
# PERSISTENT APPLICATION STATE
# =============================================================================

"""
    AppState

Persistent user preferences, serialized to `state_file_path()` to survive
across sessions. `current_panel` is the active UI panel (:layout,
:controller, :protocol, :console); the settings fields group the per-panel
configuration.
"""
mutable struct AppState
    dark::Bool
    current_panel::Symbol
    layout::LayoutSettings
    controller::ControllerSettings
    protocol::ProtocolSettings
    roi::RoiSettings
    console::ConsoleSettings
end

"""
    AppState(use_dark::Bool)

All-defaults state, with the dark theme when `use_dark` is true.
"""
function AppState(use_dark::Bool)
    return AppState(
        use_dark,
        :layout,
        LayoutSettings(),
        ControllerSettings(),
        ProtocolSettings(),
        RoiSettings(),
        ConsoleSettings()
    )
end

# =============================================================================
# RUNTIME APPLICATION STATE
# =============================================================================

# The FLIM pipeline's `ChannelSeries` — a per-channel "latest frame" snapshot
# of the decay histogram, its fit and the photon count — has no ratiometric
# counterpart. The Histogram plot it fed showed a TCSPC decay curve, which no
# longer exists; the image plot that replaced it renders a `FramePreview`
# instead, held directly on `AppRun.preview` because there is one preview per
# instance rather than one per channel.

"""
    KalmanState

Constant-velocity (2-state) Kalman filter state: estimated value (`pos`)
and its rate of change (`vel`), their 2x2 covariance (`p11`/`p12`/`p22`),
and an adaptively-tracked measurement-noise estimate (`r_est`, updated from
successive raw measurements the same way the pre-Kalman heuristic's own
`scale_est` was) used as the filter's own `R` term. `prev_raw` is the last
raw (unfiltered) measurement seen, needed to compute `r_est`'s update.
`typical_dt` is an EMA of the elapsed time between updates — needed because
the process-noise growth `kalman_update!` applies over an interval `dt`
scales as `dt^3`, so a `q` intensity calibrated for one acquisition's
cadence would over- or under-smooth badly at another's (real files here
have ranged from ~20ms to ~118s between frames); `q` is derived from
`typical_dt`, not a fixed absolute constant, so "level 10" means the same
relative amount of smoothing regardless of how fast frames actually arrive.

One instance per (channel, metric) drives the PID observer
(`ChannelFitState.pid_kalman`, acquisition.jl) and one per (channel, ROI,
metric) drives plot smoothing (`RoiChannelSeries`, below) — same filter
(`kalman_update!`, smoothing.jl), independent state in each case, since ROI
mode's per-line smoothing stays independent from the PID's own observer
(each ROI only sees every Nth frame; the PID observer sees every frame).

`KalmanState()`'s all-`NaN`(/`0.0`-velocity) default is this filter's "never
seen a sample yet" sentinel — `kalman_update!` (re)initializes properly
from the first real measurement it's given.
"""
mutable struct KalmanState
    pos::Float64
    vel::Float64
    p11::Float64
    p12::Float64
    p22::Float64
    r_est::Float64
    prev_raw::Float64
    typical_dt::Float64
end

KalmanState() = KalmanState(NaN, 0.0, NaN, 0.0, NaN, NaN, NaN, NaN)

"""
    RoiChannelIntensity

One region's mean-intensity time series for one acquisition channel — the
innermost level of the series hierarchy, held by `RoiSeries.channels`.

Intensity is the only per-channel quantity that survives ratiometry (the
ratio and the concentration it calibrates to are properties of the region,
not of a channel), so this is a deliberately thin struct: one raw series, its
smoothed companion, and the filter state driving the smoothing.

`kalman` is `smoothing.jl`'s `kalman_update!` running state for `smooth` —
not plotted directly, just carried so `append_smooth_value!` can pick up
where the last call left off, and reinitialized (not persisted) across a
`recompute_smooth_series!` replay.
"""
struct RoiChannelIntensity
    values::Observable{Vector{Float64}}
    smooth::Observable{Vector{Float64}}
    kalman::KalmanState
end

RoiChannelIntensity() = RoiChannelIntensity(Observable(Float64[]), Observable(Float64[]), KalmanState())

"""
    RoiSeries

One region's accumulated runtime time series — the unit duplicated once per
drawn ROI (`app_run.rois`).

Carries its own `timestamps` because in round-robin mode each ROI only
receives every Nth instance (N = number of ROIs), so it cannot share a single
app-wide per-frame x-axis. In spatial-mask mode every region receives every
instance and the timestamp vectors coincide, but keeping them per-region lets
both modes share one code path.

# Fields
- `timestamps::Observable{Vector{Float64}}`: this region's own instance timestamps
- `ratio` / `ratio_smooth` / `ratio_kalman`: the intensity-ratio time series and its live Kalman filter state
- `concentration` / `concentration_smooth` / `concentration_kalman`: the Hill-calibrated concentration series and its filter state
- `channels::Vector{RoiChannelIntensity}`: per-channel mean intensity, one entry per acquisition channel

`channels` is sized when the series are rebuilt (`rebuild_roi_series!`,
runtime.jl), once the channel count is known from the folder layout.
"""
struct RoiSeries
    timestamps::Observable{Vector{Float64}}
    ratio::Observable{Vector{Float64}}
    ratio_smooth::Observable{Vector{Float64}}
    ratio_kalman::KalmanState
    concentration::Observable{Vector{Float64}}
    concentration_smooth::Observable{Vector{Float64}}
    concentration_kalman::KalmanState
    channels::Vector{RoiChannelIntensity}
end

"""
    RoiSeries(channel_count)

Fresh, empty series for one region, with `channel_count` per-channel
intensity slots.
"""
function RoiSeries(channel_count::Integer=2)
    return RoiSeries(
        Observable(Float64[]),
        Observable(Float64[]),
        Observable(Float64[]),
        KalmanState(),
        Observable(Float64[]),
        Observable(Float64[]),
        KalmanState(),
        [RoiChannelIntensity() for _ in 1:max(1, channel_count)]
    )
end

"""
    roi_series(app_run)

Every `RoiSeries` currently allocated — the idiomatic way to iterate "for
each region" over an `AppRun` regardless of channel-visibility toggles (used
for resetting/notifying/recomputing smoothing on all of them at once; see
`shown_channel_series` in plotting.jl for the toggle-gated, per-plot
iteration).
"""
roi_series(app_run) = app_run.rois_series

"""
    roi_channel_intensities(app_run)

Every `(RoiSeries, RoiChannelIntensity)` pair currently allocated, across all
regions and channels — the per-channel counterpart to `roi_series`, used
where smoothing or resetting has to reach the innermost series.
"""
function roi_channel_intensities(app_run)
    return ((series, channel) for series in app_run.rois_series for channel in series.channels)
end

"""
    RoiCoordinates

One ROI's boundary — imported from an ImageJ .roi/.zip file or manually
drawn in the ROI popup (roi_popup.jl) — in the underlying image's own
0-based pixel coordinates (not any particular popup canvas/display offset).
`xs`/`ys` are parallel, closed-loop vectors (last point equals first),
matching `roi_boundary_points`'s convention in roi_popup.jl.
"""
struct RoiCoordinates
    name::String
    xs::Vector{Float64}
    ys::Vector{Float64}
end

"""
    AppRun

Runtime state for the application. This structure holds references to
background tasks, communication channels, and observables that update
during execution. It is NOT serialized.

# Fields
- `channel::Union{Channel{AcquisitionSample}, Nothing}`: worker->consumer data channel
- `running::Threads.Atomic{Bool}`: flag controlling background task lifetime
- `paused::Threads.Atomic{Bool}`: flag pausing the background tasks
- `worker_task::Union{Task, Nothing}`: background worker processing task
- `consumer_task::Union{Task, Nothing}`: data consumer and GUI update task
- `autoscaler_task::Union{Task, Nothing}`: periodic axis autoscaling task
- `infos_task::Union{Task, Nothing}`: periodic info/status update task
- `serial_task::Union{Task, Nothing}`: periodic serial command task
- `serial_conn::Union{SerialPort, Nothing}`: open serial connection, if any
- `preview::Observable{Union{Nothing, FramePreview}}`: the most recent
  downsampled frame snapshot, overwritten (not appended to) each update and
  rendered by the image plot. `nothing` until the first preview is built, and
  whenever the image plot is not selected — see `build_preview`
  (acquisition.jl)
- `rois_series::Vector{RoiSeries}`: per-region accumulated time series
  (every plot but the image one) — `max(1, length(rois[]))` entries as of the
  last `rebuild_roi_series!` call (`start_pressed`/CLEAR, runtime.jl), but
  only when the ROI toggle (`app.roi.active`, Protocol panel,
  handlers_protocol.jl) is on; a single-element vector — reproducing the
  original un-split single-series behavior — otherwise, regardless of how
  many ROIs are drawn
- `channel_count::Int`: how many channels the current acquisition writes,
  resolved from the `C<n>` folder count at START (tiff_source.jl) and used to
  size every `RoiSeries.channels`. Defaults to 2 before a run has resolved a
  layout
- `protocol_setpoint::Observable{Vector{Float64}}`: time-series of protocol setpoints used by PID
- `command1::Observable{Vector{Float64}}` / `command2`: time-series of PID command values —
  NOT split per ROI: these drive real hardware output (serial.jl), not just
  the "Command" plot, so they stay a single shared series regardless of ROI count
- `timestamps::Observable{Vector{Float64}}`: time-series timestamps
- `i::Observable{UInt32}`: current frame/iteration counter
- `save_progress::Observable{Float64}`: Save-mode progress (percent, `NaN` when idle)
- `protocol::Observable{ProtocolSettings}`: normalized protocol config for the worker
- `rois::Observable{Vector{RoiCoordinates}}`: currently-drawn ROI boundaries
  (imported or manually drawn in the ROI popup, roi_popup.jl), shared here
  so other panels/functions can read the current ROI set without reaching
  into the popup itself
- `target_frequency::Threads.Atomic{Float64}`: Playback mode's target frame
  rate (Hz) — an `Atomic`, not an `Observable`, because `start_playback`
  (acquisition.jl) reads it every cycle from its own worker thread
  (`Threads.@spawn`), not the GUI thread; the target-frequency textbox
  (GUI.jl/handlers.jl) writes to it live, so it takes effect mid-run
- `imported_image_size::Tuple{Int,Int}`: `(width, height)` in pixels of the
  most recently imported ROI-popup image (roi_popup.jl's `im_import_button`
  handler) — `rois[]`'s coordinates are in this image's own pixel space.
  Read by `roi_trigger_buffer` (roi.jl) to correct for an image shorter
  than the trigger box's voltage calibration reference (see its docstring).
  Defaults to `(1024, 1024)`, matching that calibration reference, so a run
  started before any image has been imported this session behaves as if no
  correction were needed.
"""
mutable struct AppRun
    channel::Union{Channel{AcquisitionSample}, Nothing}
    running::Threads.Atomic{Bool}
    paused::Threads.Atomic{Bool}
    worker_task::Union{Task, Nothing}
    consumer_task::Union{Task, Nothing}
    autoscaler_task::Union{Task, Nothing}
    infos_task::Union{Task, Nothing}
    serial_task::Union{Task, Nothing}
    serial_conn::Union{SerialPort, Nothing}
    preview::Observable{Union{Nothing, FramePreview}}
    rois_series::Vector{RoiSeries}
    channel_count::Int
    protocol_setpoint::Observable{Vector{Float64}}
    command1::Observable{Vector{Float64}}
    command2::Observable{Vector{Float64}}
    timestamps::Observable{Vector{Float64}}
    i::Observable{UInt32}
    save_progress::Observable{Float64}
    protocol::Observable{ProtocolSettings}
    rois::Observable{Vector{RoiCoordinates}}
    target_frequency::Threads.Atomic{Float64}
    imported_image_size::Tuple{Int,Int}
end

"""
    AppRun()

Fresh runtime state: empty observables, all tasks and the channel `nothing`.
"""
function AppRun()
    return AppRun(
        nothing,
        Threads.Atomic{Bool}(false),
        Threads.Atomic{Bool}(false),
        nothing,
        nothing,
        nothing,
        nothing,
        nothing,
        nothing,
        Observable{Union{Nothing, FramePreview}}(nothing),
        [RoiSeries(DEFAULT_CHANNEL_COUNT)],
        DEFAULT_CHANNEL_COUNT,
        Observable(Float64[]),
        Observable(Float64[]),
        Observable(Float64[]),
        Observable(Float64[]),
        Observable{UInt32}(0),
        Observable(NaN),
        Observable(ProtocolSettings()),
        Observable(RoiCoordinates[]),
        Threads.Atomic{Float64}(DEFAULT_PLAYBACK_TARGET_FREQUENCY_HZ),
        (1024, 1024)
    )
end
