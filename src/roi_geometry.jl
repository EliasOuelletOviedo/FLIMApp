"""
roi_geometry.jl

Pure ROI scan geometry, shared by the GUI thread (visiting order at START),
the DAQ loop (slot pattern, loop/scan_pattern.jl) and the analysis worker
(which ROI a file belongs to): the uniform-density spiral that follows a
ROI's shape, the shortest visiting order across ROI centers, and the
pixel -> galvo voltage mapping. No state, no hardware.

The galvo voltage range (`v_min_x`/`v_max_x`/`v_min_y`/`v_max_y`, mV)
lives on `app.roi` (`RoiSettings`) and the spiral parameters on
`app.protocol` (`ProtocolSettings`), both GUI-editable and persisted; they
reach this code through a `ScanRequest` (exchange.jl) built at START.
"""

using Statistics

# =============================================================================
# TUNABLE PARAMETERS
# =============================================================================
# Plain variable, not `const` — meant to be hand-edited in this file
# (not promoted to config.jl) as the galvo setup is tuned.

# Reference image size (pixels, square) the galvo voltage range (app.roi)
# was calibrated against: a 1024x1024 image maps its full pixel extent onto
# the full voltage range. Real acquisitions are always 1024 wide but can be
# shorter than 1024 tall (e.g. a 1024x512 scan) — rather than rescale a
# shorter image to fill the full voltage range (which would use a
# *different* voltage-per-pixel scale than this calibration),
# roi_scan_segments shifts a shorter image's ROI coordinates so they sit
# centered within this same 1024x1024 reference frame before converting to
# voltage, using the actual imported image size (app_run.imported_image_size,
# recorded at import time by roi_popup.jl) to compute that shift — matching
# roi_popup.jl's own canvas-centering (image_offset) for the on-screen
# display of that same image.
roi_voltage_calibration_size = 1024

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
# FROM ROIS TO GALVO PATH
# =============================================================================

# Pixel coordinate -> galvo voltage (mV): linear over the image span,
# sign-flipped for the galvo's mirrored axis convention.
to_voltage(coord::Real, n_pixels::Real, v_min::Real, v_max::Real) =
    -(v_min + (coord - 1) * (v_max - v_min) / (n_pixels - 1))

"""
    roi_visit_order(rois)::Vector{Int}

Indices into `rois` in the order the scan visits them: the shortest cycle
across ROI centers (`optimize_centers`), starting with ROI 1. The DAQ loop
plays the ROIs in this order and the analysis attributes the k-th file of
each cycle to `rois[order[k]]` — the same order on both sides, which is
what keeps each result on the ROI that was actually scanned. Exponential in
the ROI count (Held-Karp): computed once per START, off the GUI thread.
"""
function roi_visit_order(rois::Vector{RoiCoordinates})::Vector{Int}
    centers = [centroid_center(roi.xs, roi.ys) for roi in rois]
    ordered = optimize_centers(centers)
    used = falses(length(rois))
    order = Int[]
    for c in ordered
        # Two ROIs can share a center: take the first one not used yet.
        idx = findfirst(i -> !used[i] && centers[i] == c, eachindex(centers))
        used[idx] = true
        push!(order, idx)
    end
    return order
end

"""
    roi_scan_segments(request::ScanRequest)

The galvo path for `request.rois` in `request.order`, in mV: one
`(; roi_index, center, points)` per visit, where `points` is a
uniform-density spiral scan of that ROI's shape (`shape_spiral_points`,
`request.points_per_roi` points, `request.spiral_turns` turns) starting
near `center`.

The ROI coordinates are in `request.image_size`'s own pixel space, which
can be shorter (in height) than `roi_voltage_calibration_size`'s 1024x1024
calibration reference — shifted to sit centered within that reference frame
before conversion to voltage; see that constant's comment for why.
"""
function roi_scan_segments(request::ScanRequest)
    image_width, image_height = request.image_size
    x_shift = (roi_voltage_calibration_size - image_width) / 2
    y_shift = (roi_voltage_calibration_size - image_height) / 2
    vx(x) = to_voltage(x + x_shift, roi_voltage_calibration_size, request.v_min_x, request.v_max_x)
    vy(y) = to_voltage(y + y_shift, roi_voltage_calibration_size, request.v_min_y, request.v_max_y)

    segments = NamedTuple{(:roi_index, :center, :points), Tuple{Int, Tuple{Int64,Int64}, Vector{Tuple{Int64,Int64}}}}[]

    for roi_index in request.order
        roi = request.rois[roi_index]
        cx, cy = centroid_center(roi.xs, roi.ys)
        center_v = (round(Int64, vx(cx)), round(Int64, vy(cy)))
        points = shape_spiral_points(request.points_per_roi, vx.(roi.xs), vy.(roi.ys); center=center_v, turns=request.spiral_turns)
        push!(segments, (; roi_index, center = center_v, points))
    end

    return segments
end
