"""
main.jl - Application entry point and initialization

Manages startup sequence:
1. Load/create persistent state (AppState)
2. Create runtime state (AppRun)
3. Initialize numeric context (IRF, FFT plans)
4. Create and display GUI
5. Handle graceful shutdown
"""

using Serialization
using Observables
using ZipFile
# using Threads

# Set number of Julia threads (adjust as needed)
# JULIA_NUM_THREADS = 1

# Include modules in dependency order
include("DataTypes.jl")
include("Persistence.jl")
include("Attributes.jl")
include("vec_to_lifetime.jl")
include("functions.jl")
include("GUI.jl")
# include("handlers.jl")  # Temporarily disabled - may be causing compiler crash

# ============================================================================
# APPLICATION INITIALIZATION
# ============================================================================

"""
    run_app()

Main entry point: initialize application state, numeric context, and GUI.

# Sequence
1. Attempt to load persisted AppState, fallback to defaults
2. Create runtime AppRun state
3. Load IRF and initialize FFT plans
4. Create and display Makie GUI
5. Block until GUI is closed
"""
function run_app()
    # ========================================================================
    # 1. LOAD PERSISTENT STATE
    # ========================================================================
    
    @info "Loading persistent state..."
    app = create_default_app_state(true)  # true for dark mode
    
    try
        ensure_state_dir()
        app_loaded = load_state()
        if app_loaded !== nothing
            app = app_loaded
        end
    catch e
        @warn "Failed to load previous state, using defaults" exception=e
    end

    # ========================================================================
    # 2. CREATE RUNTIME STATE
    # ========================================================================
    
    @info "Creating runtime state..."
    app_run = create_app_run()
    
    @info "AppState loaded: dark=$(app.dark), panel=$(app.current_panel)"
    @info "Julia threads: $(Threads.nthreads())"

    # ========================================================================
    # 3. INITIALIZE NUMERIC CONTEXT
    # ========================================================================
    
    @info "Loading IRF and initializing FFT plans..."
    num_context = nothing

    try
        irf_data = get_irf()
        irf_bin_size = get_irf_bin_size()
        tcspc_window_size = round(irf_data[end, 1] + irf_data[2, 1], sigdigits=4)
        
        # Pre-allocate FFT plans for standard histogram size
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
        
        @info "IRF loaded: $(size(irf_data)) points, bin size=$(irf_bin_size) ns, window=$(tcspc_window_size) ns"
        
    catch e
        @error "Failed to initialize numeric context" exception=e
        error("Cannot proceed without IRF/FFT plans")
    end

    # ========================================================================
    # 4. UPDATE COLORS AND CREATE GUI
    # ========================================================================
    
    @info "Updating theme colors..."
    try
        update_colors_for_theme(app.dark)
    catch e
        @warn "Failed to update colors" exception=e
    end
    
    @info "Setting Makie theme..."
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
    
    @info "Creating GUI..."
    gui = make_gui(app, app_run, num_context)
    
    @info "Displaying GUI..."
    try
        display(gui)
    catch e
        @warn "Could not display GUI (may be running without display support)" exception=e
    end
    
    @info "App running... close window to exit"
end

"""
    cleanup_app_run!(app_run::AppRun)

Gracefully shutdown all background tasks and close channels.
Called when GUI window closes or on interruption.
"""
function cleanup_app_run!(app_run::AppRun)
    @info "Cleaning up background tasks..."
    
    # Signal workers to stop
    app_run.running[] = false
    
    # Close channel first to unblock consumer
    if !isnothing(app_run.channel)
        try
            close(app_run.channel)
        catch e
            @warn "Error closing channel" exception=e
        end
    end
    
    # Wait for all tasks to complete
    tasks_to_wait = [
        (app_run.worker_task, "worker"),
        (app_run.consumer_task, "consumer"),
        (app_run.autoscaler_task, "autoscaler"),
        (app_run.infos_task, "infos")
    ]
    
    for (task, name) in tasks_to_wait
        if !isnothing(task)
            try
                @debug "Waiting for $name task..."
                wait(task)
            catch e
                if isa(e, InvalidStateException)
                    @debug "$name task already completed"
                else
                    @warn "Error waiting for $name task" exception=e
                end
            end
        end
    end
    
    @info "Cleanup complete"
end

# ============================================================================
# ENTRY POINT
# ============================================================================

if !isinteractive()
    run_app()
end
