"""
daq.jl

Hardware output for the FLIM application through NI-DAQmx (io/DAQmx.jl):
opening/closing the session behind the CONNECT button, the ROI galvo scan
(hardware-timed, looped by the card), the PI command outputs (software-timed,
refreshed during acquisition), and driving everything back to zero.

The task setup follows the NI-PCIe-6321 branch tests (test9/test10,
generateur.jl): one counter of the 6321 is the shared sample clock, every
hardware-timed task is slaved to it and started first, the clock is started
last, and a stopped task's outputs are explicitly written back to zero
(DAQmx otherwise holds the last value, laser commands included).
"""

# =============================================================================
# HARDWARE MAP
# =============================================================================
# Plain variables, not `const` — meant to be hand-edited in this file as the
# rig is wired. Device names are the ones shown in NI MAX. Each AO string
# must name exactly two channels (X/Y for the galvos, command 1/2).

daq_galvo_channels   = "X6321/ao0:1"                # AO 0 = galvo X, AO 1 = galvo Y
daq_do_lines         = "X6321/port0/line0:7"        # sync lines, see DO_BIT_* below
daq_clock_counter    = "X6321/ctr0"                 # counter generating the scan clock
daq_clock_source     = "/X6321/Ctr0InternalOutput"  # ...and its output terminal
daq_command_channels = "S6110/ao0:1"                # AO 0 = command 1, AO 1 = command 2

# Sample rate of the ROI scan waveform. scan_time/shift_time are whole ms, so
# any multiple of 1 kHz keeps them exact.
daq_scan_rate_hz = 10_000.0

# Any galvo sample beyond this is refused before anything is written. Set it
# to what the galvo drivers accept before connecting real hardware.
daq_galvo_limit_v = 1.0

# Voltage for a 100 % PI command (commands are clamped to 0–100 %).
daq_command_full_scale_v = 1.0

# Width of the sequence/ROI sync pulses on port 0.
daq_sync_pulse_s = 0.001

# Port 0 layout: bit k of each sample drives line P0.k. Bits 0, 2, 3 and 4–7
# match the NI-PCIe-6321 branch (sequence.jl).
const DO_BIT_GATE     = 0   # high during each ROI's scan
const DO_BIT_ENABLE   = 1   # high for as long as the scan runs
const DO_BIT_SEQUENCE = 2   # pulse at the start of the first ROI's scan, every cycle
const DO_BIT_ROI      = 3   # pulse at the start of every ROI's scan
const DO_ROI_CODE_SHIFT = 4 # bits 4–7: 0-based index of the ROI being visited

do_bit(b) = UInt8(1) << b

"""
    daq_devices()::Vector{String}

Every NI device the hardware map above refers to.
"""
function daq_devices()::Vector{String}
    specs = (daq_galvo_channels, daq_do_lines, daq_clock_counter, daq_command_channels)
    return unique([String(first(split(lstrip(spec, '/'), '/'))) for spec in specs])
end

"""
    daq_status_text(daq)::String

Text for the DAQ status label next to the CONNECT button.
"""
daq_status_text(daq) = daq === nothing ? "DAQ: not connected" : "DAQ: " * join(daq_devices(), " + ")

# =============================================================================
# SESSION
# =============================================================================

"""
    connect_daq()::Union{DaqSession, Nothing}

Check that every device in the hardware map is present, reset them (which
also releases tasks left behind by an earlier session in this process),
open the command-output task, and zero every output. Returns the session,
or `nothing` (with a logged warning) on failure — including on a machine
without the NI-DAQmx driver.
"""
function connect_daq()::Union{DaqSession, Nothing}
    try
        present = DAQmx.device_names()
        missing_devices = setdiff(daq_devices(), present)
        if !isempty(missing_devices)
            @warn "NI-DAQmx device(s) not found" missing=missing_devices present=present
            return nothing
        end

        foreach(DAQmx.reset_device, daq_devices())

        th = DAQmx.create_task("flimapp_commands")
        try
            DAQmx.add_ao_voltage(th, daq_command_channels)
            DAQmx.start_task(th)
        catch
            try; DAQmx.clear_task(th); catch; end
            rethrow()
        end

        daq = DaqSession(th, Ptr{Nothing}[])
        zero_all_outputs!(daq)
        @info "DAQ connected" devices=daq_devices()
        return daq
    catch e
        @warn "DAQ connection failed" error=string(e)
        return nothing
    end
end

"""
    disconnect_daq!(daq::DaqSession)

Stop any scan, zero every output, and release the command task.
"""
function disconnect_daq!(daq::DaqSession)
    zero_all_outputs!(daq)

    try
        DAQmx.clear_task(daq.command_task)
    catch e
        @warn "Failed to release the DAQ command task" error=string(e)
    end

    @info "DAQ disconnected"
    return nothing
end

"""
    zero_all_outputs!(daq::DaqSession)

Stop the ROI scan if one is running, then drive the galvos, every port-0
line and both command outputs to zero — the safe resting state set on STOP
(runtime.jl) and DISCONNECT (handlers.jl). Failures are logged, not raised,
so a faulty device can't block shutdown.
"""
function zero_all_outputs!(daq::DaqSession)
    stop_scan_output!(daq)

    try
        DAQmx.withtask("flimapp_zero_galvos") do th
            DAQmx.add_ao_voltage(th, daq_galvo_channels)
            DAQmx.write_analog(th, zeros(2); nsamp_per_chan = 1, autostart = true)
        end
    catch e
        @warn "Failed to zero the galvo outputs" error=string(e)
    end

    try
        DAQmx.withtask("flimapp_zero_lines") do th
            DAQmx.add_do(th, daq_do_lines)
            DAQmx.write_do(th, zeros(UInt8, 8))   # one byte per line of line0:7
        end
    catch e
        @warn "Failed to zero the port-0 lines" error=string(e)
    end

    try
        write_commands!(daq, 0.0, 0.0)
    catch e
        @warn "Failed to zero the command outputs" error=string(e)
    end

    return nothing
end

# =============================================================================
# ROI SCAN (hardware-timed)
# =============================================================================

"""
    check_galvo_waveform(x, y)

Throw unless every galvo sample is finite and within `daq_galvo_limit_v`.
"""
function check_galvo_waveform(x::AbstractVector{<:Real}, y::AbstractVector{<:Real})
    for (name, v) in (("galvo X", x), ("galvo Y", y))
        all(isfinite, v) || error("$name: non-finite value, scan refused")
        peak = maximum(abs, v)
        peak <= daq_galvo_limit_v ||
            error("$name: $(round(peak, digits=3)) V exceeds the $(daq_galvo_limit_v) V limit, scan refused")
    end
    return nothing
end

"""
    start_scan_output!(daq, x, y, d; rate_hz=daq_scan_rate_hz)

Play one cycle of galvo waveform (`x`, `y`, in volts) and port-0 pattern
(`d`, one byte per sample, see `DO_BIT_*`) over and over until
`stop_scan_output!`: continuous generation with regeneration, so the card
replays the same buffer with no further writes from the host.
Both tasks are slaved to the counter clock, which starts last, so they
share every sample edge.

Each task is recorded in `daq.scan_tasks` as soon as it exists, so a STOP
arriving mid-setup, or a failure here, releases whatever was created.
"""
function start_scan_output!(daq::DaqSession, x::Vector{Float64}, y::Vector{Float64}, d::Vector{UInt8};
                            rate_hz::Real = daq_scan_rate_hz)
    n = length(x)
    (length(y) == n && length(d) == n) || throw(ArgumentError("x, y and d must have the same length"))
    n >= 2 || throw(ArgumentError("scan waveform needs at least 2 samples"))
    check_galvo_waveform(x, y)

    stop_scan_output!(daq)

    try
        tao = DAQmx.create_task("flimapp_galvos")
        push!(daq.scan_tasks, tao)
        DAQmx.add_ao_voltage(tao, daq_galvo_channels)
        DAQmx.cfg_sample_clock(tao, rate_hz; source = daq_clock_source, mode = DAQmx.Val_ContSamps, nsamp = n)
        DAQmx.cfg_output_buffer(tao, n)
        DAQmx.write_analog(tao, vcat(x, y); nsamp_per_chan = n)   # channel by channel

        tdo = DAQmx.create_task("flimapp_sync_lines")
        push!(daq.scan_tasks, tdo)
        DAQmx.add_do(tdo, daq_do_lines)
        DAQmx.cfg_sample_clock(tdo, rate_hz; source = daq_clock_source, mode = DAQmx.Val_ContSamps, nsamp = n)
        DAQmx.cfg_output_buffer(tdo, n)
        DAQmx.write_do_u8(tdo, d)

        tco = DAQmx.create_task("flimapp_clock")
        push!(daq.scan_tasks, tco)
        DAQmx.add_co_pulse_freq(tco, daq_clock_counter, rate_hz; duty = 0.5)
        DAQmx.cfg_implicit_timing(tco, DAQmx.Val_ContSamps, 1000)

        DAQmx.start_task(tao)   # slaves first: they wait for the first clock edge
        DAQmx.start_task(tdo)
        DAQmx.start_task(tco)   # the clock starts them both
    catch
        stop_scan_output!(daq)
        rethrow()
    end

    return nothing
end

"""
    stop_scan_output!(daq::DaqSession)

Stop and release the scan tasks, clock first so every output freezes on the
same sample. Outputs then hold their last value: `zero_all_outputs!` is what
brings them back to zero. No-op when no scan is running.
"""
function stop_scan_output!(daq::DaqSession)
    for th in reverse(daq.scan_tasks)
        try; DAQmx.stop_task(th); catch; end
        try; DAQmx.clear_task(th); catch; end
    end
    empty!(daq.scan_tasks)
    return nothing
end

# =============================================================================
# PI COMMAND OUTPUTS (software-timed)
# =============================================================================

"""
    command_volts(command::Real)::Float64

Output voltage for a PI command in percent: clamped to 0–100 % and scaled
to `daq_command_full_scale_v`; a non-finite command (controller off, no
setpoint) gives 0 V.
"""
function command_volts(command::Real)::Float64
    return isfinite(command) ? clamp(Float64(command), 0.0, 100.0) / 100.0 * daq_command_full_scale_v : 0.0
end

"""
    write_commands!(daq::DaqSession, command1::Real, command2::Real)

Set both command outputs now (on-demand write on the session's command task).
"""
function write_commands!(daq::DaqSession, command1::Real, command2::Real)
    DAQmx.write_analog(daq.command_task, [command_volts(command1), command_volts(command2)]; nsamp_per_chan = 1)
    return nothing
end

"""
    last_or_nan(values::Vector{Float64})::Float64

Return the latest value of a series, or `NaN` when empty.
"""
function last_or_nan(values::Vector{Float64})::Float64
    return isempty(values) ? NaN : values[end]
end

"""
    command_output_loop(app_run, blocks; rate=20.0)

Periodic task that writes the latest PI commands to the command outputs
while an acquisition runs. Holds the outputs while paused. A failed write
closes the DAQ session, zeroing what it still can, and shows it as
disconnected in the GUI.
"""
function command_output_loop(app_run, blocks; rate=20.0)
    dt = 1 / float(rate)

    while app_run.running[]
        if app_run.paused[]
            sleep(min(dt, 0.05))
            continue
        end

        daq = app_run.daq

        if daq === nothing
            sleep(dt)
            continue
        end

        try
            write_commands!(daq, last_or_nan(app_run.command1[]), last_or_nan(app_run.command2[]))
        catch e
            @warn "DAQ command output failed; disconnecting" error=string(e)
            app_run.daq = nothing
            disconnect_daq!(daq)
            show_daq_session!(blocks, nothing)
        end

        sleep(dt)
    end

    return nothing
end
