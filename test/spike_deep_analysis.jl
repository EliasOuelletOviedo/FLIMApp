#!/usr/bin/env julia

using Statistics
using Printf

const ROOT = normpath(joinpath(@__DIR__, ".."))

include(joinpath(ROOT, "src", "config.jl"))
include(joinpath(ROOT, "src", "lifetime_analysis.jl"))
include(joinpath(ROOT, "src", "data_processing.jl"))

function percentile(v::Vector{Float64}, p::Float64)
    isempty(v) && return NaN
    s = sort(v)
    idx = clamp(ceil(Int, p * length(s)), 1, length(s))
    return s[idx]
end

function init_context!()
    global irf = get_irf()
    global irf_bin_size = _compute_irf_bin_size(irf)
    global tcspc_window_size = round(irf[end, 1] + irf[2, 1], sigdigits=4)

    n = size(irf, 1)
    global fft_plan = plan_fft(zeros(Float64, n))
    global ifft_plan = plan_ifft(zeros(Float64, n))
    global fft_plan_size = n
end

function resolve_files()
    path = get_data_root_path()
    files = sort(filter(f -> isfile(f) && endswith(lowercase(f), ".sdt"), readdir(path; join=true)))
    isempty(files) && error("No .sdt files in $(path)")
    return path, files
end

function dominant_stage(rec)
    pairs = [
        ("open", rec.open_ms),
        ("binning", rec.bin_ms),
        ("fit", rec.fit_ms),
        ("reconv", rec.reconv_ms),
        ("pid", rec.pid_ms)
    ]
    return first(sort(pairs, by = x -> x[2], rev=true))
end

function profile_worker_spikes(files::Vector{String}; n_iter::Int=500, bin::Int=4)
    layout = get_default_layout()
    layout[:binning] = bin

    n_vectors = 100
    vectors = zeros(Float64, n_vectors, DEFAULT_HISTOGRAM_RESOLUTION)
    sum_vector = zeros(Float64, DEFAULT_HISTOGRAM_RESOLUTION)
    last_bin = 1
    current_count = 0
    params = [3.0, 0.5, 0.5, 0.0, 5.0e-5]

    records = NamedTuple[]

    # Warmup outside measured loop
    warm_file = files[1]
    v, hres, _ = open_SDT_file(warm_file)
    _ = vec_to_lifetime(Float64.(v); guess=params, histogram_resolution=hres)

    for i in 1:n_iter
        filepath = files[mod1(i, length(files))]
        t0 = time_ns()
        vector, histogram_resolution, dt_sample_file = open_SDT_file(filepath)
        t1 = time_ns()

        pos = mod1(i, n_vectors)
        vectors[pos, 1:histogram_resolution] .= vector

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
        final_vector = sum_vector ./ max(bin, 1)
        t2 = time_ns()

        params_raw, data = vec_to_lifetime(Float64.(final_vector); guess=params, histogram_resolution=histogram_resolution)
        t3 = time_ns()

        if !isempty(params_raw) && !isnan(params_raw[1])
            params .= params_raw
        end

        photons = sum(data[2])
        _ = conv_irf_data(data[1], Tuple(params), irf; histogram_resolution=histogram_resolution) * photons
        t4 = time_ns()

        # tiny compute section to keep parity with worker loop
        lifetime = params[1]
        _ = (9.5 / lifetime - 1) / 0.025
        _ = max(Float64(dt_sample_file), eps(Float64))
        t5 = time_ns()

        push!(records, (
            i=i,
            total_ms=(t5-t0)/1e6,
            open_ms=(t1-t0)/1e6,
            bin_ms=(t2-t1)/1e6,
            fit_ms=(t3-t2)/1e6,
            reconv_ms=(t4-t3)/1e6,
            pid_ms=(t5-t4)/1e6
        ))
    end

    totals = [r.total_ms for r in records]
    println("\n=== Worker Spike Analysis ===")
    println(@sprintf("avg=%.3f ms  p95=%.3f ms  p99=%.3f ms  max=%.3f ms", mean(totals), percentile(totals, 0.95), percentile(totals, 0.99), maximum(totals)))

    top = sort(records, by=r -> r.total_ms, rev=true)[1:min(8, length(records))]
    println("Top outliers (iteration, total, dominant_stage):")
    for r in top
        dom = dominant_stage(r)
        println(@sprintf("  i=%4d total=%8.3f ms  dom=%-8s (%7.3f ms)  [open=%.3f bin=%.3f fit=%.3f reconv=%.3f]",
            r.i, r.total_ms, dom[1], dom[2], r.open_ms, r.bin_ms, r.fit_ms, r.reconv_ms))
    end

    return records
end

function profile_realtime_scan_spikes(data_path::String; n_iter::Int=1000)
    scan_ms = Float64[]
    statpick_ms = Float64[]

    for _ in 1:n_iter
        t0 = time_ns()
        all_entries = readdir(data_path; join=true)
        filepaths = sort(filter(f -> isfile(f) && endswith(lowercase(f), ".sdt"), all_entries))
        t1 = time_ns()

        if !isempty(filepaths)
            _ = filepaths[argmax(stat.(filepaths) .|> s -> s.mtime)]
        end
        t2 = time_ns()

        push!(scan_ms, (t1 - t0)/1e6)
        push!(statpick_ms, (t2 - t1)/1e6)
    end

    println("\n=== Real-time Directory Scan Analysis ===")
    println(@sprintf("scan(readdir+filter+sort): avg=%.3f ms p95=%.3f ms p99=%.3f ms max=%.3f ms",
        mean(scan_ms), percentile(scan_ms, 0.95), percentile(scan_ms, 0.99), maximum(scan_ms)))
    println(@sprintf("stat+argmax newest file:   avg=%.3f ms p95=%.3f ms p99=%.3f ms max=%.3f ms",
        mean(statpick_ms), percentile(statpick_ms, 0.95), percentile(statpick_ms, 0.99), maximum(statpick_ms)))
end

function main()
    println("=== FLIM Deep Spike Analysis ===")
    init_context!()
    data_path, files = resolve_files()
    println("Data path: $(data_path)  files=$(length(files))")

    _ = profile_worker_spikes(files; n_iter=500, bin=4)
    profile_realtime_scan_spikes(data_path; n_iter=1200)
end

main()
