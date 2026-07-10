"""
plotting.jl

Plot-axis autoscaling and plot-series lookup for the FLIM GUI: computing
axis limits from the current data window, mapping a plot-selection label to
its underlying observables, and the protocol-setpoint highlight overlay.
"""

using GLMakie
using Observables

# -----------------------------------------------------------------------------
# Histogram plot normalization
# -----------------------------------------------------------------------------
#
# On the Histogram plot, fit and IRF are each normalized to their own peak
# (max -> 1), so their shapes are comparable regardless of photon counts or
# IRF units. Counts use the SAME divisor as the fit (not their own max), so
# they stay on a scale comparable to the fit curve rather than also peaking
# at 1 — the whole point is showing how far the raw counts sit from the fit,
# which a self-normalized counts curve would hide.

# Normalize a curve to its own peak (max -> 1).
function normalize_to_own_max(y::AbstractVector{<:Real})
    out = zeros(Float64, length(y))
    isempty(y) && return out

    ymax = maximum(Float64.(y))
    if !isfinite(ymax) || ymax == 0.0
        return out
    end

    out .= Float64.(y) ./ ymax
    return out
end

# Normalize counts by the fit's peak, not counts' own peak.
function normalized_counts_for_histogram(counts::AbstractVector{<:Real}, fit::AbstractVector{<:Real})
    out = zeros(Float64, length(counts))
    isempty(fit) && return out

    fit_max = maximum(Float64.(fit))
    if !isfinite(fit_max) || fit_max == 0.0
        return out
    end

    out .= Float64.(counts) ./ fit_max
    return out
end

# IRF curve for the Histogram plot overlay, truncated/padded to `fit`'s
# length and normalized to its own peak (max -> 1).
function normalized_irf_from_fit(fit::AbstractVector{<:Real})
    nfit = length(fit)
    out = zeros(Float64, nfit)

    irf = RUNTIME[].irf
    if nfit == 0 || irf === nothing || size(irf, 2) < 2
        return out
    end

    irf_y = Float64.(irf[:, 2])
    if isempty(irf_y)
        return out
    end

    n = min(nfit, length(irf_y))
    out[1:n] .= normalize_to_own_max(irf_y[1:n])
    return out
end

"""
    draw_histogram_plot!(axis, app_run)

Draw the Histogram plot's three series onto `axis`: counts as semi
-transparent bars, fit and IRF as lines on top, all normalized (see the
functions above) so shapes are comparable regardless of photon counts or
IRF units. Shared by the Menu-selection handler (handlers_layout.jl) and
the initial-selection draw at GUI construction time (GUI.jl) — both need
the exact same rendering, so it lives here once instead of as two copies
that can drift out of sync.
"""
function draw_histogram_plot!(axis, app_run)
    counts_normalized = lift(normalized_counts_for_histogram, app_run.histogram, app_run.fit)
    fit_normalized = lift(normalize_to_own_max, app_run.fit)
    irf_normalized = lift(normalized_irf_from_fit, app_run.fit)

    barplot!(axis, app_run.hist_time, counts_normalized, color=(PLOT_COLOR_CH1, 0.25), gap=0.0)
    lines!(axis, app_run.hist_time, fit_normalized, color=PLOT_COLOR_CH1)
    lines!(axis, app_run.hist_time, irf_normalized, color=PLOT_COLOR_REF)

    return nothing
end

function protocol_setpoint_spans(
            timestamps::AbstractVector{<:Real},
            setpoints::AbstractVector{<:Real}
        )::Tuple{Vector{Float64}, Vector{Float64}}
    n = min(length(timestamps), length(setpoints))
    starts = Float64[]
    ends = Float64[]

    if n == 0
        return (starts, ends)
    end

    active_start = nothing

    for idx in 1:n
        t = Float64(timestamps[idx])
        sp = Float64(setpoints[idx])

        if !isfinite(t)
            continue
        end

        if isfinite(sp)
            if active_start === nothing
                active_start = t
            end
        elseif active_start !== nothing
            push!(starts, active_start)
            push!(ends, t)
            active_start = nothing
        end
    end

    if active_start !== nothing
        push!(starts, active_start)
        push!(ends, Float64(timestamps[n]))
    end

    return (starts, ends)
end

function add_protocol_setpoint_highlight!(ax, app_run)
    spans = lift(app_run.timestamps, app_run.protocol_setpoint) do ts, sp
        starts, ends = protocol_setpoint_spans(ts, sp)
        if isempty(starts)
            return ([NaN], [NaN])
        end
        return (starts, ends)
    end

    span_starts = lift(x -> x[1], spans)
    span_ends = lift(x -> x[2], spans)
    vspan!(ax, span_starts, span_ends, color = (PLOT_COLOR_REF, 0.05))

    return nothing
end

"""
    draw_lifetime_plot!(axis, app_run)

Draw the Lifetime plot's series onto `axis`: the protocol-setpoint
highlight, raw lifetime, smoothed lifetime, and the protocol setpoint
trace. Shared by the Menu-selection handler (handlers_layout.jl) and the
initial-selection draw at GUI construction time (GUI.jl) — see
`draw_histogram_plot!` above for why this needs to be one function, not two
copies.
"""
function draw_lifetime_plot!(axis, app_run)
    add_protocol_setpoint_highlight!(axis, app_run)

    lifetime_x, lifetime_y = aligned_xy_observables(app_run.timestamps, app_run.lifetime)
    smooth_x, smooth_y = aligned_xy_observables(app_run.timestamps, app_run.lifetime_smooth)
    protocol_x, protocol_y = aligned_xy_observables(app_run.timestamps, app_run.protocol_setpoint)

    lines!(axis, lifetime_x, lifetime_y, color=(PLOT_COLOR_CH1, 0.25))
    lines!(axis, smooth_x, smooth_y, color=PLOT_COLOR_CH1)
    lines!(axis, protocol_x, protocol_y, color=PLOT_COLOR_REF)

    return nothing
end

"""
    draw_ion_concentration_plot!(axis, app_run)

Draw the Ion concentration plot's series onto `axis`: raw concentration and
its smoothed trace, using the exact same smoothing (compute_lifetime_smooth_at,
see smoothing.jl) as the Lifetime plot. Shared by the Menu-selection handler
and the initial-selection draw for the same reason as `draw_lifetime_plot!`.
"""
function draw_ion_concentration_plot!(axis, app_run)
    concentration_x, concentration_y = aligned_xy_observables(app_run.timestamps, app_run.concentration)
    smooth_x, smooth_y = aligned_xy_observables(app_run.timestamps, app_run.concentration_smooth)

    lines!(axis, concentration_x, concentration_y, color=(PLOT_COLOR_CH1, 0.25))
    lines!(axis, smooth_x, smooth_y, color=PLOT_COLOR_CH1)

    return nothing
end

# -----------------------------------------------------------------------------
# axis autoscaling
# -----------------------------------------------------------------------------
#
# Called directly from consumer_loop (runtime.jl) on each published update,
# via autoscale_plot_selection! below — there is no separate autoscaler task.

"""
    autoscale_values!(ax)

Reset an axis to Makie's automatic limits (used for the Histogram plot).
"""
function autoscale_values!(ax)
    autolimits!(ax)
end

function autoscale_values!(app, ax, xs::AbstractVector; pad_ratio=0.05)
    if isempty(xs)
        return
    end

    valid = .!isnan.(xs)
    xs = xs[valid]
    if isempty(xs)
        return
    end

    time_range = app.layout.time_range
    xmin, xmax = minimum(xs), maximum(xs)

    if xmax < time_range
        xmax = time_range
    end

    if xmax - xmin > time_range
        xmin = xmax - time_range
    end

    if xmin == xmax
        xmin -= 0.5
        xmax += 0.5
    end

    xpad = (xmax - xmin) * pad_ratio

    xlims!(ax, xmin - xpad, xmax + xpad)
    ylims!(ax, 0.0, 100.0)
end

function autoscale_values!(app, ax, xs::AbstractVector, ys::AbstractVector; pad_ratio=0.05)
    if isempty(xs) || isempty(ys)
        return
    end
    time_range = app.layout.time_range

    # remove NaNs from the series
    valid = .!isnan.(ys)
    xs = xs[valid]
    ys = ys[valid]
    if isempty(xs)
        return
    end

    xmin, xmax = minimum(xs), maximum(xs)

    if xmax < time_range
        xmax = time_range
    end

    if xmax - xmin > time_range
        xmin = xmax - time_range
        # reroll y-range for new xmin boundary
        in_win = (xs .>= xmin) .& (xs .<= xmax)
        if any(in_win)
            ymin = minimum(ys[in_win])
        else
            ymin = minimum(ys)
        end
    end

    # compute y-range using only points inside the current x-window;
    # this will be updated again if we adjust the xmin limit below
    in_win = (xs .>= xmin) .& (xs .<= xmax)
    if any(in_win)
        ymin, ymax = minimum(ys[in_win]), maximum(ys[in_win])
    else
        ymin, ymax = minimum(ys), maximum(ys)
    end

    # avoid zero‑range
    if xmin == xmax
        xmin -= 0.5
        xmax += 0.5
    end
    if ymin == ymax
        ymin -= 0.5
        ymax += 0.5
    end

    xpad = (xmax - xmin) * pad_ratio
    ypad = (ymax - ymin) * pad_ratio

    xlims!(ax, xmin - xpad, xmax + xpad)
    ylims!(ax, ymin - ypad, ymax + ypad)
end

"""
    aligned_xy_observables(x_obs, y_obs)

Return a pair of lifted observables holding the common-length prefix of
`x_obs`/`y_obs`, so plotting code never sees mismatched-length series while
a background task is still appending to one of them.
"""
function aligned_xy_observables(x_obs::Observable{Vector{Float64}}, y_obs::Observable{Vector{Float64}})
    paired = lift(x_obs, y_obs) do xs, ys
        n = min(length(xs), length(ys))
        if n == 0
            return (Float64[], Float64[])
        end
        return (xs[1:n], ys[1:n])
    end
    return lift(v -> v[1], paired), lift(v -> v[2], paired)
end

"""
    windowed_slice(xs::AbstractVector{Float64}, ys::AbstractVector{Float64}, time_range::Real)

Return the common-length suffix of `xs`/`ys` covering the last `time_range`
seconds of `xs`.

`xs` here is always `app_run.timestamps[]`: a running total incremented by
each frame's duration (`run_acquisition_loop!` in acquisition.jl), so it is
non-decreasing for the lifetime of one acquisition run — that lets
`searchsortedfirst` locate the window boundary in O(log N) via binary
search instead of an O(N) scan. This matters because `lookup_plot_series`/
`autoscale_plot_selection!` run on every published update (up to 10 Hz) for
as long as an acquisition runs: without windowing first, they scanned and
`vcat`-copied the *entire* session history every call, which measured
~13 ms/call once a long real-time run had accumulated ~500k samples —
degrading the whole GUI over the course of a session even though only the
last `time_range` seconds are ever shown.
"""
function windowed_slice(xs::AbstractVector{Float64}, ys::AbstractVector{Float64}, time_range::Real)
    n = min(length(xs), length(ys))
    n == 0 && return (Float64[], Float64[])

    xs_n = view(xs, 1:n)
    ys_n = view(ys, 1:n)
    cutoff = xs_n[n] - Float64(time_range)
    start_idx = searchsortedfirst(xs_n, cutoff)

    return (xs_n[start_idx:n], ys_n[start_idx:n])
end

"""
    lookup_plot_series(app_run, plot_label, time_range)

Return x/y vectors for one plot label, restricted to the last `time_range`
seconds (see `windowed_slice`).
Labels supported: `Histogram`, `Photon counts`, `Lifetime`, `Ion concentration`, `Command`.
"""
function lookup_plot_series(app_run, plot_label, time_range)
    if plot_label == "Histogram"
        return (app_run.hist_time[], app_run.histogram[])
    end

    if plot_label == "Photon counts"
        return windowed_slice(app_run.timestamps[], app_run.photons[], time_range)
    end

    if plot_label == "Lifetime"
        ts_w, lifetime_w = windowed_slice(app_run.timestamps[], app_run.lifetime[], time_range)
        _, smooth_w = windowed_slice(app_run.timestamps[], app_run.lifetime_smooth[], time_range)
        _, setpoint_w = windowed_slice(app_run.timestamps[], app_run.protocol_setpoint[], time_range)
        return (vcat(ts_w, ts_w, ts_w), vcat(lifetime_w, smooth_w, setpoint_w))
    end

    if plot_label == "Ion concentration"
        ts_w, conc_w = windowed_slice(app_run.timestamps[], app_run.concentration[], time_range)
        _, smooth_w = windowed_slice(app_run.timestamps[], app_run.concentration_smooth[], time_range)
        return (vcat(ts_w, ts_w), vcat(conc_w, smooth_w))
    end

    if plot_label == "Command"
        ts_w, cmd1_w = windowed_slice(app_run.timestamps[], app_run.command1[], time_range)
        _, cmd2_w = windowed_slice(app_run.timestamps[], app_run.command2[], time_range)
        return (vcat(ts_w, ts_w), vcat(cmd1_w, cmd2_w))
    end

    return (Float64[], Float64[])
end

function notify_runtime_observables!(app_run)
    notify(app_run.photons)
    notify(app_run.lifetime)
    notify(app_run.lifetime_smooth)
    notify(app_run.protocol_setpoint)
    notify(app_run.concentration)
    notify(app_run.concentration_smooth)
    notify(app_run.command1)
    notify(app_run.command2)
    notify(app_run.timestamps)
    notify(app_run.i)
    return nothing
end

function autoscale_plot_selection!(app, app_run, axis, plot_label)
    if plot_label == "Histogram"
        autoscale_values!(axis)
        return nothing
    end

    xs, ys = lookup_plot_series(app_run, plot_label, app.layout.time_range)

    if plot_label == "Command"
        autoscale_values!(app, axis, xs)
    else
        autoscale_values!(app, axis, xs, ys)
    end

    return nothing
end
