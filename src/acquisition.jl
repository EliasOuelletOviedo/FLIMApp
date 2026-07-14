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
    ChannelFitState

One TCSPC channel's per-frame accumulator state for `run_acquisition_loop!`:
sliding-window binning buffer, current MLE fit parameters, and PID error
accumulators. Not persisted/Observable like `AppState`/`AppRun` — this is
purely acquisition-loop-internal state, one instance per channel.
"""
mutable struct ChannelFitState
    vectors::Matrix{Float64}
    n_vectors::Int
    sum_vector::Vector{Float64}
    last_bin::Int
    current_count::Int
    params::Vector{Float64}
    full_fit_params::Vector{Float64}
    first_fit_pending::Bool
    I_error::Float64
    old_error::Float64
    D_error::Float64
    pid_prev_smooth_lifetime::Float64
    pid_prev_raw_lifetime::Float64
    pid_scale_est::Float64
end

function ChannelFitState(initial_guess::Vector{Float64})
    return ChannelFitState(
        zeros(100, DEFAULT_HISTOGRAM_RESOLUTION), 100,
        zeros(Float64, DEFAULT_HISTOGRAM_RESOLUTION), 1, 0,
        copy(initial_guess), copy(initial_guess), true,
        0.0, 0.0, 0.0, NaN, NaN, 1.0e-6
    )
end

"""
    pid_command_from_state(state, setpoint_ns, P, I, D, inv, on)::Float64

Apply one controller's gains to `state`'s current error terms (`state.
old_error` holds the latest P_error, `state.I_error`/`state.D_error` the
integral/derivative terms — all just set by `process_channel_frame!`). Split
out from `process_channel_frame!` so a single-channel acquisition (no second
SDT channel in the file) can still drive controller 2's output from channel
1's error dynamics with controller 2's own gains — this is exactly the
original single-channel behavior (`command1`/`command2` were always two
gain-weighted views of one shared error before channel 2 existed), preserved
for files that only ever have one channel.
"""
function pid_command_from_state(state::ChannelFitState, setpoint_ns::Float64, P::Float64, I::Float64, D::Float64, inv::Bool, on::Bool)::Float64
    if isnan(setpoint_ns)
        return NaN
    end

    command = P*state.old_error + I*state.I_error + D*state.D_error
    if inv
        command = -command
    end

    return on ? clamp(command, 0.0, 100.0) : NaN
end

"""
    process_channel_frame!(state, vector, histogram_resolution, n, layout, ctx,
                            partial_fit_enabled, partial_fit_period,
                            setpoint_ns, frame_time, P, I, D, inv, on)
        -> (ChannelFrame, command)

One TCSPC channel's per-frame work: sliding-window histogram binning, MLE
lifetime fit (full or partial), and PID command computation — mutating
`state` in place. `run_acquisition_loop!` calls this once per channel per
frame with that channel's own `ChannelFitState` and controller sub-config
(P1/I1/D1/ch1_inv/ch1_on vs P2/I2/D2/ch2_inv/ch2_on), so each channel is fit
and controlled completely independently when both are present.
"""
function process_channel_frame!(
        state::ChannelFitState,
        vector::Vector{UInt16},
        histogram_resolution::Int,
        n::UInt32,
        layout::LayoutSettings,
        ctx,
        partial_fit_enabled::Bool,
        partial_fit_period::Int,
        setpoint_ns::Float64,
        frame_time::Float32,
        P::Float64, I::Float64, D::Float64,
        inv::Bool, on::Bool
    )
    # Store in circular buffer
    pos = mod1(Int(n)+1, state.n_vectors)
    state.vectors[pos, 1:histogram_resolution] .= vector

    # Apply binning from layout with sliding window optimization
    bin = layout.binning

    if bin != state.last_bin
        # Recalculate when binning changes
        effective_bin = min(bin, state.current_count + 1)
        idxs = mod1.(pos .- (0:effective_bin-1), state.n_vectors)
        fill!(state.sum_vector, 0.0)
        @inbounds for idx in idxs
            @views state.sum_vector[1:histogram_resolution] .+= state.vectors[idx, 1:histogram_resolution]
        end
        state.last_bin = bin
        state.current_count = effective_bin
    else
        if state.current_count < bin
            # Still filling window
            state.sum_vector .+= vector
            state.current_count += 1
        else
            # Slide window: remove oldest, add new
            old_pos = mod1(pos - bin, state.n_vectors)
            state.sum_vector .-= state.vectors[old_pos, 1:histogram_resolution]
            state.sum_vector .+= vector
        end
    end

    final_vector = state.sum_vector ./ bin

    # Fit every processed frame/file.
    fit_index = Int(n) + 1
    use_full_fit = !partial_fit_enabled || fit_index == 1 || mod1(fit_index, partial_fit_period) == 1

    if use_full_fit
        params_raw, data = vec_to_lifetime(Float64.(final_vector); guess=state.full_fit_params, histogram_resolution=histogram_resolution, first_fit=state.first_fit_pending)
        state.first_fit_pending = false

        if !isnan(params_raw[1])
            state.params = params_raw
            state.full_fit_params = params_raw
        end
    else
        # Fix only the offset/background (last parameter) to the last full
        # fit's value; leave every other parameter (lifetime(s),
        # amplitude(s), IRF shift) free. Generic over guess length so this
        # covers both the 1- and 2-lifetime models (see partial_fit_enabled above).
        fixed_parameters = fill(NaN, length(state.full_fit_params))
        fixed_parameters[end] = state.full_fit_params[end]
        params_raw, data = vec_to_lifetime(Float64.(final_vector); guess=state.params, histogram_resolution=histogram_resolution, fixed_parameters=fixed_parameters, first_fit=false)

        if !isnan(params_raw[1])
            state.params = params_raw
        end
    end

    histogram = data[2]
    photons = sum(histogram)
    fit = conv_irf_data(data[1], Tuple(state.params), ctx.irf; histogram_resolution=histogram_resolution) * photons
    lifetime = state.params[1]
    concentration = (9.5 / lifetime - 1) / 0.025

    smooth_level = layout_smoothing_level(layout)
    lifetime_for_pid, state.pid_prev_smooth_lifetime, state.pid_prev_raw_lifetime, state.pid_scale_est =
        update_pid_lifetime_kalman(
            lifetime,
            state.pid_prev_smooth_lifetime,
            state.pid_prev_raw_lifetime,
            state.pid_scale_est,
            smooth_level
        )

    if !isnan(setpoint_ns)
        dt_sample = max(Float64(frame_time), eps(Float64))
        P_error = setpoint_ns - lifetime_for_pid
        state.I_error += P_error * dt_sample
        state.D_error = (P_error - state.old_error) / dt_sample
        state.old_error = P_error
    else
        state.I_error = 0.0
        state.old_error = 0.0
        state.D_error = 0.0
    end

    command = pid_command_from_state(state, setpoint_ns, P, I, D, inv, on)

    return ChannelFrame(histogram, fit, photons, lifetime, concentration), command
end

"""
    run_acquisition_loop!(ch, running, layout, controller, next_file!, emit!;
                           initial_guess, protocol, use_partial_fit)

Shared body for all three acquisition modes. Repeatedly calls `next_file!(n)`
(with `n` the current, pre-increment frame counter) to obtain the next
`.sdt` filepath to process — or `nothing` to stop the loop, which each mode
uses to encode its own pacing/waiting/termination policy. For each file it
runs `process_channel_frame!` for channel 1 and, if the file has a second
TCSPC channel, independently for channel 2 too — decided once from the
first file of the run (`has_channel2`) and held fixed for the rest of the
acquisition, not re-checked per file. Then calls `emit!(sample, n)` — which
each mode uses to `put!` onto `ch` plus its own post-emit policy (extra
pacing, progress reporting) — returning `false` to stop the loop.

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
    n = UInt32(0)
    partial_fit_period = 10
    partial_fit_enabled = use_partial_fit && length(initial_guess) in (3, 5)

    if use_partial_fit && !partial_fit_enabled
        @warn "Partial fit mode is only supported for 1- and 2-lifetime fits (3 or 5 parameters); falling back to full fits."
    end

    # PID setpoint fallback used when no protocol is active.
    fallback_setpoint_ns = 4.0

    # Captured once, not per-iteration: RuntimeContext is mutable and RUNTIME[]
    # always returns the same object, so this stays live if init_irf_runtime!()
    # reloads the IRF mid-run — while letting the compiler specialize the loop
    # body on ctx's concrete field types instead of re-reading an untyped global.
    ctx = RUNTIME[]

    state1 = ChannelFitState(initial_guess)
    state2 = ChannelFitState(initial_guess)
    has_channel2 = false
    channel_count_known = false

    while running[]
        filepath = next_file!(n)
        if filepath === nothing
            break
        end

        vector1, vector2, histogram_resolution, frame_time = read_sdt_frame(filepath)

        # Decided once, from the first file of this run; every later file is
        # assumed to have the same channel count (per acquisition invariant).
        if !channel_count_known
            has_channel2 = vector2 !== nothing
            channel_count_known = true
        end

        timestamps += frame_time

        current_protocol = resolve_protocol_config(protocol)
        protocol_active = current_protocol !== nothing && current_protocol.active
        setpoint_ns = protocol_active ? protocol_setpoint_at_timestamp(current_protocol, timestamps) : fallback_setpoint_ns

        # Distinct from setpoint_ns: PID control keeps regulating toward the
        # fallback setpoint even without an active protocol, but the plotted
        # series/highlight should only reflect a genuine protocol schedule —
        # otherwise the Lifetime plot shows a spurious line and vspan at the
        # fallback value whenever the protocol is off.
        plot_setpoint_ns = protocol_active ? setpoint_ns : NaN

        frame1, command1 = process_channel_frame!(
            state1, vector1, histogram_resolution, n, layout, ctx,
            partial_fit_enabled, partial_fit_period, setpoint_ns, frame_time,
            controller.P1, controller.I1, controller.D1, controller.ch1_inv, controller.ch1_on
        )

        if has_channel2
            frame2, command2 = process_channel_frame!(
                state2, vector2, histogram_resolution, n, layout, ctx,
                partial_fit_enabled, partial_fit_period, setpoint_ns, frame_time,
                controller.P2, controller.I2, controller.D2, controller.ch2_inv, controller.ch2_on
            )
        else
            # No second SDT channel: controller 2's output still tracks
            # channel 1's lifetime error (its own gains applied to channel
            # 1's error dynamics), exactly matching pre-two-channel behavior.
            frame2 = ChannelFrame()
            command2 = pid_command_from_state(state1, setpoint_ns, controller.P2, controller.I2, controller.D2, controller.ch2_inv, controller.ch2_on)
        end

        # UInt32(1), not the literal 1 (Int64): n += 1 would silently
        # promote n to Int64 after the first frame (mixed UInt32/Int64
        # addition promotes to Int64), which broke dispatch to
        # process_channel_frame!'s strictly-typed n::UInt32 parameter —
        # caught by an actual `start_playback` run, not the syntax/type
        # checks above.
        n += UInt32(1)

        if !(isopen(ch) && running[])
            break
        end

        sample = AcquisitionSample(
            frame1, frame2,
            command1, command2, timestamps, plot_setpoint_ns, n, String(filepath)
        )
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
`target_frequency` is a live `Threads.Atomic{Float64}` (typically
`app_run.target_frequency`), re-read every cycle rather than captured once,
so editing the target-frequency textbox (GUI.jl/handlers.jl) re-paces the
schedule immediately, mid-run. See `run_acquisition_loop!` for the shared
fitting/binning/PID body.
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
        target_frequency::Threads.Atomic{Float64} = Threads.Atomic{Float64}(DEFAULT_PLAYBACK_TARGET_FREQUENCY_HZ)
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

        next_analysis_ns = Ref(time_ns())

        next_file! = function (n)
            while running[]
                # Re-read every cycle (not captured once) so a live edit to
                # the target-frequency textbox re-paces the schedule
                # immediately instead of only on the next worker restart.
                target_period_ns = round(Int, 1e9 / max(target_frequency[], 0.01))

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
