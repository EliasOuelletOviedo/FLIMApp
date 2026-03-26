"""
simulate_realtime_file_arrival.jl

Simule un flux Real Time en transferant des fichiers d'un dossier source
vers un dossier destination, avec un delai entre chaque fichier.

Usage:
    julia --project=. test/simulate_realtime_file_arrival.jl <source_dir> <destination_dir> [delay_seconds]

Exemple:
    julia --project=. test/simulate_realtime_file_arrival.jl /Users/eliasouellet-oviedo/Desktop/test1 /Users/eliasouellet-oviedo/Desktop/test2 0.5
"""

using Printf

function valid_sdt_files(folder_path::AbstractString)::Vector{String}
    if !isdir(folder_path)
        error("Source folder not found: $folder_path")
    end

    entries = readdir(folder_path; join=true)
    return sort(filter(f -> isfile(f) && endswith(lowercase(f), ".sdt"), entries))
end

function simulate_realtime_file_arrival(
    source_dir::AbstractString,
    destination_dir::AbstractString;
    delay_seconds::Float64=0.5
)
    mkpath(destination_dir)

    files = valid_sdt_files(source_dir)
    if isempty(files)
        @warn "No .sdt files found in source directory" source_dir
        return nothing
    end

    @info "Starting real-time file transfer simulation" n_files=length(files) delay_seconds source_dir destination_dir

    for (i, src_path) in enumerate(files)
        filename = basename(src_path)
        dst_path = joinpath(destination_dir, filename)

        mv(src_path, dst_path; force=true)
        @info "Transferred file" index=i total=length(files) file=filename

        if i < length(files)
            sleep(delay_seconds)
        end
    end

    @info "Simulation complete" transferred=length(files)
    return nothing
end

function main(args::Vector{String})
    if length(args) < 2
        println("Usage: julia --project=. test/simulate_realtime_file_arrival.jl <source_dir> <destination_dir> [delay_seconds]")
        return 1
    end

    source_dir = args[1]
    destination_dir = args[2]
    delay_seconds = length(args) >= 3 ? parse(Float64, args[3]) : 0.5

    simulate_realtime_file_arrival(source_dir, destination_dir; delay_seconds=delay_seconds)
    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main(ARGS))
end
