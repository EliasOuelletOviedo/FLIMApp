"""
config.jl

Paths, acquisition/UI constants, and theme definitions used across the app.
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

Per-user directory holding TIFFApp's runtime state (saved `AppState`, path
caches). Lives under the user's home directory, not the repository — state
files change on every run and must never end up committed to git.

Distinct from the FLIM app's `~/.flimapp`, so the two can be installed side
by side without one loading the other's saved state — which would fail
anyway, the settings structs having diverged.
"""
user_data_dir()::String = joinpath(homedir(), ".tiffapp")

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

# Cache file remembering the last-selected data folder. The IRF path cache
# that sat alongside it is gone with lifetime fitting — there is no
# instrument response to load for a ratiometric acquisition.
folderpath_cache()::String = joinpath(user_data_dir(), "folderpath.txt")

"""
    default_data_root_path()::String

Fallback root directory for acquisition data when no folder has been picked
in the GUI yet: the `TIFF_DATA_PATH` environment variable when set, otherwise
`~/TIFFApp_data`.

This is the folder the user points at the acquisition's output — either a
session directory, a `Bliq VMS` directory, or the parent the Realtime watcher
monitors for new sessions. See `find_bliq_root` (tiff_source.jl) for which
shapes resolve.
"""
function default_data_root_path()::String
    return get(ENV, "TIFF_DATA_PATH", joinpath(homedir(), "TIFFApp_data"))
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
# ACQUISITION CONSTANTS
# =============================================================================

const PROTOCOL_STEP_COUNT = 10             # steps per protocol (times/setpoints length)

"""
    DEFAULT_CHANNEL_COUNT

Channel count assumed before a run has resolved an actual folder layout. Only
affects how `AppRun()` sizes its initial series; the real count comes from
counting `C<n>` directories at START (`resolve_channel_layout`,
tiff_source.jl).
"""
const DEFAULT_CHANNEL_COUNT = 2

"""
    MAX_FRAME_BUFFER_DEPTH

Hard ceiling on the temporal binning window, in frames.

The binning window is a circular buffer of *whole images*, so its cost scales
with the frame size: at 1024x1024 across three channels, 50 frames is ~157 MB
of 8-bit samples (~314 MB if the camera is switched to 16-bit). Beyond that
the memory stops being worth what binning adds, since the Kalman smoother
already handles noise reduction on the resulting time series.

`ImageFrameBuffer` (acquisition.jl) allocates lazily from the first frame's
real geometry rather than assuming a size, so an acquisition with smaller
frames simply uses less.
"""
const MAX_FRAME_BUFFER_DEPTH = 50

"""
    PREVIEW_MAX_DIMENSION

Longest edge, in pixels, of the downsampled `FramePreview` the image plot
renders. The plot is a few hundred pixels on screen, so shipping more than
this per frame would allocate bandwidth for detail that is immediately
resampled away — see `FramePreview` (data_types.jl).
"""
const PREVIEW_MAX_DIMENSION = 256

"""
    PREVIEW_MIN_INTERVAL_S

Minimum wall-clock spacing between two previews. At 60 Hz the image plot
cannot usefully show every frame, and building one costs a strided pass over
every channel plus a per-pixel division on the downsampled grid; throttling
keeps that off the critical path without making the preview look stalled.
"""
const PREVIEW_MIN_INTERVAL_S = 0.1

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
