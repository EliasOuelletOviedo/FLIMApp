"""
refresh.jl

The GUI's refresh tick (plan §4 and §5): an `@async` task on the main
thread, `refresh_hz` times a second, and the only code that moves data from
the other threads into Observables. Each tick:

1. publishes the analysis settings if the user changed any (GUI -> worker);
2. copies what's new from the exchange rings (a few µs under their locks)
   and appends it to the GUI-side histories;
3. refreshes the bound curves in place, one `notify` each, and the axis
   limits at most once per `autoscale_interval_s`;
4. updates the status labels and, once a second, the diagnostics (plan §9);
5. closes the run once the worker and the scan have both stopped.

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
                @error "Refresh tick failed" exception=(e, catch_backtrace())
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

    progress = ex.save_progress[]
    if app_run.run_open && app_run.run_mode == "Save" && !isequal(progress, app_run.save_progress[])
        app_run.save_progress[] = progress
    end

    # Plots: Save mode draws only once the run ends (it runs as fast as it
    # can; redrawing along the way would only slow the GUI down).
    live = !(app_run.running[] && app_run.run_mode == "Save")
    if state.dirty && live
        for plot in values(state.plots)
            refresh_plot_slot!(app, app_run, plot)
        end
        state.dirty = false
    end
    if live && started_ns - state.last_autoscale_ns >= app_run.config.autoscale_interval_s * 1e9
        autoscale_both!(app, app_run, blocks)
        state.last_autoscale_ns = started_ns
    end

    update_loop_status!(app_run, blocks)
    update_info_label!(app_run, blocks, started_ns)
    check_run_finished!(app, app_run, blocks)

    state.tick_work_max_s = max(state.tick_work_max_s, (time_ns() - started_ns) / 1e9)
    return nothing
end

function autoscale_both!(app, app_run, blocks)
    for (slot, axis, show_ch1, show_ch2) in ((:plot1, blocks.plot_1_axis, app.layout.plot1_ch1, app.layout.plot1_ch2),
                                             (:plot2, blocks.plot_2_axis, app.layout.plot2_ch1, app.layout.plot2_ch2))
        plot = get(app_run.display.plots, slot, nothing)
        plot === nothing || autoscale_plot_slot!(app, app_run, axis, plot, show_ch1, show_ch2)
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
loop_status_text(status::LoopStatus)::String = "DAQ: " * LOOP_STATE_NAMES[status.state]

"""
    connect_button_label(state)::String

CONNECT when disconnected, RESET (acknowledge) in fault, DISCONNECT otherwise.
"""
connect_button_label(state::LoopState)::String =
    state == LOOP_DISCONNECTED ? "CONNECT" : state == LOOP_FAULT ? "RESET" : "DISCONNECT"

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
        label = connect_button_label(status.state)
        blocks.connect_button.label[] == label || (blocks.connect_button.label[] = label)
        if status.state == LOOP_FAULT
            show_status!(blocks, "DAQ fault: " * status.message)
        elseif !isempty(status.message) && startswith(status.message, "scan refused")
            show_status!(blocks, status.message)
        end
        state.last_status = status
    end
    return nothing
end

"""
    update_info_label!(app_run, blocks, now_ns)

While running, the frame rate (EMA over ~1 s windows) and the latest file
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
        blocks.info_label.text[] = "Frequency: $(round(state.frame_rate_hz, digits=1)) Hz\nFile: $(app_run.i)"
    end
    state.last_frame_count = app_run.i
    state.last_frame_count_time_ns = now_ns

    state.diagnostics[] = diagnostics_text(app_run)
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
        "Memory: $(round(Sys.maxrss() / 2^20, digits=0)) MB peak",
        "Threads: $(Threads.nthreads(:interactive)) interactive + $(Threads.nthreads(:default)) default",
        "Config: $(app_run.config.source) ($(app_run.config.backend))"
    ]
    return join(lines, "\n")
end

# -----------------------------------------------------------------------------
# End of run
# -----------------------------------------------------------------------------

"""
    check_run_finished!(app, app_run, blocks)

While a run is open: once the analysis has stopped (STOP, end of files, or
a worker error), make sure the scan stops too; once both have stopped,
close the run (`finalize_run!`).
"""
function check_run_finished!(app, app_run, blocks)
    app_run.run_open || return nothing
    ex = app_run.exchange

    worker = app_run.worker_task
    worker_done = worker === nothing || istaskdone(worker)
    worker_done && app_run.running[] && (app_run.running[] = false)
    app_run.running[] && return nothing

    state = loop_status(ex).state
    if state == LOOP_RUNNING && !ex.stop[]
        request_stop!(ex)
    end

    if worker_done && state != LOOP_RUNNING && state != LOOP_STOPPING
        finalize_run!(app, app_run, blocks)
    end
    return nothing
end

"""
    finalize_run!(app, app_run, blocks)

Close a run: last redraw over the whole run, buttons back to START/CLEAR,
the journal's run closed, and — for a Real-time run with results — the
save dialog (`start_realtime_save!`, gui/session_save.jl).
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

    app_run.save_progress[] = NaN
    send_journal!(app_run.exchange.journal, JournalRunEnd(time()))
    update_start_button_label!(app_run, blocks)
    update_stop_button_label!(app_run, blocks)

    if app_run.run_mode == "Realtime" && output isa AnalysisOutput && nrow(output.realtime_rows) > 0
        start_realtime_save!(app, app_run, output.realtime_rows)
    end
    return nothing
end
