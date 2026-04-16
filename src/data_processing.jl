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
    connect_to_port(port_name::AbstractString; baudrate::Integer=115200, timeout_sec::Integer=3)

Attempt to connect to a serial port from a menu display name.
Returns an open serial handle on success, or `nothing` on failure.
"""
function connect_to_port(port_name::AbstractString; baudrate::Integer=115200, timeout_sec::Integer=3)
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

@inline function protocol_float_or_nan(raw_value)::Float64
    if raw_value isa Number
        return Float64(raw_value)
    elseif raw_value isa AbstractString
        return something(tryparse(Float64, strip(raw_value)), NaN)
    else
        return NaN
    end
end

@inline function protocol_int_or(raw_value, default::Int; min_value::Int=0)::Int
    parsed = if raw_value isa Integer
        Int(raw_value)
    elseif raw_value isa AbstractFloat
        round(Int, raw_value)
    elseif raw_value isa AbstractString
        something(tryparse(Int, strip(raw_value)), default)
    else
        default
    end
    return max(parsed, min_value)
end

function protocol_steps(protocol::Dict{Symbol, Any})::Vector{Tuple{Float64, Float64}}
    times_raw = get(protocol, :times, Float64[])
    setpoints_raw = get(protocol, :setpoints, Float64[])

    if !(times_raw isa AbstractVector) || !(setpoints_raw isa AbstractVector)
        return Tuple{Float64, Float64}[]
    end

    nsteps = min(length(times_raw), length(setpoints_raw))
    steps = Tuple{Float64, Float64}[]

    for idx in 1:nsteps
        duration = protocol_float_or_nan(times_raw[idx])
        setpoint = protocol_float_or_nan(setpoints_raw[idx])

        if !isfinite(duration) || duration <= 0.0
            continue
        end

        push!(steps, (duration, setpoint))
    end

    return steps
end

function protocol_setpoint_at_timestamp(protocol::Dict{Symbol, Any}, timestamp::Real)::Float64
    t = Float64(timestamp)
    if !isfinite(t)
        return NaN
    end

    delay_s = protocol_int_or(get(protocol, :delay, 0), 0; min_value=0)
    repeats = protocol_int_or(get(protocol, :repeats, 1), 1; min_value=0)
    steps = protocol_steps(protocol)

    if isempty(steps)
        return NaN
    end

    t_after_delay = t - delay_s
    if t_after_delay < 0.0
        return NaN
    end

    cycle_duration = sum(step -> step[1], steps)
    if cycle_duration <= 0.0
        return NaN
    end

    if repeats > 0
        total_duration = repeats * cycle_duration
        if t_after_delay >= total_duration
            return NaN
        end
    end

    cycle_t = mod(t_after_delay, cycle_duration)
    elapsed = 0.0

    for (duration, setpoint) in steps
        elapsed += duration
        if cycle_t < elapsed
            return setpoint
        end
    end

    return steps[end][2]
end

@inline function resolve_protocol_config(protocol)
    if protocol === nothing
        return nothing
    end

    candidate = if protocol isa Observables.AbstractObservable
        protocol[]
    else
        protocol
    end

    return candidate isa Dict{Symbol, Any} ? candidate : nothing
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
- `dt::Float64` - Polling interval used to check scheduling cadence

The channel tuples contain:
1. histogram::Vector{Float64} - Raw photon counts
2. fit::Vector{Float64} - Fitted exponential decay
3. photons::Float64 - Total photon counts
4. command1::Float64 - PID command for controller 1
5. command2::Float64 - PID command for controller 2
6. lifetime::Float64 - Fitted decay constant (τ)
7. concentration::Float64 - Computed ion concentration
8. timestamps::Float64 - Cumulative acquisition time
9. protocol_setpoint::Float64 - Effective protocol setpoint used for control
10. i::UInt32 - Frame counter
"""
function start_playback(
        ch::Channel{Tuple{Vector{Float64},Vector{Float64},Float64,Float64,Float64,Float64,Float64,Float64,Float64,UInt32}},
        running::Threads.Atomic{Bool},
        layout::Dict{Symbol, Any},
        controller::Dict{Symbol, Any};
        initial_guess::Vector{Float64} = [3.0, 0.0, 5.0e-5],
        protocol::Union{Nothing, Dict{Symbol, Any}, Observables.AbstractObservable} = nothing,
    paused::Union{Nothing, Threads.Atomic{Bool}} = nothing,
        dt::Float64 = 0.0000001,
        use_partial_fit::Bool = true,
        target_frequency::Float64 = 60.0
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
        params = copy(initial_guess)
        full_fit_params = copy(initial_guess)
        n = UInt32(0)
        first_fit_pending = true
        partial_fit_period = 10
        partial_fit_enabled = use_partial_fit && length(initial_guess) == 3

        if use_partial_fit && !partial_fit_enabled
            @warn "Partial fit mode is only supported for 3-parameter playback fits; falling back to full fits."
        end

        # PID state for lifetime control
        fallback_setpoint_ns = 4.0
        I_error = 0.0
        old_error = 0.0
        D_error = 0.0
        pid_prev_smooth_lifetime = NaN
        pid_prev_raw_lifetime = NaN
        pid_scale_est = 1.0e-6

        target_period_ns = round(Int, 1e9 / target_frequency)
        next_analysis_ns = time_ns()

        while running[]
            if paused !== nothing && paused[]
                next_analysis_ns = time_ns() + target_period_ns
                sleep(min(dt, 0.02))
                continue
            end

            now_ns = time_ns()
            if now_ns < next_analysis_ns
                remaining_s = (next_analysis_ns - now_ns) / 1e9
                sleep(min(dt, remaining_s))
                continue
            end

            # Keep a fixed 60 Hz schedule when possible; if we are late, restart from now.
            next_analysis_ns += target_period_ns
            if next_analysis_ns < now_ns
                next_analysis_ns = now_ns + target_period_ns
            end

            filepath = filepaths[mod1(n+1, nb_files)]

            vector, histogram_resolution, frame_time = open_SDT_file(filepath)

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

            # Fit every processed frame/file.
            fit_index = Int(n) + 1
            use_full_fit = !partial_fit_enabled || fit_index == 1 || mod1(fit_index, partial_fit_period) == 1

            if use_full_fit
                params_raw, data = vec_to_lifetime(Float64.(final_vector); guess=full_fit_params, histogram_resolution=histogram_resolution, first_fit=first_fit_pending)
                first_fit_pending = false

                if !isnan(params_raw[1])
                    params = params_raw
                    full_fit_params = params_raw
                end
            else
                fixed_parameters = Float64[NaN, NaN, full_fit_params[3]]
                params_raw, data = vec_to_lifetime(Float64.(final_vector); guess=params, histogram_resolution=histogram_resolution, fixed_parameters=fixed_parameters, first_fit=false)

                if !isnan(params_raw[1])
                    params = params_raw
                end
            end

            histogram = data[2]
            photons = sum(histogram)
            fit = conv_irf_data(data[1], Tuple(params), irf; histogram_resolution=histogram_resolution)*photons
            lifetime = params[1]
            concentration = (9.5 / lifetime - 1)/0.025
            timestamps += frame_time
            n += 1

            current_protocol = resolve_protocol_config(protocol)
            setpoint_ns = if current_protocol === nothing || !Bool(get(current_protocol, :active, false))
                fallback_setpoint_ns
            else
                protocol_setpoint_at_timestamp(current_protocol, timestamps)
            end

            smooth_level = layout_smoothing_level(layout)
            lifetime_for_pid, pid_prev_smooth_lifetime, pid_prev_raw_lifetime, pid_scale_est =
                update_pid_lifetime_kalman(
                    lifetime,
                    pid_prev_smooth_lifetime,
                    pid_prev_raw_lifetime,
                    pid_scale_est,
                    smooth_level
                )

            command1 = NaN
            command2 = NaN

            if !isnan(setpoint_ns)
                # PID terms are shared from one lifetime error for both controllers.
                dt_sample = max(Float64(frame_time), eps(Float64))
                P_error = setpoint_ns - lifetime_for_pid
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
            else
                I_error = 0.0
                old_error = 0.0
                D_error = 0.0
            end

            # Send results; handle closed channel gracefully
            if isopen(ch) && running[]
                try
                    put!(ch, (histogram, fit, photons, command1, command2, lifetime, concentration, timestamps, setpoint_ns, n))
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
        initial_guess::Vector{Float64} = [3.0, 0.5, 0.5, 0.0, 5.0e-5],
        protocol::Union{Nothing, Dict{Symbol, Any}, Observables.AbstractObservable} = nothing,
        paused::Union{Nothing, Threads.Atomic{Bool}} = nothing,
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

        params = copy(initial_guess)
        n = UInt32(0)
        first_fit_pending = true

        fallback_setpoint_ns = 4.0
        I_error = 0.0
        old_error = 0.0
        D_error = 0.0
        pid_prev_smooth_lifetime = NaN
        pid_prev_raw_lifetime = NaN
        pid_scale_est = 1.0e-6

        last_processed_filepath = ""
        last_dir_mtime = 0.0
        known_sdt_files = String[]
        next_scan_at = 0.0

        # Build initial file list once.
        for entry in readdir(path; join=true)
            if isfile(entry) && endswith(lowercase(entry), ".sdt")
                push!(known_sdt_files, entry)
            end
        end

        if isempty(known_sdt_files)
            @warn "No .sdt files found yet in real-time folder" path=path
        end

        while running[]
            if paused !== nothing && paused[]
                sleep(min(dt, 0.05))
                continue
            end

            now_t = time()
            if now_t < next_scan_at
                sleep(min(dt, max(1e-4, next_scan_at - now_t)))
                continue
            end
            next_scan_at = now_t + poll_interval_s

            dir_stat = try
                stat(path)
            catch
                nothing
            end

            if dir_stat === nothing
                sleep(poll_interval_s)
                continue
            end

            current_dir_mtime = dir_stat.mtime

            if current_dir_mtime != last_dir_mtime
                last_dir_mtime = current_dir_mtime

                known_sdt_files = String[]
                for entry in readdir(path; join=true)
                    if isfile(entry) && endswith(lowercase(entry), ".sdt")
                        push!(known_sdt_files, entry)
                    end
                end
            end

            if isempty(known_sdt_files)
                sleep(poll_interval_s)
                continue
            end

            latest_filepath = known_sdt_files[1]
            latest_mtime = try
                stat(latest_filepath).mtime
            catch
                0.0
            end

            for f in known_sdt_files
                mt = try
                    stat(f).mtime
                catch
                    -1.0
                end
                if mt > latest_mtime
                    latest_mtime = mt
                    latest_filepath = f
                end
            end

            if latest_filepath == last_processed_filepath
                sleep(poll_interval_s)
                continue
            end

            filepath = latest_filepath
            vector, histogram_resolution, frame_time = open_SDT_file(filepath)
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

            # Fit every processed frame/file.
            params_raw, data = vec_to_lifetime(Float64.(final_vector); guess=params, histogram_resolution=histogram_resolution, first_fit=first_fit_pending)
            first_fit_pending = false

            if !isnan(params_raw[1])
                params = params_raw
            end

            histogram = data[2]
            photons = sum(histogram)
            fit = conv_irf_data(data[1], Tuple(params), irf; histogram_resolution=histogram_resolution) * photons
            lifetime = params[1]
            concentration = (9.5 / lifetime - 1) / 0.025
            timestamps += frame_time
            n += 1

            current_protocol = resolve_protocol_config(protocol)
            setpoint_ns = if current_protocol === nothing || !Bool(get(current_protocol, :active, false))
                fallback_setpoint_ns
            else
                protocol_setpoint_at_timestamp(current_protocol, timestamps)
            end

            smooth_level = layout_smoothing_level(layout)
            lifetime_for_pid, pid_prev_smooth_lifetime, pid_prev_raw_lifetime, pid_scale_est =
                update_pid_lifetime_kalman(
                    lifetime,
                    pid_prev_smooth_lifetime,
                    pid_prev_raw_lifetime,
                    pid_scale_est,
                    smooth_level
                )

            command1 = NaN
            command2 = NaN

            if !isnan(setpoint_ns)
                dt_sample = max(Float64(frame_time), eps(Float64))
                P_error = setpoint_ns - lifetime_for_pid
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
            else
                I_error = 0.0
                old_error = 0.0
                D_error = 0.0
            end

            if isopen(ch) && running[]
                try
                    put!(ch, (histogram, fit, photons, command1, command2, lifetime, concentration, timestamps, setpoint_ns, n))
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

"""
    start_save(ch::Channel, running::Threads.Atomic{Bool}, layout::Dict;
                                   dt::Float64=0.05)

Worker task for Save mode.

Processes all `.sdt` files in `DATA_ROOT_PATH` once, without publishing
intermediate GUI updates. After the full folder is processed, it pushes all
results to the channel so the UI can display the complete run.
"""
function start_save(
        ch::Channel{Tuple{Vector{Float64},Vector{Float64},Float64,Float64,Float64,Float64,Float64,Float64,Float64,UInt32}},
        running::Threads.Atomic{Bool},
        layout::Dict{Symbol, Any},
        controller::Dict{Symbol, Any};
        initial_guess::Vector{Float64} = [3.0, 0.0, 5.0e-5],
        protocol::Union{Nothing, Dict{Symbol, Any}, Observables.AbstractObservable} = nothing,
    paused::Union{Nothing, Threads.Atomic{Bool}} = nothing,
        dt::Float64 = 0.0000001,
    use_partial_fit::Bool = true,
    progress_cb::Union{Nothing, Function} = nothing
    )
    try
        @info "Save worker started on thread $(threadid())"

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

        sum_vector = zeros(Float64, DEFAULT_HISTOGRAM_RESOLUTION)
        last_bin = 1
        current_count = 0

        params = copy(initial_guess)
        full_fit_params = copy(initial_guess)
        n = UInt32(0)
        first_fit_pending = true
        partial_fit_period = 10
        partial_fit_enabled = use_partial_fit && length(initial_guess) == 3

        if use_partial_fit && !partial_fit_enabled
            @warn "Partial fit mode is only supported for 3-parameter save fits; falling back to full fits."
        end

        fallback_setpoint_ns = 4.0
        I_error = 0.0
        old_error = 0.0
        D_error = 0.0
        pid_prev_smooth_lifetime = NaN
        pid_prev_raw_lifetime = NaN
        pid_scale_est = 1.0e-6

        buffered_samples = Tuple{Vector{Float64},Vector{Float64},Float64,Float64,Float64,Float64,Float64,Float64,Float64,UInt32}[]
        last_progress_pct = -1

        if progress_cb !== nothing
            try
                progress_cb(0)
                last_progress_pct = 0
            catch e
                @warn "Save progress callback failed" error=string(e)
                progress_cb = nothing
            end
        end

        for filepath in filepaths
            if !running[]
                break
            end

            while running[] && paused !== nothing && paused[]
                sleep(min(dt, 0.05))
            end

            if !running[]
                break
            end

            vector, histogram_resolution, frame_time = open_SDT_file(filepath)

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

            fit_index = Int(n) + 1
            use_full_fit = !partial_fit_enabled || fit_index == 1 || mod1(fit_index, partial_fit_period) == 1

            if use_full_fit
                params_raw, data = vec_to_lifetime(Float64.(final_vector); guess=full_fit_params, histogram_resolution=histogram_resolution, first_fit=first_fit_pending)
                first_fit_pending = false

                if !isnan(params_raw[1])
                    params = params_raw
                    full_fit_params = params_raw
                end
            else
                fixed_parameters = Float64[NaN, NaN, full_fit_params[3]]
                params_raw, data = vec_to_lifetime(Float64.(final_vector); guess=params, histogram_resolution=histogram_resolution, fixed_parameters=fixed_parameters, first_fit=false)

                if !isnan(params_raw[1])
                    params = params_raw
                end
            end

            histogram = data[2]
            photons = sum(histogram)
            fit = conv_irf_data(data[1], Tuple(params), irf; histogram_resolution=histogram_resolution)*photons
            lifetime = params[1]
            concentration = (9.5 / lifetime - 1)/0.025
            timestamps += frame_time
            n += 1

            current_protocol = resolve_protocol_config(protocol)
            setpoint_ns = if current_protocol === nothing || !Bool(get(current_protocol, :active, false))
                fallback_setpoint_ns
            else
                protocol_setpoint_at_timestamp(current_protocol, timestamps)
            end

            smooth_level = layout_smoothing_level(layout)
            lifetime_for_pid, pid_prev_smooth_lifetime, pid_prev_raw_lifetime, pid_scale_est =
                update_pid_lifetime_kalman(
                    lifetime,
                    pid_prev_smooth_lifetime,
                    pid_prev_raw_lifetime,
                    pid_scale_est,
                    smooth_level
                )

            command1 = NaN
            command2 = NaN

            if !isnan(setpoint_ns)
                dt_sample = max(Float64(frame_time), eps(Float64))
                P_error = setpoint_ns - lifetime_for_pid
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
            else
                I_error = 0.0
                old_error = 0.0
                D_error = 0.0
            end

            push!(buffered_samples, (histogram, fit, photons, command1, command2, lifetime, concentration, timestamps, setpoint_ns, n))

            if progress_cb !== nothing
                progress_pct = clamp(floor(Int, (Int(n) * 100) / nb_files), 0, 100)
                if progress_pct > last_progress_pct
                    for pct in (last_progress_pct + 1):progress_pct
                        try
                            progress_cb(pct)
                        catch e
                            @warn "Save progress callback failed" error=string(e)
                            progress_cb = nothing
                            break
                        end
                    end
                    last_progress_pct = progress_pct
                end
            end

            if dt > 0.0
                sleep(dt)
            end
        end

        if running[] && isopen(ch)
            @info "Save mode completed processing; publishing buffered samples" count=length(buffered_samples)
            for sample in buffered_samples
                if !running[] || !isopen(ch)
                    break
                end

                while running[] && paused !== nothing && paused[]
                    sleep(min(dt, 0.05))
                end

                if !running[] || !isopen(ch)
                    break
                end

                try
                    put!(ch, sample)
                catch e
                    if isa(e, InvalidStateException)
                        break
                    else
                        rethrow()
                    end
                end
            end
        end
    catch e
        @error "Save worker error" exception=e
        rethrow()
    finally
        running[] = false
        try
            close(ch)
        catch
            # Ignore if already closed
        end
        @info "Save worker finished"
    end

    return nothing
end
