"""
gui/spc_window.jl

The SPC window (main thread only): the SPC-150N controls and live displays.
Opened from the SPC button of the top bar; closing it leaves the engine
running.

- CONNECT/DISCONNECT starts or stops the engine (FLIMCore), which opens and
  checks the cards on its own thread; CHECK redoes the check; IMAGE and
  SINGLE start or stop a measurement; UNLOCK takes over cards left locked
  (state -6) after a confirming second click — SPCM must be closed.
- Per card: the intensity image and the mean arrival time (first moment,
  no IRF correction: a preview, not a fit), then the decays (solid:
  imaging, dashed: last Single histogram) and the CFD rate.
- The geometry, display and Single settings are written back to
  config/spc.toml, which the engine rereads at every measurement start.

Every Observable here is refreshed by the refresh tick (`spc_tick!`,
gui/spc_view.jl); the callbacks only send commands or edit the settings.
"""

using GLMakie

"""Axes the refresh tick rescales (image axes when the geometry changes)."""
mutable struct SpcWindowAxes
    images::Vector{Tuple{Int, Axis}}
    decay::Axis
    rates::Axis
    image_sizes::Dict{Int, Tuple{Int, Int}}
    last_autoscale::Float64
end

function spc_bring_to_front!(screen::GLMakie.Screen)
    try
        GLMakie.GLFW.RestoreWindow(screen.glscreen)
        GLMakie.GLFW.ShowWindow(screen.glscreen)
        GLMakie.GLFW.RequestWindowAttention(screen.glscreen)
    catch e
        @warn "Unable to focus the SPC window" error=string(e)
    end
    return nothing
end

"""Settings editable from the window: (label, field, type, minimum)."""
const SPC_WINDOW_SETTINGS = [
    ("Pixel time [ns] (1024 pixels / line)", :temps_pixel_ns, Float64, 0),
    ("Pixel offset (scan_borders x)", :decalage_pixels, Int, 0),
    ("Lines / image (0 = from the frame clock)", :lignes_par_image, Int, 0),
    ("Line offset (scan_borders y)", :decalage_lignes, Int, 0),
    ("Imaging time [s] (0 = until STOP)", :duree_s, Float64, 0),
    ("Frames / image (0 = all)", :trames_par_image, Int, 0),
    ("Mean-time binning", :binning_temps, Int, 1),
    ("Single time [s]", :temps_collecte_s, Float64, 0),
    ("Single count", :n_histogrammes, Int, 1),
]

spc_card_color(i::Integer) = i == 1 ? PLOT_COLOR_CH1 : i == 2 ? PLOT_COLOR_CH2 : Makie.wong_colors()[mod1(i + 2, 7)]

"""
    build_spc_figure(view) -> (fig, widgets, (width, height))

The SPC window's figure, bound to `view`'s Observables, with its callbacks.
Displayed by `open_spc_window!`.
"""
function build_spc_figure(view::SpcView)
    cards = sort!(collect(keys(view.cards)))
    n_rows = max(1, length(cards))
    width, height = 1440, 250 + 320 * max(2, n_rows)
    fig = Figure(size = (width, height))

    controls = GridLayout(fig[1, 1:2]; tellwidth = false)
    images = GridLayout(fig[2, 1])
    side = GridLayout(fig[2, 2])
    texts = GridLayout(fig[3, 1:2]; tellwidth = false)
    colsize!(fig.layout, 2, Fixed(470))
    rowsize!(fig.layout, 3, Fixed(175))

    button(col, label) = Button(controls[1, col]; merge(BUTTON_ATTRS, Dict{Symbol, Any}(:label => label))...)
    connect_button = button(1, view.engine === nothing ? "CONNECT" : "DISCONNECT")
    check_button = button(2, "CHECK")
    image_button = button(3, "IMAGE")
    single_button = button(4, "SINGLE")
    unlock_button = button(5, "UNLOCK")
    Label(controls[1, 6], view.status; merge(LABEL_ATTRS, Dict{Symbol, Any}(
        :halign => :left, :justification => :left, :tellwidth => false, :word_wrap => true))...)
    colsize!(controls, 6, Relative(0.6))

    # Images: one row per card
    image_attrs = merge(AXIS_IMAGE_ATTRS, Dict{Symbol, Any}(:width => nothing, :height => nothing,
        :aspect => DataAspect(), :yreversed => true, :titlesize => 12, :titlefont => :regular))
    image_axes = Tuple{Int, Axis}[]
    for (row, c) in enumerate(cards)
        card = view.cards[c]
        Label(images[row, 1], card.title; merge(LABEL_ATTRS, Dict{Symbol, Any}(:rotation => pi / 2, :tellheight => false))...)
        ax_i = Axis(images[row, 2]; merge(image_attrs, Dict{Symbol, Any}(:title => "Intensity"))...)
        heatmap!(ax_i, card.intensity; colormap = :grays, colorrange = card.intensity_range)
        ax_t = Axis(images[row, 3]; merge(image_attrs, Dict{Symbol, Any}(:title => "Mean arrival time (ns)"))...)
        hm = heatmap!(ax_t, card.mean_time; colormap = :turbo, colorrange = card.time_range, nan_color = :transparent)
        Colorbar(images[row, 4], hm; width = 10, ticklabelsize = 10, ticklabelcolor = TEXT, tickcolor = COLOR_5)
        push!(image_axes, (c, ax_i), (c, ax_t))
    end

    # Decays and rates
    plot_attrs = merge(AXIS_PLOTS_ATTRS, Dict{Symbol, Any}(:width => nothing, :height => nothing, :titlesize => 12,
        :xlabelsize => 11, :ylabelsize => 11, :xticklabelsize => 10, :yticklabelsize => 10, :yscale => log10))
    decay_axis = Axis(side[1, 1:2]; merge(plot_attrs, Dict{Symbol, Any}(:title => "Decay (solid: imaging, dashed: Single)",
        :xlabel => "Time [ns]", :ylabel => "Counts + 1"))...)
    rates_axis = Axis(side[2, 1:2]; merge(plot_attrs, Dict{Symbol, Any}(:title => "CFD rate",
        :xlabel => "Time [s]", :ylabel => "Counts / s"))...)
    for (i, c) in enumerate(cards)
        card = view.cards[c]
        color = spc_card_color(i)
        lines!(decay_axis, card.decay; color = color, linewidth = PLOT_LINEWIDTH, label = "Card $c")
        lines!(decay_axis, card.single; color = color, linewidth = PLOT_LINEWIDTH, linestyle = :dash)
        lines!(rates_axis, card.rates; color = color, linewidth = PLOT_LINEWIDTH, label = "Card $c")
    end
    isempty(cards) || axislegend(rates_axis; position = :lb, labelsize = 10, framevisible = false, patchsize = (10, 5))

    # Settings (written back to config/spc.toml)
    settings = GridLayout(side[3, 1:2]; tellwidth = false)
    s = view.settings
    for (row, (label, field, T, minimum_value)) in enumerate(SPC_WINDOW_SETTINGS)
        col = 2 * ((row - 1) ÷ 5)
        r = mod1(row, 5)
        Label(settings[r, col + 1]; merge(LABEL_ATTRS, Dict{Symbol, Any}(:text => label, :halign => :right, :fontsize => 11))...)
        current = string(getfield(s, field))
        box = Textbox(settings[r, col + 2]; merge(TEXT_ATTRS, Dict{Symbol, Any}(
            :displayed_string => current, :stored_string => current, :width => 64,
            :validator => T == Int ? make_int_range_validator(minimum_value, 10_000_000) :
                                     make_float_range_validator(minimum_value, 1.0e6)))...)
        on(box.stored_string) do text
            value = tryparse(T, strip(text))
            accepted = value !== nothing && spc_edit_setting!(view, field, value)
            accepted || (box.displayed_string[] = string(getfield(view.settings, field)))
        end
    end
    Label(settings[5, 3]; merge(LABEL_ATTRS, Dict{Symbol, Any}(:text => "Save raw stream (.spc)", :halign => :right, :fontsize => 11))...)
    raw_toggle = Toggle(settings[5, 4]; merge(TOGGLE_ATTRS, Dict{Symbol, Any}(:active => s.flux_brut))...)
    on(raw_toggle.active) do active
        spc_edit_setting!(view, :flux_brut, active)
    end
    rowgap!(settings, 4)
    rowsize!(side, 3, Auto())

    # Check (with the engine info under it) and alerts, in a band across the bottom
    text_attrs = merge(LABEL_ATTRS, Dict{Symbol, Any}(:fontsize => 11, :justification => :left, :halign => :left,
        :valign => :top, :word_wrap => true, :tellwidth => false, :tellheight => false))
    Label(texts[1, 1]; merge(text_attrs, Dict{Symbol, Any}(:text => view.check_text))...)
    Label(texts[2, 1]; merge(text_attrs, Dict{Symbol, Any}(:text => view.info_text, :valign => :bottom, :tellheight => true))...)
    Label(texts[1:2, 2]; merge(text_attrs, Dict{Symbol, Any}(:text => view.alerts_text))...)
    colgap!(texts, 24)

    on(connect_button.clicks) do _
        view.engine === nothing ? spc_connect!(view) : spc_disconnect!(view)
    end
    on(check_button.clicks) do _
        spc_command!(view, FLIMCore.Verifier())
    end
    on(image_button.clicks) do _
        spc_toggle_imaging!(view)
    end
    on(single_button.clicks) do _
        spc_toggle_single!(view)
    end
    on(unlock_button.clicks) do _
        spc_unlock_pressed!(view)
    end

    widgets = SpcWindowWidgets(connect_button, image_button, single_button, unlock_button,
                               SpcWindowAxes(image_axes, decay_axis, rates_axis, Dict{Int, Tuple{Int, Int}}(), 0.0))
    return fig, widgets, (width, height)
end

"""
    open_spc_window!(app_run, screen_ref)

Open the SPC window, or bring it to the front if it is already open.
"""
function open_spc_window!(app_run, screen_ref::Base.RefValue{Union{Nothing, GLMakie.Screen}})
    existing = screen_ref[]
    if existing !== nothing && isopen(existing)
        spc_bring_to_front!(existing)
        return nothing
    end

    view = app_run.spc
    fig, widgets, (width, height) = build_spc_figure(view)
    screen = GLMakie.Screen(resolution = (width, height))
    screen_ref[] = screen
    view.widgets = widgets
    view.window_open = true
    view.last_state = :none                        # relabel the buttons on the next tick
    view.texts_dirty = true
    for card in values(view.cards)
        card.pending = !isempty(card.acc_intensity)
        card.rates_dirty = true
    end

    on(events(fig).window_open) do is_open
        is_open && return
        view.window_open = false
        view.widgets = nothing
        screen_ref[] === screen && (screen_ref[] = nothing)
    end

    display(screen, fig.scene)
    return nothing
end

"""
    spc_autoscale_window!(view)

Fit the image axes to a new image size right away, and the decay and rate
axes at most once a second (plan.md §5: no limits recomputed every tick).
"""
function spc_autoscale_window!(view::SpcView)
    w = view.widgets
    (w === nothing || !view.window_open) && return nothing
    axes = w.axes
    for (c, ax) in axes.images
        card = get(view.cards, c, nothing)
        card === nothing && continue
        sz = size(card.intensity[])
        if get(axes.image_sizes, c, (0, 0)) != sz
            reset_limits!(ax)
        end
    end
    for (c, _) in axes.images
        haskey(view.cards, c) && (axes.image_sizes[c] = size(view.cards[c].intensity[]))
    end
    if time() - axes.last_autoscale >= 1.0
        axes.last_autoscale = time()
        for ax in (axes.decay, axes.rates)
            try
                reset_limits!(ax)
            catch
                # nothing plotted yet (empty curves on a log axis)
            end
        end
    end
    return nothing
end
