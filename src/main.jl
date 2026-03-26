"""
main.jl

FLIM Application - Fluorescence Lifetime Imaging Microscopy

Main entry point for the application. Handles:
- Package imports and dependencies
- Application initialization
- State management (persistence and runtime)
- GUI creation and event binding
- Application lifecycle (start/stop)

Usage:
    julia> include("src/main.jl")
    julia> run_app()
"""

# =============================================================================
# DEPENDENCIES
# =============================================================================

using Serialization
using Observables
using ZipFile

# =============================================================================
# MODULE INITIALIZATION - LOAD IN DEPENDENCY ORDER
# =============================================================================

# Configuration must come first (defines constants)
include("config.jl")

# Data structures depend on config
include("data_types.jl")

# GUI themes (colors and styling)
include("gui_themes.jl")

# Analysis algorithms (lifetime fitting)
include("lifetime_analysis.jl")

# File I/O and worker tasks (depends on lifetime_analysis via vec_to_lifetime and conv_irf_data)
include("data_processing.jl")

# Background task management
include("runtime.jl")

# Protocol popup UI module
include("protocol_popup.jl")

# Event handlers (depends on runtime)
include("handlers.jl")

# GUI construction (depends on handlers and runtime)
include("GUI.jl")

# =============================================================================
# STATE PERSISTENCE
# =============================================================================

"""
    save_state(state::AppState; path::String)

Serialize application state to disk.

Args:
- `state::AppState` - Persistent configuration to save
- `path::String` - File path (default: STATE_FILE_PATH from config)
"""
function save_state(state::AppState; path::String=STATE_FILE_PATH)
    try
        mkpath(dirname(path))
        open(path, "w") do io
            serialize(io, state)
        end
        @info "State saved" path=path
    catch e
        @error "Failed to save state" path=path error=string(e)
    end
end

"""
    load_state(path::String)::AppState

Deserialize application state from disk.

Returns cached state if file exists; otherwise returns nothing.

Args:
- `path::String` - File path (default: STATE_FILE_PATH from config)

Returns:
- AppState if file exists and is valid, nothing otherwise
"""
function load_state(path::String=STATE_FILE_PATH)
    if !isfile(path)
        return nothing
    end
    
    try
        open(path, "r") do io
            return deserialize(io)
        end
    catch e
        @warn "Failed to load state; reverting to defaults" path=path error=string(e)
        return nothing
    end
end

# =============================================================================
# APPLICATION INITIALIZATION & EXECUTION
# =============================================================================

"""
    run_app()

Main application entry point.

1. Initializes directories and configuration
2. Loads or creates persistent application state
3. Creates GUI and attaches event handlers
4. Handles application lifecycle (blocking call)
"""
function run_app()
    @info "="^60
    @info "FLIM Application Starting"
    @info "="^60
    
    # Ensure required directories exist
    initialize_directories()
    
    # Load or create persistent state
    app = load_state()
    if app === nothing
        @info "Creating fresh application state"
        app = AppState(true)  # Start with dark mode
        save_state(app)
    else
        @info "Loaded saved state" theme=app.dark ? "dark" : "light"
    end
    
    # Initialize runtime state
    app_run = AppRun()
    
    # Load IRF for lifetime analysis
    try
        # global irf = get_irf()
        # global irf_bin_size = _compute_irf_bin_size(irf)
        # global tcspc_window_size = size(irf, 1) * irf_bin_size
        # # Initialize FFT plans with correct size based on IRF
        # global fft_plan = plan_fft(zeros(Float64, size(irf, 1)))
        # global ifft_plan = plan_ifft(zeros(Float64, size(irf, 1)))

        global irf = get_irf()
        global irf_bin_size = get_irf_bin_size()
        global tcspc_window_size = round(irf[end, 1]+irf[2, 1], sigdigits=4)
        global fft_plan = plan_fft(zeros(Float64, 256))
        global ifft_plan = plan_ifft(zeros(Float64, 256))

        @info "IRF loaded successfully" size=size(irf) bin_size=irf_bin_size window_size=tcspc_window_size
    catch e
        @error "Failed to load IRF; lifetime fitting will not work" error=string(e)
        # Use defaults - FFT plans already initialized with default size
        global irf = nothing
        global irf_bin_size = nothing
        global tcspc_window_size = nothing
    end
    
    # Create GUI
    @info "Creating GUI..."
    fig, blocks = make_gui(app, app_run)
    
    # Attach event handlers
    @info "Initializing event handlers..."
    make_handlers(app, app_run, blocks)
    
    @info "="^60
    @info "Application ready"
    @info "="^60
    
    # Display and run (blocking)
    display(fig)
    
    return fig
end

# Export public API
export AppState, AppRun, run_app, save_state, load_state

@info "FLIM Application module loaded. Call run_app() to start."

run_app()
