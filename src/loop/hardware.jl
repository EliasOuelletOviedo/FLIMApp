"""
loop/hardware.jl

The two backends the DAQ loop drives, behind one set of functions. DAQ loop
thread only: nothing else in the app creates, reads or writes a DAQmx task.

- `NIHardware`: the PCIe-6321 and PCI-6110, set up as in the NI-PCIe-6321
  branch tests (test9/test10, generateur.jl): the 6321's counter is the
  shared sample clock (RTSI to the 6110), every task is slaved to it and
  started first, the clock last; outputs stream without regeneration, so a
  card that isn't fed stops instead of replaying old samples.
- `SimulatedHardware`: the same contract in memory — the readback returns
  exactly what was written, paced in real time (or instantly, for tests),
  and running out of written samples fails the next write the way the card
  does. `backend = "simulation"` in config/bench.toml runs the app on it.

Life cycle, driven by loop/daq_loop.jl:

    hw_connect!      INIT: devices present, reset, everything at zero
    hw_prepare!      create one scan's tasks (not started), the pass counter included
    hw_write!        append a slot (or the entry) to the output buffers
    hw_go!           shutter open, watchdog, slaves, then the clock
    hw_read!         blocking read of one readback block (paces the loop)
    hw_kick!         re-arm the watchdog
    hw_generated     samples generated so far
    hw_stop!         clock first (every output freezes on the same sample),
                     clear the tasks, zero everything, close the shutter
    hw_zero!         every output to 0 V / low by on-demand writes
    hw_disconnect!
"""

abstract type Hardware end

"""
    make_hardware(cfg)::Hardware

The backend `cfg.backend` names.
"""
make_hardware(cfg::BenchConfig)::Hardware = cfg.backend === :simulation ? SimulatedHardware(cfg) : NIHardware(cfg)

"""
    expand_lines(spec)::Vector{String}

`"X6321/port0/line0:2"` -> `["X6321/port0/line0", "X6321/port0/line1",
"X6321/port0/line2"]`; comma-separated lists are expanded item by item.
"""
function expand_lines(spec::AbstractString)::Vector{String}
    out = String[]
    for part in split(spec, ',')
        item = strip(part)
        isempty(item) && continue
        m = match(r"^(.*line)(\d+):(\d+)$", item)
        if m === nothing
            push!(out, String(item))
        else
            a, b = parse(Int, m[2]), parse(Int, m[3])
            for i in (a <= b ? (a:b) : (a:-1:b))
                push!(out, "$(m[1])$i")
            end
        end
    end
    return out
end

# =============================================================================
# NI-DAQmx
# =============================================================================

const TERMINAL_CONFIGS = Dict(
    "RSE" => DAQmx.Val_RSE, "NRSE" => DAQmx.Val_NRSE, "Diff" => DAQmx.Val_Diff,
    "PseudoDiff" => DAQmx.Val_PseudoDiff, "Default" => DAQmx.Val_Cfg_Default
)

mutable struct NIHardware <: Hardware
    cfg::BenchConfig
    galvos::DAQmx.TaskHandle
    lines::DAQmx.TaskHandle
    commands::DAQmx.TaskHandle
    readback::DAQmx.TaskHandle
    clock::DAQmx.TaskHandle
    watchdog::DAQmx.TaskHandle
    shutter::DAQmx.TaskHandle
    passes::DAQmx.TaskHandle
    n_readback::Int
end

NIHardware(cfg::BenchConfig) = NIHardware(cfg, C_NULL, C_NULL, C_NULL, C_NULL, C_NULL, C_NULL, C_NULL, C_NULL, length(cfg.readback_signals))

describe_hardware(hw::NIHardware) = "NI-DAQmx: " * join(bench_devices(hw.cfg), " + ")

function hw_connect!(hw::NIHardware)
    present = with_context("listing the NI devices (DAQmxGetSysDevNames)") do
        DAQmx.device_names()
    end
    product(d) = try
        DAQmx.product_type(d)
    catch
        "?"
    end
    driver = try
        join(DAQmx.driver_version(), ".")
    catch
        "?"
    end
    seen = isempty(present) ? "none" : join(["$d ($(product(d)))" for d in present], ", ")
    @info "NI-DAQmx $driver; devices: $seen; config needs $(join(bench_devices(hw.cfg), ", "))"
    missing_devices = setdiff(bench_devices(hw.cfg), present)
    isempty(missing_devices) ||
        error("NI device(s) not found: $(join(missing_devices, ", ")) (seen: $seen)")
    # Also releases tasks a previous session in this process may have left.
    for d in bench_devices(hw.cfg)
        with_context("resetting NI device $d (DAQmxResetDevice)") do
            DAQmx.reset_device(d)
        end
    end
    hw_zero!(hw)
    check_clock_route(hw.cfg)
    return nothing
end

"""
    check_clock_route(cfg)

The command AO (`channels.commands`, on the 6110) counts the 6321's sample
clock (`channels.clock`) through the RTSI cable. A throwaway task with that
clock is committed (`DAQmx.task_control`), which reserves the route: a
missing one — the RTSI cable unplugged, or not registered in NI MAX, after
moving a card — fails here, at CONNECT (DAQmx -89125, DAQ-10), instead of
at the first write of a START. Any other error of this check is only
logged: the scan reports it with its own context.
"""
function check_clock_route(cfg::BenchConfig)
    device(spec) = String(first(split(lstrip(spec, '/'), '/')))
    (isempty(cfg.command_channels) || device(cfg.clock_source) == device(cfg.command_channels)) && return nothing
    with_context("checking the RTSI route of the sample clock ($(cfg.clock_source) → $(device(cfg.command_channels)))") do
        th = DAQmx.create_task("flimapp_route_check")
        try
            add_command_channels!(th, cfg)
            DAQmx.cfg_sample_clock(th, cfg.sample_rate_hz; source = cfg.clock_source, mode = DAQmx.Val_ContSamps, nsamp = 1000)
            DAQmx.task_control(th, DAQmx.Val_Task_Commit)
        catch e
            e isa DAQmx.DAQmxError && e.code in DAQmx.CODES_ROUTE_RTSI && rethrow()
            @warn "Clock route check inconclusive: the scan will tell" exception = e
        finally
            try
                DAQmx.clear_task(th)
            catch
            end
        end
    end
    return nothing
end

"""
    command_channel_pair(spec) -> (ao0, ao1)

The two command outputs of `channels.commands`: "S6110/ao0:1" → "S6110/ao0",
"S6110/ao1" (or two channels separated by a comma).
"""
function command_channel_pair(spec::AbstractString)
    parts = strip.(split(spec, ','))
    length(parts) == 2 && return (String(parts[1]), String(parts[2]))
    m = match(r"^(.*?)(\d+):(\d+)$", strip(spec))
    (m !== nothing && parse(Int, m[3]) == parse(Int, m[2]) + 1) ||
        error("channels.commands = \"$spec\": two consecutive outputs (\"S6110/ao0:1\") for command 1 and the 1064 nm gate")
    return (m[1] * m[2], m[1] * m[3])
end

"""
    add_command_channels!(th, cfg)

The command AO channels: AO 0, PI command 1, declared 0…`command_max_v`;
AO 1 — the 1064 nm laser gate when `[limits] gate_1064_v` > 0 — declared
0…`gate_1064_v` (otherwise PI command 2, 0…`command_max_v`). NI-DAQmx
itself refuses any write outside (-200561), a second layer behind
`check_slot`.
"""
function add_command_channels!(th, cfg::BenchConfig)
    if cfg.gate_1064_v > 0
        ao0, ao1 = command_channel_pair(cfg.command_channels)
        DAQmx.add_ao_voltage(th, ao0; minv = 0.0, maxv = cfg.command_max_v)
        DAQmx.add_ao_voltage(th, ao1; minv = 0.0, maxv = cfg.gate_1064_v)
    else
        DAQmx.add_ao_voltage(th, cfg.command_channels; minv = 0.0, maxv = cfg.command_max_v)
    end
    return th
end

function configure_output!(th, cfg::BenchConfig, buffer_samples::Integer)
    DAQmx.cfg_sample_clock(th, cfg.sample_rate_hz; source = cfg.clock_source, mode = DAQmx.Val_ContSamps, nsamp = buffer_samples)
    DAQmx.set_regen_mode(th, DAQmx.Val_DoNotAllowRegen)   # never replay old samples: an unfed card stops
    DAQmx.cfg_output_buffer(th, buffer_samples)
    return nothing
end

"""
    hw_prepare!(hw, buffer_samples; pass_ticks=nothing)

Create one scan's tasks. `pass_ticks = (entry, scan, shift)` (samples) also
creates the pass signal on `cfg.pass_counter`: counted on the shared sample
clock, low during the entry, then high for each scan and low for each
pause — wired to the SPC card's marker M0 (QC-104: pin 12), and to M3
(pin 10) with `[clamp] fin_par_m3 = true`.
"""
function hw_prepare!(hw::NIHardware, buffer_samples::Integer; pass_ticks = nothing)
    cfg = hw.cfg
    # Each step says what it creates (`with_context`): an error names the task and its channels.
    try
        with_context("creating the galvo AO task ($(cfg.galvo_channels), clock $(cfg.clock_source))") do
            hw.galvos = DAQmx.create_task("flimapp_galvos")
            DAQmx.add_ao_voltage(hw.galvos, cfg.galvo_channels; minv = -cfg.galvo_limit_v, maxv = cfg.galvo_limit_v)
            configure_output!(hw.galvos, cfg, buffer_samples)
        end

        with_context("creating the port-0 DO task ($(cfg.line_channels): gates, sync pulses, routing code)") do
            hw.lines = DAQmx.create_task("flimapp_lines")
            DAQmx.add_do(hw.lines, cfg.line_channels)
            configure_output!(hw.lines, cfg, buffer_samples)
        end

        with_context("creating the command AO task ($(cfg.command_channels): command 0…$(cfg.command_max_v) V" *
                     (cfg.gate_1064_v > 0 ? ", 1064 nm gate 0…$(cfg.gate_1064_v) V)" : ")")) do
            hw.commands = DAQmx.create_task("flimapp_commands")
            add_command_channels!(hw.commands, cfg)
            configure_output!(hw.commands, cfg, buffer_samples)
        end

        with_context("creating the readback AI task ($(cfg.readback_channels), $(cfg.readback_terminal))") do
            hw.readback = DAQmx.create_task("flimapp_readback")
            DAQmx.add_ai_voltage(hw.readback, cfg.readback_channels; termcfg = TERMINAL_CONFIGS[cfg.readback_terminal])
            n = DAQmx.num_chans(hw.readback)
            n == hw.n_readback ||
                error("readback: $(cfg.readback_channels) has $n channel(s) but readback_signals lists $(hw.n_readback)")
            input_buffer = max(Int(buffer_samples), round(Int, 10 * cfg.sample_rate_hz))
            DAQmx.cfg_sample_clock(hw.readback, cfg.sample_rate_hz; source = cfg.clock_source, mode = DAQmx.Val_ContSamps, nsamp = input_buffer)
            DAQmx.cfg_input_buffer(hw.readback, input_buffer)
        end

        hw.clock = create_clock_task(cfg)
        if pass_ticks !== nothing && !isempty(cfg.pass_counter)
            hw.passes = create_pass_task(cfg, pass_ticks...)
        end

        if !isempty(cfg.shutter_line)
            with_context("creating the shutter DO task ($(cfg.shutter_line))") do
                hw.shutter = DAQmx.create_task("flimapp_shutter")
                DAQmx.add_do(hw.shutter, cfg.shutter_line)
            end
        end

        if cfg.watchdog_enabled
            lines = vcat(expand_lines(cfg.watchdog_lines), expand_lines(cfg.shutter_line))
            device = String(first(split(lstrip(first(lines), '/'), '/')))
            with_context("creating the watchdog task ($device, $(cfg.watchdog_timeout_s) s, lines $(join(lines, ",")))") do
                hw.watchdog = DAQmx.create_watchdog(device, cfg.watchdog_timeout_s; nom = "flimapp_watchdog")
                DAQmx.cfg_watchdog_do_expir_states(hw.watchdog, join(lines, ","), fill(DAQmx.Val_Low, length(lines)))
            end
        end
    catch
        clear_scan_tasks!(hw)
        rethrow()
    end
    return nothing
end

function hw_write!(hw::NIHardware, buffers::SlotBuffers)
    n = buffer_samples(buffers)
    n == 0 && return nothing
    DAQmx.write_analog(hw.galvos, buffers.galvos; nsamp_per_chan = n)
    DAQmx.write_do_u8(hw.lines, buffers.lines)
    DAQmx.write_analog(hw.commands, buffers.commands; nsamp_per_chan = n)
    return nothing
end

"""
    create_clock_task(cfg)::DAQmx.TaskHandle

The shared sample clock (`cfg.counter` at `cfg.sample_rate_hz`), created,
not started; every scan task counts its edges (`cfg.clock_source`).
"""
function create_clock_task(cfg::BenchConfig)::DAQmx.TaskHandle
    return with_context("creating the sample clock task ($(cfg.counter) at $(cfg.sample_rate_hz) Hz)") do
        th = DAQmx.create_task("flimapp_clock")
        try
            DAQmx.add_co_pulse_freq(th, cfg.counter, cfg.sample_rate_hz; duty = 0.5)
            DAQmx.cfg_implicit_timing(th, DAQmx.Val_ContSamps, 1000)
        catch
            try; DAQmx.clear_task(th); catch; end
            rethrow()
        end
        th
    end
end

"""Where the pass signal comes out, for the messages."""
pass_terminal_text(terminal::AbstractString) = isempty(terminal) ? "default terminal (PFI13 for ctr1)" : String(terminal)

"""
    create_pass_task(cfg, entry, scan, shift; terminal=cfg.pass_terminal)::DAQmx.TaskHandle

The pass signal (`cfg.pass_counter`), created, not started: counted in
edges of the sample clock, low for `entry` samples (at least 2), then high
for each scan (`scan` samples) and low for each pause (`shift`), out on
`terminal` ("" = the counter's default, PFI13 for ctr1) — wired to the
cards' M0 (rising edge: start of pass; M3, falling edge, only with
`[clamp] fin_par_m3 = true`). Also used by
scripts/test_passes.jl.
"""
function create_pass_task(cfg::BenchConfig, entry::Integer, scan::Integer, shift::Integer;
                          terminal::AbstractString = cfg.pass_terminal)::DAQmx.TaskHandle
    return with_context("creating the pass counter task ($(cfg.pass_counter) → $(pass_terminal_text(terminal)), ticks of " *
                        "$(cfg.clock_source): delay $(max(entry, 2)), high $scan, low $shift)") do
        th = DAQmx.create_task("flimapp_passes")
        try
            DAQmx.add_co_pulse_ticks(th, cfg.pass_counter, cfg.clock_source;
                                     initial_delay = max(entry, 2), high_ticks = scan, low_ticks = shift)
            isempty(terminal) || DAQmx.set_co_pulse_term(th, terminal)
            DAQmx.cfg_implicit_timing(th, DAQmx.Val_ContSamps, 1000)
        catch
            try; DAQmx.clear_task(th); catch; end
            rethrow()
        end
        th
    end
end

function hw_go!(hw::NIHardware)
    start(label, th) = th == C_NULL || with_context(() -> DAQmx.start_task(th), "starting the $label task")
    hw.shutter == C_NULL || with_context(() -> DAQmx.write_do(hw.shutter, UInt8[1]), "opening the shutter")
    start("watchdog", hw.watchdog)
    start("galvo AO", hw.galvos)       # slaves first: they wait for the first clock edge
    start("port-0 DO", hw.lines)
    start("command AO", hw.commands)
    start("readback AI", hw.readback)
    start("pass counter", hw.passes)
    start("sample clock", hw.clock)    # the clock starts them all
    return nothing
end

function hw_read!(hw::NIHardware, buffer::Matrix{Float64}, first_sample::Integer, n_samples::Integer, n_read::Base.RefValue{Int32})
    DAQmx.read_analog_into!(hw.readback, buffer, first_sample * hw.n_readback + 1, n_samples, n_read; timeout = 1.0)
    n_read[] == n_samples || error("readback returned $(n_read[]) of $n_samples samples")
    return nothing
end

hw_kick!(hw::NIHardware) = (hw.watchdog == C_NULL || DAQmx.control_watchdog(hw.watchdog, DAQmx.Val_ResetTimer); nothing)

hw_generated(hw::NIHardware)::Int = DAQmx.samples_generated(hw.galvos)

function clear_task_field!(hw::NIHardware, field::Symbol)
    th = getfield(hw, field)
    th == C_NULL && return nothing
    try; DAQmx.stop_task(th); catch; end
    try; DAQmx.clear_task(th); catch; end
    setfield!(hw, field, C_NULL)
    return nothing
end

function clear_scan_tasks!(hw::NIHardware)
    # Clock first: every slaved output freezes on the same sample.
    for field in (:clock, :passes, :readback, :commands, :lines, :galvos, :watchdog, :shutter)
        clear_task_field!(hw, field)
    end
    return nothing
end

function hw_stop!(hw::NIHardware)
    clear_scan_tasks!(hw)
    hw_zero!(hw)
    return nothing
end

"""
    hw_zero!(hw::NIHardware)

`mise_a_zero`: galvos and commands to 0 V, port 0 and the shutter low, by
on-demand writes on fresh tasks (a stopped task holds its last value).
Failures are logged, not raised, so a faulty card can't block shutdown.
"""
function hw_zero!(hw::NIHardware)
    cfg = hw.cfg
    attempt(label, f) = try
        f()
    catch e
        # An output that may not be at zero: an error, with its code.
        report_problem!("DAQ-02", "zeroing the $label: " * describe_loop_error(e); level = :error,
                        key = "DAQ-02/zero $label", exception = (e, catch_backtrace()))
    end

    attempt("galvo outputs", () -> DAQmx.withtask("flimapp_zero_galvos") do th
        DAQmx.add_ao_voltage(th, cfg.galvo_channels; minv = -cfg.galvo_limit_v, maxv = cfg.galvo_limit_v)
        DAQmx.write_analog(th, zeros(2); nsamp_per_chan = 1, autostart = true)
    end)
    attempt("port-0 lines", () -> DAQmx.withtask("flimapp_zero_lines") do th
        DAQmx.add_do(th, cfg.line_channels)
        DAQmx.write_do_u8(th, UInt8[0]; autostart = true)
    end)
    attempt("command outputs", () -> DAQmx.withtask("flimapp_zero_commands") do th
        add_command_channels!(th, cfg)
        DAQmx.write_analog(th, zeros(2); nsamp_per_chan = 1, autostart = true)
    end)
    isempty(cfg.shutter_line) || attempt("shutter", () -> DAQmx.withtask("flimapp_zero_shutter") do th
        DAQmx.add_do(th, cfg.shutter_line)
        DAQmx.write_do(th, UInt8[0])
    end)
    return nothing
end

hw_disconnect!(hw::NIHardware) = (clear_scan_tasks!(hw); hw_zero!(hw))

# =============================================================================
# SIMULATION
# =============================================================================

"""
    SimulatedHardware(cfg; realtime=true, strict_timing=realtime)

In-memory card: written samples go to a circular buffer of the size the
loop asks for, and each readback block returns them back — per
`cfg.readback_signals`, lines as 0/5 V — once the time they take to play
has elapsed (`realtime`), or immediately (`realtime = false`, for tests).
With `strict_timing`, the card keeps its own wall-clock position like the
real one: if the loop stalls (a long iteration, a garbage-collector pause)
until the card has played everything written, that's an underflow. Reading
past the last written sample is one too. Either way the next write throws
DAQmx -200290 exactly like the card. Writes outside the declared ranges
throw -200561.

`skip_samples` is a test hook: the next read pretends the card ran that
many samples ahead of the loop.
"""
mutable struct SimulatedHardware <: Hardware
    cfg::BenchConfig
    realtime::Bool
    strict_timing::Bool
    connected::Bool
    running::Bool
    capacity::Int
    galvos::Matrix{Float64}
    lines::Vector{UInt8}
    commands::Matrix{Float64}
    written::Int
    generated::Int
    t0_ns::UInt64
    underflow::Bool
    skip_samples::Int
    zero_count::Int
    signal_sources::Vector{Tuple{Symbol, Int}}
end

function SimulatedHardware(cfg::BenchConfig; realtime::Bool = true, strict_timing::Bool = realtime)
    sources = map(cfg.readback_signals) do name
        name == "galvo_x" ? (:galvo, 1) :
        name == "galvo_y" ? (:galvo, 2) :
        name == "command_1" ? (:command, 1) :
        name == "command_2" ? (:command, 2) :
        (:line, parse(Int, last(split(name, '_'))))
    end
    return SimulatedHardware(cfg, realtime, strict_timing, false, false, 0, zeros(2, 0), UInt8[], zeros(2, 0),
                             0, 0, UInt64(0), false, 0, 0, sources)
end

describe_hardware(::SimulatedHardware) = "simulation"

simulated_error(code::Integer, message::AbstractString) = DAQmx.DAQmxError(Int32(code), "simulation: " * message)

hw_connect!(hw::SimulatedHardware) = (hw.connected = true; hw_zero!(hw); nothing)

function hw_prepare!(hw::SimulatedHardware, buffer_samples::Integer; pass_ticks = nothing)
    hw.capacity = Int(buffer_samples)
    hw.galvos = zeros(2, hw.capacity)
    hw.lines = zeros(UInt8, hw.capacity)
    hw.commands = zeros(2, hw.capacity)
    hw.written = 0
    hw.generated = 0
    hw.underflow = false
    return nothing
end

function hw_write!(hw::SimulatedHardware, buffers::SlotBuffers)
    hw.underflow && throw(simulated_error(-200290, "generation stopped: the loop did not write in time"))
    n = buffer_samples(buffers)
    hw.written - hw.generated + n <= hw.capacity || throw(simulated_error(-200292, "output buffer full"))
    cfg = hw.cfg
    for v in buffers.galvos
        abs(v) <= cfg.galvo_limit_v || throw(simulated_error(-200561, "galvo sample $v V outside the declared range"))
    end
    # The declared ranges, as add_command_channels! makes them: AO 1 up to gate_1064_v when it is the 1064 nm gate.
    for (j, v) in enumerate(buffers.commands)
        limit = j > n && cfg.gate_1064_v > 0 ? cfg.gate_1064_v : cfg.command_max_v
        0.0 <= v <= limit || throw(simulated_error(-200561, "command sample $v V outside the declared range"))
    end
    @inbounds for j in 1:n
        idx = mod(hw.written + j - 1, hw.capacity) + 1
        hw.galvos[1, idx] = buffers.galvos[j]
        hw.galvos[2, idx] = buffers.galvos[n + j]
        hw.commands[1, idx] = buffers.commands[j]
        hw.commands[2, idx] = buffers.commands[n + j]
        hw.lines[idx] = buffers.lines[j]
    end
    hw.written += n
    return nothing
end

hw_go!(hw::SimulatedHardware) = (hw.running = true; hw.t0_ns = time_ns(); nothing)

function hw_read!(hw::SimulatedHardware, buffer::Matrix{Float64}, first_sample::Integer, n_samples::Integer, n_read::Base.RefValue{Int32})
    hw.running || error("simulation: read on a stopped scan")
    if hw.skip_samples > 0
        hw.generated += hw.skip_samples
        hw.skip_samples = 0
    end
    if hw.realtime
        due_ns = hw.t0_ns + round(UInt64, (hw.generated + n_samples) * 1e9 / hw.cfg.sample_rate_hz)
        now_ns = time_ns()
        now_ns < due_ns && sleep((due_ns - now_ns) / 1e9)
    end
    hw.strict_timing && card_position(hw) > hw.written && (hw.underflow = true)
    @inbounds for j in 1:n_samples
        p = hw.generated + j - 1
        column = first_sample + j
        if p >= hw.written
            hw.underflow = true
            buffer[:, column] .= 0.0
            continue
        end
        idx = mod(p, hw.capacity) + 1
        for (c, (kind, k)) in enumerate(hw.signal_sources)
            buffer[c, column] = kind === :galvo ? hw.galvos[k, idx] :
                                kind === :command ? hw.commands[k, idx] :
                                5.0 * ((hw.lines[idx] >> k) & 0x01)
        end
    end
    hw.generated += n_samples
    n_read[] = Int32(n_samples)
    return nothing
end

"""Samples the simulated card has played by now, by the wall clock."""
card_position(hw::SimulatedHardware)::Int = floor(Int, (time_ns() - hw.t0_ns) * hw.cfg.sample_rate_hz / 1e9)

hw_kick!(::SimulatedHardware) = nothing
hw_generated(hw::SimulatedHardware)::Int = hw.strict_timing ? clamp(card_position(hw), hw.generated, hw.written) : hw.generated
hw_stop!(hw::SimulatedHardware) = (hw.running = false; hw_zero!(hw); nothing)
hw_zero!(hw::SimulatedHardware) = (hw.zero_count += 1; nothing)
hw_disconnect!(hw::SimulatedHardware) = (hw.running = false; hw_zero!(hw); hw.connected = false; nothing)
