"""
lifetime_analysis.jl

Fluorescence lifetime fitting and IRF (Instrument Response Function)
management: IRF loading, IRF-decay convolution, and MLE fitting of
multi-exponential decays (1, 2, 3+ lifetimes).

References: Bajzer et al. 1991 (MLE methodology); Maus et al. 2001 (MLE for
FLIM); Enderlein 1997 (IRF shift/delay compensation).
"""

using FFTW
using Statistics
using NativeFileDialog
using Optim
using LineSearches
using ZipFile
using LinearAlgebra: mul!

const X_DATA_CACHE = Dict{Tuple{Int, Float64}, Vector{Float64}}()
const GATING_CACHE = Dict{Tuple{Int, Int, Int}, Vector{UInt8}}()
const IRF_CHANNEL_CACHE = Dict{Int, Matrix{Float64}}()

# -----------------------------------------------------------------------------
# Helpers IRF
# -----------------------------------------------------------------------------

function sum_reshaped_channels(file::Vector{UInt16}, num_rows::Int)::Vector{Float64}
    return sum(reshape(file, (num_rows, :)), dims=2)[:, 1]
end

# Shared by both channels in read_sdt_frame: reshape/sum a raw data block
# down to one histogram_resolution-length counts vector.
function extract_channel_counts(flat_data::AbstractArray, histogram_resolution::Int)::Vector{UInt16}
    flat_counts = vec(flat_data)
    return if length(flat_counts) == histogram_resolution
        convert.(UInt16, flat_counts)
    else
        convert.(UInt16, sum_reshaped_channels(convert.(UInt16, flat_counts), histogram_resolution))
    end
end

"""
    read_sdt_frame(filepath::String)::Tuple{Vector{UInt16}, Union{Nothing,Vector{UInt16}}, Int, Float32}

Low-level reader for Becker & Hickl .sdt files, used by both the acquisition
loop (acquisition.jl) and IRF loading (`load_irf_from_sdt` below).

Parses the file via the `SdtFile` module (src/io/SdtFile.jl), which handles
header/block parsing and both uncompressed and ZIP-compressed formats. When
a block holds multiple repeated histograms (e.g. multiple pixels/frames
packed into one compressed block), they are summed into a single histogram
via `sum_reshaped_channels`, matching the previous hand-rolled reader.

SDT files may hold one or two TCSPC channels (`sdt.data[1]` / `sdt.data[2]`).
`counts2` is `nothing` when the file has only one data block — callers decide
once (from the first file of a run) whether to treat the whole acquisition as
one- or two-channel; this function itself just reports what a given file
actually contains.

The one field kept as a direct byte read is `frame_time`: a `Float32` at
`meas_desc_block_offset + 215` that `SdtFile.MeasureInfo` doesn't expose
individually (it only names the fields needed for reshape/time-axis
computation). Reading it directly here preserves exact behavior from the
previous implementation.
"""
function read_sdt_frame(filepath::String)::Tuple{Vector{UInt16}, Union{Nothing,Vector{UInt16}}, Int, Float32}
    raw_bytes = read(filepath)
    sdt = SdtFile.read_sdt(raw_bytes, basename(filepath))

    isempty(sdt.data) && error("SDT file contains no data blocks: $filepath")
    isempty(sdt.measure_info) && error("SDT file contains no measurement info: $filepath")

    histogram_resolution = Int(sdt.measure_info[1].adc_re)
    counts1 = extract_channel_counts(sdt.data[1], histogram_resolution)
    counts2 = length(sdt.data) >= 2 ? extract_channel_counts(sdt.data[2], histogram_resolution) : nothing

    meas_desc_offset = Int(sdt.header.meas_desc_block_offset)
    frame_time = reinterpret(Float32, raw_bytes[meas_desc_offset+216 : meas_desc_offset+219])[1]

    return counts1, counts2, histogram_resolution, frame_time
end

function load_irf_from_sdt(filepath::AbstractString; channel::Int=1)::Matrix{Float64}
    counts_raw, _, histogram_resolution, time = read_sdt_frame(String(filepath))

    counts = Float64.(counts_raw)
    if isempty(counts)
        error("IRF file contains no histogram data")
    end

    median_irf = round(median(counts))
    counts .-= round(Int, median_irf)
    counts[counts .<= 0] .= 0

    n = min(length(counts), histogram_resolution)
    bin_size_ns = Float64(time) * 1e9
    window_ns = bin_size_ns * n

    if !isfinite(bin_size_ns) || bin_size_ns <= 0.0 || !isfinite(window_ns) || window_ns > 1_000.0
        bin_size_ns = 12.5 / n
    end

    times = collect(0:n-1) .* bin_size_ns

    data = zeros(Float64, n, 2)
    data[:, 1] = times
    data[:, 2] = counts[1:n]
    return data
end

function get_irf(; channel=1)
    cache_path = irf_filepath_cache()

    filepath = isfile(cache_path) ? open(f -> read(f, String), cache_path) : ""

    if !ispath(filepath)
        if !isempty(filepath)
            @warn "Cached IRF filepath does not exist; please select a valid .sdt file" path=filepath
        end
        filepath = pick_file()
        set_path_cache!(cache_path, filepath)
    end

    return load_irf_from_sdt(filepath; channel=channel)
end

function compute_irf_bin_size(irf_data::Matrix{Float64})::Float64
    h = Inf
    for i in 2:size(irf_data, 1)
        dt = irf_data[i, 1] - irf_data[i-1, 1]
        if 0 < dt < h
            h = dt
        end
    end
    return h
end

function get_irf_bin_size()
    data_irf = get_irf()
    return compute_irf_bin_size(data_irf)
end

# -----------------------------------------------------------------------------
# Etat global
# -----------------------------------------------------------------------------

isnotnan(x) = !isnan(x)
smaller_or_eq_zero(x) = x <= 0

# Concrete FFTW plan types, computed once rather than hardcoded — each is
# empirically stable across input lengths (length isn't part of a Vector's
# type), but deriving them this way stays correct even if FFTW.jl's internal
# parametrization changes across versions. `plan_fft` and `plan_ifft` are
# NOT the same type as each other: `plan_ifft` wraps its plan in an
# `AbstractFFTs.ScaledPlan` for the 1/N normalization, so they need separate
# aliases rather than one shared `FFTPlanType`.
const FFTPlanType = typeof(plan_fft(zeros(Float64, 1)))
const IFFTPlanType = typeof(plan_ifft(zeros(Float64, 1)))

"""
    RuntimeContext

IRF and FFT-plan state shared by the lifetime-fitting and acquisition code.
Held behind the `const` `RUNTIME` `Ref` below so every field access is
concretely typed (unlike a bare untyped `global`), which matters here since
this is read from the acquisition hot loop (up to 1kHz in Playback mode).

Not thread-safe, by design rather than oversight: `run_acquisition_loop!`
runs on its own OS thread (`Threads.@spawn`, see runtime.jl) so the GUI
thread stays responsive during a fit, but its fields (and the FFT/gating/
IRF-channel caches in this file) are only ever written from that single
worker thread (`ensure_fft_plans`/`ensure_runtime_state!`, called from
inside `vec_to_lifetime`) — `start_pressed` refuses to launch a second
worker while one is running, and `init_irf_runtime!()` only ever runs
before a worker starts. Everywhere else (GUI/consumer code) only reads
these fields. If that ever changes — e.g. a "reload IRF while running"
button that calls `init_irf_runtime!()` concurrently with a worker — these
fields and caches would need locking.

Fields:
- `irf` - Loaded Instrument Response Function, or `nothing` before/if loading fails
- `irf_bin_size` - IRF time-bin width in ns
- `tcspc_window_size` - Total TCSPC acquisition window in ns
- `fft_plan` / `ifft_plan` - Planned FFTW transforms, sized `fft_plan_size`
- `fft_plan_size` - Histogram resolution the current plans were built for
- `irf_cache_source_id` - `objectid(irf)` at last cache build, to detect a
  newly-loaded IRF and invalidate `IRF_CHANNEL_CACHE`
- `conv_scratch_in` / `conv_scratch_a` / `conv_scratch_b` - reusable
  `ComplexF64` buffers for `convolve`'s in-place FFTs (`mul!`, see below),
  sized `fft_plan_size`. `convolve` runs on every `Optim` objective
  evaluation (50-200+ times per fit) so avoiding a fresh heap allocation per
  buffer per call materially cuts GC pressure in the acquisition hot loop.
"""
mutable struct RuntimeContext
    irf::Union{Nothing, Matrix{Float64}}
    irf_bin_size::Union{Nothing, Float64}
    tcspc_window_size::Union{Nothing, Float64}
    fft_plan::FFTPlanType
    ifft_plan::IFFTPlanType
    fft_plan_size::Int
    irf_cache_source_id::UInt
    conv_scratch_in::Vector{ComplexF64}
    conv_scratch_a::Vector{ComplexF64}
    conv_scratch_b::Vector{ComplexF64}
end

"""
    RUNTIME::Ref{RuntimeContext}

Populated in `__init__()` below, not here, with a 256-point FFT plan default
(matching histogram resolution) and no IRF loaded yet. Always defined by the
time any application code runs — callers never need to guard against it not
existing, only against `RUNTIME[].irf` still being `nothing`.

FFTW plans wrap a raw C pointer (`fftw_plan`) that is only valid within the
process that created it. Building the initial plans here, in a top-level
`const` initializer, would run them once during precompilation and bake that
now-stale pointer into the precompiled package cache — the next process to
load the package from that cache would execute a dangling pointer and
segfault (confirmed empirically: this crashed 100% of the time on the first
FFT execution after a precompiled load, and disappeared once construction
moved into `__init__()`). `__init__()` is Julia's mechanism for exactly this
case: it reruns in every fresh process, precompiled or not.
"""
const RUNTIME = Ref{RuntimeContext}()

function __init__()
    RUNTIME[] = RuntimeContext(
        nothing, nothing, nothing,
        plan_fft(zeros(Float64, 256)), plan_ifft(zeros(Float64, 256)), 256,
        UInt(0),
        Vector{ComplexF64}(undef, 256), Vector{ComplexF64}(undef, 256), Vector{ComplexF64}(undef, 256)
    )
    return nothing
end

function ensure_fft_plans(size::Int)
    ctx = RUNTIME[]
    if ctx.fft_plan_size != size
        ctx.fft_plan = plan_fft(zeros(Float64, size))
        ctx.ifft_plan = plan_ifft(zeros(Float64, size))
        ctx.fft_plan_size = size
        ctx.conv_scratch_in = Vector{ComplexF64}(undef, size)
        ctx.conv_scratch_a = Vector{ComplexF64}(undef, size)
        ctx.conv_scratch_b = Vector{ComplexF64}(undef, size)
    end
    return nothing
end

function get_x_data(total_channels::Int, bin_size::Float64)::Vector{Float64}
    key = (total_channels, bin_size)
    cached = get(X_DATA_CACHE, key, nothing)
    if cached !== nothing
        return cached
    end

    x_data = collect(bin_size:bin_size:total_channels * bin_size)
    X_DATA_CACHE[key] = x_data
    return x_data
end

function get_gating_function(total_channels::Int, low_cut_idx::Int, high_cut_idx::Int)::Vector{UInt8}
    if total_channels <= 0
        return UInt8[]
    end

    low_cut = clamp(low_cut_idx, 0, total_channels)
    high_cut = clamp(high_cut_idx, 1, total_channels + 1)

    key = (total_channels, low_cut, high_cut)
    cached = get(GATING_CACHE, key, nothing)
    if cached !== nothing
        return cached
    end

    gating = ones(UInt8, total_channels)
    if low_cut >= 1
        gating[1:low_cut] .= 0
    end
    if high_cut <= total_channels
        gating[high_cut:total_channels] .= 0
    end

    GATING_CACHE[key] = gating
    return gating
end

function get_irf_for_channels(total_channels::Int)::Matrix{Float64}
    ctx = RUNTIME[]
    if size(ctx.irf, 1) == total_channels
        return ctx.irf
    end

    cached = get(IRF_CHANNEL_CACHE, total_channels, nothing)
    if cached !== nothing
        return cached
    end

    new_irf = zeros(Float64, total_channels, 2)
    new_irf[:, 1] = collect(ctx.irf_bin_size:ctx.irf_bin_size:ctx.irf_bin_size * total_channels)
    ncopy = min(total_channels, size(ctx.irf, 1))
    new_irf[1:ncopy, 2] = ctx.irf[1:ncopy, 2]

    IRF_CHANNEL_CACHE[total_channels] = new_irf
    return new_irf
end

function fit_optim_options(number_of_lifetimes::Int, first_fit::Bool)
    if number_of_lifetimes == 1
        if first_fit
            return Optim.Options(outer_iterations=14, iterations=64, x_abstol=5e-7, outer_x_abstol=5e-7, f_reltol=1e-5, outer_f_reltol=1e-4, f_calls_limit=280, time_limit=0.060, allow_f_increases=true)
        end
        return Optim.Options(outer_iterations=8, iterations=32, x_abstol=5e-7, outer_x_abstol=5e-7, f_reltol=1e-5, outer_f_reltol=1e-4, f_calls_limit=140, time_limit=0.020, allow_f_increases=true)
    elseif number_of_lifetimes == 2
        if first_fit
            return Optim.Options(outer_iterations=10, iterations=40, f_reltol=1e-5, outer_f_reltol=1e-4, x_abstol=5e-7, outer_x_abstol=5e-7, f_calls_limit=220, time_limit=0.050)
        end
        return Optim.Options(outer_iterations=6, iterations=24, f_reltol=1e-5, outer_f_reltol=1e-4, x_abstol=5e-7, outer_x_abstol=5e-7, f_calls_limit=120, time_limit=0.015)
    end

    if first_fit
        return Optim.Options(outer_iterations=6, iterations=24, f_reltol=1e-4, outer_f_reltol=1e-3, x_abstol=1e-6, outer_x_abstol=1e-6, f_calls_limit=160, time_limit=0.030)
    end
    return Optim.Options(outer_iterations=4, iterations=16, f_reltol=1e-4, outer_f_reltol=1e-3, x_abstol=1e-6, outer_x_abstol=1e-6, f_calls_limit=80, time_limit=0.012)
end

function clamp_initial_point!(params_copy::Vector{Float64}, lower_bounds::Vector{Float64}, upper_bounds::Vector{Float64}; eps=1e-6)
    @inbounds for i in eachindex(params_copy)
        lo = lower_bounds[i] + eps
        hi = upper_bounds[i] - eps
        if lo > hi
            lo = lower_bounds[i]
            hi = upper_bounds[i]
        end
        params_copy[i] = clamp(params_copy[i], lo, hi)
    end
    return params_copy
end

function ensure_runtime_state!()
    ctx = RUNTIME[]
    if ctx.irf === nothing
        error("IRF not loaded. Call init_irf_runtime!() (or set RUNTIME[].irf) before calling vec_to_lifetime.")
    end
    if ctx.irf_bin_size === nothing || !isfinite(ctx.irf_bin_size)
        error("irf_bin_size not initialized. Set RUNTIME[].irf_bin_size = compute_irf_bin_size(RUNTIME[].irf).")
    end
    if ctx.tcspc_window_size === nothing || !isfinite(ctx.tcspc_window_size) || ctx.tcspc_window_size <= 0
        error("tcspc_window_size not initialized. Set RUNTIME[].tcspc_window_size from RUNTIME[].irf.")
    end

    src_id = objectid(ctx.irf)
    if ctx.irf_cache_source_id != src_id
        empty!(IRF_CHANNEL_CACHE)
        ctx.irf_cache_source_id = src_id
    end

    ensure_fft_plans(size(ctx.irf, 1))
    return nothing
end

# -----------------------------------------------------------------------------
# Convolution et modeles
# -----------------------------------------------------------------------------

"""
    convolve(irf_vec, decay; ...)

Runs on every `Optim` objective evaluation (50-200+ times per fit, x2
channels), so the FFTs are done in-place via `mul!` into `RUNTIME[]`'s
`conv_scratch_*` buffers (resized alongside the plans in `ensure_fft_plans`)
instead of the allocating `plan * x` form -- cuts this function from 5-6
heap allocations down to 1 (the freshly-owned `y` this function returns;
everything upstream of that stays in the reused scratch buffers). Verified
bit-identical output to the previous allocating form across a range of
inputs before landing this (see lifetime_analysis tests).

Not thread-safe, same as the rest of `RuntimeContext` (see its docstring):
scratch buffers are reused sequentially within one call and across calls
from the single acquisition worker thread, never concurrently.
"""
function convolve(irf_vec::Vector{Float64}, decay::Vector{Float64}; histogram_resolution::Int64=256, tcspc_low_cut_index::Int64=13, tcspc_high_cut_index::Int64=12)
    if length(irf_vec) != length(decay)
        error("IRF and decay vectors must have same length: $(length(irf_vec)) vs $(length(decay))")
    end

    ensure_fft_plans(length(irf_vec))
    ctx = RUNTIME[]

    ctx.conv_scratch_in .= irf_vec
    mul!(ctx.conv_scratch_a, ctx.fft_plan, ctx.conv_scratch_in)

    ctx.conv_scratch_in .= decay
    mul!(ctx.conv_scratch_b, ctx.fft_plan, ctx.conv_scratch_in)

    ctx.conv_scratch_a .*= ctx.conv_scratch_b
    mul!(ctx.conv_scratch_b, ctx.ifft_plan, ctx.conv_scratch_a)

    y = real.(ctx.conv_scratch_b)

    lo = clamp(tcspc_low_cut_index, 1, histogram_resolution)
    hi = clamp(histogram_resolution - tcspc_high_cut_index, lo, histogram_resolution)
    denom = sum(view(y, lo:hi))
    if denom <= 0 || !isfinite(denom)
        return y
    end

    y ./= denom
    return y::Vector{Float64}
end

"""
    irf_shift(data_irf, shift)

Linear-interpolated circular shift of the IRF by `shift` bins. `shift` is
itself an optimized parameter, so (unlike `get_x_data`/`get_channel_range`
etc.) the result can't be cached across `Optim` evaluations -- but the
previous broadcast form still allocated ~8-9 temporary arrays per call
(the `channel .- ... .% n ...` chains, plus the fancy-indexing gathers)
purely to materialize `index_1`/`index_2` before combining them. Rewritten
as a single `@inbounds` loop computing both indices per-element (`channel`
was always just `1:n`, i.e. the loop variable itself, so `get_channel_range`
is no longer needed either) into one freshly-allocated output -- down to 1
allocation per call. This is a literal transliteration of the original
per-element arithmetic (including its two *different*, individually
redundant `rem`/`mod1` reduction chains for index_1 vs index_2) rather than
a hand-simplified formula, specifically to keep this verifiably
bit-identical to the previous implementation -- verified across a range of
n/shift values before landing this.
"""
function irf_shift(data_irf::Matrix{Float64}, shift)
    if isnan(shift)
        shift = 0
    end

    n = size(data_irf, 1)
    irf_counts = @view data_irf[:, 2]

    floor_off = floor(Int, shift) - 1
    ceil_off = ceil(Int, shift) - 1
    # Computed with the exact same operation order as the original
    # `(1 - shift) + floor(shift)` / `(shift - floor(shift))` -- not
    # algebraically simplified to `1 - w2` -- since floating-point +/- is
    # not associative and that reordering measurably produced a ~1e-15
    # (1-ULP) difference from the original in verification.
    w1 = 1 - shift + floor(shift)
    w2 = shift - floor(shift)

    out = Vector{Float64}(undef, n)
    @inbounds for i in 1:n
        idx1 = mod1(rem(rem(rem(i - floor_off, n), n), n) + 1, n)
        idx2 = mod1(rem(rem(i - ceil_off, n) + n, n) + 1, n)
        out[i] = w1 * irf_counts[idx1] + w2 * irf_counts[idx2]
    end

    return out::Vector{Float64}
end

function conv_irf_data(x_data::Vector{Float64}, params::Tuple{Float64, Float64, Float64}, data_irf::Matrix{Float64}; histogram_resolution::Int64=256, number_of_previous_pulses::Int64=5, laser_pulse_period::Float64=12.5, tcspc_low_cut_index::Int64=13, tcspc_high_cut_index::Int64=12)
    return convolve(irf_shift(data_irf, params[2]), exp.(-x_data ./ params[1]), histogram_resolution=histogram_resolution, tcspc_low_cut_index=tcspc_low_cut_index, tcspc_high_cut_index=tcspc_high_cut_index)
end

function conv_irf_data(x_data::Vector{Float64}, params::Tuple{Float64, Float64, Float64, Float64, Float64}, data_irf::Matrix{Float64}; histogram_resolution::Int64=256, number_of_previous_pulses::Int64=5, laser_pulse_period::Float64=12.5, tcspc_low_cut_index::Int64=13, tcspc_high_cut_index::Int64=12)
    t_1, a_1, t_2, d_0, _ = params
    irf_y_data = irf_shift(data_irf, d_0)

    exp_1 = @. a_1 * exp(-x_data / t_1)
    exp_2 = @. (1.0 - a_1) * exp(-x_data / t_2)

    # @. fuses the whole RHS (including the unary minus, which a plain `.`
    # chain does NOT fuse across -- confirmed by measurement) into one pass
    # written straight into exp_1/exp_2, instead of materializing an
    # intermediate array at every operator. This loop dominates conv_irf_data's
    # allocations (it runs on every Optim objective/gradient evaluation, i.e.
    # 50-200+ times per fit): measured 29% of total fit wall time spent in GC
    # before this change, with individual fits occasionally spending 250+ ms
    # in a single GC pause. Verified bit-identical output to the previous
    # unfused form across a range of parameter values before landing this.
    for previous_pulse in 1:number_of_previous_pulses
        shift = laser_pulse_period * previous_pulse
        @. exp_1 += a_1 * exp(-(x_data + shift) / t_1)
        @. exp_2 += (1.0 - a_1) * exp(-(x_data + shift) / t_2)
    end

    return convolve(irf_y_data, exp_1 .+ exp_2, histogram_resolution=histogram_resolution, tcspc_low_cut_index=tcspc_low_cut_index, tcspc_high_cut_index=tcspc_high_cut_index)
end

function conv_irf_data(x_data::Vector{Float64}, params::Tuple{Float64, Float64, Float64, Float64, Float64, Float64, Float64, Float64}, data_irf::Matrix{Float64}; histogram_resolution::Int64=256, number_of_previous_pulses::Int64=5, laser_pulse_period::Float64=12.5, tcspc_low_cut_index::Int64=13, tcspc_high_cut_index::Int64=12)
    t_1 = params[1]
    a_1 = abs(params[2])
    t_2 = params[3]
    a_2 = abs(params[4])
    t_3 = params[5]
    a_3 = params[6]
    d_0 = params[7]

    irf_y_data = irf_shift(data_irf, d_0)

    exp_1 = @. a_1 * exp(-x_data / t_1)
    exp_2 = @. a_2 * exp(-x_data / t_2)
    exp_3 = @. a_3 * exp(-x_data / t_3)

    # See the 5-parameter (2-lifetime) conv_irf_data above for why @. here
    # (full-expression fusion, no intermediate temp arrays) instead of the
    # previous per-operator .+ / .* / exp. chain.
    for previous_pulse in 1:number_of_previous_pulses
        shift = laser_pulse_period * previous_pulse
        @. exp_1 += a_1 * exp(-(x_data + shift) / t_1)
        @. exp_2 += a_2 * exp(-(x_data + shift) / t_2)
        @. exp_3 += a_3 * exp(-(x_data + shift) / t_3)
    end

    return convolve(irf_y_data, exp_1 .+ exp_2 .+ exp_3, histogram_resolution=histogram_resolution, tcspc_low_cut_index=tcspc_low_cut_index, tcspc_high_cut_index=tcspc_high_cut_index)
end

# -----------------------------------------------------------------------------
# Fit MLE
# -----------------------------------------------------------------------------

function three_lifetime_fraction_constraints!(c, x)
    c[1] = x[2] + x[4] + x[6]
    c
end

function mle_objective(free_params::Vector{Float64}, fixed_params::Vector{Float64}, x_data::Vector{Float64}, y_data::Vector{Float64}, data_irf::Matrix{Float64}, gating_function::Vector{UInt8}, histogram_resolution::Int64, number_of_previous_pulses::Int64, laser_pulse_period::Float64, tcspc_low_cut_index::Int64, tcspc_high_cut_index::Int64)
    if length(fixed_params) == 3
        number_of_lifetimes = 1
    elseif length(fixed_params) == 5
        number_of_lifetimes = 2
    else
        number_of_lifetimes = 3
    end

    params = zeros(Float64, length(fixed_params))
    if length(free_params) == length(fixed_params)
        params = free_params
    else
        free_idx = 1
        for i in eachindex(fixed_params)
            if isnan(fixed_params[i])
                params[i] = free_params[free_idx]
                free_idx += 1
            else
                params[i] = fixed_params[i]
            end
        end
    end

    n_counts = float(sum(y_data))
    n_active_bins = max(1, histogram_resolution - tcspc_low_cut_index - tcspc_high_cut_index)

    if number_of_lifetimes == 1
        exp_val_c = ((1 - params[3]) .* conv_irf_data(x_data, (params[1], params[2], params[3]), data_irf, histogram_resolution=histogram_resolution, number_of_previous_pulses=number_of_previous_pulses, laser_pulse_period=laser_pulse_period, tcspc_low_cut_index=tcspc_low_cut_index, tcspc_high_cut_index=tcspc_high_cut_index) .+ params[3] / n_active_bins) .* n_counts
    elseif number_of_lifetimes == 2
        exp_val_c = ((1 - params[5]) .* conv_irf_data(x_data, (params[1], params[2], params[3], params[4], params[5]), data_irf, histogram_resolution=histogram_resolution, number_of_previous_pulses=number_of_previous_pulses, laser_pulse_period=laser_pulse_period, tcspc_low_cut_index=tcspc_low_cut_index, tcspc_high_cut_index=tcspc_high_cut_index) .+ params[5] / n_active_bins) .* n_counts
    else
        exp_val_c = ((1 - params[8]) .* conv_irf_data(x_data, (params[1], params[2], params[3], params[4], params[5], params[6], params[7], params[8]), data_irf, histogram_resolution=histogram_resolution, number_of_previous_pulses=number_of_previous_pulses, laser_pulse_period=laser_pulse_period, tcspc_low_cut_index=tcspc_low_cut_index, tcspc_high_cut_index=tcspc_high_cut_index) .+ params[8] / n_active_bins) .* n_counts
    end

    # y_data itself is already sanitized once in mle_reconvolution_fit before
    # Optim.optimize is called, not re-sanitized here on every one of its
    # 50-200+ objective evaluations -- exp_val_c is the only value that's
    # freshly recomputed each evaluation and actually needs it.
    replace!(x -> smaller_or_eq_zero(x) ? 1e-256 : x, exp_val_c)

    dev = 2.0 / (sqrt(n_counts) * (histogram_resolution - length(params))) * sum(gating_function .* (y_data .* log.(y_data ./ exp_val_c) .- y_data .+ exp_val_c))
    if isnan(dev)
        throw(ErrorException("NaN in objective function"))
    end
    return dev::Float64
end

function find_mean_arrival_time(counts::AbstractVector{<:Real}; tcspc_high_cut_index::Int64=0)
    lim = length(counts) - tcspc_high_cut_index
    lim = max(lim, 1)
    den = sum(counts[1:lim])
    if den <= 0
        return 0.0
    end

    num = 0.0
    @inbounds for i in 1:lim
        num += i * counts[i]
    end
    return num / den
end

function lifetime_estimate(counts::AbstractVector{<:Real}; bin_size=0.039, tcspc_high_cut_index::Int64=0)
    mean_irf_arrival_time = find_mean_arrival_time(RUNTIME[].irf[:, 2], tcspc_high_cut_index=tcspc_high_cut_index)
    mean_data_arrival_time = find_mean_arrival_time(counts, tcspc_high_cut_index=tcspc_high_cut_index)
    return ((mean_data_arrival_time - mean_irf_arrival_time) * bin_size)::Float64
end

"""
    pixel_lifetime_map(volume::Array{Float64,3}; min_photons::Real=50.0, tcspc_high_cut_index::Int64=0)::Matrix{Float64}

Per-pixel approximate lifetime (ns), via the same first-moment analysis as
`lifetime_estimate` (mean photon arrival time minus the IRF's own mean
arrival time, scaled by the IRF's bin size) but applied to every pixel's own
256-bin histogram (`volume[x, y, :]`, see `extract_sdt_volume` in
roi_popup.jl) instead of one combined ROI histogram. No MLE fit — this is
the cheap, no-optimizer estimate, meant for a quick per-pixel preview where
fitting every pixel individually would be far too slow.

A pixel with fewer than `min_photons` total counts gets `NaN` — first-moment
analysis is biased and noisy at low counts, so the caller (roi_popup.jl)
renders `NaN` as transparent rather than a misleading color. The IRF's own
mean arrival time is computed once up front, not per pixel (unlike calling
`lifetime_estimate` directly for every pixel would), so this stays cheap
even across a full ~10^6-pixel image.

Errors if the IRF hasn't been loaded (`RUNTIME[].irf`/`irf_bin_size`) —
there is no "reliable" lifetime without it.
"""
function pixel_lifetime_map(volume::Array{Float64,3}; min_photons::Real=50.0, tcspc_high_cut_index::Int64=0)::Matrix{Float64}
    irf = RUNTIME[].irf
    bin_size = RUNTIME[].irf_bin_size
    if irf === nothing || bin_size === nothing
        error("IRF not loaded. Call init_irf_runtime!() before computing a pixel lifetime map.")
    end

    mean_irf_arrival_time = find_mean_arrival_time(irf[:, 2]; tcspc_high_cut_index=tcspc_high_cut_index)

    n_cols, n_rows, n_bins = size(volume)
    result = fill(NaN, n_cols, n_rows)

    for y in 1:n_rows, x in 1:n_cols
        counts = @view volume[x, y, :]
        sum(counts) < min_photons && continue
        mean_arrival_time = find_mean_arrival_time(counts; tcspc_high_cut_index=tcspc_high_cut_index)
        result[x, y] = (mean_arrival_time - mean_irf_arrival_time) * bin_size
    end

    return result
end

# `fixed_parameters`'s default MUST track `params`'s length via `fill(NaN,
# length(params))`, not a fixed literal: mle_objective (below) infers
# number_of_lifetimes purely from `length(fixed_parameters)`, so a caller
# that fits a 2- or 3-lifetime model without overriding this default would
# otherwise silently get a 1-lifetime-shaped `fixed_parameters` and have
# mle_objective evaluate the WRONG model — the actual, previously-shipped
# bug this fixes: every full (non-partial) 2-lifetime fit in
# run_acquisition_loop! never passed `fixed_parameters` explicitly, so it
# silently optimized a degenerate 3-parameter proxy internally treated as
# number_of_lifetimes==1, ignoring the real τ2/shift/offset dimensions.
# Confirmed empirically: same guess/data, properly-scoped fixed_parameters
# converges to a genuinely different (and correctly warm-started, ~97%
# convergent) 2-exponential result at ~8x the per-fit cost of the buggy
# proxy — the previous "2 lifetimes" mode was fast because it wasn't really
# fitting two lifetimes.
function mle_reconvolution_fit(data_irf::Matrix{Float64}, data_xy::Vector{Vector{Float64}}; params, gating_function=ones(UInt8, 320), histogram_resolution::Int64=256, number_of_previous_pulses::Int64=5, laser_pulse_period::Float64=12.5, fixed_parameters::Vector{Float64}=fill(NaN, length(params)), tcspc_low_cut_index::Int64=13, tcspc_high_cut_index::Int64=12, use_lifetime_estimation_as_guess::Bool=true, first_fit::Bool=false)
    x_data = vec(data_xy[1])
    y_data = vec(data_xy[2]) .* gating_function
    replace!(x -> smaller_or_eq_zero(x) ? 1e-256 : x, y_data)

    number_of_lifetimes = floor(Int, (length(params) - 1) / 2)
    params_copy = copy(params)

    if all(isnotnan.(fixed_parameters))
        return fixed_parameters
    end

    irf_bin_size = RUNTIME[].irf_bin_size
    if number_of_lifetimes == 1
        if use_lifetime_estimation_as_guess
            params_copy[1] = lifetime_estimate(y_data, bin_size=irf_bin_size, tcspc_high_cut_index=tcspc_high_cut_index)
        end
        lower_bounds = Float64[2 * irf_bin_size, -16.0, 0.0]
        upper_bounds = Float64[laser_pulse_period * 2, 32.0, 1.0]
    elseif number_of_lifetimes == 2
        lower_bounds = Float64[2 * irf_bin_size, 0.0, 2 * irf_bin_size, -16.0, 0.0]
        upper_bounds = Float64[laser_pulse_period * 2, 1.0, laser_pulse_period * 2, 64.0, 1.0]
    else
        lower_bounds = Float64[2 * irf_bin_size, 0.0, 2 * irf_bin_size, 0.0, 2 * irf_bin_size, 0.0, -16.0, 0.0]
        upper_bounds = Float64[laser_pulse_period * 2, 1.0, laser_pulse_period * 2, 1.0, laser_pulse_period * 2, 1.0, 32.0, 1.0]
    end

    if any(.!isnan.(fixed_parameters))
        if length(params_copy) != length(fixed_parameters)
            error("params and fixed_parameters must be the same length")
        end
        fixed_indices = collect(1:length(fixed_parameters))[.!isnan.(fixed_parameters)]
        deleteat!(params_copy, fixed_indices)
        deleteat!(lower_bounds, fixed_indices)
        deleteat!(upper_bounds, fixed_indices)
    end

    clamp_initial_point!(params_copy, lower_bounds, upper_bounds)

    if number_of_lifetimes in (1, 2)
        fit = Optim.optimize(x -> mle_objective(x, fixed_parameters, x_data, y_data, data_irf, gating_function, histogram_resolution, number_of_previous_pulses, laser_pulse_period, tcspc_low_cut_index, tcspc_high_cut_index), lower_bounds, upper_bounds, params_copy, Fminbox(LBFGS(linesearch=LineSearches.BackTracking())), fit_optim_options(number_of_lifetimes, first_fit))
    else
        lower_c, upper_c = Float64[1.0], Float64[1.0]
        constraint = TwiceDifferentiableConstraints(three_lifetime_fraction_constraints!, lower_bounds, upper_bounds, lower_c, upper_c)
        fit = Optim.optimize(x -> mle_objective(x, fixed_parameters, x_data, y_data, data_irf, gating_function, histogram_resolution, number_of_previous_pulses, laser_pulse_period, tcspc_low_cut_index, tcspc_high_cut_index), constraint, params_copy, IPNewton(), fit_optim_options(number_of_lifetimes, first_fit))
    end

    res = Optim.minimizer(fit)

    output_res = zeros(Float64, length(params))
    if any(.!isnan.(fixed_parameters))
        free_counter = 1
        for p in eachindex(fixed_parameters)
            if isnan(fixed_parameters[p])
                output_res[p] = res[free_counter]
                free_counter += 1
            else
                output_res[p] = fixed_parameters[p]
            end
        end
    else
        output_res = res
    end

    if !Optim.converged(fit)
        if number_of_lifetimes == 1
            return Float64[NaN, NaN, NaN]
        elseif number_of_lifetimes == 2
            return Float64[NaN, NaN, NaN, NaN, NaN]
        end
        return Float64[NaN, NaN, NaN, NaN, NaN, NaN, NaN, NaN]
    end

    if number_of_lifetimes == 2 && output_res[3] > output_res[1]
        t_1 = output_res[1]
        t_2 = output_res[3]
        output_res[1] = t_2
        output_res[3] = t_1
        output_res[2] = 1 - output_res[2]
    elseif number_of_lifetimes == 3
        permutation = sortperm(output_res[1:2:5])
        found_params_copy = copy(output_res)
        adjusted = zeros(Int64, 3)
        for (idx, p) in enumerate(permutation)
            adjusted[idx] = p == 1 ? 1 : p == 2 ? 3 : 5
        end
        amplitudes = [found_params_copy[2], found_params_copy[4], found_params_copy[6]]
        output_res[1] = found_params_copy[adjusted[1]]
        output_res[2] = amplitudes[permutation[1]]
        output_res[3] = found_params_copy[adjusted[2]]
        output_res[4] = amplitudes[permutation[2]]
        output_res[5] = found_params_copy[adjusted[3]]
        output_res[6] = amplitudes[permutation[3]]
    end

    return output_res::Vector{Float64}
end

# -----------------------------------------------------------------------------
# API principale
# -----------------------------------------------------------------------------

# fixed_parameters's default tracks `guess`'s length -- see the comment on
# mle_reconvolution_fit above for why a fixed-length default is a bug.
function vec_to_lifetime(x; bin_size=0.04886091184430619, hist_size_threshold=500, method="MLE", guess=[3.0, 1.0, 1e-6], laser_pulse_period=12.5, histogram_resolution=256, number_of_previous_pulses=5, tac_low_cut=5.0980392, tac_high_cut=94.901962, IRF_delay=NaN, IRF_width=NaN, IRF_cutoff=NaN, lifetime_estimation=NaN, standard_deviation_estimation=NaN, fixed_parameters=fill(NaN, length(guess)), use_lifetime_estimation_as_guess::Bool=true, first_fit::Bool=false)
    ensure_runtime_state!()
    tcspc_window_size = RUNTIME[].tcspc_window_size

    requested_channels = round(Int, laser_pulse_period * histogram_resolution / tcspc_window_size)
    total_channels = requested_channels

    if total_channels <= 0
        @warn "Computed invalid total_channels from IRF window; falling back to histogram resolution" requested_channels=total_channels tcspc_window_size=tcspc_window_size histogram_resolution=histogram_resolution
        total_channels = histogram_resolution
    end

    if abs(total_channels - histogram_resolution) <= 1
        total_channels = histogram_resolution
    end

    total_channels = max(total_channels, histogram_resolution, length(x), 32)

    x_vec = Float64.(vec(x))
    if length(x_vec) < total_channels
        append!(x_vec, zeros(total_channels - length(x_vec)))
    elseif length(x_vec) > total_channels
        x_vec = x_vec[1:total_channels]
    end

    ensure_fft_plans(total_channels)
    irf_local = get_irf_for_channels(total_channels)

    x_data = get_x_data(total_channels, Float64(bin_size))

    if sum(x_vec) < hist_size_threshold
        if method == "Estimate"
            return Float64[0.0], [x_data, x_vec]::Vector{Vector{Float64}}
        end
        return Float64[NaN], [x_data, x_vec]::Vector{Vector{Float64}}
    end

    if method == "Estimate"
        return Float64[lifetime_estimate(x_vec[1:histogram_resolution], bin_size=bin_size)], [x_data[1:histogram_resolution], x_vec[1:histogram_resolution]]::Vector{Vector{Float64}}
    end

    if method != "MLE"
        error("Unsupported method in simplified lifetime_analysis.jl: $method. Supported methods: \"MLE\", \"Estimate\".")
    end

    low_cut_index = round(Int, tac_low_cut / 100 * histogram_resolution)
    low_cut_index = max(low_cut_index, 1)

    if tac_high_cut != 0
        high_cut_start = round(Int, tac_high_cut / 100 * histogram_resolution)
        high_cut_start = clamp(high_cut_start, 1, total_channels + 1)
        tcspc_high_cut_index = total_channels - high_cut_start
    else
        high_cut_start = total_channels + 1
        tcspc_high_cut_index = 0
    end

    gating_function = get_gating_function(total_channels, low_cut_index, high_cut_start)

    data_xy = [x_data, x_vec]

    tau_fit = mle_reconvolution_fit(
        irf_local,
        data_xy,
        params=guess,
        gating_function=gating_function,
        histogram_resolution=total_channels,
        number_of_previous_pulses=number_of_previous_pulses,
        laser_pulse_period=laser_pulse_period,
        fixed_parameters=fixed_parameters,
        tcspc_low_cut_index=low_cut_index,
        tcspc_high_cut_index=tcspc_high_cut_index,
        use_lifetime_estimation_as_guess=use_lifetime_estimation_as_guess,
        first_fit=first_fit,
    )

    return tau_fit::Vector{Float64}, data_xy::Vector{Vector{Float64}}
end

# -----------------------------------------------------------------------------
# JIT warmup
# -----------------------------------------------------------------------------

"""
    warmup_lifetime_fitting!()

Run one throwaway fit per lifetime-count model (1- and 2-lifetime; 3-lifetime
is skipped, see below) so Julia JIT-compiles the whole `vec_to_lifetime` ->
`Optim.optimize` -> `mle_objective` -> `conv_irf_data` -> `convolve` call
chain once, up front, instead of on the user's first real acquisition frame.

Why this matters: `conv_irf_data` dispatches on the *type* of its `params`
tuple (`Tuple{Float64,Float64,Float64}` for 1-lifetime vs
`Tuple{Float64,Float64,Float64,Float64,Float64}` for 2-lifetime) — genuinely
different methods requiring separate compilation — so each guess length must
be warmed independently. Measured cost of skipping this: the very first
`vec_to_lifetime` call in a process took 3-13 seconds of wall time in
testing, and because Julia's compiler holds locks shared across threads,
that stall was observed on the *main* GUI thread too, even though the fit
itself runs on its own thread (see `spawn_acquisition_worker!` in
runtime.jl) — i.e. moving the worker off the GUI thread does not by itself
prevent this specific freeze; only warming ahead of time does.

Only 1- and 2-lifetime are warmed: 3-lifetime has a separate, pre-existing
bug (`initial_guess_for_lifetimes("3 lifetimes")` returns a 7-element
guess but the model's bounds need 8) that throws before doing any fit work,
so there is nothing productive to warm there.

Uses a synthetic decay-shaped histogram, not real data — this only needs to
exercise the numeric code paths, not produce a scientifically meaningful
result (its output is discarded). Called once from `run_app()` after the
IRF is loaded and before the GUI is shown, so the delay reads as "app is
starting up" rather than "the app froze when I clicked Start".
"""
function warmup_lifetime_fitting!()
    ctx = RUNTIME[]
    if ctx.irf === nothing
        return nothing
    end

    synthetic_counts = [max(0.0, 1000.0 * exp(-i * 0.02) + 5.0) for i in 0:(DEFAULT_HISTOGRAM_RESOLUTION - 1)]

    for guess in (Float64[3.0, 0.0, 5.0e-5], Float64[3.0, 0.5, 0.5, 0.0, 5.0e-5])
        try
            vec_to_lifetime(synthetic_counts; guess=copy(guess), histogram_resolution=DEFAULT_HISTOGRAM_RESOLUTION, first_fit=true)
        catch e
            @warn "Lifetime-fitting warmup failed for one model; first real fit of this shape may be slow" guess_length=length(guess) error=string(e)
        end
    end

    return nothing
end
