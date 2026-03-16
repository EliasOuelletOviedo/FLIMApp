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
using Base.Threads

# =============================================================================
# SERIAL PORT ENUMERATION
# =============================================================================

"""
    list_ports()::Vector{String}

Return a sorted, de-duplicated list of available serial device paths.

Platform-specific behavior:
- **Windows**: Queries WMI for COM ports via PowerShell
- **macOS**: Scans /dev for USB tty devices
- **Linux**: Checks /dev/serial/by-id and standard tty/ttyUSB devices

Returns:
- Vector of device path strings (e.g., `/dev/ttyUSB0`, `COM3`)
- Empty vector if no devices found
"""
function list_ports()::Vector{String}
    ports = String[]
    
    if Sys.iswindows()
        _enumerate_windows_ports!(ports)
    else
        _enumerate_unix_ports!(ports)
    end
    
    return sort(unique(ports))
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
    test(ch::Channel, running::Threads.Atomic{Bool}, layout::Dict; dt::Float64=0.05)

Worker task that processes data files and streams results to GUI.

Loops over .sdt files in DATA_ROOT_PATH, processes each through
lifetime fitting, and sends results via channel to the consumer task.

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
4. reserved::Float64 - Placeholder for future use
5. lifetime::Float64 - Fitted decay constant (τ)
6. concentration::Float64 - Computed ion concentration
7. timestamps::Float64 - Cumulative acquisition time
8. i::UInt32 - Frame counter
"""
function test(
        ch::Channel{Tuple{Vector{Float64},Vector{Float64},Float64,Float64,Float64,Float64,Float64,UInt32}},
        running::Threads.Atomic{Bool},
        layout::Dict{Symbol, Any};
        dt::Float64 = 0.0001
    )
    try
        @info "Worker task started on thread $(threadid())"
        
        # Check if IRF is loaded (required for lifetime fitting)
        @info "Checking IRF status: irf=$(irf !== nothing), tcspc_window_size=$(tcspc_window_size !== nothing)"
        if irf === nothing || tcspc_window_size === nothing
            @error "IRF not loaded - cannot start data processing. Please load an IRF file first."
            @error "IRF status: irf=$(irf !== nothing), tcspc_window_size=$(tcspc_window_size !== nothing)"
            return
        end
        
        # Initialize file processing state
        path = DATA_ROOT_PATH
        all_files = readdir(path)
        files = filter(f -> occursin(".sdt", f), all_files)
        nb_files = length(files)
        
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
        params = [5.0, 0.0, 5.0e-5]
        i = UInt32(0)

        while running[]
            # Get next file in circular order
            file = files[mod1(i+1, nb_files)]
            filepath = joinpath(path, file)
            vector, histogram_resolution, time = open_SDT_file(filepath)

            # Store in circular buffer
            pos = mod1(i+1, n_vectors)
            vectors[pos, 1:histogram_resolution] .= vector

            # Apply binning from layout with sliding window optimization
            bin = get(layout, :binning, 1)

            if bin != last_bin
                # Recalculate when binning changes
                effective_bin = min(bin, current_count + 1)
                idxs = mod1.(pos .- (0:effective_bin-1), n_vectors)
                sum_vector .= @views sum(vectors[idxs, 1:histogram_resolution]; dims=1)[1, :]
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

            # Fit lifetime to data
            params_raw, data = vec_to_lifetime(Float64.(final_vector); guess=params, histogram_resolution=histogram_resolution)

            if !isnan(params_raw[1])
                params = params_raw
            end

            histogram = data[2]
            photons = sum(histogram)
            fit = conv_irf_data(data[1], Tuple(params), irf; histogram_resolution=histogram_resolution)*photons
            lifetime = params[1]
            concentration = (9.5 / lifetime - 1)/0.025
            timestamps += time
            i += 1

            # Normalize histogram to standard size
            if length(histogram) < DEFAULT_HISTOGRAM_RESOLUTION
                histogram = vcat(histogram, zeros(DEFAULT_HISTOGRAM_RESOLUTION - length(histogram)))
            elseif length(histogram) > DEFAULT_HISTOGRAM_RESOLUTION
                histogram = histogram[1:DEFAULT_HISTOGRAM_RESOLUTION]
            end
            
            if length(fit) < DEFAULT_HISTOGRAM_RESOLUTION
                fit = vcat(fit, zeros(DEFAULT_HISTOGRAM_RESOLUTION - length(fit)))
            elseif length(fit) > DEFAULT_HISTOGRAM_RESOLUTION
                fit = fit[1:DEFAULT_HISTOGRAM_RESOLUTION]
            end

            # Send results; handle closed channel gracefully
            if isopen(ch) && running[]
                try
                    put!(ch, (histogram, fit, photons, photons, lifetime, concentration, timestamps, i))
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
        @error "Worker task error" exception=e
        rethrow()
    finally
        try
            close(ch)
        catch
            # Ignore if already closed
        end
        @info "Worker task finished"
    end
    
    return nothing
end
