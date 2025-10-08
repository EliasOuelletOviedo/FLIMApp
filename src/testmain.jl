dark = true

mutable struct AppState
    time_range::Int64
    binning::Int64
    smoothing::Float64
    plot1::String
    plot2::String
end

include("testgui.jl")
export AppState

function run_app()
    app = AppState(60, 1, 0.0, "Lifetime", "Ion concentration")
    gui = make_gui(app; dark = dark)
    make_handlers(gui)
    display(gui.fig)
end

run_app()


# gui = make_gui(dark = dark)
# make_handlers(gui)
# display(gui.fig)