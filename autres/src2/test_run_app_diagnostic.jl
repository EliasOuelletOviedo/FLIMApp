"""
Diagnostic test for run_app() - step through each component to find error.
"""

cd("/Users/eliasouellet-oviedo/Documents/Stage2/Codes/FLIMApp/src2")
include("main.jl")

println("\n" * "="^70)
println("RUNNING STEP-BY-STEP run_app() DIAGNOSTIC")
println("="^70)

# Declare variables early to avoid scope issues
app = nothing
app_run = nothing
num_context = nothing

try
    # Step 1: Check file at docs/irf_filepath.txt
    println("\n[Step 1] Checking for cached IRF path...")
    irf_path = ""
    if isfile("../docs/irf_filepath.txt")
        irf_path = open(f -> read(f, String), "../docs/irf_filepath.txt")
        println("✓ Found cached path: $irf_path")
        if !ispath(irf_path)
            println("✗ Path doesn't exist: $irf_path")
        else
            println("✓ Path exists and is valid")
        end
    else
        println("ℹ No cached IRF path found (will need to select file)")
    end
    
    # Step 2: Try to load AppState
    println("\n[Step 2] Loading AppState...")
    app = try
        load_state()
    catch e
        println("ⓘ load_state() failed: $e (using defaults)")
        create_default_app_state()
    end
    println("✓ AppState loaded: $(typeof(app))")
    
    # Step 3: Create AppRun
    println("\n[Step 3] Creating AppRun...")
    app_run = create_app_run()
    println("✓ AppRun created: $(typeof(app_run))")
    
    # Step 4: Load IRF (if path exists)
    println("\n[Step 4] Checking IRF loading...")
    if !isempty(irf_path) && ispath(irf_path)
        try
            # Just check if we can load the IRF without a dialog
            irf_data = get_irf()
            println("✓ IRF loaded successfully: size = $(size(irf_data))")
        catch e
            println("✗ IRF load failed: $e")
            # This is expected if no file dialog available
            println("  (This is OK in non-interactive mode)")
        end
    else
        println("ℹ No valid IRF path - skipping IRF load (would need dialog)")
    end
    
    # Step 5: Create NumericContext
    println("\n[Step 5] Creating NumericContext...")
    try
        irf = get_irf()
        irf_bin_size = get_irf_bin_size(irf)
        tcspc_window_size = size(irf, 1) * irf_bin_size
        println("✓ IRF stats: bin_size=$irf_bin_size ns, window=$tcspc_window_size ns")
        
        # Create FFT plans
        p = plan_fft(irf[:, 2])
        p_inv = plan_ifft(zeros(length(irf[:, 2])))
        
        num_context = NumericContext(irf, irf_bin_size, tcspc_window_size, p, p_inv)
        println("✓ NumericContext created")
    catch e
        println("✗ NumericContext creation failed: $e")
        # Create a dummy one
        num_context = NumericContext(zeros(256, 2), 1.0, 256.0, nothing, nothing)
        println("  Using dummy NumericContext for testing")
    end
    
    # Step 6: Call make_gui (the problematic part)
    println("\n[Step 6] Creating GUI (make_gui)...")
    try
        fig = make_gui(app, app_run, num_context)
        println("✓ make_gui() succeeded - Figure created")
        println("  Figure type: $(typeof(fig))")
    catch e
        println("✗ make_gui() FAILED:")
        println("  Error: $e")
        println("\n  Full stacktrace:")
        for (exc, bt) in Base.catch_stack()
            Base.showerror(stdout, exc, bt)
        end
        exit(1)
    end
    
    # Step 7: Summary
    println("\n" * "="^70)
    println("✓✓✓ ALL STEPS COMPLETED SUCCESSFULLY")
    println("run_app() should work when called from REPL with file dialog")
    println("="^70)
    
catch e
    println("\n✗✗✗ UNEXPECTED ERROR:")
    println(e)
    println("\nFull stacktrace:")
    for (exc, bt) in Base.catch_stack()
        Base.showerror(stdout, exc, bt)
    end
    exit(1)
end
