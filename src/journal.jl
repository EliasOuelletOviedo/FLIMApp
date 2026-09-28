"""
journal.jl

The journal thread: the only code that writes to disk continuously. It
empties `Exchange.journal` about once a second (`journal_flush_s`) and
writes the batch, so no other thread ever waits on a file.

Layout under `journal_root(cfg)`:

    app.log                       events outside any run
    2026-09-28_101500/            one folder per START
        run.toml                  mode, config, settings at START
        log.txt                   events during the run
        files.csv                 one line per analyzed .sdt file
        visits.csv                one line per slot played by the DAQ loop
        readback.bin              every readback sample, Float32, sample-major
        readback.txt              what readback.bin holds (signals, rate, layout)

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
    files_csv::Union{Nothing, IOStream}
    visits_csv::Union{Nothing, IOStream}
    readback_bin::Union{Nothing, IOStream}
    readback_samples::Int
    readback_signals::Vector{String}
    readback_rate_hz::Float64
    orphans::Int
    write_errors::Int
end

JournalWriter(root::AbstractString) = JournalWriter(String(root), nothing, nothing, nothing, nothing, nothing, nothing, 0, String[], NaN, 0, 0)

const FILES_CSV_HEADER = "frame_index,source_file,file_sequence_number,roi_index,timestamp_s,file_time_unix_s,protocol_setpoint_ns,command1,command2,photons_ch1,lifetime_ch1_ns,concentration_ch1,photons_ch2,lifetime_ch2_ns,concentration_ch2"
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
                    writer.write_errors <= 5 && @warn "Journal write failed" entry=typeof(entry) error=string(e)
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

function write_entry!(writer::JournalWriter, entry::JournalRunStart)
    close_run!(writer, entry.time)

    name = Dates.format(local_datetime(entry.time), dateformat"yyyy-mm-dd_HHMMSS")
    dir = joinpath(writer.root, name)
    suffix = 1
    while isdir(dir)
        suffix += 1
        dir = joinpath(writer.root, "$(name)_$(suffix)")
    end
    mkpath(dir)

    open(joinpath(dir, "run.toml"), "w") do io
        TOML.print(io, entry.info; sorted=true)
    end

    writer.run_dir = dir
    writer.run_log = open(joinpath(dir, "log.txt"), "a")
    writer.files_csv = open(joinpath(dir, "files.csv"), "w")
    println(writer.files_csv, FILES_CSV_HEADER)
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
    io = writer.files_csv
    if io === nothing
        writer.orphans += 1
        return nothing
    end
    s = entry.record.sample
    println(io, csv_line(
        Int(s.frame_index), s.source_file, s.file_sequence_number, entry.record.roi_index,
        s.timestamps, s.file_time, s.protocol_setpoint, s.command1, s.command2,
        s.ch1.photons, s.ch1.lifetime, s.ch1.concentration,
        s.ch2.photons, s.ch2.lifetime, s.ch2.concentration
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
    writer.readback_signals = copy(entry.signals)
    writer.readback_rate_hz = entry.sample_rate_hz
    writer.readback_bin === nothing || close(writer.readback_bin)
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
    for io in (writer.app_log, writer.run_log, writer.files_csv, writer.visits_csv, writer.readback_bin)
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
    for io in (writer.run_log, writer.files_csv, writer.visits_csv, writer.readback_bin)
        io === nothing || close(io)
    end

    writer.run_log = nothing
    writer.files_csv = nothing
    writer.visits_csv = nothing
    writer.readback_bin = nothing
    writer.run_dir = nothing
    writer.orphans = 0
    return nothing
end
