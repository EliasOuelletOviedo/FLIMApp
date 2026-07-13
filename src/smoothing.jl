"""
smoothing.jl

Shared lifetime smoothing and PID helper utilities.

Responsibilities:
- Resolve smoothing level from layout
- Compute adaptive smoothing factors
- Provide shared Kalman-like smoothing logic
- Reuse the same PID smoothing state update across runtime and workers
"""

function lifetime_smooth_level(layout::LayoutSettings)::Int
    return clamp(layout.smoothing, 0, 10)
end

@inline function layout_smoothing_level(layout::LayoutSettings)::Int
    return lifetime_smooth_level(layout)
end

@inline function smooth_strength_factor(level::Int)::Float64
    # Keep level 1 unchanged and map level 10 to ~10x stronger smoothing.
    clamped_level = clamp(level, 1, 10)
    return 10.0 ^ ((clamped_level - 1) / 9)
end

function local_scale(values::Vector{Float64}, idx::Int, window::Int)::Float64
    if idx <= 1
        return 1.0e-6
    end

    start_idx = max(2, idx - window + 1)
    s = 0.0
    n = 0
    for k in start_idx:idx
        v1 = values[k]
        v0 = values[k - 1]
        if isfinite(v1) && isfinite(v0)
            s += abs(v1 - v0)
            n += 1
        end
    end

    return max(n > 0 ? (s / n) : 1.0e-6, 1.0e-6)
end

function compute_lifetime_smooth_at(
            values::Vector{Float64},
            idx::Int,
            level::Int,
            prev_smooth::Float64
        )::Float64
    if idx <= 0 || idx > length(values)
        return NaN
    end

    x = values[idx]
    if !isfinite(x)
        return NaN
    end

    # Level 0: smooth trace is an exact passthrough of the raw value.
    if level <= 0
        return x
    end

    if !isfinite(prev_smooth)
        return x
    end

    window = 4 + 5 * level
    scale = local_scale(values, idx, window)
    innovation = x - prev_smooth
    smooth_factor = smooth_strength_factor(level)

    q = max(scale * scale * (0.24 - 0.009 * level), 1.0e-12)
    r = max(scale * scale * (0.95 + 0.14 * level) * smooth_factor, 1.0e-12)

    gain = q / (q + r)
    innovation_ratio = abs(innovation) / (abs(innovation) + 2.0 * scale)
    gain_boost = 0.45 * innovation_ratio / smooth_factor
    k_min = 0.03 / smooth_factor
    k = clamp(gain + gain_boost, k_min, 0.90)

    return prev_smooth + k * innovation
end

"""
    update_pid_lifetime_kalman(current_lifetime, prev_smooth, prev_raw, scale_est, level)

Update a local adaptive Kalman smoother used by PID error computation.
Returns `(lifetime_for_pid, new_prev_smooth, new_prev_raw, new_scale_est)`.
"""
function update_pid_lifetime_kalman(
            current_lifetime::Float64,
            prev_smooth::Float64,
            prev_raw::Float64,
            scale_est::Float64,
            level::Int
        )::NTuple{4, Float64}
    if !isfinite(current_lifetime)
        return (current_lifetime, prev_smooth, prev_raw, scale_est)
    end

    if !isfinite(prev_raw)
        prev_raw = current_lifetime
    end

    delta_raw = abs(current_lifetime - prev_raw)
    if !isfinite(scale_est) || scale_est <= 0.0
        scale_est = max(delta_raw, 1.0e-6)
    else
        scale_est = max(0.90 * scale_est + 0.10 * delta_raw, 1.0e-6)
    end

    if level <= 0
        return (current_lifetime, current_lifetime, current_lifetime, scale_est)
    end

    if !isfinite(prev_smooth)
        prev_smooth = current_lifetime
    end

    smooth_factor = smooth_strength_factor(level)

    q = max(scale_est * scale_est * (0.24 - 0.009 * level), 1.0e-12)
    r = max(scale_est * scale_est * (0.95 + 0.14 * level) * smooth_factor, 1.0e-12)

    innovation = current_lifetime - prev_smooth
    gain = q / (q + r)
    innovation_ratio = abs(innovation) / (abs(innovation) + 2.0 * scale_est)
    gain_boost = 0.45 * innovation_ratio / smooth_factor
    k_min = 0.03 / smooth_factor
    k = clamp(gain + gain_boost, k_min, 0.90)

    smooth_lifetime = prev_smooth + k * innovation
    return (smooth_lifetime, smooth_lifetime, current_lifetime, scale_est)
end

# -----------------------------------------------------------------------------
# smoothed series helpers (used by consumer_loop / runtime.jl)
# -----------------------------------------------------------------------------
#
# Generic over which raw/smoothed observable pair they operate on, so
# lifetime and ion concentration (each channel) go through the exact same
# smoothing function with the exact same parameters
# (compute_lifetime_smooth_at) — not separate copies that could drift
# apart. Call sites pass the pair straight from a `ChannelSeries`
# (e.g. `series.lifetime`/`series.lifetime_smooth`), or use
# `recompute_channel_smooth!` below to redo a whole channel at once.

"""
    RECOMPUTE_LOOKBACK_MARGIN::Int

Extra samples replayed before the visible window in `recompute_smooth_series!`,
comfortably larger than the smoothing filter's own memory
(`window = 4 + 5*level`, max 54 at level 10) so the recomputed portion is
numerically indistinguishable from a full-history recompute by the time it
reaches the visible window.
"""
const RECOMPUTE_LOOKBACK_MARGIN = 500

function recompute_smooth_series!(app, source::Observable{Vector{Float64}}, target::Observable{Vector{Float64}}, timestamps::Observable{Vector{Float64}})
    # Snapshot mutable vectors to avoid transient length races with the consumer task.
    source_values = copy(source[])
    timestamps_values = copy(timestamps[])

    n_source = length(source_values)
    n_timestamps = length(timestamps_values)
    n_common = min(n_source, n_timestamps)

    level = lifetime_smooth_level(app.layout)

    # Recomputing from index 1 on every smoothing-level change (a UI-callback
    # side effect of moving the slider, running synchronously on the GUI
    # thread) is O(N) in total session samples — unbounded over a long
    # real-time run (measured elsewhere: comparable full-history scans cost
    # ~13 ms at 500k samples). Unlike the autoscale window in plotting.jl
    # this filter is path-dependent (each output depends on the previous
    # one), so it can't simply be sliced — instead replay starts
    # `RECOMPUTE_LOOKBACK_MARGIN` samples before the visible window so the
    # filter has settled by the time it reaches on-screen data, while
    # everything before that keeps its previously-computed value (from the
    # old smoothing level) rather than being blanked to NaN — a stale but
    # still-plotted value if the user later widens time_range, not a gap.
    target_current = target[]
    smoothed = length(target_current) == n_timestamps ? copy(target_current) : fill(NaN, n_timestamps)

    if n_common == 0
        target[] = smoothed
        return nothing
    end

    time_range = Float64(app.layout.time_range)
    cutoff = timestamps_values[n_common] - time_range
    visible_start = searchsortedfirst(view(timestamps_values, 1:n_common), cutoff)
    start_idx = max(1, visible_start - RECOMPUTE_LOOKBACK_MARGIN)

    prev = start_idx > 1 ? smoothed[start_idx - 1] : NaN
    if !isfinite(prev)
        prev = NaN
    end

    for idx in start_idx:n_common
        y = compute_lifetime_smooth_at(source_values, idx, level, prev)
        smoothed[idx] = y
        prev = y
    end

    target[] = smoothed
    return nothing
end

function append_smooth_value!(app, source::Observable{Vector{Float64}}, target::Observable{Vector{Float64}})
    idx = length(source[])
    if idx == 0
        return nothing
    end

    level = lifetime_smooth_level(app.layout)
    prev = isempty(target[]) ? NaN : target[][end]

    y = compute_lifetime_smooth_at(source[], idx, level, prev)
    push!(target[], y)

    return nothing
end

"""
    recompute_channel_smooth!(app, app_run, series::ChannelSeries)

Recompute one channel's smoothed photon-count, lifetime, and concentration
series (see `recompute_smooth_series!`) and notify their observables. Used
when the smoothing level changes (handlers_layout.jl).
"""
function recompute_channel_smooth!(app, app_run, series::ChannelSeries)
    recompute_smooth_series!(app, series.photons, series.photons_smooth, app_run.timestamps)
    notify(series.photons_smooth)
    recompute_smooth_series!(app, series.lifetime, series.lifetime_smooth, app_run.timestamps)
    notify(series.lifetime_smooth)
    recompute_smooth_series!(app, series.concentration, series.concentration_smooth, app_run.timestamps)
    notify(series.concentration_smooth)
    return nothing
end
