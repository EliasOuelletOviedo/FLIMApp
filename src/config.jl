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
"""
const STATE_FILE_PATH = joinpath("docs", "AppState.jls")

"""
    IRF_FILEPATH_CACHE::String

Path to the cached IRF file path configuration.
"""
const IRF_FILEPATH_CACHE = joinpath("docs", "irf_filepath.txt")

"""
    DATA_ROOT_PATH::String

Root directory where test/sample data files are stored.
"""
const DATA_ROOT_PATH = get(ENV, "FLIM_DATA_PATH", "/Users/eliasouellet-oviedo/Documents/Stage2/Codes/test")
const DATA_ROOT_PATH = "/Users/eliasouellet-oviedo/Desktop/test1"

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

# =============================================================================
# APPLICATION STATE DEFAULTS
# =============================================================================

"""
    get_default_layout()::Dict

Returns a dictionary of default layout configuration settings.

Settings control:
- Time display range (seconds)
- Histogram binning factor
- Smoothing parameter
- Primary and secondary plot selections
"""
function get_default_layout()::Dict{Symbol, Any}
    return Dict{Symbol, Any}(
        :time_range => 60,
        :binning    => 1,
        :smoothing  => 0,
        :plot1      => "Lifetime",
        :plot2      => "Ion concentration"
    )
end

"""
    get_default_controller()::Dict

Returns a dictionary of default hardware controller settings.

Includes channel configurations:
- Channel enable/disable (ch1_on, ch2_on)
- Inversion flags (ch1_inv, ch2_inv)
- Output mappings (ch1_out, ch2_out)
- Operation modes (ch1_mode, ch2_mode)
- PID parameters (P, I, D for each channel)
"""
function get_default_controller()::Dict{Symbol, Any}
    return Dict{Symbol, Any}(
        :ch1_inv => false,
        :ch1_on  => false,
        :ch1_out => "Out 1",
        :ch1_mode=> "Digital",
        :P1      => 0,
        :I1      => 0,
        :D1      => 0,
        :ch2_inv => false,
        :ch2_on  => false,
        :ch2_out => "Out 2",
        :ch2_mode=> "Digital",
        :P2      => 0,
        :I2      => 0,
        :D2      => 0,
    )
end

"""
    get_default_protocol()::Dict

Returns a dictionary of default protocol settings (empty).

To be populated with experimental protocol parameters as needed.
"""
function get_default_protocol()::Dict{Symbol, Any}
    return Dict{Symbol, Any}()
end

"""
    get_default_console()::Dict

Returns a dictionary of default console settings (empty).

To be populated with logging/console output settings as needed.
"""
function get_default_console()::Dict{Symbol, Any}
    return Dict{Symbol, Any}()
end

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
    mkpath(DATA_ROOT_PATH)
end
