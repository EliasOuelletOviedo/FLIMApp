"""
lifetime_analysis.jl

Fluorescence lifetime fitting algorithms and IRF (Instrument Response Function) management.

This module implements:
- IRF file loading and manipulation
- Convolution of IRF with decay models
- Maximum Likelihood Estimation (MLE) fitting for fluorescence decay
- Multi-exponential decay component fitting (1, 2, 3+ lifetimes)

References:
- Bajzer et al. 1991 (MLE methodology)
- Maus et al. 2001 (MLE for FLIM)
- Enderlein, 1997 (IRF shift/delay compensation)
"""

using FFTW
using Statistics
using NativeFileDialog
using Optim
using LineSearches
using ZipFile

const X_DATA_CACHE = Dict{Int, Vector{Float64}}()
const GATING_CACHE = Dict{Tuple{Int, Int, Int}, Vector{UInt8}}()
const IRF_CHANNEL_CACHE = Dict{Int, Matrix{Float64}}()

function reshape_to_vec_no_python(file::Vector{UInt16}, num_rows::Int)::Vector{Float64}
    return sum(reshape(file, (num_rows, :)), dims=2)[:, 1]
end

function open_sdt_file_no_python(filepath::String)::Tuple{Vector{UInt16}, Int, Float32}
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
            vector = read(io)
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

            vector = reshape_to_vec_no_python(reinterpret(UInt16, file_data), histogram_resolution)
            return convert.(UInt16, vector), histogram_resolution, time
        end
    end
end

"""
    ensure_fft_plans(size::Int)

Ensure FFT plans are created for the given size.
Recreates plans if needed.
"""
function ensure_fft_plans(size::Int)
    if fft_plan_size != size
        global fft_plan = plan_fft(zeros(Float64, size))
        global ifft_plan = plan_ifft(zeros(Float64, size))
        global fft_plan_size = size
    end
end

# Helper predicates
isnotnan(x) = !isnan(x)
smaller_or_eq_zero(x) = x <= 0

# Global state for FFT planning and IRF (initialized when IRF is loaded)
var"fft_plan" = plan_fft(zeros(Float64, 256))  # Initialize with default size
var"ifft_plan" = plan_ifft(zeros(Float64, 256))  # Initialize with default size
var"fft_plan_size" = 256  # Track the current plan size
var"irf" = nothing
var"irf_bin_size" = nothing
var"tcspc_window_size" = nothing

function get_x_data(total_channels::Int)::Vector{Float64}
    cached = get(X_DATA_CACHE, total_channels, nothing)
    if cached !== nothing
        return cached
    end

    x_data = collect(irf_bin_size:irf_bin_size:total_channels*irf_bin_size)
    X_DATA_CACHE[total_channels] = x_data
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
    new_irf[:, 1] = collect(irf_bin_size:irf_bin_size:irf_bin_size*total_channels)
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
    else
        if first_fit
            return Optim.Options(outer_iterations=6, iterations=24, f_reltol=1e-4, outer_f_reltol=1e-3, x_abstol=1e-6, outer_x_abstol=1e-6, f_calls_limit=160, time_limit=0.030)
        end
        return Optim.Options(outer_iterations=4, iterations=16, f_reltol=1e-4, outer_f_reltol=1e-3, x_abstol=1e-6, outer_x_abstol=1e-6, f_calls_limit=80, time_limit=0.012)
    end
end

# =============================================================================
# HELPER: IRF BIN SIZE CALCULATION
# =============================================================================

"""
    compute_irf_bin_size(irf_data::Matrix{Float64})::Float64

Compute the bin size (time resolution) from IRF data.

Returns the minimum time difference between consecutive bins.

Args:
- `irf_data::Matrix{Float64}` - IRF matrix with shape (n_bins, 2)

Returns:
- Float64 - Time magnitude per bin in nanoseconds
"""
function compute_irf_bin_size(irf_data::Matrix{Float64})::Float64
    h = Inf
    for i in 2:size(irf_data, 1)
        Δt = irf_data[i, 1] - irf_data[i-1, 1]
        if 0 < Δt < h
            h = Δt
        end
    end
    return h
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

    # Some SDT variants expose a per-frame duration in this header field.
    # Fall back to one laser period when this produces non-physical TCSPC windows.
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
        filepath = open(f->read(f, String), "docs/irf_filepath.txt")
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

function get_new_irf(; channel=1)
    println("Getting IRF file...")

    filepath = pick_file()

    open("docs/irf_filepath.txt", "w") do io
        write(io, filepath)
    end

    data = irf_from_sdt_without_python(filepath; channel=channel)

    println("Done")
    println()

    return data
end

function get_irf_bin_size()
    """
    Gets the bin size in nanoseconds from the IRF.
    """
    irf = get_irf()
    h = Inf::Float64
    for i in 1:1:length(irf[:, 1])
        if i == 1
            continue
        end
        if irf[i, 1]-irf[i-1, 1] < h
            h = irf[i, 1]-irf[i-1, 1]
        end
    end
    return h
end

function convolve(irf::Vector{Float64}, decay::Vector{Float64}; histogram_resolution=256::Int64)
    """
    Convolves the IRF with fluorescence decay
    """
    # Ensure FFT plans match vector sizes
    if length(irf) != length(decay)
        error("IRF and decay vectors must have same length: $(length(irf)) vs $(length(decay))")
    end
    
    n = length(irf)
    ensure_fft_plans(n)  # Ensure plans are ready for this size
    
    y = real.(ifft_plan*((fft_plan*irf) .* (fft_plan*decay)))

    return (y/sum(y[13:histogram_resolution-12]))::Vector{Float64}
end

function irf_shift(data_irf::Matrix{Float64}, shift)
    """
    Translation of the IRF to account for systematic delays in instrument
    REF: Enderlein, 1997
    """
    if isnan(shift)
        shift = 0
    end

    n = length(data_irf[:, 1])
    channel = collect(1:1:length(data_irf[:, 1]))
    irf_counts = data_irf[:, 2]
    
    index_1 = vec( ((channel .- (floor(Int, shift) - 1)).% n .% n).% n) .+ 1
    index_1[index_1 .< 1] .+= length(index_1)
    index_2 = vec(((channel .- (ceil(Int, shift) - 1)).% n .+ n).% n) .+ 1
    index_2[index_2 .< 1] .+= length(index_2)
    
    return vec((1 - shift + floor(shift)) .* irf_counts[index_1] + (shift - floor(shift)) .* irf_counts[index_2])::Vector{Float64}
end

function conv_irf_data(x_data::Vector{Float64}, params::Tuple{Float64, Float64, Float64}, irf::Matrix{Float64}; histogram_resolution=256::Int64)
    return convolve(irf_shift(irf, params[2]), exp.(-x_data./params[1]), histogram_resolution=histogram_resolution)
end

function conv_irf_data(x_data::Vector{Float64}, params::Tuple{Float64, Float64, Float64, Float64, Float64}, irf::Matrix{Float64}; histogram_resolution=256::Int64, number_of_previous_pulses=5::Int64, laser_pulse_period=12.5::Float64, tcspc_low_cut_index=13::Int64, tcspc_high_cut_index=12::Int64)
    #t_1 = params[1]
    #A_1 = params[2]
    #t_2 = params[3]
    #d_0 = params[4]
    #y_offset = params[5]
    #data = deepcopy(x_data)
    irf_y_data = irf_shift(irf, params[4])
    exp_1 = params[2].*exp.(-x_data./params[1])
    exp_2 = (1.0-params[2]).*exp.(-x_data./params[3])
    for previous_pulse in 1:1:number_of_previous_pulses
        exp_1 += params[2].*exp.(-(x_data.+laser_pulse_period.*previous_pulse)./params[1])
        exp_2 += (1.0-params[2]).*exp.(-(x_data.+laser_pulse_period.*previous_pulse)./params[3])
    end
    return convolve(irf_y_data, (exp_1.+exp_2), histogram_resolution=histogram_resolution)
    #return decay::Vector{Float64}
end

function conv_irf_data(x_data::Vector{Float64}, params::Tuple{Float64, Float64, Float64, Float64, Float64, Float64, Float64}, irf::Matrix{Float64}; histogram_resolution=256::Int64, number_of_previous_pulses=5::Int64, laser_pulse_period=12.5::Float64, tcspc_low_cut_index=13::Int64, tcspc_high_cut_index=12::Int64)
    t_1 = params[1]
    A_1 = abs(params[2])
    t_2 = params[3]
    A_2 = abs(params[4])
    t_3 = params[5]
    d_0 = params[6]
    y_offset = params[7]
    #data = deepcopy(x_data)
    irf_y_data = irf_shift(irf, d_0)
    exp_1 = A_1.*exp.(-x_data./t_1)
    exp_2 = A_2.*exp.(-x_data./t_2)
    exp_3 = (1-A_1-A_2).*exp.(-x_data./t_3)
    for previous_pulse in 1:1:number_of_previous_pulses
        exp_1 += A_1.*exp.(-(x_data.+laser_pulse_period.*previous_pulse)./t_1)
        exp_2 += A_2.*exp.(-(x_data.+laser_pulse_period.*previous_pulse)./t_2)
        exp_3 += (1-A_1-A_2).*exp.(-(x_data.+laser_pulse_period.*previous_pulse)./t_3)
    end
    return convolve(irf_y_data, (exp_1.+exp_2.+exp_3), histogram_resolution=histogram_resolution)
    #return decay::Vector{Float64}
end

function conv_irf_data(x_data::Vector{Float64}, params::Tuple{Float64, Float64, Float64, Float64, Float64, Float64, Float64, Float64}, irf::Matrix{Float64}; histogram_resolution=256::Int64, number_of_previous_pulses=5::Int64, laser_pulse_period=12.5::Float64, tcspc_low_cut_index=13::Int64, tcspc_high_cut_index=12::Int64)
    t_1 = params[1]
    A_1 = abs(params[2])
    t_2 = params[3]
    A_2 = abs(params[4])
    t_3 = params[5]
    A_3 = params[6]
    d_0 = params[7]
    y_offset = params[8]
    #data = deepcopy(x_data)
    irf_y_data = irf_shift(irf, d_0)
    exp_1 = A_1.*exp.(-x_data./t_1)
    exp_2 = A_2.*exp.(-x_data./t_2)
    exp_3 = A_3.*exp.(-x_data./t_3)
    for previous_pulse in 1:1:number_of_previous_pulses
        exp_1 += A_1.*exp.(-(x_data.+laser_pulse_period.*previous_pulse)./t_1)
        exp_2 += A_2.*exp.(-(x_data.+laser_pulse_period.*previous_pulse)./t_2)
        exp_3 += A_3.*exp.(-(x_data.+laser_pulse_period.*previous_pulse)./t_3)
    end
    return convolve(irf_y_data, (exp_1.+exp_2.+exp_3), histogram_resolution=histogram_resolution)
    #return decay::Vector{Float64}
end

function MLE_model_func(params::Vector{Float64}, x_data::Vector{Float64}, y_data::Vector{Float64}, irf::Matrix{Float64}, gating_function::Vector{UInt8}, histogram_resolution::Int64)
    """
    Model function for MLE optimizer.
    # REF: Bajzer, et al. 1991
    # REF: Maus, et al. 2001
    """
    number_of_lifetimes = round(Int, (length(params)-1)/2)
    poisson_deviance = 0.0::Float64

    # exp_val_c = gating_function.*((1-params[3]).*conv_irf_data(x_data, (params[1], params[2], params[3]), irf, histogram_resolution=histogram_resolution).+params[3]).*float(sum(y_data))

    if number_of_lifetimes == 1 || number_of_lifetimes == 0
        exp_val_c = gating_function.*((1-params[3]).*conv_irf_data(x_data, (params[1], params[2], params[3]), irf, histogram_resolution=histogram_resolution).+params[3]).*float(sum(y_data))
    elseif number_of_lifetimes == 2
        exp_val_c = gating_function.*((1-params[5]).*conv_irf_data(x_data, (params[1], params[2], params[3], params[4], params[5]), irf, histogram_resolution=histogram_resolution).+params[5]).*float(sum(y_data))
    elseif number_of_lifetimes == 3 || number_of_lifetimes == 4
        exp_val_c = gating_function.*((1-params[8]).*conv_irf_data(x_data, (params[1], params[2], params[3], params[4], params[5], params[6], params[7], params[8]), irf, histogram_resolution=histogram_resolution).+params[8]).*float(sum(y_data))
    end

    replace!(x->smaller_or_eq_zero(x) ? 1e-256 : x, exp_val_c)
    ln_data = log.(y_data./exp_val_c)
    poisson_deviance = 2*sum(y_data.*ln_data.-y_data.+exp_val_c)/(histogram_resolution-length(params))

    if isnan(poisson_deviance)
        println(params, " ", poisson_deviance)
        println(exp_val_c)
        println(y_data)
    end

    return poisson_deviance::Float64
end

function find_mean_arrival_time(counts)
    num = 0.0
    for (i, c) in enumerate(counts)
        num += i*c
    end
    return num/sum(counts)
end

function lifetime_estimate(counts)
    mean_irf_arrival_time = find_mean_arrival_time(irf[:, 2])
    mean_data_arrival_time = find_mean_arrival_time(counts)
    return (mean_data_arrival_time-mean_irf_arrival_time)*irf_bin_size
end

function fit_3lifetime_fraction_constraints_jl!(c, x)
    c[1] = x[2]+x[4]+x[6]
    c
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

function MLE_iterative_reconvolution_jl(irf::Matrix{Float64}, data_xy::Vector{Vector{Float64}}; params, gating_function=ones(UInt8, 320), histogram_resolution=256, laser_pulse_period=12.5, fixed_parameters=Float64[NaN, NaN, NaN], first_fit::Bool=false)
    """
    Curve fitting of fluorescence decay using Maximum Likelihood Estimation
    """
    x_data = vec(data_xy[1])
    y_data = copy(vec(data_xy[2]))
    @inbounds @simd for i in eachindex(y_data)
        y_data[i] *= gating_function[i]
        if y_data[i] <= 0
            y_data[i] = 1e-256
        end
    end

    number_of_lifetimes = floor(Int, (length(params)-1)/2)
    params_copy = copy(params)

    if all(isnotnan.(fixed_parameters))
        return fixed_parameters
    end

    if number_of_lifetimes == 1
        params_copy[1] = lifetime_estimate(y_data)
        lower_bounds = Float64[2*irf_bin_size, -16.0, 0.0]
        upper_bounds = Float64[laser_pulse_period*2, 32.0, 1.0]

        if any(isnotnan.(fixed_parameters))
            for i in 1:1:length(fixed_parameters)
                if !isnan(fixed_parameters[i])
                    if fixed_parameters[i] < lower_bounds[i]
                        fixed_parameters[i] = lower_bounds[i]
                    elseif fixed_parameters[i] > upper_bounds[i]
                        fixed_parameters[i] = upper_bounds[i]
                    end
                    params_copy[i] = fixed_parameters[i]
                    if fixed_parameters[i]-1e-6 >= lower_bounds[i]
                        lower_bounds[i] = fixed_parameters[i]-1e-6
                    end
                    if fixed_parameters[i]+1e-6 <= upper_bounds[i]
                        upper_bounds[i] = fixed_parameters[i]+1e-6
                    end
                end
            end
        end
        clamp_initial_point!(params_copy, lower_bounds, upper_bounds)
        fit = optimize(x->MLE_model_func(x, x_data, y_data, irf, gating_function, histogram_resolution), lower_bounds, upper_bounds, params_copy, Fminbox(LBFGS(linesearch = LineSearches.BackTracking())), fit_optim_options(number_of_lifetimes, first_fit))
        res = Optim.minimizer(fit)

        if res[1] == lower_bounds[1] || res[1] == upper_bounds[1]
            return Float64[NaN, NaN, NaN]
        end
    elseif number_of_lifetimes == 2
        bounds = [(2*irf_bin_size, laser_pulse_period*2), (0.0, 1.0), (2*irf_bin_size, laser_pulse_period*2), (-16, 32), (0.0, 1.0)]
        lower_bounds = Float64[2*irf_bin_size, 0.0, 2*irf_bin_size, -16.0, 0.0]
        upper_bounds = Float64[laser_pulse_period*2, 1.0, laser_pulse_period*2, 64.0, 1.0]
        if any(isnotnan.(fixed_parameters))
            for i in 1:1:length(fixed_parameters)
                if !isnan(fixed_parameters[i])
                    if fixed_parameters[i] < lower_bounds[i]
                        fixed_parameters[i] = lower_bounds[i]
                    elseif fixed_parameters[i] > upper_bounds[i]
                        fixed_parameters[i] = upper_bounds[i]
                    end
                    params_copy[i] = fixed_parameters[i]
                    if fixed_parameters[i]-5e-6 >= lower_bounds[i]
                        lower_bounds[i] = fixed_parameters[i]-5e-6
                    end
                    if fixed_parameters[i]+5e-6 <= upper_bounds[i]
                        upper_bounds[i] = fixed_parameters[i]+5e-6
                    end
                end
            end
        end
        clamp_initial_point!(params_copy, lower_bounds, upper_bounds)
        #res = sp_o.minimize(MLE_model_func, params_copy, args=(x_data, y_data, irf, gating_function, histogram_resolution, number_of_previous_pulses, laser_pulse_period), bounds=bounds, method="L-BFGS-B")
        fit = optimize(x->MLE_model_func(x, x_data, y_data, irf, gating_function, histogram_resolution), lower_bounds, upper_bounds, params_copy, Fminbox(LBFGS(linesearch = LineSearches.BackTracking())), fit_optim_options(number_of_lifetimes, first_fit))
        res = Optim.minimizer(fit)
    elseif number_of_lifetimes == 3 || number_of_lifetimes == 4
        #push!(params_copy, 0.25)
        #bounds = Tuple{Float64, Float64}[(2*irf_bin_size, laser_pulse_period*2), (0.0, 1.0), (2*irf_bin_size, laser_pulse_period*2), (0.0, 1.0), (2*irf_bin_size, laser_pulse_period*2), (-30.0, float(histogram_resolution)), (0.0, 1.0), (0.0, 1.0)]
        lower_bounds = Float64[2*irf_bin_size, 0.0, 2*irf_bin_size, 0.0, 2*irf_bin_size, 0.0, -16.0, 0.0]
        upper_bounds = Float64[laser_pulse_period*2, 1.0, laser_pulse_period*2, 1.0, laser_pulse_period*2, 1.0, 32.0, 1.0]
        if any(isnotnan.(fixed_parameters))
            for i in 1:1:length(fixed_parameters)
                if !isnan(fixed_parameters[i])
                    if fixed_parameters[i] < lower_bounds[i]
                        fixed_parameters[i] = lower_bounds[i]+5e-6
                    elseif fixed_parameters[i] > upper_bounds[i]
                        fixed_parameters[i] = upper_bounds[i]-5e-6
                    end
                    params_copy[i] = fixed_parameters[i]
                    if fixed_parameters[i]-5e-6 >= lower_bounds[i]
                        lower_bounds[i] = fixed_parameters[i]-5e-6
                    end
                    if fixed_parameters[i]+5e-6 <= upper_bounds[i]
                        upper_bounds[i] = fixed_parameters[i]+5e-6
                    end
                end
            end
        end
        clamp_initial_point!(params_copy, lower_bounds, upper_bounds)
        lower_c, upper_c = Float64[1.0], Float64[1.0]
        constraint = TwiceDifferentiableConstraints(fit_3lifetime_fraction_constraints_jl!, lower_bounds, upper_bounds, lower_c, upper_c)
        #println("bounds: ", bounds)
        #res = sp_o.minimize(MLE_model_func, params_copy, args=(x_data, y_data, irf, gating_function, histogram_resolution, number_of_previous_pulses, laser_pulse_period), bounds=bounds, constraints=Dict("type"=>"eq", "fun"=>fit_3_lifetime_amplitudes_constraint), method="trust-constr", tol=1e-6, options=Dict("maxiter"=>3000))
        # fit = optimize(x->MLE_model_func(x, x_data, y_data, irf, gating_function, histogram_resolution), constraint, params_copy, IPNewton(), Optim.Options(outer_iterations=10, f_reltol=1e-8, allow_f_increases = true, successive_f_reltol = 2))
        fit = optimize(x->MLE_model_func(x, x_data, y_data, irf, gating_function, histogram_resolution), constraint, params_copy, IPNewton(), fit_optim_options(number_of_lifetimes, first_fit))
        res = Optim.minimizer(fit)
        #println(res)
    end
    #println(res["success"], " ", res)
    if !Optim.converged(fit)
        if number_of_lifetimes == 1
            return Float64[NaN, NaN, NaN]
        elseif number_of_lifetimes == 2
            return Float64[NaN, NaN, NaN, NaN, NaN]
        elseif number_of_lifetimes == 3
            return Float64[NaN, NaN, NaN, NaN, NaN, NaN, NaN]
        end
    end
    #fit = conv_irf_data(x_data, res["x"])
    #chi2 = sum((y_data.-fit).^2 ./ (histogram_resolution.*y_data.+1))
    #println(chi2)
    #if chi2 > 3
    # if Optim.minimum(fit) > 5 && sum(y_data) < 50000
    #     println("Ignoring bad fit with optimization result: ", Optim.minimum(fit), " found values: ", res)
    #     if number_of_lifetimes == 1
    #         return Float64[NaN, NaN, NaN]
    #     elseif number_of_lifetimes == 2
    #         return Float64[NaN, NaN, NaN, NaN, NaN]
    #     elseif number_of_lifetimes == 3
    #         return Float64[NaN, NaN, NaN, NaN, NaN, NaN, NaN, NaN]
    #     end
    # end
    if number_of_lifetimes == 2 && res[3] > res[1]
        t_1 = res[1]
        t_2 = res[3]
        res[1] = t_2
        res[3] = t_1
        res[2] = 1-res[2]
    elseif number_of_lifetimes == 3
        permutation = sortperm(res[1:2:5])
        found_params_copy = copy(res)
        adjusted_permutation = zeros(Int64, 3)
        for (index, perm_value) in enumerate(permutation)
            if perm_value == 1
                adjusted_permutation[index] = 1
            elseif perm_value == 2
                adjusted_permutation[index] = 3
            else
                adjusted_permutation[index] = 5
            end
        end
        amplitudes = [found_params_copy[2], found_params_copy[4], found_params_copy[6]]
        res[1] = found_params_copy[adjusted_permutation[1]]
        res[2] = amplitudes[permutation[1]]
        res[3] = found_params_copy[adjusted_permutation[2]]
        res[4] = amplitudes[permutation[2]]
        res[5] = found_params_copy[adjusted_permutation[3]]
        res[6] = amplitudes[permutation[3]]
    end

    return res::Vector{Float64}
end

function vec_to_lifetime(x::Vector{Float64}; guess=[3.0, 1.0, 1e-6], laser_pulse_period=12.5, histogram_resolution=256, tac_low_cut=5.0980392, tac_high_cut=94.901962, fixed_parameters=Float64[NaN, NaN, NaN], first_fit::Bool=false)
    """
    Calculate fluorescence lifetime from vector of counts
    """
    # Safety check - ensure IRF is loaded
    if tcspc_window_size === nothing
        error("IRF not loaded: tcspc_window_size is nothing. Cannot perform lifetime fitting.")
    end
    
    # Ensure tcspc_window_size is a valid number
    if !isfinite(tcspc_window_size) || tcspc_window_size <= 0
        error("Invalid tcspc_window_size: $tcspc_window_size. IRF may not be loaded correctly.")
    end
    
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

    x_data = get_x_data(total_channels)
    irf_local = get_irf_for_channels(total_channels)
    
    if sum(x) < 100
        return Float64[NaN], [x_data, vec(x)]::Vector{Vector{Float64}}
    else
        low_cut_idx = round(Int, tac_low_cut / 100 * total_channels)
        high_cut_idx = round(Int, tac_high_cut / 100 * total_channels)
        gating_function = get_gating_function(total_channels, low_cut_idx, high_cut_idx)
        # tcspc_high_cut_index = total_channels-round(Int, tac_high_cut/100*histogram_resolution)

        data_xy = [x_data, copy(x)]
        
        tau_fit = MLE_iterative_reconvolution_jl(irf_local, data_xy, params=guess, gating_function=gating_function, histogram_resolution=total_channels, fixed_parameters=fixed_parameters, laser_pulse_period=laser_pulse_period, first_fit=first_fit)

        return tau_fit::Vector{Float64}, data_xy::Vector{Vector{Float64}}
    end
end
