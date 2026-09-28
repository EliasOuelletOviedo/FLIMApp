"""
plotting.jl

Plot rendering for the FLIM GUI (main thread only). `render_plot!` creates a
plot slot's curves once, each bound to the history it shows (`SeriesLine`,
gui/app_run.jl); the refresh tick (gui/refresh.jl) then refills those
curves' point buffers in place — windowed to the time range and decimated
to `max_points_per_line` — with one `notify` per curve per tick, and
rescales the axes at most once per `autoscale_interval_s`. No plot object
is created or deleted outside `render_plot!` (a plot-type or channel-toggle
change).
"""

using GLMakie
using Observables

const PLOT_OPTIONS = ["Histogram", "Photon counts", "Lifetime", "Ion concentration", "Command", "Readback"]

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

`(roi_series_vector, color)` pairs for whichever of the two channels its
toggle currently shows (channel 1 in `PLOT_COLOR_CH1`, channel 2 in
`PLOT_COLOR_CH2`) — `roi_series_vector` is that channel's
`Vector{RoiChannelSeries}`, one entry per drawn ROI (or a single entry
when results aren't split per ROI).
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
snapshot (`ChannelSeries`, not ROI-split).
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

# -----------------------------------------------------------------------------
# Windowing and bound curves
# -----------------------------------------------------------------------------

"""
    windowed_slice(xs::AbstractVector{Float64}, ys::AbstractVector{Float64}, time_range::Real)

Return the common-length suffix of `xs`/`ys` covering the last `time_range`
seconds of `xs`. `xs` is non-decreasing (running frame timestamps), so the
window boundary is found by binary search.
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
    fill_points!(points, xs, ys, window_s, max_points)

Refill `points` in place from the common-length prefix of `xs`/`ys`:
only the last `window_s` seconds (all of it if `window_s` is `Inf`), at
most `max_points` points (evenly decimated, last point always kept).
"""
function fill_points!(points::Vector{Point2f}, xs::AbstractVector{Float64}, ys::AbstractVector{Float64}, window_s::Float64, max_points::Int)
    n = min(length(xs), length(ys))
    if n == 0
        empty!(points)
        return points
    end

    start = isfinite(window_s) ? searchsortedfirst(view(xs, 1:n), xs[n] - window_s) : 1
    count = n - start + 1
    stride = max(1, cld(count, max_points))
    m = cld(count, stride)
    last_included = start + (m - 1) * stride == n
    resize!(points, last_included ? m : m + 1)

    j = 0
    @inbounds for i in start:stride:n
        j += 1
        points[j] = Point2f(xs[i], ys[i])
    end
    last_included || (points[end] = Point2f(xs[n], ys[n]))
    return points
end

"""
    series_line!(axis, plot, xs, ys; kwargs...)

Draw one curve bound to the history `xs`/`ys` and register it in `plot`, so
the refresh tick keeps it current.
"""
function series_line!(axis, plot::PlotSlot, xs::Vector{Float64}, ys::Vector{Float64}; kwargs...)
    points = Observable(Point2f[])
    lines!(axis, points; kwargs...)
    push!(plot.series_lines, SeriesLine(points, xs, ys))
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

function add_setpoint_highlight!(ax, plot::PlotSlot)
    spans = SetpointSpans(Observable([NaN]), Observable([NaN]))
    vspan!(ax, spans.starts, spans.ends, color = (PLOT_COLOR_REF, 0.05))
    plot.spans = spans
    return nothing
end

# -----------------------------------------------------------------------------
# Plot types
# -----------------------------------------------------------------------------

"""
    draw_histogram_plot!(axis, app_run, show_ch1, show_ch2)

Each shown channel's counts as semi-transparent bars plus its fit as a line
on top, all normalized (see above) so shapes are comparable regardless of
photon counts; the IRF drawn once regardless of the toggles. Driven by the
fixed-size `ChannelSeries` Observables the refresh tick overwrites.
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

"""
    draw_roi_metric_plot!(axis, plot, app_run, raw_field, smooth_field, show_ch1, show_ch2)

Photon counts / Lifetime / Ion concentration: each shown channel's raw
(faint) and smoothed trace, one pair per ROI, all of one channel's ROIs in
that channel's color, superimposed with no legend.
"""
function draw_roi_metric_plot!(axis, plot::PlotSlot, app_run, raw_field::Symbol, smooth_field::Symbol, show_ch1::Bool, show_ch2::Bool)
    for (roi_series, color) in shown_channel_series(app_run, show_ch1, show_ch2)
        for series in roi_series
            series_line!(axis, plot, series.timestamps, getfield(series, raw_field); color=(color, 0.25), linewidth=PLOT_LINEWIDTH)
            series_line!(axis, plot, series.timestamps, getfield(series, smooth_field); color=color, linewidth=PLOT_LINEWIDTH)
        end
    end
    return nothing
end

"""
    draw_readback_plot!(axis, plot, app_run)

The last slot the DAQ loop played, as read back by the cards: one line per
readback signal (config/bench.toml), time from the start of the slot.
"""
function draw_readback_plot!(axis, plot::PlotSlot, app_run)
    signals = app_run.config.readback_signals
    colors = Makie.wong_colors()
    for (c, name) in enumerate(signals)
        points = Observable(Point2f[])
        lines!(axis, points; color=colors[mod1(c, length(colors))], linewidth=PLOT_LINEWIDTH, label=name)
        push!(plot.readback_lines, ReadbackLine(points, c))
    end
    plot.legend = axislegend(axis; position=:rt, nbanks=2, labelsize=9, framevisible=false, patchsize=(10, 5), rowgap=0)
    return nothing
end

"""
    render_plot!(app, app_run, blocks, plot_slot::Symbol; selection=nothing, show_channels=nothing)

Render whichever series `app.layout.plot1`/`.plot2` currently selects onto
`plot_slot`'s axis (`:plot1` or `:plot2`), gated by that slot's own channel
toggles: clears the axis, creates its curves once with their bindings, fills
them right away and sets the axis limits. The single place that knows how
to render a plot slot — the Menu and toggle handlers (handlers_layout.jl),
the initial draw (GUI.jl) and START/CLEAR (runtime.jl/handlers.jl, after
the histories are replaced) all call this. `selection`/`show_channels`
override the layout settings without changing them (GUI warm-up, app.jl).
"""
function render_plot!(app, app_run, blocks, plot_slot::Symbol;
                      selection::Union{Nothing, AbstractString} = nothing,
                      show_channels::Union{Nothing, Tuple{Bool, Bool}} = nothing)
    if plot_slot == :plot1
        axis = blocks.plot_1_axis
        selection = something(selection, app.layout.plot1)
        show_ch1, show_ch2 = something(show_channels, (app.layout.plot1_ch1, app.layout.plot1_ch2))
        axis.title[] = "Plot 1\n($(selection))"
    else
        axis = blocks.plot_2_axis
        selection = something(selection, app.layout.plot2)
        show_ch1, show_ch2 = something(show_channels, (app.layout.plot2_ch1, app.layout.plot2_ch2))
        axis.title[] = "Plot 2\n($(selection))"
    end

    previous = get(app_run.display.plots, plot_slot, nothing)
    previous !== nothing && previous.legend !== nothing && delete!(previous.legend)
    empty!(axis)
    plot = PlotSlot()
    plot.selection = selection
    app_run.display.plots[plot_slot] = plot

    if selection == "Command"
        add_setpoint_highlight!(axis, plot)
        series_line!(axis, plot, app_run.timestamps, app_run.command1; color=PLOT_COLOR_CH1, linewidth=PLOT_LINEWIDTH)
        series_line!(axis, plot, app_run.timestamps, app_run.command2; color=PLOT_COLOR_CH2, linewidth=PLOT_LINEWIDTH)
    elseif selection == "Lifetime"
        add_setpoint_highlight!(axis, plot)
        # The protocol setpoint is the PID target, not measured data: drawn
        # regardless of the channel toggles.
        series_line!(axis, plot, app_run.timestamps, app_run.protocol_setpoint; color=PLOT_COLOR_REF, linewidth=PLOT_LINEWIDTH)
        draw_roi_metric_plot!(axis, plot, app_run, :lifetime, :lifetime_smooth, show_ch1, show_ch2)
    elseif selection == "Histogram"
        draw_histogram_plot!(axis, app_run, show_ch1, show_ch2)
    elseif selection == "Ion concentration"
        add_setpoint_highlight!(axis, plot)
        draw_roi_metric_plot!(axis, plot, app_run, :concentration, :concentration_smooth, show_ch1, show_ch2)
    elseif selection == "Photon counts"
        add_setpoint_highlight!(axis, plot)
        draw_roi_metric_plot!(axis, plot, app_run, :photons, :photons_smooth, show_ch1, show_ch2)
    elseif selection == "Readback"
        draw_readback_plot!(axis, plot, app_run)
    end

    refresh_plot_slot!(app, app_run, plot)
    autoscale_plot_slot!(app, app_run, axis, plot, show_ch1, show_ch2)
    return nothing
end

"""
    refresh_plot_slot!(app, app_run, plot)

Refill every curve of `plot` from its history (refresh tick and
`render_plot!`): the last `time_range` seconds while running, the whole run
once stopped.
"""
function refresh_plot_slot!(app, app_run, plot::PlotSlot)
    window_s = app_run.running[] ? Float64(app.layout.time_range) : Inf
    max_points = app_run.config.max_points_per_line

    for line in plot.series_lines
        fill_points!(line.points[], line.xs, line.ys, window_s, max_points)
        notify(line.points)
    end

    if plot.spans !== nothing
        n = min(length(app_run.timestamps), length(app_run.protocol_setpoint))
        start = isfinite(window_s) && n > 0 ? searchsortedfirst(view(app_run.timestamps, 1:n), app_run.timestamps[n] - window_s) : 1
        starts, ends = protocol_setpoint_spans(view(app_run.timestamps, start:n), view(app_run.protocol_setpoint, start:n))
        if isempty(starts)
            starts, ends = [NaN], [NaN]
        end
        plot.spans.starts.val = starts
        plot.spans.ends[] = ends   # one notify: vspan reads both
    end

    if !isempty(plot.readback_lines)
        state = app_run.display
        for line in plot.readback_lines
            points = line.points[]
            n = line.signal <= size(state.readback_data, 1) ? state.readback_points : 0
            resize!(points, n)
            @inbounds for j in 1:n
                points[j] = Point2f((j - 1) * state.readback_dt_s, state.readback_data[line.signal, j])
            end
            notify(line.points)
        end
    end

    return nothing
end

# -----------------------------------------------------------------------------
# axis autoscaling (at most once per autoscale_interval_s, see refresh.jl)
# -----------------------------------------------------------------------------

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
    end

    # compute y-range using only points inside the current x-window
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
    accumulate_windowed!(xs_acc, ys_acc, timestamps, values, time_range)

Append `windowed_slice(timestamps, values, time_range)` onto `xs_acc`/`ys_acc`.
"""
function accumulate_windowed!(xs_acc::Vector{Float64}, ys_acc::Vector{Float64}, timestamps::AbstractVector{Float64}, values::AbstractVector{Float64}, time_range)
    ts_w, val_w = windowed_slice(timestamps, values, time_range)
    append!(xs_acc, ts_w)
    append!(ys_acc, val_w)
    return nothing
end

"""
    lookup_plot_series(app_run, plot_label, time_range, show_ch1, show_ch2)

x/y values one plot label shows over the last `time_range` seconds, for
autoscaling: whichever channel(s)/ROIs are shown (each ROI windowed on its
own timestamps). `Command` ignores the channel toggles (it always shows
both controller outputs).
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
            accumulate_windowed!(xs, ys, series.timestamps, series.photons, time_range)
            accumulate_windowed!(xs, ys, series.timestamps, series.photons_smooth, time_range)
        end
    elseif plot_label == "Lifetime"
        for (roi_series, _) in shown, series in roi_series
            accumulate_windowed!(xs, ys, series.timestamps, series.lifetime, time_range)
            accumulate_windowed!(xs, ys, series.timestamps, series.lifetime_smooth, time_range)
        end
        accumulate_windowed!(xs, ys, app_run.timestamps, app_run.protocol_setpoint, time_range)
    elseif plot_label == "Ion concentration"
        for (roi_series, _) in shown, series in roi_series
            accumulate_windowed!(xs, ys, series.timestamps, series.concentration, time_range)
            accumulate_windowed!(xs, ys, series.timestamps, series.concentration_smooth, time_range)
        end
    elseif plot_label == "Command"
        accumulate_windowed!(xs, ys, app_run.timestamps, app_run.command1, time_range)
        accumulate_windowed!(xs, ys, app_run.timestamps, app_run.command2, time_range)
    end

    return (xs, ys)
end

"""
    autoscale_plot_slot!(app, app_run, axis, plot, show_ch1, show_ch2)

Set `axis`'s limits for what `plot` shows: the rolling `time_range` window
while running, the whole run once stopped.
"""
function autoscale_plot_slot!(app, app_run, axis, plot::PlotSlot, show_ch1::Bool, show_ch2::Bool)
    label = plot.selection

    if label == "Histogram"
        autoscale_values!(axis)
    elseif label == "Readback"
        autolimits!(axis)
    elseif !app_run.running[]
        autolimits!(axis)
        lim = axis.finallimits[]
        xmax = lim.origin[1] + lim.widths[1]
        xlims!(axis, 0.0, max(Float64(xmax), 0.0))
    else
        xs, ys = lookup_plot_series(app_run, label, app.layout.time_range, show_ch1, show_ch2)
        label == "Command" ? autoscale_values!(app, axis, xs) : autoscale_values!(app, axis, xs, ys)
    end
    return nothing
end
