module IOUtils

export get_path_from_file

using NativeFileDialog
using BenchmarkTools

function get_path_from_file(base_dir::AbstractString, label::AbstractString, ui_pick_fn=nothing)::String
    file = joinpath(base_dir, string(label, "_path.txt"))

    if isfile(file)
        path = strip(open(file, "r") do io read(io, String) end)
        if !isempty(path)
            return path
        end
    end

    path = ui_pick_fn()

    if !isempty(path)
        mkpath(dirname(file))
        open(file, "w") do io write(io, path) end
        return path
    end

    return get_path_from_file(base_dir, label, ui_pick_fn)
end

function create_path_file(base_dir::AbstractString, label::AbstractString, ui_pick_fn=nothing)::String
    file = joinpath(base_dir, string(label, "_path.txt"))
    path = ui_pick_fn()

    if !isempty(path)
        mkpath(dirname(file))
        open(file, "w") do io write(io, path) end
        return path
    end

    return strip(open(file, "r") do io read(io, String) end)
end

function reshape_to_vec(arr::AbstractArray, target_len::Integer)::Vector{Float64}
    v = vec(Array{Float64}(arr))
    n = length(v)

    if n == target_len
        return v
    elseif n < target_len
        out = zeros(Float64, target_len)
        out[1:n] = v
        return out
    else
        return v[1:target_len]
    end
end

function open_sdt_file(filepath::AbstractString)
    read_u16_le(bytes::Vector{UInt8}, lowidx::Integer) = Int(bytes[lowidx]) + (Int(bytes[lowidx+1]) << 8)
    read_u32_le(bytes::Vector{UInt8}, lowidx::Integer) =
        Int(bytes[lowidx]) + (Int(bytes[lowidx+1]) << 8) + (Int(bytes[lowidx+2]) << 16) + (Int(bytes[lowidx+3]) << 24)

    open(filepath, "r") do io
        seek(io, 14)
        header = read!(io, Vector{UInt8}(undef, 12))

        seek(io, read_u16_le(header, 11) + 82)
        infos = read!(io, Vector{UInt8}(undef, 2))
        histogram_resolution = read_u16_le(infos, 1)

        seek(io, read_u16_le(header, 11) + 215)
        infos_2 = read!(io, Vector{UInt8}(undef, 4))
        time = reinterpret(Float32, infos_2)[1]

        mode_val = read_u16_le(header, 7)
        if mode_val in (512, 128)
            seek(io, read_u16_le(header, 1) + 22)
            bytes = read(io)

            nbytes = length(bytes)
            nwords = div(nbytes, 2)
            if nbytes != 2*nwords
                resize!(bytes, 2*nwords)
            end

            new_vector = reinterpret(UInt16, bytes)
            return new_vector, histogram_resolution, time

        else
            seek(io, read_u16_le(header, 1) + 2)
            file_info = read!(io, Vector{UInt8}(undef, 20))

            shift_1 = read_u32_le(file_info, 5) - read_u16_le(file_info, 1)
            shift_2 = read_u32_le(file_info, 17)

            if shift_1 < 0
                throw(ErrorException("open_sdt_file: negative compressed block length (shift_1): $shift_1"))
            end
            if shift_2 < 0
                throw(ErrorException("open_sdt_file: negative uncompressed length (shift_2): $shift_2"))
            end

            compressed = Vector{UInt8}(undef, shift_1)
            read!(io, compressed)

            buf = IOBuffer(compressed)
            z = ZipFile.Reader(buf)
            try
                file_entry = first(z.files)
                file_data = Vector{UInt8}(undef, shift_2)
                read!(file_entry, file_data)
            finally
                close(z)
            end

            nbytes2 = length(file_data)
            nwords2 = div(nbytes2, 2)
            if nbytes2 != 2*nwords2
                resize!(file_data, 2*nwords2)
            end

            vec16 = reinterpret(UInt16, file_data)
            vector = reshape_to_vec(vec16, histogram_resolution)
            return vector, histogram_resolution, time
        end
    end
end

function add_to_monitor!(list::Vector{String}, filepath::AbstractString; maxlen::Integer=50)
    push!(list, filepath)
    if length(list) > maxlen
        popfirst!(list)
    end
    return list
end

function save_csv_file()
end

function open_csv_file()
end

end