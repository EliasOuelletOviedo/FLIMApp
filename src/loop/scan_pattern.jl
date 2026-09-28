"""
loop/scan_pattern.jl

The slots the DAQ loop plays (DAQ loop thread only). Built once at START
from a `ScanRequest`, then copied into preallocated slot buffers — commands
filled in — before each write, so steady-state iterations don't allocate.

One slot per ROI visit; slot `s` visits position `k = s mod R + 1` of the
visiting order, visit `v = s ÷ R`:

- scan (`scan_time`): the ROI's spiral, gate high, command outputs at the
  latest PI command, sync pulses on its first samples;
- shift (`shift_time`): half-cosine move toward the next ROI's center,
  gate low, command outputs at 0 V.

Every slot thus ends with the lasers off and the gate low. Regeneration is
forbidden (loop/hardware.jl), so a loop that stops writing leaves the card
stopped on that state. Before slot 0, the entry moves the galvos from 0 V
onto the first ROI (`shift_time`, everything off).

Without ROI scanning (ROI mode off, or no ROI drawn) there is one slot per
cycle, galvos at 0 V and port 0 low: only the command outputs play.
"""

# Port-0 lines: bit b of each sample drives line P0.b. Bits 0, 2, 3 and 4–7
# match the NI-PCIe-6321 branch (sequence.jl).
const DO_BIT_GATE     = 0   # high during each ROI's scan
const DO_BIT_ENABLE   = 1   # high while slots play (the watchdog drops it if the loop dies)
const DO_BIT_SEQUENCE = 2   # pulse at the start of the first ROI's scan, every cycle
const DO_BIT_ROI      = 3   # pulse at the start of every ROI's scan
const DO_ROI_CODE_SHIFT = 4 # bits 4–7: drawn index − 1 of the ROI being visited (mod 16)

do_bit(b) = UInt8(1) << b

"""
    ScanPattern

Everything needed to produce any slot: per visiting position `k`, the
galvo path (volts) and port-0 bytes of one slot, plus the entry move.
`roi_order[k]` is the drawn index of the ROI at position `k` (0 when the
galvos don't scan).
"""
struct ScanPattern
    sample_rate_hz::Float64
    scanning::Bool
    roi_order::Vector{Int}
    scan_samples::Int
    shift_samples::Int
    slot_samples::Int
    entry_x::Vector{Float64}
    entry_y::Vector{Float64}
    x::Matrix{Float64}
    y::Matrix{Float64}
    lines::Matrix{UInt8}
end

slots_per_cycle(p::ScanPattern) = size(p.x, 2)
slot_position(p::ScanPattern, s::Integer) = mod(s, slots_per_cycle(p)) + 1
slot_roi(p::ScanPattern, s::Integer) = p.roi_order[slot_position(p, s)]
slot_visit(p::ScanPattern, s::Integer) = s ÷ slots_per_cycle(p)
entry_samples(p::ScanPattern) = length(p.entry_x)
slot_duration_s(p::ScanPattern) = p.slot_samples / p.sample_rate_hz

"""Half-cosine move from `a` to `b` filling `out`: zero speed at both ends (sequence.jl's `deplacement`)."""
function half_cosine_move!(out::AbstractVector{Float64}, a::Real, b::Real)
    n = length(out)
    for i in 1:n
        s = n == 1 ? 1.0 : (1 - cos(π * (i - 1) / (n - 1))) / 2
        out[i] = a + (b - a) * s
    end
    return out
end

"""
    build_scan_pattern(request, cfg)::ScanPattern

Sample the slots of `request` at `cfg.sample_rate_hz`. Each spiral point is
held for an equal share of the scan. Throws if the scan time is shorter
than a sample or if any galvo sample breaks the limits (`check_galvo_path`,
loop/safety.jl) — nothing is written in that case.
"""
function build_scan_pattern(request::ScanRequest, cfg::BenchConfig)::ScanPattern
    rate = cfg.sample_rate_hz
    n_scan = round(Int, request.scan_time_ms * rate / 1000)
    n_shift = round(Int, request.shift_time_ms * rate / 1000)
    n_scan >= 1 || error("scan time of $(request.scan_time_ms) ms is shorter than one sample at $(rate) Hz")
    n_pulse = clamp(round(Int, cfg.sync_pulse_s * rate), 1, n_scan)
    n = n_scan + n_shift
    scanning = request.roi_active && !isempty(request.rois)

    if !scanning
        return ScanPattern(rate, false, [0], n_scan, n_shift, n, zeros(n_shift), zeros(n_shift),
                           zeros(n, 1), zeros(n, 1), zeros(UInt8, n, 1))
    end

    segments = roi_scan_segments(request)
    R = length(segments)
    x = zeros(n, R)
    y = zeros(n, R)
    lines = zeros(UInt8, n, R)

    for (k, segment) in enumerate(segments)
        code = (UInt8((segment.roi_index - 1) & 0x0f) << DO_ROI_CODE_SHIFT) | do_bit(DO_BIT_ENABLE)

        n_points = length(segment.points)
        for j in 1:n_scan
            point = segment.points[fld((j - 1) * n_points, n_scan) + 1]
            x[j, k] = point[1] / 1000
            y[j, k] = point[2] / 1000
            lines[j, k] = code | do_bit(DO_BIT_GATE)
        end
        lines[1:n_pulse, k] .|= do_bit(DO_BIT_ROI)
        k == 1 && (lines[1:n_pulse, k] .|= do_bit(DO_BIT_SEQUENCE))

        next_center = segments[mod1(k + 1, R)].center
        half_cosine_move!(view(x, n_scan+1:n, k), x[n_scan, k], next_center[1] / 1000)
        half_cosine_move!(view(y, n_scan+1:n, k), y[n_scan, k], next_center[2] / 1000)
        lines[n_scan+1:n, k] .= code
    end

    first_center = segments[1].center
    entry_x = half_cosine_move!(zeros(n_shift), 0.0, first_center[1] / 1000)
    entry_y = half_cosine_move!(zeros(n_shift), 0.0, first_center[2] / 1000)

    check_galvo_path(vcat(vec(x), entry_x), vcat(vec(y), entry_y), cfg)

    return ScanPattern(rate, true, [s.roi_index for s in segments], n_scan, n_shift, n,
                       entry_x, entry_y, x, y, lines)
end

"""
    SlotBuffers(n)

One slot's worth of output, laid out the way the NI writes expect it
(channel by channel): `galvos` is X then Y, `commands` is command 1 then
command 2, `lines` one byte per sample. Allocated once per run.
"""
struct SlotBuffers
    galvos::Vector{Float64}
    lines::Vector{UInt8}
    commands::Vector{Float64}
end

SlotBuffers(n::Integer) = SlotBuffers(zeros(2n), zeros(UInt8, n), zeros(2n))
buffer_samples(b::SlotBuffers) = length(b.lines)

"""
    prepare_slot!(buffers, pattern, s, command1_v, command2_v)

Fill `buffers` with slot `s`: its ROI's galvo path and lines, the two
command voltages during the scan and 0 V during the shift. No allocation.
"""
function prepare_slot!(buffers::SlotBuffers, pattern::ScanPattern, s::Integer, command1_v::Float64, command2_v::Float64)
    n = pattern.slot_samples
    offset = (slot_position(pattern, s) - 1) * n
    copyto!(buffers.galvos, 1, pattern.x, offset + 1, n)
    copyto!(buffers.galvos, n + 1, pattern.y, offset + 1, n)
    copyto!(buffers.lines, 1, pattern.lines, offset + 1, n)

    n_scan = pattern.scan_samples
    commands = buffers.commands
    @inbounds for j in 1:n
        on = j <= n_scan
        commands[j] = on ? command1_v : 0.0
        commands[n + j] = on ? command2_v : 0.0
    end
    return buffers
end

"""
    entry_buffers(pattern)::SlotBuffers

The move onto the first ROI, everything else off.
"""
function entry_buffers(pattern::ScanPattern)::SlotBuffers
    n = entry_samples(pattern)
    buffers = SlotBuffers(n)
    buffers.galvos[1:n] .= pattern.entry_x
    buffers.galvos[n+1:2n] .= pattern.entry_y
    return buffers
end
