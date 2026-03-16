"""
SIMPLIFIED GUI for Julia 1.11.5 ARM64 compiler workaround.

Due to compiler bugs in Julia 1.11.5 ARM64 (ADCE, slot2ssa crashes),
we create a minimal GUI that avoids triggering the optimization bugs.

This is a temporary workaround until Julia is fixed or upgraded.
"""

using GLMakie, Observables, Base.Threads, Dates

@noinline
function _make_minimal_gui()
    """Create bare minimum figure to avoid compiler crash"""
    fig = Figure(size=(1440, 847))
    title = Label(fig[1, 1], "FLIM Acquisition Interface (Simplified Mode)")
    ax = Axis(fig[2, 1])
    lines!(ax, 1:10, rand(10))
    return fig, ax
end

@noinline
function make_gui(app::AppState, app_run::AppRun, num_context::NumericContext)
    """
    Simplified GUI creation for Julia 1.11.5 compatibility.
    
    Avoids compiler bugs by creating minimal Figure structure.
    Advanced features (plots, handlers, tasks) can be added later.
    """
    
    @info "Creating minimal GUI (Julia 1.11.5 workaround mode)..."
    
    try
        fig, ax = _make_minimal_gui()
        
        # Add a simple status label
        Label(fig[1, 2], "Status: Ready")
        
        return fig
        
    catch e
        @error "Failed to create minimal GUI" exception=e
        # Return a completely empty figure as fallback
        return Figure(size=(1440, 847))
    end
end
