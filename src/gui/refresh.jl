"""
refresh.jl

The GUI's refresh tick (plan §4 and §5): an `@async` task on the main
thread, `refresh_hz` times a second, and the only code that moves data from
the other threads into Observables. Each tick:

1. publishes the analysis settings if the user changed any (GUI -> worker);
2. copies what's new from the exchange rings (a few µs under their locks)
   and appends it to the GUI-side histories;
3. refreshes the bound curves in place, one `notify` each, moving the
   time-series axis limits with them (Histogram and Readback at most once
   per `autoscale_interval_s`);
4. drains the SPC engine's results into the SPC window and the top bar
   (`spc_tick!`, gui/spc_view.jl), and the Playback replay engine's
   (`playback_tick!`);
5. updates the status labels and, once a second, the diagnostics (plan §9);
6. closes the run once the worker and the scan have both stopped.

Nothing here waits for another thread.
"""

using GLMakie
using Observables

"""
    start_refresh_task!(app, app_run, blocks, fig)

Start the refresh tick; it ends when the window closes or on shutdown.
Paced on absolute deadlines, so the tick interval stays at
`1 / refresh_hz` whatever each tick's own work takes.
"""
function start_refresh_task!(app, app_run, blocks, fig)
    period_ns = round(UInt64, 1e9 / app_run.config.refresh_hz)
    app_run.refresh_task = @async begin
        next_ns = time_ns()
        while isopen(fig.scene) && !app_run.exchange.shutdown[]
            try
                refresh_tick!(app, app_run, blocks)
            catch e
                report_problem!("GUI-02", first(split(sprint(showerror, e), '\n')); level = :error, quiet_s = 10,
                                exception = (e, catch_backtrace()))
            end
            next_ns += period_ns
            now_ns = time_ns()
            if next_ns <= now_ns
                next_ns = now_ns + period_ns   # late: skip ahead rather than burst
            end
            sleep((next_ns - now_ns) / 1e9)
        end
    end
    return nothing
end

"""
    refresh_tick!(app, app_run, blocks)

One refresh (see the file docstring). Also called directly by the GUI
warm-up and the tests.
"""
function refresh_tick!(app, app_run, blocks)
    state = app_run.display
    ex = app_run.exchange
    started_ns = time_ns()

    # GC time since the previous tick: a pause long enough to make the
    # display stutter shows up here in full (plan §9).
    gc_total_ns = Int(Base.gc_num().total_time)
    if state.tick_last_ns != 0
        interval_s = (started_ns - state.tick_last_ns) / 1e9
        state.tick_interval_max_s = max(state.tick_interval_max_s, interval_s)
        state.tick_interval_sum_s += interval_s
        state.tick_count += 1
        state.gc_tick_max_s = max(state.gc_tick_max_s, (gc_total_ns - state.gc_total_ns) / 1e9)
    end
    state.tick_last_ns = started_ns
    state.gc_total_ns = gc_total_ns

    publish_analysis_settings!(app, app_run)

    # Analysis results -> histories
    empty!(state.new_frames)
    state.frame_cursor, lost = take_new!(state.new_frames, ex.frames, state.frame_cursor)
    state.frames_lost += lost
    if !isempty(state.new_frames)
        for record in state.new_frames
            accumulate_frame!(app, app_run, record)
        end
        latest = state.new_frames[end].sample
        publish_frame!(app_run.ch1, latest.ch1)
        publish_frame!(app_run.ch2, latest.ch2)
        state.dirty = true
    end

    # DAQ loop slots -> diagnostics
    empty!(state.new_slots)
    state.slot_cursor, lost = take_new!(state.new_slots, ex.slots, state.slot_cursor)
    state.slots_lost += lost
    for summary in state.new_slots
        state.loop_iteration_max_s = max(state.loop_iteration_max_s, summary.iteration_s)
        state.loop_margin_min_s = min(state.loop_margin_min_s, summary.margin_s)
        state.loop_deadline_s = summary.deadline_s
        state.loop_slots += 1
        state.last_slot = summary
    end

    copy_readback_view!(state, ex.readback) && (state.dirty = true)

    # SPC engine results -> SPC window and top bar (images at most 10 Hz)
    spc_tick!(app_run.spc, started_ns)
    playback_tick!(app_run)

    if state.dirty
        for (slot, plot) in state.plots
            refresh_plot_slot!(app, app_run, plot)
            update_data_limits!(app, app_run, plot_axis(blocks, slot), plot)
        end
        state.dirty = false
    end
    if started_ns - state.last_autoscale_ns >= app_run.config.autoscale_interval_s * 1e9
        autoscale_both!(app, app_run, blocks)
        state.last_autoscale_ns = started_ns
    end

    update_loop_status!(app_run, blocks)
    update_info_label!(app_run, blocks, started_ns)
    check_run_finished!(app, app_run, blocks)

    state.tick_work_max_s = max(state.tick_work_max_s, (time_ns() - started_ns) / 1e9)
    return nothing
end

plot_axis(blocks, slot::Symbol) = slot == :plot1 ? blocks.plot_1_axis : blocks.plot_2_axis

function autoscale_both!(app, app_run, blocks)
    for (slot, plot) in app_run.display.plots
        autoscale_plot_slot!(app, app_run, plot_axis(blocks, slot), plot)
    end
    return nothing
end

"""
    copy_readback_view!(state, view)::Bool

Copy the loop's latest decimated readback slot if it changed since the last
tick (a few µs under the view's lock). Returns whether it did.
"""
function copy_readback_view!(state::DisplayState, view::ReadbackView)::Bool
    lock(view.lock)
    try
        view.version == state.readback_version && return false
        state.readback_version = view.version
        if size(state.readback_data) != size(view.data)
            state.readback_data = similar(view.data)
        end
        copyto!(state.readback_data, view.data)
        state.readback_points = view.n_points
        state.readback_dt_s = view.dt_s
        state.readback_slot = view.slot
        state.readback_signals = view.signals
        return true
    finally
        unlock(view.lock)
    end
end

fields_equal(a, b) = all(f -> isequal(getfield(a, f), getfield(b, f)), fieldnames(typeof(a)))

"""
    publish_analysis_settings!(app, app_run; force=false)

Publish a fresh `AnalysisSettings` snapshot for the analysis worker when
the layout, controller or protocol settings changed since the last one
(or when `force`d, at START). The snapshot holds copies: the worker never
reads `AppState`, which only the GUI thread mutates.
"""
function publish_analysis_settings!(app, app_run; force::Bool = false)
    # Playback with the session's settings: the GUI's edits don't reach the worker.
    app_run.run_open && app_run.run_mode == "Playback" && app_run.playback.session_settings && return nothing
    state = app_run.display
    last = state.last_settings
    changed = force || last === nothing ||
              !fields_equal(last.layout, app.layout) ||
              !fields_equal(last.controller, app.controller) ||
              !fields_equal(last.protocol, app.protocol)
    changed || return nothing

    state.last_settings = AnalysisSettings(deepcopy(app.layout), deepcopy(app.controller), deepcopy(app.protocol))
    publish_settings!(app_run.exchange, AnalysisSettings(deepcopy(app.layout), deepcopy(app.controller),
                                                         normalize_protocol_config(app.protocol)))
    return nothing
end

# -----------------------------------------------------------------------------
# Labels
# -----------------------------------------------------------------------------

const LOOP_STATE_NAMES = Dict(
    LOOP_DISCONNECTED => "not connected", LOOP_INIT => "connecting…", LOOP_READY => "ready",
    LOOP_RUNNING => "running", LOOP_STOPPING => "stopping…", LOOP_FAULT => "FAULT"
)

"""
    loop_status_text(status)::String

Short text for the DAQ label next to the CONNECT button.
"""
loop_status_text(status::LoopStatus)::String =
    "DAQ: " * (status.state == LOOP_DISCONNECTED && startswith(status.message, "connection failed") ?
               "connection failed" : LOOP_STATE_NAMES[status.state])

"""
    connect_button_label(status)::String

CONNECT when disconnected — RECONNECT when the last connection failed (the
DAQ loop's "connection failed: …" status, e.g. a card missing on the bench
PC) —, RESET (acknowledge) in fault, DISCONNECT otherwise.
"""
function connect_button_label(status::LoopStatus)::String
    status.state == LOOP_DISCONNECTED && return startswith(status.message, "connection failed") ? "RECONNECT" : "CONNECT"
    return status.state == LOOP_FAULT ? "RESET" : "DISCONNECT"
end

"""
    loop_alarm(state)::Bool

Plan §6.5: an iteration longer than half the deadline, or a margin under a
tenth of it, means the loop is getting close to missing a slot.
"""
function loop_alarm(state::DisplayState)::Bool
    s = state.last_slot
    s === nothing && return false
    return s.iteration_s > s.deadline_s / 2 || s.margin_s < s.deadline_s / 10
end

function update_loop_status!(app_run, blocks)
    state = app_run.display
    status = loop_status(app_run.exchange)
    text = loop_status_text(status)
    if status.state == LOOP_RUNNING && loop_alarm(state)
        text *= " ⚠ late"
    end
    blocks.daq_label.text[] == text || (blocks.daq_label.text[] = text)

    if status != state.last_status
        label = connect_button_label(status)
        blocks.connect_button.label[] == label || (blocks.connect_button.label[] = label)
        if status.state == LOOP_FAULT
            show_status!(blocks, "DAQ fault: " * status.message)
        elseif status.state == LOOP_DISCONNECTED && startswith(status.message, "connection failed")
            show_status!(blocks, "DAQ " * status.message * " — RECONNECT to retry")
        elseif !isempty(status.message) && startswith(status.message, "scan refused")
            show_status!(blocks, status.message)
        end
        state.last_status = status
    end
    return nothing
end

"""
    update_info_label!(app_run, blocks, now_ns)

While running, the frame rate (EMA over ~1 s windows) and the latest frame
number in the info label — the job the former 1 Hz infos task did. Left
alone otherwise, so status messages (`show_status!`) stay visible.
"""
function update_info_label!(app_run, blocks, now_ns::UInt64)
    state = app_run.display
    elapsed_s = (now_ns - state.last_frame_count_time_ns) / 1e9
    elapsed_s < 1.0 && return nothing

    if app_run.running[] && !app_run.paused[] && app_run.i != state.last_frame_count
        instant = (app_run.i - state.last_frame_count) / elapsed_s
        state.frame_rate_hz = isfinite(state.frame_rate_hz) ? 0.6 * state.frame_rate_hz + 0.4 * instant : instant
        blocks.info_label.text[] = "Frame rate: $(round(state.frame_rate_hz, digits=2)) Hz\nFrame: $(app_run.i)"
    end
    state.last_frame_count = app_run.i
    state.last_frame_count_time_ns = now_ns

    run_diagnostics!(app_run)
    state.diagnostics[] = diagnostics_text(app_run)
    return nothing
end

"""
    run_diagnostics!(app_run)

Once a second: diagnose what the cards received (the latest
`FLIMCore.EtatClamp`, `diagnose_passes`) and the analysis worker's counters
(`diagnose_worker`), check the journal, and put the latest problem in the
top bar (every problem keeps its code: see diagnostics.jl and DEBUGGING.md).
"""
function run_diagnostics!(app_run)
    view = app_run.spc
    status = view.clamp_status
    if status !== nothing && status.t != app_run.diagnosed_t
        app_run.diagnosed_t = status.t
        daq_slots = app_run.run_mode == "Realtime" ? app_run.display.loop_slots : nothing
        for d in diagnose_passes(status; daq_slots)
            level = startswith(d.id, "PASS-01") || startswith(d.id, "PASS-02") || startswith(d.id, "ROUTE-01") ? :error : :warn
            report_problem!(d.id, d.detail; key = d.key, level)
        end
    end
    if app_run.run_open || app_run.running[]
        for d in diagnose_worker(app_run.worker_stats; check_backlog = app_run.run_mode == "Realtime")
            report_problem!(d.id, d.detail; key = d.key)
        end
    end
    dropped = app_run.exchange.journal.dropped[]
    dropped > 0 && report_problem!("JRN-01", "$dropped journal entries dropped (queue full)"; key = "JRN-01/dropped", quiet_s = 300)

    # The top bar shows the latest problem of the last two minutes.
    records = problem_records()
    latest = isempty(records) ? nothing : first(records)
    text = latest === nothing || time() - latest.last_t > 120 ? "" : latest.text
    length(text) > 180 && (text = first(text, 177) * "…")
    view.problem == text || (view.problem = text)
    return nothing
end

"""
    diagnostics_text(app_run)::String

The measurements of plan §9, for the Console panel.
"""
function diagnostics_text(app_run)::String
    state = app_run.display
    ex = app_run.exchange
    status = loop_status(ex)
    gc = Base.gc_num()
    ms(x) = isfinite(x) ? string(round(1000 * x, digits=1), " ms") : "—"

    tick_mean = state.tick_count > 0 ? state.tick_interval_sum_s / state.tick_count : NaN
    lines = String[
        "DAQ loop: $(LOOP_STATE_NAMES[status.state])" * (isempty(status.message) ? "" : " — $(status.message)"),
        "  slots: $(state.loop_slots)   iteration max: $(ms(state.loop_iteration_max_s))",
        "  margin min: $(ms(state.loop_margin_min_s))   deadline: $(ms(state.loop_deadline_s))",
        "Display tick: mean $(ms(tick_mean))   max $(ms(state.tick_interval_max_s))   work max $(ms(state.tick_work_max_s))",
        "GC: most in one tick $(ms(state.gc_tick_max_s))   longest wait for a safepoint (since launch) $(ms(Int(gc.max_time_to_safepoint) / 1e9))",
        "Journal: $(pending_journal(ex.journal)) pending   $(ex.journal.dropped[]) dropped",
        "Display lost: $(state.frames_lost) frames, $(state.slots_lost) slots",
        spc_diagnostics_text(app_run.spc),
        "Memory: $(round(Sys.maxrss() / 2^20, digits=0)) MB peak",
        "Threads: $(Threads.nthreads(:interactive)) interactive + $(Threads.nthreads(:default)) default",
        "Config: $(app_run.config.source) ($(app_run.config.backend))",
        "Debug log: " * (isempty(debug_log_path()) ? "none (console only)" : debug_log_path())
    ]
    # What a bench problem looks like, with its code (diagnostics.jl, DEBUGGING.md).
    problems = problem_lines(; limit = 6)
    push!(lines, isempty(problems) ? "Problems: none" : "Problems (latest first):")
    append!(lines, ["  " * p for p in problems])
    status = app_run.spc.clamp_status
    status === nothing || append!(lines, pass_status_lines(status))
    stats = app_run.worker_stats
    stats.passes[] > 0 && push!(lines, "Analysis: $(stats.passes[]) passes, fits failed $(stats.fits_failed[1][]) / $(stats.fits_failed[2][]), " *
                                       "kept out of the PI $(stats.excluded[]), not analyzed $(stats.unmatched[]), " *
                                       "most waiting $(stats.backlog_max[]), longest $(round(stats.pass_max_ns[] / 1e6, digits = 1)) ms")
    return join(lines, "\n")
end

# -----------------------------------------------------------------------------
# End of run
# -----------------------------------------------------------------------------

"""
    playback_tick!(app_run)

Drain the Playback replay engine's results (never waiting): its alerts go
to the SPC alerts and the journal like the cards' engine's; the end of its
pass cutting (`Fin`, or the engine stopping) raises `source_done`, which
lets the analysis worker end once it has taken every pass.
"""
function playback_tick!(app_run)
    playback = app_run.playback
    engine = playback.engine
    engine === nothing && return nothing
    n = 0
    while n < 1000 && isready(engine.resultats)
        r = take!(engine.resultats)
        if r isa FLIMCore.Alerte || r isa FLIMCore.EtatClamp
            spc_handle_result!(app_run.spc, r)          # coded problems and the pass counters, as in Realtime
        elseif r isa FLIMCore.Fin && r.mesure in (:clamp, :moteur)
            playback.fin === nothing && (playback.fin = r)
            playback.source_done[] = true
            spc_journal!(app_run.spc, r.erreur ? :error : :info, "Playback replay ended: $(r.raison)")
        end
        FLIMCore.rendre!(engine, r)
        n += 1
    end
    FLIMCore.etat_moteur(engine) == :arrete && (playback.source_done[] = true)
    return nothing
end

"""
    check_run_finished!(app, app_run, blocks)

While a run is open. Realtime needs its three parts — the analysis worker,
the DAQ loop's slots and the SPC engine's measurement — so once one of them
stops (STOP, a worker error, a DAQ fault, an SPC error), stop the other
two; once all three have stopped, close the run (`finalize_run!`).
Playback has two — the replay engine and the worker, which ends by itself
once the replay is over and every pass analyzed.
"""
function check_run_finished!(app, app_run, blocks)
    app_run.run_open || return nothing
    app_run.run_mode == "Playback" && return check_playback_finished!(app, app_run, blocks)
    ex = app_run.exchange
    daq = loop_status(ex).state
    spc = spc_state(app_run.spc)

    worker = app_run.worker_task
    worker_done = worker === nothing || istaskdone(worker)
    if app_run.running[]
        hardware_stopped = !(daq in (LOOP_RUNNING, LOOP_STOPPING)) || spc != :clamp
        # A just-started run: give the two commands a moment to take effect.
        started_s = (time_ns() - app_run.run_started_ns) / 1e9
        if worker_done || (hardware_stopped && started_s > 3.0)
            hardware_stopped && !worker_done &&
                show_status!(blocks, daq == LOOP_FAULT ? "Run stopped: DAQ fault" : spc != :clamp ? "Run stopped: SPC measurement ended" : "Run stopped")
            app_run.running[] = false
        else
            return nothing
        end
    end

    daq == LOOP_RUNNING && !ex.stop[] && request_stop!(ex)
    spc_stop_clamp!(app_run.spc)

    if worker_done && daq != LOOP_RUNNING && daq != LOOP_STOPPING && spc != :clamp
        finalize_run!(app, app_run, blocks)
    end
    return nothing
end

function check_playback_finished!(app, app_run, blocks)
    playback = app_run.playback
    worker = app_run.worker_task
    worker_done = worker === nothing || istaskdone(worker)
    worker_done || return nothing

    # The worker ended (replay over, STOP, or an error): stop the replay
    # engine off the GUI thread, then close the run.
    app_run.running[] = false
    engine = playback.engine
    if engine !== nothing
        playback_stop!(playback)
        playback.engine = nothing
        errormonitor(Threads.@spawn FLIMCore.arreter_moteur(engine))
    end
    fin = playback.fin
    show_status!(blocks, fin === nothing ? "Playback stopped" : "Playback: $(fin.raison)")
    finalize_run!(app, app_run, blocks)
    return nothing
end

"""
    finalize_run!(app, app_run, blocks)

Close a run: last redraw over the whole run, buttons back to START/CLEAR,
the journal's run closed, and the run's debug report written in its folder
(`write_debug_report`, gui/debug_report.jl). Nothing to save: everything
went to the session folder during the run (journal, cards' streams), so
neither a crash nor a forgotten click loses anything.
"""
function finalize_run!(app, app_run, blocks)
    app_run.run_open = false
    app_run.paused[] = false

    output = nothing
    if app_run.worker_task !== nothing
        output = try
            fetch(app_run.worker_task)
        catch e
            @error "Analysis worker failed" exception=e
            nothing
        end
    end
    app_run.worker_output = output

    state = app_run.display
    for plot in values(state.plots)
        refresh_plot_slot!(app, app_run, plot)
    end
    state.dirty = false
    autoscale_both!(app, app_run, blocks)

    send_journal!(app_run.exchange.journal, JournalRunEnd(time()))
    update_start_button_label!(app_run, blocks)
    update_stop_button_label!(app_run, blocks)

    run_diagnostics!(app_run)                  # the final counters of the run
    if !isempty(app_run.run_dir)
        path = write_debug_report(app_run, joinpath(app_run.run_dir, "debug_report.txt"); app)
        isempty(path) || @info "Run debug report written" path=path
    end
    return nothing
end
