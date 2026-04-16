"""
smoothing.jl

Shared lifetime smoothing and PID helper utilities.

Responsibilities:
- Resolve smoothing level from layout
- Compute adaptive smoothing factors
- Provide shared Kalman-like smoothing logic
- Reuse the same PID smoothing state update across runtime and workers
"""

function lifetime_smooth_level(layout::Dict{Symbol, Any})::Int
    raw = get(layout, :smoothing, 0)
    val = raw isa Number ? Float64(raw) : 0.0
    return clamp(round(Int, val), 0, 10)
end

@inline function layout_smoothing_level(layout::Dict{Symbol, Any})::Int
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

    # Level 0 disables the smooth trace to avoid curve overlap with raw lifetime.
    if level <= 0
        return NaN
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
