"""
functions.jl - File I/O and data acquisition worker

Provides:
- Serial port enumeration (list_ports)
- SDT file format reader (open_SDT_file)
- Test data worker (worker_test)
"""

using LibSerialPort
using ZipFile

# ============================================================================
# SERIAL PORT ENUMERATION
# ============================================================================

"""
    list_ports() -> Vector{String}

Enumerate available serial ports on the system.

# Returns
Sorted vector of port paths like ["/dev/ttyUSB0", ...]

# Supports
- Windows: COM ports via WMI PowerShell query
- macOS: /dev/tty.usbserial* and cu.usbserial*
- Linux: /dev/ttyUSB*, /dev/ttyACM*, /dev/serial/by-id/

# Notes
Port enumeration can be slow; consider caching results if called frequently.
"""
function list_ports()::Vector{String}
    ports = String[]
    
    if Sys.iswindows()
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
            @warn "Failed to query Windows COM ports via PowerShell" exception=e
        end

    else  # Unix-like: macOS, Linux
        devdir = "/dev"
        if isdir(devdir)
            files = readdir(devdir)
            
            if Sys.islinux()
                # Try /dev/serial/by-id for stable names
                byid = joinpath("/dev", "serial", "by-id")
                if isdir(byid)
                    for f in readdir(byid)
                        push!(ports, joinpath(byid, f))
                        try
                            target = realpath(joinpath(byid, f))
                            push!(ports, target)
                        catch
                        end
                    end
                end
                
                # Also add common pattern devices
                for f in files
                    if occursin(r"^ttyUSB", f) || occursin(r"^ttyACM", f) || occursin(r"^ttyAMA", f)
                        push!(ports, joinpath(devdir, f))
                    end
                end

            elseif Sys.isapple()
                # macOS: tty.* and cu.* prefixes with "usb" in name
                for f in files
                    if (startswith(f, "tty.") || startswith(f, "cu.")) && 
                       occursin("usb", lowercase(f))
                        push!(ports, joinpath(devdir, f))
                    end
                end

            else
                # Generic fallback
                for f in files
                    if startswith(f, "tty") || startswith(f, "cu.")
                        push!(ports, joinpath(devdir, f))
                    end
                end
            end
        else
            @warn "/dev directory not found; cannot enumerate Unix devices"
        end
    end

    return sort(unique(ports))
end

# ============================================================================
# SDT FILE READER
# ============================================================================

"""
    reshape_to_vec(file::Vector{UInt16}, length::Int) -> Vector{UInt16}

Reshape file contents into histogram by summing along time dimension.

# Arguments
- `file`: Raw histogram data
- `length`: Histogram resolution (# of time channels)

# Returns
1D histogram vector summing across all detectors
"""
function reshape_to_vec(file::Vector{UInt16}, length::Int)::Vector{UInt16}
    @assert size(file, 1) % length == 0 "File length not divisible by histogram resolution"
    return vec(sum(reshape(file, (length, :)), dims=2))
end

"""
    open_SDT_file(filepath::AbstractString) -> (Vector{UInt16}, Int, Float32)

Read Becker & Hickl SDT file format.

# Returns
Tuple of:
- `histogram`: UInt16 vector of photon counts per time channel
- `histogram_resolution`: number of time channels
- `time`: acquisition time in seconds

# Format
Parses low-level SDT binary format including optional compression.
See: Becker & Hickl SPC-Monitor documentation.

# Throws
- Various IO errors if file corrupted or invalid
"""
function open_SDT_file(filepath::AbstractString)
    open(filepath, "r") do io
        # Read header at offset 14
        seek(io, 14)
        header = read!(io, Vector{UInt8}(undef, 12))

        # Extract histogram resolution from header
        seek(io, header[12]*0x100 + header[11] + 82)
        infos = read!(io, Vector{UInt8}(undef, 2))
        histogram_resolution = infos[2]*0x100 + infos[1]
    
        # Extract time bin width
        seek(io, header[12]*0x100 + header[11] + 215)
        infos_2 = read!(io, Vector{UInt8}(undef, 4))
        time = reinterpret(Float32, infos_2)[1]

        # Check data format: uncompressed (512, 128) or compressed
        if (header[8]*0x100 + header[7]) in (512, 128)
            # Uncompressed: read raw UInt16 data
            seek(io, header[2]*0x100 + header[1] + 22)
            vector = read(io)
            n = div(length(vector), 2)
            new_vector = reinterpret(UInt16, vector[1:2*n])
            return new_vector, histogram_resolution, time
        else
            # Compressed: extract from ZIP archive embedded in file
            seek(io, header[2]*0x100 + header[1] + 2)
            file_info = read!(io, Vector{UInt8}(undef, 20))
            
            shift_1 = file_info[8]*0x1000000 + file_info[7]*0x10000 + 
                      file_info[6]*0x100 + file_info[5] -
                      (file_info[2]*0x100 + file_info[1])
            shift_2 = file_info[20]*0x1000000 + file_info[19]*0x10000 + 
                      file_info[18]*0x100 + file_info[17]

            buffer = IOBuffer(read(io, shift_1))
            zip_file = first(ZipFile.Reader(buffer).files)

            file_data = Vector{UInt8}(undef, shift_2)
            read!(zip_file, file_data)

            vector = reshape_to_vec(reinterpret(UInt16, file_data), histogram_resolution)
            return vector, histogram_resolution, time
        end
    end
end

# ============================================================================
# TEST DATA WORKER
# ============================================================================

"""
    worker_test(
        ch::Channel{Tuple{Vector{Float64},Vector{Float64},Float64,Float64,Float64,Float64,UInt32}},
        running::Threads.Atomic{Bool},
        num_context::NumericContext;
        dt::Float64=0.05
    )

Test data acquisition worker: reads SDT files in a loop, performs lifetime fitting,
and sends results through channel to consumer.

# Arguments
- `ch`: Output channel for (histogram, fit, photons, lifetime, concentration, timestamps, i)
- `running`: Atomic flag controlling worker lifetime
- `num_context`: Numeric context with IRF and FFT plans
- `dt`: Sleep duration between acquisitions [seconds]

# Notes
**HARDCODED PATH**: This is test code. Change `test_data_path` for your system.

The worker:
1. Enumerates SDT test files from disk
2. Cycles through them repeatedly
3. Performs MLE lifetime fitting on each
4. Sends results via channel
5. Closes channel and exits when `running[]` becomes false

# Thread Safety
Must be spawned on a single dedicated thread. Does not modify AppRun directly.
"""
function worker_test(
    ch::Channel{Tuple{Vector{Float64},Vector{Float64},Float64,Float64,Float64,Float64,UInt32}},
    running::Threads.Atomic{Bool},
    num_context::NumericContext;
    dt::Float64=0.05
)
    try
        @info "Worker test started on thread $(Threads.threadid())"
        
        # TODO: Change this path to your test data directory
        test_data_path = "/Users/eliasouellet-oviedo/Documents/Stage2/Codes/test"
        
        if !isdir(test_data_path)
            @error "Test data directory not found: $test_data_path"
            close(ch)
            return
        end
        
        all_files = readdir(test_data_path)
        files = filter(f -> occursin(".sdt", f), all_files)
        
        if isempty(files)
            @error "No .sdt files found in $test_data_path"
            close(ch)
            return
        end
        
        @info "Found $(length(files)) .sdt test files"
        
        nb_files = length(files)
        timestamps = 0.0
        params = [5.0, 0.0, 5.0e-5]  # Initial guess
        i = UInt32(0)

        while running[]
            # Cycle through test files
            file_idx = mod1(Int(i + 1), nb_files)
            file = files[file_idx]
            filepath = joinpath(test_data_path, file)
            
            try
                vector, histogram_resolution, time = open_SDT_file(filepath)
                
                # Fit lifetime from histogram
                params_raw, data = vec_to_lifetime(
                    Float64.(vector), 
                    num_context;
                    histogram_resolution=histogram_resolution
                )
                
                # Use fitted parameters if valid
                if !isnan(params_raw[1])
                    params = params_raw
                end
                
                # Prepare output data
                histogram = data[2]
                photons = sum(histogram)
                fit = conv_irf_data(data[1], Tuple(params), num_context; 
                                   histogram_resolution=histogram_resolution) * photons
                lifetime = params[1]
                concentration = params[2]
                timestamps += time
                i += 1
                
                # Send to consumer
                put!(ch, (histogram, fit, photons, lifetime, concentration, timestamps, i))
                
            catch e
                @warn "Error processing file $file" exception=e
            end
            
            sleep(dt)
        end
        
        @info "Worker test shutting down (running flag = false)"
        
    catch e
        @error "Error in worker_test" exception=e
        rethrow()
    finally
        # Close channel to signal consumer
        try
            close(ch)
        catch _
            # Already closed, ignore
        end
        @info "Worker test finished"
    end
    
    return nothing
end
