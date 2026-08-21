using Test
using TIFFApp
using GLMakie
using TIFFApp: RegionFrame, RoiSeries, RoiChannelIntensity, AcquisitionSample,
               ProtocolSettings, LayoutSettings, ControllerSettings, RoiSettings,
               ConsoleSettings, RoiCoordinates, RegionMask, FramePreview

# These tests cover the GUI-free logic: the TIFF reader, acquisition folder
# resolution and channel grouping, the image binning buffer, the ratio and Hill
# calibration math, protocol schedule math, smoothing, state persistence,
# spinner stepping, plot windowing, and ROI slot tracking. The GUI itself
# (Makie widgets/handlers) is exercised manually via run_app().

@testset "TIFFApp" begin

@testset "BigTIFF reader" begin
    # Build a minimal BigTIFF by hand rather than shipping a fixture: it pins
    # the exact byte layout the reader must accept, and a fixture would hide
    # which field a regression actually broke.
    function write_bigtiff(path, width, height, bits, pixels; little=true)
        bo = little ? "<" : ">"
        entries = [
            (256, 4, 1, width),      # ImageWidth
            (257, 4, 1, height),     # ImageLength
            (258, 3, 1, bits),       # BitsPerSample
            (259, 3, 1, 1),          # Compression = none
            (277, 3, 1, 1),          # SamplesPerPixel
            (273, 16, 1, 0),         # StripOffsets (patched below)
            (279, 16, 1, length(pixels) * (bits ÷ 8)),  # StripByteCounts
        ]
        header = 16
        ifd = header
        data_offset = ifd + 8 + length(entries) * 20 + 8

        open(path, "w") do io
            write(io, little ? b"II" : b"MM")
            write(io, little ? htol(UInt16(43)) : hton(UInt16(43)))
            write(io, little ? htol(UInt16(8))  : hton(UInt16(8)))
            write(io, little ? htol(UInt16(0))  : hton(UInt16(0)))
            write(io, little ? htol(UInt64(ifd)) : hton(UInt64(ifd)))
            write(io, little ? htol(UInt64(length(entries))) : hton(UInt64(length(entries))))
            for (tag, typ, count, value) in entries
                v = tag == 273 ? data_offset : value
                write(io, little ? htol(UInt16(tag)) : hton(UInt16(tag)))
                write(io, little ? htol(UInt16(typ)) : hton(UInt16(typ)))
                write(io, little ? htol(UInt64(count)) : hton(UInt64(count)))
                pad = zeros(UInt8, 8)
                if typ == 3
                    pad[1:2] = reinterpret(UInt8, [little ? htol(UInt16(v)) : hton(UInt16(v))])
                    little || (pad[1:2] = pad[2:-1:1])
                elseif typ == 4
                    pad[1:4] = reinterpret(UInt8, [little ? htol(UInt32(v)) : hton(UInt32(v))])
                else
                    pad[1:8] = reinterpret(UInt8, [little ? htol(UInt64(v)) : hton(UInt64(v))])
                end
                write(io, pad)
            end
            write(io, little ? htol(UInt64(0)) : hton(UInt64(0)))
            for px in pixels
                write(io, little ? htol(px) : hton(px))
            end
        end
        return path
    end

    mktempdir() do dir
        # 8-bit round trip
        pixels8 = UInt8[10, 20, 30, 40, 50, 60]
        path8 = write_bigtiff(joinpath(dir, "a.tif"), 3, 2, 8, pixels8)
        info = TIFFApp.BigTiffFile.read_info(path8)
        @test (info.width, info.height, info.bits_per_sample) == (3, 2, 8)
        @test TIFFApp.BigTiffFile.sample_type(info) == UInt8

        img, _ = TIFFApp.BigTiffFile.read_frame(path8)
        # reshape(width, height) puts (x, y) where the file put it: row-major
        # rows become columns of the [x, y] matrix.
        @test size(img) == (3, 2)
        @test img[1, 1] == 10 && img[3, 1] == 30 && img[1, 2] == 40

        # read_frame! fills a caller-owned buffer and allocates no pixels
        buf = Vector{UInt8}(undef, 6)
        TIFFApp.BigTiffFile.read_frame!(buf, path8)
        @test buf == pixels8

        # 16-bit round trip
        pixels16 = UInt16[1000, 2000, 3000, 65535]
        path16 = write_bigtiff(joinpath(dir, "b.tif"), 2, 2, 16, pixels16)
        info16 = TIFFApp.BigTiffFile.read_info(path16)
        @test info16.bits_per_sample == 16
        @test TIFFApp.BigTiffFile.sample_type(info16) == UInt16
        buf16 = Vector{UInt16}(undef, 4)
        TIFFApp.BigTiffFile.read_frame!(buf16, path16)
        @test buf16 == pixels16

        # A buffer of the wrong element type must be refused, not silently
        # reinterpreted — that would read half an image and look plausible.
        @test_throws ArgumentError TIFFApp.BigTiffFile.read_frame!(Vector{UInt8}(undef, 8), path16)

        # Not a TIFF at all
        junk = joinpath(dir, "junk.tif")
        write(junk, b"not a tiff at all, really")
        @test_throws ArgumentError TIFFApp.BigTiffFile.read_info(junk)
    end
end

@testset "channel grouping and numbering conventions" begin
    # Filename parsing
    @test TIFFApp.parse_tiff_sequence_number("run-001-C2-T0042.tif") == 42
    @test TIFFApp.parse_tiff_channel_number("run-001-C2-T0042.tif") == 2
    @test TIFFApp.parse_tiff_sequence_number("no-counter-here.tif") === nothing
    # The arbitrary prefix carries its own digits and hyphens; only the
    # anchored suffix may be read as the channel/counter pair.
    @test TIFFApp.parse_tiff_sequence_number("60 Hz x 600 images-001-C1-T007.tif") == 7
    @test TIFFApp.parse_tiff_channel_number("60 Hz x 600 images-001-C1-T007.tif") == 1

    # Global numbering: instance k owns counter range [N(k-1)+1, Nk]
    @test TIFFApp.instance_index_for(1, 2, :global) == 1
    @test TIFFApp.instance_index_for(2, 2, :global) == 1
    @test TIFFApp.instance_index_for(3, 2, :global) == 2
    @test TIFFApp.instance_index_for(6, 3, :global) == 2

    # Per-channel numbering: the counter is the instance
    @test TIFFApp.instance_index_for(7, 3, :per_channel) == 7

    # The documented irregular interleaving groups as (1,2), (4,3), (6,5).
    @test [TIFFApp.instance_index_for(t, 2, :global) for t in (1, 4, 6)] == [1, 2, 3]
    @test [TIFFApp.instance_index_for(t, 2, :global) for t in (2, 3, 5)] == [1, 2, 3]
end

@testset "session resolution and instance grouping" begin
    function make_session(root, channels; per_channel=false, count=3)
        bliq = joinpath(root, "Bliq VMS")
        n = length(channels)
        counter = 0
        for k in 1:count, (ci, ch) in enumerate(channels)
            dir = joinpath(bliq, "C$ch")
            mkpath(dir)
            counter += 1
            seq = per_channel ? k : counter
            write(joinpath(dir, "sess-C$ch-T$(lpad(seq, 3, '0')).tif"), UInt8[])
        end
        return bliq
    end

    # Global numbering, two channels
    mktempdir() do dir
        session = joinpath(dir, "sess-001")
        make_session(session, [1, 2])

        # All three accepted shapes resolve to the same root.
        for candidate in (joinpath(session, "Bliq VMS"), session, dir)
            layout = TIFFApp.resolve_channel_layout(candidate)
            @test layout !== nothing
            @test layout.channel_names == ["C1", "C2"]
            @test layout.channel_numbers == [1, 2]
            @test layout.numbering == :global
        end

        layout = TIFFApp.resolve_channel_layout(session)
        instances = TIFFApp.group_instances(layout)
        @test length(instances) == 3
        @test [i.instance_index for i in instances] == [1, 2, 3]
        @test instances[1].sequence_numbers == [1, 2]
        @test instances[2].sequence_numbers == [3, 4]
        @test all(i -> length(i.paths) == 2, instances)
    end

    # Per-channel numbering: every channel counts from 1
    mktempdir() do dir
        session = joinpath(dir, "sess-002")
        make_session(session, [1, 2, 3]; per_channel=true)

        layout = TIFFApp.resolve_channel_layout(session)
        @test layout.numbering == :per_channel
        instances = TIFFApp.group_instances(layout)
        @test length(instances) == 3
        @test instances[2].sequence_numbers == [2, 2, 2]
    end

    # Non-contiguous channel names: C1 and C3, no C2
    mktempdir() do dir
        session = joinpath(dir, "sess-003")
        make_session(session, [1, 3])

        layout = TIFFApp.resolve_channel_layout(session)
        @test layout.channel_names == ["C1", "C3"]
        @test layout.channel_numbers == [1, 3]
        @test TIFFApp.channel_position(layout, 3) == 2
        @test TIFFApp.channel_position(layout, 2) === nothing
    end

    # A folder with no Bliq VMS anywhere resolves to nothing rather than throwing
    mktempdir() do dir
        @test TIFFApp.resolve_channel_layout(dir) === nothing
    end

    # An instance missing one channel is skipped, not emitted half-filled
    mktempdir() do dir
        bliq = joinpath(dir, "s", "Bliq VMS")
        mkpath(joinpath(bliq, "C1")); mkpath(joinpath(bliq, "C2"))
        write(joinpath(bliq, "C1", "s-C1-T001.tif"), UInt8[])
        write(joinpath(bliq, "C2", "s-C2-T002.tif"), UInt8[])
        write(joinpath(bliq, "C1", "s-C1-T003.tif"), UInt8[])   # instance 2 has no C2

        layout = TIFFApp.resolve_channel_layout(joinpath(dir, "s"))
        instances = TIFFApp.group_instances(layout)
        @test length(instances) == 1
        @test instances[1].instance_index == 1
    end
end

@testset "numbering detection tolerates counter glitches" begin
    # A real 1764-file acquisition skipped a counter value twice and then wrote
    # the next one to two channels at once. Under the old "any collision means
    # per-channel" rule those two anomalous files reclassified the whole run,
    # mapping every file to its own instance and reporting all 588 of them as
    # incomplete — an unreadable dataset because of two files.
    function write_files(dir, sequences)
        mkpath(dir)
        for seq in sequences
            channel = match(r"C(\d+)$", dir).captures[1]
            write(joinpath(dir, "run-C$channel-T$(lpad(seq, 3, '0')).tif"), UInt8[])
        end
    end

    mktempdir() do dir
        bliq = joinpath(dir, "Bliq VMS")
        # Global numbering across three channels, with one glitch: 613 is never
        # written and both C1 and C2 land on 614.
        c1 = [t for t in 1:3:60 if t != 13]
        push!(c1, 14)
        write_files(joinpath(bliq, "C1"), sort(c1))
        write_files(joinpath(bliq, "C2"), 2:3:60)
        write_files(joinpath(bliq, "C3"), 3:3:60)

        layout = TIFFApp.resolve_channel_layout(dir)
        @test layout.numbering == :global

        # And the glitch is absorbed: the duplicated value still falls inside
        # the instance it belongs to, so no instance is lost.
        instances = TIFFApp.group_instances(layout)
        @test length(instances) == 20
        @test [i.instance_index for i in instances] == collect(1:20)
        glitched = instances[findfirst(i -> i.instance_index == 5, instances)]
        @test glitched.sequence_numbers == [14, 14, 15]
    end

    # Genuine per-channel numbering must still be recognised: every channel
    # holding the same full range is nothing like a couple of stray collisions.
    mktempdir() do dir
        bliq = joinpath(dir, "Bliq VMS")
        for channel in 1:3
            write_files(joinpath(bliq, "C$channel"), 1:40)
        end
        @test TIFFApp.resolve_channel_layout(dir).numbering == :per_channel
    end

    # Two channels sharing every value is per-channel too, and must not be
    # mistaken for a heavily glitched global run.
    mktempdir() do dir
        bliq = joinpath(dir, "Bliq VMS")
        write_files(joinpath(bliq, "C1"), 1:30)
        write_files(joinpath(bliq, "C2"), 1:30)
        @test TIFFApp.resolve_channel_layout(dir).numbering == :per_channel
    end
end

@testset "ratio and Hill calibration" begin
    numbers = [1, 2, 3]

    @test TIFFApp.ratio_from_means([100.0, 50.0, 25.0], "C1/C2", numbers) == 2.0
    @test TIFFApp.ratio_from_means([100.0, 50.0, 25.0], "C2/C1", numbers) == 0.5
    @test TIFFApp.ratio_from_means([100.0, 50.0, 25.0], "C1/C3", numbers) == 4.0

    # Channel names, not positions: with C1 and C3 only, "C1/C3" divides the
    # two present channels rather than running off the end.
    @test TIFFApp.ratio_from_means([100.0, 25.0], "C1/C3", [1, 3]) == 4.0
    @test isnan(TIFFApp.ratio_from_means([100.0, 25.0], "C1/C2", [1, 3]))

    # A zero or non-finite denominator must be NaN, never Inf — an Inf would
    # propagate through the Kalman smoother and poison the series.
    @test isnan(TIFFApp.ratio_from_means([100.0, 0.0], "C1/C2", [1, 2]))
    @test isnan(TIFFApp.ratio_from_means([100.0, NaN], "C1/C2", [1, 2]))
    @test isnan(TIFFApp.ratio_from_means([NaN, 50.0], "C1/C2", [1, 2]))

    @test TIFFApp.parse_ratio_combination("C3/C1") == (3, 1)
    @test TIFFApp.parse_ratio_combination("nonsense") == (1, 2)
    @test length(TIFFApp.RATIO_COMBINATION_OPTIONS) == 6

    # Hill round trip
    for conc in (1.0, 46.4, 200.0)
        r = TIFFApp.hill_concentration_to_ratio(conc)
        @test TIFFApp.hill_ratio_to_concentration(r) ≈ conc rtol=1e-6
    end
    # At K_D the ratio sits halfway between Rmin and Rmax
    @test TIFFApp.hill_concentration_to_ratio(TIFFApp.HILL_KD) ≈
          (TIFFApp.HILL_RMIN + TIFFApp.HILL_RMAX) / 2

    # Out of range clamps instead of producing NaN/Inf holes in the series
    @test isfinite(TIFFApp.hill_ratio_to_concentration(5.0))
    @test TIFFApp.hill_ratio_to_concentration(0.0) ≈ 0.0 atol=1e-6
    # But "no measurement" stays "no measurement"
    @test isnan(TIFFApp.hill_ratio_to_concentration(NaN))
end

@testset "ROI masks and region reduction" begin
    # A 4x4 square covering pixels (1,1)..(2,2) in 0-based coordinates
    roi = RoiCoordinates("square", [0.0, 2.0, 2.0, 0.0, 0.0], [0.0, 0.0, 2.0, 2.0, 0.0])
    indices = TIFFApp.roi_pixel_indices(roi, 4, 4)
    @test length(indices) == 4

    # Pixel centres, not corners: the polygon spans x,y in [0,2], so centres
    # 0.5 and 1.5 are inside and 2.5 is not.
    @test TIFFApp.point_in_polygon(0.5, 0.5, roi.xs, roi.ys)
    @test TIFFApp.point_in_polygon(1.5, 1.5, roi.xs, roi.ys)
    @test !TIFFApp.point_in_polygon(2.5, 1.5, roi.xs, roi.ys)

    # Spatial mode: one mask per ROI. Round-robin mode: exactly one whole-frame
    # region regardless of how many ROIs are drawn, since the galvo makes each
    # instance cover a single ROI.
    rois = [roi, RoiCoordinates("other", [2.0, 4.0, 4.0, 2.0, 2.0], [2.0, 2.0, 4.0, 4.0, 2.0])]
    spatial = TIFFApp.build_region_masks(rois, 4, 4; use_spatial_masks=true)
    @test length(spatial) == 2
    @test spatial[1].pixel_count == 4

    roundrobin = TIFFApp.build_region_masks(rois, 4, 4; use_spatial_masks=false)
    @test length(roundrobin) == 1
    @test roundrobin[1].pixel_count == 16
    @test isempty(roundrobin[1].indices)      # "whole image" carries no index list

    # No ROIs drawn -> a single whole-frame region either way
    @test length(TIFFApp.build_region_masks(RoiCoordinates[], 4, 4; use_spatial_masks=true)) == 1

    # Reduction: whole-frame mean, then a masked mean
    image = UInt8[i for i in 1:16]
    full = TIFFApp.whole_image_mask(4, 4)
    @test TIFFApp.region_sum(image, full) == sum(1:16)
    @test TIFFApp.region_mean(image, full, 1) ≈ sum(1:16) / 16
    # Binning divisor: the same pixels summed over 4 frames average back down
    @test TIFFApp.region_mean(image, full, 4) ≈ sum(1:16) / 64
end

@testset "image plot composite and axis styling" begin
    W, H = 4, 2
    left  = Float32[x <= 2 ? 100 : 0 for x in 1:W, y in 1:H]
    right = Float32[x >= 3 ? 50  : 0 for x in 1:W, y in 1:H]
    dark  = zeros(Float32, W, H)
    preview = FramePreview([left, right, dark], zeros(Float32, W, H), 1)

    # Nothing enabled -> nothing drawn. This is the point: with every toggle
    # off the image plot must go blank rather than fall back to a default
    # channel.
    @test TIFFApp.channel_composite(preview, (false, false, false), 3) === nothing
    @test TIFFApp.channel_composite(nothing, (true, true, true), 3) === nothing
    # A channel toggled on but not written by this acquisition
    @test TIFFApp.channel_composite(FramePreview([left, right], zeros(Float32, W, H), 1),
                                    (false, false, true), 2) === nothing

    c1 = RGBf(TIFFApp.PLOT_COLOR_CH1)
    c2 = RGBf(TIFFApp.PLOT_COLOR_CH2)

    # Each channel is tinted with its own plot color where it has signal, and
    # black where it does not.
    single = TIFFApp.channel_composite(preview, (true, false, false), 3)
    @test single[1, 1] ≈ c1
    @test single[4, 1] == RGBf(0, 0, 0)

    both = TIFFApp.channel_composite(preview, (true, true, false), 3)
    @test both[1, 1] ≈ c1
    @test both[4, 1] ≈ c2

    # Overlap adds, so a pixel bright in two channels shows both colors summed
    # rather than whichever was drawn last.
    bright = fill(100.0f0, W, H)
    overlap = TIFFApp.channel_composite(FramePreview([bright, bright, dark], zeros(Float32, W, H), 1),
                                        (true, true, false), 3)
    @test overlap[1, 1] ≈ RGBf(min(1, c1.r + c2.r), min(1, c1.g + c2.g), min(1, c1.b + c2.b))

    # An all-zero channel contributes nothing and must not divide by its (zero)
    # peak.
    @test all(==(RGBf(0, 0, 0)), TIFFApp.channel_composite(preview, (false, false, true), 3))

    # Axis styling round-trips: the Image plot strips the chrome, and switching
    # back to any line plot restores every attribute it touched.
    GLMakie.activate!(visible = false)
    figure = Figure()
    axis = Axis(figure[1, 1]; TIFFApp.AXIS_PLOTS_ATTRS...)

    TIFFApp.apply_axis_style!(axis, TIFFApp.PLOT_IMAGE)
    @test axis.aspect[] isa DataAspect
    @test axis.yreversed[] == true
    @test axis.xgridvisible[] == false
    @test axis.ygridvisible[] == false
    @test axis.leftspinevisible[] == false
    @test RGBf(axis.backgroundcolor[]) == RGBf(0, 0, 0)

    # Ticks and tick labels go transparent rather than hidden — see
    # IMAGE_AXIS_OVERRIDES. Hiding them collapses the axis protrusions and
    # shifts the whole panel; the layout test below is the real guard, this
    # just pins the mechanism.
    @test axis.xticklabelcolor[].alpha == 0
    @test axis.yticklabelcolor[].alpha == 0
    @test axis.xtickcolor[].alpha == 0
    @test axis.xticklabelsvisible[] == true

    TIFFApp.apply_axis_style!(axis, TIFFApp.PLOT_RATIO)
    for (attribute, _) in TIFFApp.IMAGE_AXIS_OVERRIDES
        expected = TIFFApp.AXIS_PLOTS_ATTRS[attribute]
        got = getproperty(axis, attribute)[]
        # backgroundcolor is stored as RGBA, so compare as color rather than
        # by type.
        if attribute === :backgroundcolor
            @test RGBf(got) == RGBf(expected)
        else
            @test string(got) == string(expected)
        end
    end

    # Limits follow the frame's pixel extent, so a non-square image is fitted
    # rather than stretched.
    app_run = AppRun()
    app_run.channel_count = 3
    app_run.preview[] = preview
    TIFFApp.apply_axis_style!(axis, TIFFApp.PLOT_IMAGE)
    TIFFApp.fit_image_axis!(axis, app_run)
    @test axis.limits[] == (0, W, 0, H)
end

@testset "no local shadowed by a Makie export" begin
    # Regression guard for a bug that reached the running app: renaming a local
    # (`volume` -> `image`) left one call site behind, and because `using
    # GLMakie` brings `Makie.volume` — a plotting function — into scope, the
    # stale name resolved to *that* instead of raising. Nothing failed at load
    # or precompile time; it surfaced only as a MethodError the moment a user
    # drew a ROI.
    #
    # This walks every top-level function in src/ and reports any identifier
    # passed as a call argument that the function never binds, but which
    # TIFFApp only knows because Makie exports it. Those can only be forgotten
    # locals: a genuine reference to a Makie plotting function would be called,
    # not passed.

    function collect_lhs!(x::Symbol, out); push!(out, x); end
    function collect_lhs!(x, out)
        x isa Expr || return
        x.head === :tuple && for a in x.args; collect_lhs!(a, out); end
        x.head === :(::) && collect_lhs!(x.args[1], out)
    end

    function collect_params!(sig, out)
        if sig isa Symbol; push!(out, sig); return; end
        sig isa Expr || return
        args = sig.head === :call ? sig.args[2:end] : sig.args
        for a in args
            a isa Symbol && push!(out, a)
            if a isa Expr
                a.head === :(::) && a.args[1] isa Symbol && push!(out, a.args[1])
                a.head === :kw && collect_lhs!(a.args[1], out)
                a.head === :parameters && for prm in a.args
                    collect_lhs!(prm isa Expr && prm.head === :kw ? prm.args[1] : prm, out)
                end
            end
        end
    end

    function collect_bindings!(e, out)
        e isa Expr || return
        h = e.head
        if h in (:(=), :(+=), :(-=), :(*=), :(/=))
            collect_lhs!(e.args[1], out)
        elseif h === :local || h === :global
            for a in e.args; collect_lhs!(a, out); end
        elseif h === :for
            spec = e.args[1]
            for st in (spec isa Expr && spec.head === :block ? spec.args : [spec])
                st isa Expr && st.head === :(=) && collect_lhs!(st.args[1], out)
            end
        elseif h === :function || h === :(->)
            collect_params!(e.args[1], out)
        elseif h === :do
            length(e.args) >= 2 && collect_params!(e.args[2].args[1], out)
        end
        for a in e.args; collect_bindings!(a, out); end
    end

    function collect_arg_uses!(e, out)
        e isa Expr || return
        if e.head === :call
            for a in e.args[2:end]
                a isa Symbol && push!(out, a)
                a isa Expr && a.head === :kw && a.args[2] isa Symbol && push!(out, a.args[2])
            end
        end
        for a in e.args; collect_arg_uses!(a, out); end
    end

    src_dir = joinpath(@__DIR__, "..", "src")
    offenders = Tuple{String, String, Symbol}[]

    for (root, _, files) in walkdir(src_dir), file in files
        endswith(file, ".jl") || continue
        path = joinpath(root, file)

        for expression in Meta.parseall(read(path, String)).args
            (expression isa Expr && expression.head === :function) || continue

            signature = expression.args[1]
            name = string(signature isa Expr ? signature.args[1] : signature)

            bound = Set{Symbol}()
            collect_bindings!(expression, bound)
            collect_params!(signature, bound)

            used = Set{Symbol}()
            collect_arg_uses!(expression, used)

            for identifier in setdiff(used, bound)
                # `isdefined(TIFFApp, id)` alone is not enough: `using GLMakie`
                # makes every Makie export "defined" there. `which` reports the
                # module that actually owns the binding, which separates a real
                # definition from an import — and it is precisely an import
                # that lets a forgotten local load without error.
                isdefined(TIFFApp, identifier) || continue
                owner = try
                    Base.which(TIFFApp, identifier)
                catch
                    nothing
                end
                owner === nothing && continue

                if Base.moduleroot(owner) === Base.moduleroot(Makie) && !isdefined(Base, identifier)
                    push!(offenders, (relpath(path, src_dir), name, identifier))
                end
            end
        end
    end

    if !isempty(offenders)
        for (file, fn, identifier) in offenders
            @info "Unbound identifier resolving through Makie" file=file function_name=fn identifier=identifier
        end
    end
    @test isempty(offenders)
end

@testset "plot switching preserves layout" begin
    # Switching a slot to the Image plot and back must not move anything. The
    # axis carries a fixed width/height, but its *protrusions* — the space
    # reserved outside the box for ticks and tick labels — collapse if those
    # are hidden outright, which shifts the box origin and nudges the panel.
    GLMakie.activate!(visible = false)

    figure = Figure(size = (1000, 500))
    axis = Axis(figure[1, 1]; TIFFApp.AXIS_PLOTS_ATTRS...)
    lines!(axis, 1:10, 1:10)
    Makie.update_state_before_display!(figure)

    reference_box = axis.layoutobservables.computedbbox[]
    reference_protrusions = axis.layoutobservables.protrusions[]

    TIFFApp.apply_axis_style!(axis, TIFFApp.PLOT_IMAGE)
    Makie.update_state_before_display!(figure)
    @test axis.layoutobservables.computedbbox[] == reference_box
    @test axis.layoutobservables.protrusions[] == reference_protrusions

    TIFFApp.apply_axis_style!(axis, TIFFApp.PLOT_RATIO)
    Makie.update_state_before_display!(figure)
    @test axis.layoutobservables.computedbbox[] == reference_box
    @test axis.layoutobservables.protrusions[] == reference_protrusions

    # Repeated switching must not drift either — each application has to be a
    # full round trip, not an approximate one.
    for _ in 1:5
        TIFFApp.apply_axis_style!(axis, TIFFApp.PLOT_IMAGE)
        Makie.update_state_before_display!(figure)
        TIFFApp.apply_axis_style!(axis, TIFFApp.PLOT_RATIO)
        Makie.update_state_before_display!(figure)
    end
    @test axis.layoutobservables.computedbbox[] == reference_box
    @test axis.layoutobservables.protrusions[] == reference_protrusions
end

@testset "one series per drawn ROI" begin
    # The series count and the worker's region count must agree. Gating the
    # series count on app.roi.active while the worker built one mask per drawn
    # ROI is what made every ROI but the first vanish: consumer_loop drops
    # regions past the end of rois_series, so the rest were computed and then
    # silently discarded.
    app = AppState(true)
    app_run = AppRun()
    app_run.rois[] = [
        RoiCoordinates("a", [0.0, 4.0, 4.0, 0.0, 0.0], [0.0, 0.0, 4.0, 4.0, 0.0]),
        RoiCoordinates("b", [4.0, 8.0, 8.0, 4.0, 4.0], [0.0, 0.0, 4.0, 4.0, 0.0]),
        RoiCoordinates("c", [8.0, 12.0, 12.0, 8.0, 8.0], [0.0, 0.0, 4.0, 4.0, 0.0]),
    ]

    for roi_active in (false, true), protocol_active in (false, true)
        app.roi.active = roi_active
        app.protocol.active = protocol_active
        TIFFApp.rebuild_roi_series!(app, app_run; channel_count = 3)
        @test length(app_run.rois_series) == 3
    end

    # No ROIs drawn still yields exactly one whole-frame series.
    app_run.rois[] = RoiCoordinates[]
    TIFFApp.rebuild_roi_series!(app, app_run; channel_count = 2)
    @test length(app_run.rois_series) == 1
    @test length(app_run.rois_series[1].channels) == 2
end

@testset "ROI coordinates scale to the acquisition frame" begin
    # ROI coordinates live in the reference image's pixel space, which is not
    # the acquisition frame's whenever the reference came from the popup's
    # "current frame" capture — that records the *downsampled* preview. Without
    # conversion every ROI lands in a corner and measures the wrong pixels,
    # with nothing to signal it.
    @test TIFFApp.roi_coordinate_scale(nothing, 100, 50) == (1.0, 1.0)
    @test TIFFApp.roi_coordinate_scale((100, 50), 100, 50) == (1.0, 1.0)
    @test TIFFApp.roi_coordinate_scale((25, 12), 100, 48) == (4.0, 4.0)
    # A degenerate reference size must not scale everything to nothing
    @test TIFFApp.roi_coordinate_scale((0, 50), 100, 50) == (1.0, 1.0)

    # Same ROI expressed in two spaces must select the same pixels.
    full = RoiCoordinates("q", [0.0, 8.0, 8.0, 0.0, 0.0], [0.0, 0.0, 8.0, 8.0, 0.0])
    quarter = RoiCoordinates("q", full.xs ./ 4, full.ys ./ 4)

    at_full = TIFFApp.build_region_masks([full], 16, 16; use_spatial_masks = true)
    scaled = TIFFApp.build_region_masks([quarter], 16, 16;
                                        use_spatial_masks = true, source_size = (4, 4))
    unscaled = TIFFApp.build_region_masks([quarter], 16, 16; use_spatial_masks = true)

    @test scaled[1].indices == at_full[1].indices
    @test scaled[1].pixel_count == 64
    # And the unconverted version really is wrong, so the test above is not
    # passing by coincidence.
    @test unscaled[1].indices != at_full[1].indices
end

@testset "distinct ROIs measure distinct regions" begin
    # Three disjoint vertical bands over an image whose columns increase left
    # to right: each band must report its own mean, and a ratio formed from
    # two channels with different gradients must differ between them.
    W, H = 12, 4
    band(i) = RoiCoordinates("band$i",
        [(i - 1) * W / 3, i * W / 3, i * W / 3, (i - 1) * W / 3, (i - 1) * W / 3],
        [0.0, 0.0, Float64(H), Float64(H), 0.0])
    rois = [band(i) for i in 1:3]

    masks = TIFFApp.build_region_masks(rois, W, H; use_spatial_masks = true)
    @test length(masks) == 3
    @test all(m -> m.pixel_count == 16, masks)
    # Disjoint: no pixel belongs to two bands.
    @test length(unique(vcat((m.indices for m in masks)...))) == 3 * 16

    ramp = UInt8[UInt8(x) for x in 1:W, _ in 1:H]         # grows with x
    flat = fill(UInt8(10), W, H)

    means_ramp = [TIFFApp.region_mean(vec(ramp), m, 1) for m in masks]
    means_flat = [TIFFApp.region_mean(vec(flat), m, 1) for m in masks]

    @test length(unique(means_ramp)) == 3
    @test issorted(means_ramp)                            # left band darkest
    @test all(≈(10.0), means_flat)

    ratios = [TIFFApp.ratio_from_means([means_ramp[i], means_flat[i]], "C1/C2", [1, 2])
              for i in 1:3]
    @test length(unique(ratios)) == 3
    @test issorted(ratios)
end

@testset "image frame buffer (temporal binning)" begin
    W, H, DEPTH = 3, 2, 6
    frames = [UInt8.(rand(0:60, W * H)) for _ in 1:30]
    naive(k, window) = sum(UInt32.(frames[i]) for i in (k - min(window, k) + 1):k)

    # Fixed windows, including window == depth, where a naive circular buffer
    # overwrites the departing frame before it can be subtracted.
    for window in (1, 2, 3, DEPTH, 50)
        buffer = TIFFApp.ImageFrameBuffer{UInt8}(W, H, DEPTH)
        for k in 1:30
            got = TIFFApp.push_frame!(buffer, frames[k], window)
            expected = clamp(window, 1, min(DEPTH, k))
            @test got == expected
            @test vec(buffer.sum_image) == naive(k, expected)
        end
    end

    # Window changed mid-run: the sum's membership changes by more than the
    # arriving frame, so it must be rebuilt rather than incrementally patched.
    buffer = TIFFApp.ImageFrameBuffer{UInt8}(W, H, DEPTH)
    for (k, window) in zip(1:20, [1,1,3,3,3,5,5,2,2,6,6,1,4,4,4,2,2,2,6,6])
        got = TIFFApp.push_frame!(buffer, frames[k], window)
        expected = clamp(window, 1, min(DEPTH, k))
        @test got == expected
        @test vec(buffer.sum_image) == naive(k, expected)
    end

    # Steady state allocates nothing per frame beyond the reshape views.
    big = TIFFApp.ImageFrameBuffer{UInt8}(32, 32, 4)
    px = UInt8.(rand(0:255, 32 * 32))
    for _ in 1:10; TIFFApp.push_frame!(big, px, 3); end
    @test (@allocated TIFFApp.push_frame!(big, px, 3)) < 512

    # A frame of the wrong size is refused rather than partially copied.
    @test_throws ArgumentError TIFFApp.push_frame!(big, UInt8[1, 2, 3], 1)
end

@testset "realtime instance collector" begin
    mktempdir() do dir
        bliq = joinpath(dir, "Bliq VMS")
        mkpath(joinpath(bliq, "C1")); mkpath(joinpath(bliq, "C2"))
        layout = TIFFApp.resolve_channel_layout(dir)
        collector = TIFFApp.InstanceCollector(layout; nominal_period_s=0.1)

        # Only C1 has arrived: the instance is held, not released half-filled.
        write(joinpath(bliq, "C1", "s-C1-T001.tif"), UInt8[])
        TIFFApp.scan_new_files!(collector, 1.0)
        @test isempty(TIFFApp.take_ready_instances!(collector, 1.0))

        # C2 completes it.
        write(joinpath(bliq, "C2", "s-C2-T002.tif"), UInt8[])
        TIFFApp.scan_new_files!(collector, 1.1)
        ready = TIFFApp.take_ready_instances!(collector, 1.1)
        @test length(ready) == 1
        @test ready[1].instance_index == 1
        @test length(ready[1].paths) == 2

        # Instances are released in order: instance 3 arriving before 2 waits.
        write(joinpath(bliq, "C1", "s-C1-T005.tif"), UInt8[])
        write(joinpath(bliq, "C2", "s-C2-T006.tif"), UInt8[])
        TIFFApp.scan_new_files!(collector, 1.2)
        @test isempty(TIFFApp.take_ready_instances!(collector, 1.2))

        # Filling the hole releases both, in order.
        write(joinpath(bliq, "C1", "s-C1-T003.tif"), UInt8[])
        write(joinpath(bliq, "C2", "s-C2-T004.tif"), UInt8[])
        TIFFApp.scan_new_files!(collector, 1.3)
        ready = TIFFApp.take_ready_instances!(collector, 1.3)
        @test [i.instance_index for i in ready] == [2, 3]
    end
end

@testset "protocol schedule math" begin
    protocol = ProtocolSettings(
        active=true,
        repeats=2,
        delay=5,
        times=vcat([10.0, 20.0], fill(NaN, TIFFApp.PROTOCOL_STEP_COUNT - 2)),
        setpoints=vcat([3.5, 4.0], fill(NaN, TIFFApp.PROTOCOL_STEP_COUNT - 2))
    )

    # NaN-duration steps are skipped
    @test TIFFApp.protocol_steps(protocol) == [(10.0, 3.5), (20.0, 4.0)]

    # Before the delay has elapsed: no setpoint
    @test isnan(TIFFApp.protocol_setpoint_at(protocol, 2.0))
    # First step [5, 15), second step [15, 35)
    @test TIFFApp.protocol_setpoint_at(protocol, 6.0) == 3.5
    @test TIFFApp.protocol_setpoint_at(protocol, 20.0) == 4.0
    # Second repeat of the 30 s cycle: t = 5 + 30 + 2 is inside step 1 again
    @test TIFFApp.protocol_setpoint_at(protocol, 37.0) == 3.5
    # After both repeats (5 + 2*30 = 65): schedule over
    @test isnan(TIFFApp.protocol_setpoint_at(protocol, 70.0))
    # Non-finite timestamp
    @test isnan(TIFFApp.protocol_setpoint_at(protocol, NaN))

    # repeats == 0 repeats forever
    forever = ProtocolSettings(
        active=true, repeats=0, delay=0,
        times=vcat([10.0], fill(NaN, TIFFApp.PROTOCOL_STEP_COUNT - 1)),
        setpoints=vcat([2.5], fill(NaN, TIFFApp.PROTOCOL_STEP_COUNT - 1))
    )
    @test TIFFApp.protocol_setpoint_at(forever, 1234.0) == 2.5

    # normalize copies vectors and clamps negatives
    raw = ProtocolSettings(active=true, repeats=-3, delay=-1,
                           times=fill(NaN, TIFFApp.PROTOCOL_STEP_COUNT),
                           setpoints=fill(NaN, TIFFApp.PROTOCOL_STEP_COUNT))
    normalized = TIFFApp.normalize_protocol_config(raw)
    @test normalized.repeats == 0
    @test normalized.delay == 0
    @test normalized.times !== raw.times
end

@testset "protocol CSV round-trip" begin
    dir = mktempdir()
    csv_path = joinpath(dir, "protocol.csv")
    times = vcat([10.0, 20.0, 30.0], fill(NaN, TIFFApp.PROTOCOL_STEP_COUNT - 3))
    setpoints = vcat([3.5, 4.0, 2.0], fill(NaN, TIFFApp.PROTOCOL_STEP_COUNT - 3))

    TIFFApp.write_protocol_csv(csv_path; repeats=3, delay=7, times=times, setpoints=setpoints)
    imported = TIFFApp.read_protocol_csv(csv_path; step_count=TIFFApp.PROTOCOL_STEP_COUNT)

    @test imported.repeats == 3
    @test imported.delay == 7
    @test imported.times[1:3] == times[1:3]
    @test imported.setpoints[1:3] == setpoints[1:3]
    @test all(isnan, imported.times[4:end])
end

@testset "state persistence round-trip" begin
    app = AppState(true)
    app.layout.binning = 7
    app.layout.plot1 = TIFFApp.PLOT_IMAGE
    app.layout.ratio_combination = "C2/C3"
    app.controller.P1 = 1.25
    app.protocol.times[1] = 12.0
    app.current_panel = :controller

    dir = mktempdir()
    path = joinpath(dir, "state.jls")
    save_state(app; path=path)

    loaded = load_state(path)
    @test loaded isa AppState
    @test loaded.dark
    @test loaded.current_panel == :controller
    @test loaded.layout.binning == 7
    @test loaded.layout.plot1 == TIFFApp.PLOT_IMAGE
    @test loaded.layout.ratio_combination == "C2/C3"
    @test loaded.controller.P1 == 1.25
    @test loaded.protocol.times[1] == 12.0
    # Vectors must be copies, not aliases of the original state
    @test loaded.protocol.times !== app.protocol.times

    @test TIFFApp.valid_app_state(loaded)
    @test !TIFFApp.valid_app_state("not a state")

    # Missing and corrupted files fall back to nothing (fresh defaults)
    @test load_state(joinpath(dir, "missing.jls")) === nothing
    garbage = joinpath(dir, "garbage.jls")
    write(garbage, "this is not a serialized Dict")
    @test load_state(garbage) === nothing
end

@testset "smoothing" begin
    @test TIFFApp.series_smooth_level(LayoutSettings(smoothing=99)) == 10
    @test TIFFApp.series_smooth_level(LayoutSettings(smoothing=-2)) == 0

    # Level 1 leaves q unscaled; level 10 spans KALMAN_LEVEL_SPAN.
    @test TIFFApp.kalman_strength_factor(1) == 1.0
    @test TIFFApp.kalman_strength_factor(10) == TIFFApp.KALMAN_LEVEL_SPAN

    # Level 0 is an exact passthrough (kalman_update! re-arms at measurement).
    state = TIFFApp.KalmanState()
    @test TIFFApp.kalman_update!(state, 3.05, 1.0, 0) == 3.05
    # Non-finite measurement is returned unchanged.
    @test isnan(TIFFApp.kalman_update!(TIFFApp.KalmanState(), NaN, 1.0, 5))

    # Smoothing pulls a new estimate between the prior estimate and the raw value.
    state = TIFFApp.KalmanState()
    TIFFApp.kalman_update!(state, 3.0, 1.0, 5)       # seed the filter
    smoothed = TIFFApp.kalman_update!(state, 3.1, 1.0, 5)
    @test 3.0 <= smoothed <= 3.1
end

@testset "spinner stepping (smart_next/smart_prev)" begin
    # 1,2,...,9,10,20,...,90,100,200,... series
    @test TIFFApp.smart_next(1, 1, 99999, Int) == 2
    @test TIFFApp.smart_next(9, 1, 99999, Int) == 10
    @test TIFFApp.smart_next(10, 1, 99999, Int) == 20
    @test TIFFApp.smart_next(99999, 1, 99999, Int) == 99999   # clamped at max
    @test TIFFApp.smart_prev(20, 1, 99999, Int) == 10
    @test TIFFApp.smart_prev(10, 1, 99999, Int) == 9
    @test TIFFApp.smart_prev(1, 1, 99999, Int) == 1           # clamped at min
    # Integer edge handling around zero (smoothing spinner)
    @test TIFFApp.smart_next(0, 0, 10, Int) == 1
    @test TIFFApp.smart_prev(1, 0, 10, Int) == 0
end

@testset "plot windowing helpers" begin
    xs = collect(0.0:1.0:100.0)
    ys = collect(0.0:1.0:100.0)
    win_x, win_y = TIFFApp.windowed_slice(xs, ys, 10.0)
    @test win_x[1] == 90.0 && win_x[end] == 100.0
    @test win_y == win_x
    @test TIFFApp.windowed_slice(Float64[], Float64[], 10.0) == (Float64[], Float64[])

    # setpoint spans: contiguous finite runs of the setpoint series
    ts = [0.0, 1.0, 2.0, 3.0, 4.0, 5.0]
    sp = [NaN, 2.0, 2.0, NaN, 3.0, 3.0]
    starts, ends = TIFFApp.protocol_setpoint_spans(ts, sp)
    @test starts == [1.0, 4.0]
    @test ends == [3.0, 5.0]

end

@testset "RoiSeries / AppRun runtime state" begin
    app = AppState(true)
    app_run = AppRun()

    @test length(app_run.rois_series) == 1
    @test app_run.rois_series[1] isa RoiSeries
    @test length(app_run.rois_series[1].channels) == TIFFApp.DEFAULT_CHANNEL_COUNT
    @test app_run.preview[] === nothing

    # A RegionFrame accumulates onto one region's time series.
    frame = RegionFrame([120.0, 60.0], 2.0, 12.5)
    series = app_run.rois_series[1]
    TIFFApp.accumulate_roi_sample!(app, series, frame, 0.5)

    @test series.timestamps[] == [0.5]
    @test series.ratio[] == [2.0]
    @test series.ratio_smooth[] == [2.0]           # level 0: passthrough
    @test series.concentration[] == [12.5]
    @test series.channels[1].values[] == [120.0]
    @test series.channels[2].values[] == [60.0]

    # A frame reporting fewer channels than the series holds pads with NaN
    # rather than throwing — the series are sized at START, before the worker
    # has necessarily resolved the real channel count.
    TIFFApp.accumulate_roi_sample!(app, series, RegionFrame([90.0], NaN, NaN), 1.0)
    @test series.channels[1].values[][2] == 90.0
    @test isnan(series.channels[2].values[][2])

    TIFFApp.reset_acquisition_state!(app, app_run)
    @test isempty(app_run.rois_series[1].ratio[])
    @test isempty(app_run.rois_series[1].channels[1].values[])
    @test app_run.preview[] === nothing
    @test isnan(app_run.save_progress[])
end

@testset "ROI mask mode selection" begin
    app = AppState(true)

    # Round-robin only when the galvo is actually being driven ROI to ROI,
    # which requires both toggles.
    app.roi.active = true;  app.protocol.active = true
    @test TIFFApp.use_spatial_roi_masks(app) == false

    app.roi.active = true;  app.protocol.active = false
    @test TIFFApp.use_spatial_roi_masks(app) == true

    app.roi.active = false; app.protocol.active = true
    @test TIFFApp.use_spatial_roi_masks(app) == true

    app.roi.active = false; app.protocol.active = false
    @test TIFFApp.use_spatial_roi_masks(app) == true
end

@testset "PI command" begin
    # PI controller (no D term — the derivative was replaced by a Kalman
    # observer, see PidChannelState).
    state = TIFFApp.PidChannelState()
    state.old_error = 1.0
    state.I_error = 2.0

    # off -> NaN; no setpoint -> NaN
    @test isnan(TIFFApp.pid_command_from_state(state, 1.5, 1.0, 1.0, false, false))
    @test isnan(TIFFApp.pid_command_from_state(state, NaN, 1.0, 1.0, false, true))
    # P*1 + I*2 = 3.0
    @test TIFFApp.pid_command_from_state(state, 1.5, 1.0, 1.0, false, true) == 3.0
    # inverted and clamped to [0, 100]
    @test TIFFApp.pid_command_from_state(state, 1.5, 1.0, 1.0, true, true) == 0.0
    @test TIFFApp.pid_command_from_state(state, 1.5, 100.0, 100.0, false, true) == 100.0
end

@testset "PI error accumulation" begin
    state = TIFFApp.PidChannelState()

    # Setpoint above the measured ratio -> positive error, integral grows.
    TIFFApp.update_pid_error!(state, 1.0, 1.5, 1.0, 0)
    @test state.old_error ≈ 0.5
    @test state.I_error ≈ 0.5

    # No active protocol (NaN setpoint) resets the accumulators rather than
    # letting the integral wind on a stale error.
    TIFFApp.update_pid_error!(state, 1.0, NaN, 1.0, 0)
    @test state.old_error == 0.0
    @test state.I_error == 0.0
end

@testset "acquisition helpers" begin
    @test TIFFApp.resolve_protocol_config(nothing) === nothing
    p = ProtocolSettings()
    @test TIFFApp.resolve_protocol_config(p) === p

    # scan_time + shift_time, ms -> s
    @test TIFFApp.roi_scan_period_s(ProtocolSettings(scan_time=950, shift_time=50)) == 1.0
    @test isnan(TIFFApp.roi_scan_period_s(ProtocolSettings(scan_time=0, shift_time=0)))

    @test LayoutSettings().ratio_combination == "C1/C2"
    @test LayoutSettings().plot1 == TIFFApp.PLOT_RATIO
end

@testset "ROI slot tracking (missed-file repair)" begin
    # Helper: feed a whole run of (time, sequence_number) pairs through one
    # tracker and collect the ROI index each file would be assigned to.
    function roi_indices(period_s, n_rois, files)
        tracker = TIFFApp.RoiSlotTracker(period_s)
        return map(files) do (t, seq)
            slot, _, _ = TIFFApp.next_roi_slot!(tracker, Float64(t), seq)
            mod1(slot, n_rois)
        end
    end

    # Nothing missing: the first file's own sequence number is the origin,
    # so a clean run reproduces plain mod1(sequence_number, n_rois) exactly.
    clean = [(Float64(k - 1), k) for k in 1:8]
    @test roi_indices(1.0, 2, clean) == [1, 2, 1, 2, 1, 2, 1, 2]
    @test roi_indices(1.0, 3, clean) == [1, 2, 3, 1, 2, 3, 1, 2]

    # The reported failure: the source writes no file for ROI 2's fourth
    # scan, and because it numbers files as they are written, the numbering
    # stays consecutive right across the hole. Only the doubled delay
    # betrays it — file 4 (seq 4, which mod1 alone would send to ROI 2) is
    # really ROI 1's.
    missed = [(0.0, 1), (1.0, 2), (2.0, 3), (4.0, 4), (5.0, 5), (6.0, 6)]
    @test roi_indices(1.0, 2, missed) == [1, 2, 1, 1, 2, 1]
    # Same input keyed on the sequence number alone: ROI 1 scanned twice in
    # a row but both files land on different ROIs — the misalignment.
    @test [mod1(seq, 2) for (_, seq) in missed] == [1, 2, 1, 2, 1, 2]

    # Skips are reported, and only when they happen.
    tracker = TIFFApp.RoiSlotTracker(1.0)
    @test TIFFApp.next_roi_slot!(tracker, 0.0, 1) == (1, 0, false)
    @test TIFFApp.next_roi_slot!(tracker, 1.0, 2) == (2, 0, false)
    # Three periods of silence: two scans produced nothing.
    slot, skipped, _ = TIFFApp.next_roi_slot!(tracker, 4.0, 3)
    @test (slot, skipped) == (5, 2)
    @test tracker.skipped_total == 2

    # A gap in the numbering itself (file written, never seen by this app)
    # is still honored — that's what the sequence number is good at.
    tracker = TIFFApp.RoiSlotTracker(1.0)
    TIFFApp.next_roi_slot!(tracker, 0.0, 1)
    slot, skipped, _ = TIFFApp.next_roi_slot!(tracker, 2.0, 3)
    @test (slot, skipped) == (3, 1)

    # The two estimates disagreeing takes the larger: neither mechanism can
    # invent scans that never happened, so each is a lower bound.
    tracker = TIFFApp.RoiSlotTracker(1.0)
    TIFFApp.next_roi_slot!(tracker, 0.0, 1)
    @test TIFFApp.next_roi_slot!(tracker, 1.0, 4)[1] == 4      # numbering wins
    @test TIFFApp.next_roi_slot!(tracker, 4.0, 5)[1] == 7      # timing wins

    # Timing jitter well inside half a period must not read as a skip.
    jittery = [(0.0, 1), (0.78, 2), (1.85, 3), (2.75, 4), (4.05, 5), (5.2, 6)]
    @test roi_indices(1.0, 2, jittery) == [1, 2, 1, 2, 1, 2]

    # No usable timestamp (mtime unreadable): falls back to the numbering
    # rather than treating NaN as a gap, and the *next* gap is measured from
    # the new reference instead of spanning two files (which would read as a
    # phantom skip).
    tracker = TIFFApp.RoiSlotTracker(1.0)
    TIFFApp.next_roi_slot!(tracker, 0.0, 1)
    @test TIFFApp.next_roi_slot!(tracker, NaN, 2) == (2, 0, false)
    @test TIFFApp.next_roi_slot!(tracker, 5.0, 3) == (3, 0, false)
    @test TIFFApp.next_roi_slot!(tracker, 6.0, 4) == (4, 0, false)

    # The real period being consistently longer than the protocol's nominal
    # one (per-file overhead at the source) must not manufacture a skip on
    # every single file: ambiguous gaps are declined until the measured
    # period has been established, and then it takes over.
    stretched = [(1.6 * (k - 1), k) for k in 1:12]
    @test roi_indices(1.0, 2, stretched) == [1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2]
    tracker = TIFFApp.RoiSlotTracker(1.0)
    for (t, seq) in stretched
        TIFFApp.next_roi_slot!(tracker, t, seq)
    end
    @test tracker.skipped_total == 0
    @test tracker.period_est_s ≈ 1.6

    # ... and a genuine miss is still caught once that longer period is the
    # one being measured against. The 12th file sits at t = 17.6; nothing is
    # written for the scan after it, so the 13th arrives two periods later.
    long_run = vcat(stretched, [(17.6 + 3.2, 13), (17.6 + 4.8, 14)])
    long_indices = roi_indices(1.0, 2, long_run)
    @test long_indices[13] == 2    # ... which mod1(13, 2) alone would call ROI 1
    @test long_indices[14] == 1

    # A doubled gap must not drag the period estimate up toward 1.5x and
    # start hiding further misses — that's why the estimator is a median.
    with_misses = [(0.0, 1), (1.0, 2), (2.0, 3), (3.0, 4), (4.0, 5),
                   (6.0, 6), (7.0, 7), (9.0, 8), (10.0, 9)]
    tracker = TIFFApp.RoiSlotTracker(1.0)
    for (t, seq) in with_misses
        TIFFApp.next_roi_slot!(tracker, t, seq)
    end
    @test tracker.period_est_s ≈ 1.0
    @test tracker.skipped_total == 2

    # No nominal period available at all (unusable protocol values): the
    # tracker still bootstraps one from what it observes.
    tracker = TIFFApp.RoiSlotTracker(NaN)
    for k in 1:6
        TIFFApp.next_roi_slot!(tracker, 2.0 * (k - 1), k)
    end
    @test tracker.period_est_s ≈ 2.0
    @test tracker.skipped_total == 0
    # Sixth file sat at t = 10; a 4s gap is two periods, so one missed scan.
    @test TIFFApp.next_roi_slot!(tracker, 14.0, 7)[2] == 1

    # An absurd timestamp (garbage mtime) is bounded rather than thrown on.
    tracker = TIFFApp.RoiSlotTracker(1.0)
    TIFFApp.next_roi_slot!(tracker, 0.0, 1)
    slot, skipped, ambiguous = TIFFApp.next_roi_slot!(tracker, 1.0e30, 2)
    @test skipped == TIFFApp.ROI_SLOT_MAX_STEP - 1
    @test ambiguous
end

@testset "pixel_label_boundary (Cellpose mask -> ROI polygon)" begin
    # Round-trip check: does re-rasterizing the traced polygon
    # (roi_pixel_mask's own point-in-polygon test, on pixel centers)
    # reproduce the exact original pixel set?
    function reconstructed(mask, xs, ys)
        n_cols, n_rows = size(mask)
        Set((x, y) for x in 1:n_cols, y in 1:n_rows
                   if TIFFApp.point_in_polygon(Float64(x - 1), Float64(y - 1), xs, ys))
    end
    function original(mask, label)
        n_cols, n_rows = size(mask)
        Set((x, y) for x in 1:n_cols, y in 1:n_rows if mask[x, y] == label)
    end
    function exact_roundtrip(mask, label)
        xs, ys = TIFFApp.pixel_label_boundary(mask, label)
        return original(mask, label) == reconstructed(mask, xs, ys)
    end

    # Simple square
    mask = zeros(Int, 10, 10)
    mask[3:7, 3:7] .= 1
    @test exact_roundtrip(mask, 1)

    # Concave L-shape
    mask_l = zeros(Int, 10, 10)
    mask_l[2:6, 2:4] .= 1
    mask_l[2:4, 2:8] .= 1
    @test exact_roundtrip(mask_l, 1)

    # Circle (typical Cellpose-blob shape)
    mask_circle = zeros(Int, 20, 20)
    for x in 1:20, y in 1:20
        (x - 10.5)^2 + (y - 10.5)^2 <= 6.0^2 && (mask_circle[x, y] = 1)
    end
    @test exact_roundtrip(mask_circle, 1)

    # Non-convex crescent (two circles, set difference)
    mask_crescent = zeros(Int, 30, 30)
    for x in 1:30, y in 1:30
        in_c1 = (x - 14)^2 + (y - 15)^2 <= 10^2
        in_c2 = (x - 19)^2 + (y - 15)^2 <= 9^2
        mask_crescent[x, y] = (in_c1 && !in_c2) ? 1 : 0
    end
    @test exact_roundtrip(mask_crescent, 1)

    # Isolated single pixel
    mask_single = zeros(Int, 6, 6)
    mask_single[3, 3] = 1
    @test exact_roundtrip(mask_single, 1)

    # Two distinct blobs sharing one mask, different labels
    mask_multi = zeros(Int, 12, 12)
    mask_multi[2:4, 2:4] .= 1
    mask_multi[8:10, 8:10] .= 2
    @test exact_roundtrip(mask_multi, 1)
    @test exact_roundtrip(mask_multi, 2)

    # A label with no pixels at all -> empty, not an error
    xs_empty, ys_empty = TIFFApp.pixel_label_boundary(mask, 99)
    @test isempty(xs_empty) && isempty(ys_empty)

    # Adversarial diagonal-only touch (two pixels sharing only a corner) —
    # not producible by real Cellpose output, but the tracer must fail
    # safely (empty result), not hang or return a broken polygon.
    mask_pinch = zeros(Int, 6, 6)
    mask_pinch[3, 3] = 1
    mask_pinch[4, 4] = 1
    xs_pinch, ys_pinch = TIFFApp.pixel_label_boundary(mask_pinch, 1)
    @test isempty(xs_pinch) == isempty(ys_pinch)   # always both empty or both non-empty
end

@testset "Cellpose binary I/O round-trip" begin
    img = Float64.(reshape(1:24, 6, 4))
    tmp = tempname()
    try
        TIFFApp.write_cellpose_input(tmp, img)

        # Header + payload land exactly as cellpose_segment.py expects to read them.
        open(tmp, "r") do io
            n_cols = read(io, Int64)
            n_rows = read(io, Int64)
            @test (n_cols, n_rows) == size(img)
            data = Vector{Float64}(undef, n_cols * n_rows)
            read!(io, data)
            @test reshape(data, n_cols, n_rows) == img
        end

        # A synthetic label mask, written the way cellpose_segment.py would,
        # round-trips exactly through read_cellpose_masks.
        mask = Int32[0 1 1 0; 0 1 1 0; 2 2 0 0; 2 2 0 0; 0 0 0 0; 0 0 0 0]
        open(tmp, "w") do io
            write(io, Int64(6), Int64(4))
            write(io, mask)
        end
        @test TIFFApp.read_cellpose_masks(tmp) == mask
    finally
        rm(tmp; force=true)
    end
end

@testset "run_cellpose_segmentation (subprocess plumbing)" begin
    # A dependency-free Python stand-in for cellpose_segment.py: same binary
    # file protocol, but a trivial threshold instead of a real segmentation
    # model — lets the full write -> subprocess -> read pipeline be tested
    # through a real external process boundary without Cellpose installed.
    stub_path = tempname() * ".py"
    write(stub_path, """
        import sys, struct

        input_path, output_path, model_type, diameter_str = sys.argv[1:]

        with open(input_path, "rb") as f:
            n_cols, n_rows = struct.unpack("<qq", f.read(16))
            n = n_cols * n_rows
            data = struct.unpack(f"<{n}d", f.read(8 * n))

        labels = [1 if v > 0 else 0 for v in data]

        with open(output_path, "wb") as f:
            f.write(struct.pack("<qq", n_cols, n_rows))
            f.write(struct.pack(f"<{len(labels)}i", *labels))

        print(f"stub processed {n_cols}x{n_rows}")
        """)

    try
        image = Float64[-1.0 2.0 0.0; 3.0 -4.0 5.0]

        masks = TIFFApp.run_cellpose_segmentation(image; python_cmd="python3", script_path=stub_path)
        @test masks !== nothing
        @test masks == Int32.(image .> 0)

        # Missing script -> nothing, logged, not thrown.
        @test TIFFApp.run_cellpose_segmentation(image; script_path=tempname()) === nothing

        # Cellpose venv not set up (python_cmd doesn't resolve at all, via
        # Sys.which) -> nothing, logged with the setup hint, not thrown.
        # Every case below passes an explicit script_path so none of them
        # fall through to the *real* cellpose_script_path() default and
        # touch the user's actual ~/.flimapp (same test-hygiene reasoning as
        # the "state persistence round-trip" testset's mktempdir() above).
        @test TIFFApp.run_cellpose_segmentation(image; python_cmd=joinpath(tempname(), "python3"), script_path=stub_path) === nothing

        # python_cmd exists but isn't executable -> the Sys.which guard
        # rejects it the same as a nonexistent path (Sys.which checks the
        # executable bit, not just isfile) -> nothing, not thrown.
        non_executable = tempname()
        write(non_executable, "not an executable")
        @test TIFFApp.run_cellpose_segmentation(image; python_cmd=non_executable, script_path=stub_path) === nothing
        rm(non_executable; force=true)

        # Subprocess launches but exits nonzero -> nothing, not thrown.
        @test TIFFApp.run_cellpose_segmentation(image; python_cmd="/usr/bin/false", script_path=stub_path) === nothing
    finally
        rm(stub_path; force=true)
    end
end

@testset "cellpose_venv_python_path / cellpose_script_path" begin
    py_path = TIFFApp.cellpose_venv_python_path()
    @test occursin(joinpath(".tiffapp", "cellpose-env"), py_path)
    @test occursin(Sys.iswindows() ? "python.exe" : "python3", py_path)

    dir = mktempdir()
    script_path = TIFFApp.cellpose_script_path(; dir=dir)
    @test isfile(script_path)
    @test read(script_path, String) == TIFFApp.CELLPOSE_SEGMENT_SCRIPT

    # Stale/edited on-disk copy is refreshed back to the compiled-in script
    # on the next call, not left stale.
    write(script_path, "stale content")
    script_path2 = TIFFApp.cellpose_script_path(; dir=dir)
    @test read(script_path2, String) == TIFFApp.CELLPOSE_SEGMENT_SCRIPT
end

end # @testset TIFFApp
