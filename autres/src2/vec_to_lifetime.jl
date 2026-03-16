"""
vec_to_lifetime.jl - Fluorescence lifetime extraction via MLE

Provides:
- IRF loading and handling
- Lifetime estimation from histograms
- Maximum Likelihood Estimation (MLE) curve fitting
- Convolution with IRF and dispersion correction

References:
- Bajzer et al., 1991: Maximum entropy method in time-resolved fluorescence
- Maus et al., 2001: Accurate single molecule tracking
- Enderlein, 1997: Fast tracking of fluorescence photons for single molecule spectroscopy
"""

using PyCall
using FFTW
using Statistics
using NativeFileDialog
using Optim
using LineSearches

# ============================================================================
# HELPER PREDICATES
# ============================================================================

"""Check if value is not NaN"""
isnotnan(x) = !isnan(x)

"""Check if value is zero or negative"""
smaller_or_eq_zero(x) = x <= 0

# ============================================================================
# IRF LOADING
# ============================================================================

"""
    get_irf(; channel::Int=1) -> Matrix{Float64}

Load IRF (Instrument Response Function) from .sdt file.

If `docs/irf_filepath.txt` exists and points to valid file, load from there.
Otherwise, open file picker and save path to `docs/irf_filepath.txt`.

# Returns
Matrix{Float64} with shape (N, 2):
- Column 1: time in nanoseconds
- Column 2: IRF counts (baseline-subtracted)

# Notes
Requires Python with sdtfile package for reading Becker & Hickl SPC format.
"""
function get_irf(; channel::Int=1)
    filepath = ""
    
    # Check for cached IRF path
    if isfile("docs/irf_filepath.txt")
        filepath = open(f -> read(f, String), "docs/irf_filepath.txt")
        if !ispath(filepath)
            @warn "Cached IRF path invalid: $filepath, opening file picker"
            filepath = pick_file()
            open("docs/irf_filepath.txt", "w") do io
                write(io, filepath)
            end
        end
    else
        # Prompt user to select IRF file
        @info "Select IRF file (.sdt)"
        filepath = pick_file()
        open("docs/irf_filepath.txt", "w") do io
            write(io, filepath)
        end
    end

    # Load using Python sdtfile
    sdt = pyimport("sdtfile")
    file = sdt.SdtFile(filepath)
    
    # Safe conversion from Python objects
    counts_py = file.data[channel]
    times_py = file.times[1]
    
    # Convert to arrays element by element (avoids PyCall segfault)
    counts = zeros(Int64, length(counts_py))
    for i in eachindex(counts)
        counts[i] = Int64(counts_py[i])
    end
    
    times = zeros(Float64, length(times_py))
    for i in eachindex(times)
        times[i] = Float64(times_py[i]) * 1e9  # Convert to ns
    end
    
    # Baseline subtraction
    median_irf = round(median(counts))
    counts = counts .- round(Int, median_irf)
    counts[counts .<= 0] .= 0
    
    # Assemble matrix
    data = zeros(Float64, length(times), 2)
    data[:, 1] = times
    data[:, 2] = vec(counts)
    
    return data
end

"""
    get_new_irf(; channel::Int=1)

Interactively load a new IRF, replacing the cached one.

# Returns
Vector of [times, counts] as column vectors
"""
function get_new_irf(; channel::Int=1)
    @info "Getting new IRF file..."
    filepath = pick_file()

    open("docs/irf_filepath.txt", "w") do io
        write(io, filepath)
    end

    sdt = pyimport("sdtfile")
    file = sdt.SdtFile(filepath)
    
    # Safe conversion from Python objects
    data_py = file.data[channel]
    times_py = file.times[1]
    
    # Convert element-by-element to avoid PyCall segfault
    data = zeros(Int64, length(data_py))
    for i in eachindex(data)
        data[i] = Int64(data_py[i])
    end
    
    times = zeros(Float64, length(times_py))
    for i in eachindex(times)
        times[i] = Float64(times_py[i]) * 1e9  # Convert to ns
    end
    
    median_irf = round(median(data))
    data = data .- round(Int, 1.25 * median_irf)
    data[data .<= 0] .= 0
    data_out = [times, vec(data)]

    @info "IRF loaded successfully"
    return data_out
end

"""
    get_irf_bin_size(irf=nothing) -> Float64

Compute the time bin width [ns] from the IRF time axis.

# Returns
Minimum time difference between consecutive bins (in nanoseconds)
"""
function get_irf_bin_size(irf=nothing)
    # If no irf provided, load it
    if irf === nothing
        irf = get_irf()
    end
    
    h = Inf
    for i in 2:size(irf, 1)
        Δt = irf[i, 1] - irf[i-1, 1]
        if Δt < h
            h = Δt
        end
    end
    return h
end

# Overload: Accept IRF Matrix directly (for compatibility)
function get_irf_bin_size(irf::Matrix)
    h = Inf
    for i in 2:size(irf, 1)
        Δt = irf[i, 1] - irf[i-1, 1]
        if Δt < h
            h = Δt
        end
    end
    return h
end

# ============================================================================
# CONVOLUTION AND IRF SHIFT
# ============================================================================

"""
    convolve(
        irf::Vector{Float64},
        decay::Vector{Float64};
        fft_plan::FFTW.Plan,
        ifft_plan::FFTW.Plan,
        histogram_resolution::Int=256
    ) -> Vector{Float64}

Convolve IRF with exponential decay via FFT.

# Arguments
- `irf`: IRF counts (impulse response)
- `decay`: Exponential decay curve
- `fft_plan`, `ifft_plan`: Pre-planned FFT operators
- `histogram_resolution`: Number of valid bins to use for normalization

# Returns
Normalized convolved curve

# Notes
Uses FFTW plans passed from NumericContext to avoid recomputation.
Result is normalized to sum over valid time window.
"""
function convolve(
    irf::Vector{Float64},
    decay::Vector{Float64};
    fft_plan,
    ifft_plan,
    histogram_resolution::Int=256
)::Vector{Float64}
    y = real.(ifft_plan * ((fft_plan * irf) .* (fft_plan * decay)))
    norm = sum(y[13:(histogram_resolution-12)])
    
    if norm <= 0
        @warn "Convolution normalization invalid: $norm"
        return y
    end
    
    return y / norm
end

"""
    irf_shift(data_irf::Matrix{Float64}, shift::Float64) -> Vector{Float64}

Apply time shift to IRF to account for instrument delay.

# Arguments
- `data_irf`: IRF matrix with (times, counts) columns
- `shift`: Shift in bins (can be fractional)

# Returns
Shifted IRF counts using linear interpolation

# Reference
Enderlein, J. (1997). Extracting microsecond lifetimes from fluorescence 
decays in the presence of fast anisotropy decay. J. Fluorescence, 7(3), 255-257.
"""
function irf_shift(data_irf::Matrix{Float64}, shift::Float64)::Vector{Float64}
    if isnan(shift)
        shift = 0.0
    end

    n = size(data_irf, 1)
    channel = collect(1:n)
    irf_counts = data_irf[:, 2]
    
    # Circular shift with wrapping
    index_1 = vec(((channel .- (floor(Int, shift) - 1)) .% n .% n) .% n) .+ 1
    index_1[index_1 .< 1] .+= n
    index_2 = vec(((channel .- (ceil(Int, shift) - 1)) .% n .+ n) .% n) .+ 1
    index_2[index_2 .< 1] .+= n
    
    # Linear interpolation between adjacent indices
    frac = shift - floor(shift)
    return vec((1 - frac) .* irf_counts[index_1] + frac .* irf_counts[index_2])
end

# ============================================================================
# CONVOLUTION WITH DIFFERENT LIFETIME MODELS
# ============================================================================

"""
    conv_irf_data(
        x_data::Vector{Float64},
        params::NTuple{3,Float64},
        num_context::NumericContext;
        histogram_resolution::Int=256
    ) -> Vector{Float64}

Single exponential decay (1 lifetime parameter):

``\\text{decay}(x) = exp(-x / \\tau_1)``

with IRF shift `d_0`.
"""
function conv_irf_data(
    x_data::Vector{Float64},
    params::Tuple{Float64, Float64, Float64},
    num_context::NumericContext;
    histogram_resolution::Int=256
)::Vector{Float64}
    τ₁, A₁, d₀ = params
    decay = exp.(-x_data ./ τ₁)
    irf_shifted = irf_shift(num_context.irf, d₀)
    return convolve(irf_shifted, decay; 
                   fft_plan=num_context.fft_plan,
                   ifft_plan=num_context.ifft_plan,
                   histogram_resolution=histogram_resolution)
end

"""
    conv_irf_data(
        x_data::Vector{Float64},
        params::NTuple{5,Float64},
        num_context::NumericContext;
        histogram_resolution::Int=256,
        number_of_previous_pulses::Int=5,
        laser_pulse_period::Float64=12.5
    ) -> Vector{Float64}

Double exponential decay (2 lifetime parameters):

``\\text{decay}(x) = A_1 exp(-x/\\tau_1) + (1-A_1) exp(-x/\\tau_2)``

Accounts for laser pulse repetition.
"""
function conv_irf_data(
    x_data::Vector{Float64},
    params::Tuple{Float64, Float64, Float64, Float64, Float64},
    num_context::NumericContext;
    histogram_resolution::Int=256,
    number_of_previous_pulses::Int=5,
    laser_pulse_period::Float64=12.5
)::Vector{Float64}
    τ₁, A₁, τ₂, d₀, y_offset = params
    
    irf_shifted = irf_shift(num_context.irf, d₀)
    exp_1 = A₁ .* exp.(-x_data ./ τ₁)
    exp_2 = (1.0 - A₁) .* exp.(-x_data ./ τ₂)
    
    # Add contributions from previous laser pulses
    for pulse_idx in 1:number_of_previous_pulses
        t_prev = x_data .+ laser_pulse_period * pulse_idx
        exp_1 .+= A₁ .* exp.(-t_prev ./ τ₁)
        exp_2 .+= (1.0 - A₁) .* exp.(-t_prev ./ τ₂)
    end
    
    decay = exp_1 .+ exp_2
    return convolve(irf_shifted, decay;
                   fft_plan=num_context.fft_plan,
                   ifft_plan=num_context.ifft_plan,
                   histogram_resolution=histogram_resolution)
end

"""
    conv_irf_data(
        x_data::Vector{Float64},
        params::NTuple{7,Float64},
        num_context::NumericContext;
        histogram_resolution::Int=256,
        number_of_previous_pulses::Int=5,
        laser_pulse_period::Float64=12.5
    ) -> Vector{Float64}

Triple exponential decay (3 lifetime parameters):

``\\text{decay}(x) = A_1 exp(-x/\\tau_1) + A_2 exp(-x/\\tau_2) + (1-A_1-A_2) exp(-x/\\tau_3)``
"""
function conv_irf_data(
    x_data::Vector{Float64},
    params::Tuple{Float64, Float64, Float64, Float64, Float64, Float64, Float64},
    num_context::NumericContext;
    histogram_resolution::Int=256,
    number_of_previous_pulses::Int=5,
    laser_pulse_period::Float64=12.5
)::Vector{Float64}
    τ₁, A₁, τ₂, A₂, τ₃, d₀, y_offset = params
    
    irf_shifted = irf_shift(num_context.irf, d₀)
    exp_1 = abs(A₁) .* exp.(-x_data ./ τ₁)
    exp_2 = abs(A₂) .* exp.(-x_data ./ τ₂)
    exp_3 = (1 - abs(A₁) - abs(A₂)) .* exp.(-x_data ./ τ₃)
    
    for pulse_idx in 1:number_of_previous_pulses
        t_prev = x_data .+ laser_pulse_period * pulse_idx
        exp_1 .+= abs(A₁) .* exp.(-t_prev ./ τ₁)
        exp_2 .+= abs(A₂) .* exp.(-t_prev ./ τ₂)
        exp_3 .+= (1 - abs(A₁) - abs(A₂)) .* exp.(-t_prev ./ τ₃)
    end
    
    decay = exp_1 .+ exp_2 .+ exp_3
    return convolve(irf_shifted, decay;
                   fft_plan=num_context.fft_plan,
                   ifft_plan=num_context.ifft_plan,
                   histogram_resolution=histogram_resolution)
end

"""
    conv_irf_data(
        x_data::Vector{Float64},
        params::NTuple{8,Float64},
        num_context::NumericContext;
        histogram_resolution::Int=256,
        number_of_previous_pulses::Int=5,
        laser_pulse_period::Float64=12.5
    ) -> Vector{Float64}

Quadruple exponential decay (3 lifetimes + offset):

``\\text{decay}(x) = A_1 exp(-x/\\tau_1) + A_2 exp(-x/\\tau_2) + A_3 exp(-x/\\tau_3) + \\text{offset}``
"""
function conv_irf_data(
    x_data::Vector{Float64},
    params::Tuple{Float64, Float64, Float64, Float64, Float64, Float64, Float64, Float64},
    num_context::NumericContext;
    histogram_resolution::Int=256,
    number_of_previous_pulses::Int=5,
    laser_pulse_period::Float64=12.5
)::Vector{Float64}
    τ₁, A₁, τ₂, A₂, τ₃, A₃, d₀, y_offset = params
    
    irf_shifted = irf_shift(num_context.irf, d₀)
    exp_1 = abs(A₁) .* exp.(-x_data ./ τ₁)
    exp_2 = abs(A₂) .* exp.(-x_data ./ τ₂)
    exp_3 = A₃ .* exp.(-x_data ./ τ₃)
    
    for pulse_idx in 1:number_of_previous_pulses
        t_prev = x_data .+ laser_pulse_period * pulse_idx
        exp_1 .+= abs(A₁) .* exp.(-t_prev ./ τ₁)
        exp_2 .+= abs(A₂) .* exp.(-t_prev ./ τ₂)
        exp_3 .+= A₃ .* exp.(-t_prev ./ τ₃)
    end
    
    decay = exp_1 .+ exp_2 .+ exp_3
    return convolve(irf_shifted, decay;
                   fft_plan=num_context.fft_plan,
                   ifft_plan=num_context.ifft_plan,
                   histogram_resolution=histogram_resolution)
end

# ============================================================================
# MLE OPTIMIZATION
# ============================================================================

"""
    MLE_model_func(
        params::Vector{Float64},
        x_data::Vector{Float64},
        y_data::Vector{Float64},
        irf::Matrix{Float64},
        gating_function::Vector{UInt8},
        histogram_resolution::Int,
        num_context::NumericContext
    ) -> Float64

Compute Poisson deviance for MLE optimization.

Used as objective function for `optimize()`.

# References
- Bajzer et al. (1991): Maximum entropy method in time-resolved fluorescence spectroscopy
- Maus et al. (2001): Accurate single molecule tracking
"""
function MLE_model_func(
    params::Vector{Float64},
    x_data::Vector{Float64},
    y_data::Vector{Float64},
    irf::Matrix{Float64},
    gating_function::Vector{UInt8},
    histogram_resolution::Int,
    num_context::NumericContext
)::Float64
    num_lifetimes = div(length(params) - 1, 2)
    
    # Evaluate model based on number of lifetimes
    if num_lifetimes ∈ (0, 1)
        exp_val = conv_irf_data(x_data, (params[1], params[2], params[3]), num_context;
                               histogram_resolution=histogram_resolution)
        exp_val_c = gating_function .* ((1 - params[3]) .* exp_val .+ params[3]) .* float(sum(y_data))
    elseif num_lifetimes == 2
        exp_val = conv_irf_data(x_data, (params[1], params[2], params[3], params[4], params[5]), num_context;
                               histogram_resolution=histogram_resolution)
        exp_val_c = gating_function .* ((1 - params[5]) .* exp_val .+ params[5]) .* float(sum(y_data))
    elseif num_lifetimes ∈ (3, 4)
        exp_val = conv_irf_data(x_data, (params[1], params[2], params[3], params[4],
                                        params[5], params[6], params[7], params[8]), num_context;
                               histogram_resolution=histogram_resolution)
        exp_val_c = gating_function .* ((1 - params[8]) .* exp_val .+ params[8]) .* float(sum(y_data))
    else
        error("Unsupported number of lifetimes: $num_lifetimes")
    end
    
    # Prevent log(0) by clipping very small values
    replace!(x -> (x <= 0) ? 1e-256 : x, exp_val_c)
    
    # Poisson log-likelihood (deviance)
    ln_ratio = log.(y_data ./ exp_val_c)
    poisson_deviance = 2 * sum(y_data .* ln_ratio .- y_data .+ exp_val_c) / (histogram_resolution - length(params))
    
    if isnan(poisson_deviance)
        @warn "NaN deviance" params exp_val_c y_data
    end
    
    return poisson_deviance
end

"""
    find_mean_arrival_time(counts::Vector) -> Float64

Compute mean photon arrival time.
"""
function find_mean_arrival_time(counts::Vector)::Float64
    num = 0.0
    for (i, c) in enumerate(counts)
        num += i * c
    end
    return num / sum(counts)
end

"""
    lifetime_estimate(counts::Vector, irf::Matrix, irf_bin_size::Float64) -> Float64

Crude estimate of lifetime from mean arrival time shift.
"""
function lifetime_estimate(counts::Vector, irf::Matrix, irf_bin_size::Float64)::Float64
    mean_irf_time = find_mean_arrival_time(irf[:, 2])
    mean_data_time = find_mean_arrival_time(counts)
    return (mean_data_time - mean_irf_time) * irf_bin_size
end

"""
    fit_3lifetime_fraction_constraints_jl!(c::Vector, x::Vector)

Constraint: amplitude fractions must sum to 1.
"""
function fit_3lifetime_fraction_constraints_jl!(c::Vector, x::Vector)
    c[1] = x[2] + x[4] + x[6]
    return c
end

# ============================================================================
# MLE ITERATIVE RECONVOLUTION
# ============================================================================

"""
    MLE_iterative_reconvolution_jl(
        irf::Matrix{Float64},
        data_xy::Vector{Vector{Float64}};
        num_context::NumericContext,
        params::Vector{Float64},
        gating_function::Vector{UInt8}=ones(UInt8, 320),
        histogram_resolution::Int=256,
        laser_pulse_period::Float64=12.5,
        fixed_parameters::Vector{Float64}=Float64[NaN, NaN, NaN]
    ) -> Vector{Float64}

Perform MLE curve fitting to extract lifetime parameters.

# Returns
Vector of fitted parameters (τ₁, A₁, ...) or NaN if fit failed.

# References
- Bajzer et al. (1991)
- Maus et al. (2001)
"""
function MLE_iterative_reconvolution_jl(
    irf::Matrix{Float64},
    data_xy::Vector{Vector{Float64}};
    num_context::NumericContext,
    params::Vector{Float64},
    gating_function::Vector{UInt8}=ones(UInt8, 320),
    histogram_resolution::Int=256,
    laser_pulse_period::Float64=12.5,
    fixed_parameters::Vector{Float64}=Float64[NaN, NaN, NaN]
)::Vector{Float64}
    
    x_data = vec(data_xy[1])
    y_data = vec(data_xy[2]) .* gating_function
    replace!(x -> (x <= 0) ? 1e-256 : x, y_data)
    
    irf_copy = deepcopy(irf)
    num_lifetimes = div(length(params) - 1, 2)
    params_copy = deepcopy(params)
    
    # If all parameters fixed, return them
    if all(isnotnan.(fixed_parameters))
        return fixed_parameters
    end
    
    # ====== 1-lifetime model ======
    if num_lifetimes == 1
        params_copy[1] = lifetime_estimate(y_data, irf_copy, num_context.irf_bin_size)
        lower_bounds = [2 * num_context.irf_bin_size, -16.0, 0.0]
        upper_bounds = [laser_pulse_period * 2, 32.0, 1.0]
        
        # Apply fixed parameters
        for i in eachindex(fixed_parameters)
            if !isnan(fixed_parameters[i])
                fixed_parameters[i] = clamp(fixed_parameters[i], lower_bounds[i], upper_bounds[i])
                params_copy[i] = fixed_parameters[i]
                lower_bounds[i] = fixed_parameters[i] - 1e-6
                upper_bounds[i] = fixed_parameters[i] + 1e-6
            end
        end
        
        fit = optimize(
            p -> MLE_model_func(p, x_data, y_data, irf_copy, gating_function, 
                               histogram_resolution, num_context),
            lower_bounds, upper_bounds, params_copy,
            Fminbox(BFGS(linesearch=LineSearches.BackTracking())),
            Optim.Options(outer_iterations=5, x_abstol=5e-16, outer_x_abstol=5e-16,
                         allow_f_increases=false)
        )
        res = Optim.minimizer(fit)
        
        if res[1] == lower_bounds[1] || res[1] == upper_bounds[1]
            return Float64[NaN, NaN, NaN]
        end
        
    # ====== 2-lifetime model ======
    elseif num_lifetimes == 2
        lower_bounds = [2 * num_context.irf_bin_size, 0.0, 2 * num_context.irf_bin_size, -16.0, 0.0]
        upper_bounds = [laser_pulse_period * 2, 1.0, laser_pulse_period * 2, 64.0, 1.0]
        
        for i in eachindex(fixed_parameters)
            if !isnan(fixed_parameters[i])
                fixed_parameters[i] = clamp(fixed_parameters[i], lower_bounds[i], upper_bounds[i])
                params_copy[i] = fixed_parameters[i]
                lower_bounds[i] = fixed_parameters[i] - 5e-6
                upper_bounds[i] = fixed_parameters[i] + 5e-6
            end
        end
        
        fit = optimize(
            p -> MLE_model_func(p, x_data, y_data, irf_copy, gating_function,
                               histogram_resolution, num_context),
            lower_bounds, upper_bounds, params_copy,
            Fminbox(LBFGS(linesearch=LineSearches.BackTracking())),
            Optim.Options(outer_iterations=10, f_reltol=1e-12, outer_f_reltol=1e-2)
        )
        res = Optim.minimizer(fit)
        
        # Sort by lifetime
        if res[3] > res[1]
            res[1], res[3] = res[3], res[1]
            res[2] = 1 - res[2]
        end
        
    # ====== 3-4 lifetime model (with constraint) ======
    elseif num_lifetimes ∈ (3, 4)
        lower_bounds = [2 * num_context.irf_bin_size, 0.0, 2 * num_context.irf_bin_size, 0.0,
                       2 * num_context.irf_bin_size, 0.0, -16.0, 0.0]
        upper_bounds = [laser_pulse_period * 2, 1.0, laser_pulse_period * 2, 1.0,
                       laser_pulse_period * 2, 1.0, 32.0, 1.0]
        
        for i in eachindex(fixed_parameters)
            if !isnan(fixed_parameters[i])
                fixed_parameters[i] = clamp(fixed_parameters[i], lower_bounds[i], upper_bounds[i])
                params_copy[i] = fixed_parameters[i]
                lower_bounds[i] = fixed_parameters[i] - 5e-6
                upper_bounds[i] = fixed_parameters[i] + 5e-6
            end
        end
        
        constraint = TwiceDifferentiableConstraints(
            fit_3lifetime_fraction_constraints_jl!, 
            lower_bounds, upper_bounds, [1.0], [1.0]
        )
        
        fit = optimize(
            p -> MLE_model_func(p, x_data, y_data, irf_copy, gating_function,
                               histogram_resolution, num_context),
            constraint, params_copy, IPNewton(),
            Optim.Options(outer_iterations=10, f_reltol=1e-12, outer_f_reltol=1e-2)
        )
        res = Optim.minimizer(fit)
        
        # Sort lifetimes
        perm = sortperm(res[1:2:5])
        res_sorted = deepcopy(res)
        for (idx, p) in enumerate(perm)
            res_sorted[2*idx - 1] = res[2 * p - 1]
            res_sorted[2*idx] = res[2 * p]
        end
        res = res_sorted
    end
    
    # Check convergence
    if !Optim.converged(fit)
        return fill(NaN, length(params))
    end
    
    # Reject bad fits
    if Optim.minimum(fit) > 5 && sum(y_data) < 50000
        @info "Rejected poor fit (deviance=$(Optim.minimum(fit)))"
        return fill(NaN, length(params))
    end
    
    return res
end

# ============================================================================
# PUBLIC API: vec_to_lifetime
# ============================================================================

"""
    vec_to_lifetime(
        x::Vector{Float64},
        num_context::NumericContext;
        guess::Vector{Float64}=[3.0, 0.0, 1e-6],
        laser_pulse_period::Float64=12.5,
        histogram_resolution::Int=256,
        tac_low_cut::Float64=5.0980392,
        tac_high_cut::Float64=94.901962,
        fixed_parameters::Vector{Float64}=Float64[NaN, NaN, NaN]
    ) -> Tuple{Vector{Float64}, Vector{Vector{Float64}}}

Extract fluorescence lifetime from histogram via MLE fitting.

# Arguments
- `x`: Histogram (photon counts per time channel)
- `num_context`: Numeric context with IRF and FFT plans
- `guess`: Initial lifetime guess [ns]
- Other parameters: optimization settings and bounds

# Returns
Tuple of:
- `params`: Fitted lifetime parameters (or NaN if fit failed)
- `data_xy`: [x_data, x] for plotting

# Notes
If histogram has too few counts (< 100), returns NaN.
Automatically handles non-standard histogram resolutions.
"""
function vec_to_lifetime(
    x::Vector{Float64},
    num_context::NumericContext;
    guess::Vector{Float64}=[3.0, 0.0, 1e-6],
    laser_pulse_period::Float64=12.5,
    histogram_resolution::Int=256,
    tac_low_cut::Float64=5.0980392,
    tac_high_cut::Float64=94.901962,
    fixed_parameters::Vector{Float64}=Float64[NaN, NaN, NaN]
)
    
    total_channels = round(Int, laser_pulse_period * histogram_resolution / num_context.tcspc_window_size)
    x_data = collect(num_context.irf_bin_size : num_context.irf_bin_size : 
                    total_channels * num_context.irf_bin_size)
    
    # Pad histogram if resolution mismatch
    if total_channels != histogram_resolution
        @warn "Histogram resolution mismatch: expected $histogram_resolution, got $total_channels"
        if length(x) < total_channels
            x = vcat(x, zeros(Float64, total_channels - length(x)))
        end
    end
    
    # Skip if too few photons
    if sum(x) < 100
        return Float64[NaN], [x_data, vec(x)]
    end
    
    # Create gating window
    gating_function = ones(UInt8, total_channels)
    gating_function[1:round(Int, tac_low_cut / 100 * histogram_resolution)] .= 0
    gating_function[round(Int, tac_high_cut / 100 * histogram_resolution):end] .= 0
    
    # Perform MLE fitting
    tau_fit = MLE_iterative_reconvolution_jl(
        num_context.irf, [x_data, vec(x)];
        num_context=num_context,
        params=guess,
        gating_function=gating_function,
        histogram_resolution=total_channels,
        fixed_parameters=fixed_parameters,
        laser_pulse_period=laser_pulse_period
    )
    
    return tau_fit, [x_data, vec(x)]
end
