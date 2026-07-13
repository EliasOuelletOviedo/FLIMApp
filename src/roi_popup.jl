"""
roi_popup.jl

ROI popup: import a FLIM image from an .sdt file, import ROIs from ImageJ
.roi/.zip files (via ImageJROI.jl), display both on `image_axis`, and clear
the imported ROI overlays on demand.
"""

"""
Fixed image width (in pixels) for the `(n_pixels, adc_re)` per-pixel-vector
SDT layout (`extract_sdt_image`'s 2D branch). Real acquisitions from this
lab's setup don't populate `MeasureInfo.scan_x`/`scan_y` (both read back as
0), so the width can't be recovered from file metadata; height is derived
as `n_pixels ÷ SDT_IMAGE_WIDTH`.
"""
const SDT_IMAGE_WIDTH = 1024

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
    collapse_padded_rows(image::Matrix{Float64})::Matrix{Float64}

Some SDT acquisitions record at half the vertical resolution (e.g. a real
1024x512 scan) but still fill the full `SDT_IMAGE_WIDTH`-tall reshape,
padding every other row (`image[:, y]`) with near-zero filler. A genuine
full-height acquisition (e.g. a real 1024x1024 scan) has no such gap: real
signal lands in both odd- and even-indexed rows.

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
"""
function extract_sdt_volume(sdt::SdtFile.SdtData)::Union{Nothing, Array{Float64,3}}
    isempty(sdt.data) && return nothing
    block = sdt.data[1]

    if ndims(block) == 3
        return permutedims(Float64.(block), (2, 1, 3))
    elseif ndims(block) == 2
        n_pixels, n_bins = size(block)
        n_pixels % SDT_IMAGE_WIDTH == 0 || return nothing
        height = n_pixels ÷ SDT_IMAGE_WIDTH
        return Float64.(reshape(block, SDT_IMAGE_WIDTH, height, n_bins))
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
  spatial metadata — which is what this lab's own `.sdt` files actually
  contain (`scan_x`/`scan_y` read back as 0). Reshaped to
  `(SDT_IMAGE_WIDTH, height, adc_re)` and summed over the time-bin axis,
  matching the reshape used to reconstruct the image from raw pixel
  vectors: `reshape(pixels, width, height, bins)` then `sum(dims=3)`.
- 3D `(scan_y, scan_x, adc_re)`, when the file's `scan_x`/`scan_y` metadata
  is populated; summed over the time-bin axis and transposed to the
  `(x, y)` convention above.
"""
function extract_sdt_image(sdt::SdtFile.SdtData)::Union{Nothing, Matrix{Float64}}
    return first(extract_sdt_image_and_volume(sdt))
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
    push!(plots, lines!(image_axis, shifted_xs, shifted_ys, color=PLOT_COLOR_REF))

    pixels = roi_pixel_mask(xs, ys, n_cols, n_rows)
    if isempty(pixels)
        @warn "ROI contains no pixels; skipping lifetime fit" roi=roi_label
        return DrawnROI(shifted_xs, shifted_ys, plots)
    end

    summed_hist = roi_summed_histogram(volume, pixels)

    params_raw, _ = try
        vec_to_lifetime(summed_hist; guess=initial_guess_for_lifetime_count("1 lifetime"), histogram_resolution=n_bins)
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

    # yreversed: image row 0 (ImageJ/SdtFile's top-left pixel origin) is
    # plotted at the top of the axis, matching both the heatmap and the ROI
    # overlay's shared 0-based (x=column, y=row) pixel coordinates.
    # aspect=DataAspect(): keeps pixels square regardless of the axis
    # widget's own on-screen dimensions, so a non-square image (e.g. after
    # collapse_padded_rows halves the height) doesn't get stretched to fill
    # the axis.
    # x/yrectzoom=false: Makie's default rectangle-zoom is also a left-click
    # drag, which would fight with manual ROI point-placement (hold A, left-
    # click) below.
    image_axis = Axis(axis_layout[1, 1]; merge(AXIS_IMAGE_ATTRS, Dict{Symbol, Any}(:title => "ROI Image", :yreversed => true, :aspect => DataAspect(), :xrectzoom => false, :yrectzoom => false))...)

    im_import_button   = Button(buttons_layout[1, 1]; merge(BUTTON_ATTRS, Dict{Symbol, Any}(:label => "Import image"))...)
    cellpose_button    = Button(buttons_layout[2, 1]; merge(BUTTON_ATTRS, Dict{Symbol, Any}(:label => "Cellpose"))...)
    roi_import_button  = Button(buttons_layout[1, 2]; merge(BUTTON_ATTRS, Dict{Symbol, Any}(:label => "Import ROI"))...)
    roi_export_button  = Button(buttons_layout[2, 2]; merge(BUTTON_ATTRS, Dict{Symbol, Any}(:label => "Export ROI"))...)
    roi_clear_button   = Button(buttons_layout[1, 3]; merge(BUTTON_ATTRS, Dict{Symbol, Any}(:label => "Clear ROI"))...)
    popup_close_button = Button(buttons_layout[2, 3]; merge(BUTTON_ATTRS, Dict{Symbol, Any}(:label => "Close"))...)

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
                        push!(drawn_rois, add_roi_from_boundary!(image_axis, volume, x_offset, y_offset, xs, ys, "manual-$(manual_roi_count[])"))
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
            push!(drawing_preview_plots, scatter!(image_axis, drawing_points, color=PLOT_COLOR_REF))
            if length(drawing_points) >= 2
                push!(drawing_preview_plots, lines!(image_axis, drawing_points, color=PLOT_COLOR_REF, linestyle=:dash))
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
            end

            return Consume(true)
        end

        return Consume(false)
    end

    on(im_import_button.clicks) do _
        filepath = pick_non_empty_path(() -> pick_file(filterlist="sdt"); error_msg="Image import file dialog failed")
        filepath === nothing && return

        sdt = try
            SdtFile.read_sdt(read(filepath), basename(filepath))
        catch e
            @warn "Failed to read SDT file" path=filepath error=string(e)
            return
        end

        intensity, volume = extract_sdt_image_and_volume(sdt)
        if intensity === nothing
            @info "SDT file is a histogram, not an image; nothing to display" path=filepath
            return
        end
        pixel_volume[] = volume

        if image_plot[] !== nothing
            delete!(image_axis, image_plot[])
        end

        n_cols, n_rows = size(intensity)
        canvas_size = max(n_cols, n_rows)
        x_offset = (canvas_size - n_cols) ÷ 2
        y_offset = (canvas_size - n_rows) ÷ 2
        image_offset[] = (x_offset, y_offset)

        image_plot[] = heatmap!(image_axis, x_offset:(x_offset + n_cols - 1), y_offset:(y_offset + n_rows - 1), intensity, colormap = :grays)
        limits!(image_axis, 0, canvas_size, 0, canvas_size)

        @info "Image imported" path=filepath size=size(intensity) canvas_size=canvas_size offset=(x_offset, y_offset)
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
            push!(drawn_rois, add_roi_from_boundary!(image_axis, volume, x_offset, y_offset, xs, ys, roi.name))
        end

        @info "ROIs imported" path=filepath count=length(rois)
    end

    on(roi_clear_button.clicks) do _
        for roi in drawn_rois
            for p in roi.plots
                delete!(image_axis, p)
            end
        end
        empty!(drawn_rois)
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
