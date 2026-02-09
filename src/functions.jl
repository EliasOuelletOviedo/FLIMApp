include("vec_to_lifetime.jl")

function list_ports()
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
            @warn "Impossible d'interroger PowerShell: $e"
        end

    else
        devdir = "/dev"

        if isdir(devdir)
            files = readdir(devdir)
            
            if Sys.islinux()
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
                
                for f in files
                    if occursin(r"^ttyUSB", f) || occursin(r"^ttyACM", f) || occursin(r"^ttyAMA", f)
                        push!(ports, joinpath(devdir, f))
                    end
                end

            elseif Sys.isapple()
                for f in files
                    if (startswith(f, "tty.") || startswith(f, "cu.")) && occursin("usb", lowercase(f))
                        push!(ports, joinpath(devdir, f))
                    end
                end

            else
                for f in files
                    if startswith(f, "tty") || startswith(f, "cu.")
                        push!(ports, joinpath(devdir, f))
                    end
                end
            end
        else
            @warn "/dev non trouvé ; impossible de lister les périphériques Unix"
        end
    end

    return sort(unique(ports))
end

function reshape_to_vec(file, length)
    return sum(reshape(file, (length, :)), dims = 2)[:,1]
end

function open_SDT_file(filepath)
    open(filepath, "r") do io
        seek(io, 14)
        header = read!(io, Vector{UInt8}(undef, 12))

        seek(io, header[12]*0x100 + header[11] + 82)
        infos = read!(io, Vector{UInt8}(undef, 2))
        histogram_resolution = infos[2]*0x100 + infos[1]
    
        seek(io, header[12]*0x100 + header[11] + 215)
        infos_2 = read!(io, Vector{UInt8}(undef, 4))
        time = reinterpret(Float32, infos_2)[1]

        if (header[8]*0x100 + header[7]) in (512, 128)
            seek(io, header[2]*0x100 + header[1] + 22)
            vector = read(io)  # lit tout le reste du fichier
            # Conversion rapide en UInt16 sans boucle
            n = div(length(vector), 2)
            new_vector = reinterpret(UInt16, vector[1:2*n])
            return new_vector, histogram_resolution, time
        else
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
            return vector, histogram_resolution, time
        end
    end
end

function test(ch::Channel{Tuple{Float64,Float64,UInt32}}, running::Threads.Atomic{Bool}; dt=0.05)
    try
        @info "Worker Test started on thread $(threadid())"
        t = 0.0
        path = "/Users/eliasouellet-oviedo/Documents/Stage2/Codes/test"
        all_files = readdir(path)
        files = filter(f -> occursin(".sdt", f), all_files)
        nb_files = length(files)
        cum_time = 0.0
        vectors = zeros(100, 256)
        n_vectors = size(vectors, 1)

        params = [5.0, 0, 5.0e-5]

        i = UInt32(1)

        while running[]   # produit tant que flag true
            file = files[mod1(i, nb_files)]
            filepath = joinpath(path, file)
            vector, histogram_resolution, time = open_SDT_file(filepath)
            cum_time += time
            # vector2 = reshape(vector, (1, :))

            # if i == 1
            #     vectors[:, 1:histogram_resolution] .= reshape(vector, (1, :))
            # else
            #     vectors[1:end-1, 1:histogram_resolution] .= vectors[2:end, 1:histogram_resolution]
            #     vectors[end, 1:histogram_resolution] .= vector
            # end

            # idx_start = max(1, n_vectors - 5 + 1)
            # final_vector = @views sum(vectors[idx_start:end, 1:histogram_resolution]; dims=1)[1, :] / 5

            params_raw, data = vec_to_lifetime(Float64.(vector), guess=params, histogram_resolution=histogram_resolution)

            if !isnan(params_raw[1])
                params = params_raw
            end

            put!(ch, (cum_time, params_raw[1], i))
            i += 1
            sleep(0.0001)
        end
    catch e
        @error "Erreur dans Test" e
        rethrow()
    finally
        # ferme proprement le channel pour débloquer le consumer (s'il est encore en attente)
        try
            close(ch)
        catch _ # ignore si déjà fermé
        end
        @info "Worker Test finished (closed channel)"
    end
    return nothing
end

ports = list_ports()

if isempty(ports)
    println("Aucun port détecté.")
else
    println("Ports trouvés :")
    for p in ports
        println(" - ", p)
    end
end