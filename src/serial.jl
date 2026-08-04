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
"""
function write_pwm_command!(serial_conn, channel::Int, frequency::Int, command::Float64)
    cmd = isfinite(command) ? clamp(command, 0.0, 100.0) : 0.0

    if cmd <= 0.0
        write(serial_conn, "A 0 AO $channel 0\n")
    elseif cmd >= 100.0
        write(serial_conn, "A 0 AO $channel 5000\n")
    else
        write(serial_conn, "A 0 AP $channel $(Int(frequency)) $cmd 0 5000\n")
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
    zero_all_outputs!(serial_conn)

Drive every analog (AO 1–4) and digital (DO 1–3) output to zero — the safe
resting state sent on both STOP (runtime.jl) and disconnect (handlers.jl).
Failures are logged, not raised, so a flaky port can't block shutdown.
"""
function zero_all_outputs!(serial_conn)
    try
        for ch in 1:4
            send_command(serial_conn, "A 0 AO $ch 0\n")
        end
        for ch in 1:3
            send_command(serial_conn, "A 0 DO $ch 0\n")
        end
    catch e
        @warn "Failed to zero hardware outputs" error=string(e)
    end
    return nothing
end


"""
    serial_signal_loop(app, app_run; rate=10.0)

Periodic task that sends controller commands to the connected serial device.
"""
function serial_signal_loop(app, app_run; rate=10.0)
    dt = 1 / float(rate)

    while app_run.running[]
        if app_run.paused[]
            sleep(min(dt, 0.05))
            continue
        end

        serial_conn = app_run.serial_conn

        if serial_conn === nothing
            sleep(dt)
            continue
        end

        try
            frequency = safe_frequency(app.controller)
            cmd1 = last_or_nan(app_run.command1[])
            cmd2 = last_or_nan(app_run.command2[])

            write_pwm_command!(serial_conn, 3, frequency, cmd1)
            write_pwm_command!(serial_conn, 4, frequency, cmd2)
        catch e
            @warn "Serial signal send failed" error=string(e)

            try
                close(serial_conn)
            catch
            end

            app_run.serial_conn = nothing
        end

        sleep(dt)
    end

    return nothing
end
