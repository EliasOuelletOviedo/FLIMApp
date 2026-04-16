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

const LIFETIME_WARMUP_DONE = Ref(false)

function recompute_lifetime_smooth!(app, app_run)
    # Snapshot mutable vectors to avoid transient length races with the consumer task.
    lifetime_values = copy(app_run.lifetime[])
    timestamps_values = copy(app_run.timestamps[])

    n_lifetime = length(lifetime_values)
    n_timestamps = length(timestamps_values)
    n_common = min(n_lifetime, n_timestamps)

    smoothed = fill(NaN, n_timestamps)

    level = lifetime_smooth_level(app.layout)
    prev = NaN

    for idx in 1:n_common
        y = compute_lifetime_smooth_at(lifetime_values, idx, level, prev)
        smoothed[idx] = y
        prev = y
    end

    app_run.lifetime_smooth[] = smoothed
    return nothing
end

function append_lifetime_smooth!(app, app_run)
    idx = length(app_run.lifetime[])
    if idx == 0
        return nothing
    end

    level = lifetime_smooth_level(app.layout)
    prev = isempty(app_run.lifetime_smooth[]) ? NaN : app_run.lifetime_smooth[][end]

    y = compute_lifetime_smooth_at(app_run.lifetime[], idx, level, prev)
    push!(app_run.lifetime_smooth[], y)

    return nothing
end

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

function protocol_setpoint_spans(
    timestamps::AbstractVector{<:Real},
    setpoints::AbstractVector{<:Real}
)::Tuple{Vector{Float64}, Vector{Float64}}
    n = min(length(timestamps), length(setpoints))
    starts = Float64[]
    ends = Float64[]

    if n == 0
        return (starts, ends)
    end

    active_start = nothing

    for idx in 1:n
        t = Float64(timestamps[idx])
        sp = Float64(setpoints[idx])

        if !isfinite(t)
            continue
        end

        if isfinite(sp)
            if active_start === nothing
                active_start = t
            end
        elseif active_start !== nothing
            push!(starts, active_start)
            push!(ends, t)
            active_start = nothing
        end
    end

    if active_start !== nothing
        push!(starts, active_start)
        push!(ends, Float64(timestamps[n]))
    end

    return (starts, ends)
end

function add_protocol_setpoint_highlight!(ax, app_run)
    spans = lift(app_run.timestamps, app_run.protocol_setpoint) do ts, sp
        starts, ends = protocol_setpoint_spans(ts, sp)
        if isempty(starts)
            return ([NaN], [NaN])
        end
        return (starts, ends)
    end

    span_starts = lift(x -> x[1], spans)
    span_ends = lift(x -> x[2], spans)
    vspan!(ax, span_starts, span_ends, color = (Makie.wong_colors()[2], 0.05))

    return nothing
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
    lookup_plot_series(app_run, plot_label)

Return x/y vectors for one plot label.
Labels supported: `Histogram`, `Photon counts`, `Lifetime`, `Ion concentration`, `Command`.
"""
function lookup_plot_series(app_run, plot_label)
    if plot_label == "Histogram"
        return (app_run.hist_time[], app_run.histogram[])
    end

    if plot_label == "Photon counts"
        return (app_run.timestamps[], app_run.photons[])
    end

    if plot_label == "Lifetime"
        return (
            vcat(app_run.timestamps[], app_run.timestamps[], app_run.timestamps[]),
            vcat(app_run.lifetime[], app_run.lifetime_smooth[], app_run.protocol_setpoint[])
        )
    end

    if plot_label == "Ion concentration"
        return (app_run.timestamps[], app_run.concentration[])
    end

    if plot_label == "Command"
        return (
            vcat(app_run.timestamps[], app_run.timestamps[]),
            vcat(app_run.command1[], app_run.command2[])
        )
    end

    return (Float64[], Float64[])
end

function notify_runtime_observables!(app_run)
    notify(app_run.photons)
    notify(app_run.lifetime)
    notify(app_run.lifetime_smooth)
    notify(app_run.protocol_setpoint)
    notify(app_run.concentration)
    notify(app_run.command1)
    notify(app_run.command2)
    notify(app_run.timestamps)
    notify(app_run.i)
    return nothing
end

function autoscale_plot_selection!(app, app_run, axis, plot_label)
    if plot_label == "Histogram"
        autoscale_values!(axis)
        return nothing
    end

    xs, ys = lookup_plot_series(app_run, plot_label)

    if plot_label == "Command"
        autoscale_values!(app, axis, xs)
    else
        autoscale_values!(app, axis, xs, ys)
    end

    return nothing
end

"""
consumer_loop(app_run)

Consumes data from the channel and updates the app_run observables.
Notifications are throttled to approximately 30 Hz to avoid overwhelming
the GUI with too frequent updates.
"""
function consumer_loop(app, app_run, blocks; rate=30)
    last_publish_time = time()
    publish_interval_s = 1.0 / rate
    plot_1_axis = blocks[:plot_1_axis]
    plot_2_axis = blocks[:plot_2_axis]
    last_histogram = nothing
    last_fit = nothing
    last_photons = NaN

    try
        for sample in app_run.channel
            while app_run.running[] && app_run.paused[]
                sleep(0.02)
            end

            if !app_run.running[]
                break
            end

            histogram, fit, photons, command1, command2, lifetime, concentration, timestamp, protocol_setpoint, frame_idx = sample
            last_histogram = histogram
            last_fit = fit
            last_photons = photons

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

            if now_s - last_publish_time >= publish_interval_s
                app_run.histogram[] = histogram
                app_run.fit[] = fit
                app_run.counts[] = photons

                notify_runtime_observables!(app_run)

                last_publish_time = now_s

                autoscale_plot_selection!(app, app_run, plot_1_axis, app.layout[:plot1])
                autoscale_plot_selection!(app, app_run, plot_2_axis, app.layout[:plot2])
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
                autoscale_plot_selection!(app, app_run, plot_1_axis, app.layout[:plot1])
                autoscale_plot_selection!(app, app_run, plot_2_axis, app.layout[:plot2])
            end
        end

        if !app_run.running[]
            app_run.save_progress[] = NaN
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

"""
    last_or_nan(values::Vector{Float64})::Float64

Return the latest value of a series, or `NaN` when empty.
"""
function last_or_nan(values::Vector{Float64})::Float64
    return isempty(values) ? NaN : values[end]
end

"""
    safe_frequency(controller::Dict{Symbol, Any})::Int

Read PWM frequency from controller config and clamp to a positive integer.
"""
function safe_frequency(controller::Dict{Symbol, Any})::Int
    raw = try
        Float64(get(controller, :freq, 1000))
    catch
        1000.0
    end
    return max(1, Int(round(raw)))
end

"""
    write_pwm_command!(serial_conn, channel::Int, frequency::Int, command::Float64)

Emit the proper command for PWM/analog output depending on command saturation.
"""
function write_pwm_command!(serial_conn, channel::Int, frequency::Int, command::Float64)
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

function normalize_protocol_config(raw_protocol)::Dict{Symbol, Any}
    times_raw = get(raw_protocol, :times, Float64[])
    setpoints_raw = get(raw_protocol, :setpoints, Float64[])

    times = times_raw isa AbstractVector ? [v isa Number ? Float64(v) : NaN for v in times_raw] : Float64[]
    setpoints = setpoints_raw isa AbstractVector ? [v isa Number ? Float64(v) : NaN for v in setpoints_raw] : Float64[]

    repeats_raw = get(raw_protocol, :repeats, 1)
    delay_raw = get(raw_protocol, :delay, 0)

    repeats = repeats_raw isa Number ? Int(round(Float64(repeats_raw))) : 1
    delay = delay_raw isa Number ? Int(round(Float64(delay_raw))) : 0

    return Dict{Symbol, Any}(
        :active => Bool(get(raw_protocol, :active, false)),
        :delay => max(delay, 0),
        :repeats => max(repeats, 0),
        :times => times,
        :setpoints => setpoints
    )
end

function sync_runtime_protocol!(app, app_run)
    app_run.protocol[] = normalize_protocol_config(app.protocol)
    return nothing
end

"""
    serial_signal_loop(app, app_run; rate=10.0)

Periodic task that sends controller commands to the connected serial device.
"""
function serial_signal_loop(app, app_run; rate=10.0)
    dt = 1 / float(rate)

    while app_run.running[]
        if app_run.paused[]
            sleep(min(dt, 0.05))
            continue
        end

        serial_conn = app_run.serial_conn

        if serial_conn === nothing
            sleep(dt)
            continue
        end

        try
            frequency = safe_frequency(app.controller)
            cmd1 = last_or_nan(app_run.command1[])
            cmd2 = last_or_nan(app_run.command2[])

            write_pwm_command!(serial_conn, 1, frequency, cmd1)
            write_pwm_command!(serial_conn, 2, frequency, cmd2)
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

    warmup_lifetime_fit!()
    
    @info "Starting test function"
    app_run.running[] = true
    app_run.paused[] = false
    app_run.channel = Channel{Tuple{Vector{Float64},Vector{Float64},Float64,Float64,Float64,Float64,Float64,Float64,Float64,UInt32}}(32)

    # reset time-series data
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

    # worker & consumer
    selected_mode = haskey(blocks, :mode_menu) ? blocks[:mode_menu].selection[] : "Playback"
    if !(selected_mode isa AbstractString)
        selected_mode = "Playback"
    end

    selected_lifetimes = haskey(blocks, :lifetimes_menu) ? blocks[:lifetimes_menu].selection[] : "2 lifetimes"
    if !(selected_lifetimes isa AbstractString)
        selected_lifetimes = "2 lifetimes"
    end

    initial_guess = if selected_lifetimes == "1 lifetime"
        [3.0, 0.0, 5.0e-5]
    elseif selected_lifetimes == "3 lifetimes"
        [3.0, 0.5, 0.5, 0.5, 0.5, 0.0, 5.0e-5]
    else
        [3.0, 0.5, 0.5, 0.0, 5.0e-5]
    end

    sync_runtime_protocol!(app, app_run)
    protocol_config = app_run.protocol

    if selected_mode == "Playback"
        app_run.worker_task = @async start_playback(
            app_run.channel,
            app_run.running,
            app.layout,
            app.controller;
            initial_guess=initial_guess,
            protocol=protocol_config,
            paused=app_run.paused,
            target_frequency=60.0
        )
    elseif selected_mode == "Realtime"
        app_run.worker_task = @async start_realtime(
            app_run.channel,
            app_run.running,
            app.layout,
            app.controller;
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
            app.layout,
            app.controller;
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
            app.layout,
            app.controller;
            initial_guess=initial_guess,
            protocol=protocol_config,
            paused=app_run.paused,
            target_frequency=60.0
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
