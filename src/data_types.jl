"""
data_types.jl

Core data structures for the FLIM application.

This module defines the primary structures for application state:
- AppState: Persistent configuration that is serialized to disk
- AppRun: Runtime transient state with observables and background tasks
- ChannelFrame / ChannelSeries: one TCSPC channel's per-frame results and
  runtime observables, so per-channel logic is written once and instantiated
  per channel instead of duplicated `_ch1`/`_ch2` copies
"""

using Observables
using Base.Threads
using LibSerialPort: SerialPort

# =============================================================================
# ACQUISITION SAMPLES (worker -> consumer payload)
# =============================================================================

"""
    ChannelFrame

One TCSPC channel's slice of a single acquisition frame: the binned
histogram, its fitted decay curve, and the scalar fit results. Two of these
(one per channel) make up an `AcquisitionSample`. The "absent channel"
convention (a file with only one TCSPC channel) uses the same sentinels as
everywhere else: `NaN` for scalars, `Float64[]` for vectors — see
`ChannelFrame()` below and `process_channel_frame!` in acquisition.jl.
"""
struct ChannelFrame
    histogram::Vector{Float64}
    fit::Vector{Float64}
    photons::Float64
    lifetime::Float64
    concentration::Float64
end

"""
    ChannelFrame()

The "absent channel" frame: empty vectors and `NaN` scalars, emitted for
channel 2 when the source file has only one TCSPC channel.
"""
ChannelFrame() = ChannelFrame(Float64[], Float64[], NaN, NaN, NaN)

"""
    AcquisitionSample

One frame's worth of acquisition results, emitted onto the acquisition
channel by `run_acquisition_loop!` (acquisition.jl) and consumed by
`consumer_loop` (runtime.jl). A struct rather than a positional tuple —
too many fields to destructure positionally without risking a
silently-mismatched order.
"""
struct AcquisitionSample
    ch1::ChannelFrame
    ch2::ChannelFrame
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

# Fields
- `dark::Bool`: dark mode toggle (true for dark, false for light)
- `current_panel::Symbol`: currently active UI panel (:layout, :controller, :protocol, :console)
- `layout::LayoutSettings`: layout and display settings
- `controller::ControllerSettings`: hardware controller configuration
- `protocol::ProtocolSettings`: experimental protocol settings
- `roi::RoiSettings`: ROI settings
- `console::ConsoleSettings`: console and logging settings

This structure is serialized to `state_file_path()` to preserve user
preferences across application sessions.
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

# Arguments
- `use_dark::Bool`: initialize with dark theme if true

# Returns
- `AppState` with all settings initialized to defaults
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
    ChannelSeries

One TCSPC channel's runtime observables: the latest histogram/fit/counts
plus the accumulated per-frame time series. `AppRun` holds one instance per
channel (`ch1`/`ch2`), so every "do X for each channel" site loops over
`(app_run.ch1, app_run.ch2)` instead of duplicating `_ch1`/`_ch2` code.

# Fields
- `histogram::Observable{Vector{Float64}}`: current histogram data
- `fit::Observable{Vector{Float64}}`: fitted decay curve
- `photons::Observable{Vector{Float64}}`: time-series of photon counts
- `counts::Observable{Float64}`: current photon count
- `lifetime::Observable{Vector{Float64}}`: time-series of fitted lifetimes
- `lifetime_smooth::Observable{Vector{Float64}}`: smoothed lifetime time-series
- `concentration::Observable{Vector{Float64}}`: time-series of ion concentrations
- `concentration_smooth::Observable{Vector{Float64}}`: smoothed concentration time-series
"""
struct ChannelSeries
    histogram::Observable{Vector{Float64}}
    fit::Observable{Vector{Float64}}
    photons::Observable{Vector{Float64}}
    counts::Observable{Float64}
    lifetime::Observable{Vector{Float64}}
    lifetime_smooth::Observable{Vector{Float64}}
    concentration::Observable{Vector{Float64}}
    concentration_smooth::Observable{Vector{Float64}}
end

function ChannelSeries()
    return ChannelSeries(
        Observable(zeros(Float64, DEFAULT_HISTOGRAM_RESOLUTION)),
        Observable(zeros(Float64, DEFAULT_HISTOGRAM_RESOLUTION)),
        Observable(Float64[]),
        Observable(0.0),
        Observable(Float64[]),
        Observable(Float64[]),
        Observable(Float64[]),
        Observable(Float64[])
    )
end

"""
    channel_series(app_run) -> (ChannelSeries, ChannelSeries)

Both channels' runtime series, in channel order — the idiomatic way to
iterate "for each channel" over an `AppRun`.
"""
channel_series(app_run) = (app_run.ch1, app_run.ch2)

"""
    AppRun

Runtime state for the application. This structure holds references to
background tasks, communication channels, and observables that update
during execution. It is NOT serialized.

# Fields
- `channel::Union{Channel{AcquisitionSample}, Nothing}`: worker->consumer data channel
- `running::Threads.Atomic{Bool}`: flag controlling background task lifetime
- `paused::Threads.Atomic{Bool}`: flag pausing the background tasks
- `worker_task::Union{Task, Nothing}`: background worker processing task
- `consumer_task::Union{Task, Nothing}`: data consumer and GUI update task
- `autoscaler_task::Union{Task, Nothing}`: periodic axis autoscaling task
- `infos_task::Union{Task, Nothing}`: periodic info/status update task
- `serial_task::Union{Task, Nothing}`: periodic serial command task
- `serial_conn::Union{SerialPort, Nothing}`: open serial connection, if any
- `ch1::ChannelSeries` / `ch2::ChannelSeries`: per-channel runtime observables
- `protocol_setpoint::Observable{Vector{Float64}}`: time-series of protocol setpoints used by PID
- `command1::Observable{Vector{Float64}}` / `command2`: time-series of PID command values
- `timestamps::Observable{Vector{Float64}}`: time-series timestamps
- `i::Observable{UInt32}`: current frame/iteration counter
- `save_progress::Observable{Float64}`: Save-mode progress (percent, `NaN` when idle)
- `hist_time::Observable{Vector{Int64}}`: histogram time-axis values
- `protocol::Observable{ProtocolSettings}`: normalized protocol config for the worker
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
    serial_conn::Union{SerialPort, Nothing}
    ch1::ChannelSeries
    ch2::ChannelSeries
    protocol_setpoint::Observable{Vector{Float64}}
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

# Returns
- `AppRun` with all observables initialized to empty vectors/defaults,
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
        ChannelSeries(),
        ChannelSeries(),
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
