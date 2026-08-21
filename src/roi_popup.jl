"""
roi_popup.jl

ROI popup: load a reference image — either a TIFF chosen from disk or the
acquisition's current frame — import ROIs from ImageJ .roi/.zip files (via
ImageJROI.jl), display both on `image_axis`, and clear the ROI overlays on
demand.

The FLIM version's padded-row detection lived here too: SDT files from this
lab's scanner stored a half-height scan as a full-height image with every
other row left as dark counts, which had to be detected and collapsed. The
acquisition writes its real geometry directly (1024x512 stays 1024x512), so
that heuristic and the bounding-box trimming around it are gone.
"""

"""
    load_reference_image(filepath) -> Union{Nothing, Matrix{Float64}}

Load a TIFF as the grayscale reference image ROIs are drawn on.

Returns a matrix indexed `[x, y]` in the image's own pixel space — the same
convention `RoiCoordinates` uses — or `nothing` when the file cannot be read
as a supported TIFF.

Where the FLIM popup had to stream and reshape a compressed per-pixel TCSPC
volume (tens of gigabytes for a large file, hence the chunked reader and the
padded-row trimming that surrounded it), a ratiometric acquisition writes
plain uncompressed images. `BigTiffFile.read_frame` reads one directly, so all
of that machinery is gone along with the lifetime fitting it fed.
"""
function load_reference_image(filepath::AbstractString)::Union{Nothing, Matrix{Float64}}
    try
        pixels, _ = BigTiffFile.read_frame(filepath)
        return Float64.(pixels)
    catch e
        @warn "Failed to read TIFF image" path=filepath error=string(e)
        return nothing
    end
end

"""
    preview_reference_image(preview, position) -> Union{Nothing, Matrix{Float64}}

The live acquisition's most recent frame as a reference image, taken from the
downsampled `FramePreview` the consumer publishes.

This is the "capture the current frame" path: it lets ROIs be drawn on the
field actually being imaged rather than on a separately-imported file, which
is the only way to be sure the two are aligned. Its resolution is the
preview's, not the sensor's — coordinates are scaled back up by the caller
through `FramePreview.stride`.
"""
function preview_reference_image(preview::Union{Nothing, FramePreview}, position::Integer=1)::Union{Nothing, Matrix{Float64}}
    preview === nothing && return nothing
    isempty(preview.channel_images) && return nothing
    idx = clamp(Int(position), 1, length(preview.channel_images))
    return Float64.(preview.channel_images[idx])
end

# `point_in_polygon` used to live here; it is now shared from
# ratio_analysis.jl, which needs the same test to rasterize ROI masks for the
# acquisition. One implementation, so a ROI drawn here and a ROI measured
# there can never disagree about which pixels it covers.

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
    roi_mean_intensity(image::Matrix{Float64}, pixels::Vector{Tuple{Int,Int}})::Float64

Mean pixel value of `image` over `pixels` — what the ROI label reports, in
place of the lifetime the FLIM popup fitted from each ROI's summed TCSPC
histogram.
"""
function roi_mean_intensity(image::Matrix{Float64}, pixels::Vector{Tuple{Int,Int}})::Float64
    isempty(pixels) && return NaN
    total = 0.0
    for (x, y) in pixels
        total += image[x, y]
    end
    return total / length(pixels)
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
    add_roi_from_boundary!(image_axis, image, x_offset, y_offset, xs, ys, roi_label)::DrawnROI

Shared by imported ROIs (`roi_import_button`) and manually-drawn ROIs (hold
`A` and click on `image_axis`): given a closed polygon boundary in un-shifted,
image-local pixel coordinates (the same convention `roi_boundary_points`
returns), draw its translucent fill and outline on `image_axis`, select its
pixels, and label it with their mean intensity.

The FLIM version fitted a lifetime per ROI here and labelled it in ns; there
is no per-ROI fit to run in a ratiometric acquisition, and a mean intensity is
what usefully distinguishes one drawn region from another at draw time.
Always returns a `DrawnROI` bundling every plot object created (fill +
outline, optionally + label) for the caller to track.
"""
function add_roi_from_boundary!(image_axis, image::Matrix{Float64}, x_offset::Real, y_offset::Real, xs::Vector{Float64}, ys::Vector{Float64}, roi_label::AbstractString)::DrawnROI
    n_cols, n_rows = size(image)
    shifted_xs = xs .+ x_offset
    shifted_ys = ys .+ y_offset
    plots = Any[]

    if length(xs) >= 3
        push!(plots, poly!(image_axis, Point2f.(shifted_xs, shifted_ys), color=(PLOT_COLOR_REF, 0.1), strokewidth=0))
    end
    push!(plots, lines!(image_axis, shifted_xs, shifted_ys, color=PLOT_COLOR_REF, linewidth=PLOT_LINEWIDTH))

    pixels = roi_pixel_mask(xs, ys, n_cols, n_rows)
    if isempty(pixels)
        @warn "ROI contains no pixels" roi=roi_label
        return DrawnROI(shifted_xs, shifted_ys, plots)
    end

    mean_value = roi_mean_intensity(image, pixels)
    isfinite(mean_value) || return DrawnROI(shifted_xs, shifted_ys, plots)

    label_x = (minimum(xs) + maximum(xs)) / 2 + x_offset
    label_y = (minimum(ys) + maximum(ys)) / 2 + y_offset
    label_text = string(round(mean_value, digits=1))
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
convention) to `path` as the flat binary format
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

    # yreversed=true: image row 0 (ImageJ/TIFF's top-left pixel origin)
    # is plotted at the TOP of the axis — confirmed against real acquisitions
    # (a tissue/background boundary visible in the raw data, checked against
    # its known real-world position). Display-only (Makie handles the
    # screen<->data mapping transparently either way, so heatmap!/poly!/
    # lines! coordinates, mouseposition(), and every ROI pixel-mask/boundary
    # computation below all stay in the same 0-based (x=column, y=row) data
    # space regardless of this setting).
    # aspect=DataAspect(): keeps pixels square regardless of the axis
    # widget's own on-screen dimensions, so a non-square image (a 1024x512
    # acquisition, say) doesn't get stretched to fill the axis.
    # x/yrectzoom=false: Makie's default rectangle-zoom is also a left-click
    # drag, which would fight with manual ROI point-placement (hold A, left-
    # click) below.
    image_axis = Axis(axis_layout[1, 1]; merge(AXIS_IMAGE_ATTRS, Dict{Symbol, Any}(:title => "ROI Image", :yreversed => true, :aspect => DataAspect(), :xrectzoom => false, :yrectzoom => false))...)

    # The FLIM popup's lifetime-map overlay and its min-photons threshold are
    # gone — there is no per-pixel lifetime to map. The slot now selects which
    # acquisition channel a captured live frame is taken from.
    channel_label       = Label(buttons_layout[1, 1][1, 1];   merge(LABEL_ATTRS,  Dict{Symbol, Any}(:text => "Channel"))...)
    channel_menu        = Menu(buttons_layout[1, 1][1, 2];    merge(MENU_ATTRS,   Dict{Symbol, Any}(:options => ["1", "2", "3"], :default => "1"))...)
    live_frame_button   = Button(buttons_layout[2, 1];  merge(BUTTON_ATTRS, Dict{Symbol, Any}(:label => "Current frame"))...)

    im_import_button    = Button(buttons_layout[1, 2];  merge(BUTTON_ATTRS, Dict{Symbol, Any}(:label => "Import image"))...)
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
    # Grayscale image currently displayed, in its own [x, y] pixel space. ROI
    # pixel selection and the mean-intensity labels are computed from this.
    intensity_image = Ref{Union{Nothing, Matrix{Float64}}}(nothing)

    # drawn_rois and app_run.rois are kept in lockstep, index-for-index:
    # drawn_rois holds this popup's GUI plot objects (never leaves this
    # function), app_run.rois holds the plain boundary data other
    # panels/functions can read.
    function add_and_track_roi!(image::Matrix{Float64}, x_offset::Real, y_offset::Real, xs::Vector{Float64}, ys::Vector{Float64}, label::AbstractString)
        push!(drawn_rois, add_roi_from_boundary!(image_axis, image, x_offset, y_offset, xs, ys, label))
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
                    image = intensity_image[]
                    if image === nothing
                        @warn "No image loaded yet; cannot create manual ROI"
                    else
                        x_offset, y_offset = image_offset[]
                        xs = Float64[p[1] - x_offset for p in drawing_points]
                        ys = Float64[p[2] - y_offset for p in drawing_points]
                        push!(xs, xs[1])
                        push!(ys, ys[1])

                        manual_roi_count[] += 1
                        add_and_track_roi!(image, x_offset, y_offset, xs, ys, "manual-$(manual_roi_count[])")
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

    """
        show_reference_image!(image, source_label)

    Display `image` as the popup's grayscale backdrop and make it the data ROI
    pixel selection is computed from.

    The image is centered in a square canvas, so a non-square frame (this
    acquisition writes 1024x512 as readily as 1024x1024) is not stretched. The
    offset is recorded on `image_offset` so ROI overlays line up, and the
    un-padded size on `app_run.imported_image_size` so roi.jl's trigger-box
    voltage mapping can apply the same centering at START — long after this
    popup and its local offsets are gone.
    """
    function show_reference_image!(image::Matrix{Float64}, source_label::AbstractString)
        intensity_image[] = image

        n_cols, n_rows = size(image)
        canvas_size = max(n_cols, n_rows)
        x_offset = (canvas_size - n_cols) ÷ 2
        y_offset = (canvas_size - n_rows) ÷ 2
        image_offset[] = (x_offset, y_offset)
        app_run.imported_image_size = (n_cols, n_rows)

        if image_plot[] !== nothing
            delete!(image_axis, image_plot[])
        end
        image_plot[] = heatmap!(image_axis, x_offset:(x_offset + n_cols - 1), y_offset:(y_offset + n_rows - 1), image, colormap = :grays)

        # Set the limits attribute directly rather than calling limits!/ylims!:
        # those helpers reset ax.yreversed[] to false whenever the y-limits are
        # passed low-to-high (their own convention for "not reversed"), which
        # would silently undo the yreversed=true set at axis construction.
        image_axis.limits[] = (0, canvas_size, 0, canvas_size)

        @info "Reference image set" source=source_label size=(n_cols, n_rows) canvas_size=canvas_size offset=(x_offset, y_offset)
        return nothing
    end

    on(im_import_button.clicks) do _
        filepath = open_tiff_dialog()
        filepath === nothing && return

        image = load_reference_image(filepath)
        image === nothing && return

        show_reference_image!(image, basename(filepath))
    end

    # Capture whatever the acquisition is currently showing, so ROIs can be
    # drawn on the real field of view rather than on a separately-imported
    # file that may not be aligned with it.
    #
    # The captured frame is the *preview*, which is downsampled (see
    # FramePreview, data_types.jl). ROI coordinates are therefore in preview
    # pixels, and `imported_image_size` is set to the preview's own size by
    # show_reference_image! — which is what roi.jl's voltage mapping needs, since
    # it scales ROI coordinates by the image extent they were drawn in.
    on(live_frame_button.clicks) do _
        position = something(tryparse(Int, something(channel_menu.selection[], "1")), 1)
        image = preview_reference_image(app_run.preview[], position)

        if image === nothing
            @warn "No acquisition frame available yet; start a run or import an image instead"
            return
        end

        show_reference_image!(image, "live channel $position")
    end

    # Galvo voltage range textboxes: commit straight to app.roi (RoiSettings,
    # data_types.jl) and persist, so roi_trigger_buffer (roi.jl) picks up the
    # edited range next time it reads app.roi, and the range survives across
    # sessions like every other persisted setting.
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

        # No RUNTIME[] race to guard against any more: the FLIM version fitted
        # a lifetime per imported ROI, which mutated the shared FFT-plan
        # singleton the worker thread also wrote to. Labelling a ROI with a
        # mean intensity touches nothing shared, so ROIs can now be imported
        # while an acquisition is running.
        image = intensity_image[]
        if image === nothing
            @warn "No image loaded yet; cannot place ROIs" path=filepath
            return
        end

        x_offset, y_offset = image_offset[]

        for roi in rois
            xs, ys = roi_boundary_points(roi)
            add_and_track_roi!(image, x_offset, y_offset, xs, ys, roi.name)
        end

        @info "ROIs imported" path=filepath count=length(rois)
    end

    on(cellpose_button.clicks) do _
        intensity = intensity_image[]
        if intensity === nothing
            @warn "No image loaded yet; cannot run Cellpose"
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
                    add_and_track_roi!(intensity, x_offset, y_offset, xs, ys, "cellpose-$label")
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
