"""
plotting.jl

Plot-axis autoscaling and plot-series lookup for the GUI: computing axis
limits from the current data window, mapping a plot-selection label to its
underlying observables, and the protocol-setpoint highlight overlay.
"""

using GLMakie
using Observables

# -----------------------------------------------------------------------------
# plot selection labels
# -----------------------------------------------------------------------------

"""
Labels the Plot 1 / Plot 2 menus offer, and the values persisted in
`LayoutSettings.plot1`/`.plot2`.

Named constants rather than bare strings because the same label has to match
in four places — the menu options, `render_plot!`'s dispatch,
`lookup_plot_series`'s dispatch, and the persisted state — and a typo in any
one of them silently renders an empty plot.

`PLOT_IMAGE` replaces FLIM's Histogram plot: a TCSPC decay curve has no
ratiometric counterpart, whereas seeing the field being imaged does.
"""
const PLOT_IMAGE         = "Image"
const PLOT_INTENSITY     = "Mean intensity"
const PLOT_RATIO         = "Ratio"
const PLOT_CONCENTRATION = "Concentration"
const PLOT_COMMAND       = "Command"

"""
    PLOT_OPTIONS

Every plot selection, in menu order.
"""
const PLOT_OPTIONS = [PLOT_IMAGE, PLOT_INTENSITY, PLOT_RATIO, PLOT_CONCENTRATION, PLOT_COMMAND]

"""
    MAX_PLOT_CHANNELS

How many per-channel visibility toggles each plot slot carries. Three because
that is the most channels the acquisition writes; toggles beyond a run's
actual channel count are simply inert.
"""
const MAX_PLOT_CHANNELS = 3

"""
    plot_channel_toggles(layout, slot) -> NTuple{MAX_PLOT_CHANNELS, Bool}

The per-channel visibility toggles for plot slot 1 or 2.

Gathered into a tuple so every drawing and autoscaling function takes one
argument that scales with channel count, instead of the `show_ch1, show_ch2`
pair that would have to grow a third positional argument (and be updated at
every call site) each time a channel is added.
"""
function plot_channel_toggles(layout::LayoutSettings, slot::Integer)
    return slot == 1 ?
        (layout.plot1_ch1, layout.plot1_ch2, layout.plot1_ch3) :
        (layout.plot2_ch1, layout.plot2_ch2, layout.plot2_ch3)
end

"""
    shown_channel_positions(toggles, channel_count) -> Vector{Int}

Which channel positions a plot should draw: those whose toggle is on and
which the current acquisition actually provides.

An acquisition writing two channels leaves the third toggle inert rather than
drawing an empty trace for it.
"""
function shown_channel_positions(toggles, channel_count::Integer)
    return [c for c in 1:min(length(toggles), Int(channel_count)) if toggles[c]]
end

# -----------------------------------------------------------------------------
# image plot
# -----------------------------------------------------------------------------

"""
    channel_composite(preview, toggles, channel_count) -> Union{Nothing, Matrix{RGBf}}

Composite the enabled channels of one `FramePreview` into a single RGB image,
each channel tinted with its own plot color and added on top of black.

Additive mixing, the convention for multichannel fluorescence display: a pixel
bright in channels 1 and 2 shows their two colors summed, so overlap is
visible rather than hidden behind whichever channel happened to be drawn last.
Components are clamped at 1, so saturated overlap goes white instead of
wrapping.

Each channel is normalized to *its own* maximum before tinting. Absolute
comparability between channels is not the point here — the Mean intensity plot
carries that — whereas an 8-bit acquisition with a mean around 9/255 would be
nearly invisible under a shared scale.

Returns `nothing` when there is nothing to draw: no preview yet, or no channel
toggle enabled. That last case is deliberate — with every toggle off the image
plot must go blank, not fall back to some default channel.
"""
function channel_composite(preview::Union{Nothing, FramePreview}, toggles, channel_count)::Union{Nothing, Matrix{RGBf}}
    preview === nothing && return nothing

    positions = [p for p in shown_channel_positions(toggles, channel_count)
                 if p <= length(preview.channel_images)]
    isempty(positions) && return nothing

    reference = preview.channel_images[first(positions)]
    isempty(reference) && return nothing

    out = fill(RGBf(0.0f0, 0.0f0, 0.0f0), size(reference))

    for position in positions
        source = preview.channel_images[position]
        size(source) == size(reference) || continue

        peak = 0.0f0
        @inbounds for v in source
            isfinite(v) && v > peak && (peak = v)
        end
        peak > 0 || continue

        tint = RGBf(plot_channel_color(position))

        @inbounds for i in eachindex(out)
            v = source[i]
            isfinite(v) || continue
            level = clamp(v / peak, 0.0f0, 1.0f0)
            previous = out[i]
            out[i] = RGBf(
                min(1.0f0, previous.r + level * tint.r),
                min(1.0f0, previous.g + level * tint.g),
                min(1.0f0, previous.b + level * tint.b)
            )
        end
    end

    return out
end

"""
Axis attributes the Image plot overrides, paired with the value it wants.

Every one of them is restored from `AXIS_PLOTS_ATTRS` when the slot switches
back to a line plot (`apply_axis_style!` below), so the two plot families can
share an axis without the image's chrome-free look leaking into the traces.

- **`aspect`** — `DataAspect` keeps pixels square, so a 1024x512 frame is not
  stretched to fill a wide axis. Measured not to affect the block's size or
  position, the axis carrying a fixed `width`/`height`.
- **`yreversed`** — TIFF row 0 is the top of the image, while a Makie axis puts
  y = 0 at the bottom. Without this the frame is displayed upside down
  relative to the ROI popup, where the ROIs were drawn.
- **`backgroundcolor`** — black, so unlit pixels read as unlit rather than as
  the panel's grey.
- **spines and grids** — hidden outright; neither participates in layout.
- **ticks and tick labels** — turned *transparent* rather than hidden, for the
  reason below.

# Why ticks are made invisible rather than hidden

Setting `xticksvisible`/`xticklabelsvisible` (and their y counterparts) to
`false` does not merely stop them being drawn: it collapses the axis's
**protrusions**, the space reserved outside the plotting box for decorations.
The box keeps its 840x300 size, but its origin moves — measured at ~12 px in x
and ~13 px in y — so every switch to or from the Image plot nudged the whole
panel. Painting them transparent instead leaves them measured, and therefore
leaves the protrusions and the layout byte-identical, while showing nothing.

The other overrides were each measured against the axis's computed bounding box
and protrusions; only these four moved anything.
"""
const IMAGE_AXIS_OVERRIDES = (
    :aspect             => DataAspect(),
    :yreversed          => true,
    # `RGBAf`, not `:black`: the axis's `backgroundcolor` observable is typed
    # `RGBA{Float32}`, and a Symbol has no conversion to it — assigning one
    # throws rather than being interpreted as a named color.
    :backgroundcolor    => RGBAf(0.0f0, 0.0f0, 0.0f0, 1.0f0),
    :xgridvisible       => false,
    :ygridvisible       => false,
    :topspinevisible    => false,
    :bottomspinevisible => false,
    :leftspinevisible   => false,
    :rightspinevisible  => false,
    :xtickcolor         => RGBAf(0.0f0, 0.0f0, 0.0f0, 0.0f0),
    :ytickcolor         => RGBAf(0.0f0, 0.0f0, 0.0f0, 0.0f0),
    :xticklabelcolor    => RGBAf(0.0f0, 0.0f0, 0.0f0, 0.0f0),
    :yticklabelcolor    => RGBAf(0.0f0, 0.0f0, 0.0f0, 0.0f0),
    :xminortickcolor    => RGBAf(0.0f0, 0.0f0, 0.0f0, 0.0f0),
    :yminortickcolor    => RGBAf(0.0f0, 0.0f0, 0.0f0, 0.0f0),
)

"""
    apply_axis_style!(axis, plot_label)

Put `axis` into image mode or back into line-plot mode, depending on what it
is about to draw.

Called from `render_plot!` on every re-render — including the ones triggered by
switching plot type or toggling a channel — so the styling always matches the
current selection rather than whatever the previous one left behind.
"""
function apply_axis_style!(axis, plot_label)
    if plot_label == PLOT_IMAGE
        for (attribute, value) in IMAGE_AXIS_OVERRIDES
            getproperty(axis, attribute)[] = value
        end
    else
        for (attribute, _) in IMAGE_AXIS_OVERRIDES
            getproperty(axis, attribute)[] = AXIS_PLOTS_ATTRS[attribute]
        end
    end

    return nothing
end

"""
    fit_image_axis!(axis, app_run)

Set `axis`'s limits to the current preview's pixel extent, so the frame is
centered and fills the axis.

Called both when the Image plot is first drawn and on every publish tick (via
`autoscale_plot!`), because the preview's size is not known until the first
frame arrives — and can change between runs, the acquisition writing 1024x512
as readily as 1024x1024.

`DataAspect` (see `IMAGE_AXIS_OVERRIDES`) then letterboxes the frame within
whatever aspect ratio the axis widget happens to have, rather than stretching
it to fit.
"""
function fit_image_axis!(axis, app_run)
    preview = app_run.preview[]
    preview === nothing && return nothing
    isempty(preview.channel_images) && return nothing

    width, height = size(first(preview.channel_images))
    (width > 0 && height > 0) || return nothing

    axis.limits[] = (0, width, 0, height)
    return nothing
end

"""
    draw_image_plot!(axis, app, app_run, toggles)

Draw the most recent frame snapshot onto `axis` as an additive color composite
of the enabled channels.

Unlike the FLIM Histogram plot this replaces, and unlike a heatmap of a single
channel, the toggles here *accumulate*: every enabled channel contributes its
own color to one image (see `channel_composite`). With no toggle enabled
nothing is drawn at all.

The image is `lift`ed from `app_run.preview`, so it refreshes whenever the
consumer publishes a new snapshot without the axis being rebuilt. The lift
substitutes a 1x1 transparent pixel when there is nothing to show, since a
Makie plot cannot carry `nothing` as its data — but the plot is only created
in the first place when at least one channel is on.
"""
function draw_image_plot!(axis, app, app_run, toggles)
    positions = shown_channel_positions(toggles, app_run.channel_count)
    isempty(positions) && return nothing

    blank = fill(RGBAf(0.0f0, 0.0f0, 0.0f0, 0.0f0), 1, 1)

    image_data = lift(app_run.preview) do preview
        composite = channel_composite(preview, toggles, app_run.channel_count)
        composite === nothing && return blank
        return RGBAf.(composite)
    end

    # `image!` rather than `heatmap!`: the data is already RGB, and image!
    # maps it onto the given extent without a colormap in between.
    extents = lift(image_data) do img
        return (0 .. max(size(img, 1), 1), 0 .. max(size(img, 2), 1))
    end

    image!(axis, lift(first, extents), lift(last, extents), image_data; interpolate=false)
    fit_image_axis!(axis, app_run)

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
    draw_region_series!(axis, app, app_run, values_of, smooth_of, color_of)

Shared body of the three line plots: for each region, draw its raw trace
faintly and its smoothed trace solid on top.

`values_of`/`smooth_of` pull the raw and smoothed observables out of a
`RoiSeries`, and `color_of` picks that trace's color. Factored out because
the Ratio, Concentration and Mean-intensity plots differ *only* in those three
choices — the FLIM version carried three near-identical copies, and a fix
applied to one of them (the per-ROI superposition) had to be repeated in all
three.

Every region's lines share a color with no legend, so a single-region run
looks exactly as it did before per-ROI splitting existed.
"""
function draw_region_series!(axis, app, app_run, values_of, smooth_of, color)
    for series in app_run.rois_series
        raw_x, raw_y = plot_xy_observables(app, app_run, series.timestamps, values_of(series))
        smooth_x, smooth_y = plot_xy_observables(app, app_run, series.timestamps, smooth_of(series))
        lines!(axis, raw_x, raw_y, color=(color, 0.25), linewidth=PLOT_LINEWIDTH)
        lines!(axis, smooth_x, smooth_y, color=color, linewidth=PLOT_LINEWIDTH)
    end
    return nothing
end

"""
    draw_ratio_plot!(axis, app, app_run)

Draw the Ratio plot: the protocol-setpoint trace and highlight, plus each
region's raw and smoothed intensity ratio.

Not gated by the channel toggles — a ratio is formed *across* channels and
belongs to a region, so "show channel 2's ratio" has no meaning. This is the
direct replacement for FLIM's Lifetime plot, and like it, it is the series the
PI controller regulates on.
"""
function draw_ratio_plot!(axis, app, app_run)
    add_setpoint_highlight!(axis, app_run)
    protocol_x, protocol_y = plot_xy_observables(app, app_run, app_run.timestamps, app_run.protocol_setpoint)
    lines!(axis, protocol_x, protocol_y, color=PLOT_COLOR_REF, linewidth=PLOT_LINEWIDTH)

    draw_region_series!(axis, app, app_run, s -> s.ratio, s -> s.ratio_smooth, PLOT_COLOR_CH1)

    return nothing
end

"""
    draw_concentration_plot!(axis, app, app_run)

Draw the Concentration plot: each region's raw and smoothed concentration,
obtained by inverting the Hill calibration on that region's ratio (see
`hill_ratio_to_concentration`, ratio_analysis.jl).

Like the Ratio plot, not gated by the channel toggles — the concentration is a
function of the ratio, so it is per-region rather than per-channel.
"""
function draw_concentration_plot!(axis, app, app_run)
    add_setpoint_highlight!(axis, app_run)

    draw_region_series!(axis, app, app_run, s -> s.concentration, s -> s.concentration_smooth, PLOT_COLOR_CH1)

    return nothing
end

"""
    draw_intensity_plot!(axis, app, app_run, toggles)

Draw the Mean intensity plot: for each shown channel, that channel's raw and
smoothed mean intensity, one line pair per region, in the channel's own color.

This is the one line plot the channel toggles genuinely apply to — mean
intensity is the only quantity that remains per-channel after ratiometry, and
watching it is how photobleaching and saturation become visible.
"""
function draw_intensity_plot!(axis, app, app_run, toggles)
    add_setpoint_highlight!(axis, app_run)

    for position in shown_channel_positions(toggles, app_run.channel_count)
        color = plot_channel_color(position)
        for series in app_run.rois_series
            position > length(series.channels) && continue
            channel = series.channels[position]
            raw_x, raw_y = plot_xy_observables(app, app_run, series.timestamps, channel.values)
            smooth_x, smooth_y = plot_xy_observables(app, app_run, series.timestamps, channel.smooth)
            lines!(axis, raw_x, raw_y, color=(color, 0.25), linewidth=PLOT_LINEWIDTH)
            lines!(axis, smooth_x, smooth_y, color=color, linewidth=PLOT_LINEWIDTH)
        end
    end

    return nothing
end

"""
    render_plot!(app, app_run, blocks, plot_slot::Symbol)

Render whichever series `app.layout.plot1`/`.plot2` currently selects onto
`plot_slot`'s axis (`:plot1` or `:plot2`), gated by that slot's own channel
toggles. This is the single place that knows how to render a plot slot — the
Menu `on(selection)` handler and the channel-toggle `on(active)` handler (both
in handlers_layout.jl) and the initial render at GUI construction time
(GUI.jl's `draw_initial_plots!`) all call this instead of each keeping its own
copy.
"""
function render_plot!(app, app_run, blocks, plot_slot::Symbol)
    if plot_slot == :plot1
        axis = blocks.plot_1_axis
        selection = app.layout.plot1
        toggles = plot_channel_toggles(app.layout, 1)
        axis.title[] = "Plot 1\n($(selection))"
    else
        axis = blocks.plot_2_axis
        selection = app.layout.plot2
        toggles = plot_channel_toggles(app.layout, 2)
        axis.title[] = "Plot 2\n($(selection))"
    end

    empty!(axis)

    # Before drawing, not after: the Image plot wants a chrome-free, square,
    # y-flipped axis on a black ground, and every other plot wants the styling
    # AXIS_PLOTS_ATTRS gave it. Switching either way has to restore what the
    # previous selection changed.
    apply_axis_style!(axis, selection)

    if selection == PLOT_COMMAND
        add_setpoint_highlight!(axis, app_run)

        cmd1_x, cmd1_y = plot_xy_observables(app, app_run, app_run.timestamps, app_run.command1)
        cmd2_x, cmd2_y = plot_xy_observables(app, app_run, app_run.timestamps, app_run.command2)
        lines!(axis, cmd1_x, cmd1_y, color=PLOT_COLOR_CH1, linewidth=PLOT_LINEWIDTH)
        lines!(axis, cmd2_x, cmd2_y, color=PLOT_COLOR_CH2, linewidth=PLOT_LINEWIDTH)
    elseif selection == PLOT_RATIO
        draw_ratio_plot!(axis, app, app_run)
    elseif selection == PLOT_IMAGE
        draw_image_plot!(axis, app, app_run, toggles)
    elseif selection == PLOT_CONCENTRATION
        draw_concentration_plot!(axis, app, app_run)
    elseif selection == PLOT_INTENSITY
        draw_intensity_plot!(axis, app, app_run, toggles)
    end

    if selection == PLOT_IMAGE
        # An image has no time axis to pin, and the rolling-window logic below
        # would squash it. Its limits are the frame's pixel extent instead.
        fit_image_axis!(axis, app_run)
    elseif !app_run.running[]
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
        autoscale_plot!(app, app_run, axis, selection, toggles)
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

Reset an axis to Makie's automatic limits (used for the Image plot).
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
`ys_acc` in place. Small helper for `lookup_plot_series` below, so gating a
series on its channel toggle stays a one-liner instead of a branch per plot
label.
"""
function accumulate_windowed!(xs_acc::Vector{Float64}, ys_acc::Vector{Float64}, timestamps::AbstractVector{Float64}, values::AbstractVector{Float64}, time_range)
    ts_w, val_w = windowed_slice(timestamps, values, time_range)
    append!(xs_acc, ts_w)
    append!(ys_acc, val_w)
    return nothing
end

"""
    lookup_plot_series(app_run, plot_label, time_range, toggles)

Return x/y vectors for one plot label, restricted to the last `time_range`
units (see `windowed_slice`) and to whichever channels/regions are shown.

Each region's own `timestamps` windows its own series — per `RoiSeries`, they
are not aligned to a single shared x-axis.

Used for autoscaling only, never for drawing, so it flattens every shown trace
into one x/y pair: the axis limits depend on the union of the data, not on
which trace a point came from.

`PLOT_IMAGE` returns empty vectors — a heatmap's extent comes from the image
itself, not from a time window. `PLOT_COMMAND` ignores the toggles and always
reports both controller outputs; see `AppRun`'s docstring (data_types.jl) for
why the command series are not region-split like the others.
"""
function lookup_plot_series(app_run, plot_label, time_range, toggles)
    plot_label == PLOT_IMAGE && return (Float64[], Float64[])

    xs = Float64[]
    ys = Float64[]

    if plot_label == PLOT_INTENSITY
        for position in shown_channel_positions(toggles, app_run.channel_count)
            for series in app_run.rois_series
                position > length(series.channels) && continue
                channel = series.channels[position]
                ts = series.timestamps[]
                accumulate_windowed!(xs, ys, ts, channel.values[], time_range)
                accumulate_windowed!(xs, ys, ts, channel.smooth[], time_range)
            end
        end
        return (xs, ys)
    end

    if plot_label == PLOT_RATIO
        for series in app_run.rois_series
            ts = series.timestamps[]
            accumulate_windowed!(xs, ys, ts, series.ratio[], time_range)
            accumulate_windowed!(xs, ys, ts, series.ratio_smooth[], time_range)
        end
        accumulate_windowed!(xs, ys, app_run.timestamps[], app_run.protocol_setpoint[], time_range)
        return (xs, ys)
    end

    if plot_label == PLOT_CONCENTRATION
        for series in app_run.rois_series
            ts = series.timestamps[]
            accumulate_windowed!(xs, ys, ts, series.concentration[], time_range)
            accumulate_windowed!(xs, ys, ts, series.concentration_smooth[], time_range)
        end
        return (xs, ys)
    end

    if plot_label == PLOT_COMMAND
        ts = app_run.timestamps[]
        accumulate_windowed!(xs, ys, ts, app_run.command1[], time_range)
        accumulate_windowed!(xs, ys, ts, app_run.command2[], time_range)
        return (xs, ys)
    end

    return (Float64[], Float64[])
end

"""
    notify_roi_series!(series::RoiSeries)

Notify one region's time-series observables — timestamps, ratio,
concentration, each channel's mean intensity, and their smoothed
counterparts.
"""
function notify_roi_series!(series::RoiSeries)
    notify(series.timestamps)
    notify(series.ratio)
    notify(series.ratio_smooth)
    notify(series.concentration)
    notify(series.concentration_smooth)

    for channel in series.channels
        notify(channel.values)
        notify(channel.smooth)
    end

    return nothing
end

function notify_runtime_observables!(app_run)
    foreach(notify_roi_series!, app_run.rois_series)
    notify(app_run.protocol_setpoint)
    notify(app_run.command1)
    notify(app_run.command2)
    notify(app_run.timestamps)
    notify(app_run.i)
    return nothing
end

function autoscale_plot!(app, app_run, axis, plot_label, toggles)
    if plot_label == PLOT_IMAGE
        # Re-fit rather than autoscale: the preview's size is unknown until the
        # first frame arrives, so the limits set at draw time may predate any
        # image existing at all.
        fit_image_axis!(axis, app_run)
        return nothing
    end

    xs, ys = lookup_plot_series(app_run, plot_label, app.layout.time_range, toggles)

    if plot_label == PLOT_COMMAND
        autoscale_values!(app, axis, xs)
    else
        autoscale_values!(app, axis, xs, ys)
    end

    return nothing
end
