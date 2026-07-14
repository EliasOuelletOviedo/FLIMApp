"""
smoothing.jl

Shared lifetime smoothing and PID helper utilities.

Responsibilities:
- Resolve smoothing level from layout
- Compute adaptive smoothing factors
- Provide the plot-facing smoothing filter — time-aware EMA with a jump
  snap, see `compute_lifetime_smooth_at`. Two properties, combined:
    - **A** — baseline gain from elapsed *acquisition* time, not sample count.
    - **B** — innovation-gated hard jump detection/snap (`robust_step_scale`),
      on two layers: a single-step test (is *this* sample a big step from the
      last one?) and a cumulative multi-step test (is the drift over the last
      several samples big, even though no individual step was?) — the latter
      catches a real rapid transition that lands spread across a handful of
      consecutive files (e.g. under ROI round-robin splitting, where each
      file only contributes a fraction of a fast underlying change and so
      never trips the single-step test on its own).
- Reuse the same PID smoothing state update across runtime and workers

`compute_lifetime_smooth_at` (plots: lifetime/photons/concentration, via
`append_smooth_value!`/`recompute_smooth_series!`) and
`update_pid_lifetime_kalman` (the PID feedback loop, acquisition.jl) are
deliberately separate filters despite the similar names/shape: the plot
filter optimizes for how the trace *looks* (smooth, but catches up fast on
real steps); the PID filter's tuning affects live hardware control
stability and hasn't been touched here.
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

"""
    SMOOTH_TIME_CONSTANT_MIN_STEPS::Float64 / SMOOTH_TIME_CONSTANT_MAX_STEPS::Float64

Exponential-smoothing time-constant endpoints, in units of this
acquisition's own *typical* frame spacing (`robust_typical_dt`), for the
plot filter (`plot_time_constant`) at level 1 and level 10 respectively.
The filter's baseline gain (`compute_lifetime_smooth_at`) is
`k = 1 - exp(-Δt/τ)` with `τ = robust_typical_dt(...) * steps(level)`, so a
level-1 step response settles (~63%) after about
`SMOOTH_TIME_CONSTANT_MIN_STEPS` typical frames and a level-10 one after
`SMOOTH_TIME_CONSTANT_MAX_STEPS` — expressed as a multiple of the data's own
cadence rather than an absolute number of seconds.

This has to be relative, not absolute: smoothing is deliberately tied to
`RoiChannelSeries.timestamps` (the acquisition clock, not wall-clock) so
that replaying the same file looks identically smooth no matter how fast
it's fed through (Playback's target_frequency, machine speed, etc) — see
`accumulate_roi_channel_sample!`, runtime.jl. But that acquisition clock's
*absolute* scale varies wildly between recordings — one real file here had
frame times of ~118 seconds each — so a fixed-seconds τ either barely
smooths a coarse recording (Δt ≫ τ, k ≈ 1 regardless of level) or
over-smooths a fine one. Scaling τ by the data's own recent typical spacing
keeps "level 10" meaning the same thing (averaging over
~`SMOOTH_TIME_CONSTANT_MAX_STEPS` frames) at any cadence.

Deliberately a wide ratio (100x) between the two ends: level 1 was
originally reported as noticeably over-smoothed even at its lightest
setting, so the low end needed real headroom near "barely more than a
single step," not just a uniform rescale. Tune directly if the plots feel
too twitchy/sluggish at either end of the slider.
"""
const SMOOTH_TIME_CONSTANT_MIN_STEPS = 1.0
const SMOOTH_TIME_CONSTANT_MAX_STEPS = 100.0

"""
    SMOOTH_TYPICAL_DT_WINDOW::Int

Number of recent inter-sample gaps `robust_typical_dt` averages over to
estimate this acquisition's characteristic frame spacing.
"""
const SMOOTH_TYPICAL_DT_WINDOW = 20

"""
    robust_typical_dt(timestamps::Vector{Float64}, idx::Int)::Float64

Typical recent inter-sample gap (trimmed-mean Δtimestamp over the last
`SMOOTH_TYPICAL_DT_WINDOW` samples ending at `idx`), excluding the single
largest gap so one genuine pause in acquisition doesn't skew the "typical
cadence" estimate that `plot_time_constant` scales τ by. Returns `NaN` if
there isn't at least one valid gap yet (e.g. idx <= 1).
"""
function robust_typical_dt(timestamps::Vector{Float64}, idx::Int)::Float64
    idx <= 1 && return NaN

    start_idx = max(2, idx - SMOOTH_TYPICAL_DT_WINDOW + 1)
    total = 0.0
    largest = 0.0
    n = 0

    for k in start_idx:idx
        t1 = timestamps[k]
        t0 = timestamps[k - 1]
        if isfinite(t1) && isfinite(t0)
            d = t1 - t0
            if d > 0.0
                total += d
                largest = max(largest, d)
                n += 1
            end
        end
    end

    n == 0 && return NaN

    trimmed_total = n >= 3 ? total - largest : total
    trimmed_n = n >= 3 ? n - 1 : n

    return trimmed_n > 0 ? trimmed_total / trimmed_n : NaN
end

"""
    plot_time_constant(level::Int, typical_dt::Float64)::Float64

Plot filter's EMA time constant at a given smoothing level: log-linear
(exponential) interpolation between `SMOOTH_TIME_CONSTANT_MIN_STEPS` (level
1) and `SMOOTH_TIME_CONSTANT_MAX_STEPS` (level 10) multiples of
`typical_dt` (see `robust_typical_dt`).
"""
@inline function plot_time_constant(level::Int, typical_dt::Float64)::Float64
    clamped_level = clamp(level, 1, 10)
    ratio = SMOOTH_TIME_CONSTANT_MAX_STEPS / SMOOTH_TIME_CONSTANT_MIN_STEPS
    steps = SMOOTH_TIME_CONSTANT_MIN_STEPS * ratio ^ ((clamped_level - 1) / 9)
    return typical_dt * steps
end

"""
    SMOOTH_JUMP_SIGMA::Float64

How many multiples of the recent (outlier-trimmed) typical step size an
innovation must exceed for `compute_lifetime_smooth_at` to treat it as a
genuine step change rather than noise — see `robust_step_scale`.
"""
const SMOOTH_JUMP_SIGMA = 4.0

"""
    SMOOTH_JUMP_CATCHUP::Float64

Fraction of a detected jump's gap `compute_lifetime_smooth_at` closes
immediately. Less than 1.0 so a confirmed step still reads as a fast
transition on the plot rather than a hard, single-sample discontinuity;
close to 1.0 so it doesn't itself look like sluggish smoothing.
"""
const SMOOTH_JUMP_CATCHUP = 0.7

"""
    SMOOTH_SCALE_WINDOW_STEPS::Float64

How many multiples of this acquisition's own typical frame spacing
(`robust_typical_dt`) `robust_step_scale` looks back to estimate the recent
"typical" step size used for jump detection (`SMOOTH_JUMP_SIGMA`).

This used to be a fixed *sample count* (`4 + 5*level`), then a fixed
*elapsed-time* span (2.0s) — both broke down the same way `τ` did (see
`SMOOTH_TIME_CONSTANT_MIN_STEPS`'s docstring): a fixed sample count covers
barely any real time at a fast acquisition rate (54 samples at 1000 Hz is
only ~54ms), so the "typical step" estimate was unstable and let ordinary
noise cross the jump threshold far too often; a fixed elapsed-time span has
the opposite problem at a *slow* acquisition rate (the ~118s/frame file
seen in testing), where 2.0s of history contains at most one sample, so the
`SMOOTH_SCALE_MIN_SAMPLES` floor always kicks in and the estimate is built
from a tiny, noisy sample regardless of how much real history exists.
Expressing the window as a multiple of the data's own cadence keeps the
estimate similarly stable (similar effective sample count) at any
acquisition timescale.
"""
const SMOOTH_SCALE_WINDOW_STEPS = 20.0

"""
    SMOOTH_SCALE_MIN_SAMPLES::Int / SMOOTH_SCALE_MAX_SAMPLES::Int

Sample-count floor/ceiling applied around `SMOOTH_SCALE_WINDOW_STEPS`'s
window in `robust_step_scale`. The floor guards against too few points when
`typical_dt` itself is poorly estimated (e.g. very early in a run). The
ceiling bounds the per-frame cost at a fast sample rate, since this runs on
the hot per-frame path (`append_smooth_value!`).
"""
const SMOOTH_SCALE_MIN_SAMPLES = 5
const SMOOTH_SCALE_MAX_SAMPLES = 200

"""
    robust_step_scale(values::Vector{Float64}, timestamps::Vector{Float64}, idx::Int, typical_dt::Float64)::Float64

Typical recent step size (mean |Δ| over the last
`SMOOTH_SCALE_WINDOW_STEPS * typical_dt` of history ending at `idx`,
bounded to `[SMOOTH_SCALE_MIN_SAMPLES, SMOOTH_SCALE_MAX_SAMPLES]` samples),
with the single largest step in that window excluded before averaging. That
trim matters: a plain mean (the old `local_scale`) lets one genuine jump
inflate the "typical noise" estimate for the next window, which then made
the *following* samples of that same transition look normal by comparison
and suppressed the old filter's catch-up boost — a fast partial snap
followed by a visible crawl to finish. Excluding the largest step keeps
this estimate representative of ordinary sample-to-sample noise even
immediately after a real jump.

Also the noise-floor building block for the cumulative multi-step test
(`cumulative_drift_window`/`compute_lifetime_smooth_at`): a sum of
`n` independent single-step noise terms has standard deviation
`scale * sqrt(n)`, so that test multiplies this same per-step scale by
`sqrt(n)` rather than maintaining a separate estimate.
"""
function robust_step_scale(values::Vector{Float64}, timestamps::Vector{Float64}, idx::Int, typical_dt::Float64)::Float64
    idx <= 1 && return 1.0e-6

    window_s = isfinite(typical_dt) && typical_dt > 0.0 ? typical_dt * SMOOTH_SCALE_WINDOW_STEPS : 0.0
    cutoff = timestamps[idx] - window_s
    total = 0.0
    largest = 0.0
    n = 0
    k = idx

    while k > 1 && n < SMOOTH_SCALE_MAX_SAMPLES && (n < SMOOTH_SCALE_MIN_SAMPLES || timestamps[k - 1] >= cutoff)
        v1 = values[k]
        v0 = values[k - 1]
        if isfinite(v1) && isfinite(v0)
            d = abs(v1 - v0)
            total += d
            largest = max(largest, d)
            n += 1
        end
        k -= 1
    end

    n == 0 && return 1.0e-6

    trimmed_total = n >= 3 ? total - largest : total
    trimmed_n = n >= 3 ? n - 1 : n

    return max(trimmed_n > 0 ? trimmed_total / trimmed_n : 1.0e-6, 1.0e-6)
end

"""
    SMOOTH_CUM_JUMP_SIGMA::Float64

Sigma multiplier for the cumulative multi-step jump test (see
`compute_lifetime_smooth_at`): triggers when the drift over the last
`n` samples (`cumulative_drift_window`) exceeds
`SMOOTH_CUM_JUMP_SIGMA * robust_step_scale(...) * sqrt(n)` — the expected
spread of `n` independent noise steps, by the same reasoning as
`SMOOTH_JUMP_SIGMA` for a single step.
"""
const SMOOTH_CUM_JUMP_SIGMA = 1.5

"""
    SMOOTH_CUM_WINDOW_STEPS::Float64

How many multiples of this acquisition's own typical frame spacing
(`robust_typical_dt`) the cumulative multi-step jump test looks back over.
"""
const SMOOTH_CUM_WINDOW_STEPS = 3.0

"""
    SMOOTH_CUM_MIN_SAMPLES::Int / SMOOTH_CUM_MAX_SAMPLES::Int

Sample-count floor/ceiling for `cumulative_drift_window`, same rationale as
`SMOOTH_SCALE_MIN_SAMPLES`/`SMOOTH_SCALE_MAX_SAMPLES`. The floor also acts
as the minimum span the cumulative test requires before it can fire at all
— below it, the single-step test (B) is the only one active.
"""
const SMOOTH_CUM_MIN_SAMPLES = 2
const SMOOTH_CUM_MAX_SAMPLES = 50

"""
    cumulative_drift_window(timestamps::Vector{Float64}, idx::Int, typical_dt::Float64)::Int

Number of samples back from `idx` the cumulative multi-step jump test spans
— out to `SMOOTH_CUM_WINDOW_STEPS * typical_dt` of acquisition time,
bounded to `[SMOOTH_CUM_MIN_SAMPLES, SMOOTH_CUM_MAX_SAMPLES]`. Returns 0 if
`idx <= 1` (nothing to span yet).
"""
function cumulative_drift_window(timestamps::Vector{Float64}, idx::Int, typical_dt::Float64)::Int
    idx <= 1 && return 0

    window_s = isfinite(typical_dt) && typical_dt > 0.0 ? typical_dt * SMOOTH_CUM_WINDOW_STEPS : 0.0
    cutoff = timestamps[idx] - window_s
    n = 0
    k = idx

    while k > 1 && n < SMOOTH_CUM_MAX_SAMPLES && (n < SMOOTH_CUM_MIN_SAMPLES || timestamps[k - 1] >= cutoff)
        n += 1
        k -= 1
    end

    return n
end

"""
    compute_lifetime_smooth_at(values, timestamps, idx, level, prev_smooth)::Float64

Plot-facing smoothing filter: a time-aware EMA (`plot_time_constant`) with
a hard snap on detected step changes. Two layers feed the same snap:

- **Single-step**: `|x - prev_smooth| > SMOOTH_JUMP_SIGMA * scale`, catching
  a jump that lands entirely within one sample.
- **Cumulative multi-step**: `|x - values[idx - n]| > SMOOTH_CUM_JUMP_SIGMA
  * scale * sqrt(n)` over the last `n` samples
  (`cumulative_drift_window`), catching a real rapid transition spread
  across several consecutive files where no single step individually
  crosses the single-step threshold — e.g. under ROI round-robin splitting,
  a fast underlying change gets divided into a handful of smaller steps,
  each sub-threshold on its own but consistent in direction. Comparing
  against `scale * sqrt(n)` (not `scale * n`) matters: that's the expected
  spread of `n` steps of pure *noise* (a random walk), which grows slower
  than `n` — so a real sustained drift eventually separates from noise as
  `n` grows, while noise alone stays contained.

Either layer snaps the same way: close most of the gap between
`prev_smooth` and the current value now (`SMOOTH_JUMP_CATCHUP`) instead of
leaking toward it over several samples. `values`/`timestamps` must be
index-aligned (the same convention `RoiChannelSeries` already keeps).
"""
function compute_lifetime_smooth_at(
            values::Vector{Float64},
            timestamps::Vector{Float64},
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

    # No previous point to smooth against (first sample), or no valid
    # elapsed time to base the gain on (missing/out-of-order timestamp).
    if !isfinite(prev_smooth) || idx <= 1 || idx > length(timestamps)
        return x
    end

    Δt = timestamps[idx] - timestamps[idx - 1]
    if !isfinite(Δt) || Δt <= 0.0
        return x
    end

    # This acquisition's own typical frame spacing — both the jump-detector's
    # window (property B) and the EMA's time constant (property A) are
    # expressed relative to it, so the filter behaves the same regardless of
    # whether frames are 20ms or 118s apart (see plot_time_constant's
    # docstring).
    typical_dt = robust_typical_dt(timestamps, idx)
    if !isfinite(typical_dt) || typical_dt <= 0.0
        typical_dt = Δt
    end

    scale = robust_step_scale(values, timestamps, idx, typical_dt)
    innovation = x - prev_smooth

    # B (single-step): a clearly-larger-than-usual step is a real change,
    # not noise — close most of the gap now instead of leaking toward it
    # over several samples.
    is_single_step_jump = abs(innovation) > SMOOTH_JUMP_SIGMA * scale

    # B (cumulative multi-step): several consecutive sub-threshold steps
    # that together add up to a rapid change — see this function's
    # docstring.
    is_cumulative_jump = false
    n_cum = cumulative_drift_window(timestamps, idx, typical_dt)
    if n_cum >= SMOOTH_CUM_MIN_SAMPLES
        base_idx = idx - n_cum
        base_value = values[base_idx]
        if isfinite(base_value)
            drift = x - base_value
            is_cumulative_jump = abs(drift) > SMOOTH_CUM_JUMP_SIGMA * scale * sqrt(n_cum)
        end
    end

    if is_single_step_jump || is_cumulative_jump
        return prev_smooth + SMOOTH_JUMP_CATCHUP * innovation
    end

    # A: baseline gain from elapsed (acquisition) time, scaled by typical_dt.
    τ = plot_time_constant(level, typical_dt)
    k = 1.0 - exp(-Δt / τ)

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
so the recomputed portion is numerically indistinguishable from a
full-history recompute by the time it reaches the visible window. Needs to
cover the jump-detector's own memory (`robust_step_scale`/
`cumulative_drift_window`, capped at `SMOOTH_SCALE_MAX_SAMPLES` = 200
samples) and several multiples of the EMA's settling time —
`plot_time_constant` now expresses τ as a multiple of this acquisition's
own typical frame spacing (up to `SMOOTH_TIME_CONSTANT_MAX_STEPS` = 100x at
level 10), so settling itself takes on the order of a few hundred samples
*regardless of the acquisition's absolute timescale* (unlike the old
fixed-seconds τ, this no longer needs to assume a fastest-supported sample
rate to convert seconds to samples). 10000 gives comfortable headroom above
that; this only runs once per smoothing-level UI change, not on the hot
per-frame path, so a generous margin costs nothing.
"""
const RECOMPUTE_LOOKBACK_MARGIN = 10_000

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
        y = compute_lifetime_smooth_at(source_values, timestamps_values, idx, level, prev)
        smoothed[idx] = y
        prev = y
    end

    target[] = smoothed
    return nothing
end

"""
    append_smooth_value!(app, source, target, timestamps)

Append one new smoothed point to `target`, from the just-appended raw value
at `source[end]`. `timestamps` must be index-aligned with `source` (same
convention as `RoiChannelSeries`) — the elapsed time since the previous
sample drives the filter's baseline gain (see `compute_lifetime_smooth_at`).
"""
function append_smooth_value!(app, source::Observable{Vector{Float64}}, target::Observable{Vector{Float64}}, timestamps::Observable{Vector{Float64}})
    idx = length(source[])
    if idx == 0
        return nothing
    end

    level = lifetime_smooth_level(app.layout)
    prev = isempty(target[]) ? NaN : target[][end]

    y = compute_lifetime_smooth_at(source[], timestamps[], idx, level, prev)
    push!(target[], y)

    return nothing
end

"""
    recompute_roi_channel_smooth!(app, series::RoiChannelSeries)

Recompute one ROI's smoothed photon-count, lifetime, and concentration
series (see `recompute_smooth_series!`) and notify their observables. Paces
against `series`' own `timestamps` (each ROI has its own, since it only
receives every Nth frame — see `RoiChannelSeries` in data_types.jl), the
acquisition clock, so the recomputed result matches whatever
`accumulate_roi_channel_sample!` already produced live. Used when the
smoothing level changes (handlers_layout.jl), looping every
`roi_channel_series(app_run)`.
"""
function recompute_roi_channel_smooth!(app, series::RoiChannelSeries)
    recompute_smooth_series!(app, series.photons, series.photons_smooth, series.timestamps)
    notify(series.photons_smooth)
    recompute_smooth_series!(app, series.lifetime, series.lifetime_smooth, series.timestamps)
    notify(series.lifetime_smooth)
    recompute_smooth_series!(app, series.concentration, series.concentration_smooth, series.timestamps)
    notify(series.concentration_smooth)
    return nothing
end
