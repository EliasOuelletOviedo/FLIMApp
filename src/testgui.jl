using GLMakie

include("attributes.jl")



function make_gui(app; dark = true)
    if dark
        set_theme!(;DARK_MODE[:theme]...)
    else
        set_theme!(;LIGHT_MODE[:theme]...)
    end

    fig = Figure(size = (1440, 847), figure_padding = 0)

    top_grid   = GridLayout(fig[1, 1:2], width = 1440, height = 24)
    left_grid  = GridLayout(fig[2, 1],   width = 300,  height = 823)
    right_grid = GridLayout(fig[2, 2],   width = 1140, height = 823)

    button_grid   = GridLayout(left_grid[2, 2])
    path_grid     = GridLayout(left_grid[3, 2])
    panelbtn_grid = GridLayout(left_grid[4, 2])
    panel_grid    = GridLayout(left_grid[5, 2])

    Box(top_grid[1, 1:5];     merge(BOX_ATTRS, Dict{Symbol, Any}(:color => COLOR_3,      :strokewidth => 0.2))...)
    Box(left_grid[1:6, 1:3];  merge(BOX_ATTRS, Dict{Symbol, Any}(:color => COLOR_1,      :strokewidth => 0.2))...)
    Box(right_grid[1:5, 1:5]; merge(BOX_ATTRS, Dict{Symbol, Any}(:color => :transparent, :strokewidth => 0.2))...)
    Box(left_grid[5, 2];      merge(BOX_ATTRS, Dict{Symbol, Any}(:color => COLOR_2,      :height => 400, :strokewidth => 0))...)
    Box(left_grid[4:5, 2];    merge(BOX_ATTRS, Dict{Symbol, Any}(:strokewidth => 0.3))...)

    # menu_btn = Dict{Symbol, Any}(
    #     :file   => Menu(top_grid[1, 1]; merge(MENU_ATTRS, Dict{Symbol, Any}(:options => ["File"]))...),
    #     :edit   => Menu(top_grid[1, 2]; merge(MENU_ATTRS, Dict{Symbol, Any}(:options => ["Edit"]))...),
    #     :view   => Menu(top_grid[1, 3]; merge(MENU_ATTRS, Dict{Symbol, Any}(:options => ["View"]))...),
    #     :help   => Menu(top_grid[1, 4]; merge(MENU_ATTRS, Dict{Symbol, Any}(:options => ["Help"]))...),
    # )

    Box(button_grid[1, 1]; merge(BOX_ATTRS, Dict{Symbol, Any}(:cornerradius => BUTTON_ATTRS[:cornerradius]))...)
    Box(button_grid[1, 2]; merge(BOX_ATTRS, Dict{Symbol, Any}(:cornerradius => BUTTON_ATTRS[:cornerradius]))...)

    start = Button(button_grid[1, 1]; merge(BUTTON_ATTRS, Dict{Symbol, Any}(:label => "START"))...)
    stop =  Button(button_grid[1, 2]; merge(BUTTON_ATTRS, Dict{Symbol, Any}(:label => "CLEAR"))...)

    panel = Dict{Symbol, Button}(
        :layout     => Button(panelbtn_grid[1, 1]; merge(PANEL_ATTRS, Dict{Symbol, Any}(:label => "Layout"))...),
        :controller => Button(panelbtn_grid[1, 2]; merge(PANEL_ATTRS, Dict{Symbol, Any}(:label => "Controller"))...),
        :protocol   => Button(panelbtn_grid[1, 3]; merge(PANEL_ATTRS, Dict{Symbol, Any}(:label => "Protocol"))...),
        :console    => Button(panelbtn_grid[1, 4]; merge(PANEL_ATTRS, Dict{Symbol, Any}(:label => "Console"))...)
    )

    current_panel = Observable{Symbol}(:controller)

    counts = Axis(right_grid[2:3, 2]; merge(AXIS_COUNTS_ATTRS, Dict{Symbol, Any}(
        :width  => 40,
        :height => nothing,
        :ylabel => "Photon count",
        :yscale => log10,
        :limits => (nothing, (1, 1e7))
    ))...)

    plot_1 = Axis(right_grid[2, 4]; merge(AXIS_PLOTS_ATTRS, Dict{Symbol, Any}(:height => 320, :title =>"Plot 1", :width => 840))...)
    plot_2 = Axis(right_grid[3, 4]; merge(AXIS_PLOTS_ATTRS, Dict{Symbol, Any}(:height => 320, :title =>"Plot 2", :width => 840))...)

    hspan!(counts, 1, 10000)

    rowgap!(left_grid, 4, 0)
    rowgap!(fig.layout, 1, 0)
    colgap!(fig.layout, 1, 0)
    colgap!(panelbtn_grid, -1)
    colsize!(right_grid, 1, 40)
    colsize!(right_grid, 5, 40)

    return (
        app = app,
        fig = fig,
        start = start,
        stop  = stop,
        panel = panel,
        current_panel = current_panel,
        panel_grid = panel_grid,
        counts = counts,
        plot_1 = plot_1,
        plot_2 = plot_2,
    )
end

include("testhandlers.jl")

# gui

# gui = make_gui()
# display(gui.fig)