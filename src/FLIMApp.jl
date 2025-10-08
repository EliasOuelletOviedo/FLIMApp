module FLIMApp

using GLMakie        # GUI + plotting backend
using Observables    # Observable containers (Makie usually re-exports, but safe to import)
using Base.Threads

const TARGET_FPS = 30
const FRAME_PERIOD = 1.0 / TARGET_FPS

# -----------------------
# App-wide state type
# -----------------------

mutable struct AppState
    dark::Threads.Atomic{Bool}
    running::Threads.Atomic{Bool}    # atomic boolean to start/stop producer threads
    data_ch::Channel{Vector{Float64}}# channel used to send computed arrays to GUI
    npoints::Int                     # length of arrays used for plotting
end

# include implementation files (they are evaluated inside this module)
include("functions.jl")  # defines producer_loop!(...)
include("GUI.jl")        # defines build_gui(...)

export run_app, AppState

"Start the GUI and return the Figure object. Call `run_app()` from REPL/main."
function run_app()
    npoints = 200
    app = AppState(Threads.Atomic{Bool}(true), Threads.Atomic{Bool}(false), Channel{Vector{Float64}}(8), npoints)

    fig, ys_obs, start_btn = build_gui(app)   # build GUI (from GUI.jl)

    @async begin
        last_time = time()
        latest = zeros(app.npoints)

        while isopen(app.data_ch)
            newdata = take!(app.data_ch)
            latest .= newdata
            now = time()

            if now - last_time >= FRAME_PERIOD
                ys_obs[] = copy(latest)
                notify(ys_obs)
                
                last_time = time()
            end

        end
    end

    return fig, app
end

end # module
