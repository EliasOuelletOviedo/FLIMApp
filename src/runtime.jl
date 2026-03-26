"""
runtime.jl

Background task management for the FLIM application.

Implements three main asynchronous tasks:
1. **autoscaler_loop**: Periodic (30 Hz) adjustment of plot axis limits
2. **consumer_loop**: Data channel consumption and GUI observable updates
3. **infos_loop**: Status display (frequency counter) at ~1 Hz

These tasks run on separate threads controlled by app_run.running flag.
Communication occurs via Observables (reactive) and Channels (one-shot).

Tasks are launched by start_pressed() and terminated by stop_pressed().
"""

using GLMakie
using Observables
using Base.Threads

# Normalize IRF to the fit amplitude for histogram overlays.
function normalized_irf_from_fit(fit::AbstractVector{<:Real})
    nfit = length(fit)
    out = zeros(Float64, nfit)

    if nfit == 0 || !(@isdefined irf) || irf === nothing || size(irf, 2) < 2
        return out
    end

    irf_y = Float64.(irf[:, 2])
    if isempty(irf_y)
        return out
    end

    fit_max = maximum(Float64.(fit))
    irf_max = maximum(irf_y)

    if !isfinite(fit_max) || !isfinite(irf_max) || irf_max == 0.0
        return out
    end

    n = min(nfit, length(irf_y))
    out[1:n] .= irf_y[1:n] .* (fit_max / irf_max)
    return out
end

# -----------------------------------------------------------------------------
# task loops
# -----------------------------------------------------------------------------

"""
autoscaler_loop(app_run, blocks; rate=30.0)

Periodic task that updates the plot axes limits based on the latest
data.  Runs at approximately `rate` hertz until `app_run.running[]` is
set to `false`.

The `blocks` dictionary is expected to contain the keys
`:plot_1_axis` and `:plot_2_axis` holding the two Makie Axis objects
that should be autoscaled.  The loop catches and logs any exceptions
so that a single error does not kill the task.
"""
# internal helper replicating the scaling logic defined in GUI.apply_autoscale!
# separated here so the autoscaler task doesn't need to depend on GUI scope.
function autoscale_values!(ax)
    autolimits!(ax)
end

function autoscale_values!(app, ax, xs::AbstractVector; pad_ratio=0.05)
    if isempty(xs)
        return
    end

    valid = .!isnan.(xs)
    xs = xs[valid]
    if isempty(xs)
        return
    end

    time_range = app.layout[:time_range]
    xmin, xmax = minimum(xs), maximum(xs)

    if xmax < time_range
        xmax = time_range
    end

    if xmax - xmin > time_range
        xmin = xmax - time_range
    end

    if xmin == xmax
        xmin -= 0.5
        xmax += 0.5
    end

    xpad = (xmax - xmin) * pad_ratio

    xlims!(ax, xmin - xpad, xmax + xpad)
    ylims!(ax, 0.0, 100.0)
end

function autoscale_values!(app, ax, xs::AbstractVector, ys::AbstractVector; pad_ratio=0.05)
    if isempty(xs) || isempty(ys)
        return
    end
    time_range = app.layout[:time_range]

    # remove NaNs from the series
    valid = .!isnan.(ys)
    xs = xs[valid]
    ys = ys[valid]
    if isempty(xs)
        return
    end

    xmin, xmax = minimum(xs), maximum(xs)

    if xmax < time_range
        xmax = time_range
    end

    if xmax - xmin > time_range
        xmin = xmax - time_range
        # reroll y-range for new xmin boundary
        in_win = (xs .>= xmin) .& (xs .<= xmax)
        if any(in_win)
            ymin = minimum(ys[in_win])
        else
            ymin = minimum(ys)
        end
    end

    # compute y-range using only points inside the current x-window;
    # this will be updated again if we adjust the xmin limit below
    in_win = (xs .>= xmin) .& (xs .<= xmax)
    if any(in_win)
        ymin, ymax = minimum(ys[in_win]), maximum(ys[in_win])
    else
        ymin, ymax = minimum(ys), maximum(ys)
    end

    # avoid zero‑range
    if xmin == xmax
        xmin -= 0.5
        xmax += 0.5
    end
    if ymin == ymax
        ymin -= 0.5
        ymax += 0.5
    end

    xpad = (xmax - xmin) * pad_ratio
    ypad = (ymax - ymin) * pad_ratio

    xlims!(ax, xmin - xpad, xmax + xpad)
    ylims!(ax, ymin - ypad, ymax + ypad)
end

"""
    lookup_plot_series(app_run, selection)

Return x/y data vectors matching a plot selection label.
"""
function lookup_plot_series(app_run, selection)
    if selection == "Histogram"
        return (app_run.hist_time[], app_run.histogram[])
    elseif selection == "Photon counts"
        return (app_run.timestamps[], app_run.photons[])
    elseif selection == "Lifetime"
        return (app_run.timestamps[], app_run.lifetime[])
    elseif selection == "Ion concentration"
        return (app_run.timestamps[], app_run.concentration[])
    elseif selection == "Command"
        return (vcat(app_run.timestamps[], app_run.timestamps[]), vcat(app_run.command1[], app_run.command2[]))
    else
        return (Float64[], Float64[])
    end
end

"""
consumer_loop(app_run)

Consumes data from the channel and updates the app_run observables.
Notifications are throttled to approximately 30 Hz to avoid overwhelming
the GUI with too frequent updates.
"""
function consumer_loop(app, app_run, blocks; rate=30)
    last_notify_time = time()
    notify_interval = 1.0 / rate
    ax1 = blocks[:plot_1_axis]
    ax2 = blocks[:plot_2_axis]

    try
        for (histogram, fit, photons, command1, command2, lifetime, concentration, timestamps, counts, i) in app_run.channel
            push!(app_run.photons[], photons)
            push!(app_run.lifetime[], lifetime)
            push!(app_run.concentration[], concentration)
            push!(app_run.command1[], command1)
            push!(app_run.command2[], command2)
            push!(app_run.timestamps[], timestamps)
            app_run.i[] = i

            current_time = time()

            if current_time - last_notify_time >= notify_interval
                app_run.histogram[] = histogram
                app_run.fit[] = fit
                app_run.counts[] = counts

                notify(app_run.photons)
                notify(app_run.lifetime)
                notify(app_run.concentration)
                notify(app_run.command1)
                notify(app_run.command2)
                notify(app_run.timestamps)
                notify(app_run.i)

                last_notify_time = current_time

                sel1 = app.layout[:plot1]
                sel2 = app.layout[:plot2]

                if sel1 == "Histogram"
                    autoscale_values!(ax1)
                elseif sel1 == "Command"
                    xs, _ = lookup_plot_series(app_run, sel1)
                    autoscale_values!(app, ax1, xs)
                else
                    xs, ys = lookup_plot_series(app_run, sel1)
                    autoscale_values!(app, ax1, xs, ys)
                end

                if sel2 == "Histogram"
                    autoscale_values!(ax2)
                elseif sel2 == "Command"
                    xs, _ = lookup_plot_series(app_run, sel2)
                    autoscale_values!(app, ax2, xs)
                else
                    xs, ys = lookup_plot_series(app_run, sel2)
                    autoscale_values!(app, ax2, xs, ys)
                end
            end
        end
    catch e
        @error "Consumer error" e
    end
end

function infos_loop(app_run, info_label; rate=1.0)
    last_i = app_run.i[]
    dt = 1/float(rate)
    while app_run.running[]
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

"""
    _last_or_nan(values::Vector{Float64})::Float64

Return the latest value of a series, or `NaN` when empty.
"""
function _last_or_nan(values::Vector{Float64})::Float64
    return isempty(values) ? NaN : values[end]
end

"""
    _safe_frequency(controller::Dict{Symbol, Any})::Int

Read PWM frequency from controller config and clamp to a positive integer.
"""
function _safe_frequency(controller::Dict{Symbol, Any})::Int
    raw = try
        Float64(get(controller, :freq, 1000))
    catch
        1000.0
    end
    return max(1, Int(round(raw)))
end

"""
    _write_pwm_command!(serial_conn, channel::Int, frequency::Int, command::Float64)

Emit the proper command for PWM/analog output depending on command saturation.
"""
function _write_pwm_command!(serial_conn, channel::Int, frequency::Int, command::Float64)
    cmd = isfinite(command) ? clamp(command, 0.0, 100.0) : 0.0

    if cmd <= 0.0
        write(serial_conn, "A 0 AO $channel 0\n")
    elseif cmd >= 100.0
        write(serial_conn, "A 0 AO $channel 5000\n")
    else
        write(serial_conn, "A 0 AP $channel $(Int(frequency)) $cmd 0 5000\n")
    end

    return nothing
end

"""
    send_command(serial_conn, command_str::AbstractString)

Write a raw command string to serial.
"""
function send_command(serial_conn, command_str::AbstractString)
    write(serial_conn, String(command_str))
    return nothing
end

"""
    serial_signal_loop(app, app_run; rate=10.0)

Periodic task that sends controller commands to the connected serial device.
"""
function serial_signal_loop(app, app_run; rate=10.0)
    dt = 1 / float(rate)

    while app_run.running[]
        serial_conn = app_run.serial_conn

        if serial_conn === nothing
            sleep(dt)
            continue
        end

        try
            frequency = _safe_frequency(app.controller)
            cmd1 = _last_or_nan(app_run.command1[])
            cmd2 = _last_or_nan(app_run.command2[])

            _write_pwm_command!(serial_conn, 1, frequency, cmd1)
            _write_pwm_command!(serial_conn, 2, frequency, cmd2)
        catch e
            @warn "Serial signal send failed" error=string(e)

            try
                close(serial_conn)
            catch
            end

            app_run.serial_conn = nothing
        end

        sleep(dt)
    end

    return nothing
end

# -----------------------------------------------------------------------------
# button handlers
# -----------------------------------------------------------------------------

"""
start_pressed(app, app_run, blocks)

Handler called when the START button is clicked.  It sets up the
communication channel, resets all time-series observables, and launches
four background tasks:

* **worker_task** - executes `test` which reads data files and pushes
  tuples onto the channel;
* **consumer_task** - pulls tuples from the channel and updates the
  `app_run` observables so that the plots react;
* **autoscaler_task** - periodically adjusts the axes limits at 30 Hz;
* **infos_task** - refreshes the status label at 1 Hz.

The `blocks` dict is used by the latter two tasks to obtain the
necessary axes and info label objects.
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
    
    @info "Starting test function"
    app_run.running[] = true
    app_run.channel = Channel{Tuple{Vector{Float64},Vector{Float64},Float64,Float64,Float64,Float64,Float64,Float64,Float64,UInt32}}(32)

    # reset time-series data
    empty!(app_run.photons[])
    app_run.counts[] = 0.0
    empty!(app_run.lifetime[])
    empty!(app_run.concentration[])
    empty!(app_run.command1[])
    empty!(app_run.command2[])
    empty!(app_run.timestamps[])
    app_run.i[] = 0

    # worker & consumer
    selected_mode = haskey(blocks, :mode_menu) ? blocks[:mode_menu].selection[] : "Playback"
    if !(selected_mode isa AbstractString)
        selected_mode = "Playback"
    end
    playback = selected_mode == "Playback"

    if playback
        app_run.worker_task = @async start_playback(
            app_run.channel,
            app_run.running,
            app.layout,
            app.controller
        )
    else
        app_run.worker_task = @async start_realtime(
            app_run.channel,
            app_run.running,
            app.layout,
            app.controller
        )
    end

    app_run.consumer_task = @async consumer_loop(app, app_run, blocks; rate=10)
    app_run.serial_task = @async serial_signal_loop(app, app_run; rate=20.0)

    # periodic tasks
    # app_run.autoscaler_task = @async autoscaler_loop(app, app_run, blocks; rate=10)
    # info label is optional; if missing we simply skip the task
    # if haskey(blocks, :info_label)
    app_run.infos_task = @async infos_loop(app_run, blocks[:info_label]; rate=1)
    # end

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
        @info "Not running"
        return
    end

    @info "Stopping test function"
    
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
    return nothing
end
