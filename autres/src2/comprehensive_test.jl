#!/usr/bin/env julia
"""
Comprehensive test of main.jl and all modules
Tests every step of run_app() without displaying GUI
"""

println("=" ^ 70)
println("COMPREHENSIVE TEST OF src2/main.jl")
println("=" ^ 70)

# Change to src2 directory
cd(@__DIR__)

# Test 1: Include all modules
println("\n[TEST 1] Loading all modules...")
try
    include("DataTypes.jl")
    println("  ✓ DataTypes.jl loaded")
    include("Persistence.jl")
    println("  ✓ Persistence.jl loaded")
    include("Attributes.jl")
    println("  ✓ Attributes.jl loaded")
    include("vec_to_lifetime.jl")
    println("  ✓ vec_to_lifetime.jl loaded")
    include("functions.jl")
    println("  ✓ functions.jl loaded")
    include("GUI.jl")
    println("  ✓ GUI.jl loaded")
    include("handlers.jl")
    println("  ✓ handlers.jl loaded")
catch e
    println("  ✗ FAILED: $e")
    rethrow(e)
end

# Main test function to avoid scope issues
function run_tests()
    # Test 2: Test each initialization step
    println("\n[TEST 2] Testing initialization steps...")

    # 2a: Create default AppState
    print("  Creating default AppState... ")
    app = create_default_app_state(true)
    println("✓")

    # 2b: Load or create state
    print("  Attempting to load persistent state... ")
    try
        ensure_state_dir()
        app_loaded = load_state()
        if app_loaded !== nothing
            app = app_loaded
            println("✓ (loaded from disk)")
        else
            println("✓ (no previous state, using defaults)")
        end
    catch e
        println("✓ (load failed as expected, using defaults)")
        app = create_default_app_state(true)
    end

    # 2c: Create AppRun
    print("  Creating AppRun... ")
    app_run = create_app_run()
    println("✓")

    # 2d: Load IRF
    print("  Loading IRF file... ")
    irf_data = get_irf()
    println("✓ (size: $(size(irf_data)))")

    # 2e: Get IRF bin size
    print("  Getting IRF bin size... ")
    irf_bin_size = get_irf_bin_size()
    println("✓ ($(irf_bin_size) ns)")

    # 2f: Calculate TCSPC window
    print("  Calculating TCSPC window... ")
    tcspc_window_size = round(irf_data[end, 1] + irf_data[2, 1], sigdigits=4)
    println("✓ ($(tcspc_window_size) ns)")

    # 2g: Create FFT plans
    print("  Creating FFT plans... ")
    histogram_resolution = 256
    fft_plan = plan_fft(zeros(Float64, histogram_resolution))
    ifft_plan = plan_ifft(zeros(Float64, histogram_resolution))
    println("✓")

    # 2h: Create NumericContext
    print("  Creating NumericContext... ")
    num_context = NumericContext(
        irf_data,
        irf_bin_size,
        tcspc_window_size,
        fft_plan,
        ifft_plan
    )
    println("✓")

    # 2i: Update colors
    print("  Updating theme colors... ")
    update_colors_for_theme(app.dark)
    println("✓")

    # 2j: Get theme colors
    print("  Getting theme colors... ")
    colors = get_theme_colors(app.dark)
    println("✓")

    # Test 3: Observable functionality
    println("\n[TEST 3] Testing Observable functionality...")
    print("  Observable histogram update... ")
    test_hist = Observable(zeros(Float64, 256))
    test_hist[] = rand(Float64, 256)
    println("✓")

    print("  Observable vcat pattern (used in GUI)... ")
    test_obs = Observable(Float64[])
    test_obs[] = vcat(test_obs[], [1.0, 2.0, 3.0])
    if test_obs[] == [1.0, 2.0, 3.0]
        println("✓")
    else
        println("✗ vcat didn't work correctly")
        error("Observable vcat failed")
    end

    # Test 4: Verify critical bug fixes
    println("\n[TEST 4] Verifying critical bug fixes...")

    print("  Observable assignment triggers callbacks... ")
    obs = Observable(Float64[1.0])
    callback_called = Ref(false)
    on(obs) do x
        callback_called[] = true
    end
    callback_called[] = false
    obs[] = vcat(obs[], [2.0])
    if callback_called[]
        println("✓ (CORRECT: triggers callback)")
    else
        println("✗ FAILED: callback not triggered")
        error("Observable assignment not triggering callback")
    end

    # Test 5: Serialization
    println("\n[TEST 5] Testing state persistence...")

    print("  Save state atomically... ")
    test_state = create_default_app_state(true)
    test_path = tempname() * ".jls"
    save_state_atomic(test_state; path=test_path)
    if isfile(test_path)
        println("✓")
        rm(test_path)
    else
        println("✗ (file not created)")
        error("State file not created")
    end

    print("  Load state with version handling... ")
    test_state = create_default_app_state(true)
    test_path = tempname() * ".jls"
    save_state_atomic(test_state; path=test_path)
    loaded_state = load_state(test_path)
    if loaded_state !== nothing && loaded_state.dark == test_state.dark
        println("✓")
        rm(test_path)
    else
        println("✗ (state mismatch or loading failed)")
        error("State load/save mismatch")
    end

    return true
end

# Run the tests
try
    result = run_tests()
    
    println("\n" ^ 2)
    println("=" ^ 70)
    println("✓ ALL TESTS PASSED!")
    println("=" ^ 70)
    println("\nThe application is ready to run.")
    println("\nTo start the app:")
    println("  1. cd(\"/Users/eliasouellet-oviedo/Documents/Stage2/Codes/FLIMApp\")")
    println("  2. include(\"src2/main.jl\")")
    println("  3. run_app()")
    println("  4. Select your IRF .sdt file when prompted")
    println("\n" ^ 2)

catch e
    println("\n" ^ 2)
    println("=" ^ 70)
    println("✗ TEST FAILED")
    println("=" ^ 70)
    println("\nError: $(e)")
    println("\nStacktrace:")
    showerror(stderr, e, catch_backtrace())
    exit(1)
end
