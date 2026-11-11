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

A `shift_time` of 0 (no pause) still leaves `PASS_GAP_SAMPLES` between two
scans (`pause_samples`): the pass signal's shortest low, which delimits the
passes. Without ROI scanning the lasers stay on through it — gate high,
commands and PWM running — under the reserved code (its photons thrown
away): the light never stops. With ROIs it is the galvos' jump to the next
ROI, lasers off as in any shift.

The 1064 nm commands (AO 0, and the gate on AO 1) follow the gate P0.0:
at their value wherever it is high, 0 V elsewhere (`prepare_slot!`).

The ROI popup's galvo scan (`RasterRequest`) is one frame, one slot per
line: the line's ramp (gate and pass signal high, `CODE_SANS_ROI`), then
the flyback to the next line's start (gate low, the reserved code) — after
the last line, back to 0 V. It plays once (`total_slots`): the loop ends by
itself after the last line.

The opto laser's PWM (`ScanRequest.pwm_hz`, the Protocol panel's), for the
whole run: within the scans (the whole slot in images), each period of
`pwm_period` samples starts with `pwm_on` samples of opto — the 1064 nm
power (AO 0) and gate (AO 1) at the slot's command, the reserved routing
code so that their photons are thrown away — and the rest is the
acquisition, the 1064 nm off. The 850 nm gate (P0.0) doesn't change. The
periods run on from one slot to the next (counted from the run's first
sample), so the PWM is regular whatever the slot length.
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
    image_mode::Bool
    raster::Bool
    pwm_period::Int        # samples per period of the opto laser's PWM; 0: no PWM
    pwm_on::Int            # its opto phase, at the start of each period
end

ScanPattern(rate, idle, scanning, order, n_scan, n_shift, n, entry_x, entry_y, x, y, lines, image_mode = false, raster = false) =
    ScanPattern(rate, idle, scanning, order, n_scan, n_shift, n, entry_x, entry_y, x, y, lines, image_mode, raster, 0, 0)

slots_per_cycle(p::ScanPattern) = size(p.x, 2)
slot_position(p::ScanPattern, s::Integer) = mod(s, slots_per_cycle(p)) + 1
slot_roi(p::ScanPattern, s::Integer) = p.roi_order[slot_position(p, s)]
slot_visit(p::ScanPattern, s::Integer) = s ÷ slots_per_cycle(p)
entry_samples(p::ScanPattern) = length(p.entry_x)
slot_duration_s(p::ScanPattern) = p.slot_samples / p.sample_rate_hz
"""Slots the scan plays before ending by itself: one frame for the galvo scan, unlimited (`typemax`) otherwise."""
total_slots(p::ScanPattern) = p.raster ? slots_per_cycle(p) : typemax(Int)

"""
    pwm_samples(hz, duty, rate) -> (period, on)

The opto laser's PWM in samples of the DAQ loop at `rate`: a period of
`round(rate / hz)` samples, its first `on` (`duty` of it, rounded, one
sample of each phase at least) the opto phase; `(0, 0)` without PWM
(`hz` ≤ 0). The NI switches once per sample: a SafetyError above `rate / 2`.
"""
function pwm_samples(hz::Real, duty::Real, rate::Real)
    hz > 0 || return (0, 0)
    hz <= rate / 2 ||
        throw(SafetyError("PWM of $hz Hz: at most $(rate / 2) Hz at $(rate) Hz sampling (one sample of opto, one of acquisition)"))
    period = round(Int, rate / hz)
    return (period, clamp(round(Int, duty * period), 1, period - 1))
end

"""The pass signal's shortest low between two passes (an NI counter phase lasts 2 ticks at least): a shift of 0."""
const PASS_GAP_SAMPLES = 2

"""
    pause_samples(shift_time_ms, rate)::Int

Samples of the pause after each scan: `shift_time_ms` at `rate`; 0 ms (no
pause) gives `PASS_GAP_SAMPLES`, the gap the pass signal needs to delimit
two passes. The DAQ loop, the SPC engine (`pause_s`) and run.toml use it.
"""
pause_samples(shift_time_ms::Real, rate::Real)::Int =
    shift_time_ms == 0 ? PASS_GAP_SAMPLES : round(Int, shift_time_ms * rate / 1000)

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
    n_shift = pause_samples(request.shift_time_ms, rate)
    n_scan >= 1 || error("scan time of $(request.scan_time_ms) ms is shorter than one sample at $(rate) Hz")
    n_pulse = clamp(round(Int, cfg.sync_pulse_s * rate), 1, n_scan)
    n = n_scan + n_shift
    scanning = request.roi_active && !isempty(request.rois)
    if !isempty(cfg.pass_counter) && min(n_scan, n_shift) < 2
        throw(SafetyError("scan time, and a shift other than 0, must last at least 2 samples ($(2000 / rate) ms) for the pass counter"))
    end
    scan_bits = do_bit(DO_BIT_GATE) | do_bit(DO_BIT_ENABLE)
    off_roi = routing_byte(FLIMCore.CODE_HORS_ROI, request.invert_routing)
    pwm_period, pwm_on = pwm_samples(request.pwm_hz, request.pwm_duty, rate)

    if request.image_mode
        # The Realtime in images: the microscope's scanner images; the galvos
        # stay at 0 V and the gate (and enable) high the whole slot — no
        # pause; the slots only pace the commands (the protocol's voltages).
        lines = fill(routing_byte(FLIMCore.CODE_SANS_ROI, request.invert_routing) | scan_bits, n, 1)
        lines[1:n_pulse, 1] .|= pulse_bits(true)
        return ScanPattern(rate, off_roi, false, [0], n_scan, n_shift, n, zeros(n_shift), zeros(n_shift),
                           zeros(n, 1), zeros(n, 1), lines, true, false, pwm_period, pwm_on)
    end

    if !scanning
        # Galvos still, same scan/pause rhythm: the no-ROI code during the
        # scan, the reserved code during the pause.
        lines = zeros(UInt8, n, 1)
        lines[1:n_scan, 1] .= routing_byte(FLIMCore.CODE_SANS_ROI, request.invert_routing) | scan_bits
        # No pause (shift 0): the lasers stay on through the pass signal's gap, its photons thrown away.
        lines[n_scan+1:n, 1] .= off_roi | (request.shift_time_ms == 0 ? scan_bits : do_bit(DO_BIT_ENABLE))
        lines[1:n_pulse, 1] .|= pulse_bits(true)
        return ScanPattern(rate, off_roi, false, [0], n_scan, n_shift, n, zeros(n_shift), zeros(n_shift),
                           zeros(n, 1), zeros(n, 1), lines, false, false, pwm_period, pwm_on)
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
                       entry_x, entry_y, x, y, lines, false, false, pwm_period, pwm_on)
end

"""Share of each galvo-scan line spent on the flyback to the next line's start (half-cosine move)."""
const RASTER_FLYBACK_FRACTION = 0.15

"""
    raster_timing(request, rate) -> (n_scan, n_shift)

Samples of each galvo-scan line at `rate`: the line period that fits the
frame in `request.duration_s`, `RASTER_FLYBACK_FRACTION` of it for the
flyback, the rest for the ramp. The SPC engine is told the same timing
(`FLIMCore.BalayageGalvos`).
"""
function raster_timing(request::RasterRequest, rate::Real)
    line = round(Int, request.duration_s * rate / request.lines)
    n_shift = round(Int, RASTER_FLYBACK_FRACTION * line)
    return line - n_shift, n_shift
end

"""
    build_scan_pattern(request::RasterRequest, cfg)::ScanPattern

The galvo scan's frame, one slot per line (`raster_timing`). Pixel `k` of a
line is at `to_voltage(k, pixels, …)`, the ROIs' own mapping; the ramp
crosses it at constant speed, sample `j` at the voltage of the middle of
its own time in the line, so a photon's place in the line's pass is its
pixel. Y holds the line's voltage during the ramp and moves to the next
line during the flyback; the last flyback returns to 0 V. Throws like the
ROI pattern: a ramp or flyback shorter than 2 samples, a galvo voltage past
the limits.
"""
function build_scan_pattern(request::RasterRequest, cfg::BenchConfig)::ScanPattern
    rate = cfg.sample_rate_hz
    n_scan, n_shift = raster_timing(request, rate)
    min(request.pixels, request.lines) >= 2 || throw(SafetyError("galvo scan: at least 2 pixels and 2 lines"))
    min(n_scan, n_shift) >= 2 ||
        throw(SafetyError("galvo scan: $(request.lines) lines in $(request.duration_s) s leave a ramp of $n_scan and a flyback of $n_shift samples; 2 at least"))
    n = n_scan + n_shift
    P, L = request.pixels, request.lines
    vx(c) = to_voltage(c, P, request.v_min_x, request.v_max_x) / 1000
    vy(c) = to_voltage(c, L, request.v_min_y, request.v_max_y) / 1000
    ramp = [vx(clamp(-0.5 + P * (j - 0.5) / n_scan, 0, P - 1)) for j in 1:n_scan]
    line_bits = routing_byte(FLIMCore.CODE_SANS_ROI, request.invert_routing) | do_bit(DO_BIT_GATE) | do_bit(DO_BIT_ENABLE)
    off = routing_byte(FLIMCore.CODE_HORS_ROI, request.invert_routing)
    x, y = zeros(n, L), zeros(n, L)
    lines = zeros(UInt8, n, L)
    for k in 1:L
        last_line = k == L
        x[1:n_scan, k] .= ramp
        y[1:n_scan, k] .= vy(k - 1)
        half_cosine_move!(view(x, n_scan+1:n, k), ramp[end], last_line ? 0.0 : ramp[1])
        half_cosine_move!(view(y, n_scan+1:n, k), vy(k - 1), last_line ? 0.0 : vy(k))
        lines[1:n_scan, k] .= line_bits
        lines[n_scan+1:n, k] .= off | do_bit(DO_BIT_ENABLE)
    end
    entry_x = half_cosine_move!(zeros(n_shift), 0.0, ramp[1])
    entry_y = half_cosine_move!(zeros(n_shift), 0.0, vy(0))
    check_galvo_path(vcat(vec(x), entry_x), vcat(vec(y), entry_y), cfg)
    return ScanPattern(rate, off, true, zeros(Int, L), n_scan, n_shift, n, entry_x, entry_y, x, y, lines, false, true)
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
command voltages wherever the gate P0.0 is high — during the scan, the
whole slot in images, and the pass signal's gap of a 0 ms shift without
ROIs — and 0 V elsewhere (the shift). With the opto laser's PWM
(`pattern.pwm_period` > 0), the commands only during its opto phases, which
carry the reserved routing code; 0 V during its acquisition phases. No
allocation.
"""
function prepare_slot!(buffers::SlotBuffers, pattern::ScanPattern, s::Integer, command1_v::Float64, command2_v::Float64)
    n = pattern.slot_samples
    offset = (slot_position(pattern, s) - 1) * n
    copyto!(buffers.galvos, 1, pattern.x, offset + 1, n)
    copyto!(buffers.galvos, n + 1, pattern.y, offset + 1, n)
    copyto!(buffers.lines, 1, pattern.lines, offset + 1, n)

    commands, lines = buffers.commands, buffers.lines
    period, opto = pattern.pwm_period, pattern.pwm_on
    slot_start = entry_samples(pattern) + s * n          # the run's sample count at the slot's start: the PWM runs on
    reserved = pattern.idle_lines & 0xf0                 # the reserved routing code (bits 4–7)
    @inbounds for j in 1:n
        on = (lines[j] & do_bit(DO_BIT_GATE)) != 0         # the 1064 nm where the gate P0.0 is high
        if on && period > 0
            if mod(slot_start + j - 1, period) < opto    # opto: the 1064 nm on, its photons thrown away
                commands[j], commands[n + j] = command1_v, command2_v
                lines[j] = (lines[j] & 0x0f) | reserved
            else                                         # acquisition: the 1064 nm off
                commands[j], commands[n + j] = 0.0, 0.0
            end
        else
            commands[j] = on ? command1_v : 0.0
            commands[n + j] = on ? command2_v : 0.0
        end
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
