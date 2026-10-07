"""
loop/scan_pattern.jl

The slots the DAQ loop plays (DAQ loop thread only). Built once at START
from a `ScanRequest`, then copied into preallocated slot buffers — commands
filled in — before each write, so steady-state iterations don't allocate.

One slot per ROI visit; slot `s` visits position `k = s mod R + 1` of the
visiting order, visit `v = s ÷ R`:

- scan (`scan_time`): the ROI's spiral, gate high, its routing code,
  command outputs at that ROI's latest PI command, sync pulses on its first
  samples;
- shift (`shift_time`): half-cosine move toward the next ROI's center,
  gate low, the reserved routing code, command outputs at 0 V.

The SPC card (QC-104, or the SPC-150N) sees two things from the NI:

- the routing code on P0.4–P0.7, written NOT-ed when `invert_routing`
  (active-low inputs) so the card reads the code itself: during each scan,
  the ROI's drawn index (1–15), or `FLIMCore.CODE_SANS_ROI` without ROIs;
  during the moves of the galvos, the pauses and the entry, the reserved
  code (`FLIMCore.CODE_HORS_ROI`), whose photons are thrown away when the
  stream is decoded — in FIFO mode, what CNTE would do, without a line;
- the pass signal, a counter clocked by the same sample clock (loop/hardware.jl,
  `channels.passes`), high during each scan: its edges on the cards'
  markers M0/M3 delimit each pass in their FIFO.

Every slot thus ends with the lasers off and the gate low. Regeneration is
forbidden (loop/hardware.jl), so a loop that stops writing leaves the card
stopped on that state. Before slot 0, the entry moves the galvos from 0 V
onto the first ROI (`shift_time`, everything off).

Without ROI scanning (ROI mode off, or no ROI drawn) there is one slot per
cycle and the galvos stay at 0 V, but the slot keeps the same rhythm: gate
high for `scan_time`, low for the pause (`shift_time`); the routing lines
carry `FLIMCore.CODE_SANS_ROI` during the scan, the reserved code during
the pause.
"""

# Port-0 lines: bit b of each sample drives line P0.b. Bits 0, 2, 3 and 4–7
# match the NI-PCIe-6321 branch (sequence.jl).
const DO_BIT_GATE     = 0   # high during each ROI's scan (850 nm laser gate)
const DO_BIT_ENABLE   = 1   # high while slots play (the watchdog drops it if the loop dies)
const DO_BIT_SEQUENCE = 2   # pulse at the start of the first ROI's scan, every cycle
const DO_BIT_ROI      = 3   # pulse at the start of every ROI's scan
const DO_ROI_CODE_SHIFT = 4 # bits 4–7: the SPC routing code of the ROI being visited (see above)

do_bit(b) = UInt8(1) << b

"""ROIs the routing code can tell apart: 4 lines, codes 1–15, 0 reserved (FLIMCore.ROI_MAX)."""
const ROI_MAX = FLIMCore.ROI_MAX

"""Port-0 byte of the routing code that makes the card read `code`."""
routing_byte(code::Integer, invert::Bool) = FLIMCore.code_ecrit(code, invert) << DO_ROI_CODE_SHIFT

"""The sync pulse bits of a scan's first samples."""
pulse_bits(first_roi::Bool) = do_bit(DO_BIT_ROI) | (first_roi ? do_bit(DO_BIT_SEQUENCE) : 0x00)

"""
    ScanPattern

Everything needed to produce any slot: per visiting position `k`, the
galvo path (volts) and port-0 bytes of one slot, plus the entry move.
`roi_order[k]` is the drawn index of the ROI at position `k` (0 when the
galvos don't scan). `idle_lines`: the port-0 byte of the entry (the
reserved routing code, everything else off).
"""
struct ScanPattern
    sample_rate_hz::Float64
    idle_lines::UInt8
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
than a sample, if there are more ROIs than routing codes (`ROI_MAX`), if a
scan, pause or entry is too short for the pass counter (2 samples), or if
any galvo sample breaks the limits (`check_galvo_path`, loop/safety.jl) —
nothing is written in that case.
"""
function build_scan_pattern(request::ScanRequest, cfg::BenchConfig)::ScanPattern
    rate = cfg.sample_rate_hz
    n_scan = round(Int, request.scan_time_ms * rate / 1000)
    n_shift = round(Int, request.shift_time_ms * rate / 1000)
    n_scan >= 1 || error("scan time of $(request.scan_time_ms) ms is shorter than one sample at $(rate) Hz")
    n_pulse = clamp(round(Int, cfg.sync_pulse_s * rate), 1, n_scan)
    n = n_scan + n_shift
    scanning = request.roi_active && !isempty(request.rois)
    if !isempty(cfg.pass_counter) && min(n_scan, n_shift) < 2
        throw(SafetyError("scan and shift times must last at least 2 samples ($(2000 / rate) ms) for the pass counter"))
    end
    scan_bits = do_bit(DO_BIT_GATE) | do_bit(DO_BIT_ENABLE)
    off_roi = routing_byte(FLIMCore.CODE_HORS_ROI, request.invert_routing)

    if !scanning
        # Galvos still, same scan/pause rhythm: the no-ROI code during the
        # scan, the reserved code during the pause.
        lines = zeros(UInt8, n, 1)
        lines[1:n_scan, 1] .= routing_byte(FLIMCore.CODE_SANS_ROI, request.invert_routing) | scan_bits
        lines[n_scan+1:n, 1] .= off_roi | do_bit(DO_BIT_ENABLE)
        lines[1:n_pulse, 1] .|= pulse_bits(true)
        return ScanPattern(rate, off_roi, false, [0], n_scan, n_shift, n, zeros(n_shift), zeros(n_shift),
                           zeros(n, 1), zeros(n, 1), lines)
    end

    length(request.rois) <= ROI_MAX ||
        throw(SafetyError("$(length(request.rois)) ROIs: the routing code tells only $ROI_MAX apart (code 0 is reserved)"))
    segments = roi_scan_segments(request)
    R = length(segments)
    x = zeros(n, R)
    y = zeros(n, R)
    lines = zeros(UInt8, n, R)

    for (k, segment) in enumerate(segments)
        code = routing_byte(FLIMCore.code_routage(segment.roi_index), request.invert_routing)

        n_points = length(segment.points)
        for j in 1:n_scan
            point = segment.points[fld((j - 1) * n_points, n_scan) + 1]
            x[j, k] = point[1] / 1000
            y[j, k] = point[2] / 1000
            lines[j, k] = code | scan_bits
        end
        lines[1:n_pulse, k] .|= pulse_bits(k == 1)

        next_center = segments[mod1(k + 1, R)].center
        half_cosine_move!(view(x, n_scan+1:n, k), x[n_scan, k], next_center[1] / 1000)
        half_cosine_move!(view(y, n_scan+1:n, k), y[n_scan, k], next_center[2] / 1000)
        lines[n_scan+1:n, k] .= off_roi | do_bit(DO_BIT_ENABLE)     # the galvos move: reserved code
    end

    first_center = segments[1].center
    entry_x = half_cosine_move!(zeros(n_shift), 0.0, first_center[1] / 1000)
    entry_y = half_cosine_move!(zeros(n_shift), 0.0, first_center[2] / 1000)

    check_galvo_path(vcat(vec(x), entry_x), vcat(vec(y), entry_y), cfg)

    return ScanPattern(rate, off_roi, true, [s.roi_index for s in segments], n_scan, n_shift, n,
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

The move onto the first ROI: the reserved routing code, everything else off.
"""
function entry_buffers(pattern::ScanPattern)::SlotBuffers
    n = entry_samples(pattern)
    buffers = SlotBuffers(n)
    buffers.galvos[1:n] .= pattern.entry_x
    buffers.galvos[n+1:2n] .= pattern.entry_y
    buffers.lines .= pattern.idle_lines
    return buffers
end
