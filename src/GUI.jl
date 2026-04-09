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
    cached_basename(cache_path::AbstractString; fallback_path::Union{Nothing, AbstractString}=nothing)::String

Read a cached full path and return only the filename/folder name for UI display.
Falls back to `fallback_path` when cache is missing or empty.
"""
function cached_basename(cache_path::AbstractString; fallback_path::Union{Nothing, AbstractString}=nothing)::String
    path_value = ""

    if isfile(cache_path)
        path_value = try
            strip(open(f -> read(f, String), cache_path))
        catch
            ""
        end
    end

    if isempty(path_value) && fallback_path !== nothing
        path_value = strip(String(fallback_path))
    end

    if isempty(path_value)
        return ""
    end

    return splitpath(path_value)[end]
end

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

    initial_irf_name = cached_basename(IRF_FILEPATH_CACHE)
    initial_folder_name = cached_basename(FOLDERPATH_CACHE; fallback_path=get_data_root_path())
    irf_path      = Textbox(button_grid[2, 1:2]; merge(PATH_TEXT_ATTRS, Dict{Symbol, Any}(:placeholder => "IRF path", :displayed_string => initial_irf_name, :stored_string => initial_irf_name))...)
    folder_path   = Textbox(button_grid[3, 1:2]; merge(PATH_TEXT_ATTRS, Dict{Symbol, Any}(:placeholder => "Folder path", :displayed_string => initial_folder_name, :stored_string => initial_folder_name))...)
    irf_button    = Button(button_grid[2, 1:2];  PATH_BUTTON_ATTRS...)
    folder_button = Button(button_grid[3, 1:2];  PATH_BUTTON_ATTRS...)

    NO_PORT_SELECTED_LABEL = "No port selected"

    initial_port_options = port_options(NO_PORT_SELECTED_LABEL)
    port = Menu(button_grid[4, 1]; merge(MENU_ATTRS, Dict{Symbol, Any}(:options => initial_port_options, :default => 1))...)

    connect = Button(button_grid[4, 2]; merge(BUTTON_ATTRS, Dict{Symbol, Any}(:label => "CONNECT"))...)

    label = Label(button_grid[5, 1], "Frequency: -- Hz\nFile: --"; merge(LABEL_ATTRS, Dict{Symbol, Any}(:justification => :left, :halign => :left, :tellwidth => false))...)

    mode = Menu(button_grid[6, 1]; merge(MENU_ATTRS, Dict{Symbol, Any}(:options => ["Playback", "Realtime"]))...)
    lifetimes = Menu(button_grid[6, 2]; merge(MENU_ATTRS, Dict{Symbol, Any}(:options => ["1 lifetime", "2 lifetimes", "3 lifetimes"]))...)

    Box(button_grid[2, 1:2]; PATH_BOX_ATTRS...)
    Box(button_grid[3, 1:2]; PATH_BOX_ATTRS...)

    panel = Dict{Symbol, Button}(
        :layout     => Button(panelbtn_grid[1, 1]; merge(PANEL_ATTRS, Dict{Symbol, Any}(:label => "Layout"))...),
        :controller => Button(panelbtn_grid[1, 2]; merge(PANEL_ATTRS, Dict{Symbol, Any}(:label => "Controller"))...),
        :protocol   => Button(panelbtn_grid[1, 3]; merge(PANEL_ATTRS, Dict{Symbol, Any}(:label => "Protocol"))...),
        :console    => Button(panelbtn_grid[1, 4]; merge(PANEL_ATTRS, Dict{Symbol, Any}(:label => "Console"))...)
    )

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
        :irf_path_textbox => irf_path,
        :irf_button    => irf_button,
        :folder_path_textbox => folder_path,
        :folder_button => folder_button,
        :port_menu     => port,
        :connect_button => connect,
        :mode_menu     => mode,
        :lifetimes_menu => lifetimes,
        :panel_buttons => panel,
        :counts_axis   => counts_axis,
        :plot_1_axis   => plot_1,
        :plot_2_axis   => plot_2,
        :info_label    => label
    )

    @async begin
        was_open = false

        while true
            is_window_open = isopen(fig.scene)

            if is_window_open
                was_open = true
                refresh_port_menu!(port; no_port_label=NO_PORT_SELECTED_LABEL)
            elseif was_open
                break
            end

            sleep(1.0)
        end
    end

    mapping = Dict(
        "Histogram"       => (app_run.hist_time, app_run.histogram),
        "Photon counts"   => (app_run.timestamps, app_run.photons),
        "Lifetime"        => (app_run.timestamps, app_run.lifetime),
        "Ion concentration" => (app_run.timestamps, app_run.concentration),
        "Command"         => (app_run.timestamps, app_run.command1)
    )

    selection_1 = app.layout[:plot1]
    selection_2 = app.layout[:plot2]

    plot_data_1 = get(mapping, selection_1, nothing)
    plot_data_2 = get(mapping, selection_2, nothing)

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

    lifetime_x1, lifetime_y1 = aligned_xy_observables(app_run.timestamps, app_run.lifetime)
    smooth_x1, smooth_y1 = aligned_xy_observables(app_run.timestamps, app_run.lifetime_smooth)
    protocol_x1, protocol_y1 = aligned_xy_observables(app_run.timestamps, app_run.protocol_setpoint)

    lifetime_x2, lifetime_y2 = aligned_xy_observables(app_run.timestamps, app_run.lifetime)
    smooth_x2, smooth_y2 = aligned_xy_observables(app_run.timestamps, app_run.lifetime_smooth)
    protocol_x2, protocol_y2 = aligned_xy_observables(app_run.timestamps, app_run.protocol_setpoint)

    function draw_selection!(axis, selection, series_data, lifetime_x, lifetime_y, smooth_x, smooth_y, protocol_x, protocol_y)
        if selection == "Command"
            lines!(axis, app_run.timestamps, app_run.command1, color=Makie.wong_colors()[1])
            lines!(axis, app_run.timestamps, app_run.command2, color=Makie.wong_colors()[2])
            return
        end

        if selection == "Lifetime"
            add_protocol_setpoint_highlight!(axis, app_run)
            lines!(axis, lifetime_x, lifetime_y, color=Makie.wong_colors()[1])
            lines!(axis, smooth_x, smooth_y, color=Makie.wong_colors()[3])
            lines!(axis, protocol_x, protocol_y, color=Makie.wong_colors()[2])
            return
        end

        lines!(axis, series_data..., color=Makie.wong_colors()[1])

        if selection == "Histogram"
            lines!(axis, app_run.hist_time, app_run.fit, color=Makie.wong_colors()[6])
            lines!(axis, app_run.hist_time, lift(f -> normalized_irf_from_fit(f), app_run.fit), color=Makie.wong_colors()[3])
        end
    end

    draw_selection!(plot_1, selection_1, plot_data_1, lifetime_x1, lifetime_y1, smooth_x1, smooth_y1, protocol_x1, protocol_y1)
    draw_selection!(plot_2, selection_2, plot_data_2, lifetime_x2, lifetime_y2, smooth_x2, smooth_y2, protocol_x2, protocol_y2)

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
