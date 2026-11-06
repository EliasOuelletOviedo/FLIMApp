"""
gui/galvo_scan.jl

The ROI popup's galvo scan (its "Galvo scan" button), main thread only: the
NI galvos raster the ROI field — `roi_voltage_calibration_size` lines of as
many pixels over the popup's X/Y min/max, one frame in `GALVO_SCAN_S` —
while the SPC card counts, and the image comes back to the popup like the
Image button's. It is the ROIs' reference: a ROI drawn on it lands where
the galvos point, whatever the microscope's own image and the calibration
between the two.

Two parts run together, as in Realtime: the SPC engine
(`FLIMCore.ImageGalvos`) and the DAQ loop (`RasterRequest`). The engine is
armed first and the frame starts only once it counts — a line it missed
would shift the image. Then `galvo_scan_tick!` (refresh tick) shows the
progress and, when one part stops — the frame finished, STOP, a fault, an
error —, stops the other.
"""

"""How long the galvo scan's frame lasts (s)."""
const GALVO_SCAN_S = 60.0

"""After the SPC engine starts counting, the cards' own start before the frame begins (s)."""
const GALVO_SCAN_ARM_S = 0.25

"""The SPC engine counting, then the DAQ loop playing: each must start within this (s)."""
const GALVO_SCAN_START_TIMEOUT_S = 20.0

"""Once the NI has played every line, the SPC card has this long to see the end of the last one (s)."""
const GALVO_SCAN_GRACE_S = 3.0

"""
    GalvoScan

The galvo scan while it runs (`app_run.galvo_scan`): the frame the DAQ loop
plays (`request`) and the SPC engine images (`geometry`), where the progress
goes (`status`, the popup's status line) and who to tell when it's over
(`on_end(outcome)`; `outcome` "" when it went to the end), and how far it
got.
"""
mutable struct GalvoScan
    request::RasterRequest
    geometry::FLIMCore.BalayageGalvos
    status::Observable{String}
    on_end::Function
    started::Float64
    armed_t::Float64              # the SPC engine seen counting (NaN before)
    daq_sent::Bool
    daq_sent_t::Float64
    daq_seen::Bool                # the DAQ loop seen RUNNING the frame
    daq_done_t::Float64           # the DAQ loop done with the frame (NaN before)
    slots_at_start::Int
    stop_sent::Bool
    outcome::String
end

"""The popup's galvo range (`app.roi`, mV): `(v_min_x, v_max_x, v_min_y, v_max_y)`."""
roi_galvo_range(app)::NTuple{4, Int} = (app.roi.v_min_x, app.roi.v_max_x, app.roi.v_min_y, app.roi.v_max_y)

"""
    galvo_scan_request(app, app_run; size=roi_voltage_calibration_size, duration_s=GALVO_SCAN_S, range_mV=roi_galvo_range(app))::RasterRequest

The galvo scan of the ROI field: the popup's galvo range (`app.roi`, mV;
`range_mV`, another one: the calibration's), the size of the frame the
ROIs' voltage mapping is calibrated on (`roi_voltage_calibration_size`
pixels and lines), one frame in `GALVO_SCAN_S`. `size` and `duration_s`
shrink it for the tests.
"""
galvo_scan_request(app, app_run; size::Integer = roi_voltage_calibration_size, duration_s::Real = GALVO_SCAN_S,
                   range_mV = roi_galvo_range(app))::RasterRequest =
    RasterRequest(range_mV..., size, size, duration_s, app_run.spc.settings.inverser_routage)

"""
    galvo_scan_geometry(request, cfg, settings)::FLIMCore.BalayageGalvos

What the SPC engine needs to place the photons: the lines the DAQ loop
plays (`raster_timing`: ramp and line period) and where each one ends
(`[clamp] fin_par_m3`).
"""
function galvo_scan_geometry(request::RasterRequest, cfg::BenchConfig, settings::FLIMCore.Reglages)::FLIMCore.BalayageGalvos
    n_scan, n_shift = raster_timing(request, cfg.sample_rate_hz)
    return FLIMCore.BalayageGalvos(pixels = request.pixels, lignes = request.lines,
                                   scan_s = n_scan / cfg.sample_rate_hz, periode_s = (n_scan + n_shift) / cfg.sample_rate_hz,
                                   fin_par_m3 = settings.fin_par_m3)
end

"""
    galvo_scan_refusal(app, app_run; range_mV=roi_galvo_range(app))::String

Why the galvo scan can't start now ("" if it can): offline, a run going on,
a galvo scan already running, the DAQ loop not ready, the SPC engine not
ready, or the galvo range past `[limits] galvo_v`.
"""
function galvo_scan_refusal(app, app_run; range_mV = roi_galvo_range(app))::String
    isempty(app_run.offline) || return app_run.offline
    (app_run.running[] || app_run.run_open) && return "a run is going on: STOP it first"
    app_run.galvo_scan === nothing || return "a galvo scan is already running"
    daq = loop_status(app_run.exchange).state
    daq == LOOP_READY || return "DAQ not ready ($(LOOP_STATE_NAMES[daq])): CONNECT it first"
    spc = spc_state(app_run.spc)
    spc == :pret || return spc == :none ? "SPC engine not running: CONNECT it in the SPC window" :
                           "SPC engine busy ($(SPC_ENGINE_STATE_NAMES[spc]))"
    limit = app_run.config.galvo_limit_v
    peak = maximum(abs, range_mV) / 1000
    peak <= limit || return "the galvo range reaches $peak V, past the $limit V limit: change X/Y min/max"
    return ""
end

"""
    start_galvo_scan!(app, app_run, status; on_end=outcome -> nothing, size, duration_s, range_mV)::String

The "Galvo scan" button: "" when started, otherwise why not
(`galvo_scan_refusal`, or the SPC engine's refusal). Arms the SPC engine
(`spc_request_galvo_image!`, whose image reaches the popup through
`app_run.spc.roi_image`) and leaves the rest to `galvo_scan_tick!`. `size`,
`duration_s` and `range_mV`: `galvo_scan_request`'s.
"""
function start_galvo_scan!(app, app_run, status::Observable{String}; on_end::Function = outcome -> nothing,
                           size::Integer = roi_voltage_calibration_size, duration_s::Real = GALVO_SCAN_S,
                           range_mV = roi_galvo_range(app))::String
    refusal = galvo_scan_refusal(app, app_run; range_mV)
    isempty(refusal) || return refusal
    request = galvo_scan_request(app, app_run; size, duration_s, range_mV)
    geometry = galvo_scan_geometry(request, app_run.config, app_run.spc.settings)
    reason = spc_request_galvo_image!(app_run.spc, geometry)
    isempty(reason) || return reason
    app_run.galvo_scan = GalvoScan(request, geometry, status, on_end, time(), NaN, false, NaN, false, NaN,
                                   app_run.display.loop_slots, false, "")
    status[] = "Galvo scan: starting the SPC card…"
    @info "Galvo scan requested" pixels=request.pixels lines=request.lines duration_s=request.duration_s ramp_s=geometry.scan_s line_s=geometry.periode_s range_mV=(request.v_min_x, request.v_max_x, request.v_min_y, request.v_max_y) fin_par_m3=geometry.fin_par_m3
    return ""
end

"""
    stop_galvo_scan!(app_run, outcome)

End the galvo scan early (its button again, the popup closed, the other
part stopped): the DAQ loop's stop flag — the galvos back to 0 V within one
readback block — and the SPC engine's measurement, which still sends the
image of the lines it saw. `outcome` says why ("stopped", "failed: …"); the
first one given is kept.
"""
function stop_galvo_scan!(app_run, outcome::AbstractString)
    scan = app_run.galvo_scan
    (scan === nothing || scan.stop_sent) && return nothing
    scan.outcome = String(outcome)
    scan.stop_sent = true
    scan.daq_sent && request_stop!(app_run.exchange)
    # Queued behind the engine's ImageGalvos if it hasn't started it yet.
    app_run.spc.roi_image_pending && spc_command!(app_run.spc, FLIMCore.Arret())
    @info "Galvo scan ended early" outcome=outcome
    return nothing
end

"""
    galvo_scan_tick!(app_run)

The galvo scan, once per refresh tick (refresh.jl): start the frame once the
SPC engine counts; show the progress in the popup; when one part stops,
stop the other — after the NI's last line the engine normally ends by
itself, on the last pass, within `GALVO_SCAN_GRACE_S` (IMG-03 if not); once
both have stopped, forget the scan and call its `on_end`.
"""
function galvo_scan_tick!(app_run)
    scan = app_run.galvo_scan
    scan === nothing && return nothing
    view, ex = app_run.spc, app_run.exchange
    loop = loop_status(ex)
    daq, now = loop.state, time()
    imaging = view.roi_image_pending                   # the engine's ImageGalvos hasn't ended
    lines = scan.request.lines

    if !scan.daq_sent
        if !imaging
            isempty(scan.outcome) && (scan.outcome = "failed: the SPC engine ended it — " *
                                                     (view.last_fin === nothing ? "see its alerts" : view.last_fin.raison))
        elseif scan.stop_sent
            # stopped before the frame started: the engine ends its measurement
        elseif spc_state(view) == :galvos
            isnan(scan.armed_t) && (scan.armed_t = now)
            if now - scan.armed_t >= GALVO_SCAN_ARM_S
                if daq == LOOP_READY
                    ex.stop[] = false
                    scan.daq_sent = send_command!(ex, StartCommand(scan.request))
                    scan.daq_sent_t = now
                    scan.daq_sent || stop_galvo_scan!(app_run, "failed: the DAQ loop is not taking commands")
                else
                    stop_galvo_scan!(app_run, "failed: DAQ not ready ($(LOOP_STATE_NAMES[daq]))")
                end
            end
        elseif now - scan.started > GALVO_SCAN_START_TIMEOUT_S
            stop_galvo_scan!(app_run, "failed: the SPC card didn't start counting in $(round(Int, GALVO_SCAN_START_TIMEOUT_S)) s")
        end
    else
        daq == LOOP_RUNNING && (scan.daq_seen = true)
        if !scan.daq_seen
            if daq == LOOP_FAULT || daq == LOOP_DISCONNECTED ||
               (daq == LOOP_READY && now - scan.daq_sent_t > GALVO_SCAN_START_TIMEOUT_S)
                stop_galvo_scan!(app_run, "failed: the DAQ loop didn't play the frame" * (isempty(loop.message) ? "" : " — " * loop.message))
            end
        elseif daq == LOOP_FAULT
            stop_galvo_scan!(app_run, "failed: DAQ fault — " * loop.message)
        elseif daq == LOOP_READY && loop.message == "galvo scan finished"
            isnan(scan.daq_done_t) && (scan.daq_done_t = now)
            if imaging && now - scan.daq_done_t > GALVO_SCAN_GRACE_S && !scan.stop_sent
                report_problem!("IMG-03", "galvo scan: the NI played its $lines lines, the SPC card didn't see the end of " *
                                          "every one of them in $(GALVO_SCAN_GRACE_S) s — the SPC alerts give the line markers each card saw"; quiet_s = 0)
                stop_galvo_scan!(app_run, "ended: the SPC card missed the end of some lines (IMG-03)")
            end
        elseif daq == LOOP_READY || daq == LOOP_DISCONNECTED
            stop_galvo_scan!(app_run, "stopped")                       # STOP or DISCONNECT in the main window
        end
        # The engine ended first: normal right at the last line; otherwise the frame is stopped.
        if !imaging && daq == LOOP_RUNNING
            fin = view.last_fin
            fin !== nothing && fin.mesure == :galvos && !fin.erreur && startswith(fin.raison, "$lines lignes") ||
                stop_galvo_scan!(app_run, "failed: the SPC measurement ended — " * (fin === nothing ? "see its alerts" : fin.raison))
        end
    end

    if imaging && daq == LOOP_RUNNING && !scan.stop_sent
        played = clamp(app_run.display.loop_slots - scan.slots_at_start, 0, lines)
        text = "Galvo scan: line $played / $lines, $(round(Int, now - scan.daq_sent_t)) s of $(round(Int, scan.request.duration_s)) — click again to stop"
        scan.status[] == text || (scan.status[] = text)
    end

    # Both parts stopped (and the frame never left waiting for the DAQ loop): over.
    if !imaging && daq != LOOP_RUNNING && daq != LOOP_STOPPING && (!scan.daq_sent || scan.daq_seen || scan.stop_sent)
        app_run.galvo_scan = nothing
        @info "Galvo scan over" outcome=(isempty(scan.outcome) ? "complete" : scan.outcome) lines_played=app_run.display.loop_slots - scan.slots_at_start
        scan.on_end(scan.outcome)
    end
    return nothing
end
