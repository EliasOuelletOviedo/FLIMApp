"""
roi.jl

ROI trigger-box scan-buffer generation. When ROI mode is active
(`app.roi.active`) and a serial trigger box is connected
(`app_run.serial_conn`), `build_and_send_roi_trigger_buffer!` computes a
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

# Delay between writing a command and reading the trigger box's response
# (send_roi_trigger_command), giving the device time to process and reply
# before the read is attempted. A real upload sends on the order of 1000+
# of these round trips (2 per scan point, plus overhead commands), so too
# short a delay here risks a read finding no data yet and blocking until
# connect_to_port's read timeout (serial.jl) — surfacing as
# LibSerialPort.Timeout() and aborting the whole upload on one slow reply.
# Raise if timeouts persist; lower if uploads feel unnecessarily slow.
roi_trigger_command_delay_s = 0.000001

# How many times build_and_send_roi_trigger_buffer! restarts the *entire*
# build-and-upload sequence (buffer rebuild, full point re-upload, arming
# commands) from scratch after a failure — e.g. a LibSerialPort.Timeout()
# partway through — before giving up and logging an error. Not a per-command
# retry (see send_roi_trigger_command): a failure partway through leaves the
# device's buffer in an unknown partial state, so the only reliable recovery
# is to clear and redo the whole thing, not resume from wherever it broke.
roi_trigger_buffer_max_attempts = 3

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
    return strip(read(serial_conn, String))
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

    points_per_roi = app.protocol.points_per_roi
    dwell_points = round(Int, app.protocol.shift_time / app.protocol.scan_time * points_per_roi)

    v_min_x, v_max_x = app.roi.v_min_x, app.roi.v_max_x
    v_min_y, v_max_y = app.roi.v_min_y, app.roi.v_max_y

    image_width, image_height = app_run.imported_image_size
    x_shift = (roi_voltage_calibration_size - image_width) / 2
    y_shift = (roi_voltage_calibration_size - image_height) / 2

    centers = [centroid_center(roi.xs, roi.ys) for roi in rois]
    ordered_centers = optimize_centers(centers)
    ordered_rois = [rois[findfirst(==(c), centers)] for c in ordered_centers]

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

    append!(buffer, fill(first_center_v, dwell_points))

    return buffer
end

"""
    build_and_send_roi_trigger_buffer!(app, app_run)

If ROI mode is active (`app.roi.active`) and a serial trigger box is
connected (`app_run.serial_conn`), build the scan buffer for the currently
drawn ROIs (`app_run.rois`) and upload it, then arm the device's playback
timing. A no-op (with a log message) if ROI mode is off, no device is
connected, or no ROIs are drawn.

On failure (e.g. a `LibSerialPort.Timeout()` partway through), restarts the
whole sequence from scratch — buffer rebuild, full re-upload, arming
commands — up to `roi_trigger_buffer_max_attempts` times, re-checking
`app_run.serial_conn` on each attempt in case a concurrent disconnect
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

    if app_run.serial_conn === nothing
        @info "ROI mode is active but no serial device is connected; skipping trigger-box upload"
        return nothing
    end

    rois = app_run.rois[]
    if isempty(rois)
        @info "ROI mode is active but no ROIs are drawn; skipping trigger-box upload"
        return nothing
    end

    for attempt in 1:roi_trigger_buffer_max_attempts
        serial_conn = app_run.serial_conn
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
            f = 1000.0 / ((scan_time + shift_time) * n_rois)
            duty_percent = 100 - round(Int64, 100 * shift_time / (shift_time + scan_time))

            response = send_roi_trigger_command(serial_conn, "S 1 D 1 R 1\n")
            response *= send_roi_trigger_command(serial_conn, "A 1 AA $f $(length(buffer))\n")
            response *= send_roi_trigger_command(serial_conn, "A 1 DD 1 $(f * n_rois) $duty_percent 2 $n_rois 10\n")
            response *= send_roi_trigger_command(serial_conn, "A 1 DD 1 $(f * n_rois) $duty_percent 2 1 10\n")
            # response *= send_roi_trigger_command(serial_conn, "A 1 DD 1 $f $duty_percent 2 1 $duty_percent\n")
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
