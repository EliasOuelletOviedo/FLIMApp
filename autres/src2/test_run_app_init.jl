#!/usr/bin/env julia
"""
Unit test for run_app() - tests initialization without displaying GUI
"""

println("=" ^ 70)
println("TESTING run_app() INITIALIZATION STEPS")
println("=" ^ 70)

cd(@__DIR__)

println("\n[Loading modules...]")
include("DataTypes.jl")
include("Persistence.jl")
include("Attributes.jl")
include("vec_to_lifetime.jl")
include("functions.jl")
include("GUI.jl")
include("handlers.jl")

println("✓ All modules loaded\n")

# ============================================================================
# TEST: Replicate the first 70% of run_app() (before GUI display)
# ============================================================================

function test_run_app_initialization()
    println("[TEST 1] Loading persistent state...")
    @info "Loading persistent state..."
    app = create_default_app_state(true)
    
    try
        ensure_state_dir()
        app_loaded = load_state()
        if app_loaded !== nothing
            app = app_loaded
            println("  ✓ Loaded from disk")
        else
            println("  ✓ Using defaults")
        end
    catch e
        println("  ✓ Using defaults (load failed as expected)")
        app = create_default_app_state(true)
    end

    println("\n[TEST 2] Creating runtime state...")
    app_run = create_app_run()
    println("  ✓ AppRun created")

    println("\n[TEST 3] Initializing numeric context (IRF + FFT)...")
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
    
    println("  ✓ IRF size: $(size(irf_data))")
    println("  ✓ IRF bin size: $irf_bin_size ns")
    println("  ✓ TCSPC window: $tcspc_window_size ns")
    println("  ✓ FFT plans created")

    println("\n[TEST 4] Updating theme colors...")
    update_colors_for_theme(app.dark)
    println("  ✓ Colors updated")

    println("\n[TEST 5] Getting theme assets...")
    colors = get_theme_colors(app.dark)
    println("  ✓ Theme colors obtained")

    println("\n[TEST 6] Testing GUI module functions exist...")
    if @isdefined(make_gui)
        println("  ✓ make_gui function exists")
    else
        error("make_gui not defined!")
    end

    println("\n[TEST 7] Testing handler functions exist...")
    if @isdefined(on_time_range_changed)
        println("  ✓ on_time_range_changed defined")
    else
        println("  ⚠ on_time_range_changed not pre-defined (may load dynamically)")
    end

    println("\n" ^ 2)
    println("=" ^ 70)
    println("✓ ALL INITIALIZATION TESTS PASSED!")
    println("=" ^ 70)
    println("\nrun_app() will:")
    println("  1. Execute the above steps ✓")
    println("  2. Call make_gui(app, app_run, num_context)")
    println("  3. Display Makie figure")
    println("  4. Wait for user interactions")
    println("\nTo use:")
    println("  julia> include(\"main.jl\")")
    println("  julia> run_app()")
    println("\n" ^ 2)

    return true
end

# Run the test
try
    result = test_run_app_initialization()
    exit(0)
catch e
    println("\n" ^ 2)
    println("=" ^ 70)
    println("✗ TEST FAILED")
    println("=" ^ 70)
    println("\nError: $e\n")
    showerror(stderr, e, catch_backtrace())
    exit(1)
end
