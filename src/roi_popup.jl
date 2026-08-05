"""
roi_popup.jl

ROI popup: import a FLIM image from an .sdt file, import ROIs from ImageJ
.roi/.zip files (via ImageJROI.jl), display both on `image_axis`, and clear
the imported ROI overlays on demand.
"""

"""
Fraction of the image's total intensity a row parity (all odd- or all
even-indexed rows) may carry and still be considered "padding" in
`collapse_padded_rows`. Real SDT files don't zero out the padded parity
exactly — dark counts/crosstalk leak a little signal in — so an exact
`== 0` check never fires; on a real 1024x512-scanned file the padded
parity carried ~0.55% of the total intensity (54803 vs 9854174 counts),
well under this threshold, while a genuine full-height scan has real
signal split across both parities (nowhere near this small).
"""
const PADDED_ROW_ENERGY_FRACTION = 0.05

"""
    padded_row_keep_range(image::Matrix{Float64})::AbstractVector{Int}

Row indices (into dim 2 of `image`) that `collapse_padded_rows` would keep
— exposed separately so the same row selection can also be applied to the
raw per-pixel time-bin volume (see `extract_sdt_volume`), keeping the
displayed image and the data used for ROI lifetime fitting in sync.
"""
function padded_row_keep_range(image::Matrix{Float64})::AbstractVector{Int}
    n_rows = size(image, 2)
    n_rows < 2 && return 1:n_rows

    odd_total  = sum(@view image[:, 1:2:n_rows])
    even_total = sum(@view image[:, 2:2:n_rows])
    total = odd_total + even_total
    total == 0 && return 1:n_rows

    if even_total / total < PADDED_ROW_ENERGY_FRACTION
        return 1:2:n_rows
    elseif odd_total / total < PADDED_ROW_ENERGY_FRACTION
        return 2:2:n_rows
    else
        return 1:n_rows
    end
end

"""
    active_bounding_box(intensity::Matrix{Float64})::Tuple{UnitRange{Int}, UnitRange{Int}}

`(x_range, y_range)`, each `1:n`, covering the smallest top-left-anchored
rectangle holding essentially all of `intensity`'s total — a *different*
padding pattern than `padded_row_keep_range`'s interleaved rows: some real
acquisitions from this lab store a smaller true scan inside a larger fixed
buffer as one contiguous block (e.g. a real 2048x2048-stored file whose
actual content occupied only columns 1:1062, rows 1:1048 — confirmed on a
real file: *exactly* zero beyond that box, 100% of the total intensity
inside it), rather than interleaving real/padding rows throughout. Both
patterns are independent and real; `extract_sdt_image_streamed!` applies
this crop first, then still checks the cropped region for interleaving.

A column/row is "active" if its sum exceeds `PADDED_ROW_ENERGY_FRACTION` of
the mean sum among all nonzero columns/rows (same threshold constant as
`padded_row_keep_range`, applied per-row/column here instead of per-parity
— the two observed real cases are both cleanly separated by orders of
magnitude, so this doesn't need to be more precise than that). Assumes the
active region starts at index 1 in both axes (true of every real case seen
so far); returns the full range unchanged if nothing looks padded.
"""
function active_bounding_box(intensity::Matrix{Float64})::Tuple{UnitRange{Int}, UnitRange{Int}}
    n_cols, n_rows = size(intensity)
    col_sums = vec(sum(intensity; dims=2))
    row_sums = vec(sum(intensity; dims=1))

    function active_extent(sums::Vector{Float64})
        n = length(sums)
        nonzero = filter(>(0), sums)
        isempty(nonzero) && return n
        threshold = PADDED_ROW_ENERGY_FRACTION * (sum(nonzero) / length(nonzero))
        hi = findlast(>(threshold), sums)
        return hi === nothing ? n : hi
    end

    return (1:active_extent(col_sums), 1:active_extent(row_sums))
end

"""
    collapse_padded_rows(image::Matrix{Float64})::Matrix{Float64}

Some SDT acquisitions record at half the vertical resolution (e.g. a real
1024x512 scan) but still fill the full square stored buffer (see
`extract_sdt_volume`'s `isqrt(n_pixels)`-inferred width — this lab's setup
always stores width == height), padding every other row (`image[:, y]`)
with near-zero filler. A genuine full-height acquisition (e.g. a real
1024x1024 scan) has no such gap: real signal lands in both odd- and
even-indexed rows.

Distinguish the two by comparing each row parity's share of the image's
total intensity: if one parity holds less than `PADDED_ROW_ENERGY_FRACTION`
of the total, it's padding and only the other parity is kept (halving the
height back to the true resolution); otherwise both parities carry real
signal and the image is returned unchanged. See `padded_row_keep_range` for
the underlying row selection.
"""
function collapse_padded_rows(image::Matrix{Float64})::Matrix{Float64}
    return image[:, padded_row_keep_range(image)]
end

"""
    extract_sdt_volume(sdt::SdtFile.SdtData)::Union{Nothing, Array{Float64,3}}

Build the raw per-pixel time-bin volume `(width, height, bins)` — i.e.
`volume[x, y, :]` is pixel `(x, y)`'s own 256-bin TCSPC histogram — from an
SDT file's first data block, or `nothing` if that block isn't image data (a
plain histogram block is 1D). Same `(x, y)` axis convention and pixel
reshape as `extract_sdt_image`, but without summing over bins or trimming
padded rows (see `extract_sdt_image_and_volume`, which does both and keeps
this volume in sync with the displayed image).

For the `(n_pixels, adc_re)` per-pixel-vector layout (2D branch — what this
lab's own acquisitions actually produce, since their `MeasureInfo.scan_x`/
`scan_y` read back as 0 and `image_x`/`image_y` are unreliable, e.g. a real
2048x2048 scan's own `image_x`/`image_y` metadata read `1062`/`1062`,
matching neither the true width nor the pixel count), the width is inferred
as `isqrt(n_pixels)`, not assumed fixed: this lab's setup always stores a
*square* raw buffer regardless of the true scanned height (see
`collapse_padded_rows` for the shorter-real-scan case, which pads out to
that same square shape rather than storing a non-square buffer directly),
so `n_pixels` is the square of the real stored width for every file from
this setup — 1024x1024, 2048x2048, or any other size, not just 1024. Falls
back to `nothing` (rather than guessing) when `n_pixels` isn't a perfect
square.
"""
function extract_sdt_volume(sdt::SdtFile.SdtData)::Union{Nothing, Array{Float64,3}}
    isempty(sdt.data) && return nothing
    block = sdt.data[1]

    if ndims(block) == 3
        return permutedims(Float64.(block), (2, 1, 3))
    elseif ndims(block) == 2
        n_pixels, n_bins = size(block)
        width = isqrt(n_pixels)
        width * width == n_pixels || return nothing
        return Float64.(reshape(block, width, width, n_bins))
    else
        return nothing
    end
end

"""
    extract_sdt_image_and_volume(sdt::SdtFile.SdtData)::Tuple{Union{Nothing,Matrix{Float64}}, Union{Nothing,Array{Float64,3}}}

`(image, volume)` pair built from the same reshape, with `collapse_padded_rows`'s
row selection applied to both — `image` is `sum(volume; dims=3)` after
trimming, so `volume[x, y, :]` always corresponds to the exact pixel
`image[x, y]` was summed from. `(nothing, nothing)` if the block isn't
image data.
"""
function extract_sdt_image_and_volume(sdt::SdtFile.SdtData)::Tuple{Union{Nothing, Matrix{Float64}}, Union{Nothing, Array{Float64,3}}}
    volume = extract_sdt_volume(sdt)
    volume === nothing && return nothing, nothing

    image = dropdims(sum(volume; dims=3); dims=3)
    keep = padded_row_keep_range(image)
    return image[:, keep], volume[:, keep, :]
end

"""
    extract_sdt_image(sdt::SdtFile.SdtData)::Union{Nothing, Matrix{Float64}}

Build a 2D intensity image (summed over the time-bin axis) from an SDT
file's first data block, or `nothing` if that block isn't image data (a
plain histogram block is 1D). Returned as `(width, height)`, i.e.
`image[x, y]` — Makie's native `heatmap!` convention (dim 1 -> x-axis) —
with padded rows collapsed out (see `collapse_padded_rows`).

Handles both shapes `SdtFile.compute_shape` can produce for an image:
- 2D `(n_pixels, adc_re)` — one contiguous time-bin vector per pixel, no
  (trustworthy) spatial metadata — which is what this lab's own `.sdt`
  files actually contain (`scan_x`/`scan_y` read back as 0, `image_x`/
  `image_y` don't reliably match the real pixel count). Reshaped to
  `(isqrt(n_pixels), isqrt(n_pixels), adc_re)` (see `extract_sdt_volume`
  for why this lab's setup always stores a square buffer) and summed over
  the time-bin axis, matching the reshape used to reconstruct the image
  from raw pixel vectors: `reshape(pixels, width, height, bins)` then
  `sum(dims=3)`.
- 3D `(scan_y, scan_x, adc_re)`, when the file's `scan_x`/`scan_y` metadata
  is populated; summed over the time-bin axis and transposed to the
  `(x, y)` convention above.
"""
function extract_sdt_image(sdt::SdtFile.SdtData)::Union{Nothing, Matrix{Float64}}
    return first(extract_sdt_image_and_volume(sdt))
end

"""
    ROW_STREAM_CHUNK_BYTES::Int

Output chunk size for `raw_inflate_stream` calls in `extract_sdt_image_streamed`
below — large enough (a few MiB) that a ~2GB decompression completes in
under a second (measured), small enough that peak memory for the
decompression itself stays negligible next to the final extracted volume.
"""
const ROW_STREAM_CHUNK_BYTES = 8 * 1024 * 1024

"""
    stream_stored_rows(f::Function, compressed_bytes, stored_width::Int, adc_re::Int)::Bool

Decompress `compressed_bytes` (one SDT IMG block's raw DEFLATE payload, see
`SdtFile.locate_first_data_block`) and call `f(y, row_u16)` once per stored
row, in order, where `row_u16` is a `reshape`d `(adc_re, stored_width)`
view — `row_u16[:, x]` is pixel `(x, y)`'s own `adc_re`-bin histogram — for
row `y` of the `stored_width`-wide raw buffer. `f`'s `row_u16` view is only
valid for the duration of that call (backed by a reused buffer). Returns
`raw_inflate_stream`'s own success flag.

Shared by `extract_sdt_image_streamed`'s two passes (summed-intensity, then
full-volume extraction) so the row-framing/buffering logic — the part with
real off-by-one risk — exists once, not twice.
"""
function stream_stored_rows(f::Function, compressed_bytes, stored_width::Int, adc_re::Int)::Bool
    row_bytes = stored_width * adc_re * sizeof(UInt16)
    buf = UInt8[]
    pos = Ref(1)     # 1-based index of the first unread byte in buf
    y = Ref(1)

    return SdtFile.raw_inflate_stream(compressed_bytes, ROW_STREAM_CHUNK_BYTES) do chunk
        append!(buf, chunk)
        while length(buf) - pos[] + 1 >= row_bytes && y[] <= stored_width
            row_u16 = reshape(reinterpret(UInt16, view(buf, pos[]:pos[]+row_bytes-1)), adc_re, stored_width)
            f(y[], row_u16)
            pos[] += row_bytes
            y[] += 1
        end
        # Compact only once the unread tail grows large, not on every row —
        # an O(n) shift on every one of `stored_width` rows would dominate
        # runtime for no benefit (the unread tail between rows is always
        # under one row's worth of bytes already).
        if pos[] > 8 * ROW_STREAM_CHUNK_BYTES
            deleteat!(buf, 1:pos[]-1)
            pos[] = 1
        end
    end
end

"""
    extract_sdt_image_streamed(filepath::AbstractString)::Tuple{Union{Nothing,Matrix{Float64}}, Union{Nothing,Array{Float64,3}}}

Memory-bounded equivalent of `extract_sdt_image_and_volume(SdtFile.read_sdt(...))`
for a large compressed IMG block: `read_sdt` decompresses the *entire*
block into one buffer up front (hundreds of MB to several GB — for a real
2048x2048x256 file, ~2GB just for that buffer, then *another* ~8GB to
convert it to `Float64`, on top of whatever the padding this lab's setup
can store around the true content — enough together to exhaust an 8GB
machine's RAM well before the padding is even trimmed off). This instead:

1. Locates the block's raw DEFLATE payload without decompressing it
   (`SdtFile.locate_first_data_block`).
2. **Pass 1**: streams it once (`stream_stored_rows`), row by row, summing
   each pixel's bins into a `(stored_width, stored_width)` intensity image
   — the *only* thing held for the full stored buffer, a few tens of MB
   regardless of `adc_re`. From it, determines the true content region:
   `active_bounding_box` for the contiguous-block padding pattern (a
   smaller real scan stored inside a larger fixed buffer), then
   `padded_row_keep_range` on the cropped image for the interleaved-row
   pattern (`collapse_padded_rows`'s own case) within it — the two are
   independent and both are checked.
3. **Pass 2**: streams the *same* payload again (decompression is fast —
   under a second for ~2GB measured — so re-decompressing rather than
   buffering pass 1's rows until the crop is known is the simpler, still
   cheap choice), this time keeping only the identified rows/columns,
   building the final `(kept_width, kept_height, adc_re)` `Float64` volume
   directly at its true size — for the file this was written against,
   ~2.3GB, in line with what an ordinary already-supported 1024x1024 file
   needs, not the ~10GB the naive full-buffer path would have required.

Falls back to `(nothing, nothing)` wherever `extract_sdt_volume` would:
the block isn't compressed 2D image data, or its pixel count isn't a
perfect square (see that function's docstring). Also returns `(nothing,
nothing)` — logging why via `@warn` — if the file can't be read/located,
since unlike `extract_sdt_volume` this does its own file I/O.
"""
function extract_sdt_image_streamed(filepath::AbstractString)::Tuple{Union{Nothing, Matrix{Float64}}, Union{Nothing, Array{Float64,3}}}
    b = try
        read(filepath)
    catch e
        @warn "Failed to read SDT file" path=filepath error=string(e)
        return nothing, nothing
    end

    loc = SdtFile.locate_first_data_block(b)
    if loc === nothing
        @warn "SDT file has no readable data block" path=filepath
        return nothing, nothing
    end

    if !loc.compressed || loc.dtype != UInt16 || loc.adc_re == 0 || (loc.scan_x > 0 && loc.scan_y > 0)
        # Uncompressed (or non-image) blocks aren't the memory problem this
        # function exists for — already at their final size in the file,
        # nothing to stream-decompress. A populated scan_x/scan_y means
        # SdtFile.compute_shape would pick its 3D (scan_y, scan_x, adc_re)
        # shape, not the flat 2D pixel-list one this function only handles
        # (real files from this lab's own setup never hit this — scan_x/
        # scan_y read back 0 — so it's untested territory; falling back
        # avoids silently mis-shaping it instead). Either way, fall back to
        # the simple, existing path.
        sdt = try
            SdtFile.read_sdt(b, basename(filepath))
        catch e
            @warn "Failed to read SDT file" path=filepath error=string(e)
            return nothing, nothing
        end
        return extract_sdt_image_and_volume(sdt)
    end

    n_pixels = loc.dsize ÷ loc.adc_re
    stored_width = isqrt(n_pixels)
    if stored_width * stored_width != n_pixels
        @warn "SDT image pixel count is not a perfect square; cannot infer stored width" path=filepath n_pixels=n_pixels
        return nothing, nothing
    end
    adc_re = loc.adc_re

    # Pass 1: cheap (stored_width, stored_width) summed-intensity image.
    intensity = zeros(Float64, stored_width, stored_width)
    ok1 = stream_stored_rows(loc.bytes, stored_width, adc_re) do y, row_u16
        @views intensity[:, y] .= vec(sum(Float64, row_u16; dims=1))
    end
    if !ok1
        @warn "Failed to decompress SDT image data (pass 1/2)" path=filepath
        return nothing, nothing
    end

    x_range, y_range = active_bounding_box(intensity)
    cropped = intensity[x_range, y_range]
    row_keep_local = padded_row_keep_range(cropped)
    keep_x = collect(x_range)
    keep_y = collect(y_range)[row_keep_local]
    keep_y_set = Set(keep_y)
    y_out_of = Dict(y => i for (i, y) in enumerate(keep_y))  # original row -> output row index

    kept_width = length(keep_x)
    kept_height = length(keep_y)

    # Pass 2: re-decompress (fast — see docstring), this time keeping only
    # the identified rows/columns, building the final right-sized volume
    # directly (never materializing the full stored_width x stored_width
    # buffer at Float64 precision).
    volume = Array{Float64,3}(undef, kept_width, kept_height, adc_re)
    ok2 = stream_stored_rows(loc.bytes, stored_width, adc_re) do y, row_u16
        if y in keep_y_set
            y_out = y_out_of[y]
            @views volume[:, y_out, :] .= Float64.(transpose(row_u16[:, keep_x]))
        end
    end
    if !ok2
        @warn "Failed to decompress SDT image data (pass 2/2)" path=filepath
        return nothing, nothing
    end

    image = dropdims(sum(volume; dims=3); dims=3)
    return image, volume
end

"""
    point_in_polygon(px::Float64, py::Float64, xs::Vector{Float64}, ys::Vector{Float64})::Bool

Standard even-odd ray-casting point-in-polygon test: is `(px, py)` inside
the closed polygon `(xs, ys)`? Shared by `roi_pixel_mask` (per-pixel, to
select which pixels a ROI covers) and `open_roi_popup!`'s D-click-to-delete
handler (single click point, to find which drawn ROI was clicked).
"""
function point_in_polygon(px::Float64, py::Float64, xs::Vector{Float64}, ys::Vector{Float64})::Bool
    n = length(xs)
    inside = false
    j = n
    for i in 1:n
        xi, yi = xs[i], ys[i]
        xj, yj = xs[j], ys[j]
        if ((yi > py) != (yj > py)) && (px < (xj - xi) * (py - yi) / (yj - yi) + xi)
            inside = !inside
        end
        j = i
    end
    return inside
end

"""
    roi_pixel_mask(xs::Vector{Float64}, ys::Vector{Float64}, n_cols::Int, n_rows::Int)::Vector{Tuple{Int,Int}}

1-based `(x, y)` indices into a `(n_cols, n_rows, ...)` volume whose pixel
center (the same 0-based `(x-1, y-1)` coordinate `roi_boundary_points`
returns, i.e. no offset applied) falls inside the closed polygon `(xs, ys)`
(`point_in_polygon`). Only scans the polygon's bounding box (clamped to the
volume's extent), not the whole image.
"""
function roi_pixel_mask(xs::Vector{Float64}, ys::Vector{Float64}, n_cols::Int, n_rows::Int)::Vector{Tuple{Int,Int}}
    isempty(xs) && return Tuple{Int,Int}[]

    x_lo = clamp(floor(Int, minimum(xs)) + 1, 1, n_cols)
    x_hi = clamp(ceil(Int, maximum(xs)) + 1, 1, n_cols)
    y_lo = clamp(floor(Int, minimum(ys)) + 1, 1, n_rows)
    y_hi = clamp(ceil(Int, maximum(ys)) + 1, 1, n_rows)

    pixels = Tuple{Int,Int}[]
    for iy in y_lo:y_hi, ix in x_lo:x_hi
        point_in_polygon(Float64(ix - 1), Float64(iy - 1), xs, ys) && push!(pixels, (ix, iy))
    end
    return pixels
end

"""
    pixel_label_boundary(mask_xy::AbstractMatrix{<:Integer}, label::Integer)::Tuple{Vector{Float64}, Vector{Float64}}

Outer boundary of every pixel in `mask_xy` (an `(n_cols, n_rows)` integer
label image — 0 = background, see `read_cellpose_masks`) equal to `label`,
as a closed polygon in the same 0-based pixel-index coordinate convention
`roi_boundary_points` uses — so it plugs directly into `add_and_track_roi!`
the same as an imported or manually-drawn ROI, and `roi_pixel_mask` on the
result reproduces `label`'s exact pixel set (verified: traces vertices at
pixel *corners*, not centers, so the polygon boundary and the pixel-center
points `roi_pixel_mask` tests against never coincide — the classic
ray-casting point-on-boundary ambiguity that a naive pixel-center trace
would hit on roughly half of every blob's own perimeter pixels).

Traced via edge cancellation: every masked pixel's unit-square footprint
(in pixel-corner coordinates) contributes its 4 edges; an edge shared by two
adjacent masked pixels cancels (appears twice); the remaining odd-count
edges are the boundary, walked into one closed loop from an arbitrary
starting edge. Assumes each label is one 4-connected blob with no interior
hole, true of real Cellpose output; the one failure mode is a label whose
pixels touch themselves only diagonally (never produced by Cellpose's
smooth probability-map segmentation, but possible in principle) — the walk
then can't close and this returns two empty vectors rather than a
partial/self-intersecting polygon, so the caller (`run_cellpose_segmentation!`)
can skip that label safely instead of handing a broken boundary to
`add_and_track_roi!` (and, downstream, `roi_trigger_buffer`'s hardware scan
path).
"""
function pixel_label_boundary(mask_xy::AbstractMatrix{<:Integer}, label::Integer)::Tuple{Vector{Float64}, Vector{Float64}}
    n_cols, n_rows = size(mask_xy)

    # Corner coordinates on a half-integer grid (actual coordinate = value/2)
    # so edge endpoints compare by exact integer equality — no floating-point
    # tie-breaking risk from repeated `x - 0.5` arithmetic.
    edge_count = Dict{Tuple{Tuple{Int,Int}, Tuple{Int,Int}}, Int}()
    function add_edge!(a::Tuple{Int,Int}, b::Tuple{Int,Int})
        key = a <= b ? (a, b) : (b, a)
        edge_count[key] = get(edge_count, key, 0) + 1
        return nothing
    end

    any_pixel = false
    for y in 1:n_rows, x in 1:n_cols
        mask_xy[x, y] == label || continue
        any_pixel = true

        px, py = x - 1, y - 1   # 0-based pixel index
        tl = (2px - 1, 2py - 1)
        tr = (2px + 1, 2py - 1)
        br = (2px + 1, 2py + 1)
        bl = (2px - 1, 2py + 1)
        add_edge!(tl, tr)
        add_edge!(tr, br)
        add_edge!(br, bl)
        add_edge!(bl, tl)
    end
    any_pixel || return Float64[], Float64[]

    boundary_edges = [k for (k, c) in edge_count if isodd(c)]
    isempty(boundary_edges) && return Float64[], Float64[]

    adjacency = Dict{Tuple{Int,Int}, Vector{Tuple{Int,Int}}}()
    for (a, b) in boundary_edges
        push!(get!(() -> Tuple{Int,Int}[], adjacency, a), b)
        push!(get!(() -> Tuple{Int,Int}[], adjacency, b), a)
    end

    start = boundary_edges[1][1]
    path = Tuple{Int,Int}[start]
    prev = nothing
    current = start
    closed = false

    # Generous but finite: a real (non-adversarial) boundary closes in
    # exactly `length(boundary_edges)` steps; this only guards against
    # hanging on a pathological input, not normal operation.
    for _ in 1:(length(boundary_edges) + 4)
        next = something(findfirst(!=(prev), adjacency[current]), 1)
        next_corner = adjacency[current][next]

        if next_corner == start
            closed = true
            break
        end
        push!(path, next_corner)
        prev = current
        current = next_corner
    end
    closed || return Float64[], Float64[]

    push!(path, start)
    xs = Float64[p[1] / 2.0 for p in path]
    ys = Float64[p[2] / 2.0 for p in path]
    return xs, ys
end

"""
    roi_summed_histogram(volume::Array{Float64,3}, pixels::Vector{Tuple{Int,Int}})::Vector{Float64}

Sum every pixel's own 256-bin TCSPC histogram (`volume[x, y, :]`) across
`pixels` into a single combined histogram, for lifetime fitting.
"""
function roi_summed_histogram(volume::Array{Float64,3}, pixels::Vector{Tuple{Int,Int}})::Vector{Float64}
    total = zeros(Float64, size(volume, 3))
    for (x, y) in pixels
        total .+= @view volume[x, y, :]
    end
    return total
end

"""
    DrawnROI

One ROI currently shown on `image_axis` — either imported or manually
drawn (`add_roi_from_boundary!` builds these). `shifted_xs`/`shifted_ys`
are its boundary in the same display (offset-shifted) coordinates a click
lands in, used to hit-test D-click-to-delete; `plots` are every Makie plot
object backing it (fill, outline, and label if the fit converged), removed
together on delete/clear.
"""
struct DrawnROI
    shifted_xs::Vector{Float64}
    shifted_ys::Vector{Float64}
    plots::Vector{Any}
end

"""
    add_roi_from_boundary!(image_axis, volume::Array{Float64,3}, x_offset::Real, y_offset::Real, xs::Vector{Float64}, ys::Vector{Float64}, roi_label::AbstractString)::DrawnROI

Shared by imported ROIs (`roi_import_button`) and manually-drawn ROIs (hold
`A` and click on `image_axis`): given a closed polygon boundary in
un-shifted, volume-local pixel coordinates (the same convention
`roi_boundary_points` returns), draw its translucent fill and outline on
`image_axis`, select its pixels, sum their histograms, and fit a lifetime —
adding a label at the ROI's center if the fit converges, or just warning
under `roi_label` if the ROI is empty or the fit doesn't converge. Always
returns a `DrawnROI` bundling every plot object created (fill + outline,
optionally + label) for the caller to track.
"""
function add_roi_from_boundary!(image_axis, volume::Array{Float64,3}, x_offset::Real, y_offset::Real, xs::Vector{Float64}, ys::Vector{Float64}, roi_label::AbstractString)::DrawnROI
    n_cols, n_rows, n_bins = size(volume)
    shifted_xs = xs .+ x_offset
    shifted_ys = ys .+ y_offset
    plots = Any[]

    if length(xs) >= 3
        push!(plots, poly!(image_axis, Point2f.(shifted_xs, shifted_ys), color=(PLOT_COLOR_REF, 0.1), strokewidth=0))
    end
    push!(plots, lines!(image_axis, shifted_xs, shifted_ys, color=PLOT_COLOR_REF, linewidth=PLOT_LINEWIDTH))

    pixels = roi_pixel_mask(xs, ys, n_cols, n_rows)
    if isempty(pixels)
        @warn "ROI contains no pixels; skipping lifetime fit" roi=roi_label
        return DrawnROI(shifted_xs, shifted_ys, plots)
    end

    summed_hist = roi_summed_histogram(volume, pixels)

    params_raw, _ = try
        vec_to_lifetime(summed_hist; guess=initial_guess_for_lifetimes("1 lifetime"), histogram_resolution=n_bins)
    catch e
        @warn "Lifetime fit failed for ROI" roi=roi_label error=string(e)
        return DrawnROI(shifted_xs, shifted_ys, plots)
    end

    if isempty(params_raw) || isnan(params_raw[1])
        @warn "Lifetime fit did not converge for ROI" roi=roi_label
        return DrawnROI(shifted_xs, shifted_ys, plots)
    end

    label_x = (minimum(xs) + maximum(xs)) / 2 + x_offset
    label_y = (minimum(ys) + maximum(ys)) / 2 + y_offset
    label_text = string(round(params_raw[1], digits=2), " ns")
    push!(plots, text!(image_axis, label_x, label_y; text=label_text, color=Makie.wong_colors()[6], align=(:center, :center)))

    return DrawnROI(shifted_xs, shifted_ys, plots)
end

"""
    roi_boundary_points(roi::ImageJROI.ROIData)::Tuple{Vector{Float64}, Vector{Float64}}

Closed-loop (or open, for a straight line) `(xs, ys)` boundary points for a
parsed ImageJ ROI, in the same 0-based pixel coordinates used by the ROI
file itself. Explicit polygon/freehand coordinates are used when present;
`"line"` uses its two endpoints; `"oval"` is approximated by an ellipse
sampled from its bounding box; everything else (e.g. `"rect"`) falls back
to its bounding-box rectangle.
"""
function roi_boundary_points(roi::ImageJROI.ROIData)::Tuple{Vector{Float64}, Vector{Float64}}
    if !isempty(roi.x_coordinates)
        xs = Float64.(roi.x_coordinates)
        ys = Float64.(roi.y_coordinates)
        return vcat(xs, xs[1]), vcat(ys, ys[1])
    elseif roi.roitype == "line"
        return Float64[roi.x1, roi.x2], Float64[roi.y1, roi.y2]
    elseif roi.roitype == "oval"
        cx, cy = (roi.left + roi.right) / 2, (roi.top + roi.bottom) / 2
        rx, ry = roi.width / 2, roi.height / 2
        theta = range(0, 2π; length=65)
        return cx .+ rx .* cos.(theta), cy .+ ry .* sin.(theta)
    else
        xs = Float64[roi.left, roi.right, roi.right, roi.left, roi.left]
        ys = Float64[roi.top, roi.top, roi.bottom, roi.bottom, roi.top]
        return xs, ys
    end
end

"""
    read_rois(filepath::String)::Vector{ImageJROI.ROIData}

Read ROIs from an ImageJ `.roi` file or a `.zip` of `.roi` files, dispatched
on the file extension.
"""
function read_rois(filepath::String)::Vector{ImageJROI.ROIData}
    lower_path = lowercase(filepath)
    if endswith(lower_path, ".zip")
        return collect(values(ImageJROI.read_roi_zip(filepath)))
    elseif endswith(lower_path, ".roi")
        return [ImageJROI.read_roi(filepath)]
    else
        error("Unsupported ROI file extension (expected .roi or .zip): $filepath")
    end
end

# "cpsam_v2" is CellposeModel's own default pretrained model in Cellpose
# 4.x (its general-purpose SAM-based segmentation model) — the classic
# cyto/cyto2/cyto3/nuclei family (this constant's original value) no longer
# exists as of 4.x (confirmed against a real 4.2.1.1 install: MODEL_NAMES =
# ['cpsam_v2', 'cpdino', 'cpdino-vitb', 'cpsam']). If you're on an older
# Cellpose install, change this back to "cyto3".
const CELLPOSE_MODEL_TYPE = "cpsam_v2"
const CELLPOSE_DIAMETER = 0.0   # 0 lets Cellpose auto-estimate object size

"""
    cellpose_venv_python_path()::String

Path to the python executable inside the dedicated Cellpose virtual
environment this app expects at `~/.flimapp/cellpose-env` — set up once,
outside the app:

    python3 -m venv ~/.flimapp/cellpose-env
    ~/.flimapp/cellpose-env/bin/pip install cellpose

A fixed, `homedir()`-anchored path, not a bare `"python3"` resolved via
`PATH`: a macOS `.app` launched by double-click (build/create_app.jl) gets a
minimal `PATH` that excludes Homebrew/venv/pyenv locations, so PATH
resolution works from a terminal but silently breaks once compiled — this
app also wouldn't otherwise know *which* `python3` (if several are
installed) actually has Cellpose. A function, not a `const`, for the same
reason `user_data_dir()` (config.jl) is: evaluated at call time, not baked
into the build.
"""
function cellpose_venv_python_path()::String
    venv_dir = joinpath(user_data_dir(), "cellpose-env")
    return Sys.iswindows() ? joinpath(venv_dir, "Scripts", "python.exe") : joinpath(venv_dir, "bin", "python3")
end

"""
    CELLPOSE_SEGMENT_SCRIPT::String

Full source of `cellpose_segment.py`, read once when this file is
*compiled* (a plain `read` at an `@__DIR__`-derived path — the same kind of
compile-time file access every other `include`d file in src/ already
relies on) and embedded directly in the resulting binary/sysimage.
`cellpose_script_path()` below writes this text out to a real file at *run*
time — see its docstring for why *locating* an external file via `@__DIR__`
at runtime is unsafe in a PackageCompiler app, even though *reading* one at
compile time, as done here, is not.
"""
const CELLPOSE_SEGMENT_SCRIPT = read(normpath(joinpath(@__DIR__, "..", "scripts", "cellpose_segment.py")), String)

"""
    cellpose_script_path(; dir=user_data_dir())::String

Path to an on-disk copy of `cellpose_segment.py`, (re)written from the
compiled-in `CELLPOSE_SEGMENT_SCRIPT` whenever it's missing or stale.
Materialized under `dir` (`user_data_dir()`, i.e. `~/.flimapp`, by default —
overridable so tests don't touch the real one) rather than looked up via
`@__DIR__`: `@__DIR__` resolves to a fixed string at *compile* time, so a
`const` built from it directly — this function's own earlier, now-fixed
version — bakes in wherever `scripts/` sat on the *build machine*, not
wherever a PackageCompiler bundle (build/create_app.jl) actually ends up
(`FLIMApp.app/Contents/Resources/app/...`, an entirely different path).
Embedding the script's *contents* at compile time (`CELLPOSE_SEGMENT_SCRIPT`)
sidesteps that: nothing at runtime needs to locate the original `scripts/`
folder at all.
"""
function cellpose_script_path(; dir::AbstractString=user_data_dir())::String
    path = joinpath(dir, "cellpose_segment.py")
    if !isfile(path) || read(path, String) != CELLPOSE_SEGMENT_SCRIPT
        mkpath(dir)
        write(path, CELLPOSE_SEGMENT_SCRIPT)
    end
    return path
end

"""
    write_cellpose_input(path, image_xy::Matrix{Float64})

Write `image_xy` (an `(n_cols, n_rows)` image, FLIMApp's own `(x, y)`
convention — see `extract_sdt_image`) to `path` as the flat binary format
`cellpose_segment.py` reads: an `(n_cols, n_rows)` `Int64` header, then the
pixel data in Julia's native column-major order (which `write` on a plain
`Array` already writes as raw memory — no manual reshaping needed here).
"""
function write_cellpose_input(path::AbstractString, image_xy::Matrix{Float64})
    open(path, "w") do io
        write(io, Int64.(size(image_xy))...)
        write(io, image_xy)
    end
    return nothing
end

"""
    read_cellpose_masks(path)::Matrix{Int32}

Read the `(n_cols, n_rows)` `Int32` label mask `cellpose_segment.py` writes
back (0 = background, 1..N = one region each) — the inverse binary layout
of `write_cellpose_input`.
"""
function read_cellpose_masks(path::AbstractString)::Matrix{Int32}
    return open(path, "r") do io
        n_cols = read(io, Int64)
        n_rows = read(io, Int64)
        data = Vector{Int32}(undef, n_cols * n_rows)
        read!(io, data)
        reshape(data, n_cols, n_rows)
    end
end

"""
    run_cellpose_segmentation(image_xy::Matrix{Float64})::Union{Nothing, Matrix{Int32}}

Run `cellpose_segment.py` as a subprocess on `image_xy` and return its
`(n_cols, n_rows)` `Int32` label mask, or `nothing` on any failure — the
Cellpose venv missing, Cellpose not installed in it, a segmentation error,
or a malformed output file — always logged via `@error`, including the
subprocess's own stderr (e.g. Cellpose's own Python traceback), so a real
failure is diagnosable from the app's log without reproducing it
separately.

A subprocess, not an in-process Python bridge (PyCall.jl/PythonCall.jl):
this repo has no Python dependency otherwise and ships as a compiled
PackageCompiler binary (build/create_app.jl) that cannot bundle a
Python/PyTorch runtime. Talks to the script over two temp files
(`write_cellpose_input`/`read_cellpose_masks`), not stdin/stdout, so a large
image doesn't need to round-trip through a pipe.

`run(...; wait=false)` + explicit `wait`/`success` (rather than plain
`run(cmd)`, which throws on a nonzero exit) is what lets a Cellpose failure
be reported through this function's own return value/log instead of an
uncaught exception on the GUI thread.

`python_cmd`/`script_path`/`model_type`/`diameter` default to
`cellpose_venv_python_path()`/`cellpose_script_path()`/the `CELLPOSE_*`
constants — the button handler below calls this with no overrides — but are
keyword arguments (not hardcoded) so tests can swap in a stand-in
script/interpreter without a real Cellpose install.
"""
function run_cellpose_segmentation(
        image_xy::Matrix{Float64};
        python_cmd::AbstractString=cellpose_venv_python_path(),
        script_path::AbstractString=cellpose_script_path(),
        model_type::AbstractString=CELLPOSE_MODEL_TYPE,
        diameter::Real=CELLPOSE_DIAMETER
    )::Union{Nothing, Matrix{Int32}}
    if !isfile(script_path)
        @error "Cellpose wrapper script not found" path=script_path
        return nothing
    end

    if Sys.which(python_cmd) === nothing
        @error "Cellpose virtual environment not found" expected_path=python_cmd hint="python3 -m venv ~/.flimapp/cellpose-env && ~/.flimapp/cellpose-env/bin/pip install cellpose"
        return nothing
    end

    input_path = tempname()
    output_path = tempname()

    try
        write_cellpose_input(input_path, image_xy)

        cmd = `$python_cmd $script_path $input_path $output_path $model_type $diameter`
        stdout_io = IOBuffer()
        stderr_io = IOBuffer()

        process = try
            p = run(pipeline(cmd; stdout=stdout_io, stderr=stderr_io); wait=false)
            wait(p)
            p
        catch e
            @error "Failed to launch Cellpose" python_cmd=python_cmd error=string(e)
            return nothing
        end

        if !success(process)
            @error "Cellpose segmentation failed" exit_code=process.exitcode stderr=strip(String(take!(stderr_io)))
            return nothing
        end

        if !isfile(output_path)
            @error "Cellpose subprocess exited successfully but wrote no output" stderr=strip(String(take!(stderr_io)))
            return nothing
        end

        @info "Cellpose segmentation finished" output=strip(String(take!(stdout_io)))
        return read_cellpose_masks(output_path)
    catch e
        @error "Cellpose segmentation failed" error=string(e)
        return nothing
    finally
        rm(input_path; force=true)
        rm(output_path; force=true)
    end
end

function roi_bring_popup_to_front!(screen::GLMakie.Screen)
    try
        GLMakie.to_native(screen).window.focused[] = true
    catch e
        @warn "Unable to focus ROI popup" error=string(e)
    end

    return nothing
end

function open_roi_popup!(app, app_run, roi_popup_screen::Base.RefValue{Union{Nothing, GLMakie.Screen}})
    existing_screen = roi_popup_screen[]
    if existing_screen !== nothing && isopen(existing_screen)
        roi_bring_popup_to_front!(existing_screen)
        return
    end

    save_state(app)

    popup_figure = Figure(size = (700, 800))
    popup_screen = GLMakie.Screen(resolution = (700, 800))
    roi_popup_screen[] = popup_screen

    axis_layout = GridLayout(popup_figure[1, 1])
    buttons_layout = GridLayout(popup_figure[2, 1])

    # yreversed=false: image row 0 (ImageJ/SdtFile's top-left pixel origin)
    # is plotted at the BOTTOM of the axis — a display-only flip (Makie
    # handles the screen<->data mapping transparently either way, so
    # heatmap!/poly!/lines! coordinates, mouseposition(), and every ROI
    # pixel-mask/boundary computation below all stay in the same 0-based
    # (x=column, y=row) data space regardless of this setting).
    # aspect=DataAspect(): keeps pixels square regardless of the axis
    # widget's own on-screen dimensions, so a non-square image (e.g. after
    # collapse_padded_rows halves the height) doesn't get stretched to fill
    # the axis.
    # x/yrectzoom=false: Makie's default rectangle-zoom is also a left-click
    # drag, which would fight with manual ROI point-placement (hold A, left-
    # click) below.
    image_axis = Axis(axis_layout[1, 1]; merge(AXIS_IMAGE_ATTRS, Dict{Symbol, Any}(:title => "ROI Image", :yreversed => true, :aspect => DataAspect(), :xrectzoom => false, :yrectzoom => false))...)

    # First-moment (mean-arrival-time) per-pixel lifetime preview — see
    # pixel_lifetime_map (lifetime_analysis.jl) and refresh_image_display!
    # below. min_photons_textbox's default matches pixel_lifetime_map's own.
    lifetime_map_label  = Label(buttons_layout[1, 1];   merge(LABEL_ATTRS,  Dict{Symbol, Any}(:text => "Lifetime map"))...)
    min_photons_label   = Label(buttons_layout[2, 1];   merge(LABEL_ATTRS,  Dict{Symbol, Any}(:text => "Min photons"))...)
    lifetime_map_toggle = Toggle(buttons_layout[1, 2];  merge(TOGGLE_ATTRS, Dict{Symbol, Any}(:active => false))...)
    min_photons_textbox = Textbox(buttons_layout[2, 2]; merge(TEXT_ATTRS,   Dict{Symbol, Any}(:displayed_string => "25", :stored_string => "25"))...)

    im_import_button    = Button(buttons_layout[1, 3];  merge(BUTTON_ATTRS, Dict{Symbol, Any}(:label => "Import image"))...)
    cellpose_button     = Button(buttons_layout[2, 3];  merge(BUTTON_ATTRS, Dict{Symbol, Any}(:label => "Cellpose"))...)
    roi_import_button   = Button(buttons_layout[1, 4];  merge(BUTTON_ATTRS, Dict{Symbol, Any}(:label => "Import ROI"))...)
    roi_export_button   = Button(buttons_layout[2, 4];  merge(BUTTON_ATTRS, Dict{Symbol, Any}(:label => "Export ROI"))...)
    roi_clear_button    = Button(buttons_layout[1, 5];  merge(BUTTON_ATTRS, Dict{Symbol, Any}(:label => "Clear ROI"))...)
    popup_close_button  = Button(buttons_layout[2, 5];  merge(BUTTON_ATTRS, Dict{Symbol, Any}(:label => "Close"))...)

    image_plot = Ref{Any}(nothing)
    # Every ROI currently shown on image_axis (imported or manually drawn),
    # each bundling its own plot objects so a single ROI can be deleted (D +
    # click its interior) without touching the others.
    drawn_rois = DrawnROI[]
    # Pixel offset of the currently displayed image's (0,0) corner within
    # the square canvas (see the im_import_button handler below); ROI
    # overlays and ROI-fit labels are shifted by the same amount so they
    # stay aligned with the centered, padded image rather than its own
    # un-padded coordinates.
    image_offset = Ref((0.0, 0.0))
    # Raw per-pixel time-bin volume backing the currently displayed image
    # (same (x, y) extent, already padded-row-trimmed to match) — the data
    # ROI lifetime fits are actually computed from.
    pixel_volume = Ref{Union{Nothing, Array{Float64,3}}}(nothing)
    # Grayscale intensity image for the currently displayed image, cached
    # alongside pixel_volume so update_lifetime_overlay! (below) can redraw
    # the overlay without re-reading the SDT file.
    intensity_image = Ref{Union{Nothing, Matrix{Float64}}}(nothing)
    # The lifetime-map overlay heatmap, drawn on top of the always-visible
    # grayscale image[] — nothing if none has been computed yet (or the
    # computation failed/found no qualifying pixel). Unlike image_plot,
    # toggling it on/off (see lifetime_map_toggle below) only flips its
    # `.visible` attribute; it is not deleted/recreated, so a toggle click is
    # a cheap redraw, not a recompute.
    lifetime_map_plot = Ref{Any}(nothing)
    # Lifetime-map Colorbar: unlike a heatmap plot, a Colorbar block has no
    # settable `visible`, so it's created only while the overlay is actually
    # shown and deleted (not hidden) when the overlay is toggled off.
    lifetime_colorbar = Ref{Any}(nothing)
    # Last valid min-photons threshold, restored into the textbox on an
    # unparseable edit — same reset-to-last-valid idiom as the Controller
    # panel's P/I textboxes (handlers_controller.jl).
    min_photons = Ref(50.0)

    """
        update_lifetime_overlay!()

    Recompute the lifetime-map overlay (`pixel_lifetime_map`,
    lifetime_analysis.jl) from the cached `pixel_volume`/`min_photons` and
    redraw it — called once right after an image import and again whenever
    `min_photons_textbox` commits a new threshold, so the overlay is always
    ready the moment `lifetime_map_toggle` is switched on (no compute lag on
    the toggle click itself). No-op if no image is loaded.

    Always replaces the previous overlay heatmap/colorbar outright (cheap:
    this only runs on import or an explicit threshold edit, not per toggle
    click) rather than updating them in place. The overlay heatmap's
    `visible` is set to match `lifetime_map_toggle`'s current state, so
    changing the threshold while the overlay is showing updates it live,
    and while hidden leaves it hidden. Falls back to no overlay (grayscale
    image only, via the always-present `image_plot`) if the map computation
    fails (e.g. IRF not loaded) or no pixel meets the photon threshold —
    logging why either way.

    Color range is `mean ± 3σ` over the qualifying (non-NaN) pixels, not
    `extrema` — low-photon pixels that clear `min_photons` but still carry
    high first-moment variance produce occasional far-outlier estimates that
    would otherwise stretch the whole colormap and wash out the real
    contrast. Pixel values outside that range are clamped to it (not just
    the colormap, so `nan_color`-excluded pixels aside, what's displayed is
    the actual capped data) before drawing.
    """
    function update_lifetime_overlay!()
        volume = pixel_volume[]
        volume === nothing && return nothing

        if lifetime_map_plot[] !== nothing
            delete!(image_axis, lifetime_map_plot[])
            lifetime_map_plot[] = nothing
        end
        if lifetime_colorbar[] !== nothing
            delete!(lifetime_colorbar[])
            lifetime_colorbar[] = nothing
        end

        lifetime_map = try
            pixel_lifetime_map(volume; min_photons=min_photons[])
        catch e
            @warn "Failed to compute pixel lifetime map" error=string(e)
            return nothing
        end

        finite_values = filter(isfinite, vec(lifetime_map))
        if isempty(finite_values)
            @warn "No pixel has enough photons for a lifetime map" min_photons=min_photons[]
            return nothing
        end

        # mean ± 3σ, degrading gracefully to a small pad around the mean
        # when there's no meaningful spread to measure (a single qualifying
        # pixel, or all of them identical).
        mu = mean(finite_values)
        sigma = length(finite_values) >= 2 ? std(finite_values) : 0.0
        lo, hi = mu - 3*sigma, mu + 3*sigma
        if !(hi > lo)
            lo -= 0.5
            hi += 0.5
        end

        clamped_map = clamp.(lifetime_map, lo, hi)   # NaN passes through unchanged

        x_offset, y_offset = image_offset[]
        n_cols, n_rows = size(clamped_map)
        xs = x_offset:(x_offset + n_cols - 1)
        ys = y_offset:(y_offset + n_rows - 1)

        lifetime_map_plot[] = heatmap!(image_axis, xs, ys, clamped_map; colormap = :turbo, colorrange = (lo, hi), nan_color = :transparent, visible = lifetime_map_toggle.active[])
        if lifetime_map_toggle.active[]
            lifetime_colorbar[] = Colorbar(axis_layout[1, 2]; colormap = :turbo, limits = (lo, hi), label = "ns")
        end

        return nothing
    end

    # drawn_rois and app_run.rois are kept in lockstep, index-for-index:
    # drawn_rois holds this popup's GUI plot objects (never leaves this
    # function), app_run.rois holds the plain boundary data other
    # panels/functions can read.
    function add_and_track_roi!(volume::Array{Float64,3}, x_offset::Real, y_offset::Real, xs::Vector{Float64}, ys::Vector{Float64}, label::AbstractString)
        push!(drawn_rois, add_roi_from_boundary!(image_axis, volume, x_offset, y_offset, xs, ys, label))
        push!(app_run.rois[], RoiCoordinates(String(label), xs, ys))
        notify(app_run.rois)
        return nothing
    end

    # Manual ROI drawing (hold A, click to place vertices, release A to
    # finish): points collected so far, in display (offset-shifted) canvas
    # coordinates, and the live dashed-line/marker preview plots redrawn on
    # each click.
    drawing_active = Ref(false)
    drawing_points = Point2f[]
    drawing_preview_plots = Any[]
    manual_roi_count = Ref(0)
    # D-click-to-delete: held the same way A (drawing) is.
    deleting_active = Ref(false)
    # Guards against a double-click launching a second Cellpose subprocess
    # while one is already segmenting (cellpose_button.clicks handler,
    # below) — segmentation can take anywhere from seconds to a minute.
    cellpose_running = Ref(false)

    function clear_drawing_preview!()
        for p in drawing_preview_plots
            delete!(image_axis, p)
        end
        empty!(drawing_preview_plots)
        return nothing
    end

    on(events(popup_figure).keyboardbutton) do event
        if event.key == Keyboard.a
            if event.action == Keyboard.press
                drawing_active[] = true
                empty!(drawing_points)
                clear_drawing_preview!()
            elseif event.action == Keyboard.release
                drawing_active[] = false
                clear_drawing_preview!()

                if length(drawing_points) >= 3
                    volume = pixel_volume[]
                    if volume === nothing
                        @warn "No image imported yet; cannot create manual ROI"
                    elseif app_run.running[]
                        @warn "Acquisition is running; skipping manual ROI lifetime fitting"
                    else
                        x_offset, y_offset = image_offset[]
                        xs = Float64[p[1] - x_offset for p in drawing_points]
                        ys = Float64[p[2] - y_offset for p in drawing_points]
                        push!(xs, xs[1])
                        push!(ys, ys[1])

                        manual_roi_count[] += 1
                        add_and_track_roi!(volume, x_offset, y_offset, xs, ys, "manual-$(manual_roi_count[])")
                    end
                end

                empty!(drawing_points)
            end
        elseif event.key == Keyboard.d
            deleting_active[] = event.action == Keyboard.press ? true :
                                 event.action == Keyboard.release ? false : deleting_active[]
        end

        return Consume(false)
    end

    on(events(popup_figure).mousebutton) do event
        (event.button == Mouse.left && event.action == Mouse.press && is_mouseinside(image_axis)) || return Consume(false)
        pos = mouseposition(image_axis)

        if drawing_active[]
            push!(drawing_points, Point2f(pos[1], pos[2]))

            clear_drawing_preview!()
            if length(drawing_points) == 1
                push!(drawing_preview_plots, scatter!(image_axis, drawing_points, color=PLOT_COLOR_REF))
            else
                push!(drawing_preview_plots, lines!(image_axis, drawing_points, color=PLOT_COLOR_REF, linewidth=PLOT_LINEWIDTH))
            end

            return Consume(true)
        elseif deleting_active[]
            px, py = Float64(pos[1]), Float64(pos[2])
            # findlast: prefer the most-recently-added (visually topmost) ROI
            # when boundaries overlap.
            hit = findlast(roi -> point_in_polygon(px, py, roi.shifted_xs, roi.shifted_ys), drawn_rois)
            if hit !== nothing
                for p in drawn_rois[hit].plots
                    delete!(image_axis, p)
                end
                deleteat!(drawn_rois, hit)
                deleteat!(app_run.rois[], hit)
                notify(app_run.rois)
            end

            return Consume(true)
        end

        return Consume(false)
    end

    on(im_import_button.clicks) do _
        filepath = pick_non_empty_path(() -> pick_file(filterlist="sdt"); error_msg="Image import file dialog failed")
        filepath === nothing && return

        # extract_sdt_image_streamed does its own file I/O and decompresses
        # in bounded chunks (see its docstring) rather than materializing
        # the whole block at once like SdtFile.read_sdt — the difference
        # that matters for a large image (e.g. a real 2048x2048x256 file
        # needs on the order of 10GB through the old path just to load,
        # before any padding this lab's setup can store around the true
        # content is even trimmed off).
        intensity, volume = extract_sdt_image_streamed(filepath)
        if intensity === nothing
            @info "SDT file is a histogram, not an image; nothing to display" path=filepath
            return
        end
        pixel_volume[] = volume
        intensity_image[] = intensity

        n_cols, n_rows = size(intensity)
        canvas_size = max(n_cols, n_rows)
        x_offset = (canvas_size - n_cols) ÷ 2
        y_offset = (canvas_size - n_rows) ÷ 2
        image_offset[] = (x_offset, y_offset)
        # Recorded so roi.jl's trigger-box voltage mapping can apply this
        # same centering to app_run.rois's coordinates (in this image's own,
        # un-padded pixel space) at Start-button time, long after this popup
        # and its local x_offset/y_offset above have gone away.
        app_run.imported_image_size = (n_cols, n_rows)

        # Grayscale base image: always drawn, never hidden by the lifetime
        # toggle below — the lifetime map (if any) is a separate heatmap
        # layered on top of it.
        if image_plot[] !== nothing
            delete!(image_axis, image_plot[])
        end
        image_plot[] = heatmap!(image_axis, x_offset:(x_offset + n_cols - 1), y_offset:(y_offset + n_rows - 1), intensity, colormap = :grays)
        update_lifetime_overlay!()
        limits!(image_axis, 0, canvas_size, 0, canvas_size)

        @info "Image imported" path=filepath size=size(intensity) canvas_size=canvas_size offset=(x_offset, y_offset)
    end

    # Cheap show/hide: no recompute, since update_lifetime_overlay! already
    # kept lifetime_map_plot current (import time, and any threshold edit).
    on(lifetime_map_toggle.active) do is_active
        plot = lifetime_map_plot[]
        if plot !== nothing
            plot.visible[] = is_active
        end

        if is_active
            if plot !== nothing && lifetime_colorbar[] === nothing
                lo, hi = plot.colorrange[]
                lifetime_colorbar[] = Colorbar(axis_layout[1, 2]; colormap = :turbo, limits = (lo, hi), label = "ns")
            end
        elseif lifetime_colorbar[] !== nothing
            delete!(lifetime_colorbar[])
            lifetime_colorbar[] = nothing
        end
    end

    on(min_photons_textbox.stored_string) do new_str
        val = tryparse(Float64, new_str)
        if val !== nothing && val >= 0
            min_photons[] = val
            min_photons_textbox.displayed_string[] = string(val)
        else
            min_photons_textbox.displayed_string[] = string(min_photons[])
            min_photons_textbox.stored_string[]    = string(min_photons[])
        end

        update_lifetime_overlay!()
    end

    on(roi_import_button.clicks) do _
        filepath = pick_non_empty_path(() -> pick_file(filterlist="zip,roi"); error_msg="ROI import file dialog failed")
        filepath === nothing && return

        rois = try
            read_rois(filepath)
        catch e
            @warn "Failed to read ROI file" path=filepath error=string(e)
            return
        end

        volume = pixel_volume[]
        if volume === nothing
            @warn "No image imported yet; cannot fit ROI lifetimes" path=filepath
            return
        end

        # vec_to_lifetime mutates the shared, non-thread-safe RUNTIME[]
        # singleton (FFT plans/caches) that the acquisition worker thread
        # also writes to — only safe to call here while no worker is running.
        if app_run.running[]
            @warn "Acquisition is running; skipping ROI lifetime fitting" path=filepath
            return
        end

        x_offset, y_offset = image_offset[]

        for roi in rois
            xs, ys = roi_boundary_points(roi)
            add_and_track_roi!(volume, x_offset, y_offset, xs, ys, roi.name)
        end

        @info "ROIs imported" path=filepath count=length(rois)
    end

    on(cellpose_button.clicks) do _
        volume = pixel_volume[]
        intensity = intensity_image[]
        if volume === nothing || intensity === nothing
            @warn "No image imported yet; cannot run Cellpose"
            return
        end

        # add_and_track_roi! -> add_roi_from_boundary! -> vec_to_lifetime
        # mutates the shared, non-thread-safe RUNTIME[] singleton the
        # acquisition worker thread also writes to — same guard as
        # roi_import_button above.
        if app_run.running[]
            @warn "Acquisition is running; skipping Cellpose segmentation"
            return
        end

        if cellpose_running[]
            @info "Cellpose is already running; ignoring click"
            return
        end
        cellpose_running[] = true
        cellpose_button.label[] = "Running..."

        # Segmentation is a slow (seconds-to-a-minute) external subprocess —
        # @async, not synchronous, for the same reason as start_pressed's own
        # heavy-lifting body (runtime.jl): this handler's call stack IS
        # GLMakie's render-loop task, and wait()-ing on the subprocess
        # in-line would freeze the window for the whole segmentation run.
        # Plain @async (not Threads.@spawn) keeps the ROI-drawing calls below
        # (poly!/lines!/text! onto image_axis) on the render-loop's own
        # thread, where touching GLMakie/Observables is safe.
        @async begin
            try
                masks = run_cellpose_segmentation(intensity)
                if masks === nothing
                    return   # run_cellpose_segmentation already logged why
                end

                x_offset, y_offset = image_offset[]
                labels = sort(filter(!=(0), unique(masks)))
                n_added = 0

                for label in labels
                    xs, ys = pixel_label_boundary(masks, label)
                    if isempty(xs)
                        @warn "Skipping a Cellpose object whose boundary could not be traced" label=label
                        continue
                    end
                    add_and_track_roi!(volume, x_offset, y_offset, xs, ys, "cellpose-$label")
                    n_added += 1
                end

                @info "Cellpose ROIs imported" found=length(labels) added=n_added
            finally
                cellpose_running[] = false
                cellpose_button.label[] = "Cellpose"
            end
        end
    end

    on(roi_clear_button.clicks) do _
        for roi in drawn_rois
            for p in roi.plots
                delete!(image_axis, p)
            end
        end
        empty!(drawn_rois)
        empty!(app_run.rois[])
        notify(app_run.rois)
    end

    on(popup_close_button.clicks) do _
        if isopen(popup_screen)
            close(popup_screen)
        end

        if roi_popup_screen[] === popup_screen
            roi_popup_screen[] = nothing
        end
    end

    on(events(popup_figure).window_open) do is_open
        if !is_open && roi_popup_screen[] === popup_screen
            roi_popup_screen[] = nothing
        end
    end

    display(popup_screen, popup_figure.scene)

    return nothing
end
