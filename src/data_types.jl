"""
data_types.jl

Core data structures for the FLIM application.

This module defines the primary structures for application state:
- AppState: Persistent configuration that is serialized to disk
- AppRun: Runtime transient state with observables and background tasks
"""

using Observables
using Base.Threads

"""
    AcquisitionSample

One frame's worth of acquisition results, emitted onto the acquisition
channel by `run_acquisition_loop!` (acquisition.jl) and consumed by
`consumer_loop` (runtime.jl). A struct rather than a positional tuple —
16 fields is too many to destructure positionally without risking a
silently-mismatched order. Channel-2 fields use the same "absent" sentinels
as everywhere else in this file: `NaN` for scalars, `Float64[]` for vectors,
set when the source file has only one TCSPC channel (see
`process_channel_frame!` in acquisition.jl).
"""
struct AcquisitionSample
    histogram1::Vector{Float64}
    fit1::Vector{Float64}
    photons1::Float64
    lifetime1::Float64
    concentration1::Float64
    histogram2::Vector{Float64}
    fit2::Vector{Float64}
    photons2::Float64
    lifetime2::Float64
    concentration2::Float64
    command1::Float64
    command2::Float64
    timestamps::Float64
    protocol_setpoint::Float64
    frame_index::UInt32
    source_file::String
end

# =============================================================================
# APPLICATION STATE SETTINGS GROUPS
# =============================================================================
#
# Base.@kwdef gives each struct a zero-argument default constructor (e.g.
# LayoutSettings()) that doubles as "get the defaults" — no separate
# get_default_*() function needed. Typed fields mean a typo'd key or a
# wrong-typed value is a compile-time/construction-time error instead of a
# silent Dict lookup returning `nothing` at some unrelated call site.

"""
    LayoutSettings

Display settings: time range, binning, smoothing, which series each plot
shows, and per-plot channel toggles.
"""
Base.@kwdef mutable struct LayoutSettings
    time_range::Int = 60
    binning::Int = 1
    smoothing::Int = 0
    plot1::String = "Lifetime"
    plot2::String = "Ion concentration"
    plot1_ch1::Bool = false
    plot1_ch2::Bool = false
    plot2_ch1::Bool = false
    plot2_ch2::Bool = false
end

"""
    ControllerSettings

Hardware controller configuration for the two PID output channels.
"""
Base.@kwdef mutable struct ControllerSettings
    ch1_inv::Bool = false
    ch1_on::Bool = false
    ch1_out::String = "Out 1"
    ch1_mode::String = "Digital"
    freq::Int = 1000
    P1::Float64 = 0.0
    I1::Float64 = 0.0
    D1::Float64 = 0.0
    ch2_inv::Bool = false
    ch2_on::Bool = false
    ch2_out::String = "Out 2"
    ch2_mode::String = "Digital"
    P2::Float64 = 0.0
    I2::Float64 = 0.0
    D2::Float64 = 0.0
end

"""
    ProtocolSettings

Experimental protocol schedule: `times`/`setpoints` are parallel vectors of
`PROTOCOL_STEP_COUNT` per-step durations and setpoints.
"""
Base.@kwdef mutable struct ProtocolSettings
    active::Bool = false
    repeats::Int = 1
    delay::Int = 0
    times::Vector{Float64} = fill(NaN, PROTOCOL_STEP_COUNT)
    setpoints::Vector{Float64} = fill(NaN, PROTOCOL_STEP_COUNT)
end

"""
    RoiSettings

ROI panel settings.
"""
Base.@kwdef mutable struct RoiSettings
    active::Bool = false
end

"""
    ConsoleSettings

Console/logging settings (no fields yet).
"""
Base.@kwdef mutable struct ConsoleSettings end

# =============================================================================
# PERSISTENT APPLICATION STATE
# =============================================================================

"""
    AppState

Persistent configuration state that can be serialized to disk.

Fields:
- `dark::Bool` - Dark mode toggle (true for dark, false for light)
- `current_panel::Symbol` - Currently active UI panel (:layout, :controller, :protocol, :console)
- `layout::LayoutSettings` - Layout and display settings
- `controller::ControllerSettings` - Hardware controller configuration
- `protocol::ProtocolSettings` - Experimental protocol settings
- `roi::RoiSettings` - ROI settings
- `console::ConsoleSettings` - Console and logging settings

This structure is serialized to `STATE_FILE_PATH` to preserve user preferences
across application sessions.
"""
mutable struct AppState
    dark::Bool
    current_panel::Symbol
    layout::LayoutSettings
    controller::ControllerSettings
    protocol::ProtocolSettings
    roi::RoiSettings
    console::ConsoleSettings
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
        LayoutSettings(),
        ControllerSettings(),
        ProtocolSettings(),
        RoiSettings(),
        ConsoleSettings()
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
- `histogram_ch1::Observable{Vector{Float64}}` - Current histogram data (channel 1)
- `fit_ch1::Observable{Vector{Float64}}` - Fitted decay curve (channel 1)
- `photons_ch1::Observable{Vector{Float64}}` - Time-series of photon counts (channel 1)
- `counts_ch1::Observable{Float64}` - Current photon count (channel 1)
- `lifetime_ch1::Observable{Vector{Float64}}` - Time-series of fitted lifetimes (channel 1)
- `lifetime_ch1_smooth::Observable{Vector{Float64}}` - Smoothed time-series of fitted lifetimes (channel 1)
- `protocol_setpoint::Observable{Vector{Float64}}` - Time-series of protocol setpoints used by PID
- `concentration_ch1::Observable{Vector{Float64}}` - Time-series of ion concentrations (channel 1)
- `concentration_ch1_smooth::Observable{Vector{Float64}}` - Smoothed time-series of ion concentrations (channel 1)
- `histogram_ch2::Observable{Vector{Float64}}` - Current histogram data (channel 2)
- `fit_ch2::Observable{Vector{Float64}}` - Fitted decay curve (channel 2)
- `photons_ch2::Observable{Vector{Float64}}` - Time-series of photon counts (channel 2)
- `counts_ch2::Observable{Float64}` - Current photon count (channel 2)
- `lifetime_ch2::Observable{Vector{Float64}}` - Time-series of fitted lifetimes (channel 2)
- `lifetime_ch2_smooth::Observable{Vector{Float64}}` - Smoothed time-series of fitted lifetimes (channel 2)
- `concentration_ch2::Observable{Vector{Float64}}` - Time-series of ion concentrations (channel 2)
- `concentration_ch2_smooth::Observable{Vector{Float64}}` - Smoothed time-series of ion concentrations (channel 2)
- `command1::Observable{Vector{Float64}}` - Time-series of PID command values (controller 1)
- `command2::Observable{Vector{Float64}}` - Time-series of PID command values (controller 2)
- `timestamps::Observable{Vector{Float64}}` - Time-series timestamps
- `i::Observable{UInt32}` - Current frame/iteration counter
- `hist_time::Observable{Vector{Int64}}` - Histogram time-axis values
"""
mutable struct AppRun
    channel::Union{Channel{AcquisitionSample}, Nothing}
    running::Threads.Atomic{Bool}
    paused::Threads.Atomic{Bool}
    worker_task::Union{Task, Nothing}
    consumer_task::Union{Task, Nothing}
    autoscaler_task::Union{Task, Nothing}
    infos_task::Union{Task, Nothing}
    serial_task::Union{Task, Nothing}
    serial_conn::Union{Any, Nothing}
    histogram_ch1::Observable{Vector{Float64}}
    fit_ch1::Observable{Vector{Float64}}
    photons_ch1::Observable{Vector{Float64}}
    counts_ch1::Observable{Float64}
    lifetime_ch1::Observable{Vector{Float64}}
    lifetime_ch1_smooth::Observable{Vector{Float64}}
    protocol_setpoint::Observable{Vector{Float64}}
    concentration_ch1::Observable{Vector{Float64}}
    concentration_ch1_smooth::Observable{Vector{Float64}}
    histogram_ch2::Observable{Vector{Float64}}
    fit_ch2::Observable{Vector{Float64}}
    photons_ch2::Observable{Vector{Float64}}
    counts_ch2::Observable{Float64}
    lifetime_ch2::Observable{Vector{Float64}}
    lifetime_ch2_smooth::Observable{Vector{Float64}}
    concentration_ch2::Observable{Vector{Float64}}
    concentration_ch2_smooth::Observable{Vector{Float64}}
    command1::Observable{Vector{Float64}}
    command2::Observable{Vector{Float64}}
    timestamps::Observable{Vector{Float64}}
    i::Observable{UInt32}
    save_progress::Observable{Float64}
    hist_time::Observable{Vector{Int64}}
    protocol::Observable{ProtocolSettings}
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
        Observable(zeros(Float64, DEFAULT_HISTOGRAM_RESOLUTION)),
        Observable(zeros(Float64, DEFAULT_HISTOGRAM_RESOLUTION)),
        Observable(Float64[]),
        Observable(0.0),
        Observable(Float64[]),
        Observable(Float64[]),
        Observable(Float64[]),
        Observable(Float64[]),
        Observable(Float64[]),
        Observable(Float64[]),
        Observable(Float64[]),
        Observable{UInt32}(0),
        Observable(NaN),
        Observable(collect(1:DEFAULT_HISTOGRAM_RESOLUTION)),
        Observable(ProtocolSettings())
    )
end
