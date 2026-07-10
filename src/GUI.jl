"""
GUI.jl

Makie-based graphical user interface for the FLIM application.

Implements:
- Main figure layout with grid system
- Plotting axes for histograms, lifetimes, and ion concentration
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

    hspan!(counts_axis, 1, app_run.counts, color = (PLOT_COLOR_CH1, 0.25))
    hlines!(counts_axis, app_run.counts, color = PLOT_COLOR_CH1)

    return (counts_axis=counts_axis, plot_1=plot_1, plot_2=plot_2, save_progress_axis=save_progress_axis)
end

"""
    make_control_widgets!(button_grid, panelbtn_grid)

Create the START/CLEAR buttons, IRF/data-folder path controls, serial port
menu + CONNECT button, info label, mode/lifetimes menus, and the panel
switch buttons. Returns a NamedTuple of the created widgets.
"""
function make_control_widgets!(button_grid, panelbtn_grid)
    start = Button(button_grid[1, 1]; merge(BUTTON_ATTRS, Dict{Symbol, Any}(:label => "START"))...)
    stop  = Button(button_grid[1, 2]; merge(BUTTON_ATTRS, Dict{Symbol, Any}(:label => "CLEAR"))...)

    initial_irf_name = cached_basename(IRF_FILEPATH_CACHE)
    initial_folder_name = cached_basename(FOLDERPATH_CACHE; fallback_path=get_data_root_path())
    irf_path      = Textbox(button_grid[2, 1:2]; merge(PATH_TEXT_ATTRS, Dict{Symbol, Any}(:placeholder => "IRF path", :displayed_string => initial_irf_name, :stored_string => initial_irf_name))...)
    folder_path   = Textbox(button_grid[3, 1:2]; merge(PATH_TEXT_ATTRS, Dict{Symbol, Any}(:placeholder => "Folder path", :displayed_string => initial_folder_name, :stored_string => initial_folder_name))...)
    irf_button    = Button(button_grid[2, 1:2];  PATH_BUTTON_ATTRS...)
    folder_button = Button(button_grid[3, 1:2];  PATH_BUTTON_ATTRS...)

    no_port_selected_label = "No port selected"

    initial_port_options = port_options(no_port_selected_label)
    port = Menu(button_grid[4, 1]; merge(MENU_ATTRS, Dict{Symbol, Any}(:options => initial_port_options, :default => 1))...)

    connect = Button(button_grid[4, 2]; merge(BUTTON_ATTRS, Dict{Symbol, Any}(:label => "CONNECT"))...)

    label = Label(button_grid[5, 1], "Frequency: -- Hz\nFile: --"; merge(LABEL_ATTRS, Dict{Symbol, Any}(:justification => :left, :halign => :left, :tellwidth => false))...)

    mode = Menu(button_grid[6, 1]; merge(MENU_ATTRS, Dict{Symbol, Any}(:options => ["Playback", "Realtime", "Save"]))...)
    lifetimes = Menu(button_grid[6, 2]; merge(MENU_ATTRS, Dict{Symbol, Any}(:options => ["1 lifetime", "2 lifetimes", "3 lifetimes"]))...)

    Box(button_grid[2, 1:2]; PATH_BOX_ATTRS...)
    Box(button_grid[3, 1:2]; PATH_BOX_ATTRS...)

    panel = Dict{Symbol, Button}(
        :layout     => Button(panelbtn_grid[1, 1]; merge(PANEL_ATTRS, Dict{Symbol, Any}(:label => "Layout"))...),
        :controller => Button(panelbtn_grid[1, 2]; merge(PANEL_ATTRS, Dict{Symbol, Any}(:label => "Controller"))...),
        :protocol   => Button(panelbtn_grid[1, 3]; merge(PANEL_ATTRS, Dict{Symbol, Any}(:label => "Protocol"))...),
        :console    => Button(panelbtn_grid[1, 4]; merge(PANEL_ATTRS, Dict{Symbol, Any}(:label => "Console"))...)
    )

    return (start_button=start, stop_button=stop, irf_path_textbox=irf_path, irf_button=irf_button,
            folder_path_textbox=folder_path, folder_button=folder_button, port_menu=port,
            connect_button=connect, info_label=label, mode_menu=mode, lifetimes_menu=lifetimes,
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
    draw_initial_plot_selections!(app, app_run, plot_1, plot_2)

Draw the initially-selected series (per `app.layout.plot1`/`.plot2`) onto
the two plot axes at GUI construction time.
"""
function draw_initial_plot_selections!(app, app_run, plot_1, plot_2)
    mapping = Dict(
        "Histogram"       => (app_run.hist_time, app_run.histogram),
        "Photon counts"   => (app_run.timestamps, app_run.photons),
        "Lifetime"        => (app_run.timestamps, app_run.lifetime),
        "Ion concentration" => (app_run.timestamps, app_run.concentration),
        "Command"         => (app_run.timestamps, app_run.command1)
    )

    selection_1 = app.layout.plot1
    selection_2 = app.layout.plot2

    plot_data_1 = get(mapping, selection_1, nothing)
    plot_data_2 = get(mapping, selection_2, nothing)

    function draw_selection!(axis, selection, series_data)
        if selection == "Command"
            lines!(axis, app_run.timestamps, app_run.command1, color=PLOT_COLOR_CH1)
            lines!(axis, app_run.timestamps, app_run.command2, color=PLOT_COLOR_CH2)
            return
        end

        if selection == "Lifetime"
            draw_lifetime_plot!(axis, app_run)
            return
        end

        if selection == "Histogram"
            draw_histogram_plot!(axis, app_run)
            return
        end

        if selection == "Ion concentration"
            draw_ion_concentration_plot!(axis, app_run)
            return
        end

        lines!(axis, series_data..., color=PLOT_COLOR_CH1)
    end

    draw_selection!(plot_1, selection_1, plot_data_1)
    draw_selection!(plot_2, selection_2, plot_data_2)

    return nothing
end

"""
make_gui(app, app_run)

Construct the Makie-based graphical user interface and return the
`Figure` object.  The function lays out the two plotting axes, control
buttons, text fields and panel buttons.  It does not attach event
handlers; that task is delegated to `make_handlers` in `handlers.jl`.

Arguments:
- `app` : persistent configuration (`AppState`)
- `app_run` : runtime data (`AppRun`)
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
    widgets = make_control_widgets!(grids.button_grid, grids.panelbtn_grid)

    apply_gui_layout_tweaks!(fig, grids)

    blocks = Dict{Symbol, Any}(
        :top_grid      => grids.top_grid,
        :right_grid    => grids.right_grid,
        :left_grid     => grids.left_grid,
        :button_grid   => grids.button_grid,
        :path_grid     => grids.path_grid,
        :panelbtn_grid => grids.panelbtn_grid,
        :panel_grid    => grids.panel_grid,
        :start_button  => widgets.start_button,
        :stop_button   => widgets.stop_button,
        :irf_path_textbox => widgets.irf_path_textbox,
        :irf_button    => widgets.irf_button,
        :folder_path_textbox => widgets.folder_path_textbox,
        :folder_button => widgets.folder_button,
        :port_menu     => widgets.port_menu,
        :connect_button => widgets.connect_button,
        :mode_menu     => widgets.mode_menu,
        :lifetimes_menu => widgets.lifetimes_menu,
        :panel_buttons => widgets.panel_buttons,
        :counts_axis   => axes.counts_axis,
        :plot_1_axis   => axes.plot_1,
        :plot_2_axis   => axes.plot_2,
        :save_progress_axis => axes.save_progress_axis,
        :info_label    => widgets.info_label
    )

    start_port_menu_refresher!(fig, widgets.port_menu, widgets.no_port_selected_label)
    draw_initial_plot_selections!(app, app_run, axes.plot_1, axes.plot_2)

    # Axis autoscaling is handled by plotting.jl's autoscale_values!/autoscale_plot_selection!
    # (called directly from consumer_loop on the axes stored in `blocks`).

    return fig, blocks
end
