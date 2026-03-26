"""
data_processing.jl

Data acquisition and file I/O functions for the FLIM application.

Responsibilities:
- Serial device enumeration across platforms (Windows, macOS, Linux)
- Becker & Hickl .sdt file format reading
- Worker task for batch data processing
- Histogram binning and accumulation
"""

using ZipFile
using LibSerialPort
using Base.Threads

# =============================================================================
# SERIAL PORT ENUMERATION
# =============================================================================

"""
    list_ports()::Vector{String}

Return a sorted, de-duplicated list of available serial device names.

Platform-specific behavior:
- **Windows**: Queries WMI for COM ports via PowerShell
- **macOS**: Scans /dev for USB tty devices
- **Linux**: Checks /dev/serial/by-id and standard tty/ttyUSB devices

Returns:
- Vector of display names (e.g., `usbmodem1103`, `ttyUSB0`, `COM3`)
- Empty vector if no devices found
"""
function list_ports()::Vector{String}
    ports = String[]
    
    if Sys.iswindows()
        _enumerate_windows_ports!(ports)
    else
        _enumerate_unix_ports!(ports)
    end
    
    display_ports = map(_port_display_name, ports)
    return sort(unique(display_ports))
end

"""
    _serial_port_candidates(port_name::AbstractString)::Vector{String}

Build a list of concrete device candidates from a user-facing port name.
"""
function _serial_port_candidates(port_name::AbstractString)::Vector{String}
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
    connect_to_port(port_name::AbstractString; baudrate::Integer=115200, timeout_sec::Integer=3)

Attempt to connect to a serial port from a menu display name.
Returns an open serial handle on success, or `nothing` on failure.
"""
function connect_to_port(port_name::AbstractString; baudrate::Integer=115200, timeout_sec::Integer=3)
    candidates = _serial_port_candidates(port_name)
    if isempty(candidates)
        @warn "No port selected"
        return nothing
    end

    last_error = nothing

    for device in candidates
        try
            ser = LibSerialPort.open(device, baudrate)
            LibSerialPort.set_read_timeout(ser, timeout_sec)
            sleep(0.1)
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
    _port_display_name(port::AbstractString)::String

Convert a platform-specific device path/name into a compact display string.
Examples:
- `/dev/cu.usbmodem1103` -> `usbmodem1103`
- `/dev/ttyUSB0` -> `ttyUSB0`
- `COM8` -> `COM8`
"""
function _port_display_name(port::AbstractString)::String
    name = splitpath(port)[end]
    name = replace(name, r"^(tty\.|cu\.)" => "")
    return strip(name)
end

"""
    _enumerate_windows_ports!(ports::Vector{String})

Query Windows COM ports using PowerShell WMI.
"""
function _enumerate_windows_ports!(ports::Vector{String})
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
    _enumerate_unix_ports!(ports::Vector{String})

Scan /dev directory for Unix serial ports (macOS/Linux).
"""
function _enumerate_unix_ports!(ports::Vector{String})
    devdir = "/dev"
    
    if !isdir(devdir)
        @warn "Device directory not found: $devdir"
        return
    end
    
    files = readdir(devdir)
    
    if Sys.islinux()
        _enumerate_linux_ports!(ports, files)
    elseif Sys.isapple()
        _enumerate_macos_ports!(ports, files)
    else
        _enumerate_generic_unix_ports!(ports, files)
    end
end

"""
    _enumerate_linux_ports!(ports::Vector{String}, files::Vector{String})

Enumerate Linux tty devices including symbolic links from /dev/serial/by-id.
"""
function _enumerate_linux_ports!(ports::Vector{String}, files::Vector{String})
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
    _enumerate_macos_ports!(ports::Vector{String}, files::Vector{String})

Enumerate macOS USB serial ports.
"""
function _enumerate_macos_ports!(ports::Vector{String}, files::Vector{String})
    devdir = "/dev"
    for f in files
        if (startswith(f, "tty.") || startswith(f, "cu.")) && occursin("usb", lowercase(f))
            push!(ports, joinpath(devdir, f))
        end
    end
end

"""
    _enumerate_generic_unix_ports!(ports::Vector{String}, files::Vector{String})

Fallback enumeration for generic Unix systems.
"""
function _enumerate_generic_unix_ports!(ports::Vector{String}, files::Vector{String})
    devdir = "/dev"
    for f in files
        if startswith(f, "tty") || startswith(f, "cu.")
            push!(ports, joinpath(devdir, f))
        end
    end
end

# =============================================================================
# SDT FILE READING
# =============================================================================

"""
    reshape_to_vec(file::Vector{UInt8}, num_rows::Int)::Vector{Float64}

Helper utility for reading Becker & Hickl .sdt binary bundles.

Reshapes a raw byte vector into a 2D array with `num_rows` rows,
sums across columns, and returns the result as a column vector.

Args:
- `file::Vector{UInt8}` - Raw bytes from file
- `num_rows::Int` - Number of rows for reshape

Returns:
- Single-column vector with summed data
"""
function reshape_to_vec(file::Vector{UInt8}, num_rows::Int)::Vector{Float64}
    return sum(reshape(file, (num_rows, :)), dims=2)[:, 1]
end

"""
    open_SDT_file(filepath::String)::Tuple{Vector{UInt16}, Int, Float32}

Low-level reader for Becker & Hickl .sdt binary files.

Parses the file header to extract:
- Histogram data (photon counts)
- Histogram resolution (number of time bins)
- Time per channel (acquisition duration)

The function handles two file format variants:
1. Simple format (uncompressed histogram)
2. ZIP-compressed format

Args:
- `filepath::String` - Path to .sdt file

Returns:
- Tuple of (counts::Vector{UInt16}, resolution::Int, time_per_channel::Float32)
"""
function open_SDT_file(filepath::String)::Tuple{Vector{UInt16}, Int, Float32}
    open(filepath, "r") do io
        # Read header to find data offset and size
        seek(io, 14)
        header = read!(io, Vector{UInt8}(undef, 12))

        # Extract histogram resolution and time per channel
        seek(io, header[12]*0x100 + header[11] + 82)
        infos = read!(io, Vector{UInt8}(undef, 2))
        histogram_resolution = infos[2]*0x100 + infos[1]
    
        seek(io, header[12]*0x100 + header[11] + 215)
        infos_2 = read!(io, Vector{UInt8}(undef, 4))
        time = reinterpret(Float32, infos_2)[1]

        # Check format type and read accordingly
        if (header[8]*0x100 + header[7]) in (512, 128)
            # Simple uncompressed format
            seek(io, header[2]*0x100 + header[1] + 22)
            vector = read(io)  # Read rest of file
            
            # Fast conversion to UInt16 without loop
            n = div(length(vector), 2)
            new_vector = reinterpret(UInt16, vector[1:2*n])
            return new_vector, histogram_resolution, time
        else
            # ZIP-compressed format
            seek(io, header[2]*0x100 + header[1] + 2)
            file_info = read!(io, Vector{UInt8}(undef, 20))
            shift_1 = file_info[8]*0x1000000 + file_info[7]*0x10000 + file_info[6]*0x100 + file_info[5] -
                      (file_info[2]*0x100 + file_info[1])
            shift_2 = file_info[20]*0x1000000 + file_info[19]*0x10000 + file_info[18]*0x100 + file_info[17]

            buffer = IOBuffer(read(io, shift_1))
            zip_file = first(ZipFile.Reader(buffer).files)

            file_data = Vector{UInt8}(undef, shift_2)
            read!(zip_file, file_data)

            vector = reshape_to_vec(reinterpret(UInt16, file_data), histogram_resolution)
            return convert.(UInt16, vector), histogram_resolution, time
        end
    end
end

# =============================================================================
# WORKER TASK
# =============================================================================

"""
    start_playback(ch::Channel, running::Threads.Atomic{Bool}, layout::Dict;
                                        dt::Float64=0.05)

Worker task for Playback mode.

Loops over all `.sdt` files in `DATA_ROOT_PATH` in circular order.

Implements histogram binning via sliding-window accumulation for efficiency.

Args:
- `ch::Channel` - Output channel for (histogram, fit, photons, ...) tuples
- `running::Threads.Atomic{Bool}` - Flag to control loop termination
- `layout::Dict` - Layout config (for binning parameter)

Keyword Args:
- `dt::Float64` - Sleep interval between frames (default 0.05 seconds)

The channel tuples contain:
1. histogram::Vector{Float64} - Raw photon counts
2. fit::Vector{Float64} - Fitted exponential decay
3. photons::Float64 - Total photon counts
4. command1::Float64 - PID command for controller 1
5. command2::Float64 - PID command for controller 2
6. lifetime::Float64 - Fitted decay constant (τ)
7. concentration::Float64 - Computed ion concentration
8. timestamps::Float64 - Cumulative acquisition time
9. reserved::Float64 - Placeholder for future use
10. i::UInt32 - Frame counter
"""
function start_playback(
    ch::Channel{Tuple{Vector{Float64},Vector{Float64},Float64,Float64,Float64,Float64,Float64,Float64,Float64,UInt32}},
        running::Threads.Atomic{Bool},
    layout::Dict{Symbol, Any},
    controller::Dict{Symbol, Any};
        dt::Float64 = 0.0001
    )
    try
        @info "Playback worker started on thread $(threadid())"
        
        # Check if IRF is loaded (required for lifetime fitting)
        @info "Checking IRF status: irf=$(irf !== nothing), tcspc_window_size=$(tcspc_window_size !== nothing)"
        if irf === nothing || tcspc_window_size === nothing
            @error "IRF not loaded - cannot start data processing. Please load an IRF file first."
            @error "IRF status: irf=$(irf !== nothing), tcspc_window_size=$(tcspc_window_size !== nothing)"
            return
        end
        
        path = get_data_root_path()
        if !isdir(path)
            @error "Data folder not found: $path"
            return
        end

        all_entries = readdir(path; join=true)
        filepaths = sort(filter(f -> isfile(f) && endswith(lowercase(f), ".sdt"), all_entries))
        nb_files = length(filepaths)

        if nb_files == 0
            @error "No .sdt files found in $path"
            return
        end
        
        timestamps = 0.0
        vectors = zeros(100, DEFAULT_HISTOGRAM_RESOLUTION)
        n_vectors = 100

        # Sliding sum optimization for binning
        sum_vector = zeros(Float64, DEFAULT_HISTOGRAM_RESOLUTION)
        last_bin = 1
        current_count = 0

        # Initial parameter guess for lifetime fitting
        params = [3.0, 0.5, 0.5, 0.0, 5.0e-5]
        n = UInt32(0)

        # Adaptive anti-spike controls for expensive lifetime optimization.
        fit_every = max(1, Int(get(layout, :fit_every, 1)))
        max_fit_ms = max(1.0, Float64(get(layout, :max_fit_ms, 35.0)))
        fit_cooldown_frames = max(0, Int(get(layout, :fit_cooldown_frames, 3)))
        skip_fit_frames = 0

        # PID state for lifetime control
        lifetime_setpoint_ns = 4.0
        I_error = 0.0
        old_error = 0.0
        D_error = 0.0

        while running[]
            filepath = filepaths[mod1(n+1, nb_files)]

            vector, histogram_resolution, time = open_SDT_file(filepath)

            # Store in circular buffer
            pos = mod1(n+1, n_vectors)
            vectors[pos, 1:histogram_resolution] .= vector

            # Apply binning from layout with sliding window optimization
            bin = get(layout, :binning, 1)

            if bin != last_bin
                # Recalculate when binning changes
                effective_bin = min(bin, current_count + 1)
                idxs = mod1.(pos .- (0:effective_bin-1), n_vectors)
                fill!(sum_vector, 0.0)
                @inbounds for idx in idxs
                    @views sum_vector[1:histogram_resolution] .+= vectors[idx, 1:histogram_resolution]
                end
                last_bin = bin
                current_count = effective_bin
            else
                if current_count < bin
                    # Still filling window
                    sum_vector .+= vector
                    current_count += 1
                else
                    # Slide window: remove oldest, add new
                    old_pos = mod1(pos - bin, n_vectors)
                    sum_vector .-= vectors[old_pos, 1:histogram_resolution]
                    sum_vector .+= vector
                end
            end

            final_vector = sum_vector ./ bin

            # Fit lifetime can be expensive; throttle and cool down after spikes.
            should_fit = (skip_fit_frames == 0) && ((Int(n) % fit_every == 0) || n == 0)

            if should_fit
                t_fit_start = time_ns()
                params_raw, data = vec_to_lifetime(Float64.(final_vector); guess=params, histogram_resolution=histogram_resolution)
                fit_elapsed_ms = (time_ns() - t_fit_start) / 1e6

                if fit_elapsed_ms > max_fit_ms
                    skip_fit_frames = fit_cooldown_frames
                end

                if !isnan(params_raw[1])
                    params = params_raw
                end
            else
                if skip_fit_frames > 0
                    skip_fit_frames -= 1
                end

                x_data = collect(irf_bin_size:irf_bin_size:histogram_resolution*irf_bin_size)
                data = [x_data, Float64.(final_vector)]
            end

            histogram = data[2]
            photons = sum(histogram)
            fit = conv_irf_data(data[1], Tuple(params), irf; histogram_resolution=histogram_resolution)*photons
            lifetime = params[1]
            concentration = (9.5 / lifetime - 1)/0.025
            timestamps += time
            n += 1

            # PID terms are shared from one lifetime error for both controllers.
            dt_sample = max(Float64(time), eps(Float64))
            P_error = lifetime_setpoint_ns - lifetime
            I_error += P_error * dt_sample
            D_error = (P_error - old_error) / dt_sample
            old_error = P_error

            p1 = Float64(get(controller, :P1, 0.0))
            i1 = Float64(get(controller, :I1, 0.0))
            d1 = Float64(get(controller, :D1, 0.0))
            p2 = Float64(get(controller, :P2, 0.0))
            i2 = Float64(get(controller, :I2, 0.0))
            d2 = Float64(get(controller, :D2, 0.0))

            command1 = p1*P_error + i1*I_error + d1*D_error
            command2 = p2*P_error + i2*I_error + d2*D_error

            # Inversion is applied only to the command sent to each controller.
            if Bool(get(controller, :ch1_inv, false))
                command1 = -command1
            end

            if Bool(get(controller, :ch2_inv, false))
                command2 = -command2
            end

            if Bool(get(controller, :ch1_on, false))
                command1 = clamp(command1, 0.0, 100.0)
            else
                command1 = NaN
            end

            if Bool(get(controller, :ch2_on, false))
                command2 = clamp(command2, 0.0, 100.0)
            else
                command2 = NaN
            end

            # Send results; handle closed channel gracefully
            if isopen(ch) && running[]
                try
                    put!(ch, (histogram, fit, photons, command1, command2, lifetime, concentration, timestamps, photons, n))
                catch e
                    if isa(e, InvalidStateException)
                        break
                    else
                        rethrow()
                    end
                end
            else
                break
            end
            
            sleep(dt)
        end
    catch e
        @error "Playback worker error" exception=e
        rethrow()
    finally
        running[] = false
        try
            close(ch)
        catch
            # Ignore if already closed
        end
        @info "Playback worker finished"
    end
    
    return nothing
end

"""
    start_realtime(ch::Channel, running::Threads.Atomic{Bool}, layout::Dict;
                                        dt::Float64=0.05, poll_interval_s::Float64=0.1)

Worker task for Real-time mode.

Always processes the newest available `.sdt` file in `DATA_ROOT_PATH`.
If no file exists yet, or if the newest file was already processed, it waits
until a new file appears.
"""
function start_realtime(
    ch::Channel{Tuple{Vector{Float64},Vector{Float64},Float64,Float64,Float64,Float64,Float64,Float64,Float64,UInt32}},
        running::Threads.Atomic{Bool},
    layout::Dict{Symbol, Any},
    controller::Dict{Symbol, Any};
        dt::Float64 = 0.0001,
        poll_interval_s::Float64 = 0.1
    )
    try
        @info "Real-time worker started on thread $(threadid())"

        @info "Checking IRF status: irf=$(irf !== nothing), tcspc_window_size=$(tcspc_window_size !== nothing)"
        if irf === nothing || tcspc_window_size === nothing
            @error "IRF not loaded - cannot start data processing. Please load an IRF file first."
            @error "IRF status: irf=$(irf !== nothing), tcspc_window_size=$(tcspc_window_size !== nothing)"
            return
        end

        path = get_data_root_path()
        @info "Real-time mode active: waiting for new .sdt files in $path"

        timestamps = 0.0
        vectors = zeros(100, DEFAULT_HISTOGRAM_RESOLUTION)
        n_vectors = 100

        sum_vector = zeros(Float64, DEFAULT_HISTOGRAM_RESOLUTION)
        last_bin = 1
        current_count = 0

        params = [3.0, 0.5, 0.5, 0.0, 5.0e-5]
        n = UInt32(0)

        # Adaptive anti-spike controls for expensive lifetime optimization.
        fit_every = max(1, Int(get(layout, :fit_every, 1)))
        max_fit_ms = max(1.0, Float64(get(layout, :max_fit_ms, 35.0)))
        fit_cooldown_frames = max(0, Int(get(layout, :fit_cooldown_frames, 3)))
        skip_fit_frames = 0

        lifetime_setpoint_ns = 4.0
        I_error = 0.0
        old_error = 0.0
        D_error = 0.0

        last_processed_filepath = ""

        while running[]
            all_entries = readdir(path; join=true)
            filepaths = sort(filter(f -> isfile(f) && endswith(lowercase(f), ".sdt"), all_entries))

            if isempty(filepaths)
                sleep(poll_interval_s)
                continue
            end

            latest_filepath = filepaths[argmax(stat.(filepaths) .|> s -> s.mtime)]

            if latest_filepath == last_processed_filepath
                sleep(poll_interval_s)
                continue
            end

            filepath = latest_filepath
            vector, histogram_resolution, time = open_SDT_file(filepath)
            last_processed_filepath = filepath

            pos = mod1(n+1, n_vectors)
            vectors[pos, 1:histogram_resolution] .= vector

            bin = get(layout, :binning, 1)

            if bin != last_bin
                effective_bin = min(bin, current_count + 1)
                idxs = mod1.(pos .- (0:effective_bin-1), n_vectors)
                fill!(sum_vector, 0.0)
                @inbounds for idx in idxs
                    @views sum_vector[1:histogram_resolution] .+= vectors[idx, 1:histogram_resolution]
                end
                last_bin = bin
                current_count = effective_bin
            else
                if current_count < bin
                    sum_vector .+= vector
                    current_count += 1
                else
                    old_pos = mod1(pos - bin, n_vectors)
                    sum_vector .-= vectors[old_pos, 1:histogram_resolution]
                    sum_vector .+= vector
                end
            end

            final_vector = sum_vector ./ bin

            should_fit = (skip_fit_frames == 0) && ((Int(n) % fit_every == 0) || n == 0)

            if should_fit
                t_fit_start = time_ns()
                params_raw, data = vec_to_lifetime(Float64.(final_vector); guess=params, histogram_resolution=histogram_resolution)
                fit_elapsed_ms = (time_ns() - t_fit_start) / 1e6

                if fit_elapsed_ms > max_fit_ms
                    skip_fit_frames = fit_cooldown_frames
                end

                if !isnan(params_raw[1])
                    params = params_raw
                end
            else
                if skip_fit_frames > 0
                    skip_fit_frames -= 1
                end

                x_data = collect(irf_bin_size:irf_bin_size:histogram_resolution*irf_bin_size)
                data = [x_data, Float64.(final_vector)]
            end

            histogram = data[2]
            photons = sum(histogram)
            fit = conv_irf_data(data[1], Tuple(params), irf; histogram_resolution=histogram_resolution) * photons
            lifetime = params[1]
            concentration = (9.5 / lifetime - 1) / 0.025
            timestamps += time
            n += 1

            dt_sample = max(Float64(time), eps(Float64))
            P_error = lifetime_setpoint_ns - lifetime
            I_error += P_error * dt_sample
            D_error = (P_error - old_error) / dt_sample
            old_error = P_error

            p1 = Float64(get(controller, :P1, 0.0))
            i1 = Float64(get(controller, :I1, 0.0))
            d1 = Float64(get(controller, :D1, 0.0))
            p2 = Float64(get(controller, :P2, 0.0))
            i2 = Float64(get(controller, :I2, 0.0))
            d2 = Float64(get(controller, :D2, 0.0))

            command1 = p1*P_error + i1*I_error + d1*D_error
            command2 = p2*P_error + i2*I_error + d2*D_error

            if Bool(get(controller, :ch1_inv, false))
                command1 = -command1
            end

            if Bool(get(controller, :ch2_inv, false))
                command2 = -command2
            end

            if Bool(get(controller, :ch1_on, false))
                command1 = clamp(command1, 0.0, 100.0)
            else
                command1 = NaN
            end

            if Bool(get(controller, :ch2_on, false))
                command2 = clamp(command2, 0.0, 100.0)
            else
                command2 = NaN
            end

            if isopen(ch) && running[]
                try
                    put!(ch, (histogram, fit, photons, command1, command2, lifetime, concentration, timestamps, photons, n))
                catch e
                    if isa(e, InvalidStateException)
                        break
                    else
                        rethrow()
                    end
                end
            else
                break
            end

            sleep(dt)
        end
    catch e
        @error "Real-time worker error" exception=e
        rethrow()
    finally
        running[] = false
        try
            close(ch)
        catch
            # Ignore if already closed
        end
        @info "Real-time worker finished"
    end

    return nothing
end
