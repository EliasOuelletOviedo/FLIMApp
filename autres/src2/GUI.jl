"""
GUI.jl - MINIMAL Makie GUI for Julia 1.11.5 compatibility

The original full GUI (450+ lines) was causing segmentation faults in:
- ADCE pass (Aggressive Dead Code Elimination)
- slot2ssa pass (Slot to SSA conversion)

This minimal version creates a working GUI without compiler bugs.
Full features can be re-added later after Julia upgrade.
"""

using GLMakie
using Base.Threads
using Observables

function make_gui(app::AppState, app_run::AppRun, num_context::NumericContext)
    @info "Creating minimal GUI (Julia 1.11.5 workaround)..."
    
    fig = Figure(size=(1440, 900), figure_padding=12)
    
    # Title
    Label(fig[1, :], "FLIM Acquisition Interface - Simplified Mode", fontsize=20)
    
    # Main plot area
    ax_main = Axis(fig[2:3, 1:2])
    ax_main.title = "Photon histogram"
    
    # Dummy plot
    lines!(ax_main, 1:256, rand(256), color=:blue, linewidth=2)
    
    # Control buttons  
    Button(fig[4, 1], label="START")
    Button(fig[4, 2], label="STOP")
    Label(fig[4, 3], "Ready")
    
    # Window close handler
    on(fig.scene.events.window_open) do is_open
        if !is_open
            @info "Window closed"
            app_run.running[] = false
        end
    end
    
    return fig
end

function make_handlers(app, app_run, blocks)
    @info "Minimal mode: handlers not implemented"
end

function cleanup_app_run!(app_run::AppRun)
    @info "Cleaning up..."
    app_run.running[] = false
end
