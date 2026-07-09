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
    global irf_bin_size = compute_irf_bin_size(irf)
    global tcspc_window_size = round(irf[end, 1] + irf[2, 1], sigdigits=4)

    n = size(irf, 1)
    global fft_plan = plan_fft(zeros(Float64, n))
    global ifft_plan = plan_ifft(zeros(Float64, n))
    global fft_plan_size = n
end

function resolve_files()
    path = get_data_root_path()
    files = sort(filter(f -> isfile(f) && endswith(lowercase(f), ".sdt"), readdir(path; join=true)))
    isempty(files) && error("No .sdt files found in $(path)")
    return path, files
end

function dominant_stage(r)
    pairs = [
        ("open", r.open_ms),
        ("bin", r.bin_ms),
        ("fit", r.fit_ms),
        ("reconv", r.reconv_ms),
        ("scan", r.scan_ms),
        ("stat", r.stat_ms)
    ]
    return first(sort(pairs, by=x->x[2], rev=true))
end

function run_for_duration(files::Vector{String}, data_path::String; seconds::Float64=180.0)
    layout = get_default_layout()
    bin = Int(get(layout, :binning, 1))

    n_vectors = 100
    vectors = zeros(Float64, n_vectors, DEFAULT_HISTOGRAM_RESOLUTION)
    sum_vector = zeros(Float64, DEFAULT_HISTOGRAM_RESOLUTION)
    last_bin = 1
    current_count = 0
    params = [3.0, 0.5, 0.5, 0.0, 5.0e-5]

    fit_every = max(1, Int(get(layout, :fit_every, 2)))
    max_fit_every = max(fit_every, Int(get(layout, :max_fit_every, 10)))
    max_fit_ms = max(1.0, Float64(get(layout, :max_fit_ms, 20.0)))
    fit_cooldown_frames = max(0, Int(get(layout, :fit_cooldown_frames, 6)))
    fit_every_dynamic = fit_every
    skip_fit_frames = 0

    records = NamedTuple[]
    worker_total = Float64[]
    fit_ms_all = Float64[]
    scan_ms_all = Float64[]
    stat_ms_all = Float64[]

    start_t = time()
    i = 0
    last_processed = ""
    last_dir_mtime = 0.0
    known_sdt = copy(files)

    # Warmup before measured interval.
    v, hres, _ = open_SDT_file(files[1])
    _ = vec_to_lifetime(Float64.(v); guess=params, histogram_resolution=hres)

    while (time() - start_t) < seconds
        i += 1

        t0 = time_ns()
        vector, histogram_resolution, _ = open_SDT_file(files[mod1(i, length(files))])
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

        fit_elapsed_ms = 0.0
        if (skip_fit_frames == 0) && ((i % fit_every_dynamic == 0) || i == 1)
            tfit0 = time_ns()
            params_raw, data = vec_to_lifetime(Float64.(final_vector); guess=params, histogram_resolution=histogram_resolution)
            tfit1 = time_ns()
            fit_elapsed_ms = (tfit1 - tfit0) / 1e6

            if fit_elapsed_ms > max_fit_ms
                skip_fit_frames = fit_cooldown_frames
                fit_every_dynamic = min(max_fit_every, fit_every_dynamic + 1)
            elseif fit_every_dynamic > fit_every && fit_elapsed_ms < max_fit_ms * 0.5
                fit_every_dynamic -= 1
            end

            if !isempty(params_raw) && !isnan(params_raw[1])
                params .= params_raw
            end
        else
            if skip_fit_frames > 0
                skip_fit_frames -= 1
            end
            x_data = get_x_data(histogram_resolution)
            data = [x_data, Float64.(final_vector)]
        end
        t3 = time_ns()

        photons = sum(data[2])
        _ = conv_irf_data(data[1], Tuple(params), irf; histogram_resolution=histogram_resolution) * photons
        t4 = time_ns()

        # Realtime scan path, same strategy as runtime loop.
        tscan0 = time_ns()
        dir_stat = try
            stat(data_path)
        catch
            nothing
        end
        if dir_stat !== nothing
            cur = dir_stat.mtime
            if cur != last_dir_mtime
                last_dir_mtime = cur
                known_sdt = String[]
                for entry in readdir(data_path; join=true)
                    if isfile(entry) && endswith(lowercase(entry), ".sdt")
                        push!(known_sdt, entry)
                    end
                end
            end
        end
        tscan1 = time_ns()

        tstat0 = time_ns()
        if !isempty(known_sdt)
            latest = known_sdt[1]
            latest_mt = try stat(latest).mtime catch; 0.0 end
            for f in known_sdt
                mt = try stat(f).mtime catch; -1.0 end
                if mt > latest_mt
                    latest = f
                    latest_mt = mt
                end
            end
            if latest == last_processed
                # nothing to do
            else
                last_processed = latest
            end
        end
        tstat1 = time_ns()

        total_ms = (tstat1 - t0) / 1e6
        open_ms = (t1 - t0) / 1e6
        bin_ms = (t2 - t1) / 1e6
        fit_ms = (t3 - t2) / 1e6
        reconv_ms = (t4 - t3) / 1e6
        scan_ms = (tscan1 - tscan0) / 1e6
        stat_ms = (tstat1 - tstat0) / 1e6

        push!(worker_total, total_ms)
        push!(fit_ms_all, fit_ms)
        push!(scan_ms_all, scan_ms)
        push!(stat_ms_all, stat_ms)
        push!(records, (
            i=i,
            total_ms=total_ms,
            open_ms=open_ms,
            bin_ms=bin_ms,
            fit_ms=fit_ms,
            reconv_ms=reconv_ms,
            scan_ms=scan_ms,
            stat_ms=stat_ms,
            fit_every_dynamic=fit_every_dynamic,
            skip_fit_frames=skip_fit_frames
        ))
    end

    println("\n=== 3-minute Spike Summary ===")
    println(@sprintf("frames=%d  elapsed=%.1f s", length(records), time() - start_t))
    println(@sprintf("total   avg=%.3f ms p95=%.3f ms p99=%.3f ms p999=%.3f ms max=%.3f ms",
        mean(worker_total), percentile(worker_total, 0.95), percentile(worker_total, 0.99), percentile(worker_total, 0.999), maximum(worker_total)))
    println(@sprintf("fit     avg=%.3f ms p95=%.3f ms p99=%.3f ms max=%.3f ms",
        mean(fit_ms_all), percentile(fit_ms_all, 0.95), percentile(fit_ms_all, 0.99), maximum(fit_ms_all)))
    println(@sprintf("scan    avg=%.3f ms p95=%.3f ms p99=%.3f ms max=%.3f ms",
        mean(scan_ms_all), percentile(scan_ms_all, 0.95), percentile(scan_ms_all, 0.99), maximum(scan_ms_all)))
    println(@sprintf("stat    avg=%.3f ms p95=%.3f ms p99=%.3f ms max=%.3f ms",
        mean(stat_ms_all), percentile(stat_ms_all, 0.95), percentile(stat_ms_all, 0.99), maximum(stat_ms_all)))

    top = sort(records, by=r->r.total_ms, rev=true)[1:min(12, length(records))]
    println("\nTop spikes:")
    for r in top
        dom = dominant_stage(r)
        println(@sprintf("i=%6d total=%8.3f ms dom=%-6s %7.3f ms  fitdyn=%d skip=%d  [open=%.3f bin=%.3f fit=%.3f reconv=%.3f scan=%.3f stat=%.3f]",
            r.i, r.total_ms, dom[1], dom[2], r.fit_every_dynamic, r.skip_fit_frames,
            r.open_ms, r.bin_ms, r.fit_ms, r.reconv_ms, r.scan_ms, r.stat_ms))
    end
end

function main()
    secs = length(ARGS) >= 1 ? parse(Float64, ARGS[1]) : 180.0
    println("=== FLIM 2-3 min Spike Run ===")
    println(@sprintf("Target duration: %.1f s", secs))
    init_context!()
    data_path, files = resolve_files()
    println("Data path: $(data_path), files=$(length(files))")
    run_for_duration(files, data_path; seconds=secs)
end

main()
