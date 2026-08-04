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
function normalize_counts_to_fit(counts::AbstractVector{<:Real}, fit::AbstractVector{<:Real})
    out = zeros(Float64, length(counts))
    isempty(fit) && return out

    fit_max = maximum(Float64.(fit))
    if !isfinite(fit_max) || fit_max == 0.0
        return out
    end

    out .= Float64.(counts) ./ fit_max
    return out
end

"""
    shown_channel_series(app_run, show_ch1, show_ch2)

The standard "for each shown channel" iteration used by the ROI-split
draw_*_plot! functions below (Photon counts/Lifetime/Ion concentration):
`(roi_series_vector, color)` pairs for whichever of the two channels its
toggle currently shows (channel 1 in `PLOT_COLOR_CH1`, channel 2 in
`PLOT_COLOR_CH2`) — `roi_series_vector` is that channel's
`Vector{RoiChannelSeries}` (`app_run.ch1_rois`/`ch2_rois`), one entry per
drawn ROI (or a single entry when none are drawn).
"""
function shown_channel_series(app_run, show_ch1::Bool, show_ch2::Bool)
    pairs = Tuple{Vector{RoiChannelSeries}, typeof(PLOT_COLOR_CH1)}[]
    show_ch1 && push!(pairs, (app_run.ch1_rois, PLOT_COLOR_CH1))
    show_ch2 && push!(pairs, (app_run.ch2_rois, PLOT_COLOR_CH2))
    return pairs
end

"""
    shown_snapshot_series(app_run, show_ch1, show_ch2)

Like `shown_channel_series`, but for the Histogram plot's "latest frame"
snapshot (`ChannelSeries`, not ROI-split — see its docstring in
data_types.jl for why): `(series, color)` pairs for whichever of the two
channels its toggle currently shows.
"""
function shown_snapshot_series(app_run, show_ch1::Bool, show_ch2::Bool)
    pairs = Tuple{ChannelSeries, typeof(PLOT_COLOR_CH1)}[]
    show_ch1 && push!(pairs, (app_run.ch1, PLOT_COLOR_CH1))
    show_ch2 && push!(pairs, (app_run.ch2, PLOT_COLOR_CH2))
    return pairs
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
    draw_histogram_plot!(axis, app_run, show_ch1, show_ch2)

Draw the Histogram plot's series onto `axis`: each shown channel's counts
as semi-transparent bars plus its fit as a line on top (channel 1 in
`PLOT_COLOR_CH1`, channel 2 in `PLOT_COLOR_CH2`), all normalized (see the
functions above) so shapes are comparable regardless of photon counts. IRF
is drawn once regardless of the toggles — one instrument response, not
per-channel. Shared by the Menu-selection handler (handlers_layout.jl) and
the initial-selection draw at GUI construction time (GUI.jl) via
`render_plot!` — both need the exact same rendering, so it lives
here once instead of as two copies that can drift out of sync.
"""
function draw_histogram_plot!(axis, app_run, show_ch1::Bool, show_ch2::Bool)
    for (series, color) in shown_snapshot_series(app_run, show_ch1, show_ch2)
        counts_normalized = lift(normalize_counts_to_fit, series.histogram, series.fit)
        fit_normalized = lift(normalize_to_own_max, series.fit)
        barplot!(axis, app_run.hist_time, counts_normalized, color=(color, 0.1), gap=0.0)
        lines!(axis, app_run.hist_time, fit_normalized, color=color, linewidth=PLOT_LINEWIDTH)
    end

    irf_normalized = lift(normalized_irf_from_fit, app_run.ch1.fit)
    lines!(axis, app_run.hist_time, irf_normalized, color=PLOT_COLOR_REF, linewidth=PLOT_LINEWIDTH)

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

function add_setpoint_highlight!(ax, app_run)
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
    draw_lifetime_plot!(axis, app, app_run, show_ch1, show_ch2)

Draw the Lifetime plot's series onto `axis`: the protocol-setpoint
highlight and trace (channel-agnostic — it's the PID target, not measured
data, so it's drawn regardless of the toggles), plus each shown channel's
raw/smoothed lifetime, one line pair per ROI (`app_run.rois`) — all of one
channel's ROI lines share that channel's color (channel 1
`PLOT_COLOR_CH1`, channel 2 `PLOT_COLOR_CH2`), superimposed with no legend,
so a single-ROI (or no-ROI) run looks exactly as it did before this
existed. Shared by the Menu-selection handler (handlers_layout.jl) and the
initial-selection draw at GUI construction time (GUI.jl) via
`render_plot!` — see `draw_histogram_plot!` above for why this
needs to be one function, not two copies.
"""
function draw_lifetime_plot!(axis, app, app_run, show_ch1::Bool, show_ch2::Bool)
    add_setpoint_highlight!(axis, app_run)
    protocol_x, protocol_y = plot_xy_observables(app, app_run, app_run.timestamps, app_run.protocol_setpoint)
    lines!(axis, protocol_x, protocol_y, color=PLOT_COLOR_REF, linewidth=PLOT_LINEWIDTH)

    for (roi_series, color) in shown_channel_series(app_run, show_ch1, show_ch2)
        for series in roi_series
            raw_x, raw_y = plot_xy_observables(app, app_run, series.timestamps, series.lifetime)
            smooth_x, smooth_y = plot_xy_observables(app, app_run, series.timestamps, series.lifetime_smooth)
            lines!(axis, raw_x, raw_y, color=(color, 0.25), linewidth=PLOT_LINEWIDTH)
            lines!(axis, smooth_x, smooth_y, color=color, linewidth=PLOT_LINEWIDTH)
        end
    end

    return nothing
end

"""
    draw_ion_concentration_plot!(axis, app, app_run, show_ch1, show_ch2)

Draw the Ion concentration plot's series onto `axis`: each shown channel's
raw concentration and its smoothed trace, one line pair per ROI — same
per-ROI superimposed-same-color-no-legend treatment as
`draw_lifetime_plot!` (see its docstring), using the exact same smoothing
(kalman_update!, see smoothing.jl). Shared by the Menu-selection
handler and the initial-selection draw for the same reason as
`draw_lifetime_plot!`.
"""
function draw_ion_concentration_plot!(axis, app, app_run, show_ch1::Bool, show_ch2::Bool)
    add_setpoint_highlight!(axis, app_run)

    for (roi_series, color) in shown_channel_series(app_run, show_ch1, show_ch2)
        for series in roi_series
            raw_x, raw_y = plot_xy_observables(app, app_run, series.timestamps, series.concentration)
            smooth_x, smooth_y = plot_xy_observables(app, app_run, series.timestamps, series.concentration_smooth)
            lines!(axis, raw_x, raw_y, color=(color, 0.25), linewidth=PLOT_LINEWIDTH)
            lines!(axis, smooth_x, smooth_y, color=color, linewidth=PLOT_LINEWIDTH)
        end
    end

    return nothing
end

"""
    draw_photon_counts_plot!(axis, app, app_run, show_ch1, show_ch2)

Draw the Photon counts plot's series onto `axis`: each shown channel's raw
photon-count trace and its smoothed trace, one line pair per ROI — same
per-ROI superimposed-same-color-no-legend treatment as
`draw_lifetime_plot!` (see its docstring), using the exact same smoothing
(kalman_update!, see smoothing.jl). Shared by the Menu-selection
handler and the initial-selection draw for the same reason as
`draw_lifetime_plot!`.
"""
function draw_photon_counts_plot!(axis, app, app_run, show_ch1::Bool, show_ch2::Bool)
    add_setpoint_highlight!(axis, app_run)

    for (roi_series, color) in shown_channel_series(app_run, show_ch1, show_ch2)
        for series in roi_series
            raw_x, raw_y = plot_xy_observables(app, app_run, series.timestamps, series.photons)
            smooth_x, smooth_y = plot_xy_observables(app, app_run, series.timestamps, series.photons_smooth)
            lines!(axis, raw_x, raw_y, color=(color, 0.25), linewidth=PLOT_LINEWIDTH)
            lines!(axis, smooth_x, smooth_y, color=color, linewidth=PLOT_LINEWIDTH)
        end
    end

    return nothing
end

"""
    render_plot!(app, app_run, blocks, plot_slot::Symbol)

Render whichever series `app.layout.plot1`/`.plot2` currently selects onto
`plot_slot`'s axis (`:plot1` or `:plot2`), gated by that slot's own
`plot1_ch1`/`plot1_ch2`/`plot2_ch1`/`plot2_ch2` toggles. This is the single
place that knows how to render a plot slot — the Menu `on(selection)`
handler and the channel-toggle `on(active)` handler (both in
handlers_layout.jl) and the initial render at GUI construction time
(GUI.jl's `draw_initial_plots!`) all call this instead of each
keeping its own copy, for the same reason `draw_histogram_plot!` etc. are
shared functions above.
"""
function render_plot!(app, app_run, blocks, plot_slot::Symbol)
    if plot_slot == :plot1
        axis = blocks.plot_1_axis
        selection = app.layout.plot1
        show_ch1 = app.layout.plot1_ch1
        show_ch2 = app.layout.plot1_ch2
        axis.title[] = "Plot 1\n($(selection))"
    else
        axis = blocks.plot_2_axis
        selection = app.layout.plot2
        show_ch1 = app.layout.plot2_ch1
        show_ch2 = app.layout.plot2_ch2
        axis.title[] = "Plot 2\n($(selection))"
    end

    empty!(axis)

    if selection == "Command"
        add_setpoint_highlight!(axis, app_run)

        cmd1_x, cmd1_y = plot_xy_observables(app, app_run, app_run.timestamps, app_run.command1)
        cmd2_x, cmd2_y = plot_xy_observables(app, app_run, app_run.timestamps, app_run.command2)
        lines!(axis, cmd1_x, cmd1_y, color=PLOT_COLOR_CH1, linewidth=PLOT_LINEWIDTH)
        lines!(axis, cmd2_x, cmd2_y, color=PLOT_COLOR_CH2, linewidth=PLOT_LINEWIDTH)
    elseif selection == "Lifetime"
        draw_lifetime_plot!(axis, app, app_run, show_ch1, show_ch2)
    elseif selection == "Histogram"
        draw_histogram_plot!(axis, app_run, show_ch1, show_ch2)
    elseif selection == "Ion concentration"
        draw_ion_concentration_plot!(axis, app, app_run, show_ch1, show_ch2)
    elseif selection == "Photon counts"
        draw_photon_counts_plot!(axis, app, app_run, show_ch1, show_ch2)
    end

    if !app_run.running[]
        autolimits!(axis)
        lim = axis.finallimits[]
        xmax = lim.origin[1] + lim.widths[1]
        xlims!(axis, 0.0, max(Float64(xmax), 0.0))
    else
        # Running (including paused): pin the axis to the rolling window now,
        # via the same function consumer_loop calls on every publish tick. The
        # drawn lines are already clipped to the last time_range seconds
        # (plot_xy_observables), but the axis *limits* still need setting so a
        # mid-run plot-type switch shows that window immediately rather than
        # whatever autolimits makes of the just-drawn data. While running this
        # self-heals within one publish tick (~100ms); while paused,
        # consumer_loop is blocked and nothing else would ever re-pin it.
        autoscale_plot!(app, app_run, axis, selection, show_ch1, show_ch2)
    end

    return nothing
end

# -----------------------------------------------------------------------------
# axis autoscaling
# -----------------------------------------------------------------------------
#
# Called directly from consumer_loop (runtime.jl) on each published update,
# via autoscale_plot! below — there is no separate autoscaler task.

"""
    autoscale_values!(ax)

Reset an axis to Makie's automatic limits (used for the Histogram plot).
"""
function autoscale_values!(ax)
    autolimits!(ax)
    ylims!(ax, -0.05, 1.25)
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
    plot_xy_observables(app, app_run, x_obs, y_obs)

Pair of lifted observables feeding one plotted line. Always trims to the
common-length prefix of `x_obs`/`y_obs` (so plotting never sees a
mismatched-length series while a task is mid-append). While an acquisition
is running it further clips to the last `time_range` seconds
(`windowed_slice`), so per-frame render/allocation cost stays bounded no
matter how long the session runs instead of growing with the full history;
when stopped it returns the whole series, so the final view shows the entire
run (matching `render_plot!`'s full-history autolimits on stop).
"""
function plot_xy_observables(app, app_run, x_obs::Observable{Vector{Float64}}, y_obs::Observable{Vector{Float64}})
    paired = lift(x_obs, y_obs) do xs, ys
        n = min(length(xs), length(ys))
        n == 0 && return (Float64[], Float64[])
        if app_run.running[]
            return windowed_slice(xs, ys, app.layout.time_range)
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
`autoscale_plot!` run on every published update (up to 10 Hz) for
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
    accumulate_windowed!(xs_acc, ys_acc, timestamps, values, time_range)

Append `windowed_slice(timestamps, values, time_range)` onto `xs_acc`/
`ys_acc` in place. Small helper for `lookup_plot_series` below, so
gating a series on `show_ch1`/`show_ch2` is a one-line `show_chN && ...`
instead of a branch per plot label.
"""
function accumulate_windowed!(xs_acc::Vector{Float64}, ys_acc::Vector{Float64}, timestamps::AbstractVector{Float64}, values::AbstractVector{Float64}, time_range)
    ts_w, val_w = windowed_slice(timestamps, values, time_range)
    append!(xs_acc, ts_w)
    append!(ys_acc, val_w)
    return nothing
end

"""
    lookup_plot_series(app_run, plot_label, time_range, show_ch1, show_ch2)

Return x/y vectors for one plot label, restricted to the last `time_range`
seconds (see `windowed_slice`) and to whichever channel(s)/ROIs are shown
(each ROI's own `timestamps`, per `RoiChannelSeries`, is used to window its
own series — they aren't aligned to a single shared x-axis any more).
Labels supported: `Histogram`, `Photon counts`, `Lifetime`, `Ion concentration`, `Command`.
`Histogram` and `Command` ignore `show_ch1`/`show_ch2` — Histogram returns
the raw (un-windowed) channel-1 series regardless (autoscaling only, not
used for drawing), and Command always shows both controller outputs (see
`RoiChannelSeries`'s docstring in data_types.jl for why Command isn't
ROI-split like the other three: it drives real hardware output, not just
this plot).
"""
function lookup_plot_series(app_run, plot_label, time_range, show_ch1::Bool, show_ch2::Bool)
    if plot_label == "Histogram"
        return (app_run.hist_time[], app_run.ch1.histogram[])
    end

    xs = Float64[]
    ys = Float64[]
    shown = shown_channel_series(app_run, show_ch1, show_ch2)

    if plot_label == "Photon counts"
        for (roi_series, _) in shown, series in roi_series
            ts = series.timestamps[]
            accumulate_windowed!(xs, ys, ts, series.photons[], time_range)
            accumulate_windowed!(xs, ys, ts, series.photons_smooth[], time_range)
        end
        return (xs, ys)
    end

    if plot_label == "Lifetime"
        for (roi_series, _) in shown, series in roi_series
            ts = series.timestamps[]
            accumulate_windowed!(xs, ys, ts, series.lifetime[], time_range)
            accumulate_windowed!(xs, ys, ts, series.lifetime_smooth[], time_range)
        end
        accumulate_windowed!(xs, ys, app_run.timestamps[], app_run.protocol_setpoint[], time_range)
        return (xs, ys)
    end

    if plot_label == "Ion concentration"
        for (roi_series, _) in shown, series in roi_series
            ts = series.timestamps[]
            accumulate_windowed!(xs, ys, ts, series.concentration[], time_range)
            accumulate_windowed!(xs, ys, ts, series.concentration_smooth[], time_range)
        end
        return (xs, ys)
    end

    if plot_label == "Command"
        ts = app_run.timestamps[]
        accumulate_windowed!(xs, ys, ts, app_run.command1[], time_range)
        accumulate_windowed!(xs, ys, ts, app_run.command2[], time_range)
        return (xs, ys)
    end

    return (Float64[], Float64[])
end

"""
    notify_channel_series!(series::ChannelSeries)

Notify one channel's "latest frame" snapshot observables (histogram/fit/counts).
"""
function notify_channel_series!(series::ChannelSeries)
    notify(series.histogram)
    notify(series.fit)
    notify(series.counts)
    return nothing
end

"""
    notify_roi_series!(series::RoiChannelSeries)

Notify one ROI's per-channel time-series observables (timestamps, photons,
lifetime, concentration, and their smoothed counterparts).
"""
function notify_roi_series!(series::RoiChannelSeries)
    notify(series.timestamps)
    notify(series.photons)
    notify(series.photons_smooth)
    notify(series.lifetime)
    notify(series.lifetime_smooth)
    notify(series.concentration)
    notify(series.concentration_smooth)
    return nothing
end

function notify_runtime_observables!(app_run)
    foreach(notify_roi_series!, roi_channel_series(app_run))
    notify(app_run.protocol_setpoint)
    notify(app_run.command1)
    notify(app_run.command2)
    notify(app_run.timestamps)
    notify(app_run.i)
    return nothing
end

function autoscale_plot!(app, app_run, axis, plot_label, show_ch1::Bool, show_ch2::Bool)
    if plot_label == "Histogram"
        autoscale_values!(axis)
        return nothing
    end

    xs, ys = lookup_plot_series(app_run, plot_label, app.layout.time_range, show_ch1, show_ch2)

    if plot_label == "Command"
        autoscale_values!(app, axis, xs)
    else
        autoscale_values!(app, axis, xs, ys)
    end

    return nothing
end
