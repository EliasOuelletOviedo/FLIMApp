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
and persisted, via the Protocol panel (handlers_protocol.jl). The remaining
tunables below stay plain (non-persisted) module variables, hand-edited
directly in this file.

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

# Full image pixel dimensions the ROIs were drawn against — needed to map
# pixel coordinates to the trigger box's voltage range below. Must match
# the actual imported/displayed image (roi_popup.jl); update if that changes.
roi_image_width = 1024
roi_image_height = 1024

# Galvo output voltage range for each axis.
trigger_box_v_min_x = -1000
trigger_box_v_max_x = 1000
trigger_box_v_min_y = -500
trigger_box_v_max_y = 500

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
    sleep(1e-6)
    return strip(read(serial_conn, String))
end

function send_roi_trigger_points!(serial_conn, pts::Vector{Tuple{Int64,Int64}})
    response = send_roi_trigger_command(serial_conn, "C Z\n")
    occursin("ERR", response) && @warn "Trigger box error clearing buffer" response=response

    for (idx, (x, y)) in enumerate(pts)
        response = send_roi_trigger_command(serial_conn, "A 0 AB 1 $idx $x\n")
        occursin("ERR", response) && @warn "Trigger box error setting buffer point" axis=1 idx=idx value=x response=response

        response = send_roi_trigger_command(serial_conn, "A 0 AB 2 $idx $y\n")
        occursin("ERR", response) && @warn "Trigger box error setting buffer point" axis=2 idx=idx value=y response=response
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
    roi_trigger_buffer(app, rois::Vector{RoiCoordinates})::Vector{Tuple{Int64,Int64}}

Build the galvo trigger-box scan buffer for `rois`, in voltage units: an
optimized-order tour across ROI centers (`optimize_centers`), each followed
by a uniform-density spiral scan of that ROI's shape
(`shape_spiral_points`), with a settle dwell before entering each ROI after
the first, and a final dwell back at the first ROI's center to close the
cycle. Scan timing (`app.protocol.points_per_roi`/`.spiral_turns`/
`.scan_time`/`.shift_time`) is read from `app` — GUI-editable via the
Protocol panel, handlers_protocol.jl.
"""
function roi_trigger_buffer(app, rois::Vector{RoiCoordinates})::Vector{Tuple{Int64,Int64}}
    isempty(rois) && return Tuple{Int64,Int64}[]

    points_per_roi = app.protocol.points_per_roi
    dwell_points = round(Int, app.protocol.shift_time / app.protocol.scan_time * points_per_roi)

    centers = [centroid_center(roi.xs, roi.ys) for roi in rois]
    ordered_centers = optimize_centers(centers)
    ordered_rois = [rois[findfirst(==(c), centers)] for c in ordered_centers]

    buffer = Tuple{Int64,Int64}[]
    first_center_v = nothing

    for roi in ordered_rois
        cx, cy = centroid_center(roi.xs, roi.ys)
        center_v = (
            round(Int64, to_voltage(cx, roi_image_width, trigger_box_v_min_x, trigger_box_v_max_x)),
            round(Int64, to_voltage(cy, roi_image_height, trigger_box_v_min_y, trigger_box_v_max_y))
        )

        xs_v = [to_voltage(x, roi_image_width, trigger_box_v_min_x, trigger_box_v_max_x) for x in roi.xs]
        ys_v = [to_voltage(y, roi_image_height, trigger_box_v_min_y, trigger_box_v_max_y) for y in roi.ys]

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
connected, or no ROIs are drawn. Errors are logged and swallowed, not
raised — a trigger-box upload failure shouldn't block acquisition from
starting.
"""
function build_and_send_roi_trigger_buffer!(app, app_run)
    if !app.roi.active
        return nothing
    end

    serial_conn = app_run.serial_conn
    if serial_conn === nothing
        @info "ROI mode is active but no serial device is connected; skipping trigger-box upload"
        return nothing
    end

    rois = app_run.rois[]
    if isempty(rois)
        @info "ROI mode is active but no ROIs are drawn; skipping trigger-box upload"
        return nothing
    end

    try
        @info "Building ROI trigger-box scan buffer" n_rois=length(rois) points_per_roi=app.protocol.points_per_roi
        buffer = roi_trigger_buffer(app, rois)

        @info "Uploading ROI trigger-box scan buffer" n_points=length(buffer)
        send_roi_trigger_points!(serial_conn, buffer)

        scan_time = app.protocol.scan_time
        shift_time = app.protocol.shift_time
        n_rois = length(rois)
        f = 1000.0 / ((scan_time + shift_time) * n_rois)
        duty_percent = 100 - round(Int64, 100 * shift_time / (shift_time + scan_time))

        response = send_roi_trigger_command(serial_conn, "S 1 D 1 R 1\n")
        response *= send_roi_trigger_command(serial_conn, "A 1 AA $f $(length(buffer))\n")
        response *= send_roi_trigger_command(serial_conn, "A 1 DD 2 $(f * n_rois) $duty_percent 1 $n_rois 10\n")
        response *= send_roi_trigger_command(serial_conn, "A 0 DO 3 1\n")

        if occursin("ERR", response)
            @warn "Trigger box error arming playback timing" response=response
        else
            @info "ROI trigger-box scan buffer uploaded and armed"
        end
    catch e
        @error "Failed to build/send ROI trigger-box scan buffer" error=string(e)
    end

    return nothing
end
