using PyCall
using FFTW
using Statistics
using NativeFileDialog
using Optim
using LineSearches

isnotnan(x) = !isnan(x)
smaller_or_eq_zero(x) = x <= 0

function get_irf(; channel=1)
    """
    Loads an .sdt IRF file. If irf_filepath.txt exists, load the IRF from this filepath, otherwise, open a file dialog create irf_filepath.txt
    """
    if isfile("docs/irf_filepath.txt")
        filepath = open(f->read(f, String), "docs/irf_filepath.txt")
        if !ispath(filepath)
            println("IRF filepath does not exist. Please select valid .sdt file.")
            # filepath = open_dialog("IRF: Choose .sdt file to open.")
            filepath = pick_file()
            open("docs/irf_filepath.txt", "w") do io
                write(io, filepath)
            end
        end
    else
        # filepath = open_dialog("IRF: Choose .sdt file to open.")
        filepath = pick_file()
        open("docs/irf_filepath.txt", "w") do io
            write(io, filepath)
        end
    end

    sdt = pyimport("sdtfile")
    file = sdt.SdtFile(filepath)
    counts = convert.(Int64, file.data[channel])
    median_irf = round(median(counts))
    counts = counts.-round(Int, median_irf)
    counts[counts .<= 0] .= 0
    times = convert.(Float64, vec(file.times[1]).*1e9)
    data = zeros(Float64, length(times), 2)::Matrix{Float64}
    data[:, 1] = times
    data[:, 2] = vec(counts)
    return data
end

function get_new_irf(; channel=1)
    println("Getting IRF file...")

    filepath = pick_file()

    open("docs/irf_filepath.txt", "w") do io
        write(io, filepath)
    end

    sdt = pyimport("sdtfile")
    file = sdt.SdtFile(filepath)
    data = convert.(Int64, file.data[channel])
    median_irf = round(median(data))
    data = data.-round(Int, 1.25*median_irf)
    data[data .<= 0] .= 0
    times = convert.(Float64, vec(file.times[1]).*1e9)
    data = [times, vec(data)]

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

function MLE_iterative_reconvolution_jl(irf::Matrix{Float64}, data_xy::Vector{Vector{Float64}}; params, gating_function=ones(UInt8, 320), histogram_resolution=256, laser_pulse_period=12.5, fixed_parameters=Float64[NaN, NaN, NaN])
    """
    Curve fitting of fluorescence decay using Maximum Likelihood Estimation
    """
    x_data = vec(data_xy[1])
    y_data = vec(data_xy[2]).*gating_function
    replace!(x->smaller_or_eq_zero(x) ? 1e-256 : x, y_data)
    irf = deepcopy(irf)

    number_of_lifetimes = floor(Int, (length(params)-1)/2)
    params_copy = deepcopy(params)

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
                        fixed_parameters[i] = upper[i]
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
        fit = optimize(x->MLE_model_func(x, x_data, y_data, irf, gating_function, histogram_resolution), lower_bounds, upper_bounds, params_copy, Fminbox(BFGS(linesearch = LineSearches.BackTracking())), Optim.Options(outer_iterations=5, x_abstol=5e-16, outer_x_abstol=5e-16, allow_f_increases=false))
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
                        fixed_parameters[i] = upper[i]
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
        #res = sp_o.minimize(MLE_model_func, params_copy, args=(x_data, y_data, irf, gating_function, histogram_resolution, number_of_previous_pulses, laser_pulse_period), bounds=bounds, method="L-BFGS-B")
        fit = optimize(x->MLE_model_func(x, x_data, y_data, irf, gating_function, histogram_resolution), lower_bounds, upper_bounds, params_copy, Fminbox(LBFGS(linesearch = LineSearches.BackTracking())), Optim.Options(outer_iterations=10, f_reltol=1e-12, outer_f_reltol=1e-2))
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
        lower_c, upper_c = Float64[1.0], Float64[1.0]
        constraint = TwiceDifferentiableConstraints(fit_3lifetime_fraction_constraints_jl!, lower_bounds, upper_bounds, lower_c, upper_c)
        #println("bounds: ", bounds)
        #res = sp_o.minimize(MLE_model_func, params_copy, args=(x_data, y_data, irf, gating_function, histogram_resolution, number_of_previous_pulses, laser_pulse_period), bounds=bounds, constraints=Dict("type"=>"eq", "fun"=>fit_3_lifetime_amplitudes_constraint), method="trust-constr", tol=1e-6, options=Dict("maxiter"=>3000))
        # fit = optimize(x->MLE_model_func(x, x_data, y_data, irf, gating_function, histogram_resolution), constraint, params_copy, IPNewton(), Optim.Options(outer_iterations=10, f_reltol=1e-8, allow_f_increases = true, successive_f_reltol = 2))
        fit = optimize(x->MLE_model_func(x, x_data, y_data, irf, gating_function, histogram_resolution), constraint, params_copy, IPNewton(), Optim.Options(outer_iterations=10, f_reltol=1e-12, outer_f_reltol=1e-2))
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
    if Optim.minimum(fit) > 5 && sum(y_data) < 50000
        println("Ignoring bad fit with optimization result: ", Optim.minimum(fit), " found values: ", res)
        if number_of_lifetimes == 1
            return Float64[NaN, NaN, NaN]
        elseif number_of_lifetimes == 2
            return Float64[NaN, NaN, NaN, NaN, NaN]
        elseif number_of_lifetimes == 3
            return Float64[NaN, NaN, NaN, NaN, NaN, NaN, NaN, NaN]
        end
    end
    if number_of_lifetimes == 2 && res[3] > res[1]
        t_1 = res[1]
        t_2 = res[3]
        res[1] = t_2
        res[3] = t_1
        res[2] = 1-res[2]
    elseif number_of_lifetimes == 3
        permutation = sortperm(res[1:2:5])
        found_params_copy = deepcopy(res)
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

function vec_to_lifetime(x::Vector{Float64}; guess=[3.0, 1.0, 1e-6], laser_pulse_period=12.5, histogram_resolution=256, tac_low_cut=5.0980392, tac_high_cut=94.901962, fixed_parameters=Float64[NaN, NaN, NaN])
    """
    Calculate fluorescence lifetime from vector of counts
    """
    total_channels = round(Int, laser_pulse_period*histogram_resolution/tcspc_window_size)
    x_data = vec(collect(irf_bin_size:irf_bin_size:total_channels*irf_bin_size))

    if total_channels != histogram_resolution
        println("Mismatch")
        global fft_plan = plan_fft(zeros(Float64, total_channels))
        global ifft_plan = plan_ifft(zeros(Float64, total_channels))
        new_irf = zeros(Float64, total_channels, 2)
        new_irf[:, 1] = collect(irf_bin_size:irf_bin_size:irf_bin_size*total_channels)
        new_irf[1:length(irf[:, 2]), 2] = irf[:, 2]
        global irf = new_irf
        append!(vec(x), zeros(total_channels-histogram_resolution))
    end
    
    if sum(x) < 100
        return Float64[NaN], [x_data, vec(x)]::Vector{Vector{Float64}}
    else
        gating_function = ones(UInt8, total_channels)
        gating_function[1:round(Int, tac_low_cut/100*histogram_resolution)] .= 0

        # tac_low_cut_index = round(Int, tac_low_cut/100*histogram_resolution)
        gating_function[round(Int, tac_high_cut/100*histogram_resolution):total_channels] .= 0
        # tcspc_high_cut_index = total_channels-round(Int, tac_high_cut/100*histogram_resolution)

        data_xy = [x_data, vec(x)]
        
        tau_fit = MLE_iterative_reconvolution_jl(irf, data_xy, params=guess, gating_function=gating_function, histogram_resolution=total_channels, fixed_parameters=fixed_parameters, laser_pulse_period=laser_pulse_period)

        return tau_fit::Vector{Float64}, data_xy::Vector{Vector{Float64}}
    end
end
