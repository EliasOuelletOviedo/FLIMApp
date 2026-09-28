"""
loop/daq_loop.jl

The DAQ loop thread: the only code that touches the cards (through
loop/hardware.jl). It runs the state machine of plan §7 and, while a scan
runs, one iteration per slot (plan §3):

    card plays slot s          loop reads slot s's readback in blocks of
                               `block_ms`, checking the stop flag between blocks
    end of slot s              loop prepares and writes slot s + lead (latest
                               PI commands), publishes slot s's summary and
                               readback, hands them to the journal

Slots s + 1 … s + lead − 1 are already in the card's buffer, so the deadline
for writing slot s + lead is (lead − 1) slots. Waiting happens only inside
the readback read (`gc_safe` on Julia ≥ 1.12, loop/DAQmx.jl), never on
another thread: commands are read only while idle, the PI commands are
atomics, the display and journal exchanges never block.

Any error during a scan — a missed deadline included — stops the tasks,
zeroes every output and leaves the loop in `LOOP_FAULT` until the GUI
acknowledges it.
"""

"""
    daq_loop(cfg, ex; hardware=make_hardware(cfg))

Body of the DAQ loop thread (`Threads.@spawn` at startup), alive until a
`QuitCommand`. Whatever happens, the outputs are zeroed on the way out.
"""
function daq_loop(cfg::BenchConfig, ex::Exchange; hardware::Hardware = make_hardware(cfg))
    connected = false
    set_loop_status!(ex, LOOP_DISCONNECTED)

    try
        while true
            command = take!(ex.commands)   # idle: waiting for the GUI is fine here
            command isa QuitCommand && break
            state = loop_status(ex).state

            if command isa ConnectCommand
                state == LOOP_DISCONNECTED && (connected = initialize_hardware!(hardware, cfg, ex))
            elseif command isa AcknowledgeCommand
                state == LOOP_FAULT && (connected = initialize_hardware!(hardware, cfg, ex))
            elseif command isa DisconnectCommand
                if state != LOOP_DISCONNECTED
                    try
                        hw_disconnect!(hardware)
                    catch e
                        @warn "DAQ disconnect failed" error=describe_loop_error(e)
                    end
                    journal_event!(ex.journal, :info, "DAQ disconnected")
                end
                connected = false
                set_loop_status!(ex, LOOP_DISCONNECTED)
            elseif command isa StartCommand
                if state == LOOP_READY
                    run_scan!(hardware, cfg, ex, command.request)
                else
                    journal_event!(ex.journal, :warn, "scan not started: the DAQ loop is $(state)")
                end
            end
        end
    catch e
        e isa InvalidStateException || @error "DAQ loop crashed" exception=(e, catch_backtrace())
    finally
        if connected
            try
                hw_disconnect!(hardware)
            catch e
                @warn "DAQ disconnect failed" error=describe_loop_error(e)
            end
        end
        set_loop_status!(ex, LOOP_DISCONNECTED)
    end

    return nothing
end

"""
    initialize_hardware!(hw, cfg, ex)::Bool

INIT: check and reset the cards, zero everything, warm up the iteration
code. READY on success, FAULT (with the reason) otherwise.
"""
function initialize_hardware!(hw::Hardware, cfg::BenchConfig, ex::Exchange)::Bool
    set_loop_status!(ex, LOOP_INIT, "checking the cards")
    try
        hw_connect!(hw)
        warm_up_loop!(cfg)
        set_loop_status!(ex, LOOP_READY, describe_hardware(hw))
        journal_event!(ex.journal, :info, "DAQ connected: $(describe_hardware(hw)) (config $(cfg.source))")
        return true
    catch e
        message = describe_loop_error(e)
        set_loop_status!(ex, LOOP_FAULT, "connection failed: $message")
        journal_event!(ex.journal, :error, "DAQ connection failed: $message")
        @warn "DAQ connection failed" error=message
        return false
    end
end

"""
    warm_up_loop!(cfg)

Run the non-hardware part of an iteration once on a dummy pattern, so JIT
compilation doesn't land on the first slot's deadline (plan §6.3).
"""
function warm_up_loop!(cfg::BenchConfig)
    request = ScanRequest(RoiCoordinates[], Int[], false, -1000, 1000, -1000, 1000, 10, 1, 10, 2, (1024, 1024))
    pattern = build_scan_pattern(request, cfg)
    buffers = SlotBuffers(pattern.slot_samples)
    prepare_slot!(buffers, pattern, 0, command_volts(50.0, cfg), command_volts(NaN, cfg))
    check_slot(buffers, cfg)
    readback = zeros(length(cfg.readback_signals), pattern.slot_samples)
    view = ReadbackView()
    reset_readback_view!(view, cfg.readback_signals, pattern.slot_samples, 1 / cfg.sample_rate_hz)
    publish_readback_view!(view, readback, pattern.slot_samples, 1, 0)
    pool = ReadbackPool(length(cfg.readback_signals), pattern.slot_samples, 1)
    copy_readback!(pool.buffers[1], readback, pattern.slot_samples)
    SlotSummary(0, slot_roi(pattern, 0), slot_visit(pattern, 0), 0.0, 0.0, 0.0, 0.0, 0.0)
    return nothing
end

function reset_readback_view!(view::ReadbackView, signals::Vector{String}, n_points::Integer, dt_s::Real)
    lock(view.lock)
    try
        view.data = zeros(Float32, length(signals), n_points)
        view.n_points = 0
        view.dt_s = Float64(dt_s)
        view.slot = -1
        view.signals = copy(signals)
        view.version += 1
    finally
        unlock(view.lock)
    end
    return nothing
end

"""Decimated copy of one slot's readback into the display view (a few µs under the lock)."""
function publish_readback_view!(view::ReadbackView, readback::Matrix{Float64}, n::Integer, stride::Integer, slot::Integer)
    lock(view.lock)
    try
        data = view.data
        n_points = min(cld(n, stride), size(data, 2))
        @inbounds for j in 1:n_points, c in 1:size(data, 1)
            data[c, j] = Float32(readback[c, (j - 1) * stride + 1])
        end
        view.n_points = n_points
        view.slot = slot
        view.version += 1
    finally
        unlock(view.lock)
    end
    return nothing
end

function copy_readback!(dest::Matrix{Float32}, readback::Matrix{Float64}, n::Integer)
    @inbounds for j in 1:n, c in 1:size(dest, 1)
        dest[c, j] = Float32(readback[c, j])
    end
    return dest
end

"""Hand `n` readback samples to the journal through the pool; dropped and counted if no buffer is free."""
function journal_readback!(ex::Exchange, pool::Union{Nothing, ReadbackPool}, readback::Matrix{Float64}, n::Integer)
    pool === nothing && return nothing
    index = acquire!(pool)
    if index == 0
        Threads.atomic_add!(ex.journal.dropped, 1)
        return nothing
    end
    copy_readback!(pool.buffers[index], readback, n)
    send_journal!(ex.journal, JournalReadback(pool, index, n)) || release!(pool, index)
    return nothing
end

"""
    read_span!(hw, readback, n, cfg, ex, n_read)::Bool

Read `n` readback samples into `readback[:, 1:n]` in blocks of
`cfg.block_samples`, re-arming the watchdog after each block. Returns
`false` as soon as the stop flag is seen (checked before every block).
"""
function read_span!(hw::Hardware, readback::Matrix{Float64}, n::Integer, cfg::BenchConfig, ex::Exchange, n_read::Base.RefValue{Int32})::Bool
    position = 0
    while position < n
        ex.stop[] && return false
        block = min(cfg.block_samples, n - position)
        hw_read!(hw, readback, position, block, n_read)
        hw_kick!(hw)
        position += block
    end
    return true
end

"""
    write_slot!(hw, buffers, pattern, s, cfg, ex, written_commands)

Prepare slot `s` with the latest PI commands, check it, write it, and
remember the command voltages it carries (for its summary, published once
it has played).
"""
function write_slot!(hw::Hardware, buffers::SlotBuffers, pattern::ScanPattern, s::Integer,
                     cfg::BenchConfig, ex::Exchange, written_commands::Matrix{Float64})
    command1_v = command_volts(ex.command_values[1][], cfg)
    command2_v = command_volts(ex.command_values[2][], cfg)
    prepare_slot!(buffers, pattern, s, command1_v, command2_v)
    check_slot(buffers, cfg)
    hw_write!(hw, buffers)
    column = mod(s, size(written_commands, 2)) + 1
    written_commands[1, column] = command1_v
    written_commands[2, column] = command2_v
    return nothing
end

"""
    run_scan!(hw, cfg, ex, request)

RUNNING: play `request`'s slots until the stop flag is set or something
fails; then STOPPING (tasks cleared, outputs zeroed) and back to READY, or
FAULT on error. A request the safety checks refuse never reaches the card
and leaves the loop READY.
"""
function run_scan!(hw::Hardware, cfg::BenchConfig, ex::Exchange, request::ScanRequest)
    pattern = try
        build_scan_pattern(request, cfg)
    catch e
        message = describe_loop_error(e)
        set_loop_status!(ex, LOOP_READY, "scan refused: $message")
        journal_event!(ex.journal, :error, "scan refused: $message")
        @warn "Scan refused" error=message
        return nothing
    end

    if ex.stop[]
        set_loop_status!(ex, LOOP_READY, "stopped before starting")
        return nothing
    end

    # Everything the iterations use is allocated here, once.
    n = pattern.slot_samples
    n_entry = entry_samples(pattern)
    lead = cfg.lead_slots == 0 ? max(2, slots_per_cycle(pattern)) : cfg.lead_slots
    deadline_s = (lead - 1) * slot_duration_s(pattern)
    n_signals = length(cfg.readback_signals)
    buffers = SlotBuffers(n)
    readback = zeros(n_signals, max(n, n_entry))
    n_read = Ref{Int32}(0)
    written_commands = zeros(2, lead + 1)
    pool = cfg.journal_readback ? ReadbackPool(n_signals, max(n, n_entry), 8) : nothing
    stride = max(1, cld(n, cfg.max_points_per_line))
    reset_readback_view!(ex.readback, cfg.readback_signals, cld(n, stride), stride / cfg.sample_rate_hz)

    pool === nothing || send_journal!(ex.journal, JournalReadbackStart(cfg.readback_signals, cfg.sample_rate_hz))
    description = pattern.scanning ?
        "$(slots_per_cycle(pattern)) ROI(s), $(round(1000 * slot_duration_s(pattern), digits=1)) ms slots, $lead ahead" :
        "commands only, $(round(1000 * slot_duration_s(pattern), digits=1)) ms slots, $lead ahead"
    journal_event!(ex.journal, :info, "scan started: $description; deadline $(round(1000 * deadline_s, digits=1)) ms")

    fault = nothing
    set_loop_status!(ex, LOOP_RUNNING, description)
    try
        hw_prepare!(hw, n_entry + (lead + 2) * n)
        n_entry > 0 && hw_write!(hw, entry_buffers(pattern))
        for s in 0:lead-1
            write_slot!(hw, buffers, pattern, s, cfg, ex, written_commands)
        end
        written = n_entry + lead * n
        hw_go!(hw)

        running = n_entry == 0 || read_span!(hw, readback, n_entry, cfg, ex, n_read)
        running && journal_readback!(ex, pool, readback, n_entry)

        s = 0
        while running
            running = read_span!(hw, readback, n, cfg, ex, n_read)
            running || break

            # End of slot s: the one iteration that has a deadline.
            t0 = time_ns()
            margin_s = (written - hw_generated(hw)) / cfg.sample_rate_hz
            write_slot!(hw, buffers, pattern, s + lead, cfg, ex, written_commands)
            written += n
            iteration_s = (time_ns() - t0) / 1e9

            column = mod(s, size(written_commands, 2)) + 1
            summary = SlotSummary(s, slot_roi(pattern, s), slot_visit(pattern, s),
                                  written_commands[1, column], written_commands[2, column],
                                  iteration_s, margin_s, deadline_s)
            publish!(ex.slots, summary)
            send_journal!(ex.journal, JournalVisit(summary, n_entry + s * n))
            journal_readback!(ex, pool, readback, n)
            publish_readback_view!(ex.readback, readback, n, stride, s)
            s += 1
        end
    catch e
        fault = e
    finally
        set_loop_status!(ex, LOOP_STOPPING)
        try
            hw_stop!(hw)
        catch e
            fault === nothing && (fault = e)
        end
    end

    if fault === nothing
        set_loop_status!(ex, LOOP_READY, "stopped")
        journal_event!(ex.journal, :info, "scan stopped")
    else
        message = describe_loop_error(fault)
        set_loop_status!(ex, LOOP_FAULT, message)
        journal_event!(ex.journal, :error, "scan fault: $message")
        @error "DAQ loop fault; outputs zeroed" error=message
    end
    return nothing
end
