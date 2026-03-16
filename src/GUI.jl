"""
GUI.jl

Makie-based graphical user interface for the FLIM application.

Implements:
- Main figure layout with grid system
- Plotting axes for histograms, lifetimes, and ion concentration
- Control panels (Layout, Controller, Protocol, Console)
- Interactive widgets (buttons, text boxes, menus, spinners)
- Theme-aware styling and colors

The make_gui() function constructs and configures all GUI elements.
The make_handlers() function (in handlers.jl) attaches event callbacks.
"""

using GLMakie
using Base.Threads
using Dates


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
        set_theme!(;DARK_MODE[:theme]...)
    else
        set_theme!(;LIGHT_MODE[:theme]...)
    end

    fig = Figure(size = (1440, 847), figure_padding = 0)

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

    ################    LEFT GRID    ################

    counts_axis = Axis(left_grid[2:3, 2]; AXIS_COUNTS_ATTRS...)

    plot_1 = Axis(left_grid[2, 4]; merge(AXIS_PLOTS_ATTRS, Dict{Symbol, Any}(:title =>"Plot 1\n($(app.layout[:plot1]))"))...)
    plot_2 = Axis(left_grid[3, 4]; merge(AXIS_PLOTS_ATTRS, Dict{Symbol, Any}(:title =>"Plot 2\n($(app.layout[:plot2]))"))...)

    hspan!(counts_axis, 1, app_run.counts, color = COLOR_4)

    ################    RIGHT GRID    ################

    start = Button(button_grid[1, 1]; merge(BUTTON_ATTRS, Dict{Symbol, Any}(:label => "START"))...)
    stop  = Button(button_grid[1, 2]; merge(BUTTON_ATTRS, Dict{Symbol, Any}(:label => "CLEAR"))...)

    irf_path      = Textbox(button_grid[2, 1:2]; merge(PATH_TEXT_ATTRS, Dict{Symbol, Any}(:placeholder => "IRF path"))...)
    folder_path   = Textbox(button_grid[3, 1:2]; merge(PATH_TEXT_ATTRS, Dict{Symbol, Any}(:placeholder => "Folder path"))...)
    irf_button    = Button(button_grid[2, 1:2];  PATH_BUTTON_ATTRS...)
    folder_button = Button(button_grid[3, 1:2];  PATH_BUTTON_ATTRS...)

    ports = list_ports()

    if isempty(ports)
        ports = ["No ports detected"]
    end

    port = Menu(button_grid[4, 1]; merge(MENU_ATTRS, Dict{Symbol, Any}(:options => ports))...)

    Box(button_grid[2, 1:2]; PATH_BOX_ATTRS...)
    Box(button_grid[3, 1:2]; PATH_BOX_ATTRS...)

    panel = Dict{Symbol, Button}(
        :layout     => Button(panelbtn_grid[1, 1]; merge(PANEL_ATTRS, Dict{Symbol, Any}(:label => "Layout"))...),
        :controller => Button(panelbtn_grid[1, 2]; merge(PANEL_ATTRS, Dict{Symbol, Any}(:label => "Controller"))...),
        :protocol   => Button(panelbtn_grid[1, 3]; merge(PANEL_ATTRS, Dict{Symbol, Any}(:label => "Protocol"))...),
        :console    => Button(panelbtn_grid[1, 4]; merge(PANEL_ATTRS, Dict{Symbol, Any}(:label => "Console"))...)
    )

    label = Label(button_grid[5, 1], "test")

    rowgap!(right_grid, 5, 0)
    rowgap!(fig.layout, 1, 0)
    colgap!(fig.layout, 1, 0)
    colgap!(panelbtn_grid, -1)
    colsize!(left_grid, 1, 32)
    colsize!(left_grid, 5, 32)

    blocks = Dict{Symbol, Any}(
        :top_grid      => top_grid,
        :right_grid    => right_grid,
        :left_grid     => left_grid,
        :button_grid   => button_grid,
        :path_grid     => path_grid,
        :panelbtn_grid => panelbtn_grid,
        :panel_grid    => panel_grid,
        :start_button  => start,
        :stop_button   => stop,
        :panel_buttons => panel,
        :counts_axis   => counts_axis,
        :plot_1_axis   => plot_1,
        :plot_2_axis   => plot_2,
        :info_label    => label
    )

    plt1 = nothing
    plt2 = nothing

    mapping = Dict(
        "Histogram"       => (app_run.hist_time, app_run.histogram),
        "Photon counts"   => (app_run.timestamps, app_run.photons),
        "Lifetime"        => (app_run.timestamps, app_run.lifetime),
        "Ion concentration" => (app_run.timestamps, app_run.concentration),
        "Command"         => (app_run.timestamps, app_run.i)
    )

    selection1 = app.layout[:plot1]
    selection2 = app.layout[:plot2]

    xy1 = get(mapping, selection1, nothing)
    xy2 = get(mapping, selection2, nothing)

    lines!(plot_1, xy1..., color=Makie.wong_colors()[1])
    lines!(plot_2, xy2..., color=Makie.wong_colors()[1])

    if selection1 == "Histogram"
        lines!(plot_1, app_run.hist_time, app_run.fit, color=Makie.wong_colors()[6])
    end

    if selection2 == "Histogram"
        lines!(plot_2, app_run.hist_time, app_run.fit, color=Makie.wong_colors()[6])
    end

    function apply_autoscale!(app, ax, xs::Vector{Float64}, ys::Vector{Float64}; pad_ratio=0.05)
        if isempty(xs) || isempty(ys)
            return
        end

        time_range = app.layout[:time_range]

        # enlever NaN
        xs = xs[.!isnan.(ys)]
        ys = ys[.!isnan.(ys)]

        xmin, xmax = minimum(xs), maximum(xs)
        ymin, ymax = minimum(ys), maximum(ys)

        if xmax < time_range
            xmax = time_range
        end

        if xmax - xmin > time_range
            xmin = xmax - time_range
            ymin = minimum(ys[xs .>= xmin])
        end

        # éviter zero-range (si tous les xs identiques)
        if xmin == xmax
            xmin -= 0.5
            xmax += 0.5
        end
        if ymin == ymax
            ymin -= 0.5
            ymax += 0.5
        end

        # padding relatif
        xpad = (xmax - xmin) * pad_ratio
        ypad = (ymax - ymin) * pad_ratio

        xlims!(ax, xmin - xpad, xmax + xpad)
        ylims!(ax, ymin - ypad, ymax + ypad)
    end

    function apply_autoscale!(app, ax, xs::Vector{Int64}, ys::Vector{Float64}; pad_ratio=0.05)
        autolimits!(ax)
    end

    return fig, blocks
end
