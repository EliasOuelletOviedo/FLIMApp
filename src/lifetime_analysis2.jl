"""
lifetime_analysis2.jl

Version simplifiee et orientee performance de vec_to_lifetime.
Ce fichier garde uniquement les fonctions necessaires au flux MLE/Estimate.
"""

using FFTW
using Statistics
using NativeFileDialog
using Optim
using LineSearches
using ZipFile

const X_DATA_CACHE = Dict{Tuple{Int, Float64}, Vector{Float64}}()
const GATING_CACHE = Dict{Tuple{Int, Int, Int}, Vector{UInt8}}()
const IRF_CHANNEL_CACHE = Dict{Int, Matrix{Float64}}()

# -----------------------------------------------------------------------------
# Helpers IRF
# -----------------------------------------------------------------------------

function reshape_to_vec_no_python(file::Vector{UInt16}, num_rows::Int)::Vector{Float64}
    return sum(reshape(file, (num_rows, :)), dims=2)[:, 1]
end

function open_sdt_file_no_python(filepath::String)::Tuple{Vector{UInt16}, Int, Float32}
    open(filepath, "r") do io
        seek(io, 14)
        header = read!(io, Vector{UInt8}(undef, 12))

        seek(io, header[12] * 0x100 + header[11] + 82)
        infos = read!(io, Vector{UInt8}(undef, 2))
        histogram_resolution = infos[2] * 0x100 + infos[1]

        seek(io, header[12] * 0x100 + header[11] + 215)
        infos_2 = read!(io, Vector{UInt8}(undef, 4))
        time = reinterpret(Float32, infos_2)[1]

        if (header[8] * 0x100 + header[7]) in (512, 128)
            seek(io, header[2] * 0x100 + header[1] + 22)
            vector = read(io)
            n = div(length(vector), 2)
            new_vector = reinterpret(UInt16, vector[1:2*n])
            return new_vector, histogram_resolution, time
        end

        seek(io, header[2] * 0x100 + header[1] + 2)
        file_info = read!(io, Vector{UInt8}(undef, 20))
        shift_1 = file_info[8] * 0x1000000 + file_info[7] * 0x10000 + file_info[6] * 0x100 + file_info[5] -
                  (file_info[2] * 0x100 + file_info[1])
        shift_2 = file_info[20] * 0x1000000 + file_info[19] * 0x10000 + file_info[18] * 0x100 + file_info[17]

        buffer = IOBuffer(read(io, shift_1))
        zip_file = first(ZipFile.Reader(buffer).files)

        file_data = Vector{UInt8}(undef, shift_2)
        read!(zip_file, file_data)

        vector = reshape_to_vec_no_python(reinterpret(UInt16, file_data), histogram_resolution)
        return convert.(UInt16, vector), histogram_resolution, time
    end
end

function irf_from_sdt_without_python(filepath::AbstractString; channel::Int=1)::Matrix{Float64}
    counts_raw, histogram_resolution, time = open_sdt_file_no_python(String(filepath))

    counts = Float64.(counts_raw)
    if isempty(counts)
        error("IRF file contains no histogram data")
    end

    median_irf = round(median(counts))
    counts .-= round(Int, median_irf)
    counts[counts .<= 0] .= 0

    n = min(length(counts), histogram_resolution)
    bin_size_ns = Float64(time) * 1e9
    window_ns = bin_size_ns * n

    if !isfinite(bin_size_ns) || bin_size_ns <= 0.0 || !isfinite(window_ns) || window_ns > 1_000.0
        bin_size_ns = 12.5 / n
    end

    times = collect(0:n-1) .* bin_size_ns

    data = zeros(Float64, n, 2)
    data[:, 1] = times
    data[:, 2] = counts[1:n]
    return data
end

function get_irf(; channel=1)
    if isfile("docs/irf_filepath.txt")
        filepath = open(f -> read(f, String), "docs/irf_filepath.txt")
        if !ispath(filepath)
            println("IRF filepath does not exist. Please select valid .sdt file.")
            filepath = pick_file()
            open("docs/irf_filepath.txt", "w") do io
                write(io, filepath)
            end
        end
    else
        filepath = pick_file()
        open("docs/irf_filepath.txt", "w") do io
            write(io, filepath)
        end
    end

    return irf_from_sdt_without_python(filepath; channel=channel)
end

function compute_irf_bin_size(irf_data::Matrix{Float64})::Float64
    h = Inf
    for i in 2:size(irf_data, 1)
        dt = irf_data[i, 1] - irf_data[i-1, 1]
        if 0 < dt < h
            h = dt
        end
    end
    return h
end

function get_irf_bin_size()
    data_irf = get_irf()
    return compute_irf_bin_size(data_irf)
end

# -----------------------------------------------------------------------------
# Etat global
# -----------------------------------------------------------------------------

isnotnan(x) = !isnan(x)
smaller_or_eq_zero(x) = x <= 0

var"fft_plan" = plan_fft(zeros(Float64, 256))
var"ifft_plan" = plan_ifft(zeros(Float64, 256))
var"fft_plan_size" = 256
var"irf" = nothing
var"irf_bin_size" = nothing
var"tcspc_window_size" = nothing
var"irf_cache_source_id" = UInt(0)

function ensure_fft_plans(size::Int)
    if fft_plan_size != size
        global fft_plan = plan_fft(zeros(Float64, size))
        global ifft_plan = plan_ifft(zeros(Float64, size))
        global fft_plan_size = size
    end
end

function get_x_data(total_channels::Int, bin_size::Float64)::Vector{Float64}
    key = (total_channels, bin_size)
    cached = get(X_DATA_CACHE, key, nothing)
    if cached !== nothing
        return cached
    end

    x_data = collect(bin_size:bin_size:total_channels * bin_size)
    X_DATA_CACHE[key] = x_data
    return x_data
end

function get_gating_function(total_channels::Int, low_cut_idx::Int, high_cut_idx::Int)::Vector{UInt8}
    if total_channels <= 0
        return UInt8[]
    end

    low_cut = clamp(low_cut_idx, 0, total_channels)
    high_cut = clamp(high_cut_idx, 1, total_channels + 1)

    key = (total_channels, low_cut, high_cut)
    cached = get(GATING_CACHE, key, nothing)
    if cached !== nothing
        return cached
    end

    gating = ones(UInt8, total_channels)
    if low_cut >= 1
        gating[1:low_cut] .= 0
    end
    if high_cut <= total_channels
        gating[high_cut:total_channels] .= 0
    end

    GATING_CACHE[key] = gating
    return gating
end

function get_irf_for_channels(total_channels::Int)::Matrix{Float64}
    if size(irf, 1) == total_channels
        return irf
    end

    cached = get(IRF_CHANNEL_CACHE, total_channels, nothing)
    if cached !== nothing
        return cached
    end

    new_irf = zeros(Float64, total_channels, 2)
    new_irf[:, 1] = collect(irf_bin_size:irf_bin_size:irf_bin_size * total_channels)
    ncopy = min(total_channels, size(irf, 1))
    new_irf[1:ncopy, 2] = irf[1:ncopy, 2]

    IRF_CHANNEL_CACHE[total_channels] = new_irf
    return new_irf
end

function fit_optim_options(number_of_lifetimes::Int, first_fit::Bool)
    if number_of_lifetimes == 1
        if first_fit
            return Optim.Options(outer_iterations=14, iterations=64, x_abstol=5e-7, outer_x_abstol=5e-7, f_reltol=1e-5, outer_f_reltol=1e-4, f_calls_limit=280, time_limit=0.060, allow_f_increases=true)
        end
        return Optim.Options(outer_iterations=8, iterations=32, x_abstol=5e-7, outer_x_abstol=5e-7, f_reltol=1e-5, outer_f_reltol=1e-4, f_calls_limit=140, time_limit=0.020, allow_f_increases=true)
    elseif number_of_lifetimes == 2
        if first_fit
            return Optim.Options(outer_iterations=10, iterations=40, f_reltol=1e-5, outer_f_reltol=1e-4, x_abstol=5e-7, outer_x_abstol=5e-7, f_calls_limit=220, time_limit=0.050)
        end
        return Optim.Options(outer_iterations=6, iterations=24, f_reltol=1e-5, outer_f_reltol=1e-4, x_abstol=5e-7, outer_x_abstol=5e-7, f_calls_limit=120, time_limit=0.015)
    end

    if first_fit
        return Optim.Options(outer_iterations=6, iterations=24, f_reltol=1e-4, outer_f_reltol=1e-3, x_abstol=1e-6, outer_x_abstol=1e-6, f_calls_limit=160, time_limit=0.030)
    end
    return Optim.Options(outer_iterations=4, iterations=16, f_reltol=1e-4, outer_f_reltol=1e-3, x_abstol=1e-6, outer_x_abstol=1e-6, f_calls_limit=80, time_limit=0.012)
end

function clamp_initial_point!(params_copy::Vector{Float64}, lower_bounds::Vector{Float64}, upper_bounds::Vector{Float64}; eps=1e-6)
    @inbounds for i in eachindex(params_copy)
        lo = lower_bounds[i] + eps
        hi = upper_bounds[i] - eps
        if lo > hi
            lo = lower_bounds[i]
            hi = upper_bounds[i]
        end
        params_copy[i] = clamp(params_copy[i], lo, hi)
    end
    return params_copy
end

function ensure_runtime_state!()
    if irf === nothing
        error("IRF not loaded. Define global irf = get_irf() before calling vec_to_lifetime.")
    end
    if irf_bin_size === nothing || !isfinite(irf_bin_size)
        error("irf_bin_size not initialized. Define global irf_bin_size = compute_irf_bin_size(irf).")
    end
    if tcspc_window_size === nothing || !isfinite(tcspc_window_size) || tcspc_window_size <= 0
        error("tcspc_window_size not initialized. Define global tcspc_window_size from irf.")
    end

    src_id = objectid(irf)
    if irf_cache_source_id != src_id
        empty!(IRF_CHANNEL_CACHE)
        global irf_cache_source_id = src_id
    end

    ensure_fft_plans(size(irf, 1))
    return nothing
end

# -----------------------------------------------------------------------------
# Convolution et modeles
# -----------------------------------------------------------------------------

function convolve(irf_vec::Vector{Float64}, decay::Vector{Float64}; histogram_resolution::Int64=256, tcspc_low_cut_index::Int64=13, tcspc_high_cut_index::Int64=12)
    if length(irf_vec) != length(decay)
        error("IRF and decay vectors must have same length: $(length(irf_vec)) vs $(length(decay))")
    end

    ensure_fft_plans(length(irf_vec))
    y = real.(ifft_plan * ((fft_plan * irf_vec) .* (fft_plan * decay)))

    lo = clamp(tcspc_low_cut_index, 1, histogram_resolution)
    hi = clamp(histogram_resolution - tcspc_high_cut_index, lo, histogram_resolution)
    denom = sum(y[lo:hi])
    if denom <= 0 || !isfinite(denom)
        return y
    end

    return (y / denom)::Vector{Float64}
end

function irf_shift(data_irf::Matrix{Float64}, shift)
    if isnan(shift)
        shift = 0
    end

    n = length(data_irf[:, 1])
    channel = collect(1:n)
    irf_counts = data_irf[:, 2]

    index_1 = mod1.(vec(((channel .- (floor(Int, shift) - 1)) .% n .% n) .% n) .+ 1, n)
    index_2 = mod1.(vec(((channel .- (ceil(Int, shift) - 1)) .% n .+ n) .% n) .+ 1, n)

    return vec((1 - shift + floor(shift)) .* irf_counts[index_1] + (shift - floor(shift)) .* irf_counts[index_2])::Vector{Float64}
end

function conv_irf_data(x_data::Vector{Float64}, params::Tuple{Float64, Float64, Float64}, data_irf::Matrix{Float64}; histogram_resolution::Int64=256, number_of_previous_pulses::Int64=5, laser_pulse_period::Float64=12.5, tcspc_low_cut_index::Int64=13, tcspc_high_cut_index::Int64=12)
    return convolve(irf_shift(data_irf, params[2]), exp.(-x_data ./ params[1]), histogram_resolution=histogram_resolution, tcspc_low_cut_index=tcspc_low_cut_index, tcspc_high_cut_index=tcspc_high_cut_index)
end

function conv_irf_data(x_data::Vector{Float64}, params::Tuple{Float64, Float64, Float64, Float64, Float64}, data_irf::Matrix{Float64}; histogram_resolution::Int64=256, number_of_previous_pulses::Int64=5, laser_pulse_period::Float64=12.5, tcspc_low_cut_index::Int64=13, tcspc_high_cut_index::Int64=12)
    t_1, a_1, t_2, d_0, _ = params
    irf_y_data = irf_shift(data_irf, d_0)

    exp_1 = a_1 .* exp.(-x_data ./ t_1)
    exp_2 = (1.0 - a_1) .* exp.(-x_data ./ t_2)

    for previous_pulse in 1:number_of_previous_pulses
        shift = laser_pulse_period * previous_pulse
        exp_1 .+= a_1 .* exp.(-(x_data .+ shift) ./ t_1)
        exp_2 .+= (1.0 - a_1) .* exp.(-(x_data .+ shift) ./ t_2)
    end

    return convolve(irf_y_data, exp_1 .+ exp_2, histogram_resolution=histogram_resolution, tcspc_low_cut_index=tcspc_low_cut_index, tcspc_high_cut_index=tcspc_high_cut_index)
end

function conv_irf_data(x_data::Vector{Float64}, params::Tuple{Float64, Float64, Float64, Float64, Float64, Float64, Float64, Float64}, data_irf::Matrix{Float64}; histogram_resolution::Int64=256, number_of_previous_pulses::Int64=5, laser_pulse_period::Float64=12.5, tcspc_low_cut_index::Int64=13, tcspc_high_cut_index::Int64=12)
    t_1 = params[1]
    a_1 = abs(params[2])
    t_2 = params[3]
    a_2 = abs(params[4])
    t_3 = params[5]
    a_3 = params[6]
    d_0 = params[7]

    irf_y_data = irf_shift(data_irf, d_0)

    exp_1 = a_1 .* exp.(-x_data ./ t_1)
    exp_2 = a_2 .* exp.(-x_data ./ t_2)
    exp_3 = a_3 .* exp.(-x_data ./ t_3)

    for previous_pulse in 1:number_of_previous_pulses
        shift = laser_pulse_period * previous_pulse
        exp_1 .+= a_1 .* exp.(-(x_data .+ shift) ./ t_1)
        exp_2 .+= a_2 .* exp.(-(x_data .+ shift) ./ t_2)
        exp_3 .+= a_3 .* exp.(-(x_data .+ shift) ./ t_3)
    end

    return convolve(irf_y_data, exp_1 .+ exp_2 .+ exp_3, histogram_resolution=histogram_resolution, tcspc_low_cut_index=tcspc_low_cut_index, tcspc_high_cut_index=tcspc_high_cut_index)
end

# -----------------------------------------------------------------------------
# Fit MLE
# -----------------------------------------------------------------------------

function fit_3lifetime_fraction_constraints_jl!(c, x)
    c[1] = x[2] + x[4] + x[6]
    c
end

function MLE_model_func(free_params::Vector{Float64}, fixed_params::Vector{Float64}, x_data::Vector{Float64}, y_data::Vector{Float64}, data_irf::Matrix{Float64}, gating_function::Vector{UInt8}, histogram_resolution::Int64, number_of_previous_pulses::Int64, laser_pulse_period::Float64, tcspc_low_cut_index::Int64, tcspc_high_cut_index::Int64)
    if length(fixed_params) == 3
        number_of_lifetimes = 1
    elseif length(fixed_params) == 5
        number_of_lifetimes = 2
    else
        number_of_lifetimes = 3
    end

    params = zeros(Float64, length(fixed_params))
    if length(free_params) == length(fixed_params)
        params = free_params
    else
        free_idx = 1
        for i in eachindex(fixed_params)
            if isnan(fixed_params[i])
                params[i] = free_params[free_idx]
                free_idx += 1
            else
                params[i] = fixed_params[i]
            end
        end
    end

    n_counts = float(sum(y_data))
    n_active_bins = max(1, histogram_resolution - tcspc_low_cut_index - tcspc_high_cut_index)

    if number_of_lifetimes == 1
        exp_val_c = ((1 - params[3]) .* conv_irf_data(x_data, (params[1], params[2], params[3]), data_irf, histogram_resolution=histogram_resolution, number_of_previous_pulses=number_of_previous_pulses, laser_pulse_period=laser_pulse_period, tcspc_low_cut_index=tcspc_low_cut_index, tcspc_high_cut_index=tcspc_high_cut_index) .+ params[3] / n_active_bins) .* n_counts
    elseif number_of_lifetimes == 2
        exp_val_c = ((1 - params[5]) .* conv_irf_data(x_data, (params[1], params[2], params[3], params[4], params[5]), data_irf, histogram_resolution=histogram_resolution, number_of_previous_pulses=number_of_previous_pulses, laser_pulse_period=laser_pulse_period, tcspc_low_cut_index=tcspc_low_cut_index, tcspc_high_cut_index=tcspc_high_cut_index) .+ params[5] / n_active_bins) .* n_counts
    else
        exp_val_c = ((1 - params[8]) .* conv_irf_data(x_data, (params[1], params[2], params[3], params[4], params[5], params[6], params[7], params[8]), data_irf, histogram_resolution=histogram_resolution, number_of_previous_pulses=number_of_previous_pulses, laser_pulse_period=laser_pulse_period, tcspc_low_cut_index=tcspc_low_cut_index, tcspc_high_cut_index=tcspc_high_cut_index) .+ params[8] / n_active_bins) .* n_counts
    end

    replace!(x -> smaller_or_eq_zero(x) ? 1e-256 : x, y_data)
    replace!(x -> smaller_or_eq_zero(x) ? 1e-256 : x, exp_val_c)

    dev = 2.0 / (sqrt(n_counts) * (histogram_resolution - length(params))) * sum(gating_function .* (y_data .* log.(y_data ./ exp_val_c) .- y_data .+ exp_val_c))
    if isnan(dev)
        throw(ErrorException("NaN in objective function"))
    end
    return dev::Float64
end

function find_mean_arrival_time(counts::AbstractVector{<:Real}; tcspc_high_cut_index::Int64=0)
    lim = length(counts) - tcspc_high_cut_index
    lim = max(lim, 1)
    den = sum(counts[1:lim])
    if den <= 0
        return 0.0
    end

    num = 0.0
    @inbounds for i in 1:lim
        num += i * counts[i]
    end
    return num / den
end

function lifetime_estimate(counts::AbstractVector{<:Real}; bin_size=0.039, tcspc_high_cut_index::Int64=0)
    mean_irf_arrival_time = find_mean_arrival_time(irf[:, 2], tcspc_high_cut_index=tcspc_high_cut_index)
    mean_data_arrival_time = find_mean_arrival_time(counts, tcspc_high_cut_index=tcspc_high_cut_index)
    return ((mean_data_arrival_time - mean_irf_arrival_time) * bin_size)::Float64
end

function MLE_iterative_reconvolution_jl(data_irf::Matrix{Float64}, data_xy::Vector{Vector{Float64}}; params, gating_function=ones(UInt8, 320), histogram_resolution::Int64=256, number_of_previous_pulses::Int64=5, laser_pulse_period::Float64=12.5, fixed_parameters::Vector{Float64}=Float64[NaN, NaN, NaN], tcspc_low_cut_index::Int64=13, tcspc_high_cut_index::Int64=12, use_lifetime_estimation_as_guess::Bool=true, first_fit::Bool=false)
    x_data = vec(data_xy[1])
    y_data = vec(data_xy[2]) .* gating_function
    replace!(x -> smaller_or_eq_zero(x) ? 1e-256 : x, y_data)

    number_of_lifetimes = floor(Int, (length(params) - 1) / 2)
    params_copy = copy(params)

    if all(isnotnan.(fixed_parameters))
        return fixed_parameters
    end

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

    if number_of_lifetimes in (1, 2)
        fit = Optim.optimize(x -> MLE_model_func(x, fixed_parameters, x_data, y_data, data_irf, gating_function, histogram_resolution, number_of_previous_pulses, laser_pulse_period, tcspc_low_cut_index, tcspc_high_cut_index), lower_bounds, upper_bounds, params_copy, Fminbox(LBFGS(linesearch=LineSearches.BackTracking())), fit_optim_options(number_of_lifetimes, first_fit))
    else
        lower_c, upper_c = Float64[1.0], Float64[1.0]
        constraint = TwiceDifferentiableConstraints(fit_3lifetime_fraction_constraints_jl!, lower_bounds, upper_bounds, lower_c, upper_c)
        fit = Optim.optimize(x -> MLE_model_func(x, fixed_parameters, x_data, y_data, data_irf, gating_function, histogram_resolution, number_of_previous_pulses, laser_pulse_period, tcspc_low_cut_index, tcspc_high_cut_index), constraint, params_copy, IPNewton(), fit_optim_options(number_of_lifetimes, first_fit))
    end

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
            return Float64[NaN, NaN, NaN]
        elseif number_of_lifetimes == 2
            return Float64[NaN, NaN, NaN, NaN, NaN]
        end
        return Float64[NaN, NaN, NaN, NaN, NaN, NaN, NaN, NaN]
    end

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

    return output_res::Vector{Float64}
end

# -----------------------------------------------------------------------------
# API principale
# -----------------------------------------------------------------------------

function vec_to_lifetime(x; bin_size=0.04886091184430619, hist_size_threshold=500, method="MLE", guess=[3.0, 1.0, 1e-6], laser_pulse_period=12.5, histogram_resolution=256, number_of_previous_pulses=5, tac_low_cut=5.0980392, tac_high_cut=94.901962, IRF_delay=NaN, IRF_width=NaN, IRF_cutoff=NaN, lifetime_estimation=NaN, standard_deviation_estimation=NaN, fixed_parameters=Float64[NaN, NaN, NaN], use_lifetime_estimation_as_guess::Bool=true, first_fit::Bool=false)
    ensure_runtime_state!()

    requested_channels = round(Int, laser_pulse_period * histogram_resolution / tcspc_window_size)
    total_channels = requested_channels

    if total_channels <= 0
        @warn "Computed invalid total_channels from IRF window; falling back to histogram resolution" requested_channels=total_channels tcspc_window_size=tcspc_window_size histogram_resolution=histogram_resolution
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

    ensure_fft_plans(total_channels)
    irf_local = get_irf_for_channels(total_channels)

    x_data = get_x_data(total_channels, Float64(bin_size))

    if sum(x_vec) < hist_size_threshold
        if method == "Estimate"
            return Float64[0.0], [x_data, x_vec]::Vector{Vector{Float64}}
        end
        return Float64[NaN], [x_data, x_vec]::Vector{Vector{Float64}}
    end

    if method == "Estimate"
        return Float64[lifetime_estimate(x_vec[1:histogram_resolution], bin_size=bin_size)], [x_data[1:histogram_resolution], x_vec[1:histogram_resolution]]::Vector{Vector{Float64}}
    end

    if method != "MLE"
        error("Unsupported method in simplified lifetime_analysis2.jl: $method. Supported methods: \"MLE\", \"Estimate\".")
    end

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

    tau_fit = MLE_iterative_reconvolution_jl(
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

    return tau_fit::Vector{Float64}, data_xy::Vector{Vector{Float64}}
end
