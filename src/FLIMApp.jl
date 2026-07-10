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

# Typed container for the GUI elements shared across handlers and tasks
include("gui_blocks.jl")

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

# Becker & Hickl .sdt file parser (used by lifetime_analysis.jl's read_sdt_frame)
include("io/SdtFile.jl")

# Analysis algorithms (lifetime fitting)
include("lifetime_analysis.jl")

# Acquisition worker tasks (depends on lifetime_analysis, protocol.jl, smoothing.jl)
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
    struct_to_dict(x)

Recursively convert a struct (and any nested structs) into a plain
`Dict{Symbol,Any}`, leaving `Bool`/`Int`/`Float64`/`String`/`Symbol` values
and vectors (copied, to avoid aliasing the original) untouched.

Used to strip `AppState` down to plain, module-independent data before
serializing — see `state_file_path`'s docstring for why serializing the
struct directly is unsafe.
"""
struct_to_dict(x::Union{Bool, Int, Float64, String, Symbol, Nothing}) = x
struct_to_dict(x::AbstractVector) = copy(x)
struct_to_dict(x) = Dict{Symbol, Any}(name => struct_to_dict(getfield(x, name)) for name in fieldnames(typeof(x)))

"""
    dict_to_struct(::Type{T}, d::Dict) where T

Inverse of `struct_to_dict`: reconstruct a `T` from a plain `Dict`, using
`T`'s default positional constructor (every struct has one, whether or not
it's `Base.@kwdef`, as long as no inner constructor suppresses it — true for
`AppState` and all of its settings structs). A value that is itself a
`Dict` is recursively reconstructed via the corresponding field's declared
type.
"""
function dict_to_struct(::Type{T}, d::Dict) where T
    values = (d[name] isa Dict ? dict_to_struct(fieldtype(T, name), d[name]) : d[name] for name in fieldnames(T))
    return T(values...)
end

"""
    save_state(state::AppState; path::String)

Serialize application state to disk as a plain `Dict` (see `struct_to_dict`).

# Arguments
- `state::AppState`: persistent configuration to save
- `path::String`: file path (default: `state_file_path()` from config)
"""
function save_state(state::AppState; path::String=state_file_path())
    try
        mkpath(dirname(path))
        open(path, "w") do io
            serialize(io, struct_to_dict(state))
        end
        @info "State saved" path=path
    catch e
        @error "Failed to save state" path=path error=string(e)
    end
end

"""
    valid_app_state(state)::Bool

Check that a reconstructed object is actually a well-formed `AppState` with
each settings field holding its expected struct type.

`dict_to_struct` always builds proper `AppState`/`LayoutSettings`/etc.
instances (or throws, e.g. a `KeyError` on a missing field from an
older-format file — caught by `load_state`'s `try/catch`), so this is
defense-in-depth for future schema changes rather than something load_state
relies on today.
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

# Arguments
- `path::String`: file path (default: `state_file_path()` from config)

# Returns
- `AppState` if the file exists and is valid, `nothing` otherwise
"""
function load_state(path::String=state_file_path())
    if !isfile(path)
        return nothing
    end

    try
        raw = open(path, "r") do io
            deserialize(io)
        end

        if !(raw isa Dict)
            @warn "Saved state has an outdated format; reverting to defaults" path=path
            return nothing
        end

        result = dict_to_struct(AppState, raw)

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

Load the IRF into `RUNTIME[]`, used by lifetime fitting and FFT-based
operations. Falls back to `nothing` fields when loading fails.

Doesn't touch `RUNTIME[].fft_plan`/`ifft_plan` — those already have a valid
256-point default from `RUNTIME`'s initialization, and `ensure_fft_plans`
(called from `ensure_runtime_state!` on every fit) replans on demand for
whatever size is actually needed, so redoing the same 256-point plan here
on every call would just be wasted work.
"""
function init_irf_runtime!()
    ctx = RUNTIME[]
    try
        new_irf = get_irf()
        ctx.irf = new_irf
        ctx.irf_bin_size = get_irf_bin_size()
        ctx.tcspc_window_size = round(new_irf[end, 1] + new_irf[2, 1], sigdigits=4)

        @info "IRF loaded successfully" size=size(ctx.irf) bin_size=ctx.irf_bin_size window_size=ctx.tcspc_window_size
    catch e
        @error "Failed to load IRF; lifetime fitting will not work" error=string(e)
        ctx.irf = nothing
        ctx.irf_bin_size = nothing
        ctx.tcspc_window_size = nothing
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

    if Threads.nthreads() == 1
        @warn """
        Julia is running with only 1 thread (Threads.nthreads() == 1).
        The acquisition worker (lifetime fitting) is spawned on its own
        thread via Threads.@spawn to keep the GUI responsive during a fit,
        but that only works when a second thread is actually available —
        with one thread it falls back to sharing the GUI thread, and the
        window may stutter/freeze while fitting.
        Fix: start Julia with more threads, e.g.
            julia -t auto --project=.
        (or set the environment variable JULIA_NUM_THREADS=auto before
        starting Julia). This flag is identical on macOS and Windows.
        """
    end

    # Ensure required directories exist
    initialize_directories()

    # Load or create persistent state
    app_state = load_or_create_state()

    # Initialize runtime state
    runtime_state = AppRun()

    # Load IRF for lifetime analysis
    init_irf_runtime!()

    # One-time JIT warmup of the fitting code path, done here (before the
    # GUI appears) rather than left to the user's first Start click — see
    # warmup_lifetime_fitting!'s docstring for why this matters and why a
    # background thread doesn't sidestep it.
    @info "Warming up lifetime-fitting code paths (one-time JIT compilation)..."
    t_warmup = time()
    warmup_lifetime_fitting!()
    @info "Warmup complete" seconds = round(time() - t_warmup, digits=1)

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

"""
    julia_main()::Cint

Entry point for the compiled standalone application (see
build/create_app.jl). PackageCompiler-generated executables call this
function on launch.

Unlike an interactive session — where `display(fig)` returns and the REPL
keeps the process (and the GLMakie event loop) alive — a compiled binary
would reach the end of `main` and exit immediately, closing the window
before the user ever sees it. So after `run_app()` returns the displayed
figure, this blocks on the figure's screen until the user closes the
window.
"""
function julia_main()::Cint
    try
        fig = run_app()

        screen = GLMakie.Makie.getscreen(fig.scene)
        if screen !== nothing
            wait(screen)
        end
    catch e
        @error "FLIMApp terminated with an unhandled error" exception=(e, catch_backtrace())
        return 1
    end

    return 0
end

# Export public API
export AppState, AppRun, run_app, save_state, load_state

@info "FLIM Application module loaded. Call run_app() to start."

end # module FLIMApp
