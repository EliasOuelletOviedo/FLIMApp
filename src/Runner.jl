module Runner
using Observables

struct AppState
    folderpath::String
    irf::Union{Nothing, Array{Float64,2}}
    running::Observable{Bool}
    active::Observable{Bool}

    # add more typed fields
end

function init_state(; folderpath=".")
    AppState(folderpath, nothing, Observable(false), Observable(false))
end

end
