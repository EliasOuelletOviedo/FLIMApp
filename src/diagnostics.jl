"""
diagnostics.jl

Making every problem at the bench identifiable, so that "it doesn't work"
becomes "PASS-02 on card 1":

- a catalog of problems (`PROBLEMS`), each with a stable code — DAQ-04,
  PASS-02, ROUTE-01… —, what it means and what to check. Every warning or
  error the app raises about the bench carries its code (`report_problem!`):
  in the top bar, the Console panel, the debug log and the debug report;
- a debug log (`DebugLogger`): every log record of every thread — time,
  level, thread, source line, values, full stack trace — in one file per
  app session (`<journal>/debug/`), the last ones also kept in memory for
  the debug report (gui/debug_report.jl);
- error context (`with_context`): an error says which step failed (which
  task, which channel, which card), not only what the driver said;
- GUI handlers that can't fail silently (`on`, below): an error in any of
  them is logged with its source line and shown as GUI-01;
- the diagnosis of a Realtime measurement from what the cards received
  (`diagnose_passes`, from the SPC engine's `EtatClamp`): photons, pass
  markers, pass lengths, routing codes;
- the analysis worker's counters (`WorkerStats`, `diagnose_worker`).

DEBUGGING.md lists the codes with what to check; a test keeps it in step
with `PROBLEMS`.
"""

using Logging
using Dates
using Printf

# =============================================================================
# CATALOG
# =============================================================================

"""One kind of problem: a stable code, what it means, and what to check."""
struct Problem
    id::String
    title::String
    check::String
end

const PROBLEM_LIST = Problem[
    # --- Start-up and environment ---
    Problem("ENV-01", "Too few threads",
            "Start Julia with -t 4,1 (scripts/launch.bat does): the DAQ loop, the journal, the analysis and the SPC engine each need a thread."),
    Problem("ENV-02", "NI-DAQmx driver not found: running offline",
            "Install NI-DAQmx (nicaiu.dll in System32 on the bench PC). Without it the app runs offline: Playback only."),
    Problem("ENV-03", "SPC DLL (spcm64.dll) not found: running offline",
            "Install the Becker & Hickl TCSPC package (spcm64.dll), or set [source] type = \"simulation\" in config/spc.toml."),
    Problem("ENV-04", "Configuration file unreadable: defaults used",
            "Fix the file the message names (a typo, an unknown key, a value out of range); the message says which."),
    Problem("ENV-05", "Recording folder: little space left, or not writable",
            "Free space, or pick another recording folder (second path field). The raw stream takes about 4 bytes per photon per card."),
    Problem("ENV-06", "Unexpected error at start-up",
            "The debug log has the stack trace; the app may run without the part that failed."),
    # --- NI cards and DAQ loop ---
    Problem("DAQ-01", "NI device not found",
            "The device names in config/bench.toml ([channels]) must match NI MAX; the message lists the devices seen."),
    Problem("DAQ-02", "NI device reset or zeroing failed",
            "Another program (NI MAX test panel, LabVIEW) may hold the device: close it, then RECONNECT."),
    Problem("DAQ-03", "NI task could not be created or configured",
            "The message names the task, its channels and the DAQmx call: check those channels in config/bench.toml and in NI MAX."),
    Problem("DAQ-04", "Pass counter task failed",
            "channels.passes (X6321/ctr1), passes_terminal (\"\" = PFI13, CTR 1 OUT) and channels.clock in config/bench.toml; no other task may use that counter."),
    Problem("DAQ-05", "Missed deadline: the card ran out of written samples",
            "Longer slots or a larger timing.lead_slots (config/bench.toml); the Console panel shows the iteration time, the margin and the garbage-collector pauses."),
    Problem("DAQ-06", "Readback fell behind the card",
            "As DAQ-05: the loop was late reading; check the CPU load and the Console panel."),
    Problem("DAQ-07", "Scan refused before reaching the card",
            "The message says which limit: galvo range (ROI popup X/Y min/max), more than 15 ROIs, a scan or pause shorter than 2 samples."),
    Problem("DAQ-08", "DAQ error during a scan: outputs zeroed (FAULT)",
            "The message gives the step and the DAQmx code; RESET acknowledges it. The debug log has the full DAQmx message."),
    Problem("DAQ-09", "DAQ connection failed",
            "The message gives the step and the reason; RECONNECT once fixed."),
    Problem("DAQ-10", "No RTSI route between the NI cards: the sample clock can't reach the 6110",
            "The RTSI cable between the PCIe-6321 and the PCI-6110 must be plugged and registered in NI MAX: Devices and Interfaces → right-click → Create New… → NI-DAQmx RTSI Cable, then add both cards to it (each card's Properties → RTSI cable). Moving or adding a PCI card can undo it. Then RECONNECT."),
    # --- SPC card (SPC-QC-104, or SPC-150N) and engine ---
    Problem("SPC-01", "SPC cards: initialization failed",
            "SPCM must be closed; the cards must be seen by the PC (chassis powered before the PC); UNLOCK if a crashed session left them locked."),
    Problem("SPC-02", "SPC card identity: serial number or channel",
            "[verification] series in config/spc.toml: channel 1 then channel 2, \"<serial>/IN<input>\" for the QC-104 (3T0089/IN1), each card's serial for SPC-150N; the message says which card or input was found where."),
    Problem("SPC-03", "No SYNC on a card",
            "Laser on? SYNC cable (QC-104: the SYNC input); the 4th value of [qc] seuil_mV / zc_mV (SPC-150N: sync_threshold / sync_zc_level in [spc_module])."),
    Problem("SPC-04", "Count rate too low on a channel",
            "Detectors on (DCC software: Enable outputs, overload shutdown?), light reaching them, the detector cable on that input; [qc] seuil_mV / zc_mV (SPC-150N: cfd_limit_low in [spc_module])."),
    Problem("SPC-05", "A card setting was not applied as requested",
            "The SPC window lists requested → applied; a value out of range in [qc] (QC-104), or a key unknown to the DLL in [spc_module] (SPC-150N)."),
    Problem("SPC-06", "SPC engine error",
            "The message gives the step and the DLL function with its code; the debug log has the stack trace."),
    Problem("SPC-07", "Photons lost: FIFO overflow (SPC_FOVFL or GAP records)",
            "The passes concerned are kept out of the PI. Count rate too high for the bus, or the engine reading too slowly (CPU load)."),
    Problem("SPC-08", "ADC comb visible on a decay",
            "Differential nonlinearity of the card's ADC (SPC-150N: dither_range); the QC-104's TDC channels are resampled onto [qc] fenetre_ns with a random draw, which should leave none."),
    Problem("SPC-09", "QC-104 rate counters don't match the stream: [qc] taux",
            "Which SPC_read_rates value is IN1, IN2, IN3, SYNC isn't documented: fix [qc] taux (qc3_entrees.jl tells). Only the display between measurements uses them; the check and the measurements count photons in the stream."),
    Problem("SPC-10", "QC-104: photons or records set aside by the translation",
            "Beyond [qc] fenetre_ns: the window shorter than the laser period, diviseur_sync > 1, or decalage_ns pushing the decay to its end. An input without a channel: [verification] series. Unknown records: the QC-104's FIFO format (SPCLite.FORMAT_QC104) needs another look."),
    Problem("IMG-01", "Imaging: no line or frame clock, no image",
            "Scanner running? Its line clock on M1 and frame clock on M2 of the cards; ligne_/trame_front_montant in [imagerie]."),
    Problem("IMG-02", "Scanner setting not in the table: image lines guessed",
            "Measure this setting with scripts/spc/horloges_scanner.jl and add [lines per frame, image lines, top lines] to reglages_scanner in config/spc.toml ([imagerie])."),
    # --- Pass signal (counter → marker M0, and M3 with fin_par_m3) ---
    Problem("PASS-01", "No photon on a card during the Realtime measurement",
            "Laser and detectors on, CFD rate in the top bar, CFD/SYNC thresholds; the 850 nm gate (P0.0) high during scans."),
    Problem("PASS-02", "Photons but no M0 marker (start of pass)",
            "The pass signal (PFI13 = CTR 1 OUT) doesn't reach M0 (QC-104: pin 12 of the Micro Sub-D 15): wiring, common ground (D GND to pin 5 or 15). scripts/test_passes.jl shows where it arrives."),
    Problem("PASS-03", "M0 markers but no M3 marker (end of pass)",
            "Only with [clamp] fin_par_m3 = true: M3 isn't wired (QC-104: pin 10, the same PFI13 as pin 12). Without access to M3, set fin_par_m3 = false (M0 only)."),
    Problem("PASS-04", "Pass markers lost or extra",
            "M0 and M3 counts differ, or (M0 only) M0 missing or off the slot cadence (glitches, ignored): a marginal TTL on the marker inputs (one output feeds every card): ground, cable length, connector."),
    Problem("PASS-05", "Pass length M3 − M0 differs from the programmed scan",
            "If it equals the pause, the edges are swapped (M0 must be the rising edge, M3 the falling one); otherwise check the pass counter's clock and the sample rate."),
    Problem("PASS-06", "Passes don't pair between the two cards",
            "One card misses markers the other gets: compare their M0 counts (Console panel, debug report)."),
    Problem("PASS-07", "Pass signal seen on M1/M2 instead of M0/M3",
            "The pass signal is wired to the line or frame clock inputs: move it to M0 (and M3 with fin_par_m3 = true)."),
    Problem("PASS-08", "Many photons with a ROI code outside the passes",
            "The routing code and the pass signal are offset in time; normally only a few photons at the edges."),
    Problem("PASS-09", "No pass signal generated: the DAQ loop played no slot during the measurement",
            "The DAQ loop must be RUNNING during a Realtime measurement: see its state and any DAQ-0x problem (scan refused, task creation, fault)."),
    # --- Routing code (P0.4–P0.7 → R0–R3) ---
    Problem("ROUTE-01", "Photons in passes carry the reserved code 0: no routing code received",
            "P0.4–P0.7 of the NI don't reach /R0–/R3 of the card (QC-104: pins 2, 3, 4, 7; cable, BOB), or channels.lines doesn't drive port 0, or (QC-104) the routing isn't enabled on that input (tdc_control, from [verification] series). The debug report's \"Routing lines read back\" (or scripts/lignes_routage.jl) tells which: if the NI drives the code, the loss is after the BOB."),
    Problem("ROUTE-02", "The cards read the inverted routing code",
            "Set inverser_routage the other way in config/spc.toml ([clamp])."),
    Problem("ROUTE-03", "A routing line looks stuck",
            "The message names the line (R<b> = P0.<4+b>) and whether it is never or always high: that wire, pin or connector. \"Routing lines read back\" (debug report) shows whether the NI drives it."),
    Problem("ROUTE-04", "Photons carry routing codes the NI doesn't write",
            "Lines swapped between NI and cards (bit order), or crosstalk; the message lists the codes seen and written."),
    Problem("ROUTE-05", "Passes whose routing code is none of this run's ROIs: not analyzed",
            "See ROUTE-02 to ROUTE-04; the message lists the codes seen."),
    # --- Analysis ---
    Problem("FIT-01", "IRF missing, or taken with other settings",
            "Import a Single of the IRF taken with the current settings ([qc] or [spc_module]) and [dcc] gains (IRF button): SPCM's .sdt, or the SPC window's Single (its CSV). The log lists every difference."),
    Problem("FIT-02", "Lifetime fits failing",
            "Too few photons per pass, the IRF misaligned with the decays (other TAC settings), or a wrong number of lifetimes."),
    Problem("FIT-03", "The analysis can't keep up",
            "Passes pile up: fewer lifetimes, longer scans, or a slower pass rate."),
    Problem("FIT-04", "Passes kept out of the PI",
            "The reasons are counted: GAP or FIFO overflow → SPC-07, M3 − M0 → PASS-05."),
    Problem("FIT-05", "Analysis worker error",
            "The debug log has the stack trace; the run stopped."),
    # --- GUI, Playback, journal ---
    Problem("GUI-01", "Error in a GUI handler",
            "The message gives the handler's source file and line; the debug log has the stack trace."),
    Problem("GUI-02", "Error in the display refresh",
            "The debug log has the stack trace; the display may stop updating."),
    Problem("PLAY-01", "Playback: session unreadable or incomplete",
            "A session folder holds run.toml, irf.csv and spc/*.spc (with their _acquisition.ini)."),
    Problem("JRN-01", "Journal: entries dropped or not written",
            "Disk full or slow, or the journal folder not writable ([journal] directory in config/bench.toml)."),
]

const PROBLEMS = Dict(p.id => p for p in PROBLEM_LIST)

"""
    problem_text(id, detail="")::String

"[ID] title: detail" — what the app shows and logs for a problem.
"""
function problem_text(id::AbstractString, detail::AbstractString = "")::String
    p = get(PROBLEMS, id, nothing)
    title = p === nothing ? "Unknown problem" : p.title
    return "[$id] $title" * (isempty(detail) ? "" : ": $detail")
end

"""What to check for problem `id`."""
problem_check(id::AbstractString)::String = (p = get(PROBLEMS, id, nothing); p === nothing ? "" : p.check)

# =============================================================================
# PROBLEMS SEEN THIS SESSION
# =============================================================================

"""One problem instance (`key`: the code plus what it concerns, e.g. "PASS-02/card 0")."""
mutable struct ProblemRecord
    id::String
    key::String
    text::String
    level::Symbol
    first_t::Float64
    last_t::Float64
    logged_t::Float64
    count::Int
end

"""The problems seen this session, by key; `generation` counts changes (the GUI polls it)."""
struct ProblemLog
    lock::ReentrantLock
    records::Dict{String, ProblemRecord}
    generation::Threads.Atomic{Int}
end

const PROBLEM_LOG = ProblemLog(ReentrantLock(), Dict{String, ProblemRecord}(), Threads.Atomic{Int}(0))

"""
    report_problem!(id, detail=""; level=:warn, key=id, quiet_s=60, exception=nothing)::String

Record problem `id` (any thread): logged with its code and what to check —
and `exception`, `(e, catch_backtrace())`, with its stack trace — again
only when its text changes or after `quiet_s`; counted, and shown by the
GUI (top bar, Console panel, debug report). `key` tells instances apart
("PASS-02/card 0"). Returns the text.
"""
function report_problem!(id::AbstractString, detail::AbstractString = ""; level::Symbol = :warn,
                         key::AbstractString = id, quiet_s::Real = 60, exception = nothing)::String
    text = problem_text(id, detail)
    now = time()
    log_it = false
    lock(PROBLEM_LOG.lock) do
        r = get(PROBLEM_LOG.records, key, nothing)
        if r === nothing
            PROBLEM_LOG.records[key] = ProblemRecord(String(id), String(key), text, level, now, now, now, 1)
            log_it = true
        else
            log_it = r.text != text || now - r.logged_t >= quiet_s
            r.text, r.level, r.last_t = text, level, now
            r.count += 1
            log_it && (r.logged_t = now)
        end
    end
    Threads.atomic_add!(PROBLEM_LOG.generation, 1)
    if log_it
        check = problem_check(id)
        if exception !== nothing
            @error text problem = id check = check exception = exception
        elseif level == :error
            @error text problem = id check = check
        elseif level == :info
            @info text problem = id check = check
        else
            @warn text problem = id check = check
        end
    end
    return text
end

"""Forget the problems of a previous run (codes starting with one of `prefixes`) at START."""
function clear_problems!(prefixes = ("PASS-", "ROUTE-", "FIT-02", "FIT-03", "FIT-04", "FIT-05", "SPC-07", "DAQ-05", "DAQ-06", "DAQ-08"))
    lock(PROBLEM_LOG.lock) do
        filter!(kv -> !any(p -> startswith(kv.second.id, p), prefixes), PROBLEM_LOG.records)
    end
    Threads.atomic_add!(PROBLEM_LOG.generation, 1)
    return nothing
end

"""The problems seen, latest first."""
function problem_records()::Vector{ProblemRecord}
    records = lock(() -> [copy_record(r) for r in values(PROBLEM_LOG.records)], PROBLEM_LOG.lock)
    return sort!(records; by = r -> r.last_t, rev = true)
end
copy_record(r::ProblemRecord) = ProblemRecord(r.id, r.key, r.text, r.level, r.first_t, r.last_t, r.logged_t, r.count)

"""One line per problem seen, latest first, for the Console panel and the debug report."""
function problem_lines(; limit::Integer = typemax(Int), with_check::Bool = false)::Vector{String}
    lines = String[]
    for r in Iterators.take(problem_records(), limit)
        stamp = Dates.format(Dates.unix2datetime(r.last_t) + local_utc_offset(), "HH:MM:SS")
        push!(lines, "$stamp $(r.text)" * (r.count > 1 ? " (×$(r.count))" : ""))
        with_check && push!(lines, "         check: " * problem_check(r.id))
    end
    return lines
end

# =============================================================================
# DEBUG LOG
# =============================================================================

"""
    DebugLogger(path; console=ConsoleLogger(stderr), keep=400)

A logger for the whole app: every record (Info and up) goes to `path` with
its time, level, thread, module, source line, values and — for an
exception — the full stack trace, flushed at once; the same records go on
to `console` as before. The last `keep` records stay in memory for the
debug report (`recent_log`). Thread-safe.
"""
mutable struct DebugLogger <: Logging.AbstractLogger
    path::String
    io::Union{Nothing, IOStream}
    console::Logging.AbstractLogger
    lock::ReentrantLock
    recent::Vector{String}
    keep::Int
    write_errors::Int
end

function DebugLogger(path::AbstractString; console::Logging.AbstractLogger = Logging.ConsoleLogger(stderr), keep::Integer = 400)
    io = try
        mkpath(dirname(path))
        open(path, "a")
    catch e
        @warn "Debug log not writable; console only" path=path error=sprint(showerror, e)
        nothing
    end
    return DebugLogger(String(path), io, console, ReentrantLock(), String[], Int(keep), 0)
end

Logging.min_enabled_level(::DebugLogger) = Logging.Info
Logging.shouldlog(::DebugLogger, args...) = true
Logging.catch_exceptions(::DebugLogger) = true

"""A log value as text: an exception with its stack trace when one comes with it."""
function format_log_value(value)
    if value isa Tuple && length(value) == 2 && value[1] isa Exception
        return sprint((io, v) -> showerror(io, v[1], v[2]), value; context = :limit => true)
    elseif value isa Exception
        return sprint(showerror, value)
    end
    return sprint(show, value; context = :limit => true)
end

function format_record(level, message, _module, file, line, kwargs)::String
    stamp = Dates.format(Dates.now(), dateformat"yyyy-mm-dd HH:MM:SS.sss")
    where = file === nothing ? "?" : "$(basename(String(file))):$(line)"
    io = IOBuffer()
    print(io, stamp, " ", uppercase(string(level)), " t", Threads.threadid(), " ", _module, " ", where, " | ", message)
    for (k, v) in kwargs
        text = format_log_value(v)
        if occursin('\n', text)
            print(io, "\n    ", k, " =\n        ", replace(text, "\n" => "\n        "))
        else
            print(io, "\n    ", k, " = ", text)
        end
    end
    return String(take!(io))
end

function Logging.handle_message(logger::DebugLogger, level, message, _module, group, id, file, line; kwargs...)
    text = try
        format_record(level, message, _module, file, line, kwargs)
    catch e
        "$(Dates.now()) $(level) | $(message) (record not formatted: $(sprint(showerror, e)))"
    end
    lock(logger.lock) do
        push!(logger.recent, text)
        length(logger.recent) > logger.keep && deleteat!(logger.recent, 1:length(logger.recent) - logger.keep)
        if logger.io !== nothing
            try
                println(logger.io, text)
                flush(logger.io)
            catch
                logger.write_errors += 1
            end
        end
    end
    console = logger.console
    if level >= Logging.min_enabled_level(console)
        Logging.handle_message(console, level, message, _module, group, id, file, line; kwargs...)
    end
    return nothing
end

"""The debug logger in use, if `install_debug_logger!` installed one."""
const DEBUG_LOGGER = Ref{Union{Nothing, DebugLogger}}(nothing)

"""
    install_debug_logger!(dir)::String

Log everything of this app session to `dir/<date>_debug.log` too (see
`DebugLogger`); returns its path. The console keeps showing what it did.
"""
function install_debug_logger!(dir::AbstractString)::String
    path = joinpath(dir, Dates.format(Dates.now(), dateformat"yyyy-mm-dd_HHMMSS") * "_debug.log")
    logger = DebugLogger(path)
    DEBUG_LOGGER[] = logger
    Logging.global_logger(logger)
    return path
end

"""The debug log's path ("" when none is installed)."""
debug_log_path()::String = DEBUG_LOGGER[] === nothing ? "" : DEBUG_LOGGER[].path

"""The last records of the debug log (all of them by default), oldest first."""
function recent_log(; limit::Integer = typemax(Int))::Vector{String}
    logger = DEBUG_LOGGER[]
    logger === nothing && return String[]
    records = lock(() -> copy(logger.recent), logger.lock)
    return records[max(1, end - limit + 1):end]
end

"""
    alert_problem_id(text)::String

The problem code of an SPC engine alert or check problem (FLIMCore writes
them in French): SYNC → SPC-03, CFD → SPC-04, FIFO → SPC-07, a setting
not applied → SPC-05, a card not ready, locked or missing → SPC-01, a
serial number → SPC-02, the imaging clocks → IMG-01, the passes → PASS-0x,
the settings file → ENV-04; any other → SPC-06.
"""
function alert_problem_id(text::AbstractString)::String
    t = lowercase(text)
    has(x) = occursin(x, t)
    has("sync") && (has("perdu") || has("état") || has("laser allumé")) && return "SPC-03"
    has("[qc] taux") && return "SPC-09"
    startswith(t, "qc-104 :") && return "SPC-10"
    (has("cfd") || has("photons comptés")) && (has("chute") || has("sous le seuil")) && return "SPC-04"
    has("fifo débordé") && return "SPC-07"
    has("réglage non appliqué") && return "SPC-05"
    has("peigne") && return "SPC-08"
    (has("introuvable") || has("série")) && return "SPC-02"
    (has("verrouill") || has("aucune carte spc") || has("pas prêt") || has("non détecté")) && return "SPC-01"
    (has("horloge de ligne") || has("aucune image")) && return "IMG-01"
    has("reglages_scanner") && return "IMG-02"
    has("m3 − m0") && return "PASS-05"
    has("sans correspondante") && return "PASS-06"
    (has("sans marqueur de fin") || has("interrompue") || has("hors cadence") || has("m0 manquant")) && return "PASS-04"
    has("hors des passes") && return "PASS-08"
    has("réglages illisibles") && return "ENV-04"
    return "SPC-06"
end

# =============================================================================
# ERROR CONTEXT
# =============================================================================

"""An error raised during `context`, wrapping its `cause` (with the cause's own stack trace)."""
struct ContextError <: Exception
    context::String
    cause::Any
    backtrace::Vector{Any}
end

Base.showerror(io::IO, e::ContextError) = (print(io, e.context, ": "); showerror(io, e.cause))

"""
    with_context(f, context)

Run `f()`; an error it raises comes out as a `ContextError` that says
`context` — the step, the task, the channel — before the original message.
"""
function with_context(f, context::AbstractString)
    try
        return f()
    catch e
        throw(ContextError(String(context), e, catch_backtrace()))
    end
end

"""The original error under any `with_context` layers."""
root_cause(e) = e isa ContextError ? root_cause(e.cause) : e

"""The contexts of an error, outermost first."""
error_contexts(e)::Vector{String} = e isa ContextError ? [e.context; error_contexts(e.cause)] : String[]

# =============================================================================
# GUI HANDLERS THAT CAN'T FAIL SILENTLY
# =============================================================================

"""Where a callback was written: "file.jl:line"."""
function callback_location(f)::String
    try
        m = first(methods(f))
        return "$(basename(String(m.file))):$(m.line)"
    catch
        return string(typeof(f))
    end
end

"""
    on(f, observable; kwargs...)

`Observables.on`, for every GUI handler of this app: an error in `f` is
logged with its stack trace and reported as GUI-01 with the handler's
source line (shown in the top bar), instead of disappearing in the
console. The handler's own return value (e.g. `Consume`) is kept.
"""
function on(f, observable::Observables.AbstractObservable; kwargs...)
    where = callback_location(f)
    guarded = function (args...)
        try
            return f(args...)
        catch e
            e isa InterruptException && rethrow()
            @error "GUI handler failed ($where)" exception = (e, catch_backtrace())
            report_problem!("GUI-01", "handler at $where: " * first(split(sprint(showerror, e), '\n')); level = :error,
                            key = "GUI-01/$where", quiet_s = 5)
            return nothing
        end
    end
    return Observables.on(guarded, observable; kwargs...)
end

# =============================================================================
# REALTIME PASSES: WHAT THE CARDS RECEIVED
# =============================================================================

const Diagnosis = NamedTuple{(:id, :key, :detail), Tuple{String, String, String}}

ms_text(x) = isfinite(x) ? @sprintf("%.3f", 1000x) : "?"

"""
    diagnose_passes(state::FLIMCore.EtatClamp; daq_slots=nothing)::Vector{Diagnosis}

What the counters of a Realtime measurement say about the pass signal and
the routing code, card by card (see `FLIMCore.CompteursCarte`): no photon
(PASS-01), the pass signal on M1/M2 (PASS-07), no M0 (PASS-02), no M3
(PASS-03), M0 and M3 counts apart (PASS-04), passes of the wrong length —
the pause's length meaning swapped edges — (PASS-05), passes unpaired
between cards (PASS-06), photons lost (SPC-07), many ROI-coded photons
outside the passes (PASS-08), and, from the photons read during passes, a
missing routing code (ROUTE-01), the inverted code (ROUTE-02), a stuck line
(ROUTE-03) or other codes (ROUTE-04). Absences are only concluded after 3 s
(or at the end).

`daq_slots`: the slots the DAQ loop played meanwhile (`nothing`: unknown,
e.g. Playback). No marker on any card while it played none: the pass signal
was never generated (PASS-09, not a wiring problem); while it played some:
the signal is generated but doesn't reach the cards — on every card, the
common part (the PFI13 wire, the BOB, the ground).
"""
function diagnose_passes(state::FLIMCore.EtatClamp; daq_slots::Union{Nothing, Integer} = nothing)::Vector{Diagnosis}
    out = Diagnosis[]
    add!(id, c, detail) = push!(out, (id = id, key = "$id/card $(c.carte)", detail = detail))
    settled = state.fin || state.duree_s >= 3.0
    elapsed = @sprintf("%.1f s", state.duree_s)
    for c in state.cartes
        name = "card $(c.carte) (channel $(c.canal)" * (isempty(c.serie) ? ")" : ", $(c.serie))")
        m0, m1, m2, m3 = c.marqueurs
        in_pass = sum(c.photons_par_code)
        if settled && c.photons == 0
            add!("PASS-01", c, "$name: no photon in $elapsed ($(c.mots) FIFO words)")
            continue
        end
        if settled && m0 == 0 && m3 == 0 && m1 + m2 > 0
            add!("PASS-07", c, "$name: $m1 M1 and $m2 M2 edges, no M0/M3 in $elapsed")
        elseif settled && m0 == 0
            add!("PASS-02", c, "$name: $(c.photons) photons but no M0 edge in $elapsed" * (m3 > 0 ? " ($m3 M3 edges)" : ""))
        elseif state.fin_par_m3 && settled && m3 == 0
            add!("PASS-03", c, "$name: $m0 M0 edges, no M3 in $elapsed")
        elseif state.fin_par_m3 && abs(m0 - m3) > 1
            add!("PASS-04", c, "$name: $m0 M0 vs $m3 M3 edges, $(c.abandonnees) pass(es) abandoned")
        elseif !state.fin_par_m3 && (c.m0_manquants > 0 || c.hors_duree > 0)
            period = state.scan_s + state.pause_s
            add!("PASS-04", c, "$name: $(c.m0_manquants) M0 missing, $(c.hors_duree) off the cadence (ignored); M0 → M0 from " *
                               "$(ms_text(c.intervalle_min_s)) to $(ms_text(c.intervalle_max_s)) ms, slot $(ms_text(period)) ± $(ms_text(state.tolerance_s)) ms")
        end
        if state.fin_par_m3 && c.passes > 0 && isfinite(state.scan_s) && isfinite(state.tolerance_s)
            off(d) = isfinite(d) && abs(d - state.scan_s) > state.tolerance_s
            if off(c.duree_min_s) || off(c.duree_max_s)
                swapped = isfinite(state.pause_s) && isfinite(c.duree_derniere_s) &&
                          abs(c.duree_derniere_s - state.pause_s) <= max(state.tolerance_s, 0.01 * state.pause_s)
                add!("PASS-05", c, "$name: M3 − M0 from $(ms_text(c.duree_min_s)) to $(ms_text(c.duree_max_s)) ms (last $(ms_text(c.duree_derniere_s)) ms), " *
                                   "programmed $(ms_text(state.scan_s)) ± $(ms_text(state.tolerance_s)) ms, $(c.hors_duree) pass(es) off" *
                                   (swapped ? "; it equals the pause: M0/M3 edges swapped" : ""))
            end
        end
        c.sans_partenaire > 0 && add!("PASS-06", c, "$name: $(c.sans_partenaire) pass(es) without a partner on the other card")
        if c.fifo_deborde || c.pertes > 0
            add!("SPC-07", c, "$name: " * (c.fifo_deborde ? "SPC_FOVFL set, " : "") * "$(c.pertes) GAP record(s)")
        end
        if in_pass >= 100 && c.hors_passe > 0.05 * in_pass
            add!("PASS-08", c, "$name: $(c.hors_passe) ROI-coded photons outside the passes, $in_pass inside")
        end

        # Routing: needs enough photons read during passes.
        in_pass >= 200 || continue
        reserved = c.photons_par_code[FLIMCore.CODE_HORS_ROI + 1]
        if reserved > 0.9 * in_pass
            add!("ROUTE-01", c, @sprintf("%s: %.0f %% of the %d photons read during passes carry code 0", name, 100 * reserved / in_pass, in_pass))
            continue
        end
        coded = in_pass - reserved
        seen = [code for code in 1:15 if c.photons_par_code[code + 1] > max(0.01 * coded, 5)]
        # A share of code 0 during passes (normally a few photons at their
        # edges): some written code reads as 0, e.g. a line stuck low.
        reserved > 0.1 * in_pass && pushfirst!(seen, FLIMCore.CODE_HORS_ROI)
        expected = filter(!=(FLIMCore.CODE_HORS_ROI), sort(unique(state.codes)))
        (isempty(expected) || issubset(seen, expected)) && continue
        inverted = [15 - x for x in expected]
        if !isempty(seen) && issubset(seen, inverted) && isempty(intersect(seen, expected))
            add!("ROUTE-02", c, "$name: codes $(seen) read, the NOT of the $(expected) written")
            continue
        end
        # Stuck lines: a bit written but never read high, or read high but
        # never written low. Only if they explain every code read (else
        # lines swapped or crosstalk: ROUTE-04).
        or_seen, and_seen = reduce(|, seen; init = 0), reduce(&, seen; init = 15)
        or_written, and_written = reduce(|, expected; init = 0), reduce(&, expected; init = 15)
        stuck_low = [b for b in 0:3 if (or_written & (1 << b) != 0) && (or_seen & (1 << b) == 0)]
        stuck_high = [b for b in 0:3 if (and_written & (1 << b) == 0) && (and_seen & (1 << b) != 0)]
        low_mask, high_mask = reduce(|, (1 << b for b in stuck_low); init = 0), reduce(|, (1 << b for b in stuck_high); init = 0)
        predicted = unique([(code & ~low_mask) | high_mask for code in expected])
        stuck = vcat(["R$b (P0.$(4 + b)) never high" for b in stuck_low], ["R$b (P0.$(4 + b)) always high" for b in stuck_high])
        if !isempty(stuck) && issubset(seen, predicted)
            add!("ROUTE-03", c, "$name: $(join(stuck, ", ")); codes $(seen) read, $(expected) written")
        else
            add!("ROUTE-04", c, "$name: codes $(seen) read, $(expected) written")
        end
    end
    # No M0 on any card: was the pass signal generated at all?
    no_m0 = filter(d -> d.id == "PASS-02", out)
    if !isempty(no_m0) && length(no_m0) == length(state.cartes) && daq_slots !== nothing
        filter!(d -> d.id != "PASS-02", out)
        if daq_slots == 0
            push!(out, (id = "PASS-09", key = "PASS-09", detail = "no M0 edge on any card in $elapsed, and the DAQ loop played no slot"))
        else
            common = length(state.cartes) > 1 ? "; on every card: look at the common part (the PFI13 wire, the BOB, the ground)" : ""
            for d in no_m0
                push!(out, (id = d.id, key = d.key, detail = d.detail * "; the DAQ loop played $daq_slots slot(s), " *
                                                              "so the counter runs and its signal doesn't reach the card" * common))
            end
        end
    elseif !isempty(no_m0) && daq_slots !== nothing && daq_slots > 0
        for (k, d) in enumerate(out)
            d.id == "PASS-02" && (out[k] = (id = d.id, key = d.key, detail = d.detail * "; the DAQ loop played $daq_slots slot(s): " *
                                                                                       "the signal reaches the other card, not this one"))
        end
    end
    if length(state.cartes) == 2 && state.duree_s >= 3.0
        a, b = state.cartes
        abs(a.passes - b.passes) > 2 &&
            push!(out, (id = "PASS-06", key = "PASS-06/cards", detail = "card $(a.carte) completed $(a.passes) passes, card $(b.carte) $(b.passes)"))
    end
    return out
end

"""One line per card of an `EtatClamp`, for the Console panel and the debug report."""
function pass_status_lines(state::FLIMCore.EtatClamp)::Vector{String}
    lines = [@sprintf("Realtime counters at %.1f s%s: %d pass(es) published, codes written %s, scan %s ms, %s",
                      state.duree_s, state.fin ? " (end)" : "", state.publiees, string(state.codes), ms_text(state.scan_s),
                      state.fin_par_m3 ? "end of pass on M3" : "M0 only (pass = scan after M0)")]
    for c in state.cartes
        codes = join(["$(k - 1):$(n)" for (k, n) in enumerate(c.photons_par_code) if n > 0], " ")
        push!(lines, @sprintf("  card %d ch%d %s: photons %d, M0 %d M1 %d M2 %d M3 %d, passes %d (abandoned %d, off %d, unpaired %d, queued %d)",
                              c.carte, c.canal, c.serie, c.photons, c.marqueurs..., c.passes, c.abandonnees, c.hors_duree,
                              c.sans_partenaire, c.en_attente))
        push!(lines, "    pass $(ms_text(c.duree_min_s))…$(ms_text(c.duree_max_s)) ms, M0 → M0 $(ms_text(c.intervalle_min_s))…$(ms_text(c.intervalle_max_s)) ms, " *
                     (state.fin_par_m3 ? "" : "M0 missing $(c.m0_manquants), ") *
                     "thrown (code 0) $(c.hors_roi), outside passes $(c.hors_passe), GAP $(c.pertes)" *
                     (c.fifo_deborde ? ", FIFO OVERFLOW" : "") * "; in passes by code: " * (isempty(codes) ? "none" : codes))
    end
    return lines
end

# =============================================================================
# ANALYSIS WORKER
# =============================================================================

"""
    WorkerStats()

The analysis worker's counters (written by the worker, read by the GUI
once a second): passes taken, fits that failed per channel, passes kept
out of the PI and why, passes not analyzed and the routing codes they
carried, the most passes waiting and the longest analysis of one pass.
"""
mutable struct WorkerStats
    passes::Threads.Atomic{Int}
    fits_failed::NTuple{2, Threads.Atomic{Int}}
    excluded::Threads.Atomic{Int}
    unmatched::Threads.Atomic{Int}
    unmatched_codes::Threads.Atomic{Int}
    backlog_max::Threads.Atomic{Int}
    pass_max_ns::Threads.Atomic{Int}
    lock::ReentrantLock
    reasons::Dict{String, Int}
end

WorkerStats() = WorkerStats(Threads.Atomic{Int}(0), (Threads.Atomic{Int}(0), Threads.Atomic{Int}(0)), Threads.Atomic{Int}(0),
                            Threads.Atomic{Int}(0), Threads.Atomic{Int}(0), Threads.Atomic{Int}(0), Threads.Atomic{Int}(0),
                            ReentrantLock(), Dict{String, Int}())

"""A pass kept out of the PI: its reasons (`HistoClamp.motifs`), counted by kind (the card left out)."""
function count_exclusion!(stats::WorkerStats, reasons::AbstractVector{<:AbstractString})
    Threads.atomic_add!(stats.excluded, 1)
    lock(stats.lock) do
        for r in reasons
            kind = replace(r, r"^module \d+ : " => "")
            kind = occursin("M3 − M0", kind) ? "M3 − M0 off the programmed scan" :
                   occursin("GAP", kind) ? "GAP records (photons lost)" :
                   occursin("SPC_FOVFL", kind) ? "FIFO overflow (SPC_FOVFL)" : kind
            stats.reasons[kind] = get(stats.reasons, kind, 0) + 1
        end
    end
    return nothing
end

"""
    diagnose_worker(stats; check_backlog=true)::Vector{Diagnosis}

Fits failing on more than a tenth of the passes (FIT-02), passes piling up
(FIT-03; not in a Playback faster than the experiment, where they do by
design: `check_backlog = false`), passes kept out of the PI (FIT-04),
passes not analyzed for their routing code (ROUTE-05).
"""
function diagnose_worker(stats::WorkerStats; check_backlog::Bool = true)::Vector{Diagnosis}
    out = Diagnosis[]
    n = stats.passes[]
    for c in 1:2
        failed = stats.fits_failed[c][]
        n >= 10 && failed > 0.1 * n &&
            push!(out, (id = "FIT-02", key = "FIT-02/channel $c", detail = "channel $c: $failed of $n fits failed"))
    end
    backlog = stats.backlog_max[]
    check_backlog && backlog > 20 && push!(out, (id = "FIT-03", key = "FIT-03", detail = "up to $backlog passes waiting; longest pass analysis " *
                                                                      @sprintf("%.0f ms", stats.pass_max_ns[] / 1e6)))
    excluded = stats.excluded[]
    if excluded > 0
        reasons = lock(() -> join(["$k ×$v" for (k, v) in sort!(collect(stats.reasons); by = last, rev = true)], ", "), stats.lock)
        push!(out, (id = "FIT-04", key = "FIT-04", detail = "$excluded of $n passes: $reasons"))
    end
    unmatched = stats.unmatched[]
    if unmatched > 0
        mask = stats.unmatched_codes[]
        codes = [code for code in 0:15 if mask & (1 << code) != 0]
        push!(out, (id = "ROUTE-05", key = "ROUTE-05", detail = "$unmatched pass(es), codes read " *
                                                               (isempty(codes) ? "none (no photon with a ROI code)" : string(codes))))
    end
    return out
end
