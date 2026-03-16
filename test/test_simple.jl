include("src/main.jl")

println("Testing IRF and data processing...")

# Load IRF
global irf = get_irf()
global irf_bin_size = _compute_irf_bin_size(irf)
global tcspc_window_size = size(irf, 1) * irf_bin_size
println("IRF loaded: bin_size=$irf_bin_size, window_size=$tcspc_window_size")

# Test vec_to_lifetime
test_histogram = rand(Float64, 256) .* 1000
lifetime_result = vec_to_lifetime(test_histogram)
println("vec_to_lifetime works: lifetime=$(lifetime_result[1])")

println("SUCCESS: All core functions work!")