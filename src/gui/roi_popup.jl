"""
roi_popup.jl

ROI popup: acquire an image with the SPC-150N (the "Image" button: 100
frames with the scanner clocks, FLIMCore's `Imagerie`, the same rangement as
imagerie_photons.jl), draw ROIs on it by hand, import them from ImageJ
.roi/.zip files (via ImageJROI.jl) or segment them with Cellpose, and fit
each ROI's lifetime on its own decay, rebuilt from the image's raw photon
stream.
"""

"""The Image button's label (it acquires `ROI_IMAGE_FRAMES` frames, gui/spc_view.jl)."""
const IMAGE_BUTTON_LABEL = "Image ×$(ROI_IMAGE_FRAMES)"

"""
Colorbar label of the popup's lifetime map: a preview to place ROIs — each
pixel's mean arrival time minus the IRF's (`pixel_lifetime_map`), not a fit.
"""
const LIFETIME_PREVIEW_LABEL = "preview: mean time − IRF center [ns]"

"""Channel menu of the ROI popup: which card(s) the image shows (canal 1 is the FLIM channel)."""
const ROI_IMAGE_CHANNELS = ["Channel 1", "Channel 2", "Sum"]

"""
    RoiImage

The image the ROIs are drawn on: one channel's `ImageSomme` — or both
channels summed (`channel == 0`) —, with `intensity` and `sum_t` (summed
arrival times, ns) in FLIMApp's `(x, y)` = (pixel, line) convention, and
each card's raw photon stream (`streams`), which rebuilds any group of
pixels' decay (`roi_histograms`).
"""
struct RoiImage
    intensity::Matrix{Float64}
    sum_t::Matrix{Float64}
    streams::Vector{FLIMCore.ImageSomme}
    channel::Int
    cards::Vector{Int}
    frames::Int
end

RoiImage(img::FLIMCore.ImageSomme) = RoiImage([img], img.canal)

function RoiImage(parts::Vector{FLIMCore.ImageSomme}, channel::Integer)
    isempty(parts) && error("RoiImage: no card image")
    all(p -> size(p.intensite) == size(parts[1].intensite), parts) || error("RoiImage: card images of different sizes")
    intensity = permutedims(Float64.(reduce(+, (p.intensite for p in parts))))
    sum_t = permutedims(reduce(+, (p.somme_t for p in parts)))
    return RoiImage(intensity, sum_t, parts, Int(channel), [p.carte for p in parts], minimum(p.trames for p in parts))
end

"""
    roi_image_parts(parts, choice)::Vector{FLIMCore.ImageSomme}

The card images behind the popup's channel menu (`ROI_IMAGE_CHANNELS`):
"Channel i" is the card whose serial number is i-th in `[verification]
series` (`ImageSomme.canal`) — the i-th card by module number when no card
is identified —, "Sum" every card. Empty when that channel has no image.
"""
function roi_image_parts(parts::AbstractDict{Int, FLIMCore.ImageSomme}, choice::AbstractString)::Vector{FLIMCore.ImageSomme}
    sorted = [parts[k] for k in sort!(collect(keys(parts)))]
    choice == "Sum" && return sorted
    channel = choice == "Channel 2" ? 2 : 1
    by_serial = filter(p -> p.canal == channel, sorted)
    !isempty(by_serial) && return by_serial
    any(p -> p.canal > 0, sorted) && return FLIMCore.ImageSomme[]
    return channel <= length(sorted) ? [sorted[channel]] : FLIMCore.ImageSomme[]
end

"""The fit context of a ROI image's channel (`channel_fit_context`; channel 1's for a sum)."""
roi_image_fit_context(image::RoiImage) = channel_fit_context(image.channel == 2 ? 2 : 1)

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

1-based `(x, y)` indices into an `(n_cols, n_rows)` image whose pixel
center (the same 0-based `(x-1, y-1)` coordinate `roi_boundary_points`
returns, i.e. no offset applied) falls inside the closed polygon `(xs, ys)`
(`point_in_polygon`). Only scans the polygon's bounding box (clamped to the
image's extent), not the whole image.
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
`add_and_track_roi!` (and, downstream, `roi_scan_segments`'s hardware scan
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
    roi_histograms(image, pixel_sets)::Vector{Vector{Float64}}

Each pixel set's decay (`DEFAULT_HISTOGRAM_RESOLUTION` channels, the
analysis resolution), rebuilt from `image`'s raw photon stream in a single
pass (`FLIMCore.histogrammes_pixels`). `pixel_sets` are 1-based `(x, y)`
pixels, as `roi_pixel_mask` returns them; a pixel claimed by two sets goes
to the later one. A summed image's decays are summed over its cards.
"""
function roi_histograms(image::RoiImage, pixel_sets::Vector{Vector{Tuple{Int,Int}}})::Vector{Vector{Float64}}
    n_cols, n_rows = size(image.intensity)
    labels = zeros(Int, n_rows, n_cols)                 # lines × pixels, like the SPC image
    for (k, pixels) in enumerate(pixel_sets), (x, y) in pixels
        labels[y, x] = k
    end
    H = zeros(Float64, DEFAULT_HISTOGRAM_RESOLUTION, length(pixel_sets))
    for part in image.streams                           # summed over the image's cards
        H .+= FLIMCore.histogrammes_pixels(part.mots, part.tic_s, part.geometrie, labels, length(pixel_sets);
                                           canaux = DEFAULT_HISTOGRAM_RESOLUTION)
    end
    return [H[:, k] for k in eachindex(pixel_sets)]
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
    add_roi_from_boundary!(image_axis, histogram, x_offset, y_offset, xs, ys, roi_label)::DrawnROI

Shared by imported, Cellpose and manually-drawn ROIs: given a closed polygon
boundary in un-shifted image pixel coordinates (the same convention
`roi_boundary_points` returns) and the ROI's decay (`roi_histograms`;
`nothing` or empty when the ROI covers no pixel), draw its translucent fill
and outline on `image_axis` and fit its lifetime against `fit_ctx` (the
image channel's IRF, `roi_image_fit_context`) — adding a label at the
ROI's center if the fit converges, or just warning under `roi_label`
otherwise. Always returns a `DrawnROI` bundling every plot object created
(fill + outline, optionally + label) for the caller to track.
"""
function add_roi_from_boundary!(image_axis, histogram::Union{Nothing, Vector{Float64}}, x_offset::Real, y_offset::Real,
                                xs::Vector{Float64}, ys::Vector{Float64}, roi_label::AbstractString;
                                fit_ctx::RuntimeContext = fit_context())::DrawnROI
    shifted_xs = xs .+ x_offset
    shifted_ys = ys .+ y_offset
    plots = Any[]

    if length(xs) >= 3
        push!(plots, poly!(image_axis, Point2f.(shifted_xs, shifted_ys), color=(PLOT_COLOR_REF, 0.1), strokewidth=0))
    end
    push!(plots, lines!(image_axis, shifted_xs, shifted_ys, color=PLOT_COLOR_REF, linewidth=PLOT_LINEWIDTH))

    if histogram === nothing || sum(histogram) == 0
        @warn "ROI contains no photon; skipping lifetime fit" roi=roi_label
        return DrawnROI(shifted_xs, shifted_ys, plots)
    end

    params_raw, _ = try
        with_fit_context(fit_ctx) do
            vec_to_lifetime(histogram; guess=initial_guess_for_lifetimes("1 lifetime"), histogram_resolution=length(histogram))
        end
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
const CELLPOSE_SEGMENT_SCRIPT = read(normpath(joinpath(@__DIR__, "..", "..", "scripts", "cellpose_segment.py")), String)

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
convention — see `RoiImage`) to `path` as the flat binary format
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

    # yreversed=true: image row 0 (ImageJ's top-left pixel origin, and the
    # scanner's first line after its frame clock) is plotted at the TOP of
    # the axis. Display-only (Makie handles the
    # screen<->data mapping transparently either way, so heatmap!/poly!/
    # lines! coordinates, mouseposition(), and every ROI pixel-mask/boundary
    # computation below all stay in the same 0-based (x=column, y=row) data
    # space regardless of this setting).
    # aspect=DataAspect(): keeps pixels square regardless of the axis
    # widget's own on-screen dimensions, so a non-square image (the SPC
    # image is pixels-per-line × lines) doesn't get stretched to fill the
    # axis.
    # x/yrectzoom=false: Makie's default rectangle-zoom is also a left-click
    # drag, which would fight with manual ROI point-placement (hold A, left-
    # click) below.
    image_axis = Axis(axis_layout[1, 1]; merge(AXIS_IMAGE_ATTRS, Dict{Symbol, Any}(:title => "ROI Image", :yreversed => true, :aspect => DataAspect(), :xrectzoom => false, :yrectzoom => false))...)

    # First-moment (mean-arrival-time) per-pixel lifetime preview — see
    # pixel_lifetime_map (lifetime_analysis.jl) and refresh_image_display!
    # below. min_photons_textbox's default matches pixel_lifetime_map's own.
    lifetime_map_label  = Label(buttons_layout[1, 1][1, 1];   merge(LABEL_ATTRS,  Dict{Symbol, Any}(:text => "Lifetime preview"))...)
    min_photons_label   = Label(buttons_layout[2, 1][1, 1];   merge(LABEL_ATTRS,  Dict{Symbol, Any}(:text => "Min photons"))...)
    lifetime_map_toggle = Toggle(buttons_layout[1, 1][1, 2];  merge(TOGGLE_ATTRS, Dict{Symbol, Any}(:active => false))...)
    min_photons_textbox = Textbox(buttons_layout[2, 1][1, 2]; merge(TEXT_ATTRS,   Dict{Symbol, Any}(:displayed_string => "50", :stored_string => "50"))...)

    im_import_button    = Button(buttons_layout[1, 2];  merge(BUTTON_ATTRS, Dict{Symbol, Any}(:label => IMAGE_BUTTON_LABEL))...)
    cellpose_button     = Button(buttons_layout[2, 2];  merge(BUTTON_ATTRS, Dict{Symbol, Any}(:label => "Cellpose"))...)
    roi_import_button   = Button(buttons_layout[1, 3];  merge(BUTTON_ATTRS, Dict{Symbol, Any}(:label => "Import ROI"))...)
    roi_export_button   = Button(buttons_layout[2, 3];  merge(BUTTON_ATTRS, Dict{Symbol, Any}(:label => "Export ROI"))...)
    roi_clear_button    = Button(buttons_layout[1, 4];  merge(BUTTON_ATTRS, Dict{Symbol, Any}(:label => "Clear ROI"))...)
    popup_close_button  = Button(buttons_layout[2, 4];  merge(BUTTON_ATTRS, Dict{Symbol, Any}(:label => "Close"))...)

    x_min_label = Label(buttons_layout[3, 1]; merge(LABEL_ATTRS, Dict{Symbol, Any}(:text => "X min [mV]"))...)
    x_max_label = Label(buttons_layout[3, 2]; merge(LABEL_ATTRS, Dict{Symbol, Any}(:text => "X max [mV]"))...)
    y_min_label = Label(buttons_layout[3, 3]; merge(LABEL_ATTRS, Dict{Symbol, Any}(:text => "Y min [mV]"))...)
    y_max_label = Label(buttons_layout[3, 4]; merge(LABEL_ATTRS, Dict{Symbol, Any}(:text => "Y max [mV]"))...)

    x_min_textbox = Textbox(buttons_layout[4, 1]; merge(TEXT_ATTRS, Dict{Symbol, Any}(:displayed_string => string(app.roi.v_min_x), :stored_string => string(app.roi.v_min_x), :width => 100))...)
    x_max_textbox = Textbox(buttons_layout[4, 2]; merge(TEXT_ATTRS, Dict{Symbol, Any}(:displayed_string => string(app.roi.v_max_x), :stored_string => string(app.roi.v_max_x), :width => 100))...)
    y_min_textbox = Textbox(buttons_layout[4, 3]; merge(TEXT_ATTRS, Dict{Symbol, Any}(:displayed_string => string(app.roi.v_min_y), :stored_string => string(app.roi.v_min_y), :width => 100))...)
    y_max_textbox = Textbox(buttons_layout[4, 4]; merge(TEXT_ATTRS, Dict{Symbol, Any}(:displayed_string => string(app.roi.v_max_y), :stored_string => string(app.roi.v_max_y), :width => 100))...)

    # Which card the image shows (channel 1, the FLIM channel, by default).
    channel_menu = Menu(buttons_layout[5, 1]; merge(MENU_ATTRS, Dict{Symbol, Any}(:options => ROI_IMAGE_CHANNELS, :default => "Channel 1"))...)

    # What the Image button did last (acquiring, size, photons, or why not).
    popup_status = Observable("Image: $(ROI_IMAGE_FRAMES) frames from the SPC-150N (scanner running)")
    Label(buttons_layout[5, 2:4], popup_status; merge(LABEL_ATTRS, Dict{Symbol, Any}(:halign => :left, :tellwidth => false))...)

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
    # The SPC image backing the display — summed arrival times for the
    # lifetime map, raw photon stream for each ROI's decay (`RoiImage`) —
    # and every card's image of the last acquisition (the channel menu
    # switches between them).
    roi_image = Ref{Union{Nothing, RoiImage}}(nothing)
    image_parts = Ref{Union{Nothing, Dict{Int, FLIMCore.ImageSomme}}}(nothing)
    # An Image request is out (the engine is acquiring).
    image_requested = Ref(false)
    # Grayscale intensity image for the currently displayed image, cached
    # alongside roi_image so update_lifetime_overlay! (below) can redraw
    # the overlay without recomputing it.
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
    lifetime_analysis.jl) from the cached `roi_image`/`min_photons` and
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
    lifetime_overlay_request = Ref(0)

    function update_lifetime_overlay!()
        image = roi_image[]
        image === nothing && return nothing
        threshold = min_photons[]
        lifetime_overlay_request[] += 1
        request = lifetime_overlay_request[]

        # The per-pixel fit is heavy: computed on a worker thread, drawn
        # back here on the GUI thread (this @async task stays on it).
        @async begin
            lifetime_map = try
                ctx = roi_image_fit_context(image)
                fetch(Threads.@spawn pixel_lifetime_map(image.intensity, image.sum_t; min_photons=threshold, ctx=ctx))
            catch e
                @warn "Failed to compute pixel lifetime map" error=string(e)
                return nothing
            end
            # A newer import or threshold edit has superseded this request.
            request == lifetime_overlay_request[] || return nothing
            draw_lifetime_overlay!(lifetime_map, threshold)
        end
        return nothing
    end

    function draw_lifetime_overlay!(lifetime_map, threshold)
        if lifetime_map_plot[] !== nothing
            delete!(image_axis, lifetime_map_plot[])
            lifetime_map_plot[] = nothing
        end
        if lifetime_colorbar[] !== nothing
            delete!(lifetime_colorbar[])
            lifetime_colorbar[] = nothing
        end

        finite_values = filter(isfinite, vec(lifetime_map))
        if isempty(finite_values)
            @warn "No pixel has enough photons for a lifetime map" min_photons=threshold
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
            lifetime_colorbar[] = Colorbar(axis_layout[1, 2]; colormap = :turbo, limits = (lo, hi), label = LIFETIME_PREVIEW_LABEL)
        end

        return nothing
    end

    # drawn_rois and app_run.rois are kept in lockstep, index-for-index:
    # drawn_rois holds this popup's GUI plot objects (never leaves this
    # function), app_run.rois holds the plain boundary data other
    # panels/functions can read.
    function add_and_track_roi!(histogram, x_offset::Real, y_offset::Real, xs::Vector{Float64}, ys::Vector{Float64}, label::AbstractString)
        image = roi_image[]
        ctx = image === nothing ? fit_context() : roi_image_fit_context(image)
        push!(drawn_rois, add_roi_from_boundary!(image_axis, histogram, x_offset, y_offset, xs, ys, label; fit_ctx = ctx))
        # Both cards see the same pixels: the ROI holds for both channels;
        # the session records which one its lifetime was fitted on.
        push!(app_run.rois[], RoiCoordinates(String(label), xs, ys, image === nothing ? -1 : image.channel))
        notify(app_run.rois)
        n = length(app_run.rois[])
        n > ROI_MAX && (popup_status[] = "$n ROIs: the Realtime mode takes at most $ROI_MAX (4-bit routing code, code 0 reserved)")
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
                    image = roi_image[]
                    if image === nothing
                        @warn "No image acquired yet; cannot create manual ROI"
                    elseif app_run.running[]
                        @warn "Acquisition is running; skipping manual ROI lifetime fitting"
                    else
                        x_offset, y_offset = image_offset[]
                        xs = Float64[p[1] - x_offset for p in drawing_points]
                        ys = Float64[p[2] - y_offset for p in drawing_points]
                        push!(xs, xs[1])
                        push!(ys, ys[1])

                        manual_roi_count[] += 1
                        pixels = roi_pixel_mask(xs, ys, size(image.intensity)...)
                        histogram = isempty(pixels) ? nothing : only(roi_histograms(image, [pixels]))
                        add_and_track_roi!(histogram, x_offset, y_offset, xs, ys, "manual-$(manual_roi_count[])")
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

    # Image: ROI_IMAGE_FRAMES frames from the SPC-150N (FLIMCore's Imagerie,
    # keeping the raw stream). The engine acquires on its own thread; the
    # result comes back through the refresh tick into app_run.spc.roi_image,
    # listened to below (and released when this popup closes).
    on(im_import_button.clicks) do _
        image_requested[] && return
        reason = spc_request_roi_image!(app_run.spc)
        if !isempty(reason)
            popup_status[] = "Image: " * reason
            @warn "Cannot acquire the ROI image" reason=reason
            return
        end
        image_requested[] = true
        im_import_button.label[] = "Acquiring…"
        popup_status[] = "Acquiring $(ROI_IMAGE_FRAMES) frames…"
    end

    # Show the menu's channel of the last acquisition: base image, lifetime
    # preview, the size the ROIs are drawn on.
    function show_channel_image!()
        parts = image_parts[]
        parts === nothing && return nothing
        choice = channel_menu.selection[]
        choice isa AbstractString || (choice = "Channel 1")
        selected = roi_image_parts(parts, choice)
        if isempty(selected)
            popup_status[] = "$choice: no image (cards: $(join(sort!(collect(keys(parts))), ", ")))"
            return nothing
        end
        image = RoiImage(selected, choice == "Sum" ? 0 : choice == "Channel 2" ? 2 : 1)
        cards = join(image.cards, " + ")
        if sum(image.intensity) == 0
            popup_status[] = "$choice (card $cards): no photon in the image (laser, detectors?)"
            return nothing
        end
        roi_image[] = image
        intensity = image.intensity
        intensity_image[] = intensity

        n_cols, n_rows = size(intensity)
        canvas_size = max(n_cols, n_rows)
        x_offset = (canvas_size - n_cols) ÷ 2
        y_offset = (canvas_size - n_rows) ÷ 2
        image_offset[] = (x_offset, y_offset)
        # Recorded so the galvo voltage mapping (roi_geometry.jl) can apply this
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
        # Set the limits attribute directly rather than calling limits!/ylims!:
        # those helpers reset ax.yreversed[] to false whenever the y-limits are
        # passed low-to-high (their own convention for "not reversed"), which
        # would silently undo the yreversed=true set at axis construction.
        image_axis.limits[] = (0, canvas_size, 0, canvas_size)
        image_axis.title[] = "ROI image — $choice"

        popup_status[] = "$choice (card $cards): $(image.frames) frames, $(round(Int, sum(intensity))) photons, $n_cols × $n_rows pixels"
        @info "ROI image shown" channel=choice cards=image.cards frames=image.frames size=size(intensity)
        return nothing
    end

    image_listener = on(app_run.spc.roi_image) do parts
        image_requested[] || return
        image_requested[] = false
        im_import_button.label[] = IMAGE_BUTTON_LABEL
        if parts === nothing || isempty(parts) || all(p -> isempty(p.mots), values(parts))
            popup_status[] = "No image: no line/frame clock? (see the SPC window's alerts)"
            return
        end
        image_parts[] = parts
        show_channel_image!()
    end

    # Another channel of the same acquisition: no new image is taken. ROIs
    # already drawn keep the lifetime fit on the channel they were drawn on.
    on(channel_menu.selection) do _
        show_channel_image!()
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
                lifetime_colorbar[] = Colorbar(axis_layout[1, 2]; colormap = :turbo, limits = (lo, hi), label = LIFETIME_PREVIEW_LABEL)
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

    # Galvo voltage range textboxes: commit straight to app.roi (RoiSettings,
    # data_types.jl) and persist, so the next START's scan (roi_geometry.jl)
    # uses the edited range, and the range survives across sessions like
    # every other persisted setting.
    for (textbox, field) in ((x_min_textbox, :v_min_x), (x_max_textbox, :v_max_x), (y_min_textbox, :v_min_y), (y_max_textbox, :v_max_y))
        on(textbox.stored_string) do new_str
            val = tryparse(Int64, new_str)
            if val !== nothing
                setfield!(app.roi, field, val)
                textbox.displayed_string[] = string(val)
            else
                textbox.displayed_string[] = string(getfield(app.roi, field))
                textbox.stored_string[]    = string(getfield(app.roi, field))
            end

            save_state(app)
        end
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

        image = roi_image[]
        if image === nothing
            @warn "No image acquired yet; cannot fit ROI lifetimes" path=filepath
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
        boundaries = [roi_boundary_points(roi) for roi in rois]
        histograms = roi_histograms(image, [roi_pixel_mask(xs, ys, size(image.intensity)...) for (xs, ys) in boundaries])

        for (k, roi) in enumerate(rois)
            xs, ys = boundaries[k]
            add_and_track_roi!(histograms[k], x_offset, y_offset, xs, ys, roi.name)
        end

        @info "ROIs imported" path=filepath count=length(rois)
    end

    on(cellpose_button.clicks) do _
        image = roi_image[]
        intensity = intensity_image[]
        if image === nothing || intensity === nothing
            @warn "No image acquired yet; cannot run Cellpose"
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
                traced = Tuple{Int, Vector{Float64}, Vector{Float64}}[]
                for label in labels
                    xs, ys = pixel_label_boundary(masks, label)
                    if isempty(xs)
                        @warn "Skipping a Cellpose object whose boundary could not be traced" label=label
                        continue
                    end
                    push!(traced, (label, xs, ys))
                end
                # Every object's decay in one pass over the raw stream, off the GUI thread.
                pixel_sets = [roi_pixel_mask(xs, ys, size(image.intensity)...) for (_, xs, ys) in traced]
                histograms = fetch(Threads.@spawn roi_histograms(image, pixel_sets))
                for (k, (label, xs, ys)) in enumerate(traced)
                    add_and_track_roi!(histograms[k], x_offset, y_offset, xs, ys, "cellpose-$label")
                end
                n_added = length(traced)

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
        is_open && return
        off(image_listener)          # app_run.spc.roi_image outlives this popup
        if roi_popup_screen[] === popup_screen
            roi_popup_screen[] = nothing
        end
    end

    display(popup_screen, popup_figure.scene)

    return nothing
end
