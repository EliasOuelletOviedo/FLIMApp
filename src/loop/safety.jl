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
`galvo_limit_v`, commands within 0…`command_max_v`. Throws a
`SafetyError`; allocates nothing when the slot is fine.
"""
function check_slot(buffers::SlotBuffers, cfg::BenchConfig)
    @inbounds for v in buffers.galvos
        (isfinite(v) && abs(v) <= cfg.galvo_limit_v) || throw(SafetyError("galvo sample $v V outside ±$(cfg.galvo_limit_v) V"))
    end
    @inbounds for v in buffers.commands
        (isfinite(v) && 0.0 <= v <= cfg.command_max_v) || throw(SafetyError("command sample $v V outside 0…$(cfg.command_max_v) V"))
    end
    return nothing
end

missed_deadline(e) = e isa DAQmx.DAQmxError && e.code in DAQmx.CODES_ECHEANCE_MANQUEE
read_fell_behind(e) = e isa DAQmx.DAQmxError && e.code in DAQmx.CODES_LECTURE_EN_RETARD

"""
    describe_loop_error(e)::String

One line for the GUI and the journal: a missed deadline (the card ran out
of written samples, plan §7: the sequence is no longer reliable) is named
as such, other errors are shown as they are.
"""
function describe_loop_error(e)::String
    if missed_deadline(e)
        return "missed deadline: the card ran out of written samples (DAQmx $(e.code))"
    elseif read_fell_behind(e)
        return "readback overrun: the loop fell behind the card (DAQmx $(e.code))"
    elseif e isa DAQmx.DAQmxError
        return "DAQmx $(e.code): $(first(split(e.msg, '\n')))"
    else
        return sprint(showerror, e)
    end
end
