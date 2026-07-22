"""
smoothing.jl

Shared lifetime smoothing: a constant-velocity (2-state) Kalman filter
(`kalman_update!`, operating on a `KalmanState`, data_types.jl) used both as
the plot-facing smoothing filter (`RoiChannelSeries`'s `_smooth` series,
runtime.jl) and as the PID observer (`ChannelFitState.pid_kalman`,
acquisition.jl) that replaced the PID's derivative term — see
`process_frame!`'s docstring for why. Independent `KalmanState`
instances in each case (per (channel, ROI, metric) for plots, per
(channel, metric) for the PID observer): same filter, not shared state.
"""

function lifetime_smooth_level(layout::LayoutSettings)::Int
    return clamp(layout.smoothing, 0, 10)
end

"""
    KALMAN_LEVEL_SPAN::Float64

Ratio, level 1 to level 10, of how much process noise `kalman_update!`
lets accumulate per typical inter-sample interval — level 10's `q` is
`1/KALMAN_LEVEL_SPAN` of level 1's. Deliberately *not* a generic 10x span:
a steady-state constant-velocity Kalman filter's position-noise reduction
scales only as the *fourth root* of `r/q` (a standard result for the CV
model — the coupled velocity state means shrinking `q` helps position
estimates much less per-decade than in a 1-state filter; confirmed here,
each 10x cut in `q` bought only ~1.7x more noise reduction). So level 10
being meaningfully stronger than level 1 needs `q` to range over several
*orders of magnitude*, not just one.
"""
const KALMAN_LEVEL_SPAN = 1.0e6

@inline function kalman_strength_factor(level::Int)::Float64
    clamped_level = clamp(level, 1, 10)
    return KALMAN_LEVEL_SPAN ^ ((clamped_level - 1) / 9)
end

"""
    KALMAN_BASE_Q_R_RATIO::Float64

Baseline ratio, at smoothing level 1, of the process-noise growth in
position variance over *one typical inter-sample interval*
(`state.typical_dt`, an EMA of observed `dt` — see `KalmanState`) to the
adaptively estimated measurement-noise variance `r_est^2`.
`kalman_update!` divides this by `kalman_strength_factor(level)`, so level
10 lets `KALMAN_LEVEL_SPAN`x less uncertainty accumulate per typical step
(heavier smoothing) than level 1.

Deliberately relative to `typical_dt`, not an absolute `q` — the process
noise a constant-velocity Kalman filter applies over an interval `dt`
scales as `dt^3` (`p11`'s term below), so a `q` calibrated for one
acquisition's cadence would wildly over- or under-smooth at another's: real
files here have had frame-to-frame gaps from ~20ms up to ~118s, a
`(118/0.02)^3` ≈ 2×10^11-fold difference in raw `dt^3`. Anchoring to
`typical_dt` keeps "level 10" meaning the same *relative* amount of
smoothing regardless of how fast frames actually arrive — this was missed
in the first pass at this filter and caused it to barely smooth anything
on real (large-`dt`) acquisitions despite behaving correctly in synthetic
testing at small, fixed `dt`.

Still has no data-driven anchor for its own value beyond that (unlike
`r_est`) — the right value depends on how fast the *real* lifetime
genuinely drifts on this hardware, which only testing against real
acquisitions can calibrate. Lowered 10^4x from an initial 1.0 (measured:
~9x more noise reduction at every level, the fourth-root relationship
described above means a clean 10x needs roughly a 10^4x cut here) after
real-acquisition testing found the initial value still under-smoothed.
"""
const KALMAN_BASE_Q_R_RATIO = 1.0e-1

"""
    kalman_update!(state::KalmanState, measurement::Float64, dt::Float64, level::Int)::Float64

Advance `state` (in place) by one constant-velocity Kalman filter step and
return the updated position estimate. `dt` is the elapsed time (in
whatever clock `state` is being driven by — acquisition time for plots,
`frame_time` for the PID observer, see call sites) since the last update.

- `level <= 0`: exact passthrough — `state` is re-armed at `measurement`
  (position, zero velocity, covariance seeded from the just-updated
  `r_est`) so raising the level later resumes from here instead of an
  arbitrarily stale prior estimate.
- No prior estimate yet (`state.pos` not finite), or `dt` invalid
  (non-finite or `<= 0`): (re)initialize the same way, since there's no
  valid prior state to predict from.
- Otherwise: predict from the constant-velocity model
  (`pos += vel*dt`), grow the covariance by the discrete white-noise-
  acceleration process noise (`q * [dt^3/3 dt^2/2; dt^2/2 dt]`, `q` derived
  from `KALMAN_BASE_Q_R_RATIO` relative to `state.typical_dt`, not `dt`
  itself — see that constant's docstring for why), then correct with
  `measurement` via the standard scalar-measurement Kalman gain.

`r_est`/`prev_raw` are updated unconditionally, even at level 0, so
`r_est` already reflects real data by the time a higher level is chosen —
mirrors the pre-Kalman heuristic's own `scale_est` behavior. `typical_dt`
is only updated in the main filtering branch below (it needs a valid `dt`,
which the other two branches don't have or don't trust).
"""
function kalman_update!(state::KalmanState, measurement::Float64, dt::Float64, level::Int)::Float64
    if !isfinite(measurement)
        return measurement
    end

    if !isfinite(state.prev_raw)
        state.prev_raw = measurement
    end
    delta_raw = abs(measurement - state.prev_raw)
    state.r_est = isfinite(state.r_est) ? max(0.90 * state.r_est + 0.10 * delta_raw, 1.0e-6) : max(delta_raw, 1.0e-6)
    state.prev_raw = measurement
    r = state.r_est^2

    if level <= 0
        state.pos = measurement
        state.vel = 0.0
        state.p11 = r
        state.p12 = 0.0
        state.p22 = r
        return measurement
    end

    if !isfinite(state.pos) || !isfinite(dt) || dt <= 0.0
        state.pos = measurement
        state.vel = 0.0
        state.p11 = r
        state.p12 = 0.0
        state.p22 = r
        return measurement
    end

    state.typical_dt = isfinite(state.typical_dt) ? 0.90 * state.typical_dt + 0.10 * dt : dt
    typical_dt = max(state.typical_dt, 1.0e-9)

    smooth_factor = kalman_strength_factor(level)
    q = 3.0 * r * KALMAN_BASE_Q_R_RATIO / (smooth_factor * typical_dt^3)

    # Predict: constant-velocity model, discrete white-noise-acceleration Q
    # over this step's actual dt (which can differ from typical_dt — a
    # genuinely longer-than-usual gap correctly grows the covariance more).
    pos_pred = state.pos + state.vel * dt
    vel_pred = state.vel
    p11_pred = state.p11 + 2.0 * dt * state.p12 + dt^2 * state.p22 + q * dt^3 / 3.0
    p12_pred = state.p12 + dt * state.p22 + q * dt^2 / 2.0
    p22_pred = state.p22 + q * dt

    # Update: scalar measurement of position only (H = [1 0]).
    innovation = measurement - pos_pred
    innovation_cov = p11_pred + r
    k1 = p11_pred / innovation_cov
    k2 = p12_pred / innovation_cov

    state.pos = pos_pred + k1 * innovation
    state.vel = vel_pred + k2 * innovation
    state.p11 = (1.0 - k1) * p11_pred
    state.p12 = (1.0 - k1) * p12_pred
    state.p22 = p22_pred - k2 * p12_pred

    return state.pos
end

# -----------------------------------------------------------------------------
# smoothed series helpers (used by consumer_loop / runtime.jl)
# -----------------------------------------------------------------------------
#
# Generic over which raw/smoothed observable pair (and KalmanState) they
# operate on, so lifetime/photons/ion concentration all go through the
# exact same filter (kalman_update!) with the exact same parameters — not
# separate copies that could drift apart.

"""
    RECOMPUTE_LOOKBACK_MARGIN::Int

Extra samples replayed before the visible window in `recompute_smooth_series!`,
so the recomputed portion is numerically indistinguishable from a
full-history recompute by the time it reaches the visible window — the
Kalman filter's covariance converges from its reinitialized state
(see that function's docstring) within a handful of samples, and this
margin is comfortably larger than that. Also bounds the O(N) cost of a
full-history rescan (measured elsewhere: comparable scans cost ~13ms at
500k samples); this only runs once per smoothing-level UI change, not on
the hot per-frame path, so a generous margin costs nothing.
"""
const RECOMPUTE_LOOKBACK_MARGIN = 500

function recompute_smooth_series!(app, source::Observable{Vector{Float64}}, target::Observable{Vector{Float64}}, timestamps::Observable{Vector{Float64}}, kalman::KalmanState)
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
    # real-time run. Unlike the autoscale window in plotting.jl this filter
    # is path-dependent (each output depends on the previous one), so it
    # can't simply be sliced — instead replay starts
    # `RECOMPUTE_LOOKBACK_MARGIN` samples before the visible window so the
    # filter has settled by the time it reaches on-screen data, while
    # everything before that keeps its previously-computed value (from the
    # old smoothing level) rather than being blanked to NaN — a stale but
    # still-plotted value if the user later widens time_range, not a gap.
    #
    # kalman's own state (velocity/covariance/r_est/typical_dt) is
    # reinitialized fresh at start_idx below, not replayed from any stored
    # history: it's level(q)-dependent machinery anyway (this whole recompute exists
    # *because* the level changed), so an old covariance computed under the
    # previous level's q wouldn't be meaningfully "more correct" to resume
    # from, and the lookback margin already exists to let it reconverge
    # before reaching visible data. Only `pos` (the position estimate
    # itself) is worth carrying over, since it's a real prior estimate of
    # the underlying value regardless of which q produced it.
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

    warm_start_pos = start_idx > 1 ? smoothed[start_idx - 1] : NaN
    kalman.pos = isfinite(warm_start_pos) ? warm_start_pos : NaN
    kalman.vel = 0.0
    kalman.p11 = NaN
    kalman.p12 = 0.0
    kalman.p22 = NaN
    kalman.r_est = NaN
    kalman.prev_raw = NaN
    kalman.typical_dt = NaN

    prev_t = start_idx > 1 ? timestamps_values[start_idx - 1] : NaN

    for idx in start_idx:n_common
        t = timestamps_values[idx]
        dt = isfinite(prev_t) ? t - prev_t : NaN
        y = kalman_update!(kalman, source_values[idx], dt, level)
        smoothed[idx] = y
        prev_t = t
    end

    target[] = smoothed
    return nothing
end

"""
    append_smooth_value!(app, source, target, timestamps, kalman)

Append one new smoothed point to `target`, from the just-appended raw value
at `source[end]`, advancing `kalman` (in place) by one step. `timestamps`
must be index-aligned with `source` (same convention as `RoiChannelSeries`)
— the elapsed time since the previous sample drives the filter's process
noise (see `kalman_update!`).
"""
function append_smooth_value!(app, source::Observable{Vector{Float64}}, target::Observable{Vector{Float64}}, timestamps::Observable{Vector{Float64}}, kalman::KalmanState)
    idx = length(source[])
    if idx == 0
        return nothing
    end

    level = lifetime_smooth_level(app.layout)
    ts = timestamps[]
    dt = (idx > 1 && idx <= length(ts)) ? ts[idx] - ts[idx - 1] : NaN

    y = kalman_update!(kalman, source[][idx], dt, level)
    push!(target[], y)

    return nothing
end

"""
    recompute_roi_smooth!(app, series::RoiChannelSeries)

Recompute one ROI's smoothed photon-count, lifetime, and concentration
series (see `recompute_smooth_series!`) and notify their observables. Uses
`series`' own `timestamps` (each ROI has its own, since it only receives
every Nth frame — see `RoiChannelSeries` in data_types.jl), not a shared
app-wide one. Used when the smoothing level changes (handlers_layout.jl),
looping every `roi_channel_series(app_run)`.
"""
function recompute_roi_smooth!(app, series::RoiChannelSeries)
    recompute_smooth_series!(app, series.photons, series.photons_smooth, series.timestamps, series.photons_kalman)
    notify(series.photons_smooth)
    recompute_smooth_series!(app, series.lifetime, series.lifetime_smooth, series.timestamps, series.lifetime_kalman)
    notify(series.lifetime_smooth)
    recompute_smooth_series!(app, series.concentration, series.concentration_smooth, series.timestamps, series.concentration_kalman)
    notify(series.concentration_smooth)
    return nothing
end
