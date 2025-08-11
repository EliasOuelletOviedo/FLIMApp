module FLIMApp

include("IOUtils.jl")
include("Processing.jl")
include("Controller.jl")
include("Runner.jl")
include("GUI.jl")

export AppState, run_app

end
