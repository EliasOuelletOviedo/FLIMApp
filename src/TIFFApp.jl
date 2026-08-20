"""
TIFFApp.jl

Ratiometric TIFF imaging application — multi-channel intensity ratios of the
FRET type, with PI feedback control.

Derived from FLIMApp (branch `FLIMApp`), which fitted fluorescence lifetimes
from Becker & Hickl `.sdt` TCSPC files. Everything downstream of the
measurement — the protocol scheduler, ROI trigger box, PI controller, Kalman
smoothing, plots, session saving and state persistence — is shared with it;
what changed is that a frame is now a group of TIFF images (one per channel)
reduced to an intensity ratio, rather than a decay histogram fitted to a
lifetime.

Defines the `TIFFApp` module: package imports, application initialization,
state management (persistence and runtime), GUI creation and event binding,
and application lifecycle (start/stop).

Usage:
    julia> using TIFFApp
    julia> run_app()
"""
module TIFFApp

# =============================================================================
# DEPENDENCIES
# =============================================================================

using Serialization
using Observables

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


# TIFF/BigTIFF reader (used by tiff_source.jl and roi_popup.jl)
include("io/BigTiffFile.jl")
using .BigTiffFile

# ImageJ .roi/.zip ROI parser (used by roi_popup.jl)
include("io/ImageJROI.jl")

# Acquisition folder resolution and per-channel file grouping
include("tiff_source.jl")

# Ratio reduction, ROI rasterization, and the Hill calibration
include("ratio_analysis.jl")

# Acquisition worker tasks (depends on tiff_source, ratio_analysis, protocol.jl, smoothing.jl)
include("acquisition.jl")

# Realtime-capture session saving (depends on data_types.jl, path_utils.jl)
include("session_save.jl")

# ROI trigger-box scan-buffer generation (depends on data_types.jl for
# RoiCoordinates; used by runtime.jl's start_pressed)
include("roi.jl")

# Background task lifecycle (depends on acquisition/protocol/serial/session_save/plotting/smoothing/roi)
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

A field present in `T` but missing from `d` (a save file from before that
field existed — e.g. `ProtocolSettings` gaining `points_per_roi` etc.) falls
back to that field's value in a fresh `T()`, via `default_field_value`,
instead of throwing: without this, adding a single field to any settings
struct would `KeyError` on every old save file, and `load_state`'s
catch-and-reset-to-defaults would discard the *entire* `AppState` — every
other setting too — just because one nested struct grew one new field.
"""
function dict_to_struct(::Type{T}, d::Dict) where T
    values = (
        haskey(d, name) ?
            (d[name] isa Dict ? dict_to_struct(fieldtype(T, name), d[name]) : d[name]) :
            default_field_value(T, name)
        for name in fieldnames(T)
    )
    return T(values...)
end

"""
    default_field_value(::Type{T}, name::Symbol) where T

`name`'s value in a fresh, all-defaults `T()` — used by `dict_to_struct` to
backfill a field missing from an older-schema saved dict. Requires `T` to
support a zero-argument constructor, true for every `Base.@kwdef` settings
struct `dict_to_struct` recurses into (it's never called for `AppState`
itself, which takes no defaults: `AppState`'s own top-level field set is
stable — only its nested settings structs grow fields over time).
"""
function default_field_value(::Type{T}, name::Symbol) where T
    return getfield(T(), name)
end

"""
    save_state(state::AppState; path=state_file_path())

Serialize `state` to disk as a plain `Dict` (see `struct_to_dict`).
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
    load_state(path=state_file_path())::Union{AppState, Nothing}

Deserialize state from disk, returning the `AppState` if the file exists and
is well-formed (see `valid_app_state`), or `nothing` otherwise.
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
    @info "TIFF Ratiometry Application Starting"
    @info "="^60

    if Threads.nthreads() == 1
        @warn """
        Julia is running with only 1 thread (Threads.nthreads() == 1).
        The acquisition worker (image reading and reduction) is spawned on
        its own thread via Threads.@spawn to keep the GUI responsive while
        frames are processed, but that only works when a second thread is
        actually available — with one thread it falls back to sharing the
        GUI thread, and the window may stutter under a fast acquisition.
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

    # No IRF to load and no fitting warmup to run: the ratiometric reduction
    # is a masked sum and a division, so there is no iterative solver whose
    # first-call JIT cost would otherwise land on the user's first START.

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
        @error "TIFFApp terminated with an unhandled error" exception=(e, catch_backtrace())
        return 1
    end

    return 0
end

# Export public API
export AppState, AppRun, run_app, save_state, load_state

@info "TIFF Ratiometry module loaded. Call run_app() to start."

end # module
