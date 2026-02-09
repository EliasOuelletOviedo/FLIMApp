using Serialization
using Observables
using ZipFile

JULIA_NUM_THREADS = 2

mutable struct AppState
    dark::Bool
    current_panel::Symbol
    layout::Dict{Symbol, Any}
    controller::Dict{Symbol, Any}
    # protocol::Dict{Symbol, Any}
    # console::Dict{Symbol, Any}
end

mutable struct AppRun
    channel::Union{Channel{Tuple{Float64,Float64,UInt32}}, Nothing}
    worker_task::Union{Task, Nothing}
    consumer_task::Union{Task, Nothing}
    running::Threads.Atomic{Bool}
    lifetime::Observable{Vector{Float64}}
    timestamps::Observable{Vector{Float64}}
    i::Observable{UInt32}
end

dark = true

current_panel = :layout

layout = Dict{Symbol, Any}(
    :time_range => 60,
    :binning    => 1,
    :smoothing  => 0,
    :plot1      => "Lifetime",
    :plot2      => "Ion concentration"
)

controller = Dict{Symbol, Any}(
    :ch1_inv => false,
    :ch1_on  => false,
    :ch1_out => "Out 1",
    :ch1_mode=> "Digital",
    :P1         => 0,
    :I1         => 0,
    :D1         => 0,
    :ch2_inv => false,
    :ch2_on  => false,
    :ch2_out => "Out 2",
    :ch2_mode=> "Digital",
    :P2         => 0,
    :I2         => 0,
    :D2         => 0,
)

include("GUI.jl")

const STATE_FILE = joinpath("docs", "AppState.jls")

mkpath(dirname(STATE_FILE))

function save_state(state::AppState; path::AbstractString=STATE_FILE)
    open(path, "w") do io
        serialize(io, state)
    end
end

function load_state(path::AbstractString=STATE_FILE)
    open(path, "r") do io
        return deserialize(io)
    end
end

export AppState

function run_app()
    app = nothing

    try
        app = load_state()
    catch
        app = AppState(dark,
                       current_panel,
                       layout,
                       controller)

        save_state(app)
    end

    app_run = AppRun(nothing,
                     nothing,
                     nothing,
                     Threads.Atomic{Bool}(false),
                     Observable(Float64[]),
                     Observable(Float64[]),
                     Observable{UInt32}(0)
    )

    gui = make_gui(app, app_run)
    display(gui)
end

run_app()
