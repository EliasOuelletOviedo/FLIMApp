#!/usr/bin/env julia

using Statistics
using Printf
using FFTW
using Observables

const ROOT = normpath(joinpath(@__DIR__, ".."))

include(joinpath(ROOT, "src", "config.jl"))
include(joinpath(ROOT, "src", "lifetime_analysis2.jl"))
include(joinpath(ROOT, "src", "data_processing.jl"))

const PlaybackTuple = Tuple{Vector{Float64},Vector{Float64},Float64,Float64,Float64,Float64,Float64,Float64,Float64,UInt32}

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
                return path, files
            end
        end
    end

    error("No .sdt files found in configured paths.")
end

function drain_channel!(ch)
    while isready(ch)
        _ = take!(ch)
    end
    return nothing
end

function benchmark_playback_end_to_end(; warmup_s::Float64=2.0, measure_s::Float64=12.0)
    layout = get_default_layout()
    controller = get_default_controller()

    ch = Channel{PlaybackTuple}(8192)
    running = Threads.Atomic{Bool}(true)

    worker = @async start_playback(ch, running, layout, controller; dt=1e-7)

    warmup_end_ns = time_ns() + round(Int, warmup_s * 1e9)

    measured_count = 0
    first_measured_counter = UInt32(0)
    last_measured_counter = UInt32(0)
    interarrival_ms = Float64[]

    prev_recv_ns = 0

    while time_ns() < warmup_end_ns
        if isready(ch)
            _ = take!(ch)
            prev_recv_ns = time_ns()
        else
            sleep(0.0002)
        end
    end

    # Ensure we start timing without stale backlog from warmup.
    drain_channel!(ch)
    start_ns = time_ns()
    stop_ns = start_ns + round(Int, measure_s * 1e9)

    while time_ns() < stop_ns
        if isready(ch)
            payload = take!(ch)
            now_ns = time_ns()

            measured_count += 1
            current_counter = payload[10]
            if first_measured_counter == 0
                first_measured_counter = current_counter
            end
            last_measured_counter = current_counter

            if prev_recv_ns != 0
                push!(interarrival_ms, (now_ns - prev_recv_ns) / 1e6)
            end
            prev_recv_ns = now_ns
        else
            sleep(0.0002)
        end
    end

    running[] = false
    wait(worker)

    measured_elapsed_s = (stop_ns - start_ns) / 1e9
    produced_frames = if first_measured_counter == 0 || last_measured_counter < first_measured_counter
        measured_count
    else
        Int(last_measured_counter - first_measured_counter + 1)
    end

    hz = measured_elapsed_s > 0 ? produced_frames / measured_elapsed_s : 0.0

    return (
        hz=hz,
        count=produced_frames,
        consumed=measured_count,
        elapsed_s=measured_elapsed_s,
        interarrival_ms=interarrival_ms
    )
end

function profile_playback_pipeline(filepaths::Vector{String}; iterations::Int=140)
    layout = get_default_layout()
    controller = get_default_controller()

    n_vectors = 100
    vectors = zeros(Float64, n_vectors, DEFAULT_HISTOGRAM_RESOLUTION)
    sum_vector = zeros(Float64, DEFAULT_HISTOGRAM_RESOLUTION)

    last_bin = 1
    current_count = 0
    params = [3.0, 0.0, 5.0e-5]
    first_fit_pending = true
    n = UInt32(0)

    fallback_setpoint_ns = 4.0
    I_error = 0.0
    old_error = 0.0
    D_error = 0.0
    pid_prev_smooth_lifetime = NaN
    pid_prev_raw_lifetime = NaN
    pid_scale_est = 1.0e-6

    open_ms = Float64[]
    bin_ms = Float64[]
    fit_ms = Float64[]
    reconv_ms = Float64[]
    pid_ms = Float64[]
    put_ms = Float64[]
    total_ms = Float64[]

    sink = Channel{PlaybackTuple}(2048)

    for i in 1:iterations
        filepath = filepaths[mod1(i, length(filepaths))]

        t0 = time_ns()
        vector, histogram_resolution, frame_time = open_SDT_file(filepath)
        t1 = time_ns()

        pos = mod1(n + 1, n_vectors)
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
        t2 = time_ns()

        params_raw, data = vec_to_lifetime(Float64.(final_vector); guess=params, histogram_resolution=histogram_resolution, first_fit=first_fit_pending)
        first_fit_pending = false
        t3 = time_ns()

        if !isnan(params_raw[1])
            params = params_raw
        end

        histogram = data[2]
        photons = sum(histogram)
        fit = conv_irf_data(data[1], Tuple(params), irf; histogram_resolution=histogram_resolution) * photons
        lifetime = params[1]
        concentration = (9.5 / lifetime - 1) / 0.025
        timestamps = i * Float64(frame_time)
        t4 = time_ns()

        setpoint_ns = fallback_setpoint_ns
        smooth_level = layout_smoothing_level(layout)
        lifetime_for_pid, pid_prev_smooth_lifetime, pid_prev_raw_lifetime, pid_scale_est =
            update_pid_lifetime_kalman(
                lifetime,
                pid_prev_smooth_lifetime,
                pid_prev_raw_lifetime,
                pid_scale_est,
                smooth_level
            )

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

        command1 = p1 * P_error + i1 * I_error + d1 * D_error
        command2 = p2 * P_error + i2 * I_error + d2 * D_error
        t5 = time_ns()

        put!(sink, (histogram, fit, photons, command1, command2, lifetime, concentration, timestamps, setpoint_ns, n + 1))
        _ = take!(sink)
        t6 = time_ns()

        push!(open_ms, (t1 - t0) / 1e6)
        push!(bin_ms, (t2 - t1) / 1e6)
        push!(fit_ms, (t3 - t2) / 1e6)
        push!(reconv_ms, (t4 - t3) / 1e6)
        push!(pid_ms, (t5 - t4) / 1e6)
        push!(put_ms, (t6 - t5) / 1e6)
        push!(total_ms, (t6 - t0) / 1e6)

        n += 1
    end

    total_sum = sum(total_ms)

    function stage_stats(samples::Vector{Float64})
        return (
            avg=mean(samples),
            p95=percentile(samples, 0.95),
            max=maximum(samples),
            share=(total_sum > 0 ? 100 * sum(samples) / total_sum : 0.0)
        )
    end

    return Dict(
        :open => stage_stats(open_ms),
        :binning => stage_stats(bin_ms),
        :fit => stage_stats(fit_ms),
        :reconv => stage_stats(reconv_ms),
        :pid => stage_stats(pid_ms),
        :channel => stage_stats(put_ms),
        :total => stage_stats(total_ms),
        :throughput_hz => (mean(total_ms) > 0 ? 1000 / mean(total_ms) : 0.0)
    )
end

function print_stage(label::String, stats)
    println(@sprintf("%-12s avg=%7.3f ms p95=%7.3f ms max=%7.3f ms share=%6.2f%%",
        label, stats.avg, stats.p95, stats.max, stats.share))
end

function main()
    strict = !any(arg -> arg == "--no-strict", ARGS)
    min_hz = 350.0

    println("=== Playback Complete Benchmark ===")
    println("Julia version: $(VERSION)")

    init_numeric_context!()
    _, files = resolve_data_files()

    e2e = benchmark_playback_end_to_end()

    println("\n=== End-to-End Worker Throughput ===")
    println(@sprintf("frames=%d consumed=%d elapsed=%.3f s", e2e.count, e2e.consumed, e2e.elapsed_s))
    println(@sprintf("playback rate = %.2f Hz", e2e.hz))
    if !isempty(e2e.interarrival_ms)
        println(@sprintf("inter-arrival avg=%.3f ms p95=%.3f ms max=%.3f ms",
            mean(e2e.interarrival_ms), percentile(e2e.interarrival_ms, 0.95), maximum(e2e.interarrival_ms)))
    end

    breakdown = profile_playback_pipeline(files)

    println("\n=== Playback Stage Breakdown ===")
    print_stage("open_SDT", breakdown[:open])
    print_stage("binning", breakdown[:binning])
    print_stage("fit", breakdown[:fit])
    print_stage("reconv", breakdown[:reconv])
    print_stage("pid", breakdown[:pid])
    print_stage("channel", breakdown[:channel])
    print_stage("total", breakdown[:total])
    println(@sprintf("synthetic loop throughput = %.2f Hz", breakdown[:throughput_hz]))

    shares = [
        ("fit", breakdown[:fit].share),
        ("open_SDT", breakdown[:open].share),
        ("reconv", breakdown[:reconv].share),
        ("binning", breakdown[:binning].share),
        ("pid", breakdown[:pid].share),
        ("channel", breakdown[:channel].share)
    ]
    sorted_shares = sort(shares, by=x -> x[2], rev=true)

    println("\n=== Bottlenecks (share of total CPU time) ===")
    for (name, share) in sorted_shares[1:3]
        println(@sprintf("- %s: %.2f%%", name, share))
    end

    if strict && e2e.hz < min_hz
        error(@sprintf("Playback frequency %.2f Hz is below required minimum %.1f Hz", e2e.hz, min_hz))
    elseif e2e.hz < min_hz
        @warn @sprintf("Playback frequency %.2f Hz is below required minimum %.1f Hz", e2e.hz, min_hz)
    else
        println(@sprintf("Playback frequency check OK: %.2f Hz >= %.1f Hz", e2e.hz, min_hz))
    end
end

main()
