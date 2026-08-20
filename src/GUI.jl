"""
GUI.jl

Makie-based graphical user interface for the FLIM application.

Implements:
- Main figure layout with grid system
- Plotting axes for the image preview, ratios, intensities and concentration
- Control panels (Layout, Controller, Protocol, Console)
- Interactive widgets (buttons, text boxes, menus, spinners)
- Theme-aware styling and colors

The make_gui() function constructs and configures all GUI elements, delegating
to the make_*_grids!/make_*_axes!/make_*_widgets! helpers below for each
section. The make_handlers() function (in handlers.jl) attaches event callbacks.
"""

using GLMakie
using Base.Threads
using Dates

"""
    port_options(no_port_label::AbstractString)::Vector{String}

Enumerate serial ports and prepend a default "no selection" label.
"""
function port_options(no_port_label::AbstractString)::Vector{String}
    detected_ports = try
        list_ports()
    catch e
        @warn "Port enumeration failed" error = string(e)
        String[]
    end

    return vcat([String(no_port_label)], detected_ports)
end

"""
    refresh_port_menu!(menu::Menu; no_port_label::AbstractString="No port selected")

Refresh serial port menu options while preserving the previous valid selection.
"""
function refresh_port_menu!(menu::Menu; no_port_label::AbstractString="No port selected")
    if menu.is_open[]
        return nothing
    end

    old_selection = menu.selection[]
    new_options = port_options(no_port_label)

    # Prevent updates if user opened the dropdown while ports were being scanned.
    if menu.is_open[]
        return nothing
    end

    if menu.options[] != new_options
        menu.options[] = new_options
    end

    if old_selection isa AbstractString && old_selection in new_options
        idx = findfirst(==(old_selection), new_options)
        if idx !== nothing && menu.i_selected[] != idx
            menu.i_selected[] = idx
        end
    elseif menu.i_selected[] != 1
        menu.i_selected[] = 1
    end

    return nothing
end

"""
    make_gui_grids(fig)

Build the top-level grid skeleton (top/left/right + the nested button/path/
panel grids) and draw the static background boxes. Returns a NamedTuple of
the grids, keyed the same way they end up in `blocks`.
"""
function make_gui_grids(fig)
    top_grid   = GridLayout(fig[1, 1:2], width = 1440, height = 24)
    left_grid  = GridLayout(fig[2, 1],   width = 1140, height = 823)
    right_grid = GridLayout(fig[2, 2],   width = 300,  height = 823)

    button_grid   = GridLayout(right_grid[2, 2])
    path_grid     = GridLayout(right_grid[3, 2])
    panelbtn_grid = GridLayout(right_grid[5, 2])
    panel_grid    = GridLayout(right_grid[6, 2])

    Box(top_grid[1, 1:5];     merge(BOX_ATTRS, Dict{Symbol, Any}(:color => COLOR_3,      :strokewidth => 0.2))...)
    Box(right_grid[1:7, 1:3]; merge(BOX_ATTRS, Dict{Symbol, Any}(:color => COLOR_1,      :strokewidth => 0.2))...)
    Box(left_grid[1:5, 1:5];  merge(BOX_ATTRS, Dict{Symbol, Any}(:color => :transparent, :strokewidth => 0.2))...)
    Box(right_grid[6, 2];     merge(BOX_ATTRS, Dict{Symbol, Any}(:color => COLOR_2,      :height => 400, :strokewidth => 0, :width => 240))...)
    Box(right_grid[5:6, 2];   merge(BOX_ATTRS, Dict{Symbol, Any}(:strokewidth => 0.3,    :width  => 240))...)

    Box(button_grid[1, 1]; merge(BOX_ATTRS, Dict{Symbol, Any}(:cornerradius => BUTTON_ATTRS[:cornerradius]))...)
    Box(button_grid[1, 2]; merge(BOX_ATTRS, Dict{Symbol, Any}(:cornerradius => BUTTON_ATTRS[:cornerradius]))...)

    return (top_grid=top_grid, left_grid=left_grid, right_grid=right_grid,
            button_grid=button_grid, path_grid=path_grid,
            panelbtn_grid=panelbtn_grid, panel_grid=panel_grid)
end

"""
    apply_gui_layout_tweaks!(fig, grids)

Final row/column gap and size adjustments. Must run after every widget in
`grids` has been created (panel buttons in particular) — applying
`colgap!(panelbtn_grid, -1)` before the panel buttons exist changes how
Makie auto-sizes their columns.
"""
function apply_gui_layout_tweaks!(fig, grids)
    rowgap!(grids.right_grid, 5, 0)
    rowgap!(fig.layout, 1, 0)
    colgap!(fig.layout, 1, 0)
    colgap!(grids.panelbtn_grid, -1)
    colsize!(grids.left_grid, 1, 32)
    colsize!(grids.left_grid, 5, 32)
    rowsize!(grids.left_grid, 4, 20)
    return nothing
end

"""
    make_plot_axes!(left_grid, app, app_run)

Create the counts bar, Plot 1 / Plot 2 axes, and the save-progress bar (with
its live-updating fill driven by `app_run.save_progress`). Returns a
NamedTuple of the created axes.
"""
function make_plot_axes!(left_grid, app, app_run)
    counts_axis = Axis(left_grid[2:3, 2]; AXIS_COUNTS_ATTRS...)

    plot_1 = Axis(left_grid[2, 4]; merge(AXIS_PLOTS_ATTRS, Dict{Symbol, Any}(:title =>"Plot 1\n($(app.layout.plot1))"))...)
    plot_2 = Axis(left_grid[3, 4]; merge(AXIS_PLOTS_ATTRS, Dict{Symbol, Any}(:title =>"Plot 2\n($(app.layout.plot2))"))...)

    save_progress_axis = Axis(left_grid[4, 2:4]; PROGRESS_BAR_ATTRS...)
    hidedecorations!(save_progress_axis)
    xlims!(save_progress_axis, 0.0, 100.0)
    ylims!(save_progress_axis, 0.0, 20.0)

    save_outline_color = lift(app_run.save_progress) do p
        return isfinite(Float64(p)) ? COLOR_5 : RGBAf(1.0, 1.0, 1.0, 0.0)
    end
    lines!(save_progress_axis, [0.0, 100.0, 100.0, 0.0, 0.0], [0.0, 0.0, 20.0, 20.0, 0.0], color=save_outline_color, linewidth=1.5)

    save_fill_width = lift(app_run.save_progress, save_progress_axis.scene.viewport) do p, viewport
        width_units = Float64(viewport.widths[1])
        height_units = Float64(viewport.widths[2])

        if !isfinite(width_units) || width_units <= 0.0 || !isfinite(height_units) || height_units <= 0.0
            return 0.0
        end

        # Convert one-bar-height in viewport units to x-axis data units so 0% starts as a square.
        min_width_units = clamp(height_units * (100.0 / width_units), 0.0, 100.0)

        if !isfinite(Float64(p))
            return min_width_units
        end

        clamped = clamp(Float64(p), 0.0, 100.0)
        return min_width_units + (100.0 - min_width_units) * (clamped / 100.0)
    end

    save_fill_color = lift(app_run.save_progress) do p
        return isfinite(Float64(p)) ? COLOR_5 : RGBAf(COLOR_5.r, COLOR_5.g, COLOR_5.b, 0.0)
    end
    vspan!(save_progress_axis, 0.0, save_fill_width, color=save_fill_color)

    # The side gauge shows each channel's most recent mean intensity. Lifted
    # from the preview rather than from a dedicated "latest frame" observable:
    # the preview already carries exactly this, and a ratiometric run has no
    # per-channel scalar snapshot of its own the way a fitted photon count was.
    for position in 1:MAX_PLOT_CHANNELS
        color = plot_channel_color(position)
        level = lift(app_run.preview) do preview
            preview === nothing && return 0.0
            position > length(preview.channel_images) && return 0.0
            values = preview.channel_images[position]
            isempty(values) && return 0.0
            total = 0.0
            count = 0
            @inbounds for v in values
                isfinite(v) || continue
                total += Float64(v)
                count += 1
            end
            return count == 0 ? 0.0 : total / count
        end
        hspan!(counts_axis, 1, level, color = (color, 0.1))
        hlines!(counts_axis, level, color = color, linewidth = PLOT_LINEWIDTH)
    end

    return (counts_axis=counts_axis, plot_1=plot_1, plot_2=plot_2, save_progress_axis=save_progress_axis)
end

"""
    make_control_widgets!(button_grid, panelbtn_grid, initial_ratio_combination)

Create the START/CLEAR buttons, the data-folder path control, serial port
menu + CONNECT button, info label, mode/ratio menus, and the panel switch
buttons. Returns a NamedTuple of the created widgets.

The IRF path control the FLIM layout carried is gone — a ratiometric
acquisition has no instrument response to load — and every row below it moves
up one.

`initial_ratio_combination` seeds the ratio menu from
`app.layout.ratio_combination` (data_types.jl). Unlike `mode`, that selection
round-trips through `AppState`, so its default must reflect whatever was last
persisted rather than always starting from the menu's first option.
"""
function make_control_widgets!(button_grid, panelbtn_grid, initial_ratio_combination::AbstractString)
    start = Button(button_grid[1, 1]; merge(BUTTON_ATTRS, Dict{Symbol, Any}(:label => "START"))...)
    stop  = Button(button_grid[1, 2]; merge(BUTTON_ATTRS, Dict{Symbol, Any}(:label => "CLEAR"))...)

    initial_folder_name = cached_basename(folderpath_cache(); fallback_path=get_data_root_path())
    folder_path   = Textbox(button_grid[2, 1:2]; merge(PATH_TEXT_ATTRS, Dict{Symbol, Any}(:placeholder => "Folder path", :displayed_string => initial_folder_name, :stored_string => initial_folder_name))...)
    folder_button = Button(button_grid[2, 1:2];  PATH_BUTTON_ATTRS...)

    no_port_selected_label = "No port selected"

    initial_port_options = port_options(no_port_selected_label)
    port = Menu(button_grid[3, 1]; merge(MENU_ATTRS, Dict{Symbol, Any}(:options => initial_port_options, :default => 1))...)

    connect = Button(button_grid[3, 2]; merge(BUTTON_ATTRS, Dict{Symbol, Any}(:label => "CONNECT"))...)

    label = Label(button_grid[4, 1], "Frequency: -- Hz\nFile: --"; merge(LABEL_ATTRS, Dict{Symbol, Any}(:justification => :left, :halign => :left, :tellwidth => false))...)
    default_target_freq_string = string(DEFAULT_PLAYBACK_TARGET_FREQUENCY_HZ)
    target_freq = Textbox(button_grid[4, 2]; merge(SPINNER_TEXT_ATTRS, Dict{Symbol, Any}(:placeholder => "Target frequency (Hz)", :displayed_string => default_target_freq_string, :stored_string => default_target_freq_string, :validator => make_float_range_validator(0.01, 1.0e6)))...)

    mode = Menu(button_grid[5, 1]; merge(MENU_ATTRS, Dict{Symbol, Any}(:options => ["Playback", "Realtime", "Save"]))...)

    # Occupies the slot the "1/2/3 lifetimes" menu used to. All six ordered
    # channel pairs are always offered regardless of how many channels the
    # acquisition writes: a combination naming an absent channel yields a NaN
    # ratio rather than blocking the run, and the per-channel intensity series
    # stay usable either way.
    ratio = Menu(button_grid[5, 2]; merge(MENU_ATTRS, Dict{Symbol, Any}(:options => RATIO_COMBINATION_OPTIONS, :default => initial_ratio_combination))...)

    Box(button_grid[2, 1:2]; PATH_BOX_ATTRS...)

    panel = Dict{Symbol, Button}(
        :layout     => Button(panelbtn_grid[1, 1]; merge(PANEL_ATTRS, Dict{Symbol, Any}(:label => "Layout"))...),
        :controller => Button(panelbtn_grid[1, 2]; merge(PANEL_ATTRS, Dict{Symbol, Any}(:label => "Controller"))...),
        :protocol   => Button(panelbtn_grid[1, 3]; merge(PANEL_ATTRS, Dict{Symbol, Any}(:label => "Protocol"))...),
        :console    => Button(panelbtn_grid[1, 4]; merge(PANEL_ATTRS, Dict{Symbol, Any}(:label => "Console"))...)
    )

    return (start_button=start, stop_button=stop,
            folder_path_textbox=folder_path, folder_button=folder_button, port_menu=port,
            connect_button=connect, info_label=label, target_freq_textbox=target_freq,
            mode_menu=mode, ratio_menu=ratio,
            panel_buttons=panel, no_port_selected_label=no_port_selected_label)
end

"""
    start_port_menu_refresher!(fig, port_menu, no_port_label)

Launch a background task that periodically refreshes `port_menu`'s options
while the figure window is open, and exits once the window is closed.
"""
function start_port_menu_refresher!(fig, port_menu, no_port_label)
    @async begin
        was_open = false

        while true
            is_window_open = isopen(fig.scene)

            if is_window_open
                was_open = true
                refresh_port_menu!(port_menu; no_port_label=no_port_label)
            elseif was_open
                break
            end

            sleep(1.0)
        end
    end

    return nothing
end

"""
    draw_initial_plots!(app, app_run, blocks)

Draw the initially-selected series (per `app.layout.plot1`/`.plot2`, gated
by that plot's own channel toggles) onto the two plot axes at GUI
construction time, via `render_plot!` (plotting.jl) — the same
function the Menu/Toggle handlers in handlers_layout.jl use, so this never
drifts into a second copy of the per-plot-type drawing logic.
"""
function draw_initial_plots!(app, app_run, blocks)
    render_plot!(app, app_run, blocks, :plot1)
    render_plot!(app, app_run, blocks, :plot2)
    return nothing
end

"""
    make_gui(app, app_run) -> (Figure, GuiBlocks)

Build the Makie GUI (plot axes, control buttons, text fields, panel
buttons) and return the `Figure` with its `GuiBlocks`. Event handlers are
attached separately by `make_handlers` (handlers.jl).
"""
function make_gui(app, app_run)
    if app.dark
        set_theme!(;DARK_MODE_THEME[:theme]...)
    else
        set_theme!(;LIGHT_MODE_THEME[:theme]...)
    end

    fig = Figure(size = (1440, 847), figure_padding = 0)

    grids = make_gui_grids(fig)
    axes = make_plot_axes!(grids.left_grid, app, app_run)
    widgets = make_control_widgets!(grids.button_grid, grids.panelbtn_grid, app.layout.ratio_combination)

    apply_gui_layout_tweaks!(fig, grids)

    blocks = GuiBlocks(
        top_grid            = grids.top_grid,
        left_grid           = grids.left_grid,
        right_grid          = grids.right_grid,
        button_grid         = grids.button_grid,
        path_grid           = grids.path_grid,
        panelbtn_grid       = grids.panelbtn_grid,
        panel_grid          = grids.panel_grid,
        start_button        = widgets.start_button,
        stop_button         = widgets.stop_button,
        folder_path_textbox = widgets.folder_path_textbox,
        folder_button       = widgets.folder_button,
        port_menu           = widgets.port_menu,
        connect_button      = widgets.connect_button,
        target_freq_textbox = widgets.target_freq_textbox,
        mode_menu           = widgets.mode_menu,
        ratio_menu          = widgets.ratio_menu,
        panel_buttons       = widgets.panel_buttons,
        info_label          = widgets.info_label,
        counts_axis         = axes.counts_axis,
        plot_1_axis         = axes.plot_1,
        plot_2_axis         = axes.plot_2,
        save_progress_axis  = axes.save_progress_axis
    )

    start_port_menu_refresher!(fig, widgets.port_menu, widgets.no_port_selected_label)
    draw_initial_plots!(app, app_run, blocks)

    # Axis autoscaling is handled by plotting.jl's autoscale_values!/autoscale_plot!
    # (called directly from consumer_loop on the axes stored in `blocks`).

    return fig, blocks
end
