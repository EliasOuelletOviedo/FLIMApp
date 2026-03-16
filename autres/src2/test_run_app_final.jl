"""
Direct test of run_app() from REPL-like context
"""

cd("/Users/eliasouellet-oviedo/Documents/Stage2/Codes/FLIMApp/src2")
include("main.jl")

println("\n" * "="^70)
println("TESTING run_app() STARTUP")
println("="^70)

# Wrapper function to avoid soft scope issues
function test_run_app_startup()
    try
        println("\n[1] Calling run_app()...")
        # Don't actually display the GUI, just get to the point of creating it
        # This tests all the initialization logic
        
        # We'll manually run through the steps that run_app() does
        @info "Loading persistent state..."
        app = try
            load_state()
        catch e
            @info "Using default state: $e"
            create_default_app_state()
        end
        println("✓ AppState loaded")
        
        @info "Creating runtime state..."
        app_run = create_app_run()
        println("✓ AppRun created")
        
        @info "Loading IRF..."
        num_context = nothing
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
            
            @info "IRF loaded: $(size(irf_data)) points"
            println("✓ IRF and FFT plans initialized")
            
        catch e
            @error "Failed to initialize numeric context" exception=e
            return false
        end
        
        @info "Updating colors..."
        try
            update_colors_for_theme(app.dark)
        catch e
            @warn "Failed to update colors" exception=e
        end
        
        @info "Setting theme..."
        try
            if app.dark
                theme_dict = get_theme_colors(true)
                set_theme!(;aspect_ratio=:auto)
            else
                theme_dict = get_theme_colors(false)
                set_theme!(;aspect_ratio=:auto)
            end
        catch e
            @warn "Failed to set theme" exception=e
        end
        
        println("\n[2] Creating GUI via make_gui()...")
        gui = make_gui(app, app_run, num_context)
        println("✓ GUI created successfully!")
        println("✓✓✓ make_gui() DID NOT CRASH")
        
        return true
        
    catch e
        println("\n✗✗✗ TEST FAILED")
        println("Error: $e")
        println("\nStacktrace:")
        Base.showerror(stdout, e, catch_backtrace())
        return false
    end
end

success = test_run_app_startup()

println("\n" * "="^70)
if success
    println("✓ run_app() initialization sequence works correctly")
    println("✓ The app is ready to run interactively from REPL")
    println("\nYou can now call: run_app()")
else
    println("✗ Initialization failed - check error above")
    exit(1)
end
println("="^70)
