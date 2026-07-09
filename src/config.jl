"""
config.jl

Central configuration and application state initialization.

This module establishes all application-level settings, paths, constants,
and default configuration values that are used throughout the FLIM application.

Contains:
- File paths and configuration
- Theme and UI constants
- Default application states
- Configuration utilities
"""

using Colors

# =============================================================================
# PATHS & DIRECTORIES
# =============================================================================

"""
    STATE_FILE_PATH::String

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
const STATE_FILE_PATH = joinpath("docs", "AppState.jls")

"""
    IRF_FILEPATH_CACHE::String

Path to the cached IRF file path configuration.
"""
const IRF_FILEPATH_CACHE = joinpath("docs", "irf_filepath.txt")

"""
    FOLDERPATH_CACHE::String

Path to the cached data folder path configuration.
"""
const FOLDERPATH_CACHE = joinpath("docs", "folderpath.txt")

"""
    DATA_ROOT_PATH::String

Root directory where test/sample data files are stored.
"""
# const DATA_ROOT_PATH = get(ENV, "FLIM_DATA_PATH", "/Users/eliasouellet-oviedo/Documents/Stage2/Codes/test")
# const DATA_ROOT_PATH = "/Users/eliasouellet-oviedo/Documents/Stage2/Partie2/Données/2026-03-12/test_control/test4"
const DATA_ROOT_PATH = "/Users/eliasouellet-oviedo/Desktop/test2"

"""
    get_data_root_path()::String

Return the active data root path from cache when available,
otherwise fallback to `DATA_ROOT_PATH`.
"""
function get_data_root_path()::String
    if isfile(FOLDERPATH_CACHE)
        cached = try
            strip(open(f -> read(f, String), FOLDERPATH_CACHE))
        catch
            ""
        end

        if !isempty(cached)
            return cached
        end
    end

    return DATA_ROOT_PATH
end

# =============================================================================
# PHYSICS CONSTANTS
# =============================================================================

"""
    DEFAULT_HISTOGRAM_RESOLUTION::Int

Standard number of time bins in histograms.
"""
const DEFAULT_HISTOGRAM_RESOLUTION = 256

"""
    LASER_PULSE_PERIOD::Float64

Period between laser pulses in nanoseconds.
"""
const LASER_PULSE_PERIOD = 12.5

"""
    NUM_PREVIOUS_PULSES::Int

Number of previous laser pulses to account for in reconvolution.
"""
const NUM_PREVIOUS_PULSES = 5

"""
    TCSPC_LOW_CUT_INDEX::Int

Lower bound index for time-correlated single photon counting.
"""
const TCSPC_LOW_CUT_INDEX = 13

"""
    TCSPC_HIGH_CUT_INDEX::Int

Upper bound index for time-correlated single photon counting.
"""
const TCSPC_HIGH_CUT_INDEX = 12

"""
    PROTOCOL_STEP_COUNT::Int

Number of steps in an experimental protocol (times/setpoints vectors).
"""
const PROTOCOL_STEP_COUNT = 10

# =============================================================================
# UI THEME DEFINITIONS
# =============================================================================

"""
    DARK_MODE_THEME::Dict

Dark mode color scheme and typography settings.
"""
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

"""
    LIGHT_MODE_THEME::Dict

Light mode color scheme and typography settings.
"""
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

Returns RGB color objects for the specified theme.

Args:
- `use_dark_mode::Bool` - Use dark theme if true, light theme if false

Returns:
- NamedTuple with COLOR_1 through COLOR_5 and TEXT
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

Ensures all required directories exist. Called at application startup.
"""
function initialize_directories()
    mkpath(dirname(STATE_FILE_PATH))
    mkpath(get_data_root_path())
end
