"""
acquisition.jl

The analysis worker of the Realtime and Playback modes, on its own thread
(`Threads.@spawn` at START, see `spawn_acquisition_worker!` in
gui/runtime.jl). It never touches the GUI and never calls a card: it takes
the passes the SPC engine cuts in the cards' photon streams
(`FLIMCore.HistoClamp`, from `engine.histogrammes` — live cards in
Realtime, a recorded session in Playback), fits each one, computes the PI
commands and emits the result into the exchanges (exchange.jl) — the
display ring read by the GUI refresh tick, the PI command atomics read by
the DAQ loop, and the journal. Settings (binning, smoothing, controller
gains, protocol) are read from the atomic snapshot the GUI publishes, never
from `AppState` directly. Protocol schedule math lives in protocol.jl.

One pass per scan of the DAQ loop, delimited by the cards themselves (M0 at
its start, M3 at its end, from a 6321 counter clocked by the AO clock). With
ROIs, each photon carries the routing code the NI held during the scan: the
ROI of a pass comes from the hardware, nothing is inferred from timing.
Binning, the Kalman observer and the PI are per ROI and per channel
(`ChannelFitState`): pooling ROIs would average different cells, and the DAQ
loop writes each ROI's own commands during its scan.
"""

using Base.Threads

# =============================================================================
# OUTPUT: emission into the exchanges
# =============================================================================

"""
    AnalysisOutput(exchange; roi_order=Int[], drive_outputs=true)

Where the analysis worker sends each analyzed pass: `roi_order` holds this
run's ROIs (drawn indices, in visiting order — `roi_visit_order`,
roi_geometry.jl), empty without ROIs. `drive_outputs`: write each ROI's PI
commands for the DAQ loop — never in Playback, where they are only
simulated (the recorded stimulation doesn't change). Nothing is kept here:
the journal writes every pass to the session as it comes.
`excluded_passes`: passes kept out of the PI (shown);
`unmatched_passes`: passes whose routing code is none of this run's ROIs
(or that hold no photon under a ROI code), not analyzed.
"""
mutable struct AnalysisOutput
    exchange::Exchange
    roi_order::Vector{Int}
    drive_outputs::Bool
    excluded_passes::Int
    unmatched_passes::Int
end

AnalysisOutput(exchange::Exchange; roi_order::Vector{Int} = Int[], drive_outputs::Bool = true) =
    AnalysisOutput(exchange, copy(roi_order), drive_outputs, 0, 0)

"""
    pass_roi(h, roi_order) -> (roi_index, code)

Which ROI a pass scanned, from the routing code the cards read. Without
ROIs (`roi_order` empty): ROI 1, `code == -1` (every photon of the pass,
whatever its code). With ROIs: the code 1–$(FLIMCore.ROI_MAX) holding the
most photons over all cards — a ROI's code is its drawn index
(`FLIMCore.code_routage`) —, and `roi_index == 0` when that code isn't one
of `roi_order` or no photon carries a ROI code (`FLIMCore.CODE_HORS_ROI`
is what the cards read between scans and on undriven lines).
"""
function pass_roi(h::FLIMCore.HistoClamp, roi_order::Vector{Int})::Tuple{Int, Int}
    isempty(roi_order) && return (1, -1)
    best, best_count = 0, 0
    for code in 1:FLIMCore.ROI_MAX
        count = 0
        for m in h.histogrammes
            count += sum(Int, view(m, :, code + 1))
        end
        count > best_count && ((best, best_count) = (code, count))
    end
    best == 0 && return (0, 0)
    return (best in roi_order ? best : 0, best)
end

"""
    pass_histogram(m, code)

One card's decay for a pass: the column of routing code `code`, or every
column summed (`code == -1`, no ROIs).
"""
pass_histogram(m::AbstractMatrix{<:Integer}, code::Int) =
    code < 0 ? vec(sum(Int, m; dims = 2)) : view(m, :, code + 1)

"""
    analysis_histogram(counts)::Vector{Float64}

One card's histogram at the analysis resolution (`DEFAULT_HISTOGRAM_RESOLUTION`,
the IRF's): summed down when the cards measure finer (`[clamp] canaux`
above 256), unchanged otherwise.
"""
function analysis_histogram(counts::AbstractVector{<:Integer})::Vector{Float64}
    n, resolution = length(counts), DEFAULT_HISTOGRAM_RESOLUTION
    (n > resolution && n % resolution == 0) || return Float64.(counts)
    group = n ÷ resolution
    return [Float64(sum(Int, @view counts[(k - 1) * group + 1:k * group])) for k in 1:resolution]
end

"""
    emit_frame!(out, sample, roi_index)

Publish one analyzed pass: to the display ring (GUI), the PI command
atomics of its ROI (the DAQ loop writes them during that ROI's scans; not
in Playback, `out.drive_outputs`), and the journal (frames.csv of the
session). Never blocks.
"""
function emit_frame!(out::AnalysisOutput, sample::AcquisitionSample, roi_index::Int)
    record = FrameRecord(sample, roi_index)
    publish!(out.exchange.frames, record)
    out.drive_outputs && set_command_values!(out.exchange, roi_index, sample.command1, sample.command2)
    send_journal!(out.exchange.journal, JournalFrame(record))
    return nothing
end

# =============================================================================
# PER-CHANNEL FIT AND PI
# =============================================================================

"""
    ChannelFitState

One (ROI, channel)'s accumulator state for the analysis worker: sliding-
window binning buffer over that ROI's passes, current MLE fit parameters,
Kalman observer and PI error accumulators. Not persisted/Observable like
`AppState`/`AppRun` — purely worker-internal state, one instance per ROI
and channel (`start_realtime`). `frames` counts the passes it has taken,
`last_time` is the end of the latest one (card time, s; NaN before the
first), which dates the Kalman and PI steps.
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
    pid_kalman::KalmanState
    frames::Int
    last_time::Float64
end

function ChannelFitState(initial_guess::Vector{Float64})
    return ChannelFitState(
        zeros(100, DEFAULT_HISTOGRAM_RESOLUTION), 100,
        zeros(Float64, DEFAULT_HISTOGRAM_RESOLUTION), 1, 0,
        copy(initial_guess), copy(initial_guess), true,
        0.0, 0.0, KalmanState(), 0, NaN
    )
end

"""
    pid_command_from_state(state, setpoint_ns, P, I, inv, on)::Float64

Apply one controller's P/I gains to `state`'s current error terms (`state.
old_error` holds the latest P_error, `state.I_error` the integral term —
both just set by `process_frame!`). No `D` term: the derivative
was dropped in favor of `state.pid_kalman` (a Kalman observer) filtering
the lifetime that `P_error` is computed from — see
`process_frame!`'s docstring. Split out from `process_frame!`
so a single-card acquisition (no second SPC-150N in `[verification]
series`) can still drive controller 2's output from channel 1's error
dynamics with controller 2's own gains — this is exactly the original single-channel
behavior (`command1`/`command2` were always two gain-weighted views of one
shared error before channel 2 existed).
"""
function pid_command_from_state(state::ChannelFitState, setpoint_ns::Float64, P::Float64, I::Float64, inv::Bool, on::Bool)::Float64
    if isnan(setpoint_ns)
        return NaN
    end

    command = P*state.old_error + I*state.I_error
    if inv
        command = -command
    end

    return on ? clamp(command, 0.0, 100.0) : NaN
end

"""
    process_frame!(state, vector, histogram_resolution, layout, ctx,
                   partial_fit_enabled, partial_fit_period,
                   setpoint_ns, frame_time, P, I, inv, on; control=true)
        -> (ChannelFrame, command)

One (ROI, channel)'s work for one pass: sliding-window histogram binning
over that ROI's passes, MLE lifetime fit (full or partial), and PI command
computation — mutating `state` in place. The worker calls this once per
channel per pass with that ROI and channel's own `ChannelFitState` and
controller sub-config (P1/I1/ch1_inv/ch1_on vs P2/I2/ch2_inv/ch2_on), inside
`with_fit_context` of that channel's IRF. `frame_time`: seconds since this
ROI's previous pass.

The raw per-frame MLE-fit lifetime is filtered through `state.pid_kalman`
(a constant-velocity Kalman observer, `kalman_update!`/smoothing.jl) before
`P_error`/`I_error` are computed from it — this is what let the controller
drop its `D` term (PID -> PI): a raw discrete derivative amplifies fit
noise badly, while the observer's own velocity state tracks the lifetime's
trend directly from a model of its dynamics instead of differentiating a
noisy signal.

`control = false` (a pass kept out of the PI, see `start_realtime`): the pass is fit and shown but
kept out of the observer and the PI — the command stays the previous one
and `lifetime_kalman` is `NaN`.
"""
function process_frame!(
        state::ChannelFitState,
        vector::AbstractVector{<:Real},
        histogram_resolution::Int,
        layout::LayoutSettings,
        ctx,
        partial_fit_enabled::Bool,
        partial_fit_period::Int,
        setpoint_ns::Float64,
        frame_time::Float64,
        P::Float64, I::Float64,
        inv::Bool, on::Bool;
        control::Bool = true
    )
    # Store in circular buffer
    pos = mod1(state.frames + 1, state.n_vectors)
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

    # Fit every processed frame.
    fit_index = state.frames + 1
    state.frames += 1
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

    lifetime_for_pid = NaN
    if control
        smooth_level = lifetime_smooth_level(layout)
        dt_sample = max(frame_time, eps(Float64))
        lifetime_for_pid = kalman_update!(state.pid_kalman, lifetime, dt_sample, smooth_level)

        if !isnan(setpoint_ns)
            P_error = setpoint_ns - lifetime_for_pid
            state.I_error += P_error * dt_sample
            state.old_error = P_error
        else
            state.I_error = 0.0
            state.old_error = 0.0
        end
    end

    command = pid_command_from_state(state, setpoint_ns, P, I, inv, on)

    return ChannelFrame(histogram, fit, photons, lifetime, concentration, lifetime_for_pid), command
end

# =============================================================================
# REALTIME AND PLAYBACK
# =============================================================================

"""
    start_realtime(out, running, histograms; initial_guess, paused, source_done, poll_s=0.002)

Worker task for the Realtime and Playback modes: until `running` drops,
takes each pass the SPC engine publishes in `histograms`
(`engine.histogrammes`), finds its ROI from the routing code (`pass_roi`),
and fits channel 1 (the card `[verification] series` lists first) and, if
there is a second card, channel 2 — each against its own IRF
(`channel_fit_context`) with that ROI and channel's own binning, observer
and PI (`process_frame!`) —, then emits the pass (`emit_frame!`). A pass
the engine marks (`HistoClamp.motifs`: a record with the loss flag,
SPC_FOVFL during the pass, M3 − M0 off the programmed duration) is shown
but kept out of the PI. A mid-run edit of binning, smoothing, gains or protocol applies
from the next pass on (`current_settings`). Passes arriving while paused
are dropped. Times count from the start of the first pass. Ends when
`running` drops or, in Playback, once `source_done` is raised (the replay
is over) and every pass is taken. Returns `out`.
"""
function start_realtime(
        out::AnalysisOutput,
        running::Threads.Atomic{Bool},
        histograms::Channel{FLIMCore.HistoClamp};
        initial_guess::Vector{Float64} = [3.0, 0.5, 0.5, 0.0, 5.0e-5],
        paused::Union{Nothing, Threads.Atomic{Bool}} = nothing,
        source_done::Union{Nothing, Threads.Atomic{Bool}} = nothing,
        poll_s::Float64 = 0.002
    )
    try
        @info "Real-time worker started on thread $(threadid())"

        if RUNTIME[].irf === nothing || RUNTIME[].tcspc_window_size === nothing
            @error "IRF not loaded - cannot start data processing. Please load an IRF file first."
            return nothing
        end

        ensure_fit_warm!()

        # PID setpoint fallback used when no protocol is active.
        fallback_setpoint_ns = 4.0
        partial_fit_period = 10

        states = Dict{Tuple{Int, Int}, ChannelFitState}()
        state_for(roi, channel) = get!(() -> ChannelFitState(initial_guess), states, (roi, channel))
        n = UInt32(0)
        t0 = NaN

        while running[]
            if !isready(histograms)
                # Playback: the replay is over and every pass is taken.
                source_done !== nothing && source_done[] && !isready(histograms) && break
                sleep(poll_s)
                continue
            end
            h = take!(histograms)
            (paused !== nothing && paused[]) && continue
            isnan(t0) && (t0 = h.t_debut_s)

            roi, code = pass_roi(h, out.roi_order)
            if roi == 0
                out.unmatched_passes += 1
                continue
            end
            complete = isempty(h.motifs)
            complete || (out.excluded_passes += 1)
            timestamp = h.t_fin_s - t0

            settings = current_settings(out.exchange)
            layout = settings.layout
            controller = settings.controller
            current_protocol = settings.protocol
            protocol_active = current_protocol.active
            setpoint_ns = protocol_active ? protocol_setpoint_at(current_protocol, timestamp) : fallback_setpoint_ns

            # Distinct from setpoint_ns: PID control keeps regulating toward the
            # fallback setpoint even without an active protocol, but the plotted
            # series/highlight should only reflect a genuine protocol schedule.
            plot_setpoint_ns = protocol_active ? setpoint_ns : NaN

            frames = (ChannelFrame(), ChannelFrame())
            commands = (NaN, NaN)
            channels = min(length(h.histogrammes), 2)
            for c in 1:channels
                vector = analysis_histogram(pass_histogram(h.histogrammes[c], code))
                state = state_for(roi, c)
                frame_time = isnan(state.last_time) ? h.t_fin_s - h.t_debut_s : h.t_fin_s - state.last_time
                state.last_time = h.t_fin_s
                gains = c == 1 ? (controller.P1, controller.I1, controller.ch1_inv, controller.ch1_on) :
                                 (controller.P2, controller.I2, controller.ch2_inv, controller.ch2_on)
                ctx = channel_fit_context(c)
                frame, command = with_fit_context(ctx) do
                    process_frame!(state, vector, length(vector), layout, ctx,
                                   false, partial_fit_period, setpoint_ns, frame_time, gains...;
                                   control = complete)
                end
                frames = Base.setindex(frames, frame, c)
                commands = Base.setindex(commands, command, c)
            end
            if channels == 1
                # A single card: controller 2's output still tracks channel
                # 1's lifetime error (its own gains applied to channel 1's
                # error dynamics), exactly matching pre-two-channel behavior.
                commands = (commands[1], pid_command_from_state(state_for(roi, 1), setpoint_ns, controller.P2,
                                                                controller.I2, controller.ch2_inv, controller.ch2_on))
            end

            n += UInt32(1)
            running[] || break

            sample = AcquisitionSample(frames[1], frames[2], commands[1], commands[2], timestamp, plot_setpoint_ns,
                                       n, h.passe, h.t_debut_s, h.t_fin_s, complete, join(h.motifs, "; "), time())
            emit_frame!(out, sample, roi)
        end
    catch e
        @error "Real-time worker error" exception=e
        rethrow()
    finally
        running[] = false
        out.drive_outputs && set_command_values!(out.exchange, NaN, NaN)
        out.excluded_passes > 0 &&
            @warn "Some passes were kept out of the PI (lost records, FIFO overflow or wrong length): shown only" passes=out.excluded_passes
        out.unmatched_passes > 0 &&
            @warn "Some passes carried a routing code that is none of this run's ROIs: not analyzed" passes=out.unmatched_passes
        @info "Real-time worker finished"
    end

    return out
end
