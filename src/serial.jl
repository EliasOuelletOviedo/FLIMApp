"""
serial.jl

Serial hardware I/O for the FLIM application: port discovery/enumeration
across platforms, connecting to a device, and sending PID/PWM commands to a
connected controller during acquisition.
"""

using LibSerialPort

"""
    list_ports()::Vector{String}

Sorted, de-duplicated display names of available serial devices (e.g.
`usbmodem1103`, `ttyUSB0`, `COM3`); empty if none found. Discovery is
platform-specific: Windows queries WMI for COM ports, macOS scans /dev for
USB ttys, Linux checks /dev/serial/by-id and standard tty/ttyUSB devices.
"""
function list_ports()::Vector{String}
    ports = String[]

    if Sys.iswindows()
        enumerate_windows_ports!(ports)
    else
        enumerate_unix_ports!(ports)
    end

    display_ports = map(port_display_name, ports)
    return sort(unique(display_ports))
end

"""
    serial_port_candidates(port_name::AbstractString)::Vector{String}

Build a list of concrete device candidates from a user-facing port name.
"""
function serial_port_candidates(port_name::AbstractString)::Vector{String}
    name = strip(String(port_name))
    if isempty(name)
        return String[]
    end

    candidates = String[]

    # If a full path/identifier is provided, try it first.
    if startswith(name, "/dev/") || occursin(r"^COM\d+$", uppercase(name))
        push!(candidates, name)
    end

    if Sys.isapple()
        push!(candidates, "/dev/tty." * name)
        push!(candidates, "/dev/cu." * name)
        push!(candidates, "/dev/" * name)
    elseif Sys.iswindows()
        push!(candidates, uppercase(name))
    else
        push!(candidates, "/dev/" * name)
        push!(candidates, "/dev/tty." * name)
    end

    return unique(candidates)
end

"""
    connect_to_port(port_name::AbstractString; baudrate::Integer=115200, timeout_sec::Integer=3, settle_sec::Real=2.0)

Attempt to connect to a serial port from a menu display name.
Returns an open serial handle on success, or `nothing` on failure.

`settle_sec` is how long to wait after opening the port before returning it
ready to use. Many USB-serial boards (Arduino-compatible ones especially)
reboot when the host opens the port (DTR toggling resets the MCU) and can't
respond to anything until that reboot finishes — this used to be a flat
`sleep(0.1)`, nowhere near a typical board's boot time, so the very first
command sent right after connecting (the ROI trigger-box upload, roi.jl,
if ROI mode is active) would time out waiting for a device that was still
booting; every command after that worked fine since by then the board had
finished rebooting and the *port* stays open across acquisition start/stop
without reconnecting.
"""
function connect_to_port(port_name::AbstractString; baudrate::Integer=115200, timeout_sec::Integer=3, settle_sec::Real=2.0)
    candidates = serial_port_candidates(port_name)
    if isempty(candidates)
        @warn "No port selected"
        return nothing
    end

    last_error = nothing

    for device in candidates
        try
            ser = LibSerialPort.open(device, baudrate)
            LibSerialPort.set_read_timeout(ser, timeout_sec)
            sleep(settle_sec)
            @info "Connection successful" device=device baudrate=baudrate
            return ser
        catch e
            last_error = e
        end
    end

    if last_error === nothing
        @warn "Connection error" port=port_name
    else
        @warn "Connection error" port=port_name error=string(last_error)
    end

    return nothing
end

"""
    port_display_name(port::AbstractString)::String

Convert a platform-specific device path/name into a compact display string.
Examples:
- `/dev/cu.usbmodem1103` -> `usbmodem1103`
- `/dev/ttyUSB0` -> `ttyUSB0`
- `COM8` -> `COM8`
"""
function port_display_name(port::AbstractString)::String
    name = splitpath(port)[end]
    name = replace(name, r"^(tty\.|cu\.)" => "")
    return strip(name)
end

"""
    enumerate_windows_ports!(ports::Vector{String})

Query Windows COM ports using PowerShell WMI.
"""
function enumerate_windows_ports!(ports::Vector{String})
    cmd = `powershell -NoProfile -Command "Get-WmiObject Win32_SerialPort | Select-Object -Property DeviceID,Caption | Format-Table -HideTableHeaders"`

    try
        out = read(cmd, String)
        for line in split(out, '\n')
            m = match(r"COM\d+", line)
            if m !== nothing
                push!(ports, strip(m.match))
            end
        end
    catch e
        @warn "Unable to query Windows COM ports via PowerShell" error=string(e)
    end
end

"""
    enumerate_unix_ports!(ports::Vector{String})

Scan /dev directory for Unix serial ports (macOS/Linux).
"""
function enumerate_unix_ports!(ports::Vector{String})
    devdir = "/dev"

    if !isdir(devdir)
        @warn "Device directory not found: $devdir"
        return
    end

    files = readdir(devdir)

    if Sys.islinux()
        enumerate_linux_ports!(ports, files)
    elseif Sys.isapple()
        enumerate_macos_ports!(ports, files)
    else
        enumerate_generic_unix_ports!(ports, files)
    end
end

"""
    enumerate_linux_ports!(ports::Vector{String}, files::Vector{String})

Enumerate Linux tty devices including symbolic links from /dev/serial/by-id.
"""
function enumerate_linux_ports!(ports::Vector{String}, files::Vector{String})
    # Check symbolic links in by-id directory (more stable than device names)
    byid = "/dev/serial/by-id"
    if isdir(byid)
        for f in readdir(byid)
            full_path = joinpath(byid, f)
            push!(ports, full_path)

            try
                target = realpath(full_path)
                push!(ports, target)
            catch
                # Ignore symlink resolution failures
            end
        end
    end

    # Also add standard device names
    devdir = "/dev"
    for f in files
        if occursin(r"^ttyUSB", f) || occursin(r"^ttyACM", f) || occursin(r"^ttyAMA", f)
            push!(ports, joinpath(devdir, f))
        end
    end
end

"""
    enumerate_macos_ports!(ports::Vector{String}, files::Vector{String})

Enumerate macOS USB serial ports.
"""
function enumerate_macos_ports!(ports::Vector{String}, files::Vector{String})
    devdir = "/dev"
    for f in files
        if (startswith(f, "tty.") || startswith(f, "cu.")) && occursin("usb", lowercase(f))
            push!(ports, joinpath(devdir, f))
        end
    end
end

"""
    enumerate_generic_unix_ports!(ports::Vector{String}, files::Vector{String})

Fallback enumeration for generic Unix systems.
"""
function enumerate_generic_unix_ports!(ports::Vector{String}, files::Vector{String})
    devdir = "/dev"
    for f in files
        if startswith(f, "tty") || startswith(f, "cu.")
            push!(ports, joinpath(devdir, f))
        end
    end
end

"""
    last_or_nan(values::Vector{Float64})::Float64

Return the latest value of a series, or `NaN` when empty.
"""
function last_or_nan(values::Vector{Float64})::Float64
    return isempty(values) ? NaN : values[end]
end

"""
    safe_frequency(controller::ControllerSettings)::Int

Read PWM frequency from controller config and clamp to a positive integer.
"""
function safe_frequency(controller::ControllerSettings)::Int
    return max(1, controller.freq)
end

"""
    write_pwm_command!(serial_conn, channel::Int, frequency::Int, command::Float64)

Emit the proper command for PWM/analog output depending on command saturation.

Full scale is `ANALOG_OUTPUT_MAX_MV` (config.jl), the same ceiling
`command_to_power_mv` (roi.jl) uses. This used to be a hard-coded 5000 while
the power path used 1000, so a 100% command meant 5000 mV here and 1000 mV
there — and which one reached output 3 depended on the ROI toggle. A
non-finite command (the "no command" sentinel) emits 0, not the last level.
"""
function write_pwm_command!(serial_conn, channel::Int, frequency::Int, command::Float64)
    cmd = isfinite(command) ? clamp(command, 0.0, 100.0) : 0.0

    if cmd <= 0.0
        write(serial_conn, "A 0 AO $channel 0\n")
    elseif cmd >= 100.0
        write(serial_conn, "A 0 AO $channel $ANALOG_OUTPUT_MAX_MV\n")
    else
        write(serial_conn, "A 0 AP $channel $(Int(frequency)) $cmd 0 $ANALOG_OUTPUT_MAX_MV\n")
    end

    return nothing
end

"""
    send_command(serial_conn, command_str::AbstractString)

Write a raw command string to serial.
"""
function send_command(serial_conn, command_str::AbstractString)
    write(serial_conn, String(command_str))
    return nothing
end

"""
    drain_serial_input!(serial_conn)::Int

Discard everything the device has sent and nobody asked for, returning how many
bytes went. Never blocks: it only takes what is already buffered.

The trigger box answers every command with `OK`, and additionally announces
digital-input transitions on its own (`D2H`/`D2L` as the cycle pulse rises and
falls). `send_command` is fire-and-forget and reads none of it, so a loop
writing at 20 Hz leaves ~20 unread replies a second behind it, forever. That
output has to go somewhere: it fills the host's receive buffer, and once that
stops being emptied the device's own transmit buffer backs up behind it. A
device that cannot flush its output typically stops servicing input as well —
which is what "works for a while, then the board stops accepting commands"
looks like from the outside.

Cheap enough to call on every iteration of a periodic loop, and the right place
to do it: draining only when a reply is wanted leaves the gaps in between
accumulating.
"""
function drain_serial_input!(serial_conn)::Int
    discarded = 0

    try
        while bytesavailable(serial_conn) > 0
            discarded += length(read(serial_conn))
        end
    catch
        # A dead port is the caller's problem to notice, not this helper's.
    end

    return discarded
end

"""
    zero_all_outputs!(serial_conn)

Drive every analog (AO 1–4) and digital (DO 1–4) output to zero — the safe
resting state sent on both STOP (runtime.jl) and disconnect (handlers.jl).
Failures are logged, not raised, so a flaky port can't block shutdown.

Digital output 4 is included because it carries the ROI cycle pulse
(`roi_cycle_pulse_command`, roi.jl), which the rest of the rig triggers off:
left running past STOP it keeps re-arming the galvo sweep and the power box.
It used to stop at output 3, so that pulse survived the end of the run.
"""
function zero_all_outputs!(serial_conn)
    try
        for ch in 1:4
            send_command(serial_conn, "A 0 AO $ch 0\n")
        end
        for ch in 1:4
            send_command(serial_conn, "A 0 DO $ch 0\n")
        end
    catch e
        @warn "Failed to zero hardware outputs" error=string(e)
    end
    return nothing
end


"""
    drives_analog_output_directly(app, app_run)::Bool

Whether this run drives analog output 3 as a held level, written once per
acquired image (`push_whole_image_command!`, roi.jl), rather than through the
power box's replayed buffer.

True in the two configurations where there is a single region and therefore a
single power level to apply, so nothing has to be sequenced in time:

- **ROI mode off** — the ratio is taken over the whole frame;
- **ROI mode on with exactly one ROI** — the galvo traces that one ROI for the
  whole period (`roi_trigger_buffer` drops the settle dwell in that case, since
  there is nowhere to shift to), so its power is likewise constant across the
  period.

A buffer only earns its keep from two ROIs up, where the level has to change
partway through the cycle. Region count comes from `rois_series`, fixed for
the run by `rebuild_roi_series!`, rather than from the live ROI set, so a mid-run
edit in the ROI popup cannot flip the routing under a running acquisition.

Both the per-image writer and `serial_signal_loop` below consult this, so that
exactly one of them owns output 3 at any time.
"""
function drives_analog_output_directly(app, app_run)::Bool
    return !app.roi.active || length(app_run.rois_series) <= 1
end

"""
    power_owns_analog_output(app, app_run)::Bool

Whether the power path — in any of its forms — is the owner of the analog
output `serial_signal_loop` would otherwise drive, and so whether that loop
must keep its hands off it.

True in two of the three power configurations:

- the held level written once per image (`drives_analog_output_directly`);
- the alternating set-and-wait sequences (`RoiPowerSequencer`, roi.jl), which
  apply when a protocol is running with two or more ROIs.

False only when power goes out over the second box's replayed buffer, which
touches a different device entirely and leaves this output to the PI loop.

Checking only `drives_analog_output_directly` was not enough, and the symptom
was unmistakable: in sequencer mode that helper is false, so the loop kept
writing `A 0 AP 3 <freq> <duty> 0 <max>` twenty times a second — a PWM at
`controller.freq` (1 kHz by default) fighting the sequence for the same pin.
On a scope that is a 0-to-full-scale square wave with ~500 µs pulses, which is
nothing like the per-ROI levels the sequence is trying to hold.
"""
function power_owns_analog_output(app, app_run)::Bool
    return drives_analog_output_directly(app, app_run) || app.protocol.active
end

"""
    serial_signal_loop(app, app_run; rate=10.0)

Periodic task that sends controller commands to the connected serial device.

Output 3 is skipped whenever `power_owns_analog_output` holds — that is,
whenever either the per-image held level or the alternating power sequences
are driving it. Leaving this loop's PWM write in place there puts two writers
on one pin, and the PWM wins often enough to bury whatever the other was
trying to hold.

Two things keep this loop from flooding the device, both of which matter
because it is the only thing here that runs continuously for the whole
acquisition:

- **it only writes when a command actually changes.** An unchanged command
  re-sent at `rate` Hz asks the box to do work it has already done and to
  answer for it, and a settled controller produces the same value for minutes
  at a time. The output is a held level, so silence leaves it exactly where the
  last write put it.
- **it drains the device's output every iteration** (`drain_serial_input!`).
  Nothing else reads this port between images, and the box talks whether or not
  anyone is listening.
"""
function serial_signal_loop(app, app_run; rate=10.0)
    dt = 1 / float(rate)

    # `isequal`, not `==`, everywhere these are compared: the "no command"
    # sentinel is NaN, and NaN == NaN is false, so a plain comparison would
    # rewrite the same NaN forever — the exact case this is meant to skip.
    last_cmd1 = nothing
    last_cmd2 = nothing

    while app_run.running[]
        if app_run.paused[]
            sleep(min(dt, 0.05))
            continue
        end

        serial_conn = app_run.serial1

        if serial_conn === nothing
            sleep(dt)
            continue
        end

        try
            frequency = safe_frequency(app.controller)
            cmd1 = last_or_nan(app_run.command1[])
            cmd2 = last_or_nan(app_run.command2[])

            # Whatever the box has said since the last pass — command replies
            # nobody asked for, digital-input notifications — goes now, so it
            # cannot accumulate across the gaps between images.
            drain_serial_input!(serial_conn)

            if !power_owns_analog_output(app, app_run) && !isequal(cmd1, last_cmd1)
                write_pwm_command!(serial_conn, 3, frequency, cmd1)
                last_cmd1 = cmd1
            end

            if !isequal(cmd2, last_cmd2)
                write_pwm_command!(serial_conn, 4, frequency, cmd2)
                last_cmd2 = cmd2
            end
        catch e
            @warn "Serial signal send failed" error=string(e)

            # Try to park the outputs before letting go of the port. The write
            # that just failed may only have been a transient, in which case
            # dropping the connection without this leaves the box driving its
            # last commanded level with nothing left able to talk to it.
            try
                zero_all_outputs!(serial_conn)
            catch
            end

            try
                close(serial_conn)
            catch
            end

            app_run.serial1 = nothing
        end

        sleep(dt)
    end

    return nothing
end
