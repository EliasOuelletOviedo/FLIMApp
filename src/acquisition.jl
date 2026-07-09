"""
acquisition.jl

Data acquisition worker tasks for the FLIM application: Playback, Realtime,
and Save modes. Serial port discovery lives in serial.jl; protocol schedule
math lives in protocol.jl.

The three modes share ~90% of their logic (sliding-window histogram binning,
lifetime fitting with optional partial-fit optimization, PID command
computation, channel emission) via `run_acquisition_loop!`. They differ only
in how the next file to process is chosen and what happens after a result is
emitted:
- Playback: round-robins a fixed, sorted file list on a fixed-frequency schedule.
- Realtime: polls the data folder for the newest new file, waiting if none.
- Save: iterates the fixed file list once, reporting progress via a callback.
"""

using Base.Threads

# =============================================================================
# SHARED CORE LOOP
# =============================================================================

"""
    run_acquisition_loop!(ch, running, layout, controller, next_file!, emit!;
                           initial_guess, protocol, use_partial_fit)

Shared body for all three acquisition modes. Repeatedly calls `next_file!(n)`
(with `n` the current, pre-increment frame counter) to obtain the next
`.sdt` filepath to process — or `nothing` to stop the loop, which each mode
uses to encode its own pacing/waiting/termination policy. For each file it
does sliding-window histogram binning, lifetime fitting (full or partial, see
`use_partial_fit`), and PID command computation, then calls
`emit!(sample, n)` — which each mode uses to `put!` onto `ch` plus its own
post-emit policy (extra pacing, progress reporting) — returning `false` to
stop the loop.

Must be called from within the caller's own `try/catch/finally` so that
IRF/path validation failures and cleanup (closing `ch`, clearing `running[]`)
are handled by the specific mode wrapper (see `start_playback`/
`start_realtime`/`start_save` below).
"""
function run_acquisition_loop!(
        ch::Channel{AcquisitionSample},
        running::Threads.Atomic{Bool},
        layout::LayoutSettings,
        controller::ControllerSettings,
        next_file!::Function,
        emit!::Function;
        initial_guess::Vector{Float64},
        protocol::Union{Nothing, ProtocolSettings, Observables.AbstractObservable},
        use_partial_fit::Bool
    )
    timestamps = 0.0
    vectors = zeros(100, DEFAULT_HISTOGRAM_RESOLUTION)
    n_vectors = 100

    # Sliding sum optimization for binning
    sum_vector = zeros(Float64, DEFAULT_HISTOGRAM_RESOLUTION)
    last_bin = 1
    current_count = 0

    # Initial parameter guess for lifetime fitting
    params = copy(initial_guess)
    full_fit_params = copy(initial_guess)
    n = UInt32(0)
    first_fit_pending = true
    partial_fit_period = 10
    partial_fit_enabled = use_partial_fit && length(initial_guess) == 3

    if use_partial_fit && !partial_fit_enabled
        @warn "Partial fit mode is only supported for 3-parameter fits; falling back to full fits."
    end

    # PID state for lifetime control
    fallback_setpoint_ns = 4.0
    I_error = 0.0
    old_error = 0.0
    D_error = 0.0
    pid_prev_smooth_lifetime = NaN
    pid_prev_raw_lifetime = NaN
    pid_scale_est = 1.0e-6

    # Captured once, not per-iteration: RuntimeContext is mutable and RUNTIME[]
    # always returns the same object, so this stays live if init_irf_runtime!()
    # reloads the IRF mid-run — while letting the compiler specialize the loop
    # body on ctx's concrete field types instead of re-reading an untyped global.
    ctx = RUNTIME[]

    while running[]
        filepath = next_file!(n)
        if filepath === nothing
            break
        end

        vector, histogram_resolution, frame_time = read_sdt_frame(filepath)

        # Store in circular buffer
        pos = mod1(n+1, n_vectors)
        vectors[pos, 1:histogram_resolution] .= vector

        # Apply binning from layout with sliding window optimization
        bin = layout.binning

        if bin != last_bin
            # Recalculate when binning changes
            effective_bin = min(bin, current_count + 1)
            idxs = mod1.(pos .- (0:effective_bin-1), n_vectors)
            fill!(sum_vector, 0.0)
            @inbounds for idx in idxs
                @views sum_vector[1:histogram_resolution] .+= vectors[idx, 1:histogram_resolution]
            end
            last_bin = bin
            current_count = effective_bin
        else
            if current_count < bin
                # Still filling window
                sum_vector .+= vector
                current_count += 1
            else
                # Slide window: remove oldest, add new
                old_pos = mod1(pos - bin, n_vectors)
                sum_vector .-= vectors[old_pos, 1:histogram_resolution]
                sum_vector .+= vector
            end
        end

        final_vector = sum_vector ./ bin

        # Fit every processed frame/file.
        fit_index = Int(n) + 1
        use_full_fit = !partial_fit_enabled || fit_index == 1 || mod1(fit_index, partial_fit_period) == 1

        if use_full_fit
            params_raw, data = vec_to_lifetime(Float64.(final_vector); guess=full_fit_params, histogram_resolution=histogram_resolution, first_fit=first_fit_pending)
            first_fit_pending = false

            if !isnan(params_raw[1])
                params = params_raw
                full_fit_params = params_raw
            end
        else
            fixed_parameters = Float64[NaN, NaN, full_fit_params[3]]
            params_raw, data = vec_to_lifetime(Float64.(final_vector); guess=params, histogram_resolution=histogram_resolution, fixed_parameters=fixed_parameters, first_fit=false)

            if !isnan(params_raw[1])
                params = params_raw
            end
        end

        histogram = data[2]
        photons = sum(histogram)
        fit = conv_irf_data(data[1], Tuple(params), ctx.irf; histogram_resolution=histogram_resolution) * photons
        lifetime = params[1]
        concentration = (9.5 / lifetime - 1) / 0.025
        timestamps += frame_time
        n += 1

        current_protocol = resolve_protocol_config(protocol)
        protocol_active = current_protocol !== nothing && current_protocol.active
        setpoint_ns = protocol_active ? protocol_setpoint_at_timestamp(current_protocol, timestamps) : fallback_setpoint_ns

        # Distinct from setpoint_ns: PID control keeps regulating toward the
        # fallback setpoint even without an active protocol, but the plotted
        # series/highlight should only reflect a genuine protocol schedule —
        # otherwise the Lifetime plot shows a spurious line and vspan at the
        # fallback value whenever the protocol is off.
        plot_setpoint_ns = protocol_active ? setpoint_ns : NaN

        smooth_level = layout_smoothing_level(layout)
        lifetime_for_pid, pid_prev_smooth_lifetime, pid_prev_raw_lifetime, pid_scale_est =
            update_pid_lifetime_kalman(
                lifetime,
                pid_prev_smooth_lifetime,
                pid_prev_raw_lifetime,
                pid_scale_est,
                smooth_level
            )

        command1 = NaN
        command2 = NaN

        if !isnan(setpoint_ns)
            # PID terms are shared from one lifetime error for both controllers.
            dt_sample = max(Float64(frame_time), eps(Float64))
            P_error = setpoint_ns - lifetime_for_pid
            I_error += P_error * dt_sample
            D_error = (P_error - old_error) / dt_sample
            old_error = P_error

            command1 = controller.P1*P_error + controller.I1*I_error + controller.D1*D_error
            command2 = controller.P2*P_error + controller.I2*I_error + controller.D2*D_error

            # Inversion is applied only to the command sent to each controller.
            if controller.ch1_inv
                command1 = -command1
            end

            if controller.ch2_inv
                command2 = -command2
            end

            if controller.ch1_on
                command1 = clamp(command1, 0.0, 100.0)
            else
                command1 = NaN
            end

            if controller.ch2_on
                command2 = clamp(command2, 0.0, 100.0)
            else
                command2 = NaN
            end
        else
            I_error = 0.0
            old_error = 0.0
            D_error = 0.0
        end

        if !(isopen(ch) && running[])
            break
        end

        sample = (histogram, fit, photons, command1, command2, lifetime, concentration, timestamps, plot_setpoint_ns, n, String(filepath))
        if !emit!(sample, n)
            break
        end
    end

    return nothing
end

# =============================================================================
# PLAYBACK MODE
# =============================================================================

"""
    start_playback(ch, running, layout, controller; kwargs...)

Worker task for Playback mode: round-robins over all `.sdt` files in
`get_data_root_path()` on a fixed-frequency schedule (`target_frequency`).
See `run_acquisition_loop!` for the shared fitting/binning/PID body.
"""
function start_playback(
        ch::Channel{AcquisitionSample},
        running::Threads.Atomic{Bool},
        layout::LayoutSettings,
        controller::ControllerSettings;
        initial_guess::Vector{Float64} = [3.0, 0.0, 5.0e-5],
        protocol::Union{Nothing, ProtocolSettings, Observables.AbstractObservable} = nothing,
        paused::Union{Nothing, Threads.Atomic{Bool}} = nothing,
        dt::Float64 = 0.0001,
        use_partial_fit::Bool = true,
        target_frequency::Float64 = 60.0
    )
    try
        @info "Playback worker started on thread $(threadid())"

        @info "Checking IRF status: irf=$(RUNTIME[].irf !== nothing), tcspc_window_size=$(RUNTIME[].tcspc_window_size !== nothing)"
        if RUNTIME[].irf === nothing || RUNTIME[].tcspc_window_size === nothing
            @error "IRF not loaded - cannot start data processing. Please load an IRF file first."
            @error "IRF status: irf=$(RUNTIME[].irf !== nothing), tcspc_window_size=$(RUNTIME[].tcspc_window_size !== nothing)"
            return nothing
        end

        path = get_data_root_path()
        if !isdir(path)
            @error "Data folder not found: $path"
            return nothing
        end

        all_entries = readdir(path; join=true)
        filepaths = sort(filter(f -> isfile(f) && endswith(lowercase(f), ".sdt"), all_entries))
        nb_files = length(filepaths)

        if nb_files == 0
            @error "No .sdt files found in $path"
            return nothing
        end

        target_period_ns = round(Int, 1e9 / target_frequency)
        next_analysis_ns = Ref(time_ns())

        next_file! = function (n)
            while running[]
                if paused !== nothing && paused[]
                    next_analysis_ns[] = time_ns() + target_period_ns
                    sleep(min(dt, 0.02))
                    continue
                end

                now_ns = time_ns()
                if now_ns < next_analysis_ns[]
                    remaining_s = (next_analysis_ns[] - now_ns) / 1e9
                    sleep(min(dt, remaining_s))
                    continue
                end

                # Keep a fixed schedule when possible; if we are late, restart from now.
                next_analysis_ns[] += target_period_ns
                if next_analysis_ns[] < now_ns
                    next_analysis_ns[] = now_ns + target_period_ns
                end

                return filepaths[mod1(n+1, nb_files)]
            end
            return nothing
        end

        emit! = function (sample, n)
            try
                put!(ch, sample)
            catch e
                isa(e, InvalidStateException) && return false
                rethrow()
            end
            return true
        end

        run_acquisition_loop!(ch, running, layout, controller, next_file!, emit!;
                               initial_guess=initial_guess, protocol=protocol, use_partial_fit=use_partial_fit)
    catch e
        @error "Playback worker error" exception=e
        rethrow()
    finally
        running[] = false
        try
            close(ch)
        catch
            # Ignore if already closed
        end
        @info "Playback worker finished"
    end

    return nothing
end

# =============================================================================
# REALTIME MODE
# =============================================================================

"""
    start_realtime(ch, running, layout, controller; kwargs...)

Worker task for Real-time mode: always processes the newest available
`.sdt` file in `get_data_root_path()`, waiting (polling every
`poll_interval_s`) if no new file has appeared yet. See
`run_acquisition_loop!` for the shared fitting/binning/PID body.
"""
function start_realtime(
        ch::Channel{AcquisitionSample},
        running::Threads.Atomic{Bool},
        layout::LayoutSettings,
        controller::ControllerSettings;
        initial_guess::Vector{Float64} = [3.0, 0.5, 0.5, 0.0, 5.0e-5],
        protocol::Union{Nothing, ProtocolSettings, Observables.AbstractObservable} = nothing,
        paused::Union{Nothing, Threads.Atomic{Bool}} = nothing,
        dt::Float64 = 0.0001,
        poll_interval_s::Float64 = 0.1
    )
    try
        @info "Real-time worker started on thread $(threadid())"

        @info "Checking IRF status: irf=$(RUNTIME[].irf !== nothing), tcspc_window_size=$(RUNTIME[].tcspc_window_size !== nothing)"
        if RUNTIME[].irf === nothing || RUNTIME[].tcspc_window_size === nothing
            @error "IRF not loaded - cannot start data processing. Please load an IRF file first."
            @error "IRF status: irf=$(RUNTIME[].irf !== nothing), tcspc_window_size=$(RUNTIME[].tcspc_window_size !== nothing)"
            return nothing
        end

        path = get_data_root_path()
        @info "Real-time mode active: waiting for new .sdt files in $path"

        last_dir_mtime = Ref(0.0)
        next_scan_at = Ref(0.0)

        # Build the initial queue sorted, so the oldest file is processed
        # first — the first file shown in the plots should be the first
        # file read, not whichever file happens to be newest when the mode
        # starts on a folder that already has a backlog.
        initial_files = sort(filter(f -> isfile(f) && endswith(lowercase(f), ".sdt"), readdir(path; join=true)))
        pending_queue = Ref(initial_files)
        known_sdt_files = Ref(Set{String}(initial_files))

        if isempty(pending_queue[])
            @warn "No .sdt files found yet in real-time folder" path=path
        end

        next_file! = function (n)
            while running[]
                if paused !== nothing && paused[]
                    sleep(min(dt, 0.05))
                    continue
                end

                if !isempty(pending_queue[])
                    return popfirst!(pending_queue[])
                end

                now_t = time()
                if now_t < next_scan_at[]
                    sleep(min(dt, max(1e-4, next_scan_at[] - now_t)))
                    continue
                end
                next_scan_at[] = now_t + poll_interval_s

                dir_stat = try
                    stat(path)
                catch
                    nothing
                end

                if dir_stat === nothing
                    sleep(poll_interval_s)
                    continue
                end

                current_dir_mtime = dir_stat.mtime

                if current_dir_mtime != last_dir_mtime[]
                    last_dir_mtime[] = current_dir_mtime

                    new_files = String[]
                    for entry in readdir(path; join=true)
                        if isfile(entry) && endswith(lowercase(entry), ".sdt") && !(entry in known_sdt_files[])
                            push!(new_files, entry)
                            push!(known_sdt_files[], entry)
                        end
                    end

                    if !isempty(new_files)
                        append!(pending_queue[], sort(new_files))
                    end
                end

                if isempty(pending_queue[])
                    sleep(poll_interval_s)
                    continue
                end
            end
            return nothing
        end

        emit! = function (sample, n)
            try
                put!(ch, sample)
            catch e
                isa(e, InvalidStateException) && return false
                rethrow()
            end
            sleep(dt)
            return true
        end

        run_acquisition_loop!(ch, running, layout, controller, next_file!, emit!;
                               initial_guess=initial_guess, protocol=protocol, use_partial_fit=false)
    catch e
        @error "Real-time worker error" exception=e
        rethrow()
    finally
        running[] = false
        try
            close(ch)
        catch
            # Ignore if already closed
        end
        @info "Real-time worker finished"
    end

    return nothing
end

# =============================================================================
# SAVE MODE
# =============================================================================

"""
    start_save(ch, running, layout, controller; kwargs...)

Worker task for Save mode: processes all `.sdt` files in
`get_data_root_path()` once, reporting progress via `progress_cb(pct)`, then
stops naturally once every file has been processed. See
`run_acquisition_loop!` for the shared fitting/binning/PID body.
"""
function start_save(
        ch::Channel{AcquisitionSample},
        running::Threads.Atomic{Bool},
        layout::LayoutSettings,
        controller::ControllerSettings;
        initial_guess::Vector{Float64} = [3.0, 0.0, 5.0e-5],
        protocol::Union{Nothing, ProtocolSettings, Observables.AbstractObservable} = nothing,
        paused::Union{Nothing, Threads.Atomic{Bool}} = nothing,
        dt::Float64 = 0.0000001,
        use_partial_fit::Bool = true,
        progress_cb::Union{Nothing, Function} = nothing
    )
    try
        @info "Save worker started on thread $(threadid())"

        @info "Checking IRF status: irf=$(RUNTIME[].irf !== nothing), tcspc_window_size=$(RUNTIME[].tcspc_window_size !== nothing)"
        if RUNTIME[].irf === nothing || RUNTIME[].tcspc_window_size === nothing
            @error "IRF not loaded - cannot start data processing. Please load an IRF file first."
            @error "IRF status: irf=$(RUNTIME[].irf !== nothing), tcspc_window_size=$(RUNTIME[].tcspc_window_size !== nothing)"
            return nothing
        end

        path = get_data_root_path()
        if !isdir(path)
            @error "Data folder not found: $path"
            return nothing
        end

        all_entries = readdir(path; join=true)
        filepaths = sort(filter(f -> isfile(f) && endswith(lowercase(f), ".sdt"), all_entries))
        nb_files = length(filepaths)

        if nb_files == 0
            @error "No .sdt files found in $path"
            return nothing
        end

        last_progress_pct = Ref(-1)

        if progress_cb !== nothing
            try
                progress_cb(0)
                last_progress_pct[] = 0
            catch e
                @warn "Save progress callback failed" error=string(e)
                progress_cb = nothing
            end
        end

        file_idx = Ref(0)

        next_file! = function (n)
            if !running[]
                return nothing
            end

            while running[] && paused !== nothing && paused[]
                sleep(min(dt, 0.05))
            end

            if !running[]
                return nothing
            end

            file_idx[] += 1
            if file_idx[] > nb_files
                return nothing
            end

            return filepaths[file_idx[]]
        end

        emit! = function (sample, n)
            try
                put!(ch, sample)
            catch e
                isa(e, InvalidStateException) && return false
                rethrow()
            end

            if progress_cb !== nothing
                progress_pct = clamp(floor(Int, (Int(n) * 100) / nb_files), 0, 100)
                if progress_pct > last_progress_pct[]
                    for pct in (last_progress_pct[] + 1):progress_pct
                        try
                            progress_cb(pct)
                        catch e
                            @warn "Save progress callback failed" error=string(e)
                            progress_cb = nothing
                            break
                        end
                    end
                    last_progress_pct[] = progress_pct
                end
            end

            if dt > 0.0
                sleep(dt)
            end

            return true
        end

        run_acquisition_loop!(ch, running, layout, controller, next_file!, emit!;
                               initial_guess=initial_guess, protocol=protocol, use_partial_fit=use_partial_fit)
    catch e
        @error "Save worker error" exception=e
        rethrow()
    finally
        running[] = false
        try
            close(ch)
        catch
            # Ignore if already closed
        end
        @info "Save worker finished"
    end

    return nothing
end
