"""
gui/app_run.jl

The GUI thread's runtime state: `AppRun`, the per-ROI result histories and
the bindings between them and the plotted curves. Main thread only — the
other threads reach the GUI exclusively through the exchanges
(exchange.jl), which the refresh tick (gui/refresh.jl) copies into here.
"""

using GLMakie: Point2f

# =============================================================================
# RESULT HISTORIES
# =============================================================================

"""
    ChannelSeries

One TCSPC channel's "latest frame" snapshot: the current histogram, fitted
decay curve, and photon count, all overwritten (not appended to) by the
refresh tick — used only by the Histogram plot, which shows the most recent
frame regardless of which ROI it belongs to (see `RoiChannelSeries` for the
per-ROI accumulated histories that back every other plot). Fixed-size
Observables, updated in place.
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

Both channels' "latest frame" snapshots, in channel order.
"""
channel_series(app_run) = (app_run.ch1, app_run.ch2)

"""
    RoiChannelSeries

One ROI's full history for one TCSPC channel: raw and smoothed photons,
lifetime and concentration, each with its own timestamps (each ROI only
receives every Nth frame). Plain vectors, appended in place by the refresh
tick (`accumulate_roi_sample!`, gui/runtime.jl) — never replaced, so the
plot bindings holding them stay valid for the whole run. The `_kalman`
fields are the running smoothing state (`kalman_update!`, smoothing.jl).
"""
struct RoiChannelSeries
    timestamps::Vector{Float64}
    photons::Vector{Float64}
    photons_smooth::Vector{Float64}
    photons_kalman::KalmanState
    lifetime::Vector{Float64}
    lifetime_smooth::Vector{Float64}
    lifetime_kalman::KalmanState
    concentration::Vector{Float64}
    concentration_smooth::Vector{Float64}
    concentration_kalman::KalmanState
end

RoiChannelSeries() = RoiChannelSeries(Float64[], Float64[], Float64[], KalmanState(),
                                      Float64[], Float64[], KalmanState(),
                                      Float64[], Float64[], KalmanState())

"""
    roi_channel_series(app_run)

Every `RoiChannelSeries` currently allocated, across both channels.
"""
roi_channel_series(app_run) = Iterators.flatten((app_run.ch1_rois, app_run.ch2_rois))

# =============================================================================
# PLOT BINDINGS
# =============================================================================

"""
    SeriesLine

One plotted curve fed from a history: `points` is the Observable the line
was drawn with, refilled in place from `xs`/`ys` (the history vectors
themselves) by the refresh tick — one `notify` per tick, no new plot object.
"""
struct SeriesLine
    points::Observable{Vector{Point2f}}
    xs::Vector{Float64}
    ys::Vector{Float64}
end

"""One readback signal of the Readback plot, refilled from the latest slot."""
struct ReadbackLine
    points::Observable{Vector{Point2f}}
    signal::Int
end

"""Protocol-setpoint highlight (vspan), recomputed from the global history."""
struct SetpointSpans
    starts::Observable{Vector{Float64}}
    ends::Observable{Vector{Float64}}
end

"""
    PlotSlot

What one plot slot (`:plot1` or `:plot2`) currently shows: set by
`render_plot!` (gui/plotting.jl) when the selection changes, refreshed by
the refresh tick otherwise.
"""
mutable struct PlotSlot
    selection::String
    series_lines::Vector{SeriesLine}
    readback_lines::Vector{ReadbackLine}
    spans::Union{Nothing, SetpointSpans}
    legend::Any
end

PlotSlot() = PlotSlot("", SeriesLine[], ReadbackLine[], nothing, nothing)

# =============================================================================
# REFRESH-TICK BOOKKEEPING AND DIAGNOSTICS
# =============================================================================

"""
    DisplayState

Everything the refresh tick (gui/refresh.jl) keeps between ticks: its
cursors into the exchange rings, scratch vectors, the plot bindings, the
latest readback copy, and the measurements of plan §9 shown in the Console
panel.
"""
mutable struct DisplayState
    frame_cursor::Int
    slot_cursor::Int
    frames_lost::Int
    slots_lost::Int
    new_frames::Vector{FrameRecord}
    new_slots::Vector{SlotSummary}
    plots::Dict{Symbol, PlotSlot}
    dirty::Bool
    last_autoscale_ns::UInt64
    readback_version::Int
    readback_data::Matrix{Float32}
    readback_points::Int
    readback_dt_s::Float64
    readback_signals::Vector{String}
    readback_slot::Int
    last_settings::Union{Nothing, AnalysisSettings}
    last_status::LoopStatus
    # plan §9 measurements
    tick_count::Int
    tick_last_ns::UInt64
    tick_interval_max_s::Float64
    tick_interval_sum_s::Float64
    tick_work_max_s::Float64
    gc_total_ns::Int
    gc_tick_max_s::Float64
    loop_iteration_max_s::Float64
    loop_margin_min_s::Float64
    loop_deadline_s::Float64
    loop_slots::Int
    last_slot::Union{Nothing, SlotSummary}
    last_frame_count_time_ns::UInt64
    last_frame_count::Int
    frame_rate_hz::Float64
    diagnostics::Observable{String}
end

DisplayState() = DisplayState(
    0, 0, 0, 0, FrameRecord[], SlotSummary[],
    Dict(:plot1 => PlotSlot(), :plot2 => PlotSlot()), false, UInt64(0),
    0, zeros(Float32, 0, 0), 0, 0.0, String[], -1,
    nothing, LoopStatus(LOOP_DISCONNECTED, ""),
    0, UInt64(0), 0.0, 0.0, 0.0, 0, 0.0,
    0.0, Inf, NaN, 0, nothing, UInt64(0), 0, NaN,
    Observable("")
)

"""
    reset_diagnostics!(d::DisplayState)

Restart the §9 measurements (at START, and from the Console panel).
"""
function reset_diagnostics!(d::DisplayState)
    d.tick_count = 0
    d.tick_last_ns = UInt64(0)
    d.tick_interval_max_s = 0.0
    d.tick_interval_sum_s = 0.0
    d.tick_work_max_s = 0.0
    d.gc_total_ns = Int(Base.gc_num().total_time)
    d.gc_tick_max_s = 0.0
    d.loop_iteration_max_s = 0.0
    d.loop_margin_min_s = Inf
    d.loop_slots = 0
    d.frames_lost = 0
    d.slots_lost = 0
    return nothing
end

# =============================================================================
# PLAYBACK
# =============================================================================

"""
    PlaybackRun

A Playback run's replay: its own SPC engine (`FLIMCore.source_session`,
never the cards' engine), the session it replays (`read_session`,
analysis/session.jl), the engine's end (`Fin` of its Realtime pass
cutting), and `source_done`, raised then, which lets the analysis worker
end once it has taken every pass. `session_settings`: the worker uses the
session's layout, gains and protocol, and the GUI's edits don't reach it.
`dir` is the session folder picked with the folder button (kept in
`session_folder_cache()`).
"""
mutable struct PlaybackRun
    dir::String
    engine::Union{Nothing, FLIMCore.Moteur}
    session::Union{Nothing, Session}
    fin::Union{Nothing, FLIMCore.Fin}
    stop_sent::Bool
    source_done::Threads.Atomic{Bool}
    session_settings::Bool
end

PlaybackRun(dir::AbstractString = "") = PlaybackRun(String(dir), nothing, nothing, nothing, false, Threads.Atomic{Bool}(false), true)

# =============================================================================
# APP RUN
# =============================================================================

"""
    AppRun(cfg=BenchConfig defaults, exchange=Exchange(cfg))

Runtime state of the GUI thread. NOT serialized.

# Fields
- `config::BenchConfig`, `exchange::Exchange`: the bench config and the
  exchanges shared with the other threads
- `running`/`paused::Threads.Atomic{Bool}`: GUI -> analysis worker flags,
  atomics read by the worker every histogram
- `worker_task`, `loop_task`, `journal_task`, `refresh_task`: the analysis
  worker (one per START), the DAQ loop and journal threads (whole session),
  and the 30 Hz refresh tick
- `worker_output`: what the last finished worker returned (`AnalysisOutput`)
- `run_open::Bool`: a START's run is still being finalized (journal run
  open, worker, scan or SPC measurement still winding down)
- `run_started_ns::UInt64`: when the current run's commands were sent
- `irf_reload_pending::Bool`: an IRF was picked during a run; START loads it
- `ch1`/`ch2::ChannelSeries`: latest-frame snapshot (Histogram plot only)
- `ch1_rois`/`ch2_rois::Vector{RoiChannelSeries}`: per-channel, per-ROI
  histories, one entry per drawn ROI in ROI mode (a single entry otherwise)
- `timestamps`, `protocol_setpoint`, `command1`, `command2::Vector{Float64}`:
  global per-frame histories — each frame's commands are its ROI's (one PI
  per ROI): with several ROIs the Command plot interleaves them
- `i::Int`: latest frame index
- `hist_time::Observable{Vector{Int64}}`: histogram time axis
- `protocol::Observable{ProtocolSettings}`: normalized protocol (protocol popup preview)
- `rois::Observable{Vector{RoiCoordinates}}`: currently-drawn ROIs (roi_popup.jl)
- `roi_order::Vector{Int}`: visiting order of the current run's ROIs (`roi_visit_order`)
- `imported_image_size::Tuple{Int,Int}`: `(width, height)` of the image the
  ROIs were drawn on — see `roi_voltage_calibration_size` (roi_geometry.jl).
  Defaults to `(1024, 1024)`, the calibration reference.
- `display::DisplayState`: refresh-tick bookkeeping and diagnostics
- `spc::SpcView`: the SPC-150N engine handle, its settings (config/spc.toml)
  and what the SPC window shows (gui/spc_view.jl)
- `offline::String`: why this computer can't acquire (`offline_reason`,
  app.jl), "" when it can: the Realtime mode is then refused and Playback
  stays available
- `playback::PlaybackRun`: the Playback mode's session and replay engine
- `run_mode::String`: the mode of the current (or last) run, "Realtime" or "Playback"
- `run_rois::Vector{RoiCoordinates}`: the ROIs of the current (or last) run —
  the drawn ones in Realtime, the session's in Playback (index k = drawn ROI k)
- `run_dir::String`: the current (or last) run's folder ("" if none), where
  its debug report goes at the end
- `worker_stats::WorkerStats`: the analysis worker's counters of the current
  run, diagnosed once a second (diagnostics.jl)
- `diagnosed_t::Float64`: the time of the last `EtatClamp` diagnosed
"""
mutable struct AppRun
    config::BenchConfig
    exchange::Exchange
    running::Threads.Atomic{Bool}
    paused::Threads.Atomic{Bool}
    worker_task::Union{Task, Nothing}
    loop_task::Union{Task, Nothing}
    journal_task::Union{Task, Nothing}
    refresh_task::Union{Task, Nothing}
    worker_output::Any
    run_open::Bool
    run_started_ns::UInt64
    irf_reload_pending::Bool
    ch1::ChannelSeries
    ch2::ChannelSeries
    ch1_rois::Vector{RoiChannelSeries}
    ch2_rois::Vector{RoiChannelSeries}
    timestamps::Vector{Float64}
    protocol_setpoint::Vector{Float64}
    command1::Vector{Float64}
    command2::Vector{Float64}
    i::Int
    hist_time::Observable{Vector{Int64}}
    protocol::Observable{ProtocolSettings}
    rois::Observable{Vector{RoiCoordinates}}
    roi_order::Vector{Int}
    imported_image_size::Tuple{Int,Int}
    display::DisplayState
    spc::SpcView
    offline::String
    playback::PlaybackRun
    run_mode::String
    run_rois::Vector{RoiCoordinates}
    run_dir::String
    worker_stats::WorkerStats
    diagnosed_t::Float64
end

function AppRun(cfg::BenchConfig = bench_config_from_dict(Dict{String, Any}(); source = "defaults"),
                exchange::Exchange = Exchange(cfg))
    return AppRun(
        cfg, exchange,
        Threads.Atomic{Bool}(false),
        Threads.Atomic{Bool}(false),
        nothing, nothing, nothing, nothing, nothing,
        false, UInt64(0), false,
        ChannelSeries(), ChannelSeries(),
        [RoiChannelSeries()], [RoiChannelSeries()],
        Float64[], Float64[], Float64[], Float64[], 0,
        Observable(collect(1:DEFAULT_HISTOGRAM_RESOLUTION)),
        Observable(ProtocolSettings()),
        Observable(RoiCoordinates[]),
        Int[],
        (1024, 1024),
        DisplayState(),
        SpcView(spc_settings_path(cfg), exchange.journal),
        "",
        PlaybackRun(),
        "Realtime",
        RoiCoordinates[],
        "",
        WorkerStats(),
        0.0
    )
end
