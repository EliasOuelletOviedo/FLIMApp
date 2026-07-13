"""
runtime.jl

Background task lifecycle for the FLIM application: the consumer/info tasks
started on acquisition, and the START/PAUSE/RESUME/STOP button handlers that
launch and tear them down together with the acquisition worker task
(acquisition.jl), autoscaling (plotting.jl), and serial signaling (serial.jl).

Tasks are launched by start_pressed() and terminated by stop_pressed().
"""

using GLMakie
using Observables
using DataFrames
using Base.Threads

"""
    accumulate_channel_sample!(app, series::ChannelSeries, frame::ChannelFrame)

Append one frame's scalar results (photons, lifetime, concentration and
their smoothed values) onto one channel's time-series observables.
"""
function accumulate_channel_sample!(app, series::ChannelSeries, frame::ChannelFrame)
    push!(series.photons[], frame.photons)
    append_smooth_value!(app, series.photons, series.photons_smooth)
    push!(series.lifetime[], frame.lifetime)
    append_smooth_value!(app, series.lifetime, series.lifetime_smooth)
    push!(series.concentration[], frame.concentration)
    append_smooth_value!(app, series.concentration, series.concentration_smooth)
    return nothing
end

"""
    publish_channel_frame!(series::ChannelSeries, frame::ChannelFrame)

Publish one frame's histogram/fit/counts onto one channel's "latest value"
observables (the throttled GUI-facing update, as opposed to the per-frame
time-series accumulation above).
"""
function publish_channel_frame!(series::ChannelSeries, frame::ChannelFrame)
    series.histogram[] = frame.histogram
    series.fit[] = frame.fit
    series.counts[] = frame.photons
    return nothing
end

"""
    consumer_loop(app, app_run, blocks; rate=30, acquisition_mode="Playback")

Consumes data from the channel and updates the app_run observables.
Notifications are throttled to approximately `rate` Hz to avoid overwhelming
the GUI with too frequent updates.
"""
function consumer_loop(app, app_run, blocks; rate=30, acquisition_mode="Playback")
    last_publish_time = time()
    publish_interval_s = 1.0 / rate
    plot_1_axis = blocks.plot_1_axis
    plot_2_axis = blocks.plot_2_axis
    publish_live_updates = acquisition_mode != "Save"
    last_sample = nothing
    is_realtime_mode = acquisition_mode == "Realtime"
    realtime_frame_df = DataFrame(
        frame_idx=UInt32[],
        source_file=String[],
        timestamp=Float64[],
        photons_ch1=Float64[],
        command1=Float64[],
        command2=Float64[],
        lifetime_ch1=Float64[],
        concentration_ch1=Float64[],
        protocol_setpoint=Float64[],
        histogram_ch1=Vector{Float64}[],
        fit_ch1=Vector{Float64}[],
        photons_ch2=Float64[],
        lifetime_ch2=Float64[],
        concentration_ch2=Float64[],
        histogram_ch2=Vector{Float64}[],
        fit_ch2=Vector{Float64}[]
    )

    try
        for sample in app_run.channel
            while app_run.running[] && app_run.paused[]
                sleep(0.02)
            end

            if !app_run.running[]
                break
            end

            last_sample = sample

            if is_realtime_mode
                push!(realtime_frame_df, (
                    frame_idx=sample.frame_index,
                    source_file=String(sample.source_file),
                    timestamp=Float64(sample.timestamps),
                    photons_ch1=Float64(sample.ch1.photons),
                    command1=Float64(sample.command1),
                    command2=Float64(sample.command2),
                    lifetime_ch1=Float64(sample.ch1.lifetime),
                    concentration_ch1=Float64(sample.ch1.concentration),
                    protocol_setpoint=Float64(sample.protocol_setpoint),
                    histogram_ch1=copy(sample.ch1.histogram),
                    fit_ch1=copy(sample.ch1.fit),
                    photons_ch2=Float64(sample.ch2.photons),
                    lifetime_ch2=Float64(sample.ch2.lifetime),
                    concentration_ch2=Float64(sample.ch2.concentration),
                    histogram_ch2=copy(sample.ch2.histogram),
                    fit_ch2=copy(sample.ch2.fit)
                ))
            end

            accumulate_channel_sample!(app, app_run.ch1, sample.ch1)
            accumulate_channel_sample!(app, app_run.ch2, sample.ch2)
            push!(app_run.protocol_setpoint[], sample.protocol_setpoint)
            push!(app_run.command1[], sample.command1)
            push!(app_run.command2[], sample.command2)
            push!(app_run.timestamps[], sample.timestamps)
            app_run.i[] = sample.frame_index

            now_s = time()

            if publish_live_updates && now_s - last_publish_time >= publish_interval_s
                publish_channel_frame!(app_run.ch1, sample.ch1)
                publish_channel_frame!(app_run.ch2, sample.ch2)

                notify_runtime_observables!(app_run)

                last_publish_time = now_s

                autoscale_plot_selection!(app, app_run, plot_1_axis, app.layout.plot1, app.layout.plot1_ch1, app.layout.plot1_ch2)
                autoscale_plot_selection!(app, app_run, plot_2_axis, app.layout.plot2, app.layout.plot2_ch1, app.layout.plot2_ch2)
            end
        end

        # Publish the final frame once the loop ends, so the plots show the
        # last processed data even if it arrived between throttled updates.
        if last_sample !== nothing
            publish_channel_frame!(app_run.ch1, last_sample.ch1)
            publish_channel_frame!(app_run.ch2, last_sample.ch2)

            notify_runtime_observables!(app_run)

            save_completed = isfinite(app_run.save_progress[]) && app_run.save_progress[] >= 100.0
            if save_completed
                autolimits!(plot_1_axis)
                autolimits!(plot_2_axis)
                lim1 = plot_1_axis.finallimits[]
                lim2 = plot_2_axis.finallimits[]
                xmax1 = lim1.origin[1] + lim1.widths[1]
                xmax2 = lim2.origin[1] + lim2.widths[1]
                xlims!(plot_1_axis, 0.0, max(Float64(xmax1), 0.0))
                xlims!(plot_2_axis, 0.0, max(Float64(xmax2), 0.0))
            else
                autoscale_plot_selection!(app, app_run, plot_1_axis, app.layout.plot1, app.layout.plot1_ch1, app.layout.plot1_ch2)
                autoscale_plot_selection!(app, app_run, plot_2_axis, app.layout.plot2, app.layout.plot2_ch1, app.layout.plot2_ch2)
            end
        end

        if !app_run.running[]
            app_run.save_progress[] = NaN
        end

        if is_realtime_mode && nrow(realtime_frame_df) > 0
            save_realtime_capture!(app, app_run, realtime_frame_df)
        end

        blocks.start_button.label[] = "START"
        blocks.stop_button.label[] = "CLEAR"
    catch e
        @error "Consumer error" e
    end
end

function infos_loop(app_run, info_label; rate=1.0)
    last_i = app_run.i[]
    dt = 1/float(rate)
    while app_run.running[]
        if app_run.paused[]
            sleep(min(dt, 0.05))
            continue
        end

        sleep(dt)
        try
            i = app_run.i[]
            if i != last_i
                di = i - last_i
                last_i = i
                info_label.text[] = "Frequency: $di Hz\nFile: $i"
            end
        catch e
            @warn "Infos loop error" e
        end
    end
    return nothing
end

# -----------------------------------------------------------------------------
# button handlers
# -----------------------------------------------------------------------------

"""
    reset_channel_series!(series::ChannelSeries)

Clear one channel's time-series observables and counters ahead of a fresh
acquisition run. Does not notify — callers batch their own notifications.
"""
function reset_channel_series!(series::ChannelSeries)
    empty!(series.photons[])
    empty!(series.photons_smooth[])
    series.counts[] = 0.0
    empty!(series.lifetime[])
    empty!(series.lifetime_smooth[])
    empty!(series.concentration[])
    empty!(series.concentration_smooth[])
    return nothing
end

"""
    reset_acquisition_observables!(app_run)

Clear all time-series observables and counters ahead of a fresh acquisition run.
"""
function reset_acquisition_observables!(app_run)
    foreach(reset_channel_series!, channel_series(app_run))
    empty!(app_run.protocol_setpoint[])
    empty!(app_run.command1[])
    empty!(app_run.command2[])
    empty!(app_run.timestamps[])
    app_run.i[] = 0
    app_run.save_progress[] = NaN
    return nothing
end

"""
    initial_guess_for_lifetime_count(selected_lifetimes::AbstractString)::Vector{Float64}

Map the Lifetimes menu selection ("1 lifetime"/"2 lifetimes"/"3 lifetimes") to
the corresponding initial parameter guess for the MLE fit.
"""
function initial_guess_for_lifetime_count(selected_lifetimes::AbstractString)::Vector{Float64}
    if selected_lifetimes == "1 lifetime"
        return [3.0, 0.0, 5.0e-5]
    elseif selected_lifetimes == "3 lifetimes"
        return [3.0, 0.5, 0.5, 0.5, 0.5, 0.0, 5.0e-5]
    else
        return [3.0, 0.5, 0.5, 0.0, 5.0e-5]
    end
end

"""
    dispatch_acquisition_worker!(app_run, selected_mode, layout, controller, initial_guess, protocol_config)

Launch the background worker task for the selected acquisition mode
(Playback/Realtime/Save, defaulting to Playback for an unrecognized mode)
and store it on `app_run.worker_task`.

Launched with `Threads.@spawn`, not `@async`: the worker loop is CPU-bound
(the MLE fit dominates its frame time, measured ~88% of a loop iteration),
and `@async` tasks are sticky to the thread they were spawned from — with
GLMakie's event loop and `consumer_task`/`serial_task`/`infos_task` all
pinned to the main thread via `@async` (see `start_pressed` below), a
CPU-bound `@async` worker would block GUI redraw/input for the duration of
every fit. `Threads.@spawn` lets the scheduler run the worker on a
different OS thread when one is available, so the GUI stays responsive
even while a fit is in flight. This is pure Julia (`Base.Threads`) with no
OS-specific code, so it behaves identically on macOS and Windows; it only
*helps* when Julia is started with more than one thread (`julia -t auto`),
which `start_pressed` checks for and warns about below. With a single
thread it degrades gracefully to the same cooperative scheduling as
`@async` — never worse, just not better.

`consumer_task` (and `serial_task`/`infos_task`) must stay on `@async`:
they touch `Observable`s and the GLMakie figure directly, which are not
safe to mutate concurrently from multiple threads.
"""
function dispatch_acquisition_worker!(app_run, selected_mode, layout, controller, initial_guess, protocol_config)
    if selected_mode == "Playback"
        app_run.worker_task = Threads.@spawn start_playback(
            app_run.channel,
            app_run.running,
            layout,
            controller;
            initial_guess=initial_guess,
            protocol=protocol_config,
            paused=app_run.paused,
            target_frequency=1000.0
        )
    elseif selected_mode == "Realtime"
        app_run.worker_task = Threads.@spawn start_realtime(
            app_run.channel,
            app_run.running,
            layout,
            controller;
            initial_guess=initial_guess,
            protocol=protocol_config,
            paused=app_run.paused
        )
    elseif selected_mode == "Save"
        app_run.save_progress[] = 0.0

        save_progress_cb = function (pct)
            app_run.save_progress[] = Float64(pct)
            return nothing
        end

        app_run.worker_task = Threads.@spawn start_save(
            app_run.channel,
            app_run.running,
            layout,
            controller;
            initial_guess=initial_guess,
            protocol=protocol_config,
            paused=app_run.paused,
            progress_cb=save_progress_cb
        )
    else
        @warn "Unknown acquisition mode selected; falling back to Playback" selected_mode=selected_mode
        app_run.worker_task = Threads.@spawn start_playback(
            app_run.channel,
            app_run.running,
            layout,
            controller;
            initial_guess=initial_guess,
            protocol=protocol_config,
            paused=app_run.paused,
            target_frequency=60.0
        )
    end

    return nothing
end

"""
    start_pressed(app, app_run, blocks)

Handler called when the START button is clicked.  It sets up the
communication channel, resets all time-series observables, and launches
four background tasks:

* **worker_task** - the Playback/Realtime/Save acquisition loop (acquisition.jl)
  that reads data files and pushes samples onto the channel. Launched with
  `Threads.@spawn` (see `dispatch_acquisition_worker!`), since it is
  CPU-bound (dominated by the MLE fit) and must not block the GUI thread;
* **consumer_task** - pulls samples from the channel and updates the
  `app_run` observables so that the plots react. Stays on `@async` (pinned
  to the thread it's spawned from, i.e. the GUI thread) since it touches
  `Observable`s/GLMakie, which aren't safe to mutate from multiple threads;
* **serial_task** - periodically sends PID/PWM commands to the connected device;
* **infos_task** - refreshes the status label at 1 Hz.

`blocks` is used to read the selected mode/lifetimes menus and to obtain
the info label object for `infos_task`.
"""
function start_pressed(app, app_run, blocks)
    if app_run.running[]
        @info "Already running"
        return
    end

    # Check if IRF is loaded before starting
    if RUNTIME[].irf === nothing || RUNTIME[].tcspc_window_size === nothing
        @error "Cannot start acquisition: IRF not loaded. Please load an IRF file first."
        return
    end

    @info "Starting acquisition"
    app_run.running[] = true
    app_run.paused[] = false
    # Capacity: the worker (its own thread since Threads.@spawn, see
    # dispatch_acquisition_worker!) blocks on put! once this fills, so a
    # transient GUI-thread slowdown (a GC pause, a Makie redraw, a
    # smoothing-slider recompute) directly stalls the fit loop too, not
    # just the display. 32 gave the worker under 100ms of headroom at
    # realistic frame rates; 512 costs a few hundred KB more (each sample
    # holds two Vector{Float64} histograms) and absorbs multi-second GC/JIT
    # pauses without back-pressuring the worker, while still bounding
    # worst-case backlog if the consumer falls behind persistently rather
    # than just transiently.
    app_run.channel = Channel{AcquisitionSample}(512)

    reset_acquisition_observables!(app_run)

    selected_mode = blocks.mode_menu.selection[]
    if !(selected_mode isa AbstractString)
        selected_mode = "Playback"
    end

    selected_lifetimes = blocks.lifetimes_menu.selection[]
    if !(selected_lifetimes isa AbstractString)
        selected_lifetimes = "2 lifetimes"
    end

    initial_guess = initial_guess_for_lifetime_count(selected_lifetimes)

    sync_runtime_protocol!(app, app_run)
    protocol_config = app_run.protocol

    dispatch_acquisition_worker!(app_run, selected_mode, app.layout, app.controller, initial_guess, protocol_config)

    app_run.consumer_task = @async consumer_loop(app, app_run, blocks; rate=10, acquisition_mode=selected_mode)
    app_run.serial_task = @async serial_signal_loop(app, app_run; rate=20.0)
    app_run.infos_task = @async infos_loop(app_run, blocks.info_label; rate=1)

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

Stop any running acquisition.  This function clears the `running`
flag, closes the channel and waits for any background tasks to
complete.  Exceptions from worker or consumer tasks are caught and
logged instead of propagating.
"""
function stop_pressed(app_run)
    if app_run.serial_conn !== nothing
        try
            send_command(app_run.serial_conn, "A 0 AO 1 0\n")
            send_command(app_run.serial_conn, "A 0 AO 2 0\n")
        catch e
            @warn "Failed to send zero-signal command during stop" error=string(e)
        end
    end

    if !app_run.running[]
        app_run.save_progress[] = NaN
        @info "Not running"
        return
    end

    @info "Stopping acquisition"

    app_run.paused[] = false
    app_run.running[] = false
    if app_run.channel !== nothing && isopen(app_run.channel)
        close(app_run.channel)
    end

    for t in (app_run.worker_task, app_run.consumer_task,
              app_run.autoscaler_task, app_run.infos_task, app_run.serial_task)
        if t !== nothing && !istaskdone(t)
            try
                wait(t)
            catch e
                @warn "Task error during shutdown" e
            end
        end
    end

    app_run.worker_task = nothing
    app_run.consumer_task = nothing
    app_run.autoscaler_task = nothing
    app_run.infos_task = nothing
    app_run.serial_task = nothing

    app_run.channel = nothing
    app_run.save_progress[] = NaN
    return nothing
end
