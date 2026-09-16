"""
roi.jl

ROI trigger-box scan-buffer generation. When ROI mode is active
(`app.roi.active`) and a serial trigger box is connected
(`app_run.serial1`), `build_and_send_roi_trigger_buffer!` computes a
galvo scan buffer for the currently-drawn ROIs (`app_run.rois`) and uploads
it to the device — called once from `start_pressed` (runtime.jl), before
the acquisition worker is dispatched, so the trigger box is positioned
before files start arriving.

Scan-timing parameters (points per ROI, spiral turns, scan/shift time)
live on `app.protocol` (`ProtocolSettings`, data_types.jl) — GUI-editable
and persisted, via the Protocol panel (handlers_protocol.jl). The galvo
voltage range (`v_min_x`/`v_max_x`/`v_min_y`/`v_max_y`) lives on `app.roi`
(`RoiSettings`, data_types.jl) the same way, editable from the ROI popup
(roi_popup.jl). The remaining tunables below stay plain (non-persisted)
module variables, hand-edited directly in this file.

Ported from the standalone prototype `Test_roi_trigger_box.jl` (same
directory): that script loaded its own image/ROI-zip files and only
plotted the result. Here the ROI source is `app_run.rois` (already the
live ROI set — see roi_popup.jl) and the buffer is actually uploaded.
"""

using Statistics

# =============================================================================
# TUNABLE PARAMETERS
# =============================================================================
# Plain variables, not `const` — meant to be hand-edited in this file
# (not promoted to config.jl) as the trigger-box setup is tuned.

# Reference image size (pixels, square) the trigger-box voltage extremes
# below were calibrated against: a 1024x1024 image maps its full pixel
# extent onto the full voltage range. Real acquisitions are always 1024
# wide but can be shorter than 1024 tall (e.g. a 1024x512 scan) — rather
# than rescale a shorter image to fill the full voltage range (which would
# use a *different* voltage-per-pixel scale than this calibration),
# roi_trigger_buffer shifts a shorter image's ROI coordinates so they sit
# centered within this same 1024x1024 reference frame before converting to
# voltage, using the actual imported image size (app_run.imported_image_size,
# recorded at import time by roi_popup.jl) to compute that shift — matching
# roi_popup.jl's own canvas-centering (image_offset) for the on-screen
# display of that same image.
roi_voltage_calibration_size = 1024

# Gap held after every command written to a trigger box
# (send_roi_trigger_command), so the device gets time to actually parse it.
#
# This is flow control, not politeness. Nothing else paces these writes: the
# app does not wait for a reply, so without a real gap the commands leave
# back-to-back at full line rate. At 115200 baud a ~20-character command needs
# ~1.7 ms just to clock out, and the box needs more than that again to act on
# one — a sequence rewrite is not a memory poke. Send faster than it can drain
# and its receive buffer fills; an embedded parser that overruns typically
# wedges and stops accepting anything, which is exactly the "works for a while,
# then the board freezes" failure this replaces.
#
# It used to be 1e-6 — one microsecond, three orders of magnitude below the
# transmission time of the command it was meant to pace, i.e. no gap at all. A
# one-shot upload survived that; a run that rewrites sequences on every acquired
# image, forever, does not.
#
# Cost is linear in command count: the galvo upload is ~2 per scan point, so
# 5 ms puts a 375-point buffer at a few seconds, paid once at START. A power
# sequence swap is ~10 commands, so ~50 ms per image. Lower it if uploads feel
# slow and the box stays healthy; raise it if freezes persist.
roi_trigger_command_delay_s = 0.001

# How many times build_and_send_roi_trigger_buffer! restarts the *entire*
# build-and-upload sequence (buffer rebuild, full point re-upload, arming
# commands) from scratch after a failure — e.g. a LibSerialPort.Timeout()
# partway through — before giving up and logging an error. Not a per-command
# retry (see send_roi_trigger_command): a failure partway through leaves the
# device's buffer in an unknown partial state, so the only reliable recovery
# is to clear and redo the whole thing, not resume from wherever it broke.
roi_trigger_buffer_max_attempts = 3

# Analog output (mV) the second trigger box is driven to for a 100% PI
# command, i.e. the full-scale laser power. Commands are 0-100 (clamped by
# pid_command_from_state, acquisition.jl), so this is the only number
# converting a controller percentage into a voltage the hardware understands.
roi_power_full_scale_mv = 1000

# Duty cycle (percent) of the cycle-start pulse on digital output 4. Small on
# purpose: this output marks *when* a ROI series begins, so what matters is a
# clean edge once per cycle, not the width of the high level.
roi_cycle_pulse_duty_percent = 10

# --- Alternating power sequences (see RoiPowerSequencer) ---------------------

# Analog output channel the per-ROI laser power is written to.
roi_power_analog_channel = 3

# The two trigger sources the power sequence alternates between. Both are armed
# on the same digital input; one runs while the other is rebuilt.
#
# Deliberately clear of sources 1 and 2, which the galvo arming owns — 1 for
# the cycle pulse on digital output 4, 2 for the sweep and its gates. The
# sequencer clears and rewrites its own sources on every acquired image, so
# sharing one with the galvo would erase the sweep mid-run.
roi_power_trigger_sources = (3, 4)

# Digital input the two sources trigger on. Driven by digital output 4, the
# once-per-ROI-cycle pulse the galvo arming already emits
# (`roi_cycle_pulse_command`) — the sequencer consumes that pulse rather than
# generating a trigger of its own.
roi_power_trigger_input = 2

# Wait (µs) appended to a sequence to park it. Long enough that the sequence
# never completes and so never becomes eligible for the next trigger, which is
# what hands the input over to the other source. 2^31 - 1 is the largest value
# the field accepts.
roi_power_stall_us = 2^31 - 1

# Whether a power sequence drops to 0 between ROIs.
#
# `true` writes four actions per ROI (level, hold, zero, hold); `false` writes
# two (level, hold across scan+shift), holding each level straight through the
# shift onto the next ROI — the same shape the replayed buffer settled on.
#
# It more than halves the actions per swap, which is the lever that matters if
# the device is running out of sequence storage rather than out of time: at four
# ROIs it is 7 actions instead of 15.
roi_power_sequence_blank_between_rois = true

# Log the trigger box's reply to every power-sequence command. Debugging aid,
# and the only way to see the difference between "the app never sent it" and
# "the device refused it" — a source number the box does not implement, or a
# `C <n> Z` on a source that was never defined, comes back as an error the app
# would otherwise swallow. Verbose: one line per command on the first swap, one
# summary line per swap after that.
roi_power_log_commands = true


# =============================================================================
# GEOMETRY: uniform-density spiral scan pattern conforming to a ROI's shape
# =============================================================================

# Distance from (cx, cy) to the intersection between the ray at angle θ and
# the polygon contour (xs, ys). Returns 0.0 if no intersection is found.
function polygon_ray_distance(θ::Real, xs::AbstractVector{<:Real}, ys::AbstractVector{<:Real},
                                          cx::Real, cy::Real)
    dx, dy = cos(θ), sin(θ)
    n = length(xs)
    best = Inf

    for i in 1:n
        j = i == n ? 1 : i + 1
        ax, ay = xs[i] - cx, ys[i] - cy
        ex, ey = xs[j] - xs[i], ys[j] - ys[i]

        det = ex * dy - ey * dx
        abs(det) < 1e-12 && continue

        t = (ex * ay - ey * ax) / det
        s = (dx * ay - dy * ax) / det

        if t > 1e-9 && 0.0 <= s <= 1.0 && t < best
            best = t
        end
    end

    return isfinite(best) ? best : 0.0
end

# Variant of a disk spiral that hugs the ROI's own shape (xs, ys): the
# radial density still follows compensated_radial_cdf (computed for a mean
# radius R), but each point is then rescaled to the contour's actual
# distance in direction θ.
function shape_spiral_points(N::Int, xs::AbstractVector{<:Real}, ys::AbstractVector{<:Real};
                                         center::Tuple{Real,Real} = (0.0, 0.0),
                                         turns::Int = 4)

    x0, y0 = float(center[1]), float(center[2])

    R = mean(hypot(xs[k] - x0, ys[k] - y0) for k in eachindex(xs))

    points = Vector{Tuple{Int64,Int64}}(undef, N)

    for k in 1:N
        u = (k - 0.5) / N
        θ = π * turns * u

        R_θ = polygon_ray_distance(θ, xs, ys, x0, y0)
        R_θ = R_θ > 0 ? R_θ : R
        # ρ = R_θ * sqrt(u): uniform-area radial density (area ∝ ρ², so
        # sqrt(u) keeps points evenly spread by area, not clustered toward
        # the center) — no beam-width compensation.
        ρ_scaled = R_θ * sqrt(u)

        x = x0 + ρ_scaled * cos(θ)
        y = y0 + ρ_scaled * sin(θ)

        points[k] = (round(Int64, x), round(Int64, y))
    end

    return points
end

centroid_center(x_coords, y_coords) = (mean(x_coords), mean(y_coords))

# =============================================================================
# TOUR OPTIMIZATION: visiting order across ROI centers
# =============================================================================

dist2(p, q) = hypot(float(q[1]) - float(p[1]), float(q[2]) - float(p[2]))

function path_length_cycle(points::AbstractVector{<:Tuple{<:Real,<:Real}})
    n = length(points)
    n <= 1 && return 0.0

    s = 0.0
    for i in 1:n-1
        s += dist2(points[i], points[i+1])
    end
    s += dist2(points[end], points[1])
    return s
end

function nearest_neighbor_cycle(points::AbstractVector{<:Tuple{<:Real,<:Real}})
    n = length(points)
    n <= 1 && return collect(points)

    used = falses(n)
    order = Vector{Int}(undef, n)

    current = 1
    order[1] = current
    used[current] = true

    for k in 2:n
        best_j = 0
        best_d = Inf
        p = points[current]

        for j in 1:n
            if !used[j]
                d = dist2(p, points[j])
                if d < best_d
                    best_d = d
                    best_j = j
                end
            end
        end

        order[k] = best_j
        used[best_j] = true
        current = best_j
    end

    return [points[i] for i in order]
end

function two_opt_cycle!(tour::Vector{Tuple{Float64,Float64}})
    n = length(tour)
    n <= 3 && return tour

    improved = true
    while improved
        improved = false

        for i in 2:n-2
            for k in i+1:n-1
                A = tour[i-1]
                B = tour[i]
                C = tour[k]
                D = tour[k+1]

                old = dist2(A, B) + dist2(C, D)
                new = dist2(A, C) + dist2(B, D)

                if new + 1e-12 < old
                    reverse!(tour, i, k)
                    improved = true
                end
            end
        end
    end

    return tour
end

function heuristic_tour(points::AbstractVector{<:Tuple{<:Real,<:Real}})
    tour = [ (float(p[1]), float(p[2])) for p in nearest_neighbor_cycle(points) ]
    two_opt_cycle!(tour)
    return tour
end

# Exact shortest-cycle visiting order via Held-Karp DP (point 1 fixed to
# break symmetry). O(2^(n-1) * n) time/memory — fine for the small ROI
# counts this is meant for, but not intended to scale past ~15-20 ROIs.
function optimize_centers(points::AbstractVector{<:Tuple{<:Real,<:Real}})
    n = length(points)
    n <= 1 && return collect(points)

    pts = [(float(p[1]), float(p[2])) for p in points]

    # Initial upper bound from a fast heuristic.
    best_guess = heuristic_tour(pts)
    upper_bound = path_length_cycle(best_guess)

    d = Matrix{Float64}(undef, n, n)
    for i in 1:n, j in 1:n
        d[i, j] = dist2(pts[i], pts[j])
    end

    N = n - 1
    total_masks = 1 << N

    # dp[mask+1, j] = minimal cost starting from 1, visiting exactly mask
    # (over points 2..n), ending at j.
    dp = fill(Inf, total_masks, n)
    parent = fill(UInt16(0), total_masks, n)

    for j in 2:n
        mask = 1 << (j - 2)
        dp[mask + 1, j] = d[1, j]
        parent[mask + 1, j] = UInt16(1)
    end

    for mask in 0:total_masks-1
        for j in 2:n
            bitj = 1 << (j - 2)
            if (mask & bitj) == 0
                continue
            end

            cur = dp[mask + 1, j]
            if !isfinite(cur) || cur >= upper_bound
                continue
            end

            remaining = (~mask) & (total_masks - 1)
            while remaining != 0
                lb = remaining & -remaining
                kbit = trailing_zeros(lb)
                k = kbit + 2
                newmask = mask | lb
                newcost = cur + d[j, k]

                if newcost < dp[newmask + 1, k] && newcost < upper_bound
                    dp[newmask + 1, k] = newcost
                    parent[newmask + 1, k] = UInt16(j)
                end

                remaining -= lb
            end
        end
    end

    fullmask = total_masks - 1
    best_cost = Inf
    best_last = 0

    for j in 2:n
        c = dp[fullmask + 1, j] + d[j, 1]
        if c < best_cost
            best_cost = c
            best_last = j
        end
    end

    order = Vector{Int}(undef, n)
    order[1] = 1

    mask = fullmask
    last = best_last

    for pos in n:-1:2
        order[pos] = last
        prev = Int(parent[mask + 1, last])
        mask = mask & ~(1 << (last - 2))
        last = prev
    end

    return [points[i] for i in order]
end

# =============================================================================
# SERIAL PROTOCOL: trigger-box specific commands
# =============================================================================
#
# Distinct from serial.jl's send_command(serial_conn, command_str), which is
# fire-and-forget for the high-rate PID loop: uploading the scan buffer
# needs to read each command's response back to detect an "ERR" reply.

function send_roi_trigger_command(serial_conn, command_str::AbstractString)::String
    write(serial_conn, command_str)
    sleep(roi_trigger_command_delay_s)

    # Drain everything waiting, not just one read's worth. Whatever is left
    # behind stays queued and is attributed to the *next* command, so a partial
    # drain both misreports replies and lets the buffer creep upward across a
    # long run — and a host that stops keeping up is one more way to back
    # pressure onto the device.
    reply = ""
    while bytesavailable(serial_conn) > 0
        reply *= String(read(serial_conn))
    end

    return strip(reply)
end

"""
    send_roi_trigger_points!(serial_conn, pts; progress_cb=nothing)

Clear the trigger box's buffer and upload `pts`. `progress_cb`, if given, is
called with each new integer percent (0-100) as the upload advances —
throttled to only fire on an actual percent increase, the same idiom
`start_save` uses for save progress (acquisition.jl), so a callback wired to
an `Observable` isn't notified on every single point.
"""
function send_roi_trigger_points!(serial_conn, pts::Vector{Tuple{Int64,Int64}}; progress_cb::Union{Nothing, Function} = nothing)
    response = send_roi_trigger_command(serial_conn, "C Z\n")
    occursin("ERR", response) && @warn "Trigger box error clearing buffer" response=response

    n_pts = length(pts)
    last_progress_pct = -1

    for (idx, (x, y)) in enumerate(pts)
        response = send_roi_trigger_command(serial_conn, "A 0 AB 1 $idx $x\n")
        occursin("ERR", response) && @warn "Trigger box error setting buffer point" axis=1 idx=idx value=x response=response

        response = send_roi_trigger_command(serial_conn, "A 0 AB 2 $idx $y\n")
        occursin("ERR", response) && @warn "Trigger box error setting buffer point" axis=2 idx=idx value=y response=response

        if progress_cb !== nothing
            progress_pct = clamp(floor(Int, (idx * 100) / n_pts), 0, 100)
            if progress_pct > last_progress_pct
                for pct in (last_progress_pct + 1):progress_pct
                    try
                        progress_cb(pct)
                    catch e
                        @warn "ROI trigger-box progress callback failed" error=string(e)
                        progress_cb = nothing
                        break
                    end
                end
                last_progress_pct = progress_pct
            end
        end
    end

    return nothing
end

# =============================================================================
# BUFFER ASSEMBLY
# =============================================================================

# Pixel coordinate -> galvo voltage, matching Test_roi_trigger_box.jl's
# mapping (linear over the image span, sign-flipped for the galvo's
# mirrored axis convention).
to_voltage(coord::Real, n_pixels::Real, v_min::Real, v_max::Real) =
    -(v_min + (coord - 1) * (v_max - v_min) / (n_pixels - 1))

"""
    roi_scan_segment_lengths(protocol::ProtocolSettings)::Tuple{Int, Int}

The two segment lengths the galvo scan buffer repeats once per ROI:
`(spiral_points, dwell_points)` — the ROI's own spiral, then the settle
dwell that shifts onto the next ROI.

`dwell_points` is `shift_time/scan_time` of a spiral, rounded — so the ratio
the hardware actually plays is `spiral_points : dwell_points`, which is only
approximately `scan_time : shift_time`.

Concerns the galvo buffer alone. The power buffer carries one sample per ROI
and does not reproduce this split — see `roi_power_buffer`.
"""
function roi_scan_segment_lengths(protocol::ProtocolSettings)::Tuple{Int, Int}
    spiral_points = max(1, protocol.points_per_roi)
    scan_time = protocol.scan_time

    if !(scan_time > 0)
        return (spiral_points, 0)
    end

    dwell_points = max(0, round(Int, protocol.shift_time / scan_time * spiral_points))
    return (spiral_points, dwell_points)
end

"""
    roi_scan_cycle_frequency(protocol::ProtocolSettings, n_rois::Integer)::Float64

Playback frequency (Hz) of one full scan cycle across all `n_rois` ROIs —
the `f` both trigger boxes are armed with, so the galvo buffer and the power
buffer traverse their (different) lengths over the same wall-clock period.
"""
function roi_scan_cycle_frequency(protocol::ProtocolSettings, n_rois::Integer)::Float64
    return 1000.0 / ((protocol.scan_time + protocol.shift_time) * max(1, n_rois))
end

"""
    roi_cycle_pulse_command(frequency::Real)::String

The command arming digital output 4 as a one-pulse-per-ROI-series marker.

`frequency` is the full-cycle frequency (`roi_scan_cycle_frequency`), i.e. one
period per pass over *all* the ROIs — so the output pulses once as each series
begins, not once per ROI. The trailing field is the duty cycle,
`roi_cycle_pulse_duty_percent`.


Sent in the `A 1 ...` group, so like the galvo playback it is armed against
digital input 2 and starts on the `S 2 D 2 R 1` trigger rather than
free-running from upload time — which is what keeps the marker aligned with
the scan it marks.
"""
function roi_cycle_pulse_command(frequency::Real)::String
    return "A 1 DP 4 $frequency $roi_cycle_pulse_duty_percent\n"
end

"""
    ordered_roi_indices(rois::Vector{RoiCoordinates})::Vector{Int}

The order the galvo visits `rois` in: `result[k]` is the index into `rois` of
the ROI scanned in position `k` of the cycle (`optimize_centers`' shortest
tour across the ROI centers).

Exposed separately from `roi_trigger_buffer` because the power buffer's k-th
segment must carry the command of whichever ROI is *physically* scanned
there — which is this permutation, not `rois`' own order.
"""
function ordered_roi_indices(rois::Vector{RoiCoordinates})::Vector{Int}
    isempty(rois) && return Int[]

    centers = [centroid_center(roi.xs, roi.ys) for roi in rois]
    ordered_centers = optimize_centers(centers)

    return [findfirst(==(c), centers) for c in ordered_centers]
end

"""
    roi_trigger_buffer(app, app_run, rois::Vector{RoiCoordinates})::Vector{Tuple{Int64,Int64}}

Build the galvo trigger-box scan buffer for `rois`, in voltage units: an
optimized-order tour across ROI centers (`optimize_centers`), each followed
by a uniform-density spiral scan of that ROI's shape
(`shape_spiral_points`), with a settle dwell before entering each ROI after
the first, and a final dwell back at the first ROI's center to close the
cycle. Scan timing (`app.protocol.points_per_roi`/`.spiral_turns`/
`.scan_time`/`.shift_time`) is read from `app` — GUI-editable via the
Protocol panel, handlers_protocol.jl.

`rois`' coordinates are in `app_run.imported_image_size`'s own pixel space,
which can be shorter (in height) than `roi_voltage_calibration_size`'s
1024x1024 calibration reference — shifted to sit centered within that
reference frame before conversion to voltage; see that constant's
docstring for why.
"""
function roi_trigger_buffer(app, app_run, rois::Vector{RoiCoordinates})::Vector{Tuple{Int64,Int64}}
    isempty(rois) && return Tuple{Int64,Int64}[]

    points_per_roi, dwell_points = roi_scan_segment_lengths(app.protocol)

    v_min_x, v_max_x = app.roi.v_min_x, app.roi.v_max_x
    v_min_y, v_max_y = app.roi.v_min_y, app.roi.v_max_y

    image_width, image_height = app_run.imported_image_size
    x_shift = (roi_voltage_calibration_size - image_width) / 2
    y_shift = (roi_voltage_calibration_size - image_height) / 2

    ordered_rois = rois[ordered_roi_indices(rois)]

    buffer = Tuple{Int64,Int64}[]
    first_center_v = nothing

    for roi in ordered_rois
        cx, cy = centroid_center(roi.xs, roi.ys)
        center_v = (
            round(Int64, to_voltage(cx + x_shift, roi_voltage_calibration_size, v_min_x, v_max_x)),
            round(Int64, to_voltage(cy + y_shift, roi_voltage_calibration_size, v_min_y, v_max_y))
        )

        xs_v = [to_voltage(x + x_shift, roi_voltage_calibration_size, v_min_x, v_max_x) for x in roi.xs]
        ys_v = [to_voltage(y + y_shift, roi_voltage_calibration_size, v_min_y, v_max_y) for y in roi.ys]

        if first_center_v === nothing
            first_center_v = center_v
        else
            append!(buffer, fill(center_v, dwell_points))
        end

        append!(buffer, shape_spiral_points(points_per_roi, xs_v, ys_v; center=center_v, turns=app.protocol.spiral_turns))
    end

    # The closing dwell exists to carry the beam back to the first ROI for the
    # next cycle. With a single ROI there is nowhere to go — it is already
    # there — so the dwell would only park the beam at the ROI's centre for
    # `shift_time` out of every period. Dropping it leaves the buffer as the
    # spiral alone, and since the box replays whatever it is given across one
    # full cycle, that spiral then spans `scan_time + shift_time`: the ROI is
    # traced continuously instead of being scanned and then held still.
    if length(ordered_rois) > 1
        append!(buffer, fill(first_center_v, dwell_points))
    end

    return buffer
end

# =============================================================================
# PER-ROI POWER BUFFER (second trigger box)
# =============================================================================
#
# The galvo buffer above says *where* the beam goes; this one says how hard it
# is driven while it is there — one sample per ROI, nothing more.
#
# The two buffers deliberately do NOT share a length or a shape. The galvo
# needs `points_per_roi` coordinates per ROI to draw a spiral; the power is a
# single number per ROI. Both boxes replay their own buffer over the same cycle
# period, so a power buffer of exactly `n_rois` samples steps once per ROI
# period on its own, with no need to reproduce the galvo's scan/shift split.
#
# The power does not drop between ROIs. It steps straight from one ROI's level
# to the next and holds through the shift, so each sample spans a whole ROI
# period (scan + shift) rather than only the scan.

"""
    command_to_power_mv(command::Real)::Int

Convert one PI command (percent, 0-100) into the analog level the power
trigger box is driven to, `roi_power_full_scale_mv` at 100%.

The result is clamped to `ANALOG_OUTPUT_MAX_MV` (config.jl) regardless of what
`roi_power_full_scale_mv` is set to. That tunable is hand-edited in this file,
so without the clamp a typo there would raise the real voltage reaching the
hardware; the ceiling is not something a per-feature setting should be able to
lift.

`NaN` — the pipeline's "no command" sentinel, produced by a disabled output
or an inactive protocol (`pid_command_from_state`, acquisition.jl) — maps to
0, so losing the command turns the laser off rather than leaving it at
whatever it last held.
"""
function command_to_power_mv(command::Real)::Int
    value = Float64(command)
    isfinite(value) || return 0
    level = round(Int, clamp(value, 0.0, 100.0) / 100.0 * roi_power_full_scale_mv)
    return clamp(level, 0, ANALOG_OUTPUT_MAX_MV)
end

# =============================================================================
# ALTERNATING POWER SEQUENCES (galvo box, no second device)
# =============================================================================
#
# A second way to modulate per-ROI power, replacing the power box entirely: the
# galvo box itself steps analog output `roi_power_analog_channel` through the
# ROIs' levels, driven by a *sequence* of set-and-wait actions rather than a
# replayed sample buffer.
#
# One sequence describes a whole cycle — for each ROI, set the level, wait
# `scan_time`, drop to 0, wait `shift_time` — and is armed on a digital input
# pulsed once per cycle. The catch is that a sequence cannot be rewritten while
# it is running, and the levels change on every acquired image.
#
# Hence two sequences on two trigger sources, both armed on the *same* input.
# Only one is ever eligible: appending an enormous wait to the running one stops
# it from completing, so it never re-arms, and the next pulse falls through to
# the other. Each image parks the runner, rebuilds the idle one with fresh
# levels, and swaps. The output is therefore never interrupted to be updated.

"""
    RoiPowerSequencer

Which of the two alternating power sequences is currently running, and which
sources have ever been written.

`running` is 0 before the first sequence exists — that first call also clears
the device and starts the free-running trigger, so it is a different command
list from every later swap. `built` exists because a source that has never held
a sequence must not be cleared (`C <n> Z`), only ones that have.

`last_powers` is the level vector currently loaded on the device. A swap that
would write those same levels again is skipped entirely: the running sequence
already produces them, so rewriting it costs a full command burst to change
nothing. Once the controller settles this removes most of the traffic, which
matters because the device tolerates a limited number of these writes — see
`push_roi_power_sequence!`.

One instance per acquisition run, owned by `consumer_loop` (runtime.jl).
"""
mutable struct RoiPowerSequencer
    running::Int
    built::Set{Int}
    last_powers::Vector{Int}
end

RoiPowerSequencer() = RoiPowerSequencer(0, Set{Int}(), Int[])

"""
    roi_power_sequence_actions(protocol, powers_mv, source)::Vector{String}

The set-and-wait actions describing one full cycle on trigger `source`: for
each ROI in scan order, drive the analog channel to that ROI's level, hold for
`scan_time`, drop to 0, hold for `shift_time`.

Waits are in microseconds, so the protocol's millisecond timings are scaled by
1000. The trailing shift wait is omitted: the sequence ends at 0 and simply
idles there until the next trigger arrives, so spelling out the last gap would
only risk overrunning the cycle.
"""
function roi_power_sequence_actions(protocol::ProtocolSettings, powers_mv::AbstractVector{<:Integer}, source::Integer)::Vector{String}
    scan_us = round(Int, protocol.scan_time * 1000)
    shift_us = round(Int, protocol.shift_time * 1000)
    channel = roi_power_analog_channel

    actions = String[]
    n = length(powers_mv)

    for (i, level) in enumerate(powers_mv)
        push!(actions, "A $source AO $channel $level\n")

        if roi_power_sequence_blank_between_rois
            push!(actions, "A $source WT $scan_us\n")
            push!(actions, "A $source AO $channel 0\n")
            i < n && push!(actions, "A $source WT $shift_us\n")
        else
            # One hold spanning scan and shift: the level carries straight
            # through to the next ROI instead of being blanked and restored.
            push!(actions, "A $source WT $(scan_us + shift_us)\n")
        end
    end

    println(actions)

    return actions
end

"""
    roi_power_swap_commands(sequencer, protocol, powers_mv) -> (commands, next_source)

Every command needed to put `powers_mv` on the output, and the source they land
on — without stopping what is currently running.

Two shapes, depending on whether anything is running yet:

**First call** — clear *both* of the sequencer's own sources, arm the first,
and write the sequence. Deliberately not a device-wide `C Z`: that would erase
the galvo arming sent moments earlier, including the very pulse on digital
output 4 that drives these sequences. Nor is a trigger generator started here —
that pulse already exists (`roi_cycle_pulse_command`).

**Every call after** — park the running source with a `roi_power_stall_us`
wait, clear the other one if it has been used before, re-arm it on the same
input, and write the fresh sequence. The parked source stays parked until its
own turn comes round again, at which point it is cleared and rebuilt.

Pure: it decides nothing about I/O and mutates nothing, so the exact command
list for any state can be inspected directly. `push_roi_power_sequence!` is
what sends it and advances `sequencer`.
"""
function roi_power_swap_commands(sequencer::RoiPowerSequencer, protocol::ProtocolSettings,
                                 powers_mv::AbstractVector{<:Integer})
    first, second = roi_power_trigger_sources
    commands = String[]

    if sequencer.running == 0
        next = first
        push!(commands, "C $first Z\n")
        push!(commands, "C $second Z\n")
        push!(commands, "S $next D $roi_power_trigger_input R 1\n")
        append!(commands, roi_power_sequence_actions(protocol, powers_mv, next))
        return (commands, next)
    end

    next = sequencer.running == first ? second : first

    push!(commands, "A $(sequencer.running) WT $roi_power_stall_us\n")
    next in sequencer.built && push!(commands, "C $next Z\n")
    push!(commands, "S $next D $roi_power_trigger_input R 1\n")
    append!(commands, roi_power_sequence_actions(protocol, powers_mv, next))

    return (commands, next)
end


"""
    push_whole_image_command!(app_run, command)::Bool

Drive analog output 3 on `app_run.serial1` to `command`, the whole-frame PI
output — the ROI-mode-off counterpart to the per-ROI power buffer.

Used whenever the run has a single region — ROI mode off, or ROI mode on with
exactly one ROI (see `drives_analog_output_directly`, serial.jl). There is then
one controller and one level to apply, so there is no buffer to replay and
nothing to sequence: the level is written straight out as `A 0 AO 3 <mV>` each
time an image produces a new command, and held until the next one. Same scale
as the power buffer (`command_to_power_mv`), so a given command means the same
voltage in every configuration.

Fire-and-forget, like `serial_signal_loop`'s own output writes (serial.jl):
one command per acquired image is not a burst, and a dropped one costs a
single frame of stale level.

Returns `false` when the galvo box is not connected.
"""
function push_whole_image_command!(app_run, command::Real)::Bool
    serial_conn = app_run.serial1
    serial_conn === nothing && return false

    try
        send_command(serial_conn, "A 0 AO 3 $(command_to_power_mv(command))\n")
        return true
    catch e
        @warn "Failed to send whole-image command" error=string(e)
        return false
    end
end

"""
    roi_power_buffer(protocol, commands_in_scan_order)::Vector{Int}

Build the power buffer for one full scan cycle: one sample per ROI, in the
order the galvo visits them, holding that ROI's command as an analog level.

`commands_in_scan_order[k]` must be the command of the ROI scanned in
position `k` — i.e. already permuted through `ordered_roi_indices`, not in
the drawn-ROI order. Getting that wrong would silently drive each ROI at
another ROI's power.

There is no zero between ROIs. Armed at the cycle frequency over `n_rois`
samples, the box advances one sample per ROI period, so each level simply
holds across that ROI's scan *and* the shift onto the next one. `protocol` is
unused as a result, and kept only so callers need not care which shape the
buffer currently takes.
"""
function roi_power_buffer(protocol::ProtocolSettings, commands_in_scan_order::AbstractVector{<:Real})::Vector{Int}
    return [command_to_power_mv(command) for command in commands_in_scan_order]
end

"""
    power_buffer_emitter(serial_conn, readback::Bool)

The write function the power-buffer helpers below send through.

`readback` picks between the two I/O styles this codebase already uses:
`send_roi_trigger_command` (reads each reply, so an `ERR` surfaces, and the
read paces the writes to a rate the box can absorb) or `send_command`
(serial.jl's fire-and-forget, the style `serial_signal_loop` uses).
"""
function power_buffer_emitter(serial_conn, readback::Bool)
    return readback ?
        (cmd -> send_roi_trigger_command(serial_conn, cmd)) :
        (cmd -> (send_command(serial_conn, cmd); ""))
end

"""
    write_roi_power_samples!(serial_conn, buffer; readback=true)::String

Overwrite the power buffer's samples in place — no clear, no re-arm — so the
device keeps replaying throughout and simply picks the new values up.

This is the per-frame update path. It must not clear or re-arm: `C Z` followed
by the arming pair *restarts* playback from sample 1, so with an update on
every acquired image the box never gets further than the first ROI or two
before being reset. The visible symptom is exactly that — ROI 1 changing while
the later ROIs sit at whatever they were, or a ROI cut off part-way through its
scan. Only the initial upload (`send_roi_power_buffer!`) may clear and arm.

Returns the concatenated responses (empty when `readback` is false).
"""
function write_roi_power_samples!(serial_conn, buffer::Vector{Int}; readback::Bool=true)::String
    emit = power_buffer_emitter(serial_conn, readback)

    response = ""
    for (idx, level) in enumerate(buffer)
        response *= emit("A 0 AB 1 $idx $level\n")
    end

    return response
end

"""
    send_roi_power_buffer!(serial_conn, buffer, frequency; readback=true)::String

Upload `buffer` to the power trigger box and arm it to replay at `frequency`
(one full cycle per period, matching the galvo box).

The **initial** upload only — it clears the buffer first and arms playback
afterwards, both of which reset the device's position in the cycle. Per-frame
updates go through `write_roi_power_samples!` instead, which leaves playback
running.

Returns the concatenated responses (empty when `readback` is false).
"""
function send_roi_power_buffer!(serial_conn, buffer::Vector{Int}, frequency::Real; readback::Bool=true)::String
    emit = power_buffer_emitter(serial_conn, readback)

    response = emit("C Z\n")
    response *= write_roi_power_samples!(serial_conn, buffer; readback=readback)
    response *= emit("S 1 D 1 R 1\n")
    response *= emit("A 1 AR 1 $frequency $(length(buffer))\n")

    return response
end

"""
    RoiPowerControl

Per-ROI PI state driving the power buffer, owned by `consumer_loop`
(runtime.jl) for the length of one run.

# Why the controllers live here rather than in the worker

The acquisition worker already runs a PI pair, but a single one: it regulates
on `regions[1]` alone, because there is only one physical output pair on the
galvo box and it cannot follow every region at once. The power box is
different — it drives each ROI separately — so each ROI needs its own
integrator, and they are updated here, where every region of an instance is
available at once.

# Fields

- `pids` / `commands`: one PI state and its latest command per drawn ROI,
  indexed in the drawn-ROI order (`app_run.rois[]`), the same order
  `consumer_loop`'s `roi_idx` uses
- `last_timestamp`: when each ROI was last measured, so its `dt` spans a full
  cycle (a ROI is only seen once per cycle, not once per frame). `NaN` until
  that ROI's first sample
- `scan_order`: `ordered_roi_indices`' permutation, applied when the buffer is
  assembled so sample `k` carries the ROI actually scanned there
- `frequency`: the arming frequency, fixed for the run
- `fallback_dt`: `dt` used for a ROI's very first sample, when there is no
  previous timestamp to subtract
- `warned_nan_command`: whether the "commands are NaN, laser stays dark"
  warning has already been emitted, so it is said once per run rather than
  once per frame
"""
mutable struct RoiPowerControl
    pids::Vector{PidChannelState}
    commands::Vector{Float64}
    last_timestamp::Vector{Float64}
    scan_order::Vector{Int}
    frequency::Float64
    fallback_dt::Float64
    warned_nan_command::Bool
end

"""
    RoiPowerControl(protocol, scan_order, n_rois)

Fresh per-ROI power control for a run of `n_rois` ROIs visited in
`scan_order`. Commands start at 0 — nothing has been measured yet, so the
laser stays off until the first frame of each ROI produces a command.
"""
function RoiPowerControl(protocol::ProtocolSettings, scan_order::Vector{Int}, n_rois::Integer)
    n = max(1, Int(n_rois))
    order = isempty(scan_order) ? collect(1:n) : scan_order

    cycle_s = roi_scan_period_s(protocol) * n
    fallback_dt = (isfinite(cycle_s) && cycle_s > 0.0) ? cycle_s : 1.0

    return RoiPowerControl(
        [PidChannelState() for _ in 1:n],
        zeros(Float64, n),
        fill(NaN, n),
        order,
        roi_scan_cycle_frequency(protocol, n),
        fallback_dt,
        false
    )
end

"""
    update_roi_power_command!(control, roi_idx, ratio, setpoint, timestamp, controller, smooth_level)

Fold one instance's measurement into ROI `roi_idx`'s own PI controller and
store the resulting command, returning it.

`dt` is measured against that ROI's own previous sample rather than against the
previous frame. With every ROI measured on every instance the two coincide, but
keeping it per-ROI means the integral term stays correct for a ROI that misses
an instance, instead of silently accumulating over the wrong interval.
"""
function update_roi_power_command!(control::RoiPowerControl, roi_idx::Integer, ratio::Float64,
                                   setpoint::Float64, timestamp::Float64,
                                   controller::ControllerSettings, smooth_level::Int)::Float64
    idx = clamp(Int(roi_idx), 1, length(control.pids))

    previous = control.last_timestamp[idx]
    dt = isfinite(previous) ? timestamp - previous : control.fallback_dt
    dt = dt > 0.0 ? dt : control.fallback_dt
    control.last_timestamp[idx] = timestamp

    state = control.pids[idx]
    update_pid_error!(state, ratio, setpoint, dt, smooth_level)

    command = pid_command_from_state(state, setpoint, controller.P1, controller.I1,
                                     controller.ch1_inv, controller.ch1_on)
    control.commands[idx] = command

    return command
end

"""
    roi_power_commands_in_scan_order(control)::Vector{Float64}

`control.commands` permuted into the galvo's visiting order — what
`roi_power_buffer` expects.
"""
function roi_power_commands_in_scan_order(control::RoiPowerControl)::Vector{Float64}
    return [control.commands[i] for i in control.scan_order]
end

"""
    log_roi_power_commands(control, frame_index)

Log this instance's per-ROI commands and the mV each one maps to.

Temporary debugging aid: it makes visible, per frame, whether the power values
leaving the app are what the controller intended — separating "the commands are
wrong" from "the commands are right but the box is not driven" when nothing
shows up at the output. Remove once the hardware path is confirmed.
"""
function log_roi_power_commands(control::RoiPowerControl, frame_index)
    commands = control.commands
    levels = [command_to_power_mv(c) for c in commands]

    # A NaN command means the controller produced nothing to apply — output 1
    # switched off in the Controller panel, or no protocol setpoint at this
    # instant — and maps to 0 mV, i.e. the laser stays dark. Indistinguishable
    # from a wiring fault at the bench, so say it once, explicitly.
    if !control.warned_nan_command && any(!isfinite, commands)
        @warn "ROI power commands are NaN, so those ROIs are driven to 0 mV — check that output 1 is enabled in the Controller panel and that the protocol has a setpoint at this time"
        control.warned_nan_command = true
    end

    @info "ROI powers" frame=frame_index commands=round.(commands, digits=2) mV=levels scan_order=control.scan_order

    return nothing
end

"""
    push_roi_power_buffer!(app, app_run, control)::Bool

Rebuild the whole power buffer from `control`'s current per-ROI commands and
write it over what the box is replaying.

Every ROI is measured on every instance, so every command changes on every
instance and the whole buffer is rewritten — there is no partial update to
exploit.

Writes the samples *in place* (`write_roi_power_samples!`): no `C Z`, no
re-arm. Clearing and re-arming here would restart playback from sample 1 on
every acquired image, which never lets the box get past the first ROI or two —
see that function's docstring.

Responses are read back rather than fired and forgotten. The read is what paces
the writes to a rate the box can absorb; a burst of unacknowledged writes is a
classic way for a device to silently drop most of them. It costs one round trip
per sample — 63 for three ROIs at the default timings.

Returns `false` when no second device is connected. Failures are caught and
logged, never raised: a dropped power update should cost one cycle of stale
power, not tear down the consumer loop mid-run.
"""
function push_roi_power_buffer!(app, app_run, control::RoiPowerControl)::Bool
    serial_conn = app_run.serial2
    serial_conn === nothing && return false

    try
        buffer = roi_power_buffer(app.protocol, roi_power_commands_in_scan_order(control))
        response = write_roi_power_samples!(serial_conn, buffer; readback=true)
        occursin("ERR", response) && @warn "Power trigger box error on per-frame buffer update" response=response
        return true
    catch e
        @warn "Failed to push ROI power buffer" error=string(e)
        return false
    end
end

"""
    push_roi_power_sequence!(app, app_run, sequencer, control)::Bool

Send the next power sequence to `app_run.serial1` and advance `sequencer`.

Levels come from `control`'s per-ROI commands, permuted into the galvo's
visiting order so sequence step `k` carries the ROI actually scanned there.

Responses are read back, which paces the writes — a swap is a few dozen
commands and an unacknowledged burst is a good way to have the device drop
some. `sequencer` is only advanced once the whole list has gone out: a swap
that fails partway leaves `running` pointing at the source that is still
actually running, so the next image retries the same transition rather than
parking a sequence that never started.

Returns `false` when the galvo box is not connected.
"""
function push_roi_power_sequence!(app, app_run, sequencer::RoiPowerSequencer, control::RoiPowerControl)::Bool
    serial_conn = app_run.serial1
    serial_conn === nothing && return false

    powers_mv = [command_to_power_mv(c) for c in roi_power_commands_in_scan_order(control)]

    # Nothing to do if the device is already producing these levels. The whole
    # point of a swap is to change them; repeating one spends a command burst
    # to arrive where the hardware already is, and the device only tolerates so
    # many of those before it stops responding.
    if sequencer.running != 0 && powers_mv == sequencer.last_powers
        roi_power_log_commands && @info "power sequence unchanged, swap skipped" mV=powers_mv
        return true
    end

    commands, next = roi_power_swap_commands(sequencer, app.protocol, powers_mv)

    # The very first swap is the one that defines the sources, so it is the one
    # whose replies matter: a source number the box does not implement shows up
    # here and nowhere else.
    verbose = roi_power_log_commands && sequencer.running == 0

    try
        response = ""
        for command in commands
            reply = send_roi_trigger_command(serial_conn, command)
            verbose && @info "power sequence setup" cmd=strip(command) reply=reply
            response *= reply
        end

        if occursin("ERR", response)
            @warn "Trigger box error updating power sequence" source=next response=response
        elseif roi_power_log_commands
            @info "power sequence swapped" source=next n_commands=length(commands) mV=powers_mv reply=strip(response)
        end

        sequencer.running = next
        push!(sequencer.built, next)
        sequencer.last_powers = powers_mv
        return true
    catch e
        @warn "Failed to push ROI power sequence" source=next error=string(e)
        return false
    end
end

"""
    zero_roi_power_buffer!(app, app_run)

Drive every ROI's power to zero on `app_run.serial2` — the power box's
counterpart to `zero_all_outputs!` (serial.jl) on the galvo box, called from
`stop_pressed` (runtime.jl) so STOP leaves the laser off instead of parked at
whatever the controller last commanded.

Writes zeros over the buffer in place — no `C Z`, no re-arm — so the box goes
dark while still replaying, rather than being left in a cleared, unarmed state
whose behavior at the output is undefined.

Failures are swallowed: like `zero_all_outputs!`, a flaky port must not be
able to block shutdown.
"""
function zero_roi_power_buffer!(app, app_run)
    serial_conn = app_run.serial2
    serial_conn === nothing && return nothing

    n_rois = max(1, length(app_run.rois[]))

    try
        buffer = roi_power_buffer(app.protocol, zeros(Float64, n_rois))
        write_roi_power_samples!(serial_conn, buffer; readback=true)
        @info "ROI power buffer zeroed" n_samples=length(buffer)
    catch e
        @warn "Failed to zero ROI power buffer" error=string(e)
    end

    return nothing
end

"""
    send_initial_roi_power_buffer!(app, app_run, n_rois, frequency)

Upload the run's first power buffer to `app_run.serial2`, right after the
galvo box has been armed, so both boxes start their cycle together.

Every ROI starts at zero: no frame has been measured yet, so no ROI has a
command. `consumer_loop` (runtime.jl) replaces this buffer as soon as the
first frame of each ROI arrives.

Read back (unlike the per-frame updates) so an `ERR` from the box surfaces
once, at START, where it is actionable. A no-op when no second device is
connected — the galvo half of ROI mode works on its own.
"""
function send_initial_roi_power_buffer!(app, app_run, n_rois::Integer, frequency::Real)
    serial_conn = app_run.serial2
    if serial_conn === nothing
        @info "No second serial device connected; skipping ROI power-buffer upload"
        return nothing
    end

    buffer = roi_power_buffer(app.protocol, zeros(Float64, max(1, Int(n_rois))))
    response = send_roi_power_buffer!(serial_conn, buffer, frequency; readback=true)

    if occursin("ERR", response)
        @warn "Power trigger box error uploading initial buffer" response=response
    else
        @info "ROI power buffer uploaded and armed" n_samples=length(buffer) frequency=frequency
    end

    return nothing
end

"""
    build_and_send_roi_trigger_buffer!(app, app_run)

If ROI mode is active (`app.roi.active`) and a serial trigger box is
connected (`app_run.serial1`), build the scan buffer for the currently
drawn ROIs (`app_run.rois`) and upload it, then arm the device's playback
timing. A no-op (with a log message) if ROI mode is off, no device is
connected, or no ROIs are drawn.

Arming also sets up digital output 4 as a once-per-ROI-series pulse
(`roi_cycle_pulse_command`), for scoping or for triggering downstream
equipment on the start of each cycle.

Once the galvo box is armed, records the scan order on `app_run` and hands
off to `send_initial_roi_power_buffer!` for the second box, so both start
their cycle from the same point.

On failure (e.g. a `LibSerialPort.Timeout()` partway through), restarts the
whole sequence from scratch — buffer rebuild, full re-upload, arming
commands — up to `roi_trigger_buffer_max_attempts` times, re-checking
`app_run.serial1` on each attempt in case a concurrent disconnect
(serial.jl's `serial_signal_loop`) cleared it. Only gives up (logs an error,
swallowed, not raised) after that many failures — a trigger-box upload
failure shouldn't block acquisition from starting.

Drives the point-upload portion (`send_roi_trigger_points!`, the dominant
share of the round trips) through `app_run.save_progress` — the same
Observable/progress bar `start_save` (acquisition.jl) uses, safe to reuse
since this always runs and completes before `start_pressed` (runtime.jl)
dispatches the acquisition worker, so the two never overlap in time.
Restored to `NaN` (hidden, GUI.jl) after every attempt, success or not.
"""
function build_and_send_roi_trigger_buffer!(app, app_run)
    if !app.roi.active
        return nothing
    end

    if app_run.serial1 === nothing
        @info "ROI mode is active but no serial device is connected; skipping trigger-box upload"
        return nothing
    end

    rois = app_run.rois[]
    if isempty(rois)
        @info "ROI mode is active but no ROIs are drawn; skipping trigger-box upload"
        return nothing
    end

    for attempt in 1:roi_trigger_buffer_max_attempts
        serial_conn = app_run.serial1
        if serial_conn === nothing
            @warn "Serial device disconnected while retrying ROI trigger-box upload; giving up" attempt=attempt
            return nothing
        end

        try
            @info "Building ROI trigger-box scan buffer" n_rois=length(rois) points_per_roi=app.protocol.points_per_roi image_size=app_run.imported_image_size attempt=attempt
            buffer = roi_trigger_buffer(app, app_run, rois)

            @info "Uploading ROI trigger-box scan buffer" n_points=length(buffer)
            app_run.save_progress[] = 0.0
            roi_progress_cb = function (pct)
                app_run.save_progress[] = Float64(pct)
                return nothing
            end
            send_roi_trigger_points!(serial_conn, buffer; progress_cb=roi_progress_cb)

            scan_time = app.protocol.scan_time
            shift_time = app.protocol.shift_time
            n_rois = length(rois)
            f = roi_scan_cycle_frequency(app.protocol, n_rois)
            duty_percent = 100 - round(Int64, 100 * shift_time / (shift_time + scan_time))

            # Trigger sources on the galvo box. Source 1 is digital input 1
            # (fed from this box's own DO 3, set high at the very end), source 2
            # is digital input 2 (fed from DO 4, the cycle pulse).
            response = send_roi_trigger_command(serial_conn, "S 1 D 1 R 1\n")
            response *= send_roi_trigger_command(serial_conn, "S 2 D 2 R 1\n")

            # Armed on source 2, so the galvo sweep and its gates restart on
            # every cycle pulse rather than free-running from the single
            # experiment-start edge.
            response *= send_roi_trigger_command(serial_conn, "A 2 AA $f $(length(buffer))\n")
            response *= send_roi_trigger_command(serial_conn, "A 2 DD 1 $(f * n_rois) $duty_percent 2 $n_rois 10\n")
            response *= send_roi_trigger_command(serial_conn, "A 2 DD 1 $(f * n_rois) $duty_percent 2 1 10\n")
            # response *= send_roi_trigger_command(serial_conn, "A 1 DD 1 $f $duty_percent 2 1 $duty_percent\n")

            # Cycle-start marker on digital output 4: `f` is one period per pass
            # over every ROI, so this pulses once as each series begins. Armed on
            # source 1 — it is the one thing the experiment-start edge starts,
            # and everything else hangs off its pulses.
            response *= send_roi_trigger_command(serial_conn, roi_cycle_pulse_command(f))

            # Recorded here, not recomputed by the consumer: this is the order
            # the galvo box was *actually* programmed with, and the ROI set can
            # change (ROI popup) between this upload and the consumer starting.
            app_run.roi_scan_order = ordered_roi_indices(rois)

            # The power box has to be uploaded AND armed before the start edge is
            # produced below. Its playback is triggered by DO 4, so anything not
            # in place by then misses the pulses it was waiting for: the upload
            # alone is 60+ serial round trips, which used to run entirely after
            # DO 3 had already gone high and the cycle pulse had started.
            send_initial_roi_power_buffer!(app, app_run, n_rois, f)

            # Last, and only once everything on both boxes is armed: raise DO 3.
            # That single rising edge into DI 1 starts the cycle pulse, which in
            # turn starts the galvo sweep (via DI 2) and the power buffer (via
            # the power box's DI 1).
            response *= send_roi_trigger_command(serial_conn, "A 0 DO 3 1\n")

            if occursin("ERR", response)
                @warn "Trigger box error arming playback timing" response=response
            else
                @info "ROI trigger-box scan buffer uploaded and armed"
            end

            return nothing
        catch e
            if attempt < roi_trigger_buffer_max_attempts
                @warn "Failed to build/send ROI trigger-box scan buffer, restarting from scratch" attempt=attempt max_attempts=roi_trigger_buffer_max_attempts error=string(e)
            else
                @error "Failed to build/send ROI trigger-box scan buffer after $roi_trigger_buffer_max_attempts attempts" error=string(e)
            end
        finally
            app_run.save_progress[] = NaN
        end
    end

    return nothing
end
