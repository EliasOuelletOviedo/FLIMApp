"""
protocol.jl

Experimental protocol schedule math: converting the protocol UI's
times/setpoints into a lookup usable during acquisition, and normalizing
protocol config read from AppState/Observables.
"""

using Observables

function protocol_steps(protocol::ProtocolSettings)::Vector{Tuple{Float64, Float64}}
    times = protocol.times
    setpoints = protocol.setpoints
    nsteps = min(length(times), length(setpoints))
    steps = Tuple{Float64, Float64}[]

    for idx in 1:nsteps
        duration = times[idx]
        setpoint = setpoints[idx]

        if !isfinite(duration) || duration <= 0.0
            continue
        end

        push!(steps, (duration, setpoint))
    end

    return steps
end

function protocol_setpoint_at_timestamp(protocol::ProtocolSettings, timestamp::Real)::Float64
    t = Float64(timestamp)
    if !isfinite(t)
        return NaN
    end

    delay_s = max(protocol.delay, 0)
    repeats = max(protocol.repeats, 0)
    steps = protocol_steps(protocol)

    if isempty(steps)
        return NaN
    end

    t_after_delay = t - delay_s
    if t_after_delay < 0.0
        return NaN
    end

    cycle_duration = sum(step -> step[1], steps)
    if cycle_duration <= 0.0
        return NaN
    end

    if repeats > 0
        total_duration = repeats * cycle_duration
        if t_after_delay >= total_duration
            return NaN
        end
    end

    cycle_t = mod(t_after_delay, cycle_duration)
    elapsed = 0.0

    for (duration, setpoint) in steps
        elapsed += duration
        if cycle_t < elapsed
            return setpoint
        end
    end

    return steps[end][2]
end

@inline function resolve_protocol_config(protocol)
    if protocol === nothing
        return nothing
    end

    candidate = if protocol isa Observables.AbstractObservable
        protocol[]
    else
        protocol
    end

    return candidate isa ProtocolSettings ? candidate : nothing
end

function normalize_protocol_config(raw_protocol::ProtocolSettings)::ProtocolSettings
    return ProtocolSettings(
        active = raw_protocol.active,
        repeats = max(raw_protocol.repeats, 0),
        delay = max(raw_protocol.delay, 0),
        times = copy(raw_protocol.times),
        setpoints = copy(raw_protocol.setpoints)
    )
end

function sync_runtime_protocol!(app, app_run)
    app_run.protocol[] = normalize_protocol_config(app.protocol)
    return nothing
end
