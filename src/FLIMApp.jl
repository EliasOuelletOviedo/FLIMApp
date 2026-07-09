"""
FLIMApp.jl

FLIM Application - Fluorescence Lifetime Imaging Microscopy

Defines the `FLIMApp` module: package imports, application initialization,
state management (persistence and runtime), GUI creation and event binding,
and application lifecycle (start/stop).

Usage:
    julia> using FLIMApp
    julia> run_app()
"""
module FLIMApp

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

# GUI themes (colors and styling; reuses config.jl's DARK_MODE_THEME/LIGHT_MODE_THEME)
include("gui_themes.jl")

# Shared UI path and picker helpers
include("path_utils.jl")

# Smoothing/Kalman helpers used by acquisition and runtime
include("smoothing.jl")

# Serial port discovery + PID/PWM command I/O (standalone)
include("serial.jl")

# Protocol schedule math (standalone)
include("protocol.jl")

# Plot-axis autoscaling and plot-series lookup (needed by runtime.jl and GUI.jl)
include("plotting.jl")

# Becker & Hickl .sdt file parser (used by lifetime_analysis2.jl's read_sdt_frame)
include("io/SdtFile.jl")

# Analysis algorithms (lifetime fitting)
include("lifetime_analysis2.jl")

# Acquisition worker tasks (depends on lifetime_analysis2, protocol.jl, smoothing.jl)
include("acquisition.jl")

# Realtime-capture session saving (depends on data_types.jl, path_utils.jl)
include("session_save.jl")

# Background task lifecycle (depends on acquisition/protocol/serial/session_save/plotting/smoothing)
include("runtime.jl")

# Protocol popup UI module
include("protocol_popup.jl")

# ROI popup UI module
include("roi_popup.jl")

# Per-panel event handlers (depends on gui_themes.jl, plotting.jl, runtime.jl, protocol/roi popups)
include("handlers_layout.jl")
include("handlers_controller.jl")
include("handlers_protocol.jl")
include("handlers_console.jl")

# Event handler orchestrator (wires up the per-panel handlers above)
include("handlers.jl")

# GUI construction (depends on plotting.jl, gui_themes.jl, handlers.jl and runtime.jl)
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
    valid_app_state(state)::Bool

Check that a deserialized object is actually a well-formed `AppState` with
each settings field holding its expected struct type.

This matters because `Serialization.deserialize` does **not** error on a
type mismatch the way you'd expect: a state file saved before settings
became typed structs (when `layout` etc. were `Dict{Symbol,Any}`)
deserializes *without throwing*, reconstructing an `AppState` whose
`layout` field is still a bare `Dict` — type-inconsistent with the current
`AppState` definition. Left unchecked, that object passes `load_state()`
silently and only fails later (e.g. the first `app.layout.time_range`
access deep inside `make_gui`), which is a confusing place to discover a
stale save file. Checking eagerly here turns that into the same, already
-handled "revert to defaults" path as any other load failure.
"""
function valid_app_state(state)::Bool
    return state isa AppState &&
           state.layout isa LayoutSettings &&
           state.controller isa ControllerSettings &&
           state.protocol isa ProtocolSettings &&
           state.roi isa RoiSettings &&
           state.console isa ConsoleSettings
end

"""
    load_state(path::String)::AppState

Deserialize application state from disk.

Returns cached state if file exists and is well-formed (see
`valid_app_state`); otherwise returns nothing.

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
        result = open(path, "r") do io
            deserialize(io)
        end

        if !valid_app_state(result)
            @warn "Saved state has an outdated format; reverting to defaults" path=path
            return nothing
        end

        return result
    catch e
        @warn "Failed to load state; reverting to defaults" path=path error=string(e)
        return nothing
    end
end

"""
    load_or_create_state()::AppState

Load persisted state when available, otherwise create a new default state.

`AppState`'s settings fields are typed structs (`LayoutSettings`,
`ControllerSettings`, etc.), so a successfully-deserialized `AppState` is
always fully formed — no partial/missing-key migration step is possible or
needed the way it was when these fields were `Dict{Symbol,Any}`. If
`load_state()` fails (e.g. a state file saved before this change, in the
old Dict-based format), it already logs a warning and returns `nothing`,
so this falls through to creating a fresh default state below.
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

end # module FLIMApp
