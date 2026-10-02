"""
runtime.jl

START/PAUSE/RESUME/STOP for the FLIM GUI (main thread). The handlers do no
work themselves (plan §2): they set flags, drop a command for the DAQ loop,
spawn the analysis worker, or push slow work off the render loop — then
return. Everything that comes back from those threads arrives through the
refresh tick (gui/refresh.jl), which also closes the run once the worker
and the scan have both stopped (`finalize_run!`).

Also the per-frame accumulation the refresh tick applies to the GUI-side
histories (`accumulate_frame!`).
"""

using GLMakie
using Observables
using Base.Threads

# -----------------------------------------------------------------------------
# GUI-side histories
# -----------------------------------------------------------------------------

"""
    accumulate_roi_sample!(app, series::RoiChannelSeries, frame::ChannelFrame, timestamp::Float64)

Append one frame's scalar results (photons, lifetime, concentration and
their smoothed values) plus its own timestamp onto one ROI's per-channel
history. Which ROI is decided upstream (`pass_roi`, analysis/acquisition.jl).
"""
function accumulate_roi_sample!(app, series::RoiChannelSeries, frame::ChannelFrame, timestamp::Float64)
    push!(series.timestamps, timestamp)
    push!(series.photons, frame.photons)
    append_smooth_value!(app, series.photons, series.photons_smooth, series.timestamps, series.photons_kalman)
    push!(series.lifetime, frame.lifetime)
    append_smooth_value!(app, series.lifetime, series.lifetime_smooth, series.timestamps, series.lifetime_kalman)
    push!(series.concentration, frame.concentration)
    append_smooth_value!(app, series.concentration, series.concentration_smooth, series.timestamps, series.concentration_kalman)
    return nothing
end

"""
    accumulate_frame!(app, app_run, record::FrameRecord)

Append one analyzed histogram to the GUI-side histories: its ROI's per-channel
series and the global per-frame series.
"""
function accumulate_frame!(app, app_run, record::FrameRecord)
    sample = record.sample
    index = clamp(record.roi_index, 1, length(app_run.ch1_rois))
    accumulate_roi_sample!(app, app_run.ch1_rois[index], sample.ch1, sample.timestamps)
    accumulate_roi_sample!(app, app_run.ch2_rois[index], sample.ch2, sample.timestamps)
    push!(app_run.protocol_setpoint, sample.protocol_setpoint)
    push!(app_run.command1, sample.command1)
    push!(app_run.command2, sample.command2)
    push!(app_run.timestamps, sample.timestamps)
    app_run.i = Int(sample.frame_index)
    return nothing
end

"""
    publish_frame!(series::ChannelSeries, frame::ChannelFrame)

Publish one frame's histogram/fit/counts onto one channel's "latest value"
Observables (Histogram plot).
"""
function publish_frame!(series::ChannelSeries, frame::ChannelFrame)
    series.histogram[] = frame.histogram
    series.fit[] = frame.fit
    series.counts[] = frame.photons
    return nothing
end

"""
    recompute_roi_smooth!(app, series::RoiChannelSeries)

Recompute one ROI's smoothed photon-count, lifetime, and concentration
series (`recompute_smooth_series!`, smoothing.jl) after a smoothing-level
change (handlers_layout.jl). The caller marks the display dirty.
"""
function recompute_roi_smooth!(app, series::RoiChannelSeries)
    recompute_smooth_series!(app, series.photons, series.photons_smooth, series.timestamps, series.photons_kalman)
    recompute_smooth_series!(app, series.lifetime, series.lifetime_smooth, series.timestamps, series.lifetime_kalman)
    recompute_smooth_series!(app, series.concentration, series.concentration_smooth, series.timestamps, series.concentration_kalman)
    return nothing
end

"""
    reset_channel_series!(series::ChannelSeries)

Clear one channel's "latest frame" counter ahead of a fresh run
(histogram/fit are left as-is — `clear_runtime_plots!` NaN-fills them).
"""
function reset_channel_series!(series::ChannelSeries)
    series.counts[] = 0.0
    return nothing
end

"""
    rebuild_roi_series!(app, app_run; n_rois=nothing)

Replace `app_run.ch1_rois`/`ch2_rois` with fresh, empty histories: `n_rois`
of them (a run's ROIs: a Playback session's may differ from the drawn
ones), else one per drawn ROI (`app_run.rois[]`) when ROI mode
(`app.roi.active`) is on, a single one otherwise. Index `k` holds ROI `k`'s
results. Callers must re-render both plot slots (`render_plot!`)
afterwards: the curves are bound to the old vectors.
"""
function rebuild_roi_series!(app, app_run; n_rois::Union{Nothing, Int} = nothing)
    n = n_rois !== nothing ? max(1, n_rois) : app.roi.active ? max(1, length(app_run.rois[])) : 1
    app_run.ch1_rois = [RoiChannelSeries() for _ in 1:n]
    app_run.ch2_rois = [RoiChannelSeries() for _ in 1:n]
    return nothing
end

"""
    reset_acquisition_state!(app, app_run; n_rois=nothing)

Clear every GUI-side history and counter ahead of a fresh run. The global
histories are emptied in place (plot bindings keep them); the per-ROI ones
are rebuilt (see `rebuild_roi_series!`).
"""
function reset_acquisition_state!(app, app_run; n_rois::Union{Nothing, Int} = nothing)
    foreach(reset_channel_series!, channel_series(app_run))
    rebuild_roi_series!(app, app_run; n_rois = n_rois)
    empty!(app_run.protocol_setpoint)
    empty!(app_run.command1)
    empty!(app_run.command2)
    empty!(app_run.timestamps)
    app_run.i = 0
    return nothing
end

"""
    initial_guess_for_lifetimes(selected_lifetimes::AbstractString)::Vector{Float64}

Map the Lifetimes menu selection ("1 lifetime"/"2 lifetimes"/"3 lifetimes") to
the corresponding initial parameter guess for the MLE fit.
"""
function initial_guess_for_lifetimes(selected_lifetimes::AbstractString)::Vector{Float64}
    if selected_lifetimes == "1 lifetime"
        return [3.0, 0.0, 5.0e-5]
    elseif selected_lifetimes == "3 lifetimes"
        return [3.0, 0.5, 0.5, 0.5, 0.5, 0.0, 5.0e-5]
    else
        return [3.0, 0.5, 0.5, 0.0, 5.0e-5]
    end
end

# -----------------------------------------------------------------------------
# START
# -----------------------------------------------------------------------------

"""
    spawn_acquisition_worker!(app_run, out, histograms, initial_guess; source_done=nothing)

Launch the analysis worker (`start_realtime`, analysis/acquisition.jl) on
its own thread and store it on `app_run.worker_task`. `Threads.@spawn`,
not `@async`: the worker is CPU-bound (the MLE fit dominates its frame
time), and it never touches the GUI — its results reach it through the
exchanges. It reads the passes the SPC engine publishes in `histograms`;
`source_done` (Playback) lets it end once the replay is over and every
pass taken.
"""
function spawn_acquisition_worker!(app_run, out::AnalysisOutput, histograms::Channel{FLIMCore.HistoClamp}, initial_guess;
                                   source_done::Union{Nothing, Threads.Atomic{Bool}} = nothing)
    running, paused = app_run.running, app_run.paused
    app_run.worker_task = Threads.@spawn start_realtime(out, running, histograms; initial_guess=initial_guess, paused=paused,
                                                        source_done=source_done)
    return nothing
end

"""
    scan_request(app, app_run, order)::ScanRequest

Snapshot of everything the DAQ loop needs for this run's slots.
"""
function scan_request(app, app_run, order::Vector{Int})::ScanRequest
    return ScanRequest(
        copy(app_run.rois[]), copy(order), app.roi.active,
        app.roi.v_min_x, app.roi.v_max_x, app.roi.v_min_y, app.roi.v_max_y,
        app.protocol.points_per_roi, app.protocol.spiral_turns,
        app.protocol.scan_time, app.protocol.shift_time,
        app_run.imported_image_size, app_run.spc.settings.inverser_routage
    )
end


"""Modes of the mode menu: Playback with the session's settings (to reproduce it) or the current ones (to try others)."""
const PLAYBACK_SESSION_MODE = "Playback: session"
const PLAYBACK_CURRENT_MODE = "Playback: current"
const RUN_MODES = ["Realtime", PLAYBACK_SESSION_MODE, PLAYBACK_CURRENT_MODE]

"""
    clamp_command(app, app_run, order, dir)::FLIMCore.Clamp

What the SPC engine needs for this run: the ROIs (their routing codes, empty
without ROIs), the session folder where it records each card's stream
(`dir`/spc), and the programmed scan — in samples of the DAQ loop, as the
pass counter counts it — with the sample period, for its check of M3 − M0.
The pause only serves its simulation, which makes the passes the NI would.
"""
function clamp_command(app, app_run, order::Vector{Int}, dir::AbstractString)::FLIMCore.Clamp
    rate = app_run.config.sample_rate_hz
    return FLIMCore.Clamp(rois = copy(order), ordre = copy(order), dossier = joinpath(dir, "spc"),
                          scan_s = samples_of(app.protocol.scan_time, rate) / rate,
                          pause_s = samples_of(app.protocol.shift_time, rate) / rate,
                          echantillon_s = 1 / rate)
end

"""
    run_info(app, app_run, order; mode="Realtime", session=nothing)::Dict{String, Any}

What the journal writes to the run's run.toml (`session_info`,
analysis/session.jl). For Playback: the session's ROIs and calibration,
the settings the replay used (the session's or the current ones), and the
session replayed.
"""
function run_info(app, app_run, order::Vector{Int}; mode::AbstractString = "Realtime",
                  session::Union{Nothing, Session} = nothing, settings::Union{Nothing, AnalysisSettings} = nothing)::Dict{String, Any}
    playback = session !== nothing
    roi_settings = playback ? settings_from_dict(RoiSettings, Dict{String, Any}()) : app.roi
    if playback
        range = get(get(session.info, "roi", Dict{String, Any}()), "galvo_range_mV", nothing)
        range === nothing || ((roi_settings.v_min_x, roi_settings.v_max_x, roi_settings.v_min_y, roi_settings.v_max_y) = Int.(range))
    end
    info = session_info(;
        mode = playback ? "Playback" : mode, rois = app_run.run_rois, order, roi_active = !isempty(order),
        roi_settings,
        image_size = playback ? session.image_size : app_run.imported_image_size,
        spc = app_run.spc.settings, spc_settings_path = app_run.spc.settings_path,
        layout = settings === nothing ? app.layout : settings.layout,
        protocol = settings === nothing ? app.protocol : settings.protocol,
        controller = settings === nothing ? app.controller : settings.controller,
        irf_source = String(get(loaded_irf_info(), "source", "")),
        sample_rate_hz = app_run.config.sample_rate_hz,
        daq = Dict{String, Any}(
            "bench_config" => app_run.config.source,
            "backend" => String(app_run.config.backend),
            "state_at_start" => string(loop_status(app_run.exchange).state),
            "pass_counter" => app_run.config.pass_counter,
            "pass_terminal" => isempty(app_run.config.pass_terminal) ? "default (PFI13 for ctr1)" : app_run.config.pass_terminal
        ))
    if playback
        info["playback"] = Dict{String, Any}("session" => session.dir, "session_mode" => get(session.info, "mode", ""),
                                             "settings" => mode == PLAYBACK_CURRENT_MODE ? "current" : "session")
        info["roi"]["calibration_size"] = get(get(session.info, "roi", Dict{String, Any}()), "calibration_size",
                                              roi_voltage_calibration_size)
    end
    return info
end

"""
    abort_start!(app_run, blocks)

Undo the `running`/`paused` flags claimed by `start_pressed` and restore the
button labels when a start is abandoned.
"""
function abort_start!(app_run, blocks)
    app_run.running[] = false
    app_run.paused[] = false
    update_start_button_label!(app_run, blocks)
    update_stop_button_label!(app_run, blocks)
    return nothing
end

irf_loaded() = RUNTIME[].irf !== nothing && RUNTIME[].tcspc_window_size !== nothing

"""
    realtime_start_refusal(app, app_run)::String

Why the Realtime procedure can't start now ("" if it can): offline (no
driver on this computer), the IRF (missing, or taken with other card or
detector settings, `irf_mismatches`), the free space in the recording
folder (`RECORDING_MIN_S` of recording at least), the DAQ loop (it plays
the scans, the routing code and the pass signal), the SPC engine (it
counts), and at most `ROI_MAX` ROIs (the routing code has 4 bits, code 0
reserved).
"""
function realtime_start_refusal(app, app_run)::String
    isempty(app_run.offline) || return app_run.offline
    irf_loaded() || return "Load an IRF file before starting"
    mismatches = irf_mismatches(loaded_irf_info(), app_run.spc.settings; applied = spc_applied_settings(app_run.spc))
    isempty(mismatches) ||
        return "IRF taken with other settings: " * first(mismatches) * (length(mismatches) > 1 ? " (+$(length(mismatches) - 1) more, see the log)" : "")
    free, seconds, text = recording_space(app_run.spc.settings)
    free >= 0 && seconds < RECORDING_MIN_S && return "Recording folder nearly full: " * text
    daq = loop_status(app_run.exchange).state
    daq == LOOP_READY || return "DAQ not ready ($(LOOP_STATE_NAMES[daq])): CONNECT it first"
    spc = spc_state(app_run.spc)
    spc == :pret || return spc == :none ? "SPC engine not running: CONNECT it in the SPC window" :
                           "SPC engine busy ($(SPC_ENGINE_STATE_NAMES[spc]))"
    n_rois = length(app_run.rois[])
    app.roi.active && n_rois > ROI_MAX && return "$n_rois ROIs: the routing code tells only $ROI_MAX apart"
    return ""
end

"""
    playback_start_refusal(app_run)::String

Why Playback can't start now ("" if it can): no session picked (folder
button), not a session, or no IRF (neither the session's irf.csv nor one
loaded).
"""
function playback_start_refusal(app_run)::String
    dir = app_run.playback.dir
    isempty(dir) && return "Pick a session to replay first"
    is_session_dir(dir) || return "Not a session (no spc/*.spc): $(basename(dir))"
    isfile(joinpath(dir, "irf.csv")) || irf_loaded() || return "No IRF: the session has no irf.csv and none is loaded"
    return ""
end

"""
    start_pressed(app, app_run, blocks)

START in the mode of the mode menu. Claims `running[]` synchronously (so a
second click is caught), then does the rest on an `@async` task this
handler doesn't wait on — this function runs on GLMakie's render-loop task,
and anything that blocks it blocks rendering.

- Realtime, once the DAQ loop and the SPC engine are both ready: computes
  the ROI visiting order off the GUI thread (exponential in the ROI count),
  creates the session folder in the recording folder (`sessions_root`),
  opens the journal run, arms the SPC engine (`clamp_command`: FIFO, one
  pass per scan, the ROI from the routing code, each card's stream recorded
  in the session), then starts the DAQ loop's slots and the analysis
  worker. Everything is written to the session as the run goes.
- Playback (`start_playback!`): replays the picked session through its own
  SPC engine and the same analysis.

The refresh tick takes it from there.
"""
function start_pressed(app, app_run, blocks)
    if app_run.running[]
        @info "Already running"
        return
    end

    if app_run.run_open
        @info "Previous run is still shutting down; ignoring START"
        show_status!(blocks, "Finishing previous run…")
        return
    end

    if app_run.irf_reload_pending               # picked during the previous run, or a session's IRF in use
        app_run.irf_reload_pending = false
        init_irf_runtime!(app_run.spc.settings; ask = false)
    end

    mode = blocks.mode_menu.selection[]
    mode isa AbstractString || (mode = "Realtime")
    mode in (PLAYBACK_SESSION_MODE, PLAYBACK_CURRENT_MODE) && return start_playback!(app, app_run, blocks, mode)

    refusal = realtime_start_refusal(app, app_run)
    if !isempty(refusal)
        # The refusals that are bench problems carry their code.
        if startswith(refusal, "IRF") || startswith(refusal, "Load an IRF")
            differences = irf_mismatches(loaded_irf_info(), app_run.spc.settings; applied = spc_applied_settings(app_run.spc))
            refusal = report_problem!("FIT-01", refusal; quiet_s = 0)
            isempty(differences) || @warn "IRF settings differ from the current ones" differences = join(differences, "; ")
        elseif startswith(refusal, "Recording folder")
            refusal = report_problem!("ENV-05", refusal; quiet_s = 0)
        else
            @warn "Cannot start the Realtime acquisition" reason=refusal
        end
        show_status!(blocks, refusal)
        return
    end

    @info "Starting acquisition"
    app_run.running[] = true
    app_run.paused[] = false
    ex = app_run.exchange
    engine = app_run.spc.engine

    @async begin
        initial_guess = selected_initial_guess(blocks)

        rois = app_run.rois[]
        split_rois = app.roi.active && !isempty(rois)
        order = split_rois ? fetch(Threads.@spawn roi_visit_order(rois)) : Int[]

        if !app_run.running[]
            @info "Acquisition stopped before it finished starting"
            return nothing
        end

        app_run.run_mode = "Realtime"
        app_run.run_rois = copy(rois)
        prepare_run_display!(app, app_run, blocks; n_rois = split_rois ? length(rois) : 1)
        app_run.roi_order = order

        t = time()
        dir = try
            new_run_dir(sessions_root(app_run.spc.settings), t)
        catch e
            show_status!(blocks, report_problem!("ENV-05", "cannot create the session folder in $(sessions_root(app_run.spc.settings)): " *
                                                           sprint(showerror, e); level = :error, quiet_s = 0, exception = (e, catch_backtrace())))
            abort_start!(app_run, blocks)
            return nothing
        end
        app_run.run_dir = dir
        @info "Realtime run started" session=dir rois=length(rois) order=order roi_active=app.roi.active scan_ms=app.protocol.scan_time shift_ms=app.protocol.shift_time
        app_run.run_open = true
        app_run.run_started_ns = time_ns()
        send_journal!(ex.journal, JournalRunStart(t, dir, run_info(app, app_run, order), loaded_irfs(), loaded_irf_info()))

        # The SPC engine first: its FIFO counts from the start; the passes are
        # delimited by the cards' own markers, and the photons of the moves
        # and pauses carry the reserved routing code.
        while isready(engine.histogrammes)
            take!(engine.histogrammes)              # left over from a previous run
        end
        ex.stop[] = false
        app_run.spc.clamp_stop_sent = false
        FLIMCore.commander!(engine, clamp_command(app, app_run, order, dir))
        send_command!(ex, StartCommand(scan_request(app, app_run, order)))

        out = AnalysisOutput(ex; roi_order=order, stats=app_run.worker_stats)
        spawn_acquisition_worker!(app_run, out, engine.histogrammes, initial_guess)
        show_status!(blocks, "Realtime: session $(basename(dir))")
        return nothing
    end

    return nothing
end

"""The initial MLE guess for the Lifetimes menu's selection."""
function selected_initial_guess(blocks)::Vector{Float64}
    selected_lifetimes = blocks.lifetimes_menu.selection[]
    selected_lifetimes isa AbstractString || (selected_lifetimes = "2 lifetimes")
    return initial_guess_for_lifetimes(selected_lifetimes)
end

"""
    prepare_run_display!(app, app_run, blocks; n_rois)

Fresh histories for a run (`n_rois` per-ROI series: index k = ROI k),
both plots rebound, diagnostics and display cursors reset, the analysis
settings published, and the PI commands cleared.
"""
function prepare_run_display!(app, app_run, blocks; n_rois::Int)
    ex = app_run.exchange
    reset_acquisition_state!(app, app_run; n_rois = n_rois)
    render_plot!(app, app_run, blocks, :plot1)
    render_plot!(app, app_run, blocks, :plot2)

    state_display = app_run.display
    reset_diagnostics!(state_display)
    state_display.frame_cursor = reset_cursor(ex.frames)
    state_display.slot_cursor = reset_cursor(ex.slots)
    state_display.last_frame_count = 0
    state_display.last_frame_count_time_ns = time_ns()
    state_display.frame_rate_hz = NaN
    publish_analysis_settings!(app, app_run; force=true)
    set_command_values!(ex, NaN, NaN)
    app_run.worker_output = nothing
    # Fresh diagnostics: the previous run's pass and analysis problems are history.
    clear_problems!()
    app_run.worker_stats = WorkerStats()
    app_run.spc.clamp_status = nothing
    app_run.diagnosed_t = 0.0
    app_run.run_dir = ""
    return nothing
end

"""The Playback frequency box: the target pass rate in Hz, 0 (or empty) for the experiment's own pace."""
function playback_target_hz(blocks)::Float64
    value = tryparse(Float64, strip(String(blocks.target_freq_textbox.stored_string[])))
    return value === nothing || !isfinite(value) || value < 0 ? 0.0 : value
end

"""
    start_playback!(app, app_run, blocks, mode)

START in Playback: replay the picked session (`app_run.playback.dir`)
through its own SPC engine (`FLIMCore.source_session`) and the same
analysis as Realtime, with the session's ROIs, visiting order, IRF and
calibration. `mode`: with the session's layout, gains and protocol
(`PLAYBACK_SESSION_MODE`, to reproduce what happened) or the current ones
(`PLAYBACK_CURRENT_MODE`, e.g. another binning or Kalman), edits applying
live. The PI outputs are simulated: computed and shown, never sent to the
DAQ loop. Speed: the frequency box's pass rate, 0 = the recorded pace. The
engine checks M3 − M0 against the session's programmed scan. Journaled as
a run of its own (`<date>_playback` in the sessions folder); the replay
engine records nothing.
"""
function start_playback!(app, app_run, blocks, mode::AbstractString)
    refusal = playback_start_refusal(app_run)
    if !isempty(refusal)
        @warn "Cannot start Playback" reason=refusal
        show_status!(blocks, refusal)
        return nothing
    end

    session = try
        read_session(app_run.playback.dir)
    catch e
        show_status!(blocks, report_problem!("PLAY-01", sprint(showerror, e); level = :error, quiet_s = 0,
                                             exception = (e, catch_backtrace())))
        return nothing
    end
    order = session.roi_order
    if length(order) > ROI_MAX || any(k -> !(1 <= k <= length(session.rois)), order)
        show_status!(blocks, report_problem!("PLAY-01", "ROIs unreadable in run.toml: order $(order), $(length(session.rois)) ROI(s)"; quiet_s = 0))
        return nothing
    end

    speed = playback_speed(playback_target_hz(blocks), session)
    @info "Starting Playback" session=session.dir settings=mode speed=speed
    app_run.running[] = true
    app_run.paused[] = false
    ex = app_run.exchange

    # The session's IRF for the fit; the user's own comes back at the next START.
    if !isempty(session.irfs)
        set_irfs!(session.irfs; info = session.irf_info)
        app_run.irf_reload_pending = true
    end

    playback = app_run.playback
    playback.session = session
    playback.fin = nothing
    playback.stop_sent = false
    playback.source_done[] = false
    playback.session_settings = mode == PLAYBACK_SESSION_MODE
    engine = try
        FLIMCore.demarrer_moteur(app_run.spc.settings; source = FLIMCore.source_session(session.dir; vitesse = speed))
    catch e
        show_status!(blocks, report_problem!("PLAY-01", "cannot start the replay: " * sprint(showerror, e); level = :error,
                                             quiet_s = 0, exception = (e, catch_backtrace())))
        abort_start!(app_run, blocks)
        return nothing
    end
    playback.engine = engine
    # Commands wait in the engine's queue until it has opened the session.
    rate, scan_s, sample_s = session_pass_timing(session)
    pause_s = isfinite(rate) && rate > 0 ? 1 / rate - scan_s : 0.05
    FLIMCore.commander!(engine, FLIMCore.Clamp(rois = copy(order), ordre = copy(order), scan_s = scan_s, pause_s = pause_s,
                                               echantillon_s = sample_s))

    app_run.run_mode = "Playback"
    app_run.run_rois = copy(session.rois)
    app_run.roi_order = order
    prepare_run_display!(app, app_run, blocks; n_rois = isempty(order) ? 1 : max(1, maximum(order)))
    settings = playback.session_settings ? session_analysis_settings(session) : nothing
    settings === nothing || publish_settings!(ex, settings)

    t = time()
    dir = try
        new_run_dir(sessions_root(app_run.spc.settings), t; suffix = "_playback")
    catch e
        @warn "Cannot create the run folder; Playback runs without a journal" error=string(e)
        ""
    end
    app_run.run_dir = dir
    @info "Playback started" session=session.dir run=dir settings=mode speed=speed order=order
    app_run.run_open = true
    app_run.run_started_ns = time_ns()
    isempty(dir) || send_journal!(ex.journal, JournalRunStart(t, dir, run_info(app, app_run, order; mode, session, settings),
                                                             loaded_irfs(), loaded_irf_info()))

    out = AnalysisOutput(ex; roi_order = order, drive_outputs = false, stats = app_run.worker_stats)
    spawn_acquisition_worker!(app_run, out, engine.histogrammes, selected_initial_guess(blocks);
                              source_done = playback.source_done)
    what = playback.session_settings ? "session settings" : "current settings"
    show_status!(blocks, "Playback: $(basename(session.dir)), $what, $(round(speed; sigdigits = 3))×, PI simulated")
    return nothing
end

function pause_pressed(app_run)
    if app_run.running[]
        app_run.paused[] = true
    end
    return nothing
end

function resume_pressed(app_run)
    if app_run.running[]
        app_run.paused[] = false
    end
    return nothing
end

"""
    stop_pressed(app_run)

STOP (and CLEAR): raise the DAQ loop's stop flag — it sees it within one
readback block, stops the tasks and zeroes every output (plan §7.4) —, stop
the SPC engine's Realtime measurement (Playback: the replay), and clear
`running` so the analysis worker ends after its current pass. Nothing here waits: the refresh
tick notices when all three have stopped and closes the run
(`finalize_run!`, gui/refresh.jl).
"""
function stop_pressed(app_run)
    if app_run.run_mode == "Playback"
        playback_stop!(app_run.playback)
    else
        request_stop!(app_run.exchange)
        spc_stop_clamp!(app_run.spc)
    end

    if !app_run.running[]
        @info "Not running"
        return
    end

    @info "Stopping acquisition"
    app_run.paused[] = false
    app_run.running[] = false
    return nothing
end

"""
    tasks_still_running(app_run)::Bool

True while a previous run is still being finalized (worker, scan or SPC
measurement still winding down, journal run open).
"""
tasks_still_running(app_run)::Bool = app_run.run_open

"""Stop a Playback replay (STOP, end of run); sent once per run."""
function playback_stop!(playback::PlaybackRun)
    engine = playback.engine
    (engine === nothing || playback.stop_sent) && return nothing
    FLIMCore.etat_moteur(engine) == :clamp || FLIMCore.etat_moteur(engine) == :demarrage || return nothing
    playback.stop_sent = FLIMCore.commander!(engine, FLIMCore.Arret())
    return nothing
end
