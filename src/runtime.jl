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

const LIFETIME_WARMUP_DONE = Ref(false)

"""
consumer_loop(app_run)

Consumes data from the channel and updates the app_run observables.
Notifications are throttled to approximately 30 Hz to avoid overwhelming
the GUI with too frequent updates.
"""
function consumer_loop(app, app_run, blocks; rate=30, acquisition_mode="Playback")
    last_publish_time = time()
    publish_interval_s = 1.0 / rate
    plot_1_axis = blocks[:plot_1_axis]
    plot_2_axis = blocks[:plot_2_axis]
    publish_live_updates = acquisition_mode != "Save"
    last_histogram = nothing
    last_fit = nothing
    last_photons = NaN
    is_realtime_mode = acquisition_mode == "Realtime"
    realtime_frame_df = DataFrame(
        frame_idx=UInt32[],
        source_file=String[],
        timestamp=Float64[],
        photons=Float64[],
        command1=Float64[],
        command2=Float64[],
        lifetime=Float64[],
        concentration=Float64[],
        protocol_setpoint=Float64[],
        histogram=Vector{Float64}[],
        fit=Vector{Float64}[]
    )

    try
        for sample in app_run.channel
            while app_run.running[] && app_run.paused[]
                sleep(0.02)
            end

            if !app_run.running[]
                break
            end

            histogram, fit, photons, command1, command2, lifetime, concentration, timestamp, protocol_setpoint, frame_idx, source_file = sample
            last_histogram = histogram
            last_fit = fit
            last_photons = photons

            if is_realtime_mode
                push!(realtime_frame_df, (
                    frame_idx=frame_idx,
                    source_file=String(source_file),
                    timestamp=Float64(timestamp),
                    photons=Float64(photons),
                    command1=Float64(command1),
                    command2=Float64(command2),
                    lifetime=Float64(lifetime),
                    concentration=Float64(concentration),
                    protocol_setpoint=Float64(protocol_setpoint),
                    histogram=copy(histogram),
                    fit=copy(fit)
                ))
            end

            push!(app_run.photons[], photons)
            push!(app_run.lifetime[], lifetime)
            append_lifetime_smooth!(app, app_run)
            push!(app_run.protocol_setpoint[], protocol_setpoint)
            push!(app_run.concentration[], concentration)
            push!(app_run.command1[], command1)
            push!(app_run.command2[], command2)
            push!(app_run.timestamps[], timestamp)
            app_run.i[] = frame_idx

            now_s = time()

            if publish_live_updates && now_s - last_publish_time >= publish_interval_s
                app_run.histogram[] = histogram
                app_run.fit[] = fit
                app_run.counts[] = photons

                notify_runtime_observables!(app_run)

                last_publish_time = now_s

                autoscale_plot_selection!(app, app_run, plot_1_axis, app.layout.plot1)
                autoscale_plot_selection!(app, app_run, plot_2_axis, app.layout.plot2)
            end
        end

        if last_histogram !== nothing && last_fit !== nothing
            app_run.histogram[] = last_histogram
            app_run.fit[] = last_fit
            app_run.counts[] = last_photons

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
                autoscale_plot_selection!(app, app_run, plot_1_axis, app.layout.plot1)
                autoscale_plot_selection!(app, app_run, plot_2_axis, app.layout.plot2)
            end
        end

        if !app_run.running[]
            app_run.save_progress[] = NaN
        end

        if is_realtime_mode && nrow(realtime_frame_df) > 0
            save_realtime_capture!(app, app_run, realtime_frame_df)
        end

        if haskey(blocks, :start_button)
            blocks[:start_button].label[] = "START"
        end

        if haskey(blocks, :stop_button)
            blocks[:stop_button].label[] = "CLEAR"
        end
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
            @warn "Infos erreur" e
        end
    end
    return nothing
end

function warmup_lifetime_fit!()
    if LIFETIME_WARMUP_DONE[]
        return true
    end

    if !(@isdefined irf) || irf === nothing || !(@isdefined irf_bin_size) || irf_bin_size === nothing ||
       !(@isdefined tcspc_window_size) || tcspc_window_size === nothing
        return false
    end

    try
        n = DEFAULT_HISTOGRAM_RESOLUTION
        x = collect(1.0:1.0:n)
        synthetic_hist = @. 1800.0 * exp(-x / 36.0) + 20.0

        t0 = time_ns()
        params_raw, data = vec_to_lifetime(
            Float64.(synthetic_hist);
            guess=[3.0, 0.5, 0.5, 0.0, 5.0e-5],
            histogram_resolution=n
        )

        if !isempty(params_raw) && !isnan(params_raw[1])
            _ = conv_irf_data(data[1], Tuple(params_raw), irf; histogram_resolution=n)
        end

        LIFETIME_WARMUP_DONE[] = true
        @info "Lifetime warmup completed" elapsed_ms=((time_ns() - t0) / 1e6)
    catch e
        @warn "Lifetime warmup failed; continuing" error=string(e)
    end

    return LIFETIME_WARMUP_DONE[]
end



# -----------------------------------------------------------------------------
# button handlers
# -----------------------------------------------------------------------------

"""
    reset_acquisition_observables!(app_run)

Clear all time-series observables and counters ahead of a fresh acquisition run.
"""
function reset_acquisition_observables!(app_run)
    empty!(app_run.photons[])
    app_run.counts[] = 0.0
    empty!(app_run.lifetime[])
    empty!(app_run.lifetime_smooth[])
    empty!(app_run.protocol_setpoint[])
    empty!(app_run.concentration[])
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
"""
function dispatch_acquisition_worker!(app_run, selected_mode, layout, controller, initial_guess, protocol_config)
    if selected_mode == "Playback"
        app_run.worker_task = @async start_playback(
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
        app_run.worker_task = @async start_realtime(
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

        app_run.worker_task = @async start_save(
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
        app_run.worker_task = @async start_playback(
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
  that reads data files and pushes tuples onto the channel;
* **consumer_task** - pulls tuples from the channel and updates the
  `app_run` observables so that the plots react;
* **serial_task** - periodically sends PID/PWM commands to the connected device;
* **infos_task** - refreshes the status label at 1 Hz.

The `blocks` dict is used to read the selected mode/lifetimes menus and to
obtain the info label object for `infos_task`.
"""
function start_pressed(app, app_run, blocks)
    if app_run.running[]
        @info "Already running"
        return
    end

    # Check if IRF is loaded before starting
    @info "Checking IRF before start: irf=$(irf !== nothing), tcspc_window_size=$(tcspc_window_size !== nothing)"
    if irf === nothing || tcspc_window_size === nothing
        @error "Cannot start acquisition: IRF not loaded. Please load an IRF file first."
        @error "IRF status: irf=$(irf !== nothing), tcspc_window_size=$(tcspc_window_size !== nothing)"
        return
    end

    warmup_lifetime_fit!()

    @info "Starting test function"
    app_run.running[] = true
    app_run.paused[] = false
    app_run.channel = Channel{AcquisitionSample}(32)

    reset_acquisition_observables!(app_run)

    selected_mode = haskey(blocks, :mode_menu) ? blocks[:mode_menu].selection[] : "Playback"
    if !(selected_mode isa AbstractString)
        selected_mode = "Playback"
    end

    selected_lifetimes = haskey(blocks, :lifetimes_menu) ? blocks[:lifetimes_menu].selection[] : "2 lifetimes"
    if !(selected_lifetimes isa AbstractString)
        selected_lifetimes = "2 lifetimes"
    end

    initial_guess = initial_guess_for_lifetime_count(selected_lifetimes)

    sync_runtime_protocol!(app, app_run)
    protocol_config = app_run.protocol

    dispatch_acquisition_worker!(app_run, selected_mode, app.layout, app.controller, initial_guess, protocol_config)

    app_run.consumer_task = @async consumer_loop(app, app_run, blocks; rate=10, acquisition_mode=selected_mode)
    app_run.serial_task = @async serial_signal_loop(app, app_run; rate=20.0)
    app_run.infos_task = @async infos_loop(app_run, blocks[:info_label]; rate=1)

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
logged instead of propagating, which avoids the `TaskFailedException`
that occurred previously when the channel closed while `test`
continued running.
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

    @info "Stopping test function"
    
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
