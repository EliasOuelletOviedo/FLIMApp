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

# Shared UI path and picker helpers
include("path_utils.jl")

# Shared smoothing helpers used by runtime and workers
include("smoothing.jl")

# Analysis algorithms (lifetime fitting)
include("lifetime_analysis2.jl")

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

"""
    merge_layout_defaults!(app_state::AppState)::Bool

Ensure layout defaults exist in persisted state and perform small key migrations.

Returns `true` when the state was changed.
"""
function merge_layout_defaults!(app_state::AppState)::Bool
    defaults = get_default_layout()
    has_updates = false

    for (key, value) in defaults
        if !haskey(app_state.layout, key)
            app_state.layout[key] = value
            has_updates = true
        end
    end

    if haskey(app_state.layout, :lifetime_smooth_method)
        delete!(app_state.layout, :lifetime_smooth_method)
        has_updates = true
    end

    return has_updates
end

"""
    load_or_create_state()::AppState

Load persisted state when available, otherwise create a new default state.
Also applies small state migrations when needed.
"""
function load_or_create_state()::AppState
    app_state = load_state()

    if app_state === nothing
        @info "Creating fresh application state"
        app_state = AppState(true)
        save_state(app_state)
        return app_state
    end

    @info "Loaded saved state" theme=app_state.dark ? "dark" : "light"

    if merge_layout_defaults!(app_state)
        save_state(app_state)
    end

    return app_state
end

"""
    init_irf_runtime!()

Load IRF-related globals used by lifetime fitting and FFT-based operations.
Falls back to `nothing` values when loading fails.
"""
function init_irf_runtime!()
    try
        global irf = get_irf()
        global irf_bin_size = get_irf_bin_size()
        global tcspc_window_size = round(irf[end, 1] + irf[2, 1], sigdigits=4)
        global fft_plan = plan_fft(zeros(Float64, 256))
        global ifft_plan = plan_ifft(zeros(Float64, 256))

        @info "IRF loaded successfully" size=size(irf) bin_size=irf_bin_size window_size=tcspc_window_size
    catch e
        @error "Failed to load IRF; lifetime fitting will not work" error=string(e)
        global irf = nothing
        global irf_bin_size = nothing
        global tcspc_window_size = nothing
    end

    return nothing
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
    app_state = load_or_create_state()
    
    # Initialize runtime state
    runtime_state = AppRun()
    
    # Load IRF for lifetime analysis
    init_irf_runtime!()
    
    # Create GUI
    @info "Creating GUI..."
    fig, blocks = make_gui(app_state, runtime_state)
    
    # Attach event handlers
    @info "Initializing event handlers..."
    make_handlers(app_state, runtime_state, blocks)
    
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
