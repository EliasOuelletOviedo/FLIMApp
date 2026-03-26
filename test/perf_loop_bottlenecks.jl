#!/usr/bin/env julia

using Statistics
using Printf
using Observables
using FFTW

const ROOT = normpath(joinpath(@__DIR__, ".."))

include(joinpath(ROOT, "src", "config.jl"))
include(joinpath(ROOT, "src", "lifetime_analysis.jl"))
include(joinpath(ROOT, "src", "data_processing.jl"))

function percentile(values::Vector{Float64}, p::Float64)
    if isempty(values)
        return NaN
    end
    sorted = sort(values)
    idx = clamp(ceil(Int, p * length(sorted)), 1, length(sorted))
    return sorted[idx]
end

function format_ms(x::Float64)
    return @sprintf("%.3f ms", x)
end

function summarize_stage(name::String, samples_ms::Vector{Float64}, total_ms::Float64)
    avg_ms = mean(samples_ms)
    p95_ms = percentile(samples_ms, 0.95)
    max_ms = maximum(samples_ms)
    share = total_ms > 0 ? 100 * sum(samples_ms) / total_ms : 0.0

    println(@sprintf("%-24s avg=%9s  p95=%9s  max=%9s  share=%6.2f%%",
        name, format_ms(avg_ms), format_ms(p95_ms), format_ms(max_ms), share))
end

function autoscale_compute_only(time_range::Float64, xs::Vector{Float64}, ys::Vector{Float64})
    if isempty(xs) || isempty(ys)
        return nothing
    end

    valid = .!isnan.(ys)
    xs2 = xs[valid]
    ys2 = ys[valid]

    if isempty(xs2)
        return nothing
    end

    xmin, xmax = minimum(xs2), maximum(xs2)

    if xmax < time_range
        xmax = time_range
    end

    if xmax - xmin > time_range
        xmin = xmax - time_range
    end

    in_win = (xs2 .>= xmin) .& (xs2 .<= xmax)

    if any(in_win)
        ymin, ymax = minimum(ys2[in_win]), maximum(ys2[in_win])
    else
        ymin, ymax = minimum(ys2), maximum(ys2)
    end

    return (xmin, xmax, ymin, ymax)
end

function init_numeric_context!()
    global irf = get_irf()
    global irf_bin_size = _compute_irf_bin_size(irf)
    global tcspc_window_size = round(irf[end, 1] + irf[2, 1], sigdigits=4)

    n = size(irf, 1)
    global fft_plan = plan_fft(zeros(Float64, n))
    global ifft_plan = plan_ifft(zeros(Float64, n))
    global fft_plan_size = n

    println("IRF loaded for profiling: size=$(size(irf)), bin_size=$(irf_bin_size), window=$(tcspc_window_size)")
end

function resolve_data_files()
    candidates = String[]

    push!(candidates, get_data_root_path())
    push!(candidates, DATA_ROOT_PATH)
    push!(candidates, "/Users/eliasouellet-oviedo/Desktop/test2")

    for path in unique(candidates)
        if isdir(path)
            files = sort(filter(f -> isfile(f) && endswith(lowercase(f), ".sdt"), readdir(path; join=true)))
            if !isempty(files)
                println("Using data folder: $(path) ($(length(files)) files)")
                return files
            end
        end
    end

    error("No .sdt files found in any configured data folder.")
end

function profile_worker_pipeline(filepaths::Vector{String}; n_hot::Int=30, bin::Int=4)
    layout = get_default_layout()
    layout[:binning] = bin
    controller = get_default_controller()

    n_vectors = 100
    vectors = zeros(Float64, n_vectors, DEFAULT_HISTOGRAM_RESOLUTION)
    sum_vector = zeros(Float64, DEFAULT_HISTOGRAM_RESOLUTION)
    last_bin = Ref(1)
    current_count = Ref(0)
    params = [3.0, 0.5, 0.5, 0.0, 5.0e-5]
    n = Ref(UInt32(0))

    lifetime_setpoint_ns = 4.0
    I_error = 0.0
    old_error = 0.0

    open_ms = Float64[]
    bin_ms = Float64[]
    fit_ms = Float64[]
    reconv_ms = Float64[]
    pid_ms = Float64[]
    push_ms = Float64[]

    function one_iteration(filepath::String)
        t0 = time_ns()
        vector, histogram_resolution, dt_sample_file = open_SDT_file(filepath)
        t1 = time_ns()

        pos = mod1(n[] + 1, n_vectors)
        vectors[pos, 1:histogram_resolution] .= vector

        bin_local = get(layout, :binning, 1)
        if bin_local != last_bin[]
            effective_bin = min(bin_local, current_count[] + 1)
            idxs = mod1.(pos .- (0:effective_bin-1), n_vectors)
            sum_vector .= @views sum(vectors[idxs, 1:histogram_resolution]; dims=1)[1, :]
            last_bin[] = bin_local
            current_count[] = effective_bin
        else
            if current_count[] < bin_local
                sum_vector .+= vector
                current_count[] += 1
            else
                old_pos = mod1(pos - bin_local, n_vectors)
                sum_vector .-= vectors[old_pos, 1:histogram_resolution]
                sum_vector .+= vector
            end
        end

        final_vector = sum_vector ./ max(bin_local, 1)
        t2 = time_ns()

        params_raw, data = vec_to_lifetime(Float64.(final_vector); guess=params, histogram_resolution=histogram_resolution)
        t3 = time_ns()

        if !isnan(params_raw[1])
            params .= params_raw
        end

        histogram = data[2]
        photons = sum(histogram)
        fit = conv_irf_data(data[1], Tuple(params), irf; histogram_resolution=histogram_resolution) * photons
        t4 = time_ns()

        lifetime = params[1]
        dt_sample = max(Float64(dt_sample_file), eps(Float64))
        P_error = lifetime_setpoint_ns - lifetime
        I_error += P_error * dt_sample
        D_error = (P_error - old_error) / dt_sample
        old_error = P_error

        command1 = controller[:P1] * P_error + controller[:I1] * I_error + controller[:D1] * D_error
        command2 = controller[:P2] * P_error + controller[:I2] * I_error + controller[:D2] * D_error
        t5 = time_ns()

        tuple_payload = (histogram, fit, photons, command1, command2, lifetime, (9.5 / lifetime - 1) / 0.025, Float64(n[]), photons, n[])
        _ = tuple_payload
        t6 = time_ns()

        return (
            open=(t1 - t0) / 1e6,
            bin=(t2 - t1) / 1e6,
            fit=(t3 - t2) / 1e6,
            reconv=(t4 - t3) / 1e6,
            pid=(t5 - t4) / 1e6,
            push=(t6 - t5) / 1e6,
            total=(t6 - t0) / 1e6
        )
    end

    cold = one_iteration(filepaths[1])
    println("\nWorker pipeline cold pass total: $(format_ms(cold.total))")

    totals = Float64[]
    for i in 1:n_hot
        filepath = filepaths[mod1(i, length(filepaths))]
        result = one_iteration(filepath)

        push!(open_ms, result.open)
        push!(bin_ms, result.bin)
        push!(fit_ms, result.fit)
        push!(reconv_ms, result.reconv)
        push!(pid_ms, result.pid)
        push!(push_ms, result.push)
        push!(totals, result.total)

        n[] += 1
    end

    total_ms = sum(totals)

    println("\n=== Worker Hot Profile ($(n_hot) iterations) ===")
    summarize_stage("open_SDT_file", open_ms, total_ms)
    summarize_stage("binning update", bin_ms, total_ms)
    summarize_stage("vec_to_lifetime", fit_ms, total_ms)
    summarize_stage("conv_irf_data", reconv_ms, total_ms)
    summarize_stage("PID + command", pid_ms, total_ms)
    summarize_stage("tuple payload", push_ms, total_ms)

    println(@sprintf("%-24s avg=%9s  p95=%9s  max=%9s",
        "worker total", format_ms(mean(totals)), format_ms(percentile(totals, 0.95)), format_ms(maximum(totals))))

    return Dict(
        :cold_total_ms => cold.total,
        :hot_total_avg_ms => mean(totals),
        :hot_total_p95_ms => percentile(totals, 0.95),
        :fit_share_percent => (total_ms > 0 ? 100 * sum(fit_ms) / total_ms : 0.0),
        :reconv_share_percent => (total_ms > 0 ? 100 * sum(reconv_ms) / total_ms : 0.0)
    )
end

function profile_consumer_pipeline(; n_iters::Int=6000, notify_rate::Int=10, time_range::Float64=60.0)
    photons = Observable(Float64[])
    lifetime = Observable(Float64[])
    concentration = Observable(Float64[])
    command1 = Observable(Float64[])
    command2 = Observable(Float64[])
    timestamps = Observable(Float64[])
    i_obs = Observable(UInt32(0))
    histogram = Observable(zeros(Float64, DEFAULT_HISTOGRAM_RESOLUTION))
    fit = Observable(zeros(Float64, DEFAULT_HISTOGRAM_RESOLUTION))
    counts = Observable(0.0)

    push_ms = Float64[]
    notify_ms = Float64[]
    autoscale_lifetime_ms = Float64[]
    autoscale_command_ms = Float64[]

    sample_hist = rand(DEFAULT_HISTOGRAM_RESOLUTION)
    sample_fit = rand(DEFAULT_HISTOGRAM_RESOLUTION)

    for i in 1:n_iters
        t0 = time_ns()
        push!(photons[], 2_000.0 + 100.0 * rand())
        push!(lifetime[], 2.0 + rand())
        push!(concentration[], 15.0 + 2.0 * rand())
        push!(command1[], clamp(50 * randn() + 50, 0.0, 100.0))
        push!(command2[], clamp(50 * randn() + 50, 0.0, 100.0))
        push!(timestamps[], i * 0.05)
        i_obs[] = UInt32(i)
        t1 = time_ns()

        push!(push_ms, (t1 - t0) / 1e6)

        if i % notify_rate == 0
            t2 = time_ns()
            histogram[] = sample_hist
            fit[] = sample_fit
            counts[] = sum(sample_hist)

            notify(photons)
            notify(lifetime)
            notify(concentration)
            notify(command1)
            notify(command2)
            notify(timestamps)
            notify(i_obs)
            t3 = time_ns()

            push!(notify_ms, (t3 - t2) / 1e6)

            t4 = time_ns()
            _ = autoscale_compute_only(time_range, timestamps[], lifetime[])
            t5 = time_ns()
            push!(autoscale_lifetime_ms, (t5 - t4) / 1e6)

            t6 = time_ns()
            xs_cmd = vcat(timestamps[], timestamps[])
            ys_cmd = vcat(command1[], command2[])
            _ = autoscale_compute_only(time_range, xs_cmd, ys_cmd)
            t7 = time_ns()
            push!(autoscale_command_ms, (t7 - t6) / 1e6)
        end
    end

    total_ms = sum(push_ms) + sum(notify_ms) + sum(autoscale_lifetime_ms) + sum(autoscale_command_ms)

    println("\n=== Consumer/GUI Hot Profile ===")
    summarize_stage("push observables", push_ms, total_ms)
    summarize_stage("notify batch", notify_ms, total_ms)
    summarize_stage("autoscale lifetime", autoscale_lifetime_ms, total_ms)
    summarize_stage("autoscale command", autoscale_command_ms, total_ms)

    return Dict(
        :consumer_push_avg_ms => mean(push_ms),
        :consumer_notify_avg_ms => isempty(notify_ms) ? 0.0 : mean(notify_ms),
        :consumer_command_autoscale_avg_ms => isempty(autoscale_command_ms) ? 0.0 : mean(autoscale_command_ms),
        :consumer_command_autoscale_p95_ms => isempty(autoscale_command_ms) ? 0.0 : percentile(autoscale_command_ms, 0.95)
    )
end

function main()
    println("=== FLIM Loop Bottleneck Profiler ===")
    println("Julia version: $(VERSION)")

    init_numeric_context!()
    files = resolve_data_files()

    worker_stats = profile_worker_pipeline(files; n_hot=30, bin=4)
    consumer_stats = profile_consumer_pipeline(n_iters=6000, notify_rate=10)

    println("\n=== Diagnosis ===")
    println(@sprintf("Worker cold pass: %.3f ms", worker_stats[:cold_total_ms]))
    println(@sprintf("Worker hot avg: %.3f ms", worker_stats[:hot_total_avg_ms]))
    println(@sprintf("Worker hot p95: %.3f ms", worker_stats[:hot_total_p95_ms]))
    println(@sprintf("vec_to_lifetime share: %.2f%%", worker_stats[:fit_share_percent]))
    println(@sprintf("conv_irf_data share: %.2f%%", worker_stats[:reconv_share_percent]))
    println(@sprintf("Consumer command autoscale avg: %.3f ms", consumer_stats[:consumer_command_autoscale_avg_ms]))
    println(@sprintf("Consumer command autoscale p95: %.3f ms", consumer_stats[:consumer_command_autoscale_p95_ms]))

    principal = if worker_stats[:fit_share_percent] > 45
        "PRINCIPAL CAUSE: lifetime fitting (vec_to_lifetime / optimization loop) dominates worker frame time."
    elseif worker_stats[:reconv_share_percent] > 35
        "PRINCIPAL CAUSE: reconvolution (conv_irf_data + FFT path) dominates worker frame time."
    else
        "PRINCIPAL CAUSE: no single stage above threshold; stutter likely from combined worker + GUI update spikes."
    end

    println(principal)
end

main()
