"""
exchange.jl

The only point of contact between the app's threads. Each thread owns its
own files (gui/ = main thread, analysis/ = analysis worker, loop/ = DAQ
loop, journal.jl = journal); anything two of them share goes through one of
the exchanges below, none of which can make the DAQ loop wait:

| Exchange            | Type                          | Direction            |
|---------------------|-------------------------------|----------------------|
| display data        | `Ring` (lock, overwrite)      | analysis/loop → GUI  |
| loop commands       | `Channel{LoopCommand}`        | GUI → loop           |
| stop                | `Threads.Atomic{Bool}`        | GUI → loop           |
| PI command values   | `Threads.Atomic{Float64}`, 2 per ROI | analysis → loop |
| analysis settings   | `SettingsBox` (`@atomic`)     | GUI → analysis       |
| journal             | `JournalQueue` (lock, drops)  | everyone → journal   |
| loop status         | `StatusBox` (`@atomic`)       | loop → GUI           |

Rule of thumb: whoever writes holds a lock for a few microseconds at most,
and nobody ever waits for another thread's work — the reader copies what's
there, the writer drops (and counts) what doesn't fit.
"""

using Base.Threads

# =============================================================================
# RING: fixed capacity, oldest overwritten
# =============================================================================

"""
    Ring{T}(capacity)

Fixed-capacity buffer from one writer thread to the GUI refresh tick. The
writer stores one item under the lock; the reader copies everything written
since its own cursor (`take_new!`). If the reader falls more than
`capacity` items behind, the oldest are overwritten and reported as lost.
"""
mutable struct Ring{T}
    lock::ReentrantLock
    items::Vector{T}
    written::Int
end

Ring{T}(capacity::Integer) where T = Ring{T}(ReentrantLock(), Vector{T}(undef, capacity), 0)

function publish!(ring::Ring{T}, item::T) where T
    lock(ring.lock)
    try
        ring.written += 1
        @inbounds ring.items[mod1(ring.written, length(ring.items))] = item
    finally
        unlock(ring.lock)
    end
    return nothing
end

"""
    take_new!(out, ring, cursor) -> (new_cursor, lost)

Append to `out` every item written since `cursor` (the value this function
returned last time; 0 at first). `lost` counts items overwritten before
they could be read.
"""
function take_new!(out::Vector{T}, ring::Ring{T}, cursor::Int) where T
    lock(ring.lock)
    try
        capacity = length(ring.items)
        first_available = max(cursor + 1, ring.written - capacity + 1)
        lost = first_available - (cursor + 1)
        for i in first_available:ring.written
            push!(out, @inbounds ring.items[mod1(i, capacity)])
        end
        return ring.written, lost
    finally
        unlock(ring.lock)
    end
end

"""
    reset_cursor(ring)::Int

Cursor that skips everything already written — for a reader starting fresh
(a new run) that doesn't want the previous run's items.
"""
function reset_cursor(ring::Ring)::Int
    lock(ring.lock)
    try
        return ring.written
    finally
        unlock(ring.lock)
    end
end

# =============================================================================
# PAYLOADS
# =============================================================================

"""
    FrameRecord

One analyzed histogram as published by the analysis worker: its results
plus the drawn index of its ROI (1 without ROIs) — the routing code the
cards read during the pass (`pass_roi`, analysis/acquisition.jl).
"""
struct FrameRecord
    sample::AcquisitionSample
    roi_index::Int
end

"""
    SlotSummary

One slot played by the DAQ loop (slot `slot` = visit `visit` of ROI `roi`:
drawn ROI index — 0 when the galvos don't scan —, 0-based slot and visit):
the command voltages written for it, and the loop iteration that followed
it: `iteration_s` to prepare and write the slot `lead` slots ahead,
`margin_s` of written samples the card still had when that iteration
started, against `deadline_s`, the most the card can ever have (plan §3:
an iteration longer than half the deadline raises the alarm).
"""
struct SlotSummary
    slot::Int
    roi::Int
    visit::Int
    command1_v::Float64
    command2_v::Float64
    iteration_s::Float64
    margin_s::Float64
    deadline_s::Float64
end

"""
    ScanRequest

Everything the DAQ loop needs to build the slot pattern, copied from the
GUI's state at START (the loop never reads `AppState`/`AppRun` itself).
`order` is the ROI visiting order (`roi_visit_order`, roi_geometry.jl). The
galvos scan the ROIs only when `roi_active` and `rois` isn't empty;
otherwise they stay at 0 V with the same scan/pause rhythm.
`invert_routing` (`[clamp] inverser_routage` in config/spc.toml): write
NOT(code) on P0.4–P0.7 so the SPC card, whose routing inputs are active
low, reads the code itself.
"""
struct ScanRequest
    rois::Vector{RoiCoordinates}
    order::Vector{Int}
    roi_active::Bool
    v_min_x::Int64
    v_max_x::Int64
    v_min_y::Int64
    v_max_y::Int64
    points_per_roi::Int
    spiral_turns::Int
    scan_time_ms::Int
    shift_time_ms::Int
    image_size::Tuple{Int, Int}
    invert_routing::Bool
end

ScanRequest(rois, order, roi_active, v_min_x, v_max_x, v_min_y, v_max_y, points_per_roi, spiral_turns,
            scan_time_ms, shift_time_ms, image_size) =
    ScanRequest(rois, order, roi_active, v_min_x, v_max_x, v_min_y, v_max_y, points_per_roi, spiral_turns,
                scan_time_ms, shift_time_ms, image_size, true)

"""
    AnalysisSettings

The settings the analysis worker reads on every frame: copies, never
mutated after being published (the GUI publishes a fresh one whenever the
user changes something, see `publish_analysis_settings!` in gui/refresh.jl).
"""
struct AnalysisSettings
    layout::LayoutSettings
    controller::ControllerSettings
    protocol::ProtocolSettings
end

AnalysisSettings() = AnalysisSettings(LayoutSettings(), ControllerSettings(), ProtocolSettings())

mutable struct SettingsBox
    @atomic value::AnalysisSettings
end

# =============================================================================
# LOOP COMMANDS AND STATUS
# =============================================================================

"""
    LoopState

The DAQ loop's state machine (plan §7): `LOOP_DISCONNECTED` until CONNECT;
`LOOP_INIT` while checking and zeroing the cards; `LOOP_READY` idle with
everything at zero; `LOOP_RUNNING` while slots play; `LOOP_STOPPING` while
tasks stop and outputs are zeroed (then back to ready); `LOOP_FAULT` after
an error or a missed deadline, until acknowledged.
"""
@enum LoopState LOOP_DISCONNECTED LOOP_INIT LOOP_READY LOOP_RUNNING LOOP_STOPPING LOOP_FAULT

struct LoopStatus
    state::LoopState
    message::String
end

mutable struct StatusBox
    @atomic status::LoopStatus
end

abstract type LoopCommand end
struct ConnectCommand <: LoopCommand end
struct DisconnectCommand <: LoopCommand end
struct StartCommand <: LoopCommand
    request::ScanRequest
end
struct AcknowledgeCommand <: LoopCommand end
struct QuitCommand <: LoopCommand end

const LOOP_COMMAND_CAPACITY = 16

# =============================================================================
# READBACK: pool for the journal, latest slot for the display
# =============================================================================

"""
    ReadbackPool(n_signals, n_samples, n_buffers)

Preallocated slot-sized readback buffers, so the loop hands a whole slot of
readback to the journal without allocating: it `acquire!`s a free buffer,
fills it, sends its index; the journal writes it and `release!`s it. No
free buffer (journal behind) means the slot's readback is dropped and
counted, never that the loop waits.
"""
struct ReadbackPool
    lock::ReentrantLock
    buffers::Vector{Matrix{Float32}}
    free::Vector{Int}
end

ReadbackPool(n_signals::Integer, n_samples::Integer, n_buffers::Integer) =
    ReadbackPool(ReentrantLock(), [zeros(Float32, n_signals, n_samples) for _ in 1:n_buffers], collect(n_buffers:-1:1))

function acquire!(pool::ReadbackPool)::Int
    lock(pool.lock)
    try
        return isempty(pool.free) ? 0 : pop!(pool.free)
    finally
        unlock(pool.lock)
    end
end

function release!(pool::ReadbackPool, index::Int)
    lock(pool.lock)
    try
        push!(pool.free, index)
    finally
        unlock(pool.lock)
    end
    return nothing
end

"""
    ReadbackView

Latest completed slot's readback, decimated for display: the loop copies
it in under the lock at each slot end, the GUI copies it out when
`version` changed. `data` is `n_signals × n_points`, one point every
`dt_s` seconds from the start of slot `slot`.
"""
mutable struct ReadbackView
    lock::ReentrantLock
    data::Matrix{Float32}
    n_points::Int
    dt_s::Float64
    slot::Int
    version::Int
    signals::Vector{String}
end

ReadbackView() = ReadbackView(ReentrantLock(), zeros(Float32, 0, 0), 0, 0.0, -1, 0, String[])

# =============================================================================
# JOURNAL QUEUE
# =============================================================================

abstract type JournalEntry end

"""Free-text event for the log (`level` is :info, :warn or :error)."""
struct JournalEvent <: JournalEntry
    time::Float64
    level::Symbol
    message::String
end

"""
Opens run folder `dir` (`new_run_dir`, journal.jl): `info` is written to
its run.toml, `irfs` (one `[t_ns counts]` per channel) to its irf.csv and
`irf_info` (the settings the IRF was taken with) to its irf.toml.
"""
struct JournalRunStart <: JournalEntry
    time::Float64
    dir::String
    info::Dict{String, Any}
    irfs::Vector{Matrix{Float64}}
    irf_info::Dict{String, Any}
end

JournalRunStart(time, dir, info, irfs) = JournalRunStart(time, dir, info, irfs, Dict{String, Any}())

struct JournalRunEnd <: JournalEntry
    time::Float64
end

"""One analyzed histogram (a line of frames.csv)."""
struct JournalFrame <: JournalEntry
    record::FrameRecord
end

"""One slot played (a line of visits.csv); `first_sample` counts from the start of generation."""
struct JournalVisit <: JournalEntry
    summary::SlotSummary
    first_sample::Int
end

"""Readback layout for this run: written once, before the first `JournalReadback`."""
struct JournalReadbackStart <: JournalEntry
    signals::Vector{String}
    sample_rate_hz::Float64
end

"""`n_samples` readback samples held in `pool.buffers[index]`, to append to readback.bin."""
struct JournalReadback <: JournalEntry
    pool::ReadbackPool
    index::Int
    n_samples::Int
end

"""
    JournalQueue(capacity)

Queue feeding the journal thread. `send_journal!` never waits: past
`capacity` pending entries it drops the new one and increments `dropped`
(shown in the Console panel — the plan's target is zero).
"""
struct JournalQueue
    lock::ReentrantLock
    items::Vector{JournalEntry}
    capacity::Int
    dropped::Threads.Atomic{Int}
end

JournalQueue(capacity::Integer) = JournalQueue(ReentrantLock(), JournalEntry[], capacity, Threads.Atomic{Int}(0))

function send_journal!(queue::JournalQueue, entry::JournalEntry)::Bool
    lock(queue.lock)
    try
        if length(queue.items) >= queue.capacity
            Threads.atomic_add!(queue.dropped, 1)
            return false
        end
        push!(queue.items, entry)
        return true
    finally
        unlock(queue.lock)
    end
end

"""
    drain_journal!(out, queue)

Move every pending entry into `out` (journal thread side).
"""
function drain_journal!(out::Vector{JournalEntry}, queue::JournalQueue)
    lock(queue.lock)
    try
        append!(out, queue.items)
        empty!(queue.items)
    finally
        unlock(queue.lock)
    end
    return out
end

pending_journal(queue::JournalQueue)::Int = (lock(queue.lock); try length(queue.items) finally unlock(queue.lock) end)

journal_event!(queue::JournalQueue, level::Symbol, message::AbstractString) =
    send_journal!(queue, JournalEvent(time(), level, String(message)))

# =============================================================================
# THE EXCHANGE
# =============================================================================

"""
    Exchange

Every exchange between threads, created once at startup and shared by
reference. See the table at the top of this file.
"""
struct Exchange
    frames::Ring{FrameRecord}
    slots::Ring{SlotSummary}
    readback::ReadbackView
    status::StatusBox
    commands::Channel{LoopCommand}
    stop::Threads.Atomic{Bool}
    command_values::NTuple{2, Vector{Threads.Atomic{Float64}}}
    settings::SettingsBox
    journal::JournalQueue
    shutdown::Threads.Atomic{Bool}
end

function Exchange(; frame_capacity::Integer = 16_384, slot_capacity::Integer = 1_024, journal_capacity::Integer = 4_096)
    return Exchange(
        Ring{FrameRecord}(frame_capacity),
        Ring{SlotSummary}(slot_capacity),
        ReadbackView(),
        StatusBox(LoopStatus(LOOP_DISCONNECTED, "")),
        Channel{LoopCommand}(LOOP_COMMAND_CAPACITY),
        Threads.Atomic{Bool}(false),
        Tuple([Threads.Atomic{Float64}(NaN) for _ in 1:FLIMCore.ROI_MAX] for _ in 1:2),
        SettingsBox(AnalysisSettings()),
        JournalQueue(journal_capacity),
        Threads.Atomic{Bool}(false)
    )
end

Exchange(cfg::BenchConfig) = Exchange(journal_capacity = cfg.journal_capacity)

loop_status(ex::Exchange)::LoopStatus = @atomic ex.status.status
set_loop_status!(ex::Exchange, state::LoopState, message::AbstractString = "") =
    (@atomic ex.status.status = LoopStatus(state, String(message)); nothing)

"""
    send_command!(ex, command)::Bool

Queue a command for the DAQ loop without ever blocking the caller (the GUI
thread): if the queue is full — the loop is not taking commands — the
command is dropped with a warning.
"""
function send_command!(ex::Exchange, command::LoopCommand)::Bool
    if Base.n_avail(ex.commands) >= LOOP_COMMAND_CAPACITY
        @warn "DAQ loop is not taking commands; dropped" command=typeof(command)
        return false
    end
    put!(ex.commands, command)
    return true
end

"""
    request_stop!(ex)

Ask the running scan to stop: the loop sees the flag between two readback
blocks (every `block_ms`), stops the tasks and zeroes every output.
"""
request_stop!(ex::Exchange) = (ex.stop[] = true; nothing)

"""
    set_command_values!(ex, roi, command1, command2)
    set_command_values!(ex, command1, command2)

Latest PI commands of ROI `roi` (its drawn index; 1 without ROIs), in
percent (`NaN` = controller off), for the DAQ loop: it writes them into
the next slot that scans that ROI. Without `roi`: every ROI.
"""
function set_command_values!(ex::Exchange, roi::Integer, command1::Real, command2::Real)
    ex.command_values[1][roi][] = Float64(command1)
    ex.command_values[2][roi][] = Float64(command2)
    return nothing
end

function set_command_values!(ex::Exchange, command1::Real, command2::Real)
    foreach(roi -> set_command_values!(ex, roi, command1, command2), 1:FLIMCore.ROI_MAX)
    return nothing
end

"""PI commands (percent) the DAQ loop writes into a slot of ROI `roi` (1 without ROIs)."""
command_values(ex::Exchange, roi::Integer) = (ex.command_values[1][roi][], ex.command_values[2][roi][])

current_settings(ex::Exchange)::AnalysisSettings = @atomic ex.settings.value
publish_settings!(ex::Exchange, settings::AnalysisSettings) = (@atomic ex.settings.value = settings; nothing)
