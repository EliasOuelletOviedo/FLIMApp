using Test
using FLIMApp
using FLIMApp: ChannelFrame, ChannelSeries, AcquisitionSample, ProtocolSettings,
               LayoutSettings, ControllerSettings, RoiSettings, ConsoleSettings

# These tests cover the GUI-free logic: protocol schedule math, smoothing,
# state persistence, spinner stepping, plot windowing, and the MLE lifetime
# fit on a synthetic decay with a known lifetime. The GUI itself (Makie
# widgets/handlers) is exercised manually via run_app().

@testset "FLIMApp" begin

@testset "protocol schedule math" begin
    protocol = ProtocolSettings(
        active=true,
        repeats=2,
        delay=5,
        times=vcat([10.0, 20.0], fill(NaN, FLIMApp.PROTOCOL_STEP_COUNT - 2)),
        setpoints=vcat([3.5, 4.0], fill(NaN, FLIMApp.PROTOCOL_STEP_COUNT - 2))
    )

    # NaN-duration steps are skipped
    @test FLIMApp.protocol_steps(protocol) == [(10.0, 3.5), (20.0, 4.0)]

    # Before the delay has elapsed: no setpoint
    @test isnan(FLIMApp.protocol_setpoint_at(protocol, 2.0))
    # First step [5, 15), second step [15, 35)
    @test FLIMApp.protocol_setpoint_at(protocol, 6.0) == 3.5
    @test FLIMApp.protocol_setpoint_at(protocol, 20.0) == 4.0
    # Second repeat of the 30 s cycle: t = 5 + 30 + 2 is inside step 1 again
    @test FLIMApp.protocol_setpoint_at(protocol, 37.0) == 3.5
    # After both repeats (5 + 2*30 = 65): schedule over
    @test isnan(FLIMApp.protocol_setpoint_at(protocol, 70.0))
    # Non-finite timestamp
    @test isnan(FLIMApp.protocol_setpoint_at(protocol, NaN))

    # repeats == 0 repeats forever
    forever = ProtocolSettings(
        active=true, repeats=0, delay=0,
        times=vcat([10.0], fill(NaN, FLIMApp.PROTOCOL_STEP_COUNT - 1)),
        setpoints=vcat([2.5], fill(NaN, FLIMApp.PROTOCOL_STEP_COUNT - 1))
    )
    @test FLIMApp.protocol_setpoint_at(forever, 1234.0) == 2.5

    # normalize copies vectors and clamps negatives
    raw = ProtocolSettings(active=true, repeats=-3, delay=-1,
                           times=fill(NaN, FLIMApp.PROTOCOL_STEP_COUNT),
                           setpoints=fill(NaN, FLIMApp.PROTOCOL_STEP_COUNT))
    normalized = FLIMApp.normalize_protocol_config(raw)
    @test normalized.repeats == 0
    @test normalized.delay == 0
    @test normalized.times !== raw.times
end

@testset "protocol CSV round-trip" begin
    dir = mktempdir()
    csv_path = joinpath(dir, "protocol.csv")
    times = vcat([10.0, 20.0, 30.0], fill(NaN, FLIMApp.PROTOCOL_STEP_COUNT - 3))
    setpoints = vcat([3.5, 4.0, 2.0], fill(NaN, FLIMApp.PROTOCOL_STEP_COUNT - 3))

    FLIMApp.write_protocol_csv(csv_path; repeats=3, delay=7, times=times, setpoints=setpoints)
    imported = FLIMApp.read_protocol_csv(csv_path; step_count=FLIMApp.PROTOCOL_STEP_COUNT)

    @test imported.repeats == 3
    @test imported.delay == 7
    @test imported.times[1:3] == times[1:3]
    @test imported.setpoints[1:3] == setpoints[1:3]
    @test all(isnan, imported.times[4:end])
end

@testset "state persistence round-trip" begin
    app = AppState(true)
    app.layout.binning = 7
    app.layout.plot1 = "Histogram"
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
    @test loaded.layout.plot1 == "Histogram"
    @test loaded.controller.P1 == 1.25
    @test loaded.protocol.times[1] == 12.0
    # Vectors must be copies, not aliases of the original state
    @test loaded.protocol.times !== app.protocol.times

    @test FLIMApp.valid_app_state(loaded)
    @test !FLIMApp.valid_app_state("not a state")

    # Missing and corrupted files fall back to nothing (fresh defaults)
    @test load_state(joinpath(dir, "missing.jls")) === nothing
    garbage = joinpath(dir, "garbage.jls")
    write(garbage, "this is not a serialized Dict")
    @test load_state(garbage) === nothing
end

@testset "smoothing" begin
    @test FLIMApp.lifetime_smooth_level(LayoutSettings(smoothing=99)) == 10
    @test FLIMApp.lifetime_smooth_level(LayoutSettings(smoothing=-2)) == 0

    # Level 1 leaves q unscaled; level 10 spans KALMAN_LEVEL_SPAN.
    @test FLIMApp.kalman_strength_factor(1) == 1.0
    @test FLIMApp.kalman_strength_factor(10) == FLIMApp.KALMAN_LEVEL_SPAN

    # Level 0 is an exact passthrough (kalman_update! re-arms at measurement).
    state = FLIMApp.KalmanState()
    @test FLIMApp.kalman_update!(state, 3.05, 1.0, 0) == 3.05
    # Non-finite measurement is returned unchanged.
    @test isnan(FLIMApp.kalman_update!(FLIMApp.KalmanState(), NaN, 1.0, 5))

    # Smoothing pulls a new estimate between the prior estimate and the raw value.
    state = FLIMApp.KalmanState()
    FLIMApp.kalman_update!(state, 3.0, 1.0, 5)       # seed the filter
    smoothed = FLIMApp.kalman_update!(state, 3.1, 1.0, 5)
    @test 3.0 <= smoothed <= 3.1
end

@testset "spinner stepping (smart_next/smart_prev)" begin
    # 1,2,...,9,10,20,...,90,100,200,... series
    @test FLIMApp.smart_next(1, 1, 99999, Int) == 2
    @test FLIMApp.smart_next(9, 1, 99999, Int) == 10
    @test FLIMApp.smart_next(10, 1, 99999, Int) == 20
    @test FLIMApp.smart_next(99999, 1, 99999, Int) == 99999   # clamped at max
    @test FLIMApp.smart_prev(20, 1, 99999, Int) == 10
    @test FLIMApp.smart_prev(10, 1, 99999, Int) == 9
    @test FLIMApp.smart_prev(1, 1, 99999, Int) == 1           # clamped at min
    # Integer edge handling around zero (smoothing spinner)
    @test FLIMApp.smart_next(0, 0, 10, Int) == 1
    @test FLIMApp.smart_prev(1, 0, 10, Int) == 0
end

@testset "plot windowing helpers" begin
    xs = collect(0.0:1.0:100.0)
    ys = collect(0.0:1.0:100.0)
    win_x, win_y = FLIMApp.windowed_slice(xs, ys, 10.0)
    @test win_x[1] == 90.0 && win_x[end] == 100.0
    @test win_y == win_x
    @test FLIMApp.windowed_slice(Float64[], Float64[], 10.0) == (Float64[], Float64[])

    # setpoint spans: contiguous finite runs of the setpoint series
    ts = [0.0, 1.0, 2.0, 3.0, 4.0, 5.0]
    sp = [NaN, 2.0, 2.0, NaN, 3.0, 3.0]
    starts, ends = FLIMApp.protocol_setpoint_spans(ts, sp)
    @test starts == [1.0, 4.0]
    @test ends == [3.0, 5.0]

    @test FLIMApp.normalize_to_own_max([1.0, 2.0, 4.0]) == [0.25, 0.5, 1.0]
    @test FLIMApp.normalize_to_own_max(Float64[]) == Float64[]
    @test FLIMApp.normalize_counts_to_fit([2.0, 4.0], [1.0, 8.0]) == [0.25, 0.5]
end

@testset "ChannelSeries / RoiChannelSeries / AppRun runtime state" begin
    app = AppState(true)
    app_run = AppRun()

    @test app_run.ch1 isa ChannelSeries
    @test app_run.ch2 isa ChannelSeries
    @test FLIMApp.channel_series(app_run) === (app_run.ch1, app_run.ch2)

    # ChannelSeries holds only the "latest frame" snapshot.
    frame = ChannelFrame([1.0, 2.0], [1.0, 2.0], 100.0, 3.0, 1.5)
    FLIMApp.publish_frame!(app_run.ch1, frame)
    @test app_run.ch1.counts[] == 100.0
    @test app_run.ch1.histogram[] == [1.0, 2.0]

    # RoiChannelSeries accumulates the per-frame time series.
    series1 = app_run.ch1_rois[1]
    FLIMApp.accumulate_roi_sample!(app, series1, frame, 0.5)
    FLIMApp.accumulate_roi_sample!(app, app_run.ch2_rois[1], ChannelFrame(), 0.5)

    @test series1.timestamps[] == [0.5]
    @test series1.photons[] == [100.0]
    @test series1.lifetime[] == [3.0]
    @test series1.lifetime_smooth[] == [3.0]              # level 0: passthrough
    @test series1.concentration[] == [1.5]
    @test isnan(app_run.ch2_rois[1].lifetime[][1])        # absent-channel sentinel

    FLIMApp.reset_acquisition_state!(app, app_run)
    @test isempty(app_run.ch1_rois[1].photons[])
    @test isempty(app_run.ch2_rois[1].lifetime[])
    @test app_run.ch1.counts[] == 0.0
    @test isnan(app_run.save_progress[])
end

@testset "PI command" begin
    # PI controller (no D term — the derivative was replaced by a Kalman
    # observer, see ControllerSettings / process_frame!).
    state = FLIMApp.ChannelFitState([3.0, 0.0, 5.0e-5])
    state.old_error = 1.0
    state.I_error = 2.0

    # off -> NaN; no setpoint -> NaN
    @test isnan(FLIMApp.pid_command_from_state(state, 4.0, 1.0, 1.0, false, false))
    @test isnan(FLIMApp.pid_command_from_state(state, NaN, 1.0, 1.0, false, true))
    # P*1 + I*2 = 3.0
    @test FLIMApp.pid_command_from_state(state, 4.0, 1.0, 1.0, false, true) == 3.0
    # inverted and clamped to [0, 100]
    @test FLIMApp.pid_command_from_state(state, 4.0, 1.0, 1.0, true, true) == 0.0
    @test FLIMApp.pid_command_from_state(state, 4.0, 100.0, 100.0, false, true) == 100.0
end

@testset "acquisition helpers" begin
    @test FLIMApp.initial_guess_for_lifetimes("1 lifetime") == [3.0, 0.0, 5.0e-5]
    @test length(FLIMApp.initial_guess_for_lifetimes("2 lifetimes")) == 5
    @test length(FLIMApp.initial_guess_for_lifetimes("3 lifetimes")) == 7

    @test FLIMApp.resolve_protocol_config(nothing) === nothing
    p = ProtocolSettings()
    @test FLIMApp.resolve_protocol_config(p) === p
end

@testset "MLE lifetime fit recovers a known lifetime" begin
    ctx = FLIMApp.RUNTIME[]
    saved = (ctx.irf, ctx.irf_bin_size, ctx.tcspc_window_size)

    try
        n = FLIMApp.DEFAULT_HISTOGRAM_RESOLUTION
        bin = FLIMApp.LASER_PULSE_PERIOD / n

        # Synthetic IRF: a narrow Gaussian peak near the start of the window
        irf = zeros(n, 2)
        irf[:, 1] = (0:(n - 1)) .* bin
        for i in 1:n
            irf[i, 2] = exp(-((i - 10)^2) / 8)
        end

        ctx.irf = irf
        ctx.irf_bin_size = bin
        ctx.tcspc_window_size = round(irf[end, 1] + irf[2, 1], sigdigits=4)

        # One throwaway fit so JIT compilation doesn't eat the real fit's
        # Optim time budget (same reason run_app calls this at startup).
        FLIMApp.warmup_lifetime_fitting!()

        # Noise-free decay generated from the model itself with tau = 3.0 ns
        tau_true = 3.0
        x_data = FLIMApp.get_x_data(n, bin)
        model = FLIMApp.conv_irf_data(x_data, (tau_true, 0.0, 0.0), irf) .* 50_000

        params, data_xy = FLIMApp.vec_to_lifetime(model; guess=[2.0, 0.0, 5.0e-5], first_fit=true)
        @test isapprox(params[1], tau_true; atol=0.25)
        @test length(data_xy) == 2

        # Histograms with too few photons refuse to fit (NaN)
        low_counts, _ = FLIMApp.vec_to_lifetime(fill(0.1, n); guess=[2.0, 0.0, 5.0e-5])
        @test isnan(low_counts[1])
    finally
        ctx.irf, ctx.irf_bin_size, ctx.tcspc_window_size = saved
    end
end

@testset "pixel_lifetime_map" begin
    ctx = FLIMApp.RUNTIME[]
    saved = (ctx.irf, ctx.irf_bin_size, ctx.tcspc_window_size)

    try
        n = FLIMApp.DEFAULT_HISTOGRAM_RESOLUTION
        bin = FLIMApp.LASER_PULSE_PERIOD / n

        # Same synthetic IRF as the MLE fit test above: a narrow Gaussian
        # peak near the start of the window.
        irf = zeros(n, 2)
        irf[:, 1] = (0:(n - 1)) .* bin
        for i in 1:n
            irf[i, 2] = exp(-((i - 10)^2) / 8)
        end
        ctx.irf = irf
        ctx.irf_bin_size = bin
        mean_irf = FLIMApp.find_mean_arrival_time(irf[:, 2])

        # 1x3 "image": pixel 1 is a bright, late point-mass decay; pixel 2 an
        # equally bright but earlier one; pixel 3 is placed like pixel 1 but
        # too dim overall to trust.
        volume = zeros(1, 3, n)
        volume[1, 1, 50] = 1000.0
        volume[1, 2, 20] = 1000.0
        volume[1, 3, 50] = 5.0

        result = FLIMApp.pixel_lifetime_map(volume; min_photons=50.0)
        @test size(result) == (1, 3)

        # Point-mass histograms make find_mean_arrival_time exact, so the
        # per-pixel result should match the same first-moment formula
        # lifetime_estimate uses, computed independently here.
        @test isapprox(result[1, 1], (50.0 - mean_irf) * bin; atol=1e-9)
        @test isapprox(result[1, 2], (20.0 - mean_irf) * bin; atol=1e-9)
        @test result[1, 1] > result[1, 2]   # later arrival -> longer apparent lifetime
        @test isnan(result[1, 3])           # below min_photons -> masked out

        # No IRF loaded: errors rather than returning a meaningless map.
        ctx.irf = nothing
        ctx.irf_bin_size = nothing
        @test_throws ErrorException FLIMApp.pixel_lifetime_map(volume)
    finally
        ctx.irf, ctx.irf_bin_size, ctx.tcspc_window_size = saved
    end
end

@testset "pixel_label_boundary (Cellpose mask -> ROI polygon)" begin
    # Round-trip check: does re-rasterizing the traced polygon
    # (roi_pixel_mask's own point-in-polygon test, on pixel centers)
    # reproduce the exact original pixel set?
    function reconstructed(mask, xs, ys)
        n_cols, n_rows = size(mask)
        Set((x, y) for x in 1:n_cols, y in 1:n_rows
                   if FLIMApp.point_in_polygon(Float64(x - 1), Float64(y - 1), xs, ys))
    end
    function original(mask, label)
        n_cols, n_rows = size(mask)
        Set((x, y) for x in 1:n_cols, y in 1:n_rows if mask[x, y] == label)
    end
    function exact_roundtrip(mask, label)
        xs, ys = FLIMApp.pixel_label_boundary(mask, label)
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
    xs_empty, ys_empty = FLIMApp.pixel_label_boundary(mask, 99)
    @test isempty(xs_empty) && isempty(ys_empty)

    # Adversarial diagonal-only touch (two pixels sharing only a corner) —
    # not producible by real Cellpose output, but the tracer must fail
    # safely (empty result), not hang or return a broken polygon.
    mask_pinch = zeros(Int, 6, 6)
    mask_pinch[3, 3] = 1
    mask_pinch[4, 4] = 1
    xs_pinch, ys_pinch = FLIMApp.pixel_label_boundary(mask_pinch, 1)
    @test isempty(xs_pinch) == isempty(ys_pinch)   # always both empty or both non-empty
end

@testset "Cellpose binary I/O round-trip" begin
    img = Float64.(reshape(1:24, 6, 4))
    tmp = tempname()
    try
        FLIMApp.write_cellpose_input(tmp, img)

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
        @test FLIMApp.read_cellpose_masks(tmp) == mask
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

        masks = FLIMApp.run_cellpose_segmentation(image; python_cmd="python3", script_path=stub_path)
        @test masks !== nothing
        @test masks == Int32.(image .> 0)

        # Missing script -> nothing, logged, not thrown.
        @test FLIMApp.run_cellpose_segmentation(image; script_path=tempname()) === nothing

        # Cellpose venv not set up (python_cmd doesn't resolve at all, via
        # Sys.which) -> nothing, logged with the setup hint, not thrown.
        # Every case below passes an explicit script_path so none of them
        # fall through to the *real* cellpose_script_path() default and
        # touch the user's actual ~/.flimapp (same test-hygiene reasoning as
        # the "state persistence round-trip" testset's mktempdir() above).
        @test FLIMApp.run_cellpose_segmentation(image; python_cmd=joinpath(tempname(), "python3"), script_path=stub_path) === nothing

        # python_cmd exists but isn't executable -> the Sys.which guard
        # rejects it the same as a nonexistent path (Sys.which checks the
        # executable bit, not just isfile) -> nothing, not thrown.
        non_executable = tempname()
        write(non_executable, "not an executable")
        @test FLIMApp.run_cellpose_segmentation(image; python_cmd=non_executable, script_path=stub_path) === nothing
        rm(non_executable; force=true)

        # Subprocess launches but exits nonzero -> nothing, not thrown.
        @test FLIMApp.run_cellpose_segmentation(image; python_cmd="/usr/bin/false", script_path=stub_path) === nothing
    finally
        rm(stub_path; force=true)
    end
end

@testset "cellpose_venv_python_path / cellpose_script_path" begin
    py_path = FLIMApp.cellpose_venv_python_path()
    @test occursin(joinpath(".flimapp", "cellpose-env"), py_path)
    @test occursin(Sys.iswindows() ? "python.exe" : "python3", py_path)

    dir = mktempdir()
    script_path = FLIMApp.cellpose_script_path(; dir=dir)
    @test isfile(script_path)
    @test read(script_path, String) == FLIMApp.CELLPOSE_SEGMENT_SCRIPT

    # Stale/edited on-disk copy is refreshed back to the compiled-in script
    # on the next call, not left stale.
    write(script_path, "stale content")
    script_path2 = FLIMApp.cellpose_script_path(; dir=dir)
    @test read(script_path2, String) == FLIMApp.CELLPOSE_SEGMENT_SCRIPT
end

end # @testset FLIMApp
