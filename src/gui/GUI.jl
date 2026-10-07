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

Create the counts bar and the Plot 1 / Plot 2 axes. Returns a NamedTuple
of the created axes.
"""
function make_plot_axes!(left_grid, app, app_run)
    counts_axis = Axis(left_grid[2:3, 2]; AXIS_COUNTS_ATTRS...)

    plot_1 = Axis(left_grid[2, 4]; merge(AXIS_PLOTS_ATTRS, Dict{Symbol, Any}(:title =>"Plot 1\n($(app.layout.plot1))"))...)
    plot_2 = Axis(left_grid[3, 4]; merge(AXIS_PLOTS_ATTRS, Dict{Symbol, Any}(:title =>"Plot 2\n($(app.layout.plot2))"))...)

    for (series, color) in ((app_run.ch1, PLOT_COLOR_CH1), (app_run.ch2, PLOT_COLOR_CH2))
        hspan!(counts_axis, 1, series.counts, color = (color, 0.1))
        hlines!(counts_axis, series.counts, color = color, linewidth = PLOT_LINEWIDTH)
    end

    return (counts_axis=counts_axis, plot_1=plot_1, plot_2=plot_2)
end

"""
    make_control_widgets!(button_grid, panelbtn_grid, app_run)

Create the START/CLEAR buttons, the IRF path, recording-folder and
Playback session-folder controls, DAQ status label + CONNECT button, info
label and Playback frequency box, mode/lifetimes menus, and the panel
switch buttons. Returns a NamedTuple of the created widgets.
"""
function make_control_widgets!(button_grid, panelbtn_grid, app_run)
    start = Button(button_grid[1, 1]; merge(BUTTON_ATTRS, Dict{Symbol, Any}(:label => "START"))...)
    stop  = Button(button_grid[1, 2]; merge(BUTTON_ATTRS, Dict{Symbol, Any}(:label => "CLEAR"))...)

    initial_irf_name = cached_basename(irf_filepath_cache())
    initial_record_name = basename(rstrip(FLIMCore.dossier_spc(app_run.spc.settings), ['/', '\\']))
    initial_folder_name = cached_basename(session_folder_cache())
    irf_path      = Textbox(button_grid[2, 1:2]; merge(PATH_TEXT_ATTRS, Dict{Symbol, Any}(:placeholder => "IRF (.toml, Single .csv or .sdt)", :displayed_string => initial_irf_name, :stored_string => initial_irf_name))...)
    record_path   = Textbox(button_grid[3, 1:2]; merge(PATH_TEXT_ATTRS, Dict{Symbol, Any}(:placeholder => "Recording folder", :displayed_string => initial_record_name, :stored_string => initial_record_name))...)
    folder_path   = Textbox(button_grid[4, 1:2]; merge(PATH_TEXT_ATTRS, Dict{Symbol, Any}(:placeholder => "Session to replay (Playback)", :displayed_string => initial_folder_name, :stored_string => initial_folder_name))...)
    irf_button    = Button(button_grid[2, 1:2];  PATH_BUTTON_ATTRS...)
    record_button = Button(button_grid[3, 1:2];  PATH_BUTTON_ATTRS...)
    folder_button = Button(button_grid[4, 1:2];  PATH_BUTTON_ATTRS...)

    daq_label = Label(button_grid[5, 1], loop_status_text(LoopStatus(LOOP_DISCONNECTED, "")); merge(LABEL_ATTRS, Dict{Symbol, Any}(:justification => :left, :halign => :left, :tellwidth => false))...)
    connect = Button(button_grid[5, 2]; merge(BUTTON_ATTRS, Dict{Symbol, Any}(:label => "CONNECT"))...)

    label = Label(button_grid[6, 1], "Frame rate: -- Hz\nFrame: --"; merge(LABEL_ATTRS, Dict{Symbol, Any}(:justification => :left, :halign => :left, :tellwidth => false))...)
    # Playback speed: the target pass rate (Hz); 0 = the experiment's own pace (1×).
    target_freq = Textbox(button_grid[6, 2]; merge(SPINNER_TEXT_ATTRS, Dict{Symbol, Any}(:placeholder => "Frequency (Hz), 0 = 1×", :displayed_string => "0", :stored_string => "0", :validator => make_float_range_validator(0.0, 1.0e6)))...)
    # Offline (no driver on this computer): Playback first, Realtime refused at START.
    default_mode = isempty(app_run.offline) ? "Realtime" : PLAYBACK_SESSION_MODE
    mode = Menu(button_grid[7, 1]; merge(MENU_ATTRS, Dict{Symbol, Any}(:options => RUN_MODES, :default => default_mode))...)
    lifetimes = Menu(button_grid[7, 2]; merge(MENU_ATTRS, Dict{Symbol, Any}(:options => ["1 lifetime", "2 lifetimes", "3 lifetimes"]))...)

    Box(button_grid[2, 1:2]; PATH_BOX_ATTRS...)
    Box(button_grid[3, 1:2]; PATH_BOX_ATTRS...)
    Box(button_grid[4, 1:2]; PATH_BOX_ATTRS...)

    panel = Dict{Symbol, Button}(
        :layout     => Button(panelbtn_grid[1, 1]; merge(PANEL_ATTRS, Dict{Symbol, Any}(:label => "Layout"))...),
        :controller => Button(panelbtn_grid[1, 2]; merge(PANEL_ATTRS, Dict{Symbol, Any}(:label => "Controller"))...),
        :protocol   => Button(panelbtn_grid[1, 3]; merge(PANEL_ATTRS, Dict{Symbol, Any}(:label => "Protocol"))...),
        :console    => Button(panelbtn_grid[1, 4]; merge(PANEL_ATTRS, Dict{Symbol, Any}(:label => "Console"))...)
    )

    return (start_button=start, stop_button=stop, irf_path_textbox=irf_path, irf_button=irf_button,
            record_path_textbox=record_path, record_button=record_button,
            folder_path_textbox=folder_path, folder_button=folder_button, daq_label=daq_label,
            connect_button=connect, info_label=label, target_freq_textbox=target_freq,
            mode_menu=mode, lifetimes_menu=lifetimes, panel_buttons=panel)
end

"""
    make_top_bar_widgets!(top_grid, app_run)

The top bar: the SPC engine's status line (the offline banner, cards, CFD
rates, last error — kept current by the refresh tick through
`app_run.spc.status`) and the SPC button that opens the SPC window
(gui/spc_window.jl).
"""
function make_top_bar_widgets!(top_grid, app_run)
    spc_label = Label(top_grid[1, 1:4], app_run.spc.status; merge(LABEL_ATTRS, Dict{Symbol, Any}(
        :halign => :left, :justification => :left, :tellwidth => false, :padding => (8, 0, 0, 0)))...)
    spc_button = Button(top_grid[1, 5]; merge(PANEL_ATTRS, Dict{Symbol, Any}(:label => "SPC", :width => 64))...)
    return (spc_label=spc_label, spc_button=spc_button)
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
    widgets = make_control_widgets!(grids.button_grid, grids.panelbtn_grid, app_run)
    top_bar = make_top_bar_widgets!(grids.top_grid, app_run)

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
        irf_path_textbox    = widgets.irf_path_textbox,
        irf_button          = widgets.irf_button,
        record_path_textbox = widgets.record_path_textbox,
        record_button       = widgets.record_button,
        folder_path_textbox = widgets.folder_path_textbox,
        folder_button       = widgets.folder_button,
        daq_label           = widgets.daq_label,
        connect_button      = widgets.connect_button,
        mode_menu           = widgets.mode_menu,
        lifetimes_menu      = widgets.lifetimes_menu,
        panel_buttons       = widgets.panel_buttons,
        info_label          = widgets.info_label,
        target_freq_textbox = widgets.target_freq_textbox,
        spc_label           = top_bar.spc_label,
        spc_button          = top_bar.spc_button,
        counts_axis         = axes.counts_axis,
        plot_1_axis         = axes.plot_1,
        plot_2_axis         = axes.plot_2
    )

    draw_initial_plots!(app, app_run, blocks)

    # Curves and axis limits are kept current by the refresh tick
    # (refresh.jl), started by run_app once the window is shown.

    return fig, blocks
end
