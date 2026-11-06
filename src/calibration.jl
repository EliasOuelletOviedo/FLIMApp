"""
calibration.jl

The galvo calibration (the ROI popup's "Calibrate galvos" button,
gui/roi_popup.jl): which NI galvo voltages land on which pixel of the
microscope scanner's image. A galvo scan (`RasterRequest`) images the field
over a voltage range; registered on a scanner image — per axis, a scale and
an offset, the model of the ROIs' pixel -> voltage mapping (`to_voltage`) —
it gives the range that makes the two images coincide
(`calibrated_galvo_range`). Pure functions: no GUI, no hardware.

The registration (`register_galvo_on_scanner`) compares the two images
band-passed (`registration_image`: the cells, not the pixel noise nor the
illumination, which the two scanners don't share) with a masked normalized
cross-correlation (Padfield, IEEE TIP 2012) computed by FFT: for each
candidate scale, the best offset and its correlation; the scale is searched
on a grid (mirrors included), then refined per axis.
"""

using FFTW
using Statistics

"""
For a round of the calibration to be applied, its correlation peak must be
the only one (`calibration_refusal`): the best correlation away from it
(`second`, beyond the band-pass's scale) at most this fraction of it —
measured on two images of the same field 0.2 to 0.4, on unrelated ones 0.65
to 0.95 — and the peak at least `CALIBRATION_MIN_NCC`.
"""
const CALIBRATION_MAX_SECOND = 0.55
const CALIBRATION_MIN_NCC = 0.15

"""Round 2 scans round 1's range: it must find nearly the identity, or round 1 matched the wrong place."""
const CALIBRATION_ROUND2_MAX_SCALE = 0.1
const CALIBRATION_ROUND2_MAX_OFFSET_PX = 64.0

"""
    calibration_refusal(reg, round)::String

Why round `round`'s registration `reg` (`register_galvo_on_scanner`) can't
be applied ("" if it can): no unique correlation peak (too few photons,
another field, axes rotated or swapped), or, in round 2, a correction far
from the identity.
"""
function calibration_refusal(reg, round::Integer)::String
    r2(x) = Base.round(x; digits = 2)
    (reg.ncc >= CALIBRATION_MIN_NCC && reg.second <= CALIBRATION_MAX_SECOND * reg.ncc) ||
        return "the galvo scan doesn't match the scanner image: correlation $(r2(reg.ncc)), another offset gives " *
               "$(r2(reg.second)) (at most $(CALIBRATION_MAX_SECOND) of it for a match) — too few photons, another field, " *
               "or axes rotated or swapped?"
    if round >= 2
        (all(a -> abs(a - 1) <= CALIBRATION_ROUND2_MAX_SCALE, reg.a) && all(b -> abs(b) <= CALIBRATION_ROUND2_MAX_OFFSET_PX, reg.b)) ||
            return "round 2 finds scales $(r2.(reg.a)) and offsets $(r2.(reg.b)) px from round 1's range, not nearly the " *
                   "identity: round 1 matched the wrong place"
    end
    return ""
end

"""Band-pass of `registration_image`, in full-resolution pixels: pixel noise below, illumination above."""
const CALIBRATION_NOISE_PX = 4.0
const CALIBRATION_BACKGROUND_PX = 48.0

"""Sum of `k × k` blocks (the image cropped to a multiple of `k`)."""
function bin_image(img::AbstractMatrix{<:Real}, k::Integer)::Matrix{Float64}
    nx, ny = size(img) .÷ k
    out = zeros(Float64, nx, ny)
    @inbounds for j in 1:ny, i in 1:nx
        acc = 0.0
        for dj in 1:k, di in 1:k
            acc += img[(i - 1) * k + di, (j - 1) * k + dj]
        end
        out[i, j] = acc
    end
    return out
end

"""Separable Gaussian blur of standard deviation `σ` pixels, edges repeated."""
function gaussian_blur(img::AbstractMatrix{Float64}, σ::Real)::Matrix{Float64}
    σ > 0 || return copy(img)
    r = ceil(Int, 3σ)
    w = [exp(-k^2 / (2σ^2)) for k in -r:r]
    w ./= sum(w)
    nx, ny = size(img)
    along_x = similar(img)
    @inbounds for j in 1:ny, i in 1:nx
        acc = 0.0
        for k in -r:r
            acc += w[k + r + 1] * img[clamp(i + k, 1, nx), j]
        end
        along_x[i, j] = acc
    end
    out = similar(img)
    @inbounds for j in 1:ny, i in 1:nx
        acc = 0.0
        for k in -r:r
            acc += w[k + r + 1] * along_x[i, clamp(j + k, 1, ny)]
        end
        out[i, j] = acc
    end
    return out
end

"""
    registration_image(img, bin)

What the registration compares: the photon counts binned `bin × bin`, their
square root (the Poisson noise made even), band-passed by a difference of
Gaussians (`CALIBRATION_NOISE_PX`, `CALIBRATION_BACKGROUND_PX`).
"""
function registration_image(img::AbstractMatrix{<:Real}, bin::Integer)::Matrix{Float64}
    counts = sqrt.(bin_image(img, bin))
    return gaussian_blur(counts, CALIBRATION_NOISE_PX / bin) .- gaussian_blur(counts, CALIBRATION_BACKGROUND_PX / bin)
end

"""
    scaled_image(S, ax, ay) -> (W, M)

`S` resampled (bilinear) for `a` galvo pixels per scanner pixel on each
axis (negative: mirrored), around its center: `round(|a| × size)` pixels per
axis, with its support mask `M`. Pixel `w` of `W` is `S` at
`(w − c_W) / a + c_S` (0-based, `c` the centers).
"""
function scaled_image(S::AbstractMatrix{Float64}, ax::Real, ay::Real)
    nsx, nsy = size(S)
    wx, wy = max(2, round(Int, abs(ax) * nsx)), max(2, round(Int, abs(ay) * nsy))
    W, M = zeros(wx, wy), zeros(wx, wy)
    csx, csy, cwx, cwy = (nsx - 1) / 2, (nsy - 1) / 2, (wx - 1) / 2, (wy - 1) / 2
    @inbounds for j in 1:wy, i in 1:wx
        sx = (i - 1 - cwx) / ax + csx
        sy = (j - 1 - cwy) / ay + csy
        (0 <= sx <= nsx - 1 && 0 <= sy <= nsy - 1) || continue
        x0, y0 = min(floor(Int, sx), nsx - 2), min(floor(Int, sy), nsy - 2)
        fx, fy = sx - x0, sy - y0
        W[i, j] = (1 - fx) * (1 - fy) * S[x0 + 1, y0 + 1] + fx * (1 - fy) * S[x0 + 2, y0 + 1] +
                  (1 - fx) * fy * S[x0 + 1, y0 + 2] + fx * fy * S[x0 + 2, y0 + 2]
        M[i, j] = 1.0
    end
    return W, M
end

"""The fixed image of a masked cross-correlation (the galvo scan), its FFTs computed once for padding `P`."""
struct FixedImage
    P::Tuple{Int, Int}
    size::Tuple{Int, Int}
    f::Matrix{ComplexF64}           # rfft of F (its mask: every pixel)
    f2::Matrix{ComplexF64}          # rfft of F²
    mask::Matrix{ComplexF64}        # rfft of the mask
    count::Float64
end

pad_to(A::AbstractMatrix{Float64}, P::Tuple{Int, Int}) = (B = zeros(P); B[1:size(A, 1), 1:size(A, 2)] .= A; B)

FixedImage(F::Matrix{Float64}, P::Tuple{Int, Int}) =
    FixedImage(P, size(F), rfft(pad_to(F, P)), rfft(pad_to(F .^ 2, P)), rfft(pad_to(ones(size(F)), P)), length(F))

"""
    best_shift(fixed, W, M; min_overlap=0.5, exclusion=6) -> (ncc, t, z, second)

The shift `t` (moving pixel `w` lands on fixed pixel `w + t`) that maximizes
the masked normalized cross-correlation of the moving image `W` (support
`M`) with `fixed`, over overlaps of at least `min_overlap` of the smaller
image; `t` refined below the pixel by a parabola on each axis. `z`: how far
the peak stands above the other shifts' correlations, in standard
deviations; `second`: the best correlation more than `exclusion` pixels
away from the peak on an axis.
"""
function best_shift(fixed::FixedImage, W::Matrix{Float64}, M::Matrix{Float64}; min_overlap::Real = 0.5, exclusion::Integer = 6)
    P = fixed.P
    mw, mw2, mm = rfft(pad_to(W .* M, P)), rfft(pad_to(W .^ 2 .* M, P)), rfft(pad_to(M, P))
    corr(a, b) = irfft(a .* conj.(b), P[1])          # Σₓ A(x) B(x − t), at t mod P
    n, sF, sM = corr(fixed.mask, mm), corr(fixed.f, mm), corr(fixed.mask, mw)
    sFF, sMM, sFM = corr(fixed.f2, mm), corr(fixed.mask, mw2), corr(fixed.f, mw)
    nmin = min_overlap * min(fixed.count, sum(M))
    ncc = fill(-Inf, P)
    @inbounds for k in eachindex(ncc)
        nk = n[k]
        nk >= nmin || continue
        vf = sFF[k] - sF[k]^2 / nk
        vm = sMM[k] - sM[k]^2 / nk
        (vf > 1e-9 && vm > 1e-9) || continue
        ncc[k] = (sFM[k] - sF[k] * sM[k] / nk) / sqrt(vf * vm)
    end
    i, j = Tuple(argmax(ncc))
    peak = ncc[i, j]
    isfinite(peak) || return (ncc = -Inf, t = (0.0, 0.0), z = 0.0, second = -Inf)
    valid = filter(isfinite, ncc)
    spread = length(valid) > 1 ? std(valid) : 0.0
    z = spread > 0 ? (peak - mean(valid)) / spread : 0.0
    # The best correlation away from the peak (beyond `exclusion` pixels on an axis).
    second = -Inf
    @inbounds for jj in 1:P[2], ii in 1:P[1]
        v = ncc[ii, jj]
        (isfinite(v) && v > second) || continue
        (min(mod(ii - i, P[1]), mod(i - ii, P[1])) > exclusion || min(mod(jj - j, P[2]), mod(j - jj, P[2])) > exclusion) &&
            (second = v)
    end
    function subpixel(before, after)
        (isfinite(before) && isfinite(after)) || return 0.0
        d = before - 2peak + after
        return d < 0 ? clamp((before - after) / (2d), -0.5, 0.5) : 0.0
    end
    dx = subpixel(ncc[mod1(i - 1, P[1]), j], ncc[mod1(i + 1, P[1]), j])
    dy = subpixel(ncc[i, mod1(j - 1, P[2])], ncc[i, mod1(j + 1, P[2])])
    shift(i, N, nf) = i - 1 <= nf - 1 ? i - 1 : i - 1 - N   # index -> shift (negative ones wrap around)
    return (ncc = peak, t = (shift(i, P[1], fixed.size[1]) + dx, shift(j, P[2], fixed.size[2]) + dy), z = z, second = second)
end

"""
    register_galvo_on_scanner(scanner, galvo; bin=4, scales=(0.2, 2.5), steps=33, mirrors=true)
        -> (a, b, ncc, z, second)

Where a scanner image lies in a galvo scan (photon counts, FLIMApp's `(x, y)`
layout, the two channels summed): on each axis, galvo pixel `g = a s + b`
for scanner pixel `s` (0-based, full resolution), `a` the galvo pixels per
scanner pixel — negative if the axis is mirrored —, `ncc` the
correlation of the two band-passed images there (−1 to 1); `z` and
`second`, how far it stands above the other offsets' (`best_shift`,
`calibration_refusal`). First `steps`
scales from `scales[1]` to `scales[2]` (log spaced, the same on both axes,
each mirror combination with `mirrors`) on images binned to about 128
pixels; then each axis refined at `bin × bin` binning, by a pattern search
down to 0.1 %.
"""
function register_galvo_on_scanner(scanner::AbstractMatrix{<:Real}, galvo::AbstractMatrix{<:Real};
                                   bin::Integer = 4, scales::Tuple{Real, Real} = (0.2, 2.5), steps::Integer = 33,
                                   mirrors::Bool = true)
    lo, hi = scales
    function evaluator(b)
        S, G = registration_image(scanner, b), registration_image(galvo, b)
        P = Tuple(nextprod([2, 3, 5], size(G, d) + ceil(Int, 1.2 * hi * size(S, d))) for d in 1:2)
        fixed = FixedImage(G, P)
        return S, function (ax, ay)
            W, M = scaled_image(S, ax, ay)
            r = best_shift(fixed, W, M; exclusion = max(3, round(Int, CALIBRATION_BACKGROUND_PX / b)))
            return (ncc = r.ncc, t = r.t, z = r.z, second = r.second, ax = ax, ay = ay, w = size(W))
        end
    end
    _, coarse = evaluator(max(bin, minimum(size(galvo)) ÷ 128))
    best = (ncc = -Inf,)
    for (sx, sy) in (mirrors ? ((1, 1), (-1, 1), (1, -1), (-1, -1)) : ((1, 1),)),
        a in exp.(range(log(lo), log(hi); length = steps))
        r = coarse(sx * a, sy * a)
        r.ncc > best.ncc && (best = r)
    end
    isfinite(best.ncc) || error("the scanner image and the galvo scan don't overlap at any scale tried")
    # At `bin`, each axis on its own: steps of 4 %, 1 %, 0.25 % then 0.1 % while the correlation improves.
    S, fine = evaluator(bin)
    best = fine(best.ax, best.ay)
    for factor in (1.04, 1.01, 1.0025, 1.001)
        improved = true
        while improved
            improved = false
            for (fx, fy) in ((factor, 1), (1 / factor, 1), (1, factor), (1, 1 / factor))
                ax, ay = best.ax * fx, best.ay * fy
                (lo / 1.15 <= abs(ax) <= 1.15 * hi && lo / 1.15 <= abs(ay) <= 1.15 * hi) || continue
                r = fine(ax, ay)
                r.ncc > best.ncc + 1e-6 && (best = r; improved = true)
            end
        end
    end
    # Binned (0-based, centers) g' = a (s' − c_S) + c_W + t; then full resolution (pixel k of the
    # binned image is centered on bin·k + (bin − 1)/2).
    a = (best.ax, best.ay)
    b = ntuple(d -> begin
        b_binned = (best.w[d] - 1) / 2 + best.t[d] - a[d] * (size(S, d) - 1) / 2
        bin * b_binned + (bin - 1) / 2 * (1 - a[d])
    end, 2)
    return (a = a, b = b, ncc = best.ncc, z = best.z, second = best.second)
end

"""
    calibrated_galvo_range(range_mV, reg, scanner_size; galvo_size, calibration_size)
        -> (v_min_x, v_max_x, v_min_y, v_max_y)

The galvo range (mV) that puts each pixel of a scanner image of
`scanner_size` where the registration `reg` (`register_galvo_on_scanner`)
found it in a galvo scan of `galvo_size` taken over `range_mV`, in the
ROIs' own mapping (`roi_scan_segments`): a scanner image smaller than
`calibration_size` sits centered in the calibration frame. With the galvo
scan's pixel `g` at `to_voltage(g, galvo_size, u_min, u_max)` and scanner
pixel `s` at `g = a s + b`: `v_max − v_min = a (u_max − u_min)
(calibration_size − 1) / (galvo_size − 1)`, `v_min = u_min + (b − a shift)
(u_max − u_min) / (galvo_size − 1)`, `shift` the centering.
"""
function calibrated_galvo_range(range_mV, reg, scanner_size::Tuple{Int, Int};
                                galvo_size::Tuple{Int, Int} = (roi_voltage_calibration_size, roi_voltage_calibration_size),
                                calibration_size::Integer = roi_voltage_calibration_size)::NTuple{4, Int}
    v = ntuple(4) do k
        d = (k + 1) ÷ 2
        u_min, u_max = range_mV[2d - 1], range_mV[2d]
        du = (u_max - u_min) / (galvo_size[d] - 1)
        shift = (calibration_size - scanner_size[d]) / 2
        v_min = u_min + (reg.b[d] - reg.a[d] * shift) * du
        isodd(k) ? v_min : v_min + reg.a[d] * du * (calibration_size - 1)
    end
    return round.(Int, v)
end

"""
    galvo_on_scanner(galvo, reg, scanner_size) -> Matrix{Float64}

The galvo scan resampled on the scanner image's pixels (bilinear, 0 where
the scan doesn't reach), through the registration `reg`: what the
calibration overlay shows on the scanner image.
"""
function galvo_on_scanner(galvo::AbstractMatrix{<:Real}, reg, scanner_size::Tuple{Int, Int})::Matrix{Float64}
    ngx, ngy = size(galvo)
    out = zeros(scanner_size)
    @inbounds for j in 1:scanner_size[2], i in 1:scanner_size[1]
        gx = reg.a[1] * (i - 1) + reg.b[1]
        gy = reg.a[2] * (j - 1) + reg.b[2]
        (0 <= gx <= ngx - 1 && 0 <= gy <= ngy - 1) || continue
        x0, y0 = min(floor(Int, gx), ngx - 2), min(floor(Int, gy), ngy - 2)
        fx, fy = gx - x0, gy - y0
        out[i, j] = (1 - fx) * (1 - fy) * galvo[x0 + 1, y0 + 1] + fx * (1 - fy) * galvo[x0 + 2, y0 + 1] +
                    (1 - fx) * fy * galvo[x0 + 1, y0 + 2] + fx * fy * galvo[x0 + 2, y0 + 2]
    end
    return out
end
