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
using DataFrames
using Base.Threads

# -----------------------------------------------------------------------------
# GUI-side histories
# -----------------------------------------------------------------------------

"""
    accumulate_roi_sample!(app, series::RoiChannelSeries, frame::ChannelFrame, timestamp::Float64)

Append one frame's scalar results (photons, lifetime, concentration and
their smoothed values) plus its own timestamp onto one ROI's per-channel
history. Which ROI is decided upstream (`assign_roi!`, analysis/acquisition.jl).
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

Append one analyzed file to the GUI-side histories: its ROI's per-channel
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
    rebuild_roi_series!(app, app_run)

Replace `app_run.ch1_rois`/`ch2_rois` with fresh, empty histories: one per
drawn ROI (`app_run.rois[]`) when ROI mode (`app.roi.active`) is on, a
single one otherwise. Index `k` holds drawn ROI `k`'s results. Callers must
re-render both plot slots (`render_plot!`) afterwards: the curves are bound
to the old vectors.
"""
function rebuild_roi_series!(app, app_run)
    n = app.roi.active ? max(1, length(app_run.rois[])) : 1
    app_run.ch1_rois = [RoiChannelSeries() for _ in 1:n]
    app_run.ch2_rois = [RoiChannelSeries() for _ in 1:n]
    return nothing
end

"""
    reset_acquisition_state!(app, app_run)

Clear every GUI-side history and counter ahead of a fresh run. The global
histories are emptied in place (plot bindings keep them); the per-ROI ones
are rebuilt (see `rebuild_roi_series!`).
"""
function reset_acquisition_state!(app, app_run)
    foreach(reset_channel_series!, channel_series(app_run))
    rebuild_roi_series!(app, app_run)
    empty!(app_run.protocol_setpoint)
    empty!(app_run.command1)
    empty!(app_run.command2)
    empty!(app_run.timestamps)
    app_run.i = 0
    app_run.save_progress[] = NaN
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
    spawn_acquisition_worker!(app_run, selected_mode, out, initial_guess)

Launch the analysis worker for the selected mode (Playback/Realtime/Save,
Playback for an unrecognized mode) on its own thread and store it on
`app_run.worker_task`. `Threads.@spawn`, not `@async`: the worker is
CPU-bound (the MLE fit dominates its frame time), and it never touches the
GUI — its results reach it through the exchanges.
"""
function spawn_acquisition_worker!(app_run, selected_mode, out::AnalysisOutput, initial_guess)
    running, paused = app_run.running, app_run.paused
    app_run.worker_task = if selected_mode == "Realtime"
        Threads.@spawn start_realtime(out, running; initial_guess=initial_guess, paused=paused)
    elseif selected_mode == "Save"
        Threads.@spawn start_save(out, running; initial_guess=initial_guess, paused=paused)
    else
        selected_mode == "Playback" || @warn "Unknown acquisition mode selected; falling back to Playback" selected_mode=selected_mode
        Threads.@spawn start_playback(out, running; initial_guess=initial_guess, paused=paused,
                                      target_frequency=app_run.target_frequency)
    end
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
        app_run.imported_image_size
    )
end

"""
    run_info(app, app_run, mode, order)::Dict{String, Any}

What the journal writes to the run's run.toml.
"""
function run_info(app, app_run, mode::AbstractString, order::Vector{Int})::Dict{String, Any}
    return Dict{String, Any}(
        "mode" => String(mode),
        "data_folder" => get_data_root_path(),
        "bench_config" => app_run.config.source,
        "backend" => String(app_run.config.backend),
        "daq_state_at_start" => string(loop_status(app_run.exchange).state),
        "rois" => [r.name for r in app_run.rois[]],
        "roi_visit_order" => order,
        "roi_active" => app.roi.active,
        "protocol" => Dict{String, Any}(
            "active" => app.protocol.active, "repeats" => app.protocol.repeats, "delay" => app.protocol.delay,
            "scan_time_ms" => app.protocol.scan_time, "shift_time_ms" => app.protocol.shift_time,
            "points_per_roi" => app.protocol.points_per_roi, "spiral_turns" => app.protocol.spiral_turns
        ),
        "controller" => Dict{String, Any}(
            "P1" => app.controller.P1, "I1" => app.controller.I1, "on1" => app.controller.ch1_on, "inv1" => app.controller.ch1_inv,
            "P2" => app.controller.P2, "I2" => app.controller.I2, "on2" => app.controller.ch2_on, "inv2" => app.controller.ch2_inv
        ),
        "galvo_range_mV" => [app.roi.v_min_x, app.roi.v_max_x, app.roi.v_min_y, app.roi.v_max_y],
        "image_size" => collect(app_run.imported_image_size)
    )
end

"""
    abort_start!(app_run, blocks)

Undo the `running`/`paused` flags claimed by `start_pressed` and restore the
button labels when a start is abandoned (e.g. a missing data folder).
"""
function abort_start!(app_run, blocks)
    app_run.running[] = false
    app_run.paused[] = false
    update_start_button_label!(app_run, blocks)
    update_stop_button_label!(app_run, blocks)
    return nothing
end

"""
    start_pressed(app, app_run, blocks)

START: claim `running[]` synchronously (so a second click is caught), then
do the rest on an `@async` task this handler doesn't wait on — this
function runs on GLMakie's render-loop task, and anything that blocks it
blocks rendering. That task validates the data folder, computes the ROI
visiting order off the GUI thread (exponential in the ROI count), resets the
histories, opens the journal run, asks the DAQ loop to start the scan (if
connected and ready) and spawns the analysis worker. The refresh tick takes
it from there.
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

    if RUNTIME[].irf === nothing || RUNTIME[].tcspc_window_size === nothing
        @error "Cannot start acquisition: IRF not loaded. Please load an IRF file first."
        show_status!(blocks, "Load an IRF file before starting")
        return
    end

    @info "Starting acquisition"
    app_run.running[] = true
    app_run.paused[] = false
    ex = app_run.exchange

    @async begin
        selected_mode = blocks.mode_menu.selection[]
        selected_mode isa AbstractString || (selected_mode = "Playback")

        # Surface the common "clicked START but nothing happened" cases in
        # the window instead of only in the worker's log. Realtime waits
        # for files to appear, so it just needs the folder to exist.
        data_path = get_data_root_path()
        if !isdir(data_path)
            show_status!(blocks, "Data folder not found")
            abort_start!(app_run, blocks)
            return nothing
        end
        if selected_mode != "Realtime" && !any(f -> endswith(lowercase(f), ".sdt"), readdir(data_path))
            show_status!(blocks, "No .sdt files in the data folder")
            abort_start!(app_run, blocks)
            return nothing
        end

        selected_lifetimes = blocks.lifetimes_menu.selection[]
        selected_lifetimes isa AbstractString || (selected_lifetimes = "2 lifetimes")
        initial_guess = initial_guess_for_lifetimes(selected_lifetimes)

        rois = app_run.rois[]
        split_rois = app.roi.active && !isempty(rois)
        order = split_rois ? fetch(Threads.@spawn roi_visit_order(rois)) : Int[]

        if !app_run.running[]
            @info "Acquisition stopped before it finished starting"
            return nothing
        end

        reset_acquisition_state!(app, app_run)
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

        app_run.run_mode = selected_mode
        app_run.roi_order = order
        app_run.worker_output = nothing
        app_run.run_open = true
        send_journal!(ex.journal, JournalRunStart(time(), run_info(app, app_run, selected_mode, order)))

        state = loop_status(ex).state
        if state == LOOP_READY
            ex.stop[] = false
            send_command!(ex, StartCommand(scan_request(app, app_run, order)))
        elseif state == LOOP_FAULT
            show_status!(blocks, "DAQ in fault: acknowledge it (RESET) to drive the outputs")
            journal_event!(ex.journal, :warn, "run started without the DAQ: loop in fault")
        elseif state != LOOP_DISCONNECTED
            journal_event!(ex.journal, :warn, "run started without the DAQ: loop is $(state)")
        end

        out = AnalysisOutput(ex; roi_order=order, realtime=(selected_mode == "Realtime"),
                             nominal_period_s=roi_scan_period_s(app.protocol))
        spawn_acquisition_worker!(app_run, selected_mode, out, initial_guess)
        return nothing
    end

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
readback block, stops the tasks and zeroes every output (plan §7.4) — and
clear `running` so the analysis worker ends after its current file. Nothing
here waits: the refresh tick notices when both have stopped and closes the
run (`finalize_run!`, gui/refresh.jl).
"""
function stop_pressed(app_run)
    request_stop!(app_run.exchange)

    if !app_run.running[]
        app_run.save_progress[] = NaN
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

True while a previous run is still being finalized (worker or scan still
winding down, journal run open).
"""
tasks_still_running(app_run)::Bool = app_run.run_open
