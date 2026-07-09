#!/usr/bin/env julia

using Statistics
using Printf
using FFTW
using Observables

const ROOT = normpath(joinpath(@__DIR__, ".."))

include(joinpath(ROOT, "src", "config.jl"))
include(joinpath(ROOT, "src", "lifetime_analysis2.jl"))
include(joinpath(ROOT, "src", "data_processing.jl"))

function percentile(values::Vector{Float64}, p::Float64)
    isempty(values) && return NaN
    sorted = sort(values)
    idx = clamp(ceil(Int, p * length(sorted)), 1, length(sorted))
    return sorted[idx]
end

function init_numeric_context!()
    global irf = get_irf()
    global irf_bin_size = get_irf_bin_size()
    global tcspc_window_size = round(irf[end, 1] + irf[2, 1], sigdigits=4)

    n = size(irf, 1)
    global fft_plan = plan_fft(zeros(Float64, n))
    global ifft_plan = plan_ifft(zeros(Float64, n))
    global fft_plan_size = n

    println(@sprintf("IRF loaded: size=%s bin=%.6f ns window=%.6f ns", string(size(irf)), irf_bin_size, tcspc_window_size))
end

function resolve_data_files()
    candidates = String[]
    push!(candidates, get_data_root_path())
    push!(candidates, DATA_ROOT_PATH)
    push!(candidates, "/Users/eliasouellet-oviedo/Desktop/test2")
    push!(candidates, "/Users/eliasouellet-oviedo/Desktop/test1")

    for path in unique(candidates)
        if isdir(path)
            files = sort(filter(f -> isfile(f) && endswith(lowercase(f), ".sdt"), readdir(path; join=true)))
            if !isempty(files)
                println("Using data folder: $(path) ($(length(files)) files)")
                return files
            end
        end
    end

    error("No .sdt files found in configured paths.")
end

function run_full_fit_loop(files::Vector{String}; n_files::Int=500)
    n_files = min(n_files, length(files))
    durations = Float64[]
    valid = 0

    params = [3.0, 0.0, 5.0e-5]
    for i in 1:n_files
        vector, histogram_resolution, _ = open_SDT_file(files[i])
        t0 = time_ns()
        tau, _ = vec_to_lifetime(Float64.(vector); guess=params, histogram_resolution=histogram_resolution, first_fit=(i == 1))
        t1 = time_ns()

        push!(durations, (t1 - t0) / 1e6)
        if !isempty(tau) && !isnan(tau[1])
            valid += 1
            params = tau
        end
    end

    return durations, valid
end

function run_mixed_fit_loop(files::Vector{String}; n_files::Int=500, full_every::Int=10)
    n_files = min(n_files, length(files))
    durations = Float64[]
    full_durations = Float64[]
    partial_durations = Float64[]
    valid = 0

    full_params = [3.0, 0.0, 5.0e-5]
    partial_params = [3.0, 0.0, 5.0e-5]

    for i in 1:n_files
        vector, histogram_resolution, _ = open_SDT_file(files[i])
        is_full = (i == 1) || (mod1(i, full_every) == 1)

        t0 = time_ns()
        if is_full
            tau, _ = vec_to_lifetime(Float64.(vector); guess=full_params, histogram_resolution=histogram_resolution, first_fit=(i == 1))
            if !isempty(tau) && !isnan(tau[1])
                valid += 1
                full_params = tau
                partial_params = tau
            end
        else
            fixed = Float64[NaN, NaN, partial_params[3]]
            tau, _ = vec_to_lifetime(Float64.(vector); guess=partial_params, histogram_resolution=histogram_resolution, fixed_parameters=fixed, first_fit=false)
            if !isempty(tau) && !isnan(tau[1])
                valid += 1
                partial_params[1] = tau[1]
                partial_params[2] = tau[2]
                partial_params[3] = tau[3]
            end
        end
        t1 = time_ns()

        elapsed_ms = (t1 - t0) / 1e6
        push!(durations, elapsed_ms)
        if is_full
            push!(full_durations, elapsed_ms)
        else
            push!(partial_durations, elapsed_ms)
        end
    end

    return durations, full_durations, partial_durations, valid
end

function summary(name::String, samples::Vector{Float64})
    println(@sprintf("%-18s avg=%8.3f ms  p95=%8.3f ms  max=%8.3f ms  hz=%.2f",
        name,
        mean(samples),
        percentile(samples, 0.95),
        maximum(samples),
        1000 / mean(samples)))
end

function main()
    n_files = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : 500
    full_every = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 10

    println("=== Full vs Mixed Fit Comparison ===")
    println("Julia version: $(VERSION)")
    println(@sprintf("full_every=%d  target_files=%d", full_every, n_files))

    init_numeric_context!()
    files = resolve_data_files()

    # Warmup on a few files to reduce compilation noise.
    warmup_n = min(20, length(files))
    warmup_params = [3.0, 0.0, 5.0e-5]
    for i in 1:warmup_n
        vector, histogram_resolution, _ = open_SDT_file(files[i])
        _ = vec_to_lifetime(Float64.(vector); guess=warmup_params, histogram_resolution=histogram_resolution, first_fit=(i == 1))
    end

    full_durations, full_valid = run_full_fit_loop(files; n_files=n_files)
    mixed_durations, mixed_full_durations, mixed_partial_durations, mixed_valid = run_mixed_fit_loop(files; n_files=n_files, full_every=full_every)

    println("\n=== Full Fit Every File ===")
    summary("full loop", full_durations)
    println(@sprintf("valid fits=%d/%d", full_valid, length(full_durations)))

    println("\n=== Mixed Strategy ===")
    summary("mixed loop", mixed_durations)
    summary("mixed full", mixed_full_durations)
    summary("mixed part", mixed_partial_durations)
    println(@sprintf("valid fits=%d/%d", mixed_valid, length(mixed_durations)))

    full_avg = mean(full_durations)
    mixed_avg = mean(mixed_durations)
    speedup = full_avg / mixed_avg
    gain_pct = 100 * (full_avg - mixed_avg) / full_avg

    println("\n=== Comparison ===")
    println(@sprintf("full avg   = %.3f ms (%.2f Hz)", full_avg, 1000 / full_avg))
    println(@sprintf("mixed avg  = %.3f ms (%.2f Hz)", mixed_avg, 1000 / mixed_avg))
    println(@sprintf("speedup    = %.3fx", speedup))
    println(@sprintf("gain       = %.2f%%", gain_pct))

    if mixed_avg < full_avg
        println("Mixed strategy is faster.")
    else
        println("Full-fit strategy is faster or equal on this dataset.")
    end
end

main()
