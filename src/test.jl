using GLMakie
using Base.Threads
using Observables

mutable struct AppState
    channel::Union{Channel{Tuple{Float64,Float64}}, Nothing}
    worker_task::Union{Task, Nothing}
    consumer_task::Union{Task, Nothing}
    running::Threads.Atomic{Bool}
    lifetime::Observable{Vector{Float64}}
    timestamps::Observable{Vector{Float64}}
end

function make_app(; maxlen=500)
    app = AppState(nothing, nothing, nothing, Threads.Atomic{Bool}(false),
                   Observable(Float64[]), Observable(Float64[]))

    fig = Figure(resolution = (700,400))
    ax = Axis(fig[1,1])
    plt = lines!(ax, app.lifetime, app.timestamps)
    display(fig)

    start_btn = Button(fig[2,1], label="Start")
    stop_btn  = Button(fig[2,2], label="Stop")

    # Helper : (re)create channel + consumer
    function start_consumer!(app)
        # create channel if needed
        ch = Channel{Tuple{Float64,Float64}}(128)
        app.channel = ch

        # The consumer MUST be created on the main thread (here it is).
        app.consumer_task = @async begin
            try
                while true
                    x,y = take!(ch)           # bloquant jusqu'à production ou close
                    push!(app.lifetime[], x)
                    push!(app.timestamps[], y)
                    if length(app.lifetime[]) > maxlen
                        popfirst!(app.lifetime[])
                        popfirst!(app.timestamps[])
                    end
                    notify(app.lifetime)
                    notify(app.timestamps)
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

    on(start_btn.clicks) do _
        println("Start clicked")
        if app.running[] == false
            # Vérifications utiles
            @info "nthreads = $(Threads.nthreads()) (do `julia --threads N` si =1)"

            app.running[] = true
            # recréer channel + consumer
            start_consumer!(app)

            # lancer le worker sur un autre thread
            app.worker_task = Threads.@spawn begin
                @info "Worker started on thread $(threadid())"
                t = 0.0
                dt = 0.05
                ch = app.channel    # capture
                while app.running[]   # produit tant que flag true
                    t += dt
                    y = sin(2π*0.5*t) + 0.1*randn()
                    put!(ch, (t, y))
                    sleep(dt)
                end
                # Lorsque le worker s'arrête, ferme la channel pour débloquer consumer
                close(ch)
                @info "Worker finished and closed channel"
            end
        else
            @info "Already running"
        end
    end

    on(stop_btn.clicks) do _
        println("Stop clicked")
        if app.running[] == true
            app.running[] = false
            # wait (non-bloquant) for the worker to finish
            if app.worker_task !== nothing
                @async try
                    wait(app.worker_task)
                catch e
                    @warn "Worker error" e
                end
                app.worker_task = nothing
            end
            # consumer will exit when channel is closed by the worker
            app.channel = nothing
            app.consumer_task = nothing
        end
    end

    fig, app
end

fig, app = make_app()
