"""
data_types.jl

Core data structures for the FLIM application.

This module defines the primary structures for application state:
- AppState: Persistent configuration that is serialized to disk
- AppRun: Runtime transient state with observables and background tasks
"""

using Observables
using Base.Threads

# =============================================================================
# PERSISTENT APPLICATION STATE
# =============================================================================

"""
    AppState

Persistent configuration state that can be serialized to disk.

Fields:
- `dark::Bool` - Dark mode toggle (true for dark, false for light)
- `current_panel::Symbol` - Currently active UI panel (:layout, :controller, :protocol, :console)
- `layout::Dict{Symbol, Any}` - Layout and display settings
- `controller::Dict{Symbol, Any}` - Hardware controller configuration
- `protocol::Dict{Symbol, Any}` - Experimental protocol settings
- `console::Dict{Symbol, Any}` - Console and logging settings

This structure is serialized to `STATE_FILE_PATH` to preserve user preferences
across application sessions.
"""
mutable struct AppState
    dark::Bool
    current_panel::Symbol
    layout::Dict{Symbol, Any}
    controller::Dict{Symbol, Any}
    protocol::Dict{Symbol, Any}
    console::Dict{Symbol, Any}
end

"""
    AppState(use_dark::Bool)

Constructor creating AppState with default values.

Args:
- `use_dark::Bool` - Initialize with dark theme if true

Returns:
- AppState with all settings initialized to defaults
"""
function AppState(use_dark::Bool)
    return AppState(
        use_dark,
        :layout,
        get_default_layout(),
        get_default_controller(),
        get_default_protocol(),
        get_default_console()
    )
end

# =============================================================================
# RUNTIME APPLICATION STATE
# =============================================================================

"""
    AppRun

Runtime state for the application. This structure holds references to
background tasks, communication channels, and observables that update
during execution. It is NOT serialized.

Fields:
- `channel::Union{Channel, Nothing}` - Communication channel for worker->consumer data
- `running::Threads.Atomic{Bool}` - Flag controlling background task lifetime
- `worker_task::Union{Task, Nothing}` - Background worker processing task
- `consumer_task::Union{Task, Nothing}` - Data consumer and GUI update task
- `autoscaler_task::Union{Task, Nothing}` - Periodic axis autoscaling task
- `infos_task::Union{Task, Nothing}` - Periodic info/status update task
- `histogram::Observable{Vector{Float64}}` - Current histogram data
- `fit::Observable{Vector{Float64}}` - Fitted decay curve
- `photons::Observable{Vector{Float64}}` - Time-series of photon counts
- `counts::Observable{Float64}` - Current photon count
- `lifetime::Observable{Vector{Float64}}` - Time-series of fitted lifetimes
- `concentration::Observable{Vector{Float64}}` - Time-series of ion concentrations
- `command1::Observable{Vector{Float64}}` - Time-series of PID command values (controller 1)
- `command2::Observable{Vector{Float64}}` - Time-series of PID command values (controller 2)
- `timestamps::Observable{Vector{Float64}}` - Time-series timestamps
- `i::Observable{UInt32}` - Current frame/iteration counter
- `hist_time::Observable{Vector{Int64}}` - Histogram time-axis values
"""
mutable struct AppRun
    channel::Union{Channel{Tuple{Vector{Float64},Vector{Float64},Float64,Float64,Float64,Float64,Float64,Float64,Float64,UInt32}}, Nothing}
    running::Threads.Atomic{Bool}
    worker_task::Union{Task, Nothing}
    consumer_task::Union{Task, Nothing}
    autoscaler_task::Union{Task, Nothing}
    infos_task::Union{Task, Nothing}
    serial_task::Union{Task, Nothing}
    serial_conn::Union{Any, Nothing}
    histogram::Observable{Vector{Float64}}
    fit::Observable{Vector{Float64}}
    photons::Observable{Vector{Float64}}
    counts::Observable{Float64}
    lifetime::Observable{Vector{Float64}}
    concentration::Observable{Vector{Float64}}
    command1::Observable{Vector{Float64}}
    command2::Observable{Vector{Float64}}
    timestamps::Observable{Vector{Float64}}
    i::Observable{UInt32}
    hist_time::Observable{Vector{Int64}}
end

"""
    AppRun()

Constructor creating AppRun with initialized observables and null task references.

Returns:
- AppRun with all observables initialized to empty vectors/defaults,
  all tasks set to nothing, and channel set to nothing
"""
function AppRun()
    return AppRun(
        nothing,
        Threads.Atomic{Bool}(false),
        nothing,
        nothing,
        nothing,
        nothing,
        nothing,
        nothing,
        Observable(zeros(Float64, DEFAULT_HISTOGRAM_RESOLUTION)),
        Observable(zeros(Float64, DEFAULT_HISTOGRAM_RESOLUTION)),
        Observable(Float64[]),
        Observable(0.0),
        Observable(Float64[]),
        Observable(Float64[]),
        Observable(Float64[]),
        Observable(Float64[]),
        Observable(Float64[]),
        Observable{UInt32}(0),
        Observable(collect(1:DEFAULT_HISTOGRAM_RESOLUTION))
    )
end
