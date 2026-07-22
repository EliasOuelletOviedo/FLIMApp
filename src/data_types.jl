"""
data_types.jl

Core data structures for the FLIM application.

This module defines the primary structures for application state:
- AppState: Persistent configuration that is serialized to disk
- AppRun: Runtime transient state with observables and background tasks
- ChannelFrame / ChannelSeries: one TCSPC channel's per-frame results and
  runtime observables, so per-channel logic is written once and instantiated
  per channel instead of duplicated `_ch1`/`_ch2` copies
"""

using Observables
using Base.Threads
using LibSerialPort: SerialPort

# =============================================================================
# ACQUISITION SAMPLES (worker -> consumer payload)
# =============================================================================

"""
    ChannelFrame

One TCSPC channel's slice of a single acquisition frame: the binned
histogram, its fitted decay curve, and the scalar fit results. Two of these
(one per channel) make up an `AcquisitionSample`. The "absent channel"
convention (a file with only one TCSPC channel) uses the same sentinels as
everywhere else: `NaN` for scalars, `Float64[]` for vectors — see
`ChannelFrame()` below and `process_frame!` in acquisition.jl.
"""
struct ChannelFrame
    histogram::Vector{Float64}
    fit::Vector{Float64}
    photons::Float64
    lifetime::Float64
    concentration::Float64
end

"""
    ChannelFrame()

The "absent channel" frame: empty vectors and `NaN` scalars, emitted for
channel 2 when the source file has only one TCSPC channel.
"""
ChannelFrame() = ChannelFrame(Float64[], Float64[], NaN, NaN, NaN)

"""
    AcquisitionSample

One frame's worth of acquisition results, emitted onto the acquisition
channel by `run_acquisition_loop!` (acquisition.jl) and consumed by
`consumer_loop` (runtime.jl). A struct rather than a positional tuple —
too many fields to destructure positionally without risking a
silently-mismatched order.

`frame_index` is this app's own count of files it has read so far this run
— it advances by exactly 1 per file regardless of what the source acquisition
actually produced, so a file the upstream hardware/software never wrote
(e.g. a lag spike at the source) is invisible to it and it silently drifts
out of sync with the real physical sequence from that point on.
`file_sequence_number` (parsed from `source_file`'s name, see
`parse_file_sequence_number` in acquisition.jl) is this file's own
embedded position in that sequence instead, so a missing file just leaves a
gap rather than shifting everything after it — used by `consumer_loop`
(runtime.jl) for round-robin ROI assignment specifically because of this.
`nothing` when the filename has no parseable trailing number.
"""
struct AcquisitionSample
    ch1::ChannelFrame
    ch2::ChannelFrame
    command1::Float64
    command2::Float64
    timestamps::Float64
    protocol_setpoint::Float64
    frame_index::UInt32
    source_file::String
    file_sequence_number::Union{Int, Nothing}
end

# =============================================================================
# APPLICATION STATE SETTINGS GROUPS
# =============================================================================
#
# Base.@kwdef gives each struct a zero-argument default constructor (e.g.
# LayoutSettings()) that doubles as "get the defaults" — no separate
# get_default_*() function needed. Typed fields mean a typo'd key or a
# wrong-typed value is a compile-time/construction-time error instead of a
# silent Dict lookup returning `nothing` at some unrelated call site.

"""
    LayoutSettings

Display settings: time range, binning, smoothing, which series each plot
shows, and per-plot channel toggles.
"""
Base.@kwdef mutable struct LayoutSettings
    time_range::Int = 60
    binning::Int = 1
    smoothing::Int = 0
    plot1::String = "Lifetime"
    plot2::String = "Ion concentration"
    plot1_ch1::Bool = false
    plot1_ch2::Bool = false
    plot2_ch1::Bool = false
    plot2_ch2::Bool = false
end

"""
    ControllerSettings

Hardware controller configuration for the two PI output channels. No `D`
gain: the derivative term was dropped in favor of a Kalman observer
(`KalmanState`/`kalman_update!`, smoothing.jl) feeding the P/I error terms a
filtered lifetime instead of the raw fit — see `process_frame!`
(acquisition.jl).
"""
Base.@kwdef mutable struct ControllerSettings
    ch1_inv::Bool = false
    ch1_on::Bool = false
    ch1_out::String = "Out 1"
    ch1_mode::String = "Digital"
    freq::Int = 1000
    P1::Float64 = 0.0
    I1::Float64 = 0.0
    ch2_inv::Bool = false
    ch2_on::Bool = false
    ch2_out::String = "Out 2"
    ch2_mode::String = "Digital"
    P2::Float64 = 0.0
    I2::Float64 = 0.0
end

"""
    ProtocolSettings

Experimental protocol schedule: `times`/`setpoints` are parallel vectors of
`PROTOCOL_STEP_COUNT` per-step durations and setpoints.

`points_per_roi`/`spiral_turns`/`scan_time`/`shift_time` are the
ROI trigger-box scan-buffer parameters (roi.jl), editable from the Protocol
panel (handlers_protocol.jl) — see `roi_trigger_buffer`/
`build_and_send_roi_trigger_buffer!` in roi.jl for how they're used.
"""
Base.@kwdef mutable struct ProtocolSettings
    active::Bool = false
    repeats::Int = 1
    delay::Int = 0
    times::Vector{Float64} = fill(NaN, PROTOCOL_STEP_COUNT)
    setpoints::Vector{Float64} = fill(NaN, PROTOCOL_STEP_COUNT)
    PWM_frequency::Int = 1000
    points_per_roi::Int = 100
    spiral_turns::Int = 10
    scan_time::Int = 950
    shift_time::Int = 50
end

"""
    RoiSettings

ROI panel settings.
"""
Base.@kwdef mutable struct RoiSettings
    active::Bool = false
end

"""
    ConsoleSettings

Console/logging settings (no fields yet).
"""
Base.@kwdef mutable struct ConsoleSettings end

# =============================================================================
# PERSISTENT APPLICATION STATE
# =============================================================================

"""
    AppState

Persistent user preferences, serialized to `state_file_path()` to survive
across sessions. `current_panel` is the active UI panel (:layout,
:controller, :protocol, :console); the settings fields group the per-panel
configuration.
"""
mutable struct AppState
    dark::Bool
    current_panel::Symbol
    layout::LayoutSettings
    controller::ControllerSettings
    protocol::ProtocolSettings
    roi::RoiSettings
    console::ConsoleSettings
end

"""
    AppState(use_dark::Bool)

All-defaults state, with the dark theme when `use_dark` is true.
"""
function AppState(use_dark::Bool)
    return AppState(
        use_dark,
        :layout,
        LayoutSettings(),
        ControllerSettings(),
        ProtocolSettings(),
        RoiSettings(),
        ConsoleSettings()
    )
end

# =============================================================================
# RUNTIME APPLICATION STATE
# =============================================================================

"""
    ChannelSeries

One TCSPC channel's "latest frame" snapshot: the current histogram, fitted
decay curve, and photon count, all overwritten (not appended to) each
published update — used only by the Histogram plot, which shows the most
recent frame regardless of which ROI it belongs to (see `RoiChannelSeries`
for the per-ROI accumulated time series that back every other plot).
`AppRun` holds one instance per channel (`ch1`/`ch2`), so every "do X for
each channel" site loops over `(app_run.ch1, app_run.ch2)` instead of
duplicating `_ch1`/`_ch2` code.
"""
struct ChannelSeries
    histogram::Observable{Vector{Float64}}
    fit::Observable{Vector{Float64}}
    counts::Observable{Float64}
end

function ChannelSeries()
    return ChannelSeries(
        Observable(zeros(Float64, DEFAULT_HISTOGRAM_RESOLUTION)),
        Observable(zeros(Float64, DEFAULT_HISTOGRAM_RESOLUTION)),
        Observable(0.0)
    )
end

"""
    channel_series(app_run) -> (ChannelSeries, ChannelSeries)

Both channels' "latest frame" snapshots, in channel order — the idiomatic
way to iterate "for each channel" over an `AppRun` for Histogram-plot data.
"""
channel_series(app_run) = (app_run.ch1, app_run.ch2)

"""
    KalmanState

Constant-velocity (2-state) Kalman filter state: estimated value (`pos`)
and its rate of change (`vel`), their 2x2 covariance (`p11`/`p12`/`p22`),
and an adaptively-tracked measurement-noise estimate (`r_est`, updated from
successive raw measurements the same way the pre-Kalman heuristic's own
`scale_est` was) used as the filter's own `R` term. `prev_raw` is the last
raw (unfiltered) measurement seen, needed to compute `r_est`'s update.
`typical_dt` is an EMA of the elapsed time between updates — needed because
the process-noise growth `kalman_update!` applies over an interval `dt`
scales as `dt^3`, so a `q` intensity calibrated for one acquisition's
cadence would over- or under-smooth badly at another's (real files here
have ranged from ~20ms to ~118s between frames); `q` is derived from
`typical_dt`, not a fixed absolute constant, so "level 10" means the same
relative amount of smoothing regardless of how fast frames actually arrive.

One instance per (channel, metric) drives the PID observer
(`ChannelFitState.pid_kalman`, acquisition.jl) and one per (channel, ROI,
metric) drives plot smoothing (`RoiChannelSeries`, below) — same filter
(`kalman_update!`, smoothing.jl), independent state in each case, since ROI
mode's per-line smoothing stays independent from the PID's own observer
(each ROI only sees every Nth frame; the PID observer sees every frame).

`KalmanState()`'s all-`NaN`(/`0.0`-velocity) default is this filter's "never
seen a sample yet" sentinel — `kalman_update!` (re)initializes properly
from the first real measurement it's given.
"""
mutable struct KalmanState
    pos::Float64
    vel::Float64
    p11::Float64
    p12::Float64
    p22::Float64
    r_est::Float64
    prev_raw::Float64
    typical_dt::Float64
end

KalmanState() = KalmanState(NaN, 0.0, NaN, 0.0, NaN, NaN, NaN, NaN)

"""
    RoiChannelSeries

One ROI's accumulated runtime time series for one TCSPC channel — the unit
that gets duplicated once per drawn ROI (`app_run.rois`), per channel, when
incoming acquisition frames are round-robin assigned to ROIs (see
`accumulate_roi_sample!` in runtime.jl). Carries its own
`timestamps` because each ROI only receives every Nth frame (N = number of
ROIs), so it can't share a single app-wide per-frame x-axis the way the
original single-series design did.

# Fields
- `timestamps::Observable{Vector{Float64}}`: this ROI's own frame timestamps
- `photons::Observable{Vector{Float64}}` / `photons_smooth` / `photons_kalman`: photon-count time series and its live Kalman filter state
- `lifetime::Observable{Vector{Float64}}` / `lifetime_smooth` / `lifetime_kalman`: fitted-lifetime time series and its live Kalman filter state
- `concentration::Observable{Vector{Float64}}` / `concentration_smooth` / `concentration_kalman`: ion-concentration time series and its live Kalman filter state

The `_kalman` fields (`KalmanState`) are `smoothing.jl`'s `kalman_update!`
running state for that metric's `_smooth` series — not plotted directly,
just carried so `append_smooth_value!` can pick up where the last call left
off, and reinitialized (not persisted) across a `recompute_smooth_series!`
replay — see that function's docstring for why that's fine.
"""
struct RoiChannelSeries
    timestamps::Observable{Vector{Float64}}
    photons::Observable{Vector{Float64}}
    photons_smooth::Observable{Vector{Float64}}
    photons_kalman::KalmanState
    lifetime::Observable{Vector{Float64}}
    lifetime_smooth::Observable{Vector{Float64}}
    lifetime_kalman::KalmanState
    concentration::Observable{Vector{Float64}}
    concentration_smooth::Observable{Vector{Float64}}
    concentration_kalman::KalmanState
end

function RoiChannelSeries()
    return RoiChannelSeries(
        Observable(Float64[]),
        Observable(Float64[]),
        Observable(Float64[]),
        KalmanState(),
        Observable(Float64[]),
        Observable(Float64[]),
        KalmanState(),
        Observable(Float64[]),
        Observable(Float64[]),
        KalmanState()
    )
end

"""
    roi_channel_series(app_run)

Every `RoiChannelSeries` currently allocated, across both channels — the
idiomatic way to iterate "for each (channel, ROI)" over an `AppRun`
regardless of channel-visibility toggles (used for resetting/notifying/
recomputing smoothing on all of them at once; see `shown_channel_series` in
plotting.jl for the toggle-gated, per-plot iteration).
"""
roi_channel_series(app_run) = Iterators.flatten((app_run.ch1_rois, app_run.ch2_rois))

"""
    RoiCoordinates

One ROI's boundary — imported from an ImageJ .roi/.zip file or manually
drawn in the ROI popup (roi_popup.jl) — in the underlying image's own
0-based pixel coordinates (not any particular popup canvas/display offset).
`xs`/`ys` are parallel, closed-loop vectors (last point equals first),
matching `roi_boundary_points`'s convention in roi_popup.jl.
"""
struct RoiCoordinates
    name::String
    xs::Vector{Float64}
    ys::Vector{Float64}
end

"""
    AppRun

Runtime state for the application. This structure holds references to
background tasks, communication channels, and observables that update
during execution. It is NOT serialized.

# Fields
- `channel::Union{Channel{AcquisitionSample}, Nothing}`: worker->consumer data channel
- `running::Threads.Atomic{Bool}`: flag controlling background task lifetime
- `paused::Threads.Atomic{Bool}`: flag pausing the background tasks
- `worker_task::Union{Task, Nothing}`: background worker processing task
- `consumer_task::Union{Task, Nothing}`: data consumer and GUI update task
- `autoscaler_task::Union{Task, Nothing}`: periodic axis autoscaling task
- `infos_task::Union{Task, Nothing}`: periodic info/status update task
- `serial_task::Union{Task, Nothing}`: periodic serial command task
- `serial_conn::Union{SerialPort, Nothing}`: open serial connection, if any
- `ch1::ChannelSeries` / `ch2::ChannelSeries`: per-channel "latest frame" snapshot (Histogram plot only)
- `ch1_rois::Vector{RoiChannelSeries}` / `ch2_rois::Vector{RoiChannelSeries}`: per-channel,
  per-ROI accumulated time series (every other plot) — always the same
  length as each other, `max(1, length(rois[]))` as of the last
  `rebuild_roi_series!` call (`start_pressed`/CLEAR, runtime.jl),
  but only when the ROI toggle (`app.roi.active`, Protocol panel,
  handlers_protocol.jl) is on; a single-element vector — reproducing the
  original un-split single-series behavior — otherwise, regardless of how
  many ROIs are drawn
- `protocol_setpoint::Observable{Vector{Float64}}`: time-series of protocol setpoints used by PID
- `command1::Observable{Vector{Float64}}` / `command2`: time-series of PID command values —
  NOT split per ROI: these drive real hardware output (serial.jl), not just
  the "Command" plot, so they stay a single shared series regardless of ROI count
- `timestamps::Observable{Vector{Float64}}`: time-series timestamps
- `i::Observable{UInt32}`: current frame/iteration counter
- `save_progress::Observable{Float64}`: Save-mode progress (percent, `NaN` when idle)
- `hist_time::Observable{Vector{Int64}}`: histogram time-axis values
- `protocol::Observable{ProtocolSettings}`: normalized protocol config for the worker
- `rois::Observable{Vector{RoiCoordinates}}`: currently-drawn ROI boundaries
  (imported or manually drawn in the ROI popup, roi_popup.jl), shared here
  so other panels/functions can read the current ROI set without reaching
  into the popup itself
- `target_frequency::Threads.Atomic{Float64}`: Playback mode's target frame
  rate (Hz) — an `Atomic`, not an `Observable`, because `start_playback`
  (acquisition.jl) reads it every cycle from its own worker thread
  (`Threads.@spawn`), not the GUI thread; the target-frequency textbox
  (GUI.jl/handlers.jl) writes to it live, so it takes effect mid-run
- `imported_image_size::Tuple{Int,Int}`: `(width, height)` in pixels of the
  most recently imported ROI-popup image (roi_popup.jl's `im_import_button`
  handler) — `rois[]`'s coordinates are in this image's own pixel space.
  Read by `roi_trigger_buffer` (roi.jl) to correct for an image shorter
  than the trigger box's voltage calibration reference (see its docstring).
  Defaults to `(1024, 1024)`, matching that calibration reference, so a run
  started before any image has been imported this session behaves as if no
  correction were needed.
"""
mutable struct AppRun
    channel::Union{Channel{AcquisitionSample}, Nothing}
    running::Threads.Atomic{Bool}
    paused::Threads.Atomic{Bool}
    worker_task::Union{Task, Nothing}
    consumer_task::Union{Task, Nothing}
    autoscaler_task::Union{Task, Nothing}
    infos_task::Union{Task, Nothing}
    serial_task::Union{Task, Nothing}
    serial_conn::Union{SerialPort, Nothing}
    ch1::ChannelSeries
    ch2::ChannelSeries
    ch1_rois::Vector{RoiChannelSeries}
    ch2_rois::Vector{RoiChannelSeries}
    protocol_setpoint::Observable{Vector{Float64}}
    command1::Observable{Vector{Float64}}
    command2::Observable{Vector{Float64}}
    timestamps::Observable{Vector{Float64}}
    i::Observable{UInt32}
    save_progress::Observable{Float64}
    hist_time::Observable{Vector{Int64}}
    protocol::Observable{ProtocolSettings}
    rois::Observable{Vector{RoiCoordinates}}
    target_frequency::Threads.Atomic{Float64}
    imported_image_size::Tuple{Int,Int}
end

"""
    AppRun()

Fresh runtime state: empty observables, all tasks and the channel `nothing`.
"""
function AppRun()
    return AppRun(
        nothing,
        Threads.Atomic{Bool}(false),
        Threads.Atomic{Bool}(false),
        nothing,
        nothing,
        nothing,
        nothing,
        nothing,
        nothing,
        ChannelSeries(),
        ChannelSeries(),
        [RoiChannelSeries()],
        [RoiChannelSeries()],
        Observable(Float64[]),
        Observable(Float64[]),
        Observable(Float64[]),
        Observable(Float64[]),
        Observable{UInt32}(0),
        Observable(NaN),
        Observable(collect(1:DEFAULT_HISTOGRAM_RESOLUTION)),
        Observable(ProtocolSettings()),
        Observable(RoiCoordinates[]),
        Threads.Atomic{Float64}(DEFAULT_PLAYBACK_TARGET_FREQUENCY_HZ),
        (1024, 1024)
    )
end
