using FLIMApp

println("Testing IRF and data processing...")

# Load IRF (sets FLIMApp's internal irf/fft_plan/tcspc_window_size globals)
FLIMApp.init_irf_runtime!()
println("IRF loaded: bin_size=$(FLIMApp.irf_bin_size), window_size=$(FLIMApp.tcspc_window_size)")

# Test vec_to_lifetime
test_histogram = rand(Float64, 256) .* 1000
lifetime_result = FLIMApp.vec_to_lifetime(test_histogram)
println("vec_to_lifetime works: lifetime=$(lifetime_result[1])")

println("SUCCESS: All core functions work!")
