"""
Test if run_app() can initialize without segfault.
This tests compilation of make_gui() which was causing ADCE crash.
"""

cd("/Users/eliasouellet-oviedo/Documents/Stage2/Codes/FLIMApp/src2")
include("main.jl")

println("=" ^ 60)
println("Testing run_app() initialization (no segfault)...")
println("=" ^ 60)

# Test 1: Can we get past loading?
try
    println("\n✓ Test 1: Modules loaded successfully")
catch e
    println("✗ Test 1 FAILED: $(e)")
    exit(1)
end

# Test 2: Can we compile make_gui() without ADCE crash?
try
    # Create test AppState
    app = create_default_app_state()
    app_run = create_app_run()
    num_context = NumericContext(zeros(256, 2), 1.0, 256.0, nothing, nothing)
    
    println("✓ Test 2: AppState/AppRun/NumericContext created")
    
    # This is where the ADCE crash was happening in compilation
    @info "Attempting to compile make_gui()..."
    
    # Force compilation by calling the function (will create Figure but won't display)
    # This tests that make_gui() compiles without segfault
    fig = make_gui(app, app_run, num_context)
    println("✓ Test 3: make_gui() executed successfully (Figure created)")
    println("✓ Test 4: No ADCE segmentation fault!")
    
catch e
    println("✗ Test failed: $(e)")
    for (exc, bt) in Base.catch_stack()
        println("\nStacktrace:")
        Base.showerror(stdout, exc, bt)
    end
    exit(1)
end

println("\n" ^ 1)
println("=" ^ 60)
println("✓✓✓ All initialization tests passed!")
println("ADCE compiler bug appears to be fixed.")
println("make_gui() compiles and runs without segfault.")
println("=" ^ 60)
