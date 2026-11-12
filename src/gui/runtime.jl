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
    on = isfinite(sample.command1) && sample.command1 > 0
    push!(app_run.stimulation, on ? 1.0 : NaN)
    push!(app_run.command1, sample.command1)
    push!(app_run.timestamps, sample.timestamps)
    app_run.i = Int(sample.frame_index)
    return nothing
end

"""
    publish_frame!(series::ChannelSeries, frame::ChannelFrame)

Publish one frame's histogram and fit onto one channel's "latest value"
Observables (Histogram plot). The counts bar shows the card's count rate
instead, fed continuously by the refresh tick (`spc_channel_rates`).
"""
function publish_frame!(series::ChannelSeries, frame::ChannelFrame)
    series.histogram[] = frame.histogram
    series.fit[] = frame.fit
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
    rebuild_roi_series!(app, app_run; n_rois = n_rois)
    empty!(app_run.protocol_setpoint)
    empty!(app_run.stimulation)
    empty!(app_run.command1)
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
    run_modes(app, app_run) -> (excitation_galvos, detection_galvos)

How a START excites and detects: with ROIs to scan (ROI on, at least one
drawn), the Protocol panel's two toggles — Excitation (`excitation_galvos`)
and Detection (`[clamp] images` off); without (ROI off, or none drawn),
both by image: the galvos unused, the whole image in one histogram.
"""
function run_modes(app, app_run)::Tuple{Bool, Bool}
    app.roi.active && !isempty(app_run.rois[]) || return (false, false)
    return (app.protocol.excitation_galvos, !app_run.spc.settings.images)
end

"""What a START's modes read as on the status line ("" for both by the galvos, the usual Realtime)."""
function run_modes_text(excitation_galvos::Bool, detection_galvos::Bool, images_per_block::Integer, whole_image::Bool)::String
    excitation_galvos && detection_galvos && return ""
    blocks = "$(images_per_block) images per block"
    whole_image && return " (whole image, $blocks)"
    return " (excitation $(excitation_galvos ? "galvos" : "image"), detection " *
           (detection_galvos ? "galvos" : "images, $blocks") * ")"
end

"""
    scan_request(app, app_run, order; modes=run_modes(app, app_run))::ScanRequest

Snapshot of everything the DAQ loop needs for this run's slots: how it
excites and detects (`modes`), each ROI's spiral of `POINTS_PER_ROI`
points, the opto laser's PWM included (at `PWM_FREQUENCY_HZ`, the Protocol
panel's duty cycle, while its toggle is on).
"""
function scan_request(app, app_run, order::Vector{Int}; modes::Tuple{Bool, Bool} = run_modes(app, app_run))::ScanRequest
    p = app.protocol
    excitation_galvos, detection_galvos = modes
    return ScanRequest(
        copy(app_run.rois[]), copy(order), app.roi.active,
        app.roi.v_min_x, app.roi.v_max_x, app.roi.v_min_y, app.roi.v_max_y,
        POINTS_PER_ROI, p.spiral_full_turns, p.scan_time, p.shift_time,
        app_run.imported_image_size, app_run.spc.settings.inverser_routage, excitation_galvos, detection_galvos,
        p.PWM_active ? Float64(PWM_FREQUENCY_HZ) : 0.0, p.PWM_duty / 100
    )
end

"""
    pwm_played(protocol, rate) -> (period, on)

The opto laser's PWM as the DAQ loop plays it at `rate` (`pwm_samples`):
the period and its opto phase, in whole samples; `(0, 0)` without PWM or at
a rate too low for `PWM_FREQUENCY_HZ` (START refuses it, `pwm_refusal`).
"""
function pwm_played(protocol::ProtocolSettings, rate::Real)::Tuple{Int, Int}
    protocol.PWM_active || return (0, 0)
    try
        return pwm_samples(PWM_FREQUENCY_HZ, protocol.PWM_duty / 100, rate)
    catch
        return (0, 0)
    end
end

"""The share of each scan the opto laser's PWM gives its opto phase (`pwm_played`); 0 without PWM."""
pwm_opto_fraction(protocol::ProtocolSettings, rate::Real)::Float64 =
    ((period, on) = pwm_played(protocol, rate); period == 0 ? 0.0 : on / period)

"""
    pwm_text(protocol, rate)::String

The opto laser's PWM as the DAQ loop plays it — its frequency and duty
cycle in whole samples, which can differ from `PWM_FREQUENCY_HZ` and the
panel's duty cycle — for the status line and the log; "" without PWM.
"""
function pwm_text(protocol::ProtocolSettings, rate::Real)::String
    period, on = pwm_played(protocol, rate)
    period == 0 && return ""
    return "PWM $(round(rate / period; sigdigits = 4)) Hz, opto $(round(100 * on / period; digits = 1)) % ($on of $period samples)"
end

"""
    pwm_refusal(protocol, rate)::String

Why the opto laser's PWM can't run ("" if it can): the NI switches its
outputs once per sample, so `PWM_FREQUENCY_HZ` needs a `rate` of twice that
at least (`[timing] sample_rate_hz`, config/bench.toml).
"""
function pwm_refusal(protocol::ProtocolSettings, rate::Real)::String
    protocol.PWM_active || return ""
    PWM_FREQUENCY_HZ <= rate / 2 && return ""
    return "PWM of $PWM_FREQUENCY_HZ Hz: a sample rate of $(2 * PWM_FREQUENCY_HZ) Hz at least ([timing] sample_rate_hz: $(round(Int, rate)) Hz), the NI switching its outputs once per sample"
end

"""
    images_command(rois, order, image_size, settings, dir; pwm=false)::FLIMCore.ImagesROI

The detection by image ([clamp] images): the SPC engine images with the
settings' geometry and bins, every `images_par_bloc` images, the photons of
each ROI of `order` (its pixels on the `image_size` image it was drawn on,
`roi_pixel_mask`) — the whole image without ROIs —, each card's stream
recorded in `dir`/spc ("" : nothing). The k-th ROI of `order` gets code k:
`order` in drawn order (sorted), so that a ROI's code is its drawn index.
"""
function images_command(rois::Vector{RoiCoordinates}, order::Vector{Int}, image_size::Tuple{Int, Int},
                        settings::FLIMCore.Reglages, dir::AbstractString; pwm::Bool = false)::FLIMCore.ImagesROI
    pixels = [roi_pixel_mask(rois[k].xs, rois[k].ys, image_size...) for k in order]
    # With the opto laser's PWM, its opto phases carry the reserved code: their photons thrown away.
    return FLIMCore.ImagesROI(FLIMCore.geometrie(settings); rois = pixels, taille = image_size,
                              trames = settings.images_par_bloc, dossier = isempty(dir) ? "" : joinpath(dir, "spc"),
                              jeter_hors_roi = pwm)
end

"""
    images_start_refusal(app, app_run)::String

What keeps the detection by image from starting ("" if nothing): the ROIs
must have been drawn on an image of the microscope's scanner (the ROI
popup's Image button), whose pixels they bin — not on the galvo scan's,
whose pixels are the galvos'. (The protocol in volts is checked for every
mode, `realtime_start_refusal`.)
"""
function images_start_refusal(app, app_run)::String
    split_rois = app.roi.active && !isempty(app_run.rois[])
    split_rois && minimum(app_run.imported_image_size) <= 0 &&
        return "Detection in images: no image for the ROIs — take one with the ROI popup's Image button"
    split_rois && app_run.roi_image_source == :galvos &&
        return "Detection in images: the ROIs were drawn on the galvo scan, in the galvos' coordinates — " *
               "draw them on an image of the scanner (ROI popup's Image button)"
    return ""
end


"""
    protocol_volts_problem(protocol, limit)::String

The first of the protocol's values outside 0 V–`limit` (`[limits]
command_max_v`) when it gives the command voltage — "1.5 V is outside
0–1.0 V" —, "" if none: with the protocol in volts.
"""
function protocol_volts_problem(protocol::ProtocolSettings, limit::Real)::String
    bad = [v for v in protocol.setpoints if isfinite(v) && !(0 <= v <= limit)]
    return isempty(bad) ? "" : "$(first(bad)) V is outside 0–$(limit) V"
end

"""What made the ROIs' image, for run.toml: "scanner" (Image button), "galvo scan" (Galvo scan button), "" (none)."""
roi_image_source_name(source::Symbol)::String = source == :galvos ? "galvo scan" : source == :scanner ? "scanner" : ""

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
                          pause_s = pause_samples(app.protocol.shift_time, rate) / rate,     # 0 ms: the pass signal's gap
                          echantillon_s = 1 / rate, opto = pwm_opto_fraction(app.protocol, rate))
end

"""
    run_info(app, app_run, order; mode="Realtime", session=nothing, settings=nothing, modes=nothing)::Dict{String, Any}

What the journal writes to the run's run.toml (`session_info`,
analysis/session.jl), with how the run excites and detects (`modes`, as
START took them; `run_modes` by default). For Playback: the session's
ROIs, modes and calibration, the settings the replay used (the session's
or the current ones), and the session replayed.
"""
function run_info(app, app_run, order::Vector{Int}; mode::AbstractString = "Realtime",
                  session::Union{Nothing, Session} = nothing, settings::Union{Nothing, AnalysisSettings} = nothing,
                  modes::Union{Nothing, Tuple{Bool, Bool}} = nothing)::Dict{String, Any}
    playback = session !== nothing
    roi_settings = playback ? settings_from_dict(RoiSettings, Dict{String, Any}()) : app.roi
    if playback
        range = get(get(session.info, "roi", Dict{String, Any}()), "galvo_range_mV", nothing)
        range === nothing || ((roi_settings.v_min_x, roi_settings.v_max_x, roi_settings.v_min_y, roi_settings.v_max_y) = Int.(range))
    end
    excitation_galvos, detection_galvos = playback ? session_modes(session) : something(modes, run_modes(app, app_run))
    info = session_info(;
        mode = playback ? "Playback" : mode, rois = app_run.run_rois, order, roi_active = !isempty(order),
        roi_settings, excitation_galvos, detection_galvos,
        image_size = playback ? session.image_size : app_run.imported_image_size,
        image_source = playback ? String(get(get(session.info, "roi", Dict{String, Any}()), "image_source", "")) :
                       roi_image_source_name(app_run.roi_image_source),
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
            "pass_terminal" => isempty(app_run.config.pass_terminal) ? "default (PFI13 for ctr1)" : app_run.config.pass_terminal,
            # The opto laser's PWM as played (whole samples): [period, opto phase]; empty without PWM.
            "pwm_samples" => playback ? Int[] : filter(>(0), collect(pwm_played(app.protocol, app_run.config.sample_rate_hz)))
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
reserved), the opto PWM (`pwm_refusal`), with the protocol in volts its
values within 0 V and `command_max_v` (`protocol_volts_problem`), and a
setpoint on channel 2 or the photon ratio (`needs_two_channels`) with a
single card.
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
    pwm = pwm_refusal(app.protocol, app_run.config.sample_rate_hz)
    isempty(pwm) || return pwm
    if protocol_in_volts(app.protocol)
        problem = protocol_volts_problem(app.protocol, app_run.config.command_max_v)
        isempty(problem) || return "Protocol in volts: " * problem
    end
    kind = app.protocol.setpoint_kind
    app.protocol.active && needs_two_channels(kind) && length(app_run.spc.settings.series) < 2 &&
        return "Setpoint $kind: needs channel 2, and [verification] series lists one card"
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

    if app_run.galvo_scan !== nothing
        show_status!(blocks, "Galvo scan running (ROI popup): wait for its end, or stop it")
        return
    end

    mode = blocks.mode_menu.selection[]
    mode isa AbstractString || (mode = "Realtime")
    mode in (PLAYBACK_SESSION_MODE, PLAYBACK_CURRENT_MODE) && return start_playback!(app, app_run, blocks, mode)

    excitation_galvos, detection_galvos = run_modes(app, app_run)
    images = !detection_galvos
    refusal = realtime_start_refusal(app, app_run)
    isempty(refusal) && images && (refusal = images_start_refusal(app, app_run))
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
        # The galvos visit the ROIs in the shortest tour; without them, every ROI at once (ROI k is code k).
        galvos = excitation_galvos || detection_galvos
        order = !split_rois ? Int[] : galvos ? fetch(Threads.@spawn roi_visit_order(rois)) : collect(1:length(rois))

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
        @info "Realtime run started" session=dir rois=length(rois) order=order roi_active=app.roi.active scan_ms=app.protocol.scan_time shift_ms=app.protocol.shift_time excitation=(excitation_galvos ? "galvos" : "image") detection=(images ? "images" : "galvos") images_per_block=app_run.spc.settings.images_par_bloc pwm=pwm_text(app.protocol, app_run.config.sample_rate_hz) protocol_in_volts=protocol_in_volts(app.protocol)
        app_run.run_open = true
        app_run.run_started_ns = time_ns()
        send_journal!(ex.journal, JournalRunStart(t, dir, run_info(app, app_run, order; modes = (excitation_galvos, detection_galvos)),
                                                  loaded_irfs(), loaded_irf_info()))

        # The SPC engine first: its FIFO counts from the start; the passes are
        # delimited by the cards' own markers, and the photons of the moves
        # and pauses carry the reserved routing code.
        while isready(engine.histogrammes)
            take!(engine.histogrammes)              # left over from a previous run
        end
        ex.stop[] = false
        app_run.spc.clamp_stop_sent = false
        if images
            # Detection by image: the scanner's whole images, each ROI's pixels (codes in drawn order).
            FLIMCore.commander!(engine, images_command(rois, sort(order), app_run.imported_image_size, app_run.spc.settings, dir;
                                                       pwm = app.protocol.PWM_active))
        else
            FLIMCore.commander!(engine, clamp_command(app, app_run, order, dir))
        end
        send_command!(ex, StartCommand(scan_request(app, app_run, order; modes = (excitation_galvos, detection_galvos))))
        # The excitation by image lights every ROI at once: one PI for all of them.
        out = AnalysisOutput(ex; roi_order=order, stats=app_run.worker_stats, global_pi=!excitation_galvos,
                             command_full_scale_v=app_run.config.command_full_scale_v)
        spawn_acquisition_worker!(app_run, out, engine.histogrammes, initial_guess)
        pwm = pwm_text(app.protocol, app_run.config.sample_rate_hz)
        modes = run_modes_text(excitation_galvos, detection_galvos, app_run.spc.settings.images_par_bloc, !split_rois)
        # What the 1064 nm follows: the protocol's voltages, or a PI on the setpoint's quantity; nothing without a protocol.
        control = !app.protocol.active ? " · no active protocol: 1064 nm off" :
                  protocol_in_volts(app.protocol) ? " · protocol in volts, no PI" :
                  " · PI on $(app.protocol.setpoint_kind)" * (excitation_galvos ? "" : ", one for all ROIs")
        show_status!(blocks, "Realtime" * modes * ": session $(basename(dir))" * control * (isempty(pwm) ? "" : " · " * pwm))
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
    set_command_value!(ex, NaN)
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
    # The end of each pass as it was recorded: from M3, or M0 + the scan (sessions before this setting: M3).
    spc_info = get(session.info, "spc", Dict{String, Any}())
    fin_par_m3 = Bool(get(spc_info, "fin_par_m3", true))
    images = Bool(get(spc_info, "images", false))
    excitation_galvos, _ = session_modes(session)
    # The opto laser's PWM as it was recorded: the photons of its opto phases thrown away again.
    recorded = settings_from_dict(ProtocolSettings, get(session.info, "protocol", Dict{String, Any}()))
    if images
        # A detection by image: the same ROI binning over the recorded images, block by block.
        settings_images = deepcopy(app_run.spc.settings)
        settings_images.images_par_bloc = Int(get(spc_info, "images_par_bloc", settings_images.images_par_bloc))
        FLIMCore.commander!(engine, images_command(session.rois, sort(order), session.image_size, settings_images, "";
                                                   pwm = recorded.PWM_active))
    else
        sample_rate = isfinite(sample_s) && sample_s > 0 ? 1 / sample_s : app_run.config.sample_rate_hz
        FLIMCore.commander!(engine, FLIMCore.Clamp(rois = copy(order), ordre = copy(order), scan_s = scan_s, pause_s = pause_s,
                                                   echantillon_s = sample_s, fin_par_m3 = fin_par_m3,
                                                   opto = pwm_opto_fraction(recorded, sample_rate)))
    end

    app_run.run_mode = "Playback"
    app_run.run_rois = copy(session.rois)
    app_run.roi_order = order
    prepare_run_display!(app, app_run, blocks; n_rois = isempty(order) ? 1 : max(1, maximum(order)))
    settings = playback.session_settings ? session_analysis_settings(session) : nothing
    # A Realtime in images from before the Excitation toggle: its protocol always gave volts.
    if settings !== nothing && images && !haskey(get(session.info, "roi", Dict{String, Any}()), "excitation")
        settings.protocol.setpoint_kind = "Voltage"
    end
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

    out = AnalysisOutput(ex; roi_order = order, drive_outputs = false, stats = app_run.worker_stats,
                         global_pi = !excitation_galvos, command_full_scale_v = app_run.config.command_full_scale_v)
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
