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
using Libdl

# =============================================================================
# MODULE INITIALIZATION - LOAD IN DEPENDENCY ORDER
# =============================================================================
#
# Files are grouped by the thread that runs them (plan.md §8): gui/ runs on
# the main thread only, analysis/ on the analysis worker, loop/ on the DAQ
# loop (the only code that touches the NI cards), spc/ on the SPC engine
# (the only code that touches the SPC card), journal.jl on the journal
# thread. Files at the top level are pure or shared definitions; the threads
# share data only through exchange.jl — and, for the SPC engine, through
# FLIMCore's two channels (commands and results).

# --- Shared definitions ------------------------------------------------------

# Paths, physics/UI constants (first: defines constants)
include("config.jl")

# Bench hardware/timing/safety configuration, read from config/bench.toml
include("bench_config.jl")

# Settings structs, AppState, per-file results
include("data_types.jl")

# FLIMCore: the SPC engine — SPC-QC-104 or SPC-150N — (its own thread, the only task that calls the
# SPC DLL), its photon sources (cards, .spc replay, simulation) and the pure
# functions of the bench scripts. Its own module, standard library only
# (Plan.pdf); the routing limits it defines are shared with the DAQ loop.
include("spc/FLIMCore.jl")

# Problem codes, the debug log, error context, guarded GUI handlers, and the
# diagnosis of what the cards received (needs FLIMCore's results)
include("diagnostics.jl")

# The exchanges between threads (depends on data_types.jl, bench_config.jl)
include("exchange.jl")

# Kalman smoothing, protocol schedule math, ROI scan geometry (pure)
include("smoothing.jl")
include("protocol.jl")
include("roi_geometry.jl")

# ImageJ .roi/.zip parser
include("io/ImageJROI.jl")

# Becker & Hickl .sdt reader (the IRF, a Single measurement)
include("io/SdtFile.jl")

# --- Journal thread ----------------------------------------------------------

include("journal.jl")

# --- DAQ loop thread -----------------------------------------------------------

# NI-DAQmx bindings (ccall on nicaiu; resolved only when a function is called)
include("loop/DAQmx.jl")
include("loop/scan_pattern.jl")
include("loop/safety.jl")
include("loop/hardware.jl")
include("loop/daq_loop.jl")

# --- Analysis worker -----------------------------------------------------------

include("analysis/lifetime_analysis.jl")
include("analysis/acquisition.jl")
include("analysis/session.jl")

# --- Main thread (GUI) ---------------------------------------------------------

include("gui/gui_themes.jl")
include("gui/gui_blocks.jl")
include("gui/path_utils.jl")
include("gui/spc_view.jl")
include("gui/app_run.jl")
include("gui/plotting.jl")
include("gui/runtime.jl")
include("gui/refresh.jl")
include("gui/debug_report.jl")
include("gui/protocol_popup.jl")
include("gui/roi_popup.jl")
include("gui/spc_window.jl")
include("gui/handlers_layout.jl")
include("gui/handlers_controller.jl")
include("gui/handlers_protocol.jl")
include("gui/handlers_console.jl")
include("gui/handlers.jl")
include("gui/GUI.jl")

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

"""
    init_irf_runtime!(spc; ask=true)

Load the IRF of each channel (`load_irfs`: `~/.flimapp/irf.csv` and the
record of its settings, imported from a Single .sdt) into the fit contexts
— `RUNTIME[]` for channel 1, `RUNTIME_CH2[]` for channel 2 when the IRF has
two channels. `spc`: the SPC settings an import is checked against
(`import_irf`). Falls back to `nothing` fields when loading fails.

Doesn't touch the contexts' FFT plans — those already have a valid
256-point default, and `ensure_fft_plans` (called from
`ensure_runtime_state!` on every fit) replans on demand for whatever size
is actually needed.
"""
function init_irf_runtime!(spc::FLIMCore.Reglages; ask::Bool = true)
    try
        irfs, info = load_irfs(spc; ask)
        set_irfs!(irfs; info)
        ctx = RUNTIME[]
        @info "IRF loaded successfully" channels=length(loaded_irfs()) size=size(ctx.irf) bin_size=ctx.irf_bin_size window_size=ctx.tcspc_window_size
    catch e
        @error "Failed to load IRF; lifetime fitting will not work" error=string(e)
        IRF_INFO[] = Dict{String, Any}()
        for ctx in (RUNTIME[], RUNTIME_CH2[])
            ctx.irf = nothing
            ctx.irf_bin_size = nothing
            ctx.tcspc_window_size = nothing
        end
    end

    return nothing
end

# =============================================================================
# APPLICATION START-UP, THREADS AND SHUTDOWN
# =============================================================================

include("app.jl")

# Export public API
export AppState, AppRun, run_app, save_state, load_state, load_bench_config

@info "FLIM Application module loaded. Call run_app() to start."

end # module
