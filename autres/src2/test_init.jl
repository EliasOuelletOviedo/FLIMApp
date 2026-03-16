#!/usr/bin/env julia
"""
Minimal test - just create state and numeric context without GUI
"""

println("Loading modules...")
include("DataTypes.jl")
include("Persistence.jl")
include("Attributes.jl")
include("vec_to_lifetime.jl")
include("functions.jl")

println("Creating AppState...")
app = create_default_app_state(true)  # true for dark mode
println("  ✓ AppState created")

println("Creating AppRun...")
app_run = create_app_run()
println("  ✓ AppRun created")

println("Creating NumericContext...")
try
    irf_data = get_irf()
    irf_bin_size = get_irf_bin_size()
    tcspc_window_size = round(irf_data[end, 1] + irf_data[2, 1], sigdigits=4)
    
    histogram_resolution = 256
    fft_plan = plan_fft(zeros(Float64, histogram_resolution))
    ifft_plan = plan_ifft(zeros(Float64, histogram_resolution))
    
    num_context = NumericContext(
        irf_data,
        irf_bin_size,
        tcspc_window_size,
        fft_plan,
        ifft_plan
    )
    
    println("  ✓ NumericContext created")
    println("    IRF size: $(size(irf_data))")
    println("    IRF bin size: $irf_bin_size ns")
    println("    TCSPC window: $tcspc_window_size ns")
catch e
    println("  ✗ Failed: $e")
    rethrow(e)
end

println("\nAll initialization tests passed!")
println("Safe to run the full GUI app from REPL with: run_app()")
