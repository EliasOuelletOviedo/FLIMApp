#!/usr/bin/env julia

using Statistics
using Printf
using FFTW
using Observables
using Optim
using LineSearches

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

function profiled_mle_iterative_reconvolution(
    data_irf::Matrix{Float64},
    data_xy::Vector{Vector{Float64}};
    params,
    gating_function=ones(UInt8, 320),
    histogram_resolution::Int64=256,
    number_of_previous_pulses::Int64=5,
    laser_pulse_period::Float64=12.5,
    fixed_parameters::Vector{Float64}=Float64[NaN, NaN, NaN],
    tcspc_low_cut_index::Int64=13,
    tcspc_high_cut_index::Int64=12,
    use_lifetime_estimation_as_guess::Bool=true,
    first_fit::Bool=false
)
    times = Dict{Symbol, Float64}()

    t0 = time_ns()
    x_data = vec(data_xy[1])
    y_data = vec(data_xy[2]) .* gating_function
    replace!(x -> smaller_or_eq_zero(x) ? 1e-256 : x, y_data)
    t1 = time_ns()
    times[:mle_input_prep_ms] = (t1 - t0) / 1e6

    number_of_lifetimes = floor(Int, (length(params) - 1) / 2)
    params_copy = copy(params)

    if all(isnotnan.(fixed_parameters))
        times[:mle_guess_bounds_ms] = 0.0
        times[:mle_prune_clamp_ms] = 0.0
        times[:mle_optimize_ms] = 0.0
        times[:mle_postprocess_ms] = 0.0
        times[:mle_total_ms] = (time_ns() - t0) / 1e6
        return fixed_parameters, times
    end

    t2 = time_ns()
    if number_of_lifetimes == 1
        if use_lifetime_estimation_as_guess
            params_copy[1] = lifetime_estimate(y_data, bin_size=irf_bin_size, tcspc_high_cut_index=tcspc_high_cut_index)
        end
        lower_bounds = Float64[2 * irf_bin_size, -16.0, 0.0]
        upper_bounds = Float64[laser_pulse_period * 2, 32.0, 1.0]
    elseif number_of_lifetimes == 2
        lower_bounds = Float64[2 * irf_bin_size, 0.0, 2 * irf_bin_size, -16.0, 0.0]
        upper_bounds = Float64[laser_pulse_period * 2, 1.0, laser_pulse_period * 2, 64.0, 1.0]
    else
        lower_bounds = Float64[2 * irf_bin_size, 0.0, 2 * irf_bin_size, 0.0, 2 * irf_bin_size, 0.0, -16.0, 0.0]
        upper_bounds = Float64[laser_pulse_period * 2, 1.0, laser_pulse_period * 2, 1.0, laser_pulse_period * 2, 1.0, 32.0, 1.0]
    end
    t3 = time_ns()
    times[:mle_guess_bounds_ms] = (t3 - t2) / 1e6

    t4 = time_ns()
    if any(.!isnan.(fixed_parameters))
        if length(params_copy) != length(fixed_parameters)
            error("params and fixed_parameters must be the same length")
        end
        fixed_indices = collect(1:length(fixed_parameters))[.!isnan.(fixed_parameters)]
        deleteat!(params_copy, fixed_indices)
        deleteat!(lower_bounds, fixed_indices)
        deleteat!(upper_bounds, fixed_indices)
    end

    clamp_initial_point!(params_copy, lower_bounds, upper_bounds)
    t5 = time_ns()
    times[:mle_prune_clamp_ms] = (t5 - t4) / 1e6

    t6 = time_ns()
    if number_of_lifetimes in (1, 2)
        fit = Optim.optimize(
            x -> MLE_model_func(
                x,
                fixed_parameters,
                x_data,
                y_data,
                data_irf,
                gating_function,
                histogram_resolution,
                number_of_previous_pulses,
                laser_pulse_period,
                tcspc_low_cut_index,
                tcspc_high_cut_index
            ),
            lower_bounds,
            upper_bounds,
            params_copy,
            Fminbox(LBFGS(linesearch=LineSearches.BackTracking())),
            fit_optim_options(number_of_lifetimes, first_fit)
        )
    else
        lower_c, upper_c = Float64[1.0], Float64[1.0]
        constraint = TwiceDifferentiableConstraints(fit_3lifetime_fraction_constraints_jl!, lower_bounds, upper_bounds, lower_c, upper_c)
        fit = Optim.optimize(
            x -> MLE_model_func(
                x,
                fixed_parameters,
                x_data,
                y_data,
                data_irf,
                gating_function,
                histogram_resolution,
                number_of_previous_pulses,
                laser_pulse_period,
                tcspc_low_cut_index,
                tcspc_high_cut_index
            ),
            constraint,
            params_copy,
            IPNewton(),
            fit_optim_options(number_of_lifetimes, first_fit)
        )
    end
    t7 = time_ns()
    times[:mle_optimize_ms] = (t7 - t6) / 1e6

    t8 = time_ns()
    res = Optim.minimizer(fit)

    output_res = zeros(Float64, length(params))
    if any(.!isnan.(fixed_parameters))
        free_counter = 1
        for p in eachindex(fixed_parameters)
            if isnan(fixed_parameters[p])
                output_res[p] = res[free_counter]
                free_counter += 1
            else
                output_res[p] = fixed_parameters[p]
            end
        end
    else
        output_res = res
    end

    if !Optim.converged(fit)
        if number_of_lifetimes == 1
            output_res = Float64[NaN, NaN, NaN]
        elseif number_of_lifetimes == 2
            output_res = Float64[NaN, NaN, NaN, NaN, NaN]
        else
            output_res = Float64[NaN, NaN, NaN, NaN, NaN, NaN, NaN, NaN]
        end
    else
        if number_of_lifetimes == 2 && output_res[3] > output_res[1]
            t_1 = output_res[1]
            t_2 = output_res[3]
            output_res[1] = t_2
            output_res[3] = t_1
            output_res[2] = 1 - output_res[2]
        elseif number_of_lifetimes == 3
            permutation = sortperm(output_res[1:2:5])
            found_params_copy = copy(output_res)
            adjusted = zeros(Int64, 3)
            for (idx, p) in enumerate(permutation)
                adjusted[idx] = p == 1 ? 1 : p == 2 ? 3 : 5
            end
            amplitudes = [found_params_copy[2], found_params_copy[4], found_params_copy[6]]
            output_res[1] = found_params_copy[adjusted[1]]
            output_res[2] = amplitudes[permutation[1]]
            output_res[3] = found_params_copy[adjusted[2]]
            output_res[4] = amplitudes[permutation[2]]
            output_res[5] = found_params_copy[adjusted[3]]
            output_res[6] = amplitudes[permutation[3]]
        end
    end
    t9 = time_ns()

    times[:mle_postprocess_ms] = (t9 - t8) / 1e6
    times[:mle_total_ms] = (t9 - t0) / 1e6

    return output_res, times
end

function profiled_vec_to_lifetime(
    x;
    bin_size=0.04886091184430619,
    hist_size_threshold=500,
    method="MLE",
    guess=[3.0, 1.0, 1e-6],
    laser_pulse_period=12.5,
    histogram_resolution=256,
    number_of_previous_pulses=5,
    tac_low_cut=5.0980392,
    tac_high_cut=94.901962,
    lifetime_estimation=NaN,
    fixed_parameters=Float64[NaN, NaN, NaN],
    use_lifetime_estimation_as_guess::Bool=true,
    first_fit::Bool=false
)
    times = Dict{Symbol, Float64}()

    t0 = time_ns()
    ensure_runtime_state!()
    t1 = time_ns()
    times[:state_check_ms] = (t1 - t0) / 1e6

    t2 = time_ns()
    requested_channels = round(Int, laser_pulse_period * histogram_resolution / tcspc_window_size)
    total_channels = requested_channels
    if total_channels <= 0
        total_channels = histogram_resolution
    end
    if abs(total_channels - histogram_resolution) <= 1
        total_channels = histogram_resolution
    end
    total_channels = max(total_channels, histogram_resolution, length(x), 32)

    x_vec = Float64.(vec(x))
    if length(x_vec) < total_channels
        append!(x_vec, zeros(total_channels - length(x_vec)))
    elseif length(x_vec) > total_channels
        x_vec = x_vec[1:total_channels]
    end
    t3 = time_ns()
    times[:input_prepare_ms] = (t3 - t2) / 1e6

    t4 = time_ns()
    ensure_fft_plans(total_channels)
    irf_local = get_irf_for_channels(total_channels)
    x_data = get_x_data(total_channels, Float64(bin_size))
    t5 = time_ns()
    times[:cache_prepare_ms] = (t5 - t4) / 1e6

    t6 = time_ns()
    if sum(x_vec) < hist_size_threshold
        times[:threshold_check_ms] = (time_ns() - t6) / 1e6
        times[:gating_prepare_ms] = 0.0
        times[:mle_total_ms] = 0.0
        times[:vec_total_ms] = (time_ns() - t0) / 1e6
        if method == "Estimate"
            return Float64[0.0], [x_data, x_vec], times
        end
        return Float64[NaN], [x_data, x_vec], times
    end

    if method == "Estimate"
        times[:threshold_check_ms] = (time_ns() - t6) / 1e6
        times[:gating_prepare_ms] = 0.0
        times[:mle_total_ms] = 0.0
        times[:vec_total_ms] = (time_ns() - t0) / 1e6
        return Float64[lifetime_estimate(x_vec[1:histogram_resolution], bin_size=bin_size)], [x_data[1:histogram_resolution], x_vec[1:histogram_resolution]], times
    end

    if method != "MLE"
        error("Unsupported method: $method")
    end
    t7 = time_ns()
    times[:threshold_check_ms] = (t7 - t6) / 1e6

    t8 = time_ns()
    low_cut_index = round(Int, tac_low_cut / 100 * histogram_resolution)
    low_cut_index = max(low_cut_index, 1)

    if tac_high_cut != 0
        high_cut_start = round(Int, tac_high_cut / 100 * histogram_resolution)
        high_cut_start = clamp(high_cut_start, 1, total_channels + 1)
        tcspc_high_cut_index = total_channels - high_cut_start
    else
        high_cut_start = total_channels + 1
        tcspc_high_cut_index = 0
    end

    gating_function = get_gating_function(total_channels, low_cut_index, high_cut_start)
    data_xy = [x_data, x_vec]
    t9 = time_ns()
    times[:gating_prepare_ms] = (t9 - t8) / 1e6

    tau_fit, mle_times = profiled_mle_iterative_reconvolution(
        irf_local,
        data_xy,
        params=guess,
        gating_function=gating_function,
        histogram_resolution=total_channels,
        number_of_previous_pulses=number_of_previous_pulses,
        laser_pulse_period=laser_pulse_period,
        fixed_parameters=fixed_parameters,
        tcspc_low_cut_index=low_cut_index,
        tcspc_high_cut_index=tcspc_high_cut_index,
        use_lifetime_estimation_as_guess=use_lifetime_estimation_as_guess,
        first_fit=first_fit,
    )

    for (k, v) in mle_times
        times[k] = v
    end

    times[:vec_total_ms] = (time_ns() - t0) / 1e6
    _ = lifetime_estimation

    return tau_fit, data_xy, times
end

function summarize_step(name::String, samples::Vector{Float64}, total_sum::Float64)
    avg = mean(samples)
    p95 = percentile(samples, 0.95)
    maxv = maximum(samples)
    share = total_sum > 0 ? 100 * sum(samples) / total_sum : 0.0
    println(@sprintf("%-24s avg=%8.3f ms  p95=%8.3f ms  max=%8.3f ms  share=%6.2f%%", name, avg, p95, maxv, share))
end

function run_profile(; n_files::Int=700, warmup::Int=40)
    files = resolve_data_files()
    n_files = min(n_files, length(files))

    println(@sprintf("Profiling vec_to_lifetime on %d files (+ %d warmup)", n_files, warmup))

    sample_path = files[1]
    sample_vector, hist_res, _ = open_SDT_file(sample_path)

    for i in 1:warmup
        path = files[mod1(i, length(files))]
        vector, _, _ = open_SDT_file(path)
        _ = vec_to_lifetime(Float64.(vector); guess=[3.0, 0.0, 5.0e-5], histogram_resolution=hist_res, first_fit=(i == 1))
    end

    step_names = [
        :state_check_ms,
        :input_prepare_ms,
        :cache_prepare_ms,
        :threshold_check_ms,
        :gating_prepare_ms,
        :mle_input_prep_ms,
        :mle_guess_bounds_ms,
        :mle_prune_clamp_ms,
        :mle_optimize_ms,
        :mle_postprocess_ms,
        :mle_total_ms,
        :vec_total_ms,
    ]

    samples = Dict{Symbol, Vector{Float64}}()
    for s in step_names
        samples[s] = Float64[]
    end

    valid_fits = 0
    for i in 1:n_files
        path = files[i]
        vector, histogram_resolution, _ = open_SDT_file(path)

        tau, _, times = profiled_vec_to_lifetime(
            Float64.(vector);
            guess=[3.0, 0.0, 5.0e-5],
            histogram_resolution=histogram_resolution,
            first_fit=(i == 1),
        )

        if !isempty(tau) && !isnan(tau[1])
            valid_fits += 1
        end

        for s in step_names
            push!(samples[s], get(times, s, 0.0))
        end
    end

    total_sum = sum(samples[:vec_total_ms])

    println("\n=== vec_to_lifetime Step Profiling ===")
    println(@sprintf("files=%d valid_fits=%d", n_files, valid_fits))
    summarize_step("state_check", samples[:state_check_ms], total_sum)
    summarize_step("input_prepare", samples[:input_prepare_ms], total_sum)
    summarize_step("cache_prepare", samples[:cache_prepare_ms], total_sum)
    summarize_step("threshold_check", samples[:threshold_check_ms], total_sum)
    summarize_step("gating_prepare", samples[:gating_prepare_ms], total_sum)
    summarize_step("mle_input_prep", samples[:mle_input_prep_ms], total_sum)
    summarize_step("mle_guess_bounds", samples[:mle_guess_bounds_ms], total_sum)
    summarize_step("mle_prune_clamp", samples[:mle_prune_clamp_ms], total_sum)
    summarize_step("mle_optimize", samples[:mle_optimize_ms], total_sum)
    summarize_step("mle_postprocess", samples[:mle_postprocess_ms], total_sum)
    summarize_step("mle_total", samples[:mle_total_ms], total_sum)
    summarize_step("vec_total", samples[:vec_total_ms], total_sum)

    println("\nTop 3 bottlenecks (share):")
    shares = [
        ("mle_optimize", 100 * sum(samples[:mle_optimize_ms]) / total_sum),
        ("input_prepare", 100 * sum(samples[:input_prepare_ms]) / total_sum),
        ("mle_input_prep", 100 * sum(samples[:mle_input_prep_ms]) / total_sum),
        ("cache_prepare", 100 * sum(samples[:cache_prepare_ms]) / total_sum),
        ("mle_postprocess", 100 * sum(samples[:mle_postprocess_ms]) / total_sum),
        ("gating_prepare", 100 * sum(samples[:gating_prepare_ms]) / total_sum),
    ]

    for (name, share) in sort(shares, by=x -> x[2], rev=true)[1:3]
        println(@sprintf("- %s: %.2f%%", name, share))
    end
end

function main()
    n_files = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : 700
    warmup = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 40

    println("=== Fine vec_to_lifetime profiler ===")
    println("Julia version: $(VERSION)")

    init_numeric_context!()
    run_profile(; n_files=n_files, warmup=warmup)
end

main()
