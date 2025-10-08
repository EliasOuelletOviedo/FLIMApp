module Runner

export AppState

using Observables
using IOUtils
using Processing
using Controller
using Dates
struct AppState
    # configuration values (typed)
    average_window::Int
    buffer_len::Int
    irf::Union{Nothing,Vector{Float64}}
    # data & buffers
    buffer::Vector{Float64}         # rolling buffer for averaging
    monitor_files::Vector{String}   # playback queue or recent files
    # control observables (GUI subscribes to these)
    running::Observable{Bool}
    active::Observable{Bool}
    latest_result::Observable{Union{Processing.LifetimeResult,Nothing}}
    # device (Controller.Device)
    device::Union{Controller.Device, Nothing}
end

end # module Runner
