"""
data_types.jl

Core data structures for the FLIM application.

This file defines the structures shared across threads:
- AppState and its settings groups: persistent configuration serialized to disk
- ChannelFrame / AcquisitionSample: one analyzed histogram's results, per channel,
  so per-channel logic is written once and instantiated per channel instead
  of duplicated `_ch1`/`_ch2` copies
- KalmanState, RoiCoordinates

The GUI thread's runtime state (AppRun) lives in gui/app_run.jl, the
exchanges between threads in exchange.jl.
"""

using Observables
using Base.Threads

# =============================================================================
# ACQUISITION SAMPLES (analysis worker -> exchanges)
# =============================================================================

"""
    ChannelFrame

One TCSPC channel's slice of a single acquisition frame: the binned
histogram, its fitted decay curve, and the scalar fit results —
`lifetime_kalman` is the observer's estimate the PI acted on (`NaN` when
the pass was kept out of the PI). Two of these (one per channel) make up an
`AcquisitionSample`. The "absent channel" convention (a single SPC-150N in
`[verification] series`) uses the same sentinels as everywhere else: `NaN`
for scalars, `Float64[]` for vectors — see `ChannelFrame()` below and
`start_realtime` in acquisition.jl.
"""
struct ChannelFrame
    histogram::Vector{Float64}
    fit::Vector{Float64}
    photons::Float64
    lifetime::Float64
    concentration::Float64
    lifetime_kalman::Float64
end

ChannelFrame(histogram, fit, photons, lifetime, concentration) =
    ChannelFrame(histogram, fit, photons, lifetime, concentration, NaN)

"""
    ChannelFrame()

The "absent channel" frame: empty vectors and `NaN` scalars, emitted for
channel 2 when only one SPC-150N measures.
"""
ChannelFrame() = ChannelFrame(Float64[], Float64[], NaN, NaN, NaN)

"""
    AcquisitionSample

One analyzed pass's results, produced by the analysis worker
(`start_realtime`, analysis/acquisition.jl) and published by `emit_frame!`
into the exchanges. A struct rather than a positional tuple — too many
fields to destructure positionally without risking a silently-mismatched
order.

`frame_index` counts the passes analyzed this run; `pass` is the pass number
the cards counted (from 1, `FLIMCore.HistoClamp`), `pass_start_s`/
`pass_end_s` its markers in card time (seconds from the start of the
measurement); `timestamps` the end of the pass in seconds from the start of
the run's first pass; `complete` false when the pass was kept out of the
PI, `excluded_because` saying why (the engine's `HistoClamp.motifs`: lost
records, FIFO overflow, a pass of the wrong length); `acquired_at` when the
worker took it (unix seconds).
"""
struct AcquisitionSample
    ch1::ChannelFrame
    ch2::ChannelFrame
    command1::Float64
    command2::Float64
    timestamps::Float64
    protocol_setpoint::Float64
    frame_index::UInt32
    pass::Int
    pass_start_s::Float64
    pass_end_s::Float64
    complete::Bool
    excluded_because::String
    acquired_at::Float64
end

AcquisitionSample(ch1, ch2, command1, command2, timestamps, protocol_setpoint, frame_index, pass,
                  pass_start_s, pass_end_s, complete, acquired_at) =
    AcquisitionSample(ch1, ch2, command1, command2, timestamps, protocol_setpoint, frame_index, pass,
                      pass_start_s, pass_end_s, complete, "", acquired_at)

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
ROI galvo-scan parameters (roi_geometry.jl, loop/scan_pattern.jl), editable from the Protocol panel
(handlers_protocol.jl) — see `roi_scan_segments`/`roi_scan_waveform` in
roi.jl for how they're used.
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

ROI panel settings. `v_min_x`/`v_max_x`/`v_min_y`/`v_max_y` are the ROI
galvo voltage range (mV) for each axis, editable from the ROI popup — see
`roi_scan_segments` (roi_geometry.jl) for how they're used.
"""
Base.@kwdef mutable struct RoiSettings
    active::Bool = false
    v_min_x::Int64 = -1000
    v_max_x::Int64 = 1000
    v_min_y::Int64 = -1000
    v_max_y::Int64 = 1000
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
# SHARED RUNTIME TYPES
# =============================================================================
# Used by more than one thread (analysis worker and GUI). The GUI-only
# runtime state — AppRun, the per-ROI histories, plot bindings — lives in
# gui/app_run.jl.

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
cadence would over- or under-smooth badly at another's (frames here
have ranged from ~20ms to ~118s apart); `q` is derived from
`typical_dt`, not a fixed absolute constant, so "level 10" means the same
relative amount of smoothing regardless of how fast frames actually arrive.

One instance per (channel, metric) drives the PID observer
(`ChannelFitState.pid_kalman`, acquisition.jl) and one per (channel, ROI,
metric) drives plot smoothing (`RoiChannelSeries`, gui/app_run.jl) — same filter
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
    fit_channel::Int
end

RoiCoordinates(name, xs, ys) = RoiCoordinates(name, xs, ys, -1)

"""How a ROI's lifetime was fitted in the ROI popup, for the session: "channel 1", "channel 2", "sum" or ""."""
fit_channel_name(roi::RoiCoordinates) =
    roi.fit_channel == 1 ? "channel 1" : roi.fit_channel == 2 ? "channel 2" : roi.fit_channel == 0 ? "sum" : ""
