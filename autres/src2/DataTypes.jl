"""
DataTypes.jl - Type definitions for persistent and runtime state
"""

using Observables
# using Threads
using FFTW

# ============================================================================
# PERSISTENT STATE (to be serialized)
# ============================================================================

"""
    LayoutState

Persistent layout configuration for the GUI.
"""
struct LayoutState
    time_range::Int      # seconds [1, 99999]
    binning::Int         # [1, 100]
    smoothing::Int       # [0, 10]
    plot1::String        # "Histogram", "Photon counts", "Lifetime", "Ion concentration", "Command"
    plot2::String        # same options as plot1
end

"""Default layout configuration"""
const DEFAULT_LAYOUT = LayoutState(60, 1, 0, "Lifetime", "Ion concentration")

"""
    ControllerState

Persistent controller PID configuration for two channels.
"""
struct ControllerState
    ch1_inv::Bool        # inverted
    ch1_on::Bool         # active
    ch1_out::String      # "Out 1", "Out 2", "Out 3", "Out 4"
    ch1_mode::String     # "Digital", "Analog"
    P1::Int              # proportional gain
    I1::Int              # integral gain
    D1::Int              # derivative gain
    ch2_inv::Bool        # inverted
    ch2_on::Bool         # active
    ch2_out::String      # "Out 1", "Out 2", "Out 3", "Out 4"
    ch2_mode::String     # "Digital", "Analog"
    P2::Int              # proportional gain
    I2::Int              # integral gain
    D2::Int              # derivative gain
end

"""Default controller configuration"""
const DEFAULT_CONTROLLER = ControllerState(
    false, false, "Out 1", "Digital", 0, 0, 0,
    false, false, "Out 2", "Digital", 0, 0, 0
)

"""
    AppState

Persistent application state to be serialized to disk.
All fields must be serializable (no Tasks, Channels, Observables, etc).
"""
mutable struct AppState
    dark::Bool
    current_panel::Symbol
    layout::LayoutState
    controller::ControllerState
    protocol::Dict{Symbol, Any}     # TODO: refine structure when protocol defined
    console::Dict{Symbol, Any}      # TODO: refine structure when console defined
end

# ============================================================================
# RUNTIME STATE (never serialized)
# ============================================================================

"""
    NumericContext

Context containing numeric data and FFT plans.
Separate from state to avoid serialization issues.
"""
struct NumericContext
    irf::Matrix{Float64}                          # IRF pulse response
    irf_bin_size::Float64                         # time per channel [ns]
    tcspc_window_size::Float64                    # total time window [ns]
    # fft_plan::FFTW.cFFTWPlan{Float64, -1, false, 1}  # forward FFT plan
    # ifft_plan::FFTW.iFFTWPlan{Float64, 1, false, 1}  # inverse FFT plan
    fft_plan::Any
    ifft_plan::Any
end

"""
    AppRun

Runtime state including observables, tasks, and channels.
Do NOT serialize this structure.
"""
mutable struct AppRun
    # Data channel from worker to consumer
    channel::Union{Channel{Tuple{Vector{Float64},Vector{Float64},Float64,Float64,Float64,Float64,UInt32}}, Nothing}
    
    # Background tasks
    worker_task::Union{Task, Nothing}
    consumer_task::Union{Task, Nothing}
    autoscaler_task::Union{Task, Nothing}
    infos_task::Union{Task, Nothing}
    
    # Synchronization
    running::Threads.Atomic{Bool}
    
    # Observables for time-series data (auto-updated)
    histogram::Observable{Vector{Float64}}      # current histogram (256 channels)
    fit::Observable{Vector{Float64}}            # fitted curve
    photons::Observable{Vector{Float64}}        # time-series photon counts
    lifetime::Observable{Vector{Float64}}       # time-series lifetime τ₁
    concentration::Observable{Vector{Float64}}  # time-series concentration
    timestamps::Observable{Vector{Float64}}     # accumulated timestamps
    i::Observable{UInt32}                       # command/frame counter
    hist_time::Observable{Vector{Int64}}        # histogram time axis [1:256]
end

"""Create default AppRun with initialized observables"""
function create_app_run()
    return AppRun(
        nothing,  # channel
        nothing,  # worker_task
        nothing,  # consumer_task
        nothing,  # autoscaler_task
        nothing,  # infos_task
        Threads.Atomic{Bool}(false),
        Observable(zeros(Float64, 256)),
        Observable(zeros(Float64, 256)),
        Observable(Float64[]),
        Observable(Float64[]),
        Observable(Float64[]),
        Observable(Float64[]),
        Observable{UInt32}(0),
        Observable(collect(1:256))
    )
end

"""
    create_default_app_state(dark::Bool=true)

Create a default application state with recommended initial values.
"""
function create_default_app_state(dark::Bool=true)
    return AppState(
        dark,
        :layout,
        DEFAULT_LAYOUT,
        DEFAULT_CONTROLLER,
        Dict{Symbol, Any}(),
        Dict{Symbol, Any}()
    )
end
