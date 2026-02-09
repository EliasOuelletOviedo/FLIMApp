using GLMakie
using Base.Threads
using Dates

include("attributes.jl")
include("handlers.jl")
include("functions.jl")

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

    counts = Observable{Float64}(0.0)
    hspan!(counts_axis, 1, counts, color = COLOR_4)

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
        :plot_2_axis   => plot_2
    )

    make_handlers(app, blocks)

    on(port.is_open) do is_open
        if is_open
            ports = list_ports()

            if isempty(ports)
                ports = ["No ports detected"]
            end
            
            port.options[] = ports
        end
    end
    
    global irf               = get_irf()
    global irf_bin_size      = get_irf_bin_size()
    global tcspc_window_size = round(irf[end, 1] + irf[2, 1], sigdigits=4)
    global fft_plan          = plan_fft(zeros(Float64, 256))
    global ifft_plan         = plan_ifft(zeros(Float64, 256))

    plt = lines!(plot_1, app_run.lifetime, app_run.timestamps)

    function start_consumer!(app_run)
        # create channel if needed
        ch = Channel{Tuple{Float64,Float64,UInt32}}(128)
        app_run.channel = ch

        # The consumer MUST be created on the main thread (here it is).
        app_run.consumer_task = @async begin
            try
                while true
                    x,y,i = take!(ch)           # bloquant jusqu'à production ou close
                    push!(app_run.lifetime[], x)
                    push!(app_run.timestamps[], y)
                    app_run.i[] = i
                    counts[] = app_run.timestamps[][end]
                    notify(app_run.lifetime)
                    notify(app_run.timestamps)
                    notify(app_run.i)
                    notify(counts)
                end
            catch e
                # take! lève InvalidStateException si channel fermé et vide -> sortie propre
                if isa(e, InvalidStateException)
                    @info "Consumer: channel closed, exiting consumer."
                else
                    rethrow(e)
                end
            end
        end
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

    function start_autoscaler!(app, app_run, plot_1=plot_1, plot_2=plot_2)
        @async begin
            while app_run.running[]
                try
                    xs = copy(app_run.lifetime[])      # copy pour éviter race sur lecture
                    ys = copy(app_run.timestamps[])
                    apply_autoscale!(app, plot_1, xs, ys; pad_ratio=0.08)
                catch e
                    @warn "Autoscaler erreur" e
                end
                sleep(0.1)
            end
        end
    end

    function start_infos!(app_run, label)
        @async begin
            last_i = UInt32(0)
            while app_run.running[]
                try
                    i = app_run.i[]
                    if i != last_i
                        di = i - last_i
                        last_i = i
                        label.text[] = "Frequency: $di Hz"
                    end
                catch e
                    @warn "Infos erreur" e
                end
                sleep(1)
            end
        end
    end

    # Tâche périodique sur le MAIN thread qui ajuste les limites toutes les 0.1 s

    on(start.clicks) do _
        println("Start clicked")
        if app_run.running[] == false

            # Vérifications utiles
            @info "nthreads = $(Threads.nthreads()) (do `julia --threads N` si =1)"

            app_run.running[] = true
            # recréer channel + consumer
            start_consumer!(app_run)
            start_autoscaler!(app, app_run)
            start_infos!(app_run, label)
            
            app_run.worker_task = @spawn test(app_run.channel, app_run.running; dt=0.05)
        else
            @info "Already running"
        end
    end

    on(stop.clicks) do _
        println("Stop clicked")

        if app_run.running[] == true
            app_run.running[] = false

            if app_run.worker_task !== nothing
                task = app_run.worker_task
                app_run.worker_task = nothing

                @async try
                    wait(task)
                catch e
                    # @warn "Worker error" e
                end
            end
        end
    end

    return fig
end

# gui

# gui = make_gui()
# display(gui.fig)