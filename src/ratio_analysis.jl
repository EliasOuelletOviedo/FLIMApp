"""
ratio_analysis.jl

Ratiometric analysis: reducing multi-channel images to a per-region intensity
ratio, converting that ratio to a concentration, and rasterizing ROI polygons
into the pixel masks those reductions run over.

This replaces lifetime_analysis.jl wholesale. Where the FLIM pipeline turned a
TCSPC decay histogram into a lifetime through an iterative MLE reconvolution
fit — the single most expensive step in the old acquisition loop, and the
reason for the JIT warmup at startup — the ratiometric pipeline reduces each
channel to a mean over a region and divides. There is no fit, no IRF, and no
warmup: the arithmetic here is a sum and a division.

The consequence for the acquisition loop is that reading pixels is no longer
cheap relative to analyzing them. A 1024x1024 frame reads in ~0.08 ms and
reduces in ~0.3 ms, where an SDT histogram read in microseconds and fit in
tens of milliseconds. Everything in this file is therefore written to run over
raw integer buffers without allocating or converting to floating point until
the very last step.
"""

# =============================================================================
# CHANNEL RATIO SELECTION
# =============================================================================

"""
    RATIO_COMBINATION_OPTIONS

The six ordered channel pairs offered by the ratio menu (GUI.jl), which
occupies the slot the "1/2/3 lifetimes" menu used to.

All six are always offered regardless of how many channels the acquisition
actually writes. A combination naming a channel that does not exist yields a
`NaN` ratio rather than refusing to start — the per-channel intensity series
stay meaningful and plottable either way, so there is no reason to block a
run over it. See `ratio_from_means`.

Order is fixed and must stay stable: `LayoutSettings.ratio_combination`
persists the *label*, so reordering or renaming these silently changes what a
saved session reloads as.
"""
const RATIO_COMBINATION_OPTIONS = ["C1/C2", "C1/C3", "C2/C1", "C2/C3", "C3/C1", "C3/C2"]

"""
    DEFAULT_RATIO_COMBINATION

Combination used before the user picks one, and the fallback whenever a
persisted or menu-supplied label cannot be parsed.
"""
const DEFAULT_RATIO_COMBINATION = "C1/C2"

"""
    parse_ratio_combination(label) -> (numerator_channel, denominator_channel)

Split a `RATIO_COMBINATION_OPTIONS` label into its two 1-based channel
indices. Falls back to `DEFAULT_RATIO_COMBINATION`'s indices for anything
unparseable, so a corrupted saved state degrades to a sensible default
instead of throwing on startup.
"""
function parse_ratio_combination(label::AbstractString)::Tuple{Int, Int}
    m = match(r"^C(\d+)/C(\d+)$", strip(label))
    m === nothing && return (1, 2)
    return (parse(Int, m.captures[1]), parse(Int, m.captures[2]))
end

"""
    ratio_from_means(channel_means, combination_label, channel_numbers) -> Float64

The ratio for one region, from that region's per-channel mean intensities.

`channel_numbers` maps positions in `channel_means` to the channel numbers
the acquisition actually writes (`[1, 3]` for a run with `C1` and `C3`
directories). The combination label names channels, not positions, so it must
be resolved through this rather than used to index directly — an acquisition
skipping `C2` puts channel 3 at position 2, and indexing by name would either
read the wrong channel or fall off the end. A third of the real sessions
surveyed are exactly this shape.

Returns `NaN` — the pipeline's standard "no value" sentinel, which the plots
and the PI controller both already handle — when the combination names a
channel the acquisition does not provide, or when the denominator is zero or
non-finite. A zero denominator is a real possibility on 8-bit data in a dark
region, and must not become `Inf`: an `Inf` would propagate through the
Kalman smoother and poison the series long after the dark frame passed.
"""
function ratio_from_means(channel_means::AbstractVector{Float64}, combination_label::AbstractString,
                          channel_numbers::AbstractVector{Int})::Float64
    num_channel, den_channel = parse_ratio_combination(combination_label)

    num_idx = findfirst(==(num_channel), channel_numbers)
    den_idx = findfirst(==(den_channel), channel_numbers)

    (num_idx === nothing || den_idx === nothing) && return NaN
    (num_idx <= length(channel_means) && den_idx <= length(channel_means)) || return NaN

    numerator = channel_means[num_idx]
    denominator = channel_means[den_idx]

    isfinite(numerator) || return NaN
    (isfinite(denominator) && denominator != 0.0) || return NaN

    return numerator / denominator
end

# =============================================================================
# RATIO -> CONCENTRATION CALIBRATION
# =============================================================================

"""
Hill calibration constants mapping a measured intensity ratio to a
concentration.

**Provisional.** These are placeholders pending a real calibration; they are
gathered here, as named constants, so replacing the calibration means editing
this block and `hill_ratio_to_concentration` below and nothing else.

- `HILL_KD`   — apparent dissociation constant, in the concentration unit the
                plot is labelled with
- `HILL_N`    — Hill coefficient (cooperativity)
- `HILL_RMIN` — ratio at zero concentration
- `HILL_RMAX` — ratio at saturating concentration
"""
const HILL_KD   = 46.4
const HILL_N    = 1.21
const HILL_RMIN = 0.55
const HILL_RMAX = 1.86

"""
    hill_ratio_to_concentration(ratio) -> Float64

Invert the Hill binding curve to recover a concentration from a measured
ratio:

    [X] = K_D * ((R - Rmin) / (Rmax - R))^(1/n)

`ratio` is clamped into the open interval `(Rmin, Rmax)` before inversion
rather than being rejected outside it. The inversion diverges at `Rmax` and is
undefined below `Rmin`, so an uncalibrated or merely noisy ratio — entirely
expected on 8-bit data, and near-certain before the calibration constants
above are replaced with real ones — would otherwise punch `NaN`/`Inf` holes
through the plotted series. Clamping saturates the curve at its ends instead,
keeping the series continuous and readable, at the cost of flattening values
that stray outside the calibrated range.

A non-finite input is still passed through as `NaN`: that means "no
measurement", which is different from "a measurement outside the calibrated
range" and must not be silently turned into a concentration.
"""
function hill_ratio_to_concentration(ratio::Real)::Float64
    isfinite(ratio) || return NaN

    span = HILL_RMAX - HILL_RMIN
    span > 0 || return NaN

    margin = eps(Float64) * max(1.0, abs(HILL_RMAX))
    clamped = clamp(Float64(ratio), HILL_RMIN + margin, HILL_RMAX - margin)

    return HILL_KD * ((clamped - HILL_RMIN) / (HILL_RMAX - clamped))^(1 / HILL_N)
end

"""
    hill_concentration_to_ratio(concentration) -> Float64

Forward Hill curve, the inverse of `hill_ratio_to_concentration`:

    R = Rmin + (Rmax - Rmin) * [X]^n / (K_D^n + [X]^n)

Not used by the control loop — protocol setpoints are expressed directly in
ratio units, so no conversion sits between the setpoint and the PI error.
Kept because it is the natural way to turn a concentration of interest into
the setpoint to type in, and because having both directions available makes
the calibration testable as a round trip.
"""
function hill_concentration_to_ratio(concentration::Real)::Float64
    isfinite(concentration) && concentration >= 0 || return NaN

    x = Float64(concentration)^HILL_N
    kd = Float64(HILL_KD)^HILL_N

    return HILL_RMIN + (HILL_RMAX - HILL_RMIN) * x / (kd + x)
end

# =============================================================================
# REGION MASKS
# =============================================================================

"""
    RegionMask

A set of pixels to reduce over, stored as precomputed **linear indices** into
an image laid out `[x, y]` (width-major, matching `BigTiffFile.read_frame`).

Linear indices rather than a `BitMatrix`: the reduction runs once per channel
per frame, and iterating a dense boolean mask over a 1024x1024 image costs a
full megapixel scan even when the ROI covers a hundredth of it. An index list
touches only the pixels that matter and stays contiguous in cache.

An **empty** `indices` vector is the "whole image" region, which is what
non-ROI acquisition uses — reducing over every pixel needs no index list at
all, and materializing a million-entry vector to say so would waste both the
memory and the indirection. `region_sum` branches on this.

Masks are built once, when the ROI set or the image geometry changes, never
per frame — see `build_region_masks`.
"""
struct RegionMask
    name::String
    indices::Vector{Int32}
    pixel_count::Int
end

"""
    whole_image_mask(width, height)

The `RegionMask` covering every pixel — the region used when ROI processing
is off.
"""
whole_image_mask(width::Integer, height::Integer) = RegionMask("Full frame", Int32[], Int(width) * Int(height))

"""
    point_in_polygon(x, y, xs, ys) -> Bool

Ray-casting point-in-polygon test: count how many polygon edges a ray cast in
`+x` from `(x, y)` crosses; an odd count means inside.

`xs`/`ys` are a closed loop (last point equal to first), matching
`RoiCoordinates`'s convention. The closing segment is therefore already
present in the vectors and is not re-added here.

The `(ys[i] > y) != (ys[j] > y)` guard is the standard half-open crossing
rule: it counts an edge only when the two endpoints straddle the ray, which
keeps a vertex lying exactly on the ray from being counted twice and makes
the test consistent for pixels on a shared border between adjacent ROIs.
"""
function point_in_polygon(x::Real, y::Real, xs::AbstractVector{<:Real}, ys::AbstractVector{<:Real})::Bool
    n = length(xs)
    n >= 3 || return false

    inside = false
    j = n

    @inbounds for i in 1:n
        yi = ys[i]
        yj = ys[j]

        if (yi > y) != (yj > y)
            # x coordinate where edge (j -> i) crosses the horizontal line at y
            crossing_x = xs[i] + (y - yi) / (yj - yi) * (xs[j] - xs[i])
            if x < crossing_x
                inside = !inside
            end
        end

        j = i
    end

    return inside
end

"""
    roi_pixel_indices(roi, width, height) -> Vector{Int32}

Rasterize one ROI polygon to the linear indices of the pixels inside it.

`roi`'s `xs`/`ys` are in the underlying image's own **0-based** pixel
coordinates (see `RoiCoordinates`, data_types.jl), while the returned indices
address a 1-based Julia array laid out `[x, y]`. Pixel `(i, j)` 0-based maps
to linear index `j * width + i + 1`.

Each pixel is tested at its **center** (`i + 0.5`, `j + 0.5`) rather than its
corner. Testing corners biases every ROI half a pixel up and left, which is
invisible on a large ROI and material on a small one.

Only the polygon's bounding box is scanned, so cost scales with the ROI
rather than with the image — the difference between thousands and a million
tests for a typical cell-sized ROI.
"""
function roi_pixel_indices(roi::RoiCoordinates, width::Integer, height::Integer)::Vector{Int32}
    indices = Int32[]

    xs = roi.xs
    ys = roi.ys
    (length(xs) >= 3 && length(xs) == length(ys)) || return indices

    w = Int(width)
    h = Int(height)

    # Bounding box, clipped to the image. `floor`/`ceil` widen to whole
    # pixels so a polygon edge cutting through a pixel still gets that pixel
    # tested at its center.
    min_x = max(0, floor(Int, minimum(xs)))
    max_x = min(w - 1, ceil(Int, maximum(xs)))
    min_y = max(0, floor(Int, minimum(ys)))
    max_y = min(h - 1, ceil(Int, maximum(ys)))

    (min_x > max_x || min_y > max_y) && return indices

    sizehint!(indices, (max_x - min_x + 1) * (max_y - min_y + 1) ÷ 2)

    @inbounds for j in min_y:max_y
        row_base = j * w
        for i in min_x:max_x
            if point_in_polygon(i + 0.5, j + 0.5, xs, ys)
                push!(indices, Int32(row_base + i + 1))
            end
        end
    end

    return indices
end

"""
    build_region_masks(rois, width, height; use_spatial_masks) -> Vector{RegionMask}

The regions each frame is reduced over, for a given ROI set and image size.

`use_spatial_masks` selects between the two ROI models this app supports (see
TIFFApp_SPEC.md section 3):

- **`true`** — every image contains every ROI, so each ROI becomes its own
  pixel mask and all of them are updated from every frame. This is the plain
  widefield case, and the returned vector has one entry per drawn ROI.
- **`false`** — the galvo visits one ROI per instance, so the image *is* that
  ROI and there is nothing to mask: exactly one whole-image region is
  returned regardless of how many ROIs are drawn. Which ROI's series the
  resulting values belong to is decided downstream by `next_roi_slot!`
  (acquisition.jl), from the instance's position in the scan sequence.

An empty ROI set yields a single whole-image region in both modes, matching
`AppRun`'s "one series when no ROIs are drawn" convention.

A ROI that rasterizes to zero pixels (drawn outside the image, or degenerate)
falls back to the whole image with a warning rather than producing a region
whose every reduction is `NaN`.
"""
function build_region_masks(rois::AbstractVector{RoiCoordinates}, width::Integer, height::Integer;
                            use_spatial_masks::Bool)::Vector{RegionMask}
    if isempty(rois) || !use_spatial_masks
        return [whole_image_mask(width, height)]
    end

    masks = Vector{RegionMask}(undef, length(rois))

    for (i, roi) in enumerate(rois)
        indices = roi_pixel_indices(roi, width, height)

        if isempty(indices)
            @warn "ROI covers no pixels of the image; reducing over the whole frame instead" roi=roi.name image_size=(width, height)
            masks[i] = RegionMask(roi.name, Int32[], Int(width) * Int(height))
        else
            masks[i] = RegionMask(roi.name, indices, length(indices))
        end
    end

    return masks
end

# =============================================================================
# REDUCTIONS
# =============================================================================

"""
    region_sum(image, mask) -> UInt64

Sum `image`'s samples over `mask`'s pixels.

Accumulates in `UInt64` because the caller's `image` is already a *binned*
sum: up to 50 frames of 16-bit samples over a megapixel region reaches ~10^11,
far past what `UInt32` holds. The accumulator is the only place this could
overflow silently, so it is sized for the worst case the buffer allows rather
than for the 8-bit data seen today.

The empty-`indices` case sums the whole image directly — see `RegionMask` for
why "whole image" is represented by an absent index list rather than a
complete one.
"""
function region_sum(image::AbstractVector{T}, mask::RegionMask)::UInt64 where {T<:Unsigned}
    total = UInt64(0)

    if isempty(mask.indices)
        @inbounds @simd for i in eachindex(image)
            total += UInt64(image[i])
        end
        return total
    end

    @inbounds @simd for k in eachindex(mask.indices)
        total += UInt64(image[mask.indices[k]])
    end

    return total
end

"""
    region_mean(image, mask, frames_summed) -> Float64

Mean sample value over `mask`, undoing the temporal binning.

`image` holds `frames_summed` frames added together (the acquisition's
sliding-window sum), so dividing by both the pixel count and the frame count
recovers a per-frame, per-pixel mean — the quantity the ratio is formed from.

This is the "ratio of means" reduction: each channel is averaged over the
region first, and the division happens once, on two scalars. Averaging
per-pixel ratios instead would need a validity threshold to survive dark
pixels, and would not agree with this except on noiseless data.
"""
function region_mean(image::AbstractVector{T}, mask::RegionMask, frames_summed::Integer)::Float64 where {T<:Unsigned}
    (mask.pixel_count > 0 && frames_summed > 0) || return NaN
    return Float64(region_sum(image, mask)) / (mask.pixel_count * frames_summed)
end
