"""
Persistence.jl - Atomic save/load of application state with versioning
"""

using Serialization

const STATE_VERSION = 2
const STATE_FILE = joinpath("docs", "AppState.jls")

"""
    save_state_atomic(state::AppState; path::AbstractString=STATE_FILE)

Save AppState atomically using write-to-temp-then-move pattern.
Prevents corruption if process crashes during serialization.

# Pattern
1. Write to `path.tmp`
2. Atomic move to `path` (POSIX-compliant)
3. On error, remove temp file and rethrow
"""
function save_state_atomic(state::AppState; path::AbstractString=STATE_FILE)
    tmppath = path * ".tmp"
    try
        open(tmppath, "w") do io
            # Wrap state with version tag for future-proof migrations
            serialize(io, (version=STATE_VERSION, state=state))
        end
        # Atomic move (works on macOS, Linux, Windows)
        mv(tmppath, path, force=true)
    catch e
        # Cleanup temp file if save failed
        isfile(tmppath) && rm(tmppath; force=true)
        @error "Failed to save state to $path" exception=e
        rethrow(e)
    end
end

"""
    load_state(path::AbstractString=STATE_FILE)

Load AppState from disk, handling version migration if needed.

Returns AppState with all persistent configuration restored, or nothing if file not found.
On error, rethrows the exception (let caller handle fallback).
"""
function load_state(path::AbstractString=STATE_FILE)
    if !isfile(path)
        @warn "State file not found: $path"
        return nothing
    end

    try
        open(path, "r") do io
            data = deserialize(io)
            
            # Handle versioned format (NamedTuple)
            if isa(data, NamedTuple) && haskey(data, :version)
                version = data.version
                state = data.state
                
                if version == 2
                    return state
                elseif version == 1
                    @warn "Detected AppState V$version, attempting to load..."
                    return state
                else
                    error("Unknown AppState version: $version")
                end
            else
                # Fallback: assume old unversioned format
                @warn "Detected unversioned AppState format"
                return data
            end
        end
    catch e
        @error "Failed to load state from $path" exception=e
        rethrow(e)
    end
end

"""
    ensure_state_dir()

Create the directory for state files if it doesn't exist.
"""
function ensure_state_dir(path::AbstractString=STATE_FILE)
    dir = dirname(path)
    mkpath(dir)
end

# Initialize state directory on module load
ensure_state_dir()
