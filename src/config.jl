"""
config.jl

Paths, physics/UI constants, and theme definitions used across the app.
Application-state defaults live with the settings structs in data_types.jl.
"""

using Colors

# =============================================================================
# PATHS & DIRECTORIES
# =============================================================================
#
# These are functions rather than `const`s on purpose: a `const` path is
# evaluated once at precompilation time, so anything derived from `homedir()`
# or `ENV` would bake the *build* machine's value into the precompile cache
# (and into a PackageCompiler app, see build/create_app.jl). Functions
# re-resolve at call time on whatever machine the app actually runs on.

"""
    user_data_dir()::String

Per-user directory holding FLIMApp's runtime state (saved `AppState`, path
caches). Lives under the user's home directory, not the repository — state
files change on every run and must never end up committed to git.
"""
user_data_dir()::String = joinpath(homedir(), ".flimapp")

"""
    state_file_path()::String

Path to the serialized application state file.

`save_state` serializes a plain `Dict` (via `struct_to_dict`), not the raw
`AppState` struct. Serializing a custom struct directly ties the file to the
exact module identity (`Base.PkgId(uuid, "FLIMApp")`) active when it was
saved — if the app is loaded differently next time (e.g. `using FLIMApp`
vs. running `src/FLIMApp.jl` directly, which VS Code's "Run File" does),
that identity doesn't match and `deserialize` throws a `KeyError` on the
`PkgId` lookup, even though nothing about the data itself is wrong
(confirmed empirically: save under one loading mode, load under the other,
every time). Plain `Dict`/`Vector`/`Float64`/etc. values have no such
identity to resolve, so they survive regardless of how the app was loaded.
`load_state` falls through to `load_or_create_state()`'s fresh-defaults path
for any file it can't read (wrong format, corrupted, etc.) rather than
trying to detect and migrate it.
"""
state_file_path()::String = joinpath(user_data_dir(), "AppState.jls")

# Cache files remembering the last-selected IRF file / data folder.
irf_filepath_cache()::String = joinpath(user_data_dir(), "irf_filepath.txt")
folderpath_cache()::String = joinpath(user_data_dir(), "folderpath.txt")

"""
    default_data_root_path()::String

Fallback root directory for `.sdt` data files when no folder has been picked
in the GUI yet: the `FLIM_DATA_PATH` environment variable when set, otherwise
`~/FLIMApp_data`.
"""
function default_data_root_path()::String
    return get(ENV, "FLIM_DATA_PATH", joinpath(homedir(), "FLIMApp_data"))
end

"""
    get_data_root_path()::String

Return the active data root path from cache when available,
otherwise fall back to `default_data_root_path()`.
"""
function get_data_root_path()::String
    if isfile(folderpath_cache())
        cached = try
            strip(open(f -> read(f, String), folderpath_cache()))
        catch
            ""
        end

        if !isempty(cached)
            return cached
        end
    end

    return default_data_root_path()
end

# =============================================================================
# PHYSICS CONSTANTS
# =============================================================================

const DEFAULT_HISTOGRAM_RESOLUTION = 256   # time bins per histogram
const LASER_PULSE_PERIOD = 12.5            # ns between laser pulses
const NUM_PREVIOUS_PULSES = 5              # previous pulses for reconvolution
const TCSPC_LOW_CUT_INDEX = 13             # TCSPC window lower-bound index
const TCSPC_HIGH_CUT_INDEX = 12            # TCSPC window upper-bound index
const PROTOCOL_STEP_COUNT = 10             # steps per protocol (times/setpoints length)

"""
    DEFAULT_PLAYBACK_TARGET_FREQUENCY_HZ::Float64

Default target frame rate for Playback-mode acquisition (`start_playback`,
acquisition.jl) before the user edits the target-frequency textbox
(GUI.jl/handlers.jl). Only Playback paces itself against a fixed target —
Realtime waits for new files, Save runs its fixed file list as fast as
possible — so this has no effect on those two modes.
"""
const DEFAULT_PLAYBACK_TARGET_FREQUENCY_HZ = 1000.0

# =============================================================================
# UI THEME DEFINITIONS
# =============================================================================

# Dark-mode color scheme and typography.
const DARK_MODE_THEME = Dict{Symbol, Any}(
    :theme   => Dict{Symbol, Any}(
        :backgroundcolor => :gray12,
        :textcolor       => :gray80,
        :fonts           => (;
            regular = "Arial",
            bold    = "Arial Bold",
            italic  = "Arial Italic"
        )
    ),
    :color_1 => :gray14,
    :color_2 => :gray18,
    :color_3 => :gray22,
    :color_4 => :gray26,
    :color_5 => :gray50,
    :text    => :white
)

# Light-mode color scheme and typography.
const LIGHT_MODE_THEME = Dict{Symbol, Any}(
    :theme   => Dict{Symbol, Any}(
        :backgroundcolor => :gray88,
        :textcolor       => :gray20,
        :fonts           => (;
            regular = "Arial",
            bold    = "Arial Bold",
            italic  = "Arial Italic"
        )
    ),
    :color_1 => :gray80,
    :color_2 => :gray76,
    :color_3 => :gray72,
    :color_4 => :gray68,
    :color_5 => :gray50,
    :text    => :black
)

# Application state defaults now live as the zero-argument constructors of
# LayoutSettings / ControllerSettings / ProtocolSettings / RoiSettings /
# ConsoleSettings, defined in data_types.jl next to AppState.

# =============================================================================
# COLOR HELPER FUNCTIONS
# =============================================================================

"""
    get_theme_colors(use_dark_mode::Bool)::NamedTuple

RGB colors (`COLOR_1`..`COLOR_5`, `TEXT`) for the dark or light theme.
"""
function get_theme_colors(use_dark_mode::Bool)
    theme = use_dark_mode ? DARK_MODE_THEME : LIGHT_MODE_THEME

    return (
        COLOR_1 = parse(RGB{Float64}, theme[:color_1]),
        COLOR_2 = parse(RGB{Float64}, theme[:color_2]),
        COLOR_3 = parse(RGB{Float64}, theme[:color_3]),
        COLOR_4 = parse(RGB{Float64}, theme[:color_4]),
        COLOR_5 = parse(RGB{Float64}, theme[:color_5]),
        TEXT    = parse(RGB{Float64}, theme[:text])
    )
end

# =============================================================================
# DIRECTORY INITIALIZATION
# =============================================================================

"""
    initialize_directories()

Create the required data directories at startup (idempotent).
"""
function initialize_directories()
    mkpath(user_data_dir())
    mkpath(get_data_root_path())
end
