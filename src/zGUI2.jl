# This file is included into the FLIMApp module, so AppState is visible here.
using GLMakie
using Observables
using Base.Threads

include("attributes.jl")

"Build a minimal GLMakie GUI: a plot and a Start/Stop button."
function build_gui(app::AppState)
    fig = Figure(resolution = (900, 600))
    ax = Axis(fig[1, 1], ylabel = "Value", xlabel = "Index", width = 800, height = 400)
    xs = 1:app.npoints
    ys = Observable(zeros(app.npoints))        # the Observable the plot watches
    lines!(ax, xs, ys)                         # draw line that watches `ys`

    # Create a simple start/stop button (API may vary by Makie version)
    btn = Button(fig[2, 1], label = "Start")

    # what happens on clicks:
    on(btn.clicks) do _
        if !app.running[]
            # start producer on a THREAD so heavy math doesn't block the GUI
            app.running[] = true
            Threads.@spawn producer_loop!(app)   # function from functions.jl
            btn.label[] = "Stop"
        else
            # signal producer to stop; it will exit its loop
            app.running[] = false
            btn.label[] = "Start"
        end
    end

    display(fig)   # show the window when called from REPL
    return fig, ys, btn
end

function build_gui(app::AppState)

end
