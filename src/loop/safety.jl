"""
loop/safety.jl

Software safety layer of the DAQ loop (plan §7, first layer): command
clamping, the check every slot goes through before it is written
(`check_slot`, the branch's `verifier_bloc`), and the classification of
DAQmx errors into "missed deadline" / "fell behind" faults. The other
layers live with the hardware (loop/hardware.jl): channel ranges declared
to NI-DAQmx, slots ending off, zeroing in `finally`, the watchdog and the
shutter.
"""

"""A slot or pattern refused before reaching the card."""
struct SafetyError <: Exception
    message::String
end

Base.showerror(io::IO, e::SafetyError) = print(io, "refused: ", e.message)

"""
    command_volts(command, cfg)::Float64

Output voltage for a PI command in percent: clamped to 0–100 %, scaled to
`cfg.command_full_scale_v`, never above the declared `cfg.command_max_v`;
a non-finite command (controller off, no setpoint) gives 0 V.
"""
function command_volts(command::Real, cfg::BenchConfig)::Float64
    isfinite(command) || return 0.0
    volts = clamp(Float64(command), 0.0, 100.0) / 100.0 * cfg.command_full_scale_v
    return min(volts, cfg.command_max_v)
end

"""
    check_galvo_path(x, y, cfg)

Throw a `SafetyError` unless every galvo sample is finite and within
`cfg.galvo_limit_v`.
"""
function check_galvo_path(x::AbstractVector{<:Real}, y::AbstractVector{<:Real}, cfg::BenchConfig)
    for (name, v) in (("galvo X", x), ("galvo Y", y))
        isempty(v) && continue
        all(isfinite, v) || throw(SafetyError("$name: non-finite value"))
        peak = maximum(abs, v)
        peak <= cfg.galvo_limit_v ||
            throw(SafetyError("$name: $(round(peak, digits=3)) V exceeds the $(cfg.galvo_limit_v) V limit"))
    end
    return nothing
end

"""
    check_slot(buffers, cfg)

Last check before a slot is written: finite values, galvos within
`galvo_limit_v`, command 1 within 0…`command_max_v`, AO 1 within
0…`gate_1064_v` when it is the 1064 nm gate (0…`command_max_v` when it is
PI command 2). Throws a `SafetyError`; allocates nothing when the slot is
fine.
"""
function check_slot(buffers::SlotBuffers, cfg::BenchConfig)
    @inbounds for v in buffers.galvos
        (isfinite(v) && abs(v) <= cfg.galvo_limit_v) || throw(SafetyError("galvo sample $v V outside ±$(cfg.galvo_limit_v) V"))
    end
    n = length(buffers.commands) ÷ 2
    @inbounds for (j, v) in enumerate(buffers.commands)
        limit = j > n && cfg.gate_1064_v > 0 ? cfg.gate_1064_v : cfg.command_max_v
        (isfinite(v) && 0.0 <= v <= limit) ||
            throw(SafetyError("$(j > n ? (cfg.gate_1064_v > 0 ? "1064 nm gate" : "command 2") : "command 1") sample $v V outside 0…$limit V"))
    end
    return nothing
end

missed_deadline(e) = (e = root_cause(e); e isa DAQmx.DAQmxError && e.code in DAQmx.CODES_ECHEANCE_MANQUEE)
read_fell_behind(e) = (e = root_cause(e); e isa DAQmx.DAQmxError && e.code in DAQmx.CODES_LECTURE_EN_RETARD)
"""No trigger line between the NI cards: the sample clock can't reach the 6110 (RTSI cable)."""
rtsi_route_missing(e) = (e = root_cause(e); e isa DAQmx.DAQmxError && e.code in DAQmx.CODES_ROUTE_RTSI)

"""
    describe_loop_error(e)::String

One line for the GUI and the journal: the steps that were running
(`with_context`, outermost first), then the cause — a missed deadline (the
card ran out of written samples, plan §7: the sequence is no longer
reliable) named as such, a DAQmx error with its code and first line (the
debug log has the whole extended message: task, channel, property), other
errors as they are.
"""
function describe_loop_error(e)::String
    cause = root_cause(e)
    text = if missed_deadline(cause)
        "missed deadline: the card ran out of written samples (DAQmx $(cause.code))"
    elseif read_fell_behind(cause)
        "readback overrun: the loop fell behind the card (DAQmx $(cause.code))"
    elseif cause isa DAQmx.DAQmxError
        "DAQmx $(cause.code): $(first(split(cause.msg, '\n')))"
    else
        first(split(sprint(showerror, cause), '\n'))
    end
    contexts = error_contexts(e)
    return isempty(contexts) ? text : join(contexts, ": ") * ": " * text
end

"""
    loop_problem_id(e, phase)::String

The problem code of a DAQ loop error (`phase`: `:connect` or `:scan`):
refused by the safety checks (DAQ-07), a missed deadline (DAQ-05), the
readback behind (DAQ-06), a device missing (DAQ-01), the pass counter
(DAQ-04), a reset or zeroing (DAQ-02), a task being created (DAQ-03), or
else a connection failure (DAQ-09) or a fault during the scan (DAQ-08).
"""
function loop_problem_id(e, phase::Symbol)::String
    cause = root_cause(e)
    contexts = join(error_contexts(e), " | ")
    cause isa SafetyError && return "DAQ-07"
    missed_deadline(cause) && return "DAQ-05"
    read_fell_behind(cause) && return "DAQ-06"
    rtsi_route_missing(cause) && return "DAQ-10"
    occursin("NI device(s) not found", sprint(showerror, cause)) && return "DAQ-01"
    occursin("pass counter", contexts) && return "DAQ-04"
    (occursin("resetting", contexts) || occursin("zeroing", contexts)) && return "DAQ-02"
    occursin("creating", contexts) && return "DAQ-03"
    return phase == :connect ? "DAQ-09" : "DAQ-08"
end
