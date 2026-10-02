"""
journal.jl

The journal thread: the only code that writes to disk continuously. It
empties `Exchange.journal` about once a second (`journal_flush_s`) and
writes the batch, so no other thread ever waits on a file.

`journal_root(cfg)` holds app.log, the events outside any run. Each run is
a session folder under the recording folder (`sessions_root`,
analysis/session.jl; `[enregistrement] dossier` in config/spc.toml):

    <recording folder>/sessions/
      2026-09-28_101500/          one folder per START (`new_run_dir`)
        run.toml                  mode, versions, ROIs (routing codes, fitted channel)
                                  and their calibration, SPC and DAQ settings,
                                  layout/controller/protocol settings at START
        irf.csv, irf.toml         the IRF of each channel the fit used, and the
                                  settings it was taken with
        log.txt                   events during the run
        frames.csv                one line per analyzed pass (one scan of one ROI):
                                  pass times, setpoint, Kalman, PI outputs (simulated
                                  in Playback), why a pass was kept out of the PI
        visits.csv                one line per slot played by the DAQ loop
        readback.bin              every readback sample, Float32, sample-major
        readback.txt              what readback.bin holds (signals, rate, layout)
        spc/                      written by the SPC engine (Realtime): for each
                                  card, its FIFO stream <serial>.spc,
                                  <serial>_acquisition.ini and the parameters
                                  read back from it, <serial>_parametres.ini

A session folder is what Playback replays (`FLIMCore.source_session`).

Entries for a run that isn't open (e.g. a readback slot arriving after the
run was closed) are counted and discarded, never written to the wrong run.
"""

using Dates
using TOML

mutable struct JournalWriter
    root::String
    run_dir::Union{Nothing, String}
    app_log::Union{Nothing, IOStream}
    run_log::Union{Nothing, IOStream}
    frames_csv::Union{Nothing, IOStream}
    visits_csv::Union{Nothing, IOStream}
    readback_bin::Union{Nothing, IOStream}
    readback_samples::Int
    readback_signals::Vector{String}
    readback_rate_hz::Float64
    orphans::Int
    write_errors::Int
end

JournalWriter(root::AbstractString) = JournalWriter(String(root), nothing, nothing, nothing, nothing, nothing, nothing, 0, String[], NaN, 0, 0)

const FRAMES_CSV_HEADER = "frame_index,pass,roi_index,pass_start_s,pass_end_s,timestamp_s,complete,excluded_because,acquired_unix_s,protocol_setpoint_ns,command1,command2,photons_ch1,lifetime_ch1_ns,lifetime_kalman_ch1_ns,concentration_ch1,photons_ch2,lifetime_ch2_ns,lifetime_kalman_ch2_ns,concentration_ch2"
const VISITS_CSV_HEADER = "slot,roi,visit,first_sample,command1_v,command2_v,iteration_ms,margin_ms"

"""
    journal_loop(cfg, ex)

Body of the journal thread (`Threads.@spawn` at startup). Runs until
`ex.shutdown` is set, then writes whatever is still queued and closes
every file.
"""
function journal_loop(cfg::BenchConfig, ex::Exchange)
    writer = JournalWriter(journal_root(cfg))
    batch = JournalEntry[]
    step_s = 0.05

    try
        while true
            empty!(batch)
            drain_journal!(batch, ex.journal)
            for entry in batch
                try
                    write_entry!(writer, entry)
                catch e
                    writer.write_errors += 1
                    writer.write_errors <= 5 && report_problem!("JRN-01", "writing a $(nameof(typeof(entry))) to " *
                                                                    something(writer.run_dir, writer.root) * ": " * sprint(showerror, e);
                                                                    level = :error, key = "JRN-01/write", exception = (e, catch_backtrace()))
                end
            end
            flush_journal!(writer)

            ex.shutdown[] && pending_journal(ex.journal) == 0 && break

            # Sleep for the batch interval, but notice a shutdown quickly.
            waited = 0.0
            while waited < cfg.journal_flush_s && !ex.shutdown[]
                sleep(step_s)
                waited += step_s
            end
        end
    finally
        close_run!(writer, time())
        writer.app_log === nothing || close(writer.app_log)
        writer.app_log = nothing
    end

    return nothing
end

# Dates has no time zones: the local offset is now() - now(UTC), rounded to
# the minute (the two calls are a few microseconds apart).
local_utc_offset() = Dates.Minute(round(Int, Dates.value(Dates.now() - Dates.now(Dates.UTC)) / 60_000))
local_datetime(t::Float64) = Dates.unix2datetime(t) + local_utc_offset()
timestamp_string(t::Float64) = Dates.format(local_datetime(t), dateformat"yyyy-mm-ddTHH:MM:SS.sss")

csv_field(x::AbstractString) = occursin(r"[,\"\n]", x) ? "\"" * replace(x, "\"" => "\"\"") * "\"" : x
csv_field(x::Real) = isfinite(x) ? string(x) : ""
csv_field(::Nothing) = ""
csv_field(x) = string(x)
csv_line(values...) = join((csv_field(v) for v in values), ",")

function app_log!(writer::JournalWriter)::IOStream
    if writer.app_log === nothing
        mkpath(writer.root)
        writer.app_log = open(joinpath(writer.root, "app.log"), "a")
    end
    return writer.app_log
end

function write_entry!(writer::JournalWriter, entry::JournalEvent)
    io = writer.run_log === nothing ? app_log!(writer) : writer.run_log
    println(io, timestamp_string(entry.time), " ", uppercase(String(entry.level)), " ", entry.message)
    return nothing
end

"""
    new_run_dir(root, t)::String

Create the folder of a run started at `t` (unix seconds) under `root`:
`yyyy-mm-dd_HHMMSS` plus `suffix` (e.g. "_playback"), then `_2`, `_3`… if
that name is taken. START calls it (the SPC engine records the cards'
streams under its spc/ before the journal thread opens the run,
`JournalRunStart`).
"""
function new_run_dir(root::AbstractString, t::Float64; suffix::AbstractString = "")::String
    name = Dates.format(local_datetime(t), dateformat"yyyy-mm-dd_HHMMSS") * suffix
    dir = joinpath(root, name)
    suffix = 1
    while isdir(dir)
        suffix += 1
        dir = joinpath(root, "$(name)_$(suffix)")
    end
    mkpath(dir)
    return dir
end

function write_entry!(writer::JournalWriter, entry::JournalRunStart)
    close_run!(writer, entry.time)

    dir = entry.dir
    mkpath(dir)

    open(joinpath(dir, "run.toml"), "w") do io
        TOML.print(io, entry.info; sorted=true)
    end
    isempty(entry.irfs) || write_irf_csv(joinpath(dir, "irf.csv"), entry.irfs)
    isempty(entry.irf_info) || write_irf_info(joinpath(dir, "irf.toml"), entry.irf_info)

    writer.run_dir = dir
    writer.run_log = open(joinpath(dir, "log.txt"), "a")
    writer.frames_csv = open(joinpath(dir, "frames.csv"), "w")
    println(writer.frames_csv, FRAMES_CSV_HEADER)
    writer.readback_samples = 0

    println(app_log!(writer), timestamp_string(entry.time), " INFO run started: ", dir)
    println(writer.run_log, timestamp_string(entry.time), " INFO run started")
    return nothing
end

function write_entry!(writer::JournalWriter, entry::JournalRunEnd)
    close_run!(writer, entry.time)
    return nothing
end

function write_entry!(writer::JournalWriter, entry::JournalFrame)
    io = writer.frames_csv
    if io === nothing
        writer.orphans += 1
        return nothing
    end
    s = entry.record.sample
    println(io, csv_line(
        Int(s.frame_index), s.pass, entry.record.roi_index,
        s.pass_start_s, s.pass_end_s, s.timestamps, Int(s.complete), s.excluded_because, s.acquired_at,
        s.protocol_setpoint, s.command1, s.command2,
        s.ch1.photons, s.ch1.lifetime, s.ch1.lifetime_kalman, s.ch1.concentration,
        s.ch2.photons, s.ch2.lifetime, s.ch2.lifetime_kalman, s.ch2.concentration
    ))
    return nothing
end

function write_entry!(writer::JournalWriter, entry::JournalVisit)
    if writer.run_dir === nothing
        writer.orphans += 1
        return nothing
    end
    if writer.visits_csv === nothing
        writer.visits_csv = open(joinpath(writer.run_dir, "visits.csv"), "w")
        println(writer.visits_csv, VISITS_CSV_HEADER)
    end
    s = entry.summary
    println(writer.visits_csv, csv_line(
        s.slot, s.roi, s.visit, entry.first_sample, s.command1_v, s.command2_v,
        1000 * s.iteration_s, 1000 * s.margin_s
    ))
    return nothing
end

function write_entry!(writer::JournalWriter, entry::JournalReadbackStart)
    if writer.run_dir === nothing
        writer.orphans += 1
        return nothing
    end
    # A second scan in the same run (e.g. after a fault was acknowledged)
    # appends to the same file rather than truncating the first one.
    if writer.readback_bin !== nothing
        entry.signals == writer.readback_signals && entry.sample_rate_hz == writer.readback_rate_hz ||
            @warn "Readback layout changed within a run; appending anyway" run=writer.run_dir
        println(writer.run_log, timestamp_string(time()), " INFO new scan: readback continues at sample ", writer.readback_samples + 1)
        return nothing
    end
    writer.readback_signals = copy(entry.signals)
    writer.readback_rate_hz = entry.sample_rate_hz
    writer.readback_bin = open(joinpath(writer.run_dir, "readback.bin"), "w")
    writer.readback_samples = 0
    open(joinpath(writer.run_dir, "readback.txt"), "w") do io
        println(io, "readback.bin: Float32, little-endian, sample-major (all signals of sample 1, then sample 2, ...)")
        println(io, "sample_rate_hz = ", entry.sample_rate_hz)
        println(io, "signals = ", join(entry.signals, ", "))
        println(io, "sample 1 is the first sample generated (before the first slot: the move onto the first ROI)")
        println(io, "Julia: reshape(reinterpret(Float32, read(\"readback.bin\")), $(length(entry.signals)), :)")
    end
    return nothing
end

function write_entry!(writer::JournalWriter, entry::JournalReadback)
    try
        io = writer.readback_bin
        if io === nothing
            writer.orphans += 1
            return nothing
        end
        buffer = entry.pool.buffers[entry.index]
        n_values = size(buffer, 1) * entry.n_samples
        GC.@preserve buffer unsafe_write(io, pointer(buffer), n_values * sizeof(Float32))
        writer.readback_samples += entry.n_samples
    finally
        release!(entry.pool, entry.index)
    end
    return nothing
end

function flush_journal!(writer::JournalWriter)
    for io in (writer.app_log, writer.run_log, writer.frames_csv, writer.visits_csv, writer.readback_bin)
        io === nothing || flush(io)
    end
    return nothing
end

function close_run!(writer::JournalWriter, t::Float64)
    writer.run_dir === nothing && return nothing

    if writer.run_log !== nothing
        writer.orphans > 0 && println(writer.run_log, timestamp_string(t), " WARN ", writer.orphans, " journal entries arrived outside a run and were discarded")
        println(writer.run_log, timestamp_string(t), " INFO run closed; readback samples written: ", writer.readback_samples)
    end
    for io in (writer.run_log, writer.frames_csv, writer.visits_csv, writer.readback_bin)
        io === nothing || close(io)
    end

    writer.run_log = nothing
    writer.frames_csv = nothing
    writer.visits_csv = nothing
    writer.readback_bin = nothing
    writer.run_dir = nothing
    writer.orphans = 0
    return nothing
end
