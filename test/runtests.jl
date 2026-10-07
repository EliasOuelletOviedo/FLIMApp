using Test
using Logging
using FLIMApp
using FLIMApp: ChannelFrame, ChannelSeries, AcquisitionSample, ProtocolSettings,
               LayoutSettings, ControllerSettings, RoiSettings, ConsoleSettings

# These tests cover the GUI-free logic: protocol schedule math, smoothing,
# state persistence, spinner stepping, plot windowing, the MLE lifetime fit
# on a synthetic decay with a known lifetime, the bench config, the
# exchanges between threads, the journal, the DAQ loop on its simulated
# backend, and the SPC-150N engine (FLIMCore, test_flimcore.jl) with the
# GUI side of it. The GUI itself (Makie widgets/handlers) is exercised
# manually via run_app().

const FLIMCore = FLIMApp.FLIMCore

# A config for tests: simulated cards, journal in a temporary folder.
test_bench_config(overrides = Dict{String, Any}()) = FLIMApp.bench_config_from_dict(
    merge(Dict{String, Any}("hardware" => Dict{String, Any}("backend" => "simulation"),
                            "journal" => Dict{String, Any}("directory" => mktempdir(), "flush_interval_s" => 0.1)),
          overrides); source = "test")

square_roi(x0, y0) = FLIMApp.RoiCoordinates("roi", [x0, x0 + 40, x0 + 40, x0, x0], [y0, y0, y0 + 40, y0 + 40, y0])

"""Every pass the analysis published so far (`ex.frames`), as columns."""
function published(ex)
    records = FLIMApp.FrameRecord[]
    FLIMApp.take_new!(records, ex.frames, 0)
    s = [r.sample for r in records]
    return (roi_index = [r.roi_index for r in records], pass = [x.pass for x in s], timestamp = [x.timestamps for x in s],
            complete = [x.complete for x in s], excluded_because = [x.excluded_because for x in s],
            command1 = [x.command1 for x in s], lifetime_ch1 = [x.ch1.lifetime for x in s],
            lifetime_kalman_ch1 = [x.ch1.lifetime_kalman for x in s], lifetime_ch2 = [x.ch2.lifetime for x in s])
end

"""The record of an IRF taken with `settings` (what `import_irf_sdt` writes), for the checks at START."""
irf_info_for(settings) = Dict{String, Any}(
    "channels" => [Dict{String, Any}("serial" => serial,
                                     "settings" => Dict{String, Any}(k => Float64(v) for (k, v) in settings.spc
                                                                     if k in first.(FLIMApp.IRF_CARD_SETTINGS)))
                   for serial in settings.series],
    "dcc" => Dict{String, Any}(settings.dcc))

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

    # Axis limits follow the data: the last time_range seconds, y over that
    # window only (an old outlier and NaN values don't count).
    app = AppState(true)
    app.layout.time_range = 10
    bound_line(xs, ys) = FLIMApp.SeriesLine(FLIMApp.Observable(FLIMApp.Point2f[]), xs, ys)
    plot = FLIMApp.PlotSlot()
    ys = [i < 15 ? 1000.0 : Float64(i) for i in 0:30]
    ys[end] = NaN
    push!(plot.series_lines, bound_line(collect(0.0:1.0:30.0), ys))
    @test FLIMApp.data_limits(app, plot; pad_ratio=0.0) == ((20.0, 30.0), (20.0, 29.0))
    # Until time_range seconds of data exist, x spans 0…time_range.
    short = FLIMApp.PlotSlot()
    push!(short.series_lines, bound_line([0.0, 1.0], [2.0, 2.0]))
    @test FLIMApp.data_limits(app, short; pad_ratio=0.0) == ((0.0, 10.0), (1.5, 2.5))
    @test FLIMApp.data_limits(app, FLIMApp.PlotSlot()) === nothing

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
    @test app_run.ch1.histogram[] == [1.0, 2.0]
    @test app_run.ch1.counts[] == 0.0                    # the counts bar is the cards' rate, not the frame's photons

    # RoiChannelSeries accumulates the per-frame time series.
    series1 = app_run.ch1_rois[1]
    FLIMApp.accumulate_roi_sample!(app, series1, frame, 0.5)
    FLIMApp.accumulate_roi_sample!(app, app_run.ch2_rois[1], ChannelFrame(), 0.5)

    @test series1.timestamps == [0.5]
    @test series1.photons == [100.0]
    @test series1.lifetime == [3.0]
    @test series1.lifetime_smooth == [3.0]                # level 0: passthrough
    @test series1.concentration == [1.5]
    @test isnan(app_run.ch2_rois[1].lifetime[1])          # absent-channel sentinel

    # A whole analyzed histogram goes to its ROI's series and the global ones.
    sample = AcquisitionSample(frame, ChannelFrame(), 12.0, NaN, 1.0, 4.0, UInt32(7), 6, 0.05, 1.0, true, 0.0)
    FLIMApp.accumulate_frame!(app, app_run, FLIMApp.FrameRecord(sample, 1))
    @test app_run.command1 == [12.0] && app_run.protocol_setpoint == [4.0] && app_run.i == 7
    @test length(series1.timestamps) == 2

    # Curves are refilled in place from the histories, windowed and decimated.
    points = FLIMApp.Point2f[]
    xs = collect(0.0:1.0:1000.0)
    FLIMApp.fill_points!(points, xs, 2 .* xs, 100.0, 1000)
    @test first(points)[1] == 900.0 && last(points) == FLIMApp.Point2f(1000.0, 2000.0)
    FLIMApp.fill_points!(points, xs, xs, Inf, 10)
    @test length(points) <= 11 && last(points)[1] == 1000.0

    FLIMApp.reset_acquisition_state!(app, app_run; n_rois = 3)            # a Playback session's ROIs
    @test length(app_run.ch1_rois) == 3 && length(app_run.ch2_rois) == 3
    FLIMApp.reset_acquisition_state!(app, app_run)
    @test length(app_run.ch1_rois) == 1
    @test isempty(app_run.ch1_rois[1].photons)
    @test isempty(app_run.ch2_rois[1].lifetime)
    @test isempty(app_run.command1)
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

@testset "bench config" begin
    # The shipped file holds exactly the built-in defaults.
    shipped = FLIMApp.load_bench_config(FLIMApp.default_bench_config_path())
    defaults = FLIMApp.bench_config_from_dict(Dict{String, Any}())
    for field in fieldnames(FLIMApp.BenchConfig)
        field == :source || @test getfield(shipped, field) == getfield(defaults, field)
    end
    @test shipped.block_samples == 200                     # 20 ms at 10 kHz
    @test FLIMApp.bench_devices(shipped) == ["X6321", "S6110"]

    # A typo or an impossible value is an error, not a silent default.
    @test_throws ErrorException FLIMApp.bench_config_from_dict(Dict("timing" => Dict("blok_ms" => 20)))
    @test_throws ErrorException FLIMApp.bench_config_from_dict(Dict("hardware" => Dict("backend" => "usb")))
    @test_throws ErrorException FLIMApp.bench_config_from_dict(Dict("timing" => Dict("lead_slots" => 1)))
    @test_throws ErrorException FLIMApp.bench_config_from_dict(Dict("channels" => Dict("readback_signals" => ["galvo_z"])))
end

@testset "DAQ command voltage" begin
    cfg = test_bench_config()
    full_scale = cfg.command_full_scale_v
    @test FLIMApp.command_volts(0.0, cfg) == 0.0
    @test FLIMApp.command_volts(50.0, cfg) == full_scale / 2
    @test FLIMApp.command_volts(100.0, cfg) == full_scale
    # Clamped to 0–100 % and to the declared range; a controller that's off (NaN) outputs 0 V.
    @test FLIMApp.command_volts(250.0, cfg) == full_scale
    @test FLIMApp.command_volts(-5.0, cfg) == 0.0
    @test FLIMApp.command_volts(NaN, cfg) == 0.0
    capped = test_bench_config(Dict{String, Any}("limits" => Dict{String, Any}("command_max_v" => 1.0)))
    @test FLIMApp.command_volts(100.0, capped) == 1.0
end

@testset "exchanges between threads" begin
    # Ring: the reader gets everything new; overwritten items are reported lost.
    ring = FLIMApp.Ring{Int}(4)
    out = Int[]
    foreach(i -> FLIMApp.publish!(ring, i), 1:3)
    cursor, lost = FLIMApp.take_new!(out, ring, 0)
    @test out == [1, 2, 3] && cursor == 3 && lost == 0
    foreach(i -> FLIMApp.publish!(ring, i), 4:9)
    empty!(out)
    cursor, lost = FLIMApp.take_new!(out, ring, cursor)
    @test out == [6, 7, 8, 9] && lost == 2
    @test FLIMApp.reset_cursor(ring) == 9

    # Journal queue: never blocks, drops and counts past capacity.
    queue = FLIMApp.JournalQueue(2)
    @test FLIMApp.journal_event!(queue, :info, "a") && FLIMApp.journal_event!(queue, :info, "b")
    @test !FLIMApp.journal_event!(queue, :info, "c")
    @test queue.dropped[] == 1
    @test length(FLIMApp.drain_journal!(FLIMApp.JournalEntry[], queue)) == 2
    @test FLIMApp.pending_journal(queue) == 0

    # Readback pool: no free buffer means 0, never a wait.
    pool = FLIMApp.ReadbackPool(2, 3, 1)
    index = FLIMApp.acquire!(pool)
    @test index == 1 && FLIMApp.acquire!(pool) == 0
    FLIMApp.release!(pool, index)
    @test FLIMApp.acquire!(pool) == 1

    # Loop commands never block the GUI, even when nobody takes them.
    ex = FLIMApp.Exchange()
    @test all(_ -> FLIMApp.send_command!(ex, FLIMApp.ConnectCommand()), 1:FLIMApp.LOOP_COMMAND_CAPACITY)
    @test !(@test_logs (:warn,) match_mode=:any FLIMApp.send_command!(ex, FLIMApp.ConnectCommand()))
end

@testset "ROI scan slots" begin
    cfg = test_bench_config()
    rois = [square_roi(100.0, 100.0), square_roi(600.0, 300.0), square_roi(300.0, 800.0)]
    order = FLIMApp.roi_visit_order(rois)
    @test sort(order) == [1, 2, 3] && first(order) == 1
    request = FLIMApp.ScanRequest(rois, order, true, -1000, 1000, -1000, 1000, 20, 3, 95, 5, (1024, 1024))
    pattern = FLIMApp.build_scan_pattern(request, cfg)

    n_scan, n_shift = 950, 50
    @test pattern.slot_samples == n_scan + n_shift
    @test FLIMApp.slots_per_cycle(pattern) == 3
    @test FLIMApp.slot_duration_s(pattern) ≈ (95 + 5) / 1000
    @test pattern.roi_order == order
    @test FLIMApp.slot_roi(pattern, 4) == order[2] && FLIMApp.slot_visit(pattern, 4) == 1

    buffers = FLIMApp.SlotBuffers(pattern.slot_samples)
    rising_edges(v) = count(i -> v[i] == 1 && v[i - 1] == 0, 2:length(v))
    for s in 0:2
        FLIMApp.prepare_slot!(buffers, pattern, s, 2.0, 0.5)
        line(b) = (buffers.lines .>> b) .& 0x01
        gate = line(FLIMApp.DO_BIT_GATE)
        # Scan: gate high, commands on. Shift: gate low, commands at 0 V —
        # every slot ends off.
        @test all(==(1), gate[1:n_scan]) && all(==(0), gate[n_scan+1:end])
        @test all(==(2.0), buffers.commands[1:n_scan]) && all(==(0.0), buffers.commands[n_scan+1:pattern.slot_samples])
        @test all(==(0.5), buffers.commands[pattern.slot_samples+1:pattern.slot_samples+n_scan])
        @test buffers.commands[end] == 0.0 && buffers.lines[end] & FLIMApp.do_bit(FLIMApp.DO_BIT_GATE) == 0
        # During the scan, the visited ROI's routing code (its drawn index),
        # written as NOT(code) on bits 4–7 — the SPC-150N's routing inputs are
        # active low, it reads the code itself; during the move, the reserved
        # code, whose photons the decoding throws away. Enable on throughout.
        codes = buffers.lines .>> FLIMApp.DO_ROI_CODE_SHIFT
        @test all(==(~UInt8(order[s + 1]) & 0x0f), codes[1:n_scan]) && all(==(0x0f), codes[n_scan+1:end])
        @test all(==(1), line(FLIMApp.DO_BIT_ENABLE))
        pulse = round(Int, cfg.sync_pulse_s * cfg.sample_rate_hz)
        @test sum(line(FLIMApp.DO_BIT_ROI)) == pulse
        @test sum(line(FLIMApp.DO_BIT_SEQUENCE)) == (s == 0 ? pulse : 0)
        FLIMApp.check_slot(buffers, cfg)
    end

    # The entry onto the first ROI: the reserved code, everything else off.
    @test all(==(0xf0), FLIMApp.entry_buffers(pattern).lines)
    # No CNTE line any more (the reserved code does its job).
    @test_throws ErrorException test_bench_config(Dict{String, Any}("sync" => Dict{String, Any}("cnte_line" => 3)))

    # The spiral points in order, each held equally long; the shift ends on
    # the next ROI's center (half-cosine move); the entry reaches the first.
    segments = FLIMApp.roi_scan_segments(request)
    FLIMApp.prepare_slot!(buffers, pattern, 0, 0.0, 0.0)
    held = [(buffers.galvos[j], buffers.galvos[pattern.slot_samples + j]) for j in 1:n_scan]
    @test unique(held) == unique([(p[1] / 1000, p[2] / 1000) for p in segments[1].points])
    @test buffers.galvos[pattern.slot_samples] ≈ segments[2].center[1] / 1000
    @test pattern.entry_x[1] == 0.0 && pattern.entry_x[end] ≈ segments[1].center[1] / 1000
    @test maximum(abs, pattern.x) <= 1.0 && maximum(abs, pattern.y) <= 1.0    # default ±1000 mV range

    # Without ROI scanning: galvos still at 0 V, the same scan/pause rhythm:
    # the no-ROI code during the scan, the reserved code during the pause.
    idle = FLIMApp.build_scan_pattern(FLIMApp.ScanRequest(rois, Int[], false, -1000, 1000, -1000, 1000, 20, 3, 95, 5, (1024, 1024)), cfg)
    FLIMApp.prepare_slot!(buffers, idle, 7, 1.0, 0.0)
    gate = (buffers.lines .>> FLIMApp.DO_BIT_GATE) .& 0x01
    codes = buffers.lines .>> FLIMApp.DO_ROI_CODE_SHIFT
    @test all(==(0.0), buffers.galvos) && buffers.commands[1] == 1.0
    @test all(==(1), gate[1:n_scan]) && all(==(0), gate[n_scan+1:end])
    @test all(==(~UInt8(FLIMCore.CODE_SANS_ROI) & 0x0f), codes[1:n_scan]) && all(==(0x0f), codes[n_scan+1:end])
    @test FLIMApp.routing_byte(FLIMCore.CODE_HORS_ROI, false) == 0x00
    @test FLIMApp.slots_per_cycle(idle) == 1 && FLIMApp.slot_duration_s(idle) ≈ 0.1

    # More ROIs than routing codes (4 lines, code 0 reserved: 15 ROIs): refused.
    many = [square_roi(10.0 * k, 10.0 * k) for k in 1:16]
    @test_throws FLIMApp.SafetyError FLIMApp.build_scan_pattern(
        FLIMApp.ScanRequest(many, collect(1:16), true, -1000, 1000, -1000, 1000, 20, 3, 95, 5, (1024, 1024)), cfg)
    @test FLIMApp.build_scan_pattern(
        FLIMApp.ScanRequest(many[1:15], collect(1:15), true, -1000, 1000, -1000, 1000, 20, 3, 95, 5, (1024, 1024)), cfg) isa FLIMApp.ScanPattern

    # The pass counter needs at least two samples of scan and of pause.
    @test_throws FLIMApp.SafetyError FLIMApp.build_scan_pattern(
        FLIMApp.ScanRequest(rois, order, true, -1000, 1000, -1000, 1000, 20, 3, 95, 0, (1024, 1024)), cfg)

    # Refused before anything reaches the card.
    @test_throws FLIMApp.SafetyError FLIMApp.build_scan_pattern(
        FLIMApp.ScanRequest(rois, order, true, -9000, 9000, -1000, 1000, 20, 3, 95, 5, (1024, 1024)), cfg)
    @test_throws FLIMApp.SafetyError FLIMApp.check_galvo_path([0.0, NaN], [0.0, 0.0], cfg)
    buffers.commands[1] = cfg.command_max_v + 1
    @test_throws FLIMApp.SafetyError FLIMApp.check_slot(buffers, cfg)
end

@testset "DAQ loop on the simulated cards" begin
    cfg = test_bench_config()
    ex = FLIMApp.Exchange(cfg)
    # Paced in real time, but without the wall-clock deadline: a GC pause
    # during the test suite must not turn into a fault here.
    hw = FLIMApp.SimulatedHardware(cfg; realtime=true, strict_timing=false)
    loop = Threads.@spawn FLIMApp.daq_loop(cfg, ex; hardware=hw)
    journal = Threads.@spawn FLIMApp.journal_loop(cfg, ex)
    state() = FLIMApp.loop_status(ex).state
    await(f; timeout=10.0) = timedwait(f, timeout; pollint=0.005) === :ok

    FLIMApp.send_command!(ex, FLIMApp.ConnectCommand())
    @test await(() -> state() == FLIMApp.LOOP_READY)
    @test hw.zero_count == 1                                   # INIT zeroes everything

    rois = [square_roi(100.0, 100.0), square_roi(600.0, 300.0), square_roi(300.0, 800.0)]
    order = FLIMApp.roi_visit_order(rois)
    request = FLIMApp.ScanRequest(rois, order, true, -1000, 1000, -1000, 1000, 20, 3, 45, 5, (1024, 1024))
    FLIMApp.send_journal!(ex.journal, FLIMApp.JournalRunStart(time(), FLIMApp.new_run_dir(FLIMApp.journal_root(cfg), time()),
                                                              Dict{String, Any}("mode" => "test"), Matrix{Float64}[]))
    FLIMApp.set_command_values!(ex, 40.0, NaN)                 # every ROI
    FLIMApp.set_command_values!(ex, order[2], 60.0, NaN)       # one PI per ROI
    FLIMApp.send_command!(ex, FLIMApp.StartCommand(request))
    @test await(() -> state() == FLIMApp.LOOP_RUNNING)
    summaries = FLIMApp.SlotSummary[]
    @test await(() -> (FLIMApp.take_new!(summaries, ex.slots, length(summaries)); length(summaries) >= 6))

    # Slots follow the visiting order; commands carried as written; the loop
    # stays far from its deadline.
    @test [s.roi for s in summaries[1:3]] == order
    # Each ROI's scan carries that ROI's commands.
    @test all(s -> s.command1_v == FLIMApp.command_volts(s.roi == order[2] ? 60.0 : 40.0, cfg) && s.command2_v == 0.0, summaries)
    @test all(s -> s.iteration_s < s.deadline_s / 2, summaries)

    # The readback is what was written (the simulation mirrors the outputs).
    view = ex.readback
    pattern = FLIMApp.build_scan_pattern(request, cfg)
    lock(view.lock)
    data, n_points, slot = copy(view.data), view.n_points, view.slot
    unlock(view.lock)
    stride = max(1, cld(pattern.slot_samples, cfg.max_points_per_line))
    expected = pattern.x[1:stride:end, FLIMApp.slot_position(pattern, slot)]
    @test maximum(abs.(data[1, 1:n_points] .- expected[1:n_points])) < 1e-6

    # STOP: outputs zeroed, back to READY, within the plan's 50 ms (plus scheduling slack).
    t0 = time()
    FLIMApp.request_stop!(ex)
    @test await(() -> state() == FLIMApp.LOOP_READY)
    @test time() - t0 < 0.5
    @test hw.zero_count == 2 && !hw.running

    # Missed deadline -> FAULT (outputs zeroed); START refused until acknowledged.
    ex.stop[] = false
    FLIMApp.send_command!(ex, FLIMApp.StartCommand(request))
    @test await(() -> state() == FLIMApp.LOOP_RUNNING)
    sleep(0.1)
    hw.skip_samples = 10 * pattern.slot_samples
    @test await(() -> state() == FLIMApp.LOOP_FAULT)
    @test occursin("missed deadline", FLIMApp.loop_status(ex).message)
    @test hw.zero_count == 3
    FLIMApp.send_command!(ex, FLIMApp.AcknowledgeCommand())
    @test await(() -> state() == FLIMApp.LOOP_READY)

    FLIMApp.send_journal!(ex.journal, FLIMApp.JournalRunEnd(time()))
    FLIMApp.send_command!(ex, FLIMApp.DisconnectCommand())
    FLIMApp.send_command!(ex, FLIMApp.QuitCommand())
    @test await(() -> istaskdone(loop))
    ex.shutdown[] = true
    @test await(() -> istaskdone(journal))
    @test ex.journal.dropped[] == 0

    # The journal wrote one run folder with the visits and the readback.
    run_dir = only(filter(isdir, readdir(FLIMApp.journal_root(cfg); join=true)))
    @test readlines(joinpath(run_dir, "frames.csv")) == [FLIMApp.FRAMES_CSV_HEADER]
    visits = readlines(joinpath(run_dir, "visits.csv"))
    @test visits[1] == FLIMApp.VISITS_CSV_HEADER && length(visits) > 6
    readback = reinterpret(Float32, read(joinpath(run_dir, "readback.bin")))
    @test length(readback) % length(cfg.readback_signals) == 0
    @test isfile(joinpath(run_dir, "run.toml")) && isfile(joinpath(run_dir, "readback.txt"))
    @test any(l -> occursin("missed deadline", l), readlines(joinpath(run_dir, "log.txt")))
end

@testset "DAQ loop without the NI driver" begin
    # Connecting fails into a disconnected state with the reason — RECONNECT
    # retries; no fault, nothing throws.
    disconnected = FLIMApp.LoopStatus(FLIMApp.LOOP_DISCONNECTED, "")
    failed = FLIMApp.LoopStatus(FLIMApp.LOOP_DISCONNECTED, "connection failed: no card")
    @test FLIMApp.connect_button_label(disconnected) == "CONNECT" && FLIMApp.connect_button_label(failed) == "RECONNECT"
    @test FLIMApp.connect_button_label(FLIMApp.LoopStatus(FLIMApp.LOOP_FAULT, "x")) == "RESET"
    @test FLIMApp.loop_status_text(failed) == "DAQ: connection failed"
    if isempty(Base.Libc.Libdl.find_library("nicaiu"))
        cfg = FLIMApp.bench_config_from_dict(Dict{String, Any}("journal" => Dict{String, Any}("directory" => mktempdir())))
        ex = FLIMApp.Exchange(cfg)
        loop = Threads.@spawn FLIMApp.daq_loop(cfg, ex)
        FLIMApp.send_command!(ex, FLIMApp.ConnectCommand())
        @test timedwait(() -> startswith(FLIMApp.loop_status(ex).message, "connection failed"), 10.0) === :ok
        @test FLIMApp.loop_status(ex).state == FLIMApp.LOOP_DISCONNECTED
        # The message says which problem and which step: no driver to list the devices with.
        @test occursin("[DAQ-09]", FLIMApp.loop_status(ex).message) && occursin("listing the NI devices", FLIMApp.loop_status(ex).message)
        FLIMApp.send_command!(ex, FLIMApp.QuitCommand())
        @test timedwait(() -> istaskdone(loop), 10.0) === :ok

        # This computer (no NI-DAQmx): offline — Realtime refused, Playback available.
        reason = FLIMApp.offline_reason(cfg, FLIMCore.Reglages())
        @test occursin("OFFLINE", reason) && occursin("NI-DAQmx", reason)
        @test occursin("SPC DLL", reason) == !FLIMCore.SPCLite.dll_disponible()      # the QC-104 needs spcm64.dll too
        @test FLIMApp.offline_reason(test_bench_config(), FLIMCore.Reglages(source = "simulation")) == ""
    end
end

@testset "Diagnostics: problem codes, error context, debug log, GUI handlers" begin
    # A catalog of unique codes, each documented in DEBUGGING.md.
    ids = [p.id for p in FLIMApp.PROBLEM_LIST]
    @test allunique(ids) && all(id -> occursin(r"^[A-Z]+-\d\d$", id), ids)
    doc = read(joinpath(@__DIR__, "..", "DEBUGGING.md"), String)
    @test all(id -> occursin("| $id |", doc), ids)
    @test FLIMApp.problem_text("PASS-02", "card 0") == "[PASS-02] Photons but no M0 marker (start of pass): card 0"
    @test occursin("PFI13", FLIMApp.problem_check("PASS-02"))

    # Reported problems are counted by key, logged once, cleared per run.
    FLIMApp.clear_problems!(("TEST-",))
    logs = Test.TestLogger()
    Logging.with_logger(logs) do
        FLIMApp.report_problem!("PASS-03", "card 7"; key = "PASS-03/card 7")
        FLIMApp.report_problem!("PASS-03", "card 7"; key = "PASS-03/card 7")
    end
    @test count(r -> get(Dict(r.kwargs), :problem, "") == "PASS-03", logs.logs) == 1
    record = only(filter(r -> r.key == "PASS-03/card 7", FLIMApp.problem_records()))
    @test record.count == 2 && occursin("card 7", first(FLIMApp.problem_lines()))
    FLIMApp.clear_problems!(("PASS-",))
    @test !any(r -> r.key == "PASS-03/card 7", FLIMApp.problem_records())

    # An error says which step failed, then the cause.
    err = try
        FLIMApp.with_context("creating the pass counter task (X6321/ctr1)") do
            FLIMApp.with_context("DAQmxCreateCOPulseChanTicks") do
                throw(FLIMApp.DAQmx.DAQmxError(Int32(-200431), "Selected physical channel does not support this operation.\nTask Name: flimapp_passes"))
            end
        end
    catch e
        e
    end
    @test sprint(showerror, err) == "creating the pass counter task (X6321/ctr1): DAQmxCreateCOPulseChanTicks: DAQmx -200431 : " *
                                    "Selected physical channel does not support this operation.\nTask Name: flimapp_passes"
    @test FLIMApp.root_cause(err) isa FLIMApp.DAQmx.DAQmxError && length(FLIMApp.error_contexts(err)) == 2
    @test FLIMApp.loop_problem_id(err, :scan) == "DAQ-04"
    @test FLIMApp.describe_loop_error(err) == "creating the pass counter task (X6321/ctr1): DAQmxCreateCOPulseChanTicks: " *
                                              "DAQmx -200431: Selected physical channel does not support this operation."
    deadline = FLIMApp.ContextError("scan, slot 12, reading the readback", FLIMApp.DAQmx.DAQmxError(FLIMApp.DAQmx.CODES_ECHEANCE_MANQUEE[1], "x"), [])
    @test FLIMApp.loop_problem_id(deadline, :scan) == "DAQ-05" && FLIMApp.missed_deadline(deadline)
    @test FLIMApp.loop_problem_id(FLIMApp.SafetyError("galvo"), :scan) == "DAQ-07"
    rtsi = FLIMApp.ContextError("scan, slot 0, writing the entry and the first slots",
                                FLIMApp.DAQmx.DAQmxError(Int32(-89125), "No registered trigger lines could be found between the devices in the route."), [])
    @test FLIMApp.loop_problem_id(rtsi, :scan) == "DAQ-10" && FLIMApp.loop_problem_id(rtsi, :connect) == "DAQ-10"
    @test FLIMApp.loop_problem_id(ErrorException("NI device(s) not found: X6321 (seen: Dev1 (PCIe-6321))"), :connect) == "DAQ-01"
    @test FLIMApp.loop_problem_id(FLIMApp.ContextError("creating the galvo AO task", ErrorException("x"), []), :connect) == "DAQ-03"
    @test FLIMApp.loop_problem_id(ErrorException("x"), :connect) == "DAQ-09"

    # SPC engine alerts (in French) get their code.
    @test FLIMApp.alert_problem_id("module 0 : SYNC perdu (pas de signal) : laser coupé") == "SPC-03"
    @test FLIMApp.alert_problem_id("module 1 : chute du CFD (12 /s, seuil 100 /s)") == "SPC-04"
    @test FLIMApp.alert_problem_id("module 0 : FIFO débordé, des photons sont perdus") == "SPC-07"
    @test FLIMApp.alert_problem_id("module 0 : réglage non appliqué, tac_gain demandé 4, appliqué 2") == "SPC-05"
    @test FLIMApp.alert_problem_id("canal 2 : carte n° 3N0318 introuvable ou pas prête") == "SPC-02"
    @test FLIMApp.alert_problem_id("module 1 verrouillé par un autre programme (SPCM ouvert ?)") == "SPC-01"
    @test FLIMApp.alert_problem_id("module 0 : 3 passe(s) de durée M3 − M0 hors tolérance") == "PASS-05"
    @test FLIMApp.alert_problem_id("autre chose") == "SPC-06"

    # The debug log: time, level, thread, source line, values, stack trace.
    path = joinpath(mktempdir(), "debug", "test_debug.log")
    logger = FLIMApp.DebugLogger(path; console = Logging.NullLogger())
    Logging.with_logger(logger) do
        @info "hello" value = 42
        try
            error("boom")
        catch e
            @error "it failed" exception = (e, catch_backtrace())
        end
    end
    text = read(path, String)
    @test occursin(r"INFO t\d+ Main runtests\.jl:\d+ \| hello\n    value = 42", text)
    @test occursin("ERROR", text) && occursin("it failed", text) && occursin("boom", text) && occursin("Stacktrace", text)
    @test length(logger.recent) == 2

    # GUI handlers can't fail silently: GUI-01 with the handler's source line.
    x = FLIMApp.Observable(0)
    FLIMApp.on(x) do v
        v == 1 && error("handler boom")
        return v
    end
    Logging.with_logger(Logging.NullLogger()) do
        x[] = 1                                         # doesn't throw
    end
    gui = filter(r -> r.id == "GUI-01" && occursin("handler boom", r.text), FLIMApp.problem_records())
    @test !isempty(gui) && occursin(r"runtests\.jl:\d+", first(gui).text)
end

@testset "Diagnostics: what the cards received (pass signal, routing)" begin
    # Most cases with M3 wired (fin_par_m3 = true); M0 only further down.
    counters(; carte = 0, photons = 10_000, marqueurs = [10, 0, 0, 10], codes = Dict(1 => 5000), hors_passe = 0,
             passes = 10, durations = (0.95, 0.95, 0.95), intervals = (1.0, 1.0), pertes = 0, fovfl = false, unpaired = 0,
             early = 0, missing_m0 = 0) =
        FLIMCore.CompteursCarte(carte, "3N0317", carte + 1, 25e-9, 2photons, photons, marqueurs, [get(codes, k, 0) for k in 0:15],
                                10, hors_passe, passes, 0, pertes, fovfl, durations..., intervals..., early, missing_m0, unpaired, 0)
    state(cards; written = [1], duree = 10.0, m3 = true) =
        FLIMCore.EtatClamp(time(), duree, false, m3, written, 0.95, 0.05, 1e-4 + 95e-6, cards, 10)
    ids(st) = sort([d.id for d in FLIMApp.diagnose_passes(st)])
    detail(st, id) = only(filter(d -> d.id == id, FLIMApp.diagnose_passes(st))).detail

    @test isempty(ids(state([counters()])))                                                     # all well
    @test ids(state([counters(photons = 0)])) == ["PASS-01"]
    @test ids(state([counters(marqueurs = [0, 0, 0, 0], passes = 0)])) == ["PASS-02"]
    @test isempty(ids(state([counters(marqueurs = [0, 0, 0, 0], passes = 0)]; duree = 1.0)))      # too early to say
    @test ids(state([counters(marqueurs = [0, 300, 4, 0], passes = 0)])) == ["PASS-07"]
    @test ids(state([counters(marqueurs = [10, 0, 0, 0], passes = 0)])) == ["PASS-03"]
    @test ids(state([counters(marqueurs = [10, 0, 0, 6])])) == ["PASS-04"]
    # M0 only (no access to M3): no M3 is expected; M0 → M0 intervals tell lost or extra M0s.
    @test isempty(ids(state([counters(marqueurs = [10, 0, 0, 0])]; m3 = false)))
    lost = state([counters(marqueurs = [9, 0, 0, 0], missing_m0 = 1, intervals = (1.0, 2.0))]; m3 = false)
    @test ids(lost) == ["PASS-04"] && occursin("1 M0 missing", detail(lost, "PASS-04"))
    @test ids(state([counters(marqueurs = [10, 0, 0, 0], early = 1, intervals = (0.4, 1.0))]; m3 = false)) == ["PASS-04"]
    @test isempty(ids(state([counters(marqueurs = [10, 0, 0, 0], durations = (0.05, 0.05, 0.05))]; m3 = false)))   # length = the scan
    swapped = state([counters(durations = (0.05, 0.05, 0.05))])
    @test ids(swapped) == ["PASS-05"] && occursin("edges swapped", detail(swapped, "PASS-05"))
    late = state([counters(durations = (0.9, 0.95, 0.9))])
    @test ids(late) == ["PASS-05"] && !occursin("swapped", detail(late, "PASS-05"))
    @test ids(state([counters(pertes = 3, fovfl = true)])) == ["SPC-07"]
    @test ids(state([counters(hors_passe = 2000)])) == ["PASS-08"]
    @test ids(state([counters(unpaired = 2)])) == ["PASS-06"]
    @test "PASS-06" in ids(state([counters(passes = 10), counters(carte = 1, passes = 4)]))

    # No M0 anywhere: was the pass signal generated at all (the DAQ loop's slots)?
    nothing_anywhere = state([counters(marqueurs = [0, 0, 0, 0], passes = 0), counters(carte = 1, marqueurs = [0, 0, 0, 0], passes = 0)])
    @test sort([d.id for d in FLIMApp.diagnose_passes(nothing_anywhere; daq_slots = 0)]) == ["PASS-09"]
    generated = FLIMApp.diagnose_passes(nothing_anywhere; daq_slots = 40)
    @test [d.id for d in generated] == ["PASS-02", "PASS-02"] && all(d -> occursin("common part", d.detail) && occursin("40 slot", d.detail), generated)
    one_card = FLIMApp.diagnose_passes(state([counters(), counters(carte = 1, marqueurs = [0, 0, 0, 0], passes = 0)]); daq_slots = 40)
    @test occursin("reaches the other card", only(filter(d -> d.id == "PASS-02", one_card)).detail)

    # Routing: nothing received, inverted, a line stuck, other codes.
    @test ids(state([counters(codes = Dict(0 => 5000))])) == ["ROUTE-01"]
    inverted = state([counters(codes = Dict(14 => 2000, 13 => 2000))]; written = [1, 2])
    @test ids(inverted) == ["ROUTE-02"] && occursin("[13, 14] read", detail(inverted, "ROUTE-02"))
    # R1 stuck low: codes 2 and 3 written, 0 and 1 read.
    stuck = state([counters(codes = Dict(1 => 2000, 0 => 2000, 3 => 0))]; written = [1, 2, 3])
    @test ids(stuck) == ["ROUTE-03"] && occursin("R1 (P0.5) never high", detail(stuck, "ROUTE-03"))
    high = state([counters(codes = Dict(9 => 2000, 10 => 2000))]; written = [1, 2])
    @test ids(high) == ["ROUTE-03"] && occursin("R3 (P0.7) always high", detail(high, "ROUTE-03"))
    @test ids(state([counters(codes = Dict(1 => 2000, 4 => 2000))]; written = [1, 2])) == ["ROUTE-04"]
    @test isempty(ids(state([counters(codes = Dict(1 => 2000))]; written = [1, 2])))          # ROI 2 dark: not wiring
    @test length(FLIMApp.pass_status_lines(state([counters(), counters(carte = 1)]))) == 5

    # From the engine itself: a replay where the cards read the NOT of the
    # codes the NI writes (inverser_routage the wrong way).
    flux = Dict(m => FLIMCore.FluxRejeu(FLIMCore.flux_passes_synthetique(codes = [14, 13], passes = 6, scan_s = 0.02, pause_s = 0.005,
                                                                          graine = m + 1), 0x1, 25e-9, 12.5; serie = s)
                for (m, s) in ((0, "3N0317"), (1, "3N0318")))
    engine = FLIMCore.demarrer_moteur(FLIMCore.Reglages(dossier = mktempdir(), seuil_cfd = 10.0);
                                      source = FLIMCore.SourceRejeu(flux; vitesse = 0, boucle = false))
    FLIMCore.commander!(engine, FLIMCore.Clamp(rois = [1, 2], scan_s = 0.02, pause_s = 0.005, echantillon_s = 1e-4))
    final = nothing
    @test timedwait(() -> (while isready(engine.resultats)
                               r = take!(engine.resultats)
                               r isa FLIMCore.EtatClamp && r.fin && (final = r)
                           end; while isready(engine.histogrammes); take!(engine.histogrammes); end; final !== nothing), 60.0) === :ok
    FLIMCore.arreter_moteur(engine)
    @test final.codes == [1, 2] && all(c -> c.marqueurs[1] == 6 && c.marqueurs[4] == 6 && c.passes == 6, final.cartes)
    @test all(c -> c.duree_min_s ≈ 0.02 && c.duree_max_s ≈ 0.02 && c.photons_par_code[15] > 0, final.cartes)
    @test sort(unique(d.id for d in FLIMApp.diagnose_passes(final))) == ["ROUTE-02"]

    # The analysis worker's counters.
    stats = FLIMApp.WorkerStats()
    stats.passes[] = 40
    stats.fits_failed[2][] = 9
    stats.backlog_max[] = 30
    stats.unmatched[] = 3
    stats.unmatched_codes[] = 1 << 7
    FLIMApp.count_exclusion!(stats, ["module 0 : GAP, 2 enregistrement(s) perdus", "module 1 : M3 − M0 = 20 ms au lieu de 19 ms"])
    worker = FLIMApp.diagnose_worker(stats)
    @test sort([d.id for d in worker]) == ["FIT-02", "FIT-03", "FIT-04", "ROUTE-05"]
    @test !any(d -> d.id == "FIT-03", FLIMApp.diagnose_worker(stats; check_backlog = false))      # Playback faster than 1×
    @test occursin("channel 2: 9 of 40", only(filter(d -> d.id == "FIT-02", worker)).detail)
    @test occursin("GAP records", only(filter(d -> d.id == "FIT-04", worker)).detail)
    @test occursin("[7]", only(filter(d -> d.id == "ROUTE-05", worker)).detail)
end

@testset "Debug report" begin
    app_run = AppRun(test_bench_config())
    FLIMApp.report_problem!("PASS-02", "card 0: test"; key = "PASS-02/report test")
    text = FLIMApp.debug_report_text(app_run; app = AppState(true))
    for title in ("Versions and environment", "Problems seen", "DAQ loop", "SPC engine", "Realtime: what the cards received",
                  "Routing lines read back", "Analysis worker", "IRF", "Settings (layout, controller, protocol)", "config/spc.toml", "Debug log")
        @test occursin(title, text)
    end
    @test occursin("[PASS-02]", text) && occursin("check: The pass signal", text) && !occursin("this section failed", text)
    path = FLIMApp.write_debug_report(app_run, joinpath(mktempdir(), "debug_report.txt"))
    @test isfile(path) && startswith(read(path, String), "FLIMApp debug report")
    FLIMApp.clear_problems!(("PASS-",))
end

@testset "Routing lines read back" begin
    # A readback.bin as the journal writes it: P0.0 (gate) and P0.4–P0.7,
    # 240 samples of scan then 10 of pause, 20 slots.
    signals = ["galvo_x", "galvo_y", "line_0", "line_4", "line_5", "line_6", "line_7"]
    function session(scan_code, pause_code; invert = true, volts = 3.3)
        dir = mktempdir()
        open(joinpath(dir, "readback.txt"), "w") do io
            println(io, "sample_rate_hz = 10000.0")
            println(io, "signals = ", join(signals, ", "))
        end
        samples = Float32[]
        for _ in 1:20, j in 1:250
            scanning = j <= 240
            code = scanning ? scan_code : pause_code
            append!(samples, [0.0f0, 0.0f0, scanning ? volts : 0.0f0, (volts * ((code >> b) & 1) for b in 0:3)...])
        end
        write(joinpath(dir, "readback.bin"), samples)
        open(io -> FLIMApp.TOML.print(io, Dict("spc" => Dict("inverser_routage" => invert), "roi" => Dict("active" => false))),
             joinpath(dir, "run.toml"), "w")
        return dir
    end
    conclusion(dir) = last(FLIMApp.routing_readback_lines(FLIMApp.routing_readback(dir)))

    # No ROI, inverted: NOT 1 = 14 during scans, NOT 0 = 15 during pauses — as programmed.
    r = FLIMApp.routing_readback(session(14, 15))
    @test r.scan_samples == 20 * 240 && r.pause_samples == 20 * 10 && r.expected == [FLIMCore.CODE_SANS_ROI]
    @test r.lines[1].scan_high == 0 && r.lines[1].pause_high == 1 && r.lines[2].scan_high == 1
    @test occursin("as programmed", conclusion(session(14, 15)))
    @test occursin("as programmed", conclusion(session(1, 0; invert = false)))
    @test occursin("never high", conclusion(session(14, 15; volts = 0.3)))
    @test occursin("doesn't write what the run programs", conclusion(session(15, 15)))
    # Slots played (visits.csv) but the gate never high: the readback isn't wired to the lines.
    dir = session(0, 0; volts = 0.1)
    write(joinpath(dir, "visits.csv"), "slot,roi\n0,0\n1,0\n")
    @test FLIMApp.routing_readback(dir).slots == 2
    @test occursin("aren't wired", conclusion(dir)) && occursin("2 slot(s)", conclusion(dir))
    @test FLIMApp.routing_readback(mktempdir()) === nothing
    @test occursin("no readback.bin", only(FLIMApp.routing_readback_lines(nothing)))
end

@testset "Realtime analysis: passes to frames" begin
    # A pass: two cards (channels 1 and 2), 256 channels × 16 routing codes.
    function pass(code_counts; pertes = 0, passe = 3)
        m1, m2 = zeros(UInt32, 256, 16), zeros(UInt32, 256, 16)
        for (code, n) in code_counts
            m1[10, code + 1] = n
            m2[20, code + 1] = n ÷ 2
        end
        return FLIMCore.HistoClamp(passe, 2.0, 2.95, [1, 0], ["3N0317", "3N0318"], [m1, m2], pertes, 12.5 / 256)
    end

    # The ROI of a pass is the routing code most of its photons carry.
    @test FLIMApp.pass_roi(pass([0 => 5, 2 => 100, 3 => 2]), [1, 3, 2]) == (2, 2)
    @test FLIMApp.pass_roi(pass([0 => 5]), [1, 2]) == (0, 0)                # only the reserved code
    @test FLIMApp.pass_roi(pass([4 => 50]), [1, 2]) == (0, 4)               # not one of this run's ROIs
    @test FLIMApp.pass_roi(pass([0 => 5, 2 => 100]), Int[]) == (1, -1)      # no ROI: every photon
    h = pass([0 => 5, 2 => 100])
    @test sum(FLIMApp.pass_histogram(h.histogrammes[1], -1)) == 105
    @test sum(FLIMApp.pass_histogram(h.histogrammes[1], 2)) == 100 && sum(FLIMApp.pass_histogram(h.histogrammes[2], 2)) == 50

    # Finer cards are summed down to the analysis (and IRF) resolution.
    @test FLIMApp.analysis_histogram(fill(UInt16(1), 1024)) == fill(4.0, 256)
    @test FLIMApp.analysis_histogram(UInt16[1, 2, 3]) == [1.0, 2.0, 3.0]

    # emit_frame! publishes for the GUI, the DAQ loop (that ROI's commands),
    # the journal and the save.
    ex = FLIMApp.Exchange()
    frame = ChannelFrame([1.0], [1.0], 10.0, 3.0, 1.0, 2.9)
    out = FLIMApp.AnalysisOutput(ex; roi_order=[1, 2])
    FLIMApp.emit_frame!(out, AcquisitionSample(frame, ChannelFrame(), 25.0, 30.0, 0.9, NaN, UInt32(1), 3, 0.05, 0.9, true, 0.0), 2)
    records = FLIMApp.FrameRecord[]
    FLIMApp.take_new!(records, ex.frames, 0)
    @test only(records).roi_index == 2 && only(records).sample.pass == 3
    @test FLIMApp.command_values(ex, 2) == (25.0, 30.0) && all(isnan, FLIMApp.command_values(ex, 1))
    @test FLIMApp.pending_journal(ex.journal) == 1 && only(records).sample.ch1.lifetime_kalman == 2.9
    @test isnan(ChannelFrame([1.0], [1.0], 1.0, 1.0, 1.0).lifetime_kalman)
    # Playback: the PI outputs are only simulated, never written for the DAQ loop.
    replay = FLIMApp.AnalysisOutput(ex; roi_order=[1, 2], drive_outputs=false)
    FLIMApp.emit_frame!(replay, AcquisitionSample(frame, ChannelFrame(), 70.0, 80.0, 1.9, NaN, UInt32(2), 4, 1.05, 1.9, true, 0.0), 1)
    @test all(isnan, FLIMApp.command_values(ex, 1)) && FLIMApp.command_values(ex, 2) == (25.0, 30.0)
end

@testset "Realtime worker: per ROI and channel, lossy passes kept out of the PI" begin
    saved = [(c.irf, c.irf_bin_size, c.tcspc_window_size) for c in (FLIMApp.RUNTIME[], FLIMApp.RUNTIME_CH2[])]
    try
        irf = FLIMApp.simulated_irf()
        FLIMApp.set_irfs!([irf, irf])
        @test FLIMApp.channel_fit_context(2) === FLIMApp.RUNTIME_CH2[] && FLIMApp.loaded_irfs() == [irf, irf]
        FLIMApp.warmup_lifetime_fitting!()
        x = FLIMApp.get_x_data(256, irf[2, 1])
        decay(tau) = round.(UInt32, FLIMApp.conv_irf_data(x, (tau, 0.0, 0.0), irf) .* 50_000)     # normalized model
        tau = Dict(0 => 2.5, 1 => 2.0, 2 => 3.5)
        function pass(n, code; pertes = 0)
            m1, m2 = zeros(UInt32, 256, 16), zeros(UInt32, 256, 16)
            m1[:, code + 1] = decay(tau[code])
            m2[:, code + 1] = decay(tau[code] + 0.5)
            return FLIMCore.HistoClamp(n, n - 0.95, Float64(n), [1, 0], ["3N0317", "3N0318"], [m1, m2], pertes, 12.5 / 256)
        end

        ex = FLIMApp.Exchange()
        FLIMApp.publish_settings!(ex, FLIMApp.AnalysisSettings(LayoutSettings(), ControllerSettings(ch1_on = true, P1 = 1.0),
                                                               ProtocolSettings()))
        histograms = Channel{FLIMCore.HistoClamp}(16)
        codes = [1, 2, 1, 2, 1, 2]
        foreach(n -> put!(histograms, pass(n, codes[n]; pertes = n == 5 ? 3 : 0)), eachindex(codes))
        put!(histograms, pass(7, 0))                                   # reserved code only: not analyzed
        done = Threads.Atomic{Bool}(true)                              # the replay is over: ends once all are taken
        out = FLIMApp.AnalysisOutput(ex; roi_order = [1, 2])
        FLIMApp.start_realtime(out, Threads.Atomic{Bool}(true), histograms; initial_guess = [3.0, 0.0, 5.0e-5],
                               source_done = done)
        rows = published(ex)
        @test length(rows.pass) == 6 && rows.roi_index == codes && rows.pass == 1:6
        @test out.unmatched_passes == 1 && out.excluded_passes == 1 && rows.complete == [true, true, true, true, false, true]
        @test occursin("GAP", rows.excluded_because[5]) && all(isempty, rows.excluded_because[[1, 2, 3, 4, 6]])
        # Each ROI and channel fit on its own decays.
        @test all(k -> isapprox(rows.lifetime_ch1[k], tau[codes[k]]; atol = 0.15), 1:6)
        @test all(k -> isapprox(rows.lifetime_ch2[k], tau[codes[k]] + 0.5; atol = 0.15), 1:6)
        @test rows.timestamp ≈ (1:6) .- 0.05                        # from the start of the first pass
        # One PI per ROI (setpoint 4 ns, P = 1): ROI 1 is further from it.
        @test rows.command1[1] > rows.command1[2] > 0
        @test all(k -> rows.command1[k] ≈ clamp(4.0 - rows.lifetime_kalman_ch1[k], 0, 100), [1, 2, 3, 4, 6])
        # The lossy pass (ROI 1): shown, but no observer update, command held.
        @test isnan(rows.lifetime_kalman_ch1[5]) && rows.command1[5] == rows.command1[3]
        @test all(isnan, FLIMApp.command_values(ex, 1))                     # cleared when the worker ends
    finally
        for (c, v) in zip((FLIMApp.RUNTIME[], FLIMApp.RUNTIME_CH2[]), saved)
            c.irf, c.irf_bin_size, c.tcspc_window_size = v
        end
    end
end

@testset "Realtime chain: simulated DAQ, simulated SPC-150N, analysis" begin
    # The whole Realtime procedure without hardware: the DAQ loop plays 50 ms
    # slots (45 ms scan, CNTE high, then the pause) over two ROIs; the SPC
    # engine (simulation source) cuts the passes the 6321 counter would mark
    # (M0/M3) and the cards would route; the worker fits them per ROI and
    # channel and writes each ROI's commands for the DAQ loop.
    saved = [(c.irf, c.irf_bin_size, c.tcspc_window_size) for c in (FLIMApp.RUNTIME[], FLIMApp.RUNTIME_CH2[])]
    cfg = test_bench_config()
    ex = FLIMApp.Exchange(cfg)
    hw = FLIMApp.SimulatedHardware(cfg; realtime=true, strict_timing=false)
    loop = Threads.@spawn FLIMApp.daq_loop(cfg, ex; hardware=hw)
    engine = FLIMCore.demarrer_moteur(FLIMCore.Reglages(source = "simulation", dossier = mktempdir(), seuil_cfd = 10.0))
    running = Threads.Atomic{Bool}(true)
    await(f; timeout=60.0) = timedwait(f, timeout; pollint=0.01) === :ok
    try
        FLIMApp.set_irfs!([FLIMApp.simulated_irf()])
        FLIMApp.warmup_lifetime_fitting!()

        FLIMApp.send_command!(ex, FLIMApp.ConnectCommand())
        @test await(() -> FLIMApp.loop_status(ex).state == FLIMApp.LOOP_READY)
        @test await(() -> FLIMCore.etat_moteur(engine) == :pret)

        rois = [square_roi(100.0, 100.0), square_roi(600.0, 300.0)]
        order = FLIMApp.roi_visit_order(rois)
        request = FLIMApp.ScanRequest(rois, order, true, -1000, 1000, -1000, 1000, 20, 3, 45, 5, (1024, 1024))
        session = mktempdir()
        FLIMCore.commander!(engine, FLIMCore.Clamp(rois = order, ordre = order, dossier = joinpath(session, "spc"),
                                                   scan_s = 0.045, pause_s = 0.005))
        @test await(() -> FLIMCore.etat_moteur(engine) == :clamp)
        FLIMApp.send_command!(ex, FLIMApp.StartCommand(request))
        out = FLIMApp.AnalysisOutput(ex; roi_order=order)
        worker = Threads.@spawn FLIMApp.start_realtime(out, running, engine.histogrammes; initial_guess=[3.0, 0.0, 5.0e-5])

        records = FLIMApp.FrameRecord[]
        @test await(() -> (FLIMApp.take_new!(records, ex.frames, length(records)); length(records) >= 8))
        # Each frame is the ROI the cards read on the routing lines, in
        # visiting order, with photons on both cards, at most one scan's worth.
        @test [r.roi_index for r in records[1:4]] == [order; order]
        @test [r.sample.pass for r in records] == 1:length(records) && all(r -> r.sample.complete, records)
        @test all(r -> 0 < r.sample.ch1.photons < 2e4 && r.sample.ch2.photons > 0, records)
        @test all(r -> r.sample.pass_end_s - r.sample.pass_start_s ≈ 0.045, records)
        # Simulated lifetimes: 1.8 + 0.25 code + 0.15 channel (± 0.2 over 15 s).
        @test all(r -> abs(r.sample.ch1.lifetime - (1.95 + 0.25 * r.roi_index)) < 0.35, records)
        @test count(r -> r.sample.ch2.lifetime > r.sample.ch1.lifetime, records) >= length(records) - 1

        running[] = false
        FLIMApp.request_stop!(ex)
        FLIMCore.commander!(engine, FLIMCore.Arret())
        @test await(() -> istaskdone(worker))
        @test await(() -> FLIMApp.loop_status(ex).state == FLIMApp.LOOP_READY && FLIMCore.etat_moteur(engine) == :pret)
        # The session holds each card's stream: Playback can replay it.
        @test FLIMApp.is_session_dir(session)
    finally
        running[] = false
        FLIMCore.arreter_moteur(engine)
        FLIMApp.send_command!(ex, FLIMApp.QuitCommand())
        timedwait(() -> istaskdone(loop), 10.0)
        for (c, v) in zip((FLIMApp.RUNTIME[], FLIMApp.RUNTIME_CH2[]), saved)
            c.irf, c.irf_bin_size, c.tcspc_window_size = v
        end
    end
end

@testset "Playback of a simulated session" begin
    # simulate_session writes a session in the format of a real one (written
    # by the SPC engine itself); Playback replays it through the same engine
    # and analysis, with the session's ROIs and IRF.
    saved = [(c.irf, c.irf_bin_size, c.tcspc_window_size) for c in (FLIMApp.RUNTIME[], FLIMApp.RUNTIME_CH2[])]
    dir = joinpath(mktempdir(), "session")
    try
        FLIMApp.simulate_session(dir; duration_s = 9, photons_per_s = 2e4)
        @test FLIMApp.is_session_dir(dir) && !FLIMApp.is_session_dir(mktempdir())
        @test sort(filter(f -> endswith(f, ".spc"), readdir(joinpath(dir, "spc")))) == ["3N0317.spc", "3N0318.spc"]
        @test isfile(joinpath(dir, "spc", "3N0317_acquisition.ini")) && isfile(joinpath(dir, "spc", "3N0317_parametres.ini"))
        s = FLIMApp.read_session(dir)
        @test length(s.rois) == 3 && sort(s.roi_order) == [1, 2, 3] && s.image_size == (1024, 512) && length(s.irfs) == 2
        info = s.info
        @test info["mode"] == "Simulation" && info["versions"]["flimcore"] == FLIMCore.VERSION_CORE
        @test [e["code_written"] for e in info["roi"]["list"]] == [15 - e["index"] for e in info["roi"]["list"]]
        @test info["daq"]["scan_samples"] == 9500 && info["spc"]["code_sans_roi"] == FLIMCore.CODE_SANS_ROI
        @test_throws ErrorException FLIMApp.simulate_session(dir)              # never over an existing session
        @test s.irf_info["channels"][2]["serial"] == "3N0318" && haskey(s.irf_info, "dcc")

        # The session's settings by default (layout, gains, protocol), and its pass timing.
        @test FLIMApp.session_pass_timing(s) == (1.0, 0.95, 1e-4)
        @test FLIMApp.playback_speed(0, s) == 1.0 && FLIMApp.playback_speed(5.0, s) == 5.0
        layout = FLIMApp.settings_from_dict(LayoutSettings, FLIMApp.settings_dict(LayoutSettings(binning = 7, smoothing = 3)))
        @test layout.binning == 7 && layout.smoothing == 3
        @test FLIMApp.settings_from_dict(ControllerSettings, Dict{String, Any}("P1" => "oops", "I1" => 2.0)).I1 == 2.0
        @test FLIMApp.session_analysis_settings(s).layout.binning == LayoutSettings().binning

        # The clamp series model: a first-order response on channel 1, channel 2 flat.
        clamp = FLIMApp.clamp_series_model(noise_ns = 0.0)
        @test clamp.lifetime_ns(1, 2, 30.0) == 2.5 && clamp.lifetime_ns(1, 1, 59.9) == 2.45
        @test clamp.lifetime_ns(1, 2, 70.0) ≈ 2.0 + 0.5 * exp(-1)                       # 10 s into the first clamp
        @test clamp.lifetime_ns(1, 2, 120.0) ≈ 2.0 + 0.5 * exp(-6)
        @test clamp.lifetime_ns(1, 2, 130.0) ≈ 2.5 - 0.5 * (1 - exp(-6)) * exp(-1)      # back toward the basal level
        @test clamp.lifetime_ns(1, 3, 600.0) ≈ 2.55 atol = 1e-3                          # after the series
        @test all(t -> clamp.lifetime_ns(2, 2, t) == 2.5, 0.0:7.0:540.0)                 # channel 2: not clamped
        noisy = FLIMApp.clamp_series_model()
        deviations = [noisy.lifetime_ns(1, 2, t) - clamp.lifetime_ns(1, 2, t) for t in 0.0:1.0:539.0]
        @test 0.04 < sqrt(sum(abs2, deviations) / length(deviations)) < 0.06 && noisy.lifetime_ns(1, 2, 70.0) == noisy.lifetime_ns(1, 2, 70.0)
        p = clamp.protocol
        # Clamped over 60–120, 180–240, 300–360 and 420–480 s.
        @test [FLIMApp.protocol_setpoint_at(p, t) for t in (30, 90, 150, 210, 450, 510)] ≈ [NaN, 2.0, NaN, 2.0, 2.0, NaN] nans = true
        @test isnan(FLIMApp.protocol_setpoint_at(p, 540.5)) && clamp.controller.ch1_on && clamp.controller.ch1_inv

        # What start_playback! sets up, without a window: the session's IRF,
        # its own replay engine, the worker ending once the replay is over
        # (playback_tick!, from the refresh tick, raises source_done).
        FLIMApp.set_irfs!(s.irfs; info = s.irf_info)
        app, app_run = AppState(true), AppRun(test_bench_config())
        app_run.playback.dir = dir
        @test FLIMApp.playback_start_refusal(app_run) == ""
        playback = app_run.playback
        engine = FLIMCore.demarrer_moteur(FLIMCore.Reglages(source = "rejeu"); source = FLIMCore.source_session(dir; vitesse = 0))
        playback.engine, playback.session = engine, s
        _, scan_s, sample_s = FLIMApp.session_pass_timing(s)               # the engine checks M3 − M0 against them
        FLIMCore.commander!(engine, FLIMCore.Clamp(rois = s.roi_order, ordre = s.roi_order, scan_s = scan_s, echantillon_s = sample_s))
        # With the session's settings, the GUI's edits don't reach the worker.
        app_run.run_mode, app_run.run_open, playback.session_settings = "Playback", true, true
        FLIMApp.publish_settings!(app_run.exchange, FLIMApp.session_analysis_settings(s))
        app.layout.binning = 9
        FLIMApp.publish_analysis_settings!(app, app_run)
        @test FLIMApp.current_settings(app_run.exchange).layout.binning == LayoutSettings().binning
        out = FLIMApp.AnalysisOutput(app_run.exchange; roi_order = s.roi_order, drive_outputs = false)
        worker = Threads.@spawn FLIMApp.start_realtime(out, app_run.running, engine.histogrammes;
                                                       initial_guess = [3.0, 0.0, 5.0e-5], source_done = playback.source_done)
        app_run.running[] = true
        @test timedwait(() -> (FLIMApp.playback_tick!(app_run); istaskdone(worker)), 120.0; pollint = 0.01) === :ok
        @test playback.source_done[] && playback.fin.mesure == :clamp && !playback.fin.erreur
        FLIMCore.arreter_moteur(engine)
        app_run.run_rois = s.rois
        info = FLIMApp.run_info(app, app_run, s.roi_order; mode = FLIMApp.PLAYBACK_SESSION_MODE, session = s,
                                settings = FLIMApp.session_analysis_settings(s))
        @test info["mode"] == "Playback" && info["playback"]["session"] == dir && info["roi"]["image_size"] == [1024, 512]
        @test info["playback"]["settings"] == "session" && startswith(info["pi_outputs"], "simulated")
        @test !isempty(sprint(io -> FLIMApp.TOML.print(io, info; sorted = true)))
        rows = published(app_run.exchange)
        @test length(rows.pass) == 9 && rows.roi_index == repeat(s.roi_order, 3) && all(rows.complete)
        @test all(isnan, FLIMApp.command_values(app_run.exchange, s.roi_order[1]))      # simulated PI: no output
        @test all(k -> abs(rows.lifetime_ch1[k] - (1.95 + 0.25 * rows.roi_index[k])) < 0.35, 1:9)
    finally
        for (c, v) in zip((FLIMApp.RUNTIME[], FLIMApp.RUNTIME_CH2[]), saved)
            c.irf, c.irf_bin_size, c.tcspc_window_size = v
        end
    end
end

@testset "Realtime START checks" begin
    # What start_pressed checks and sends, without a window: refusals in
    # order (IRF, DAQ, SPC engine, 16 ROIs, offline), the Clamp command,
    # run.toml; Playback's refusals.
    ctx = FLIMApp.RUNTIME[]
    saved = (ctx.irf, ctx.irf_bin_size, ctx.tcspc_window_size)
    cfg = test_bench_config()
    app = AppState(true)
    app_run = AppRun(cfg)
    path = joinpath(mktempdir(), "spc.toml")
    FLIMCore.ecrire_reglages(path, FLIMCore.Reglages(source = "simulation", dossier = mktempdir(), seuil_cfd = 10.0))
    app_run.spc = FLIMApp.SpcView(path, app_run.exchange.journal)
    ex = app_run.exchange
    loop = Threads.@spawn FLIMApp.daq_loop(cfg, ex; hardware=FLIMApp.SimulatedHardware(cfg; realtime=false))
    tick() = FLIMApp.spc_tick!(app_run.spc, time_ns())
    await(f) = timedwait(() -> (tick(); f()), 60.0; pollint = 0.02) === :ok
    saved_info = FLIMApp.IRF_INFO[]
    try
        ctx.irf = nothing
        @test occursin("IRF", FLIMApp.realtime_start_refusal(app, app_run))
        ctx.irf, ctx.irf_bin_size, ctx.tcspc_window_size = [0.0 1.0; 0.05 0.0], 0.05, 12.5
        # An IRF without the record of its settings, or taken with others: refused.
        FLIMApp.IRF_INFO[] = Dict{String, Any}()
        @test occursin("no record", FLIMApp.realtime_start_refusal(app, app_run))
        settings = app_run.spc.settings
        other = irf_info_for(settings)
        other["channels"][1]["settings"]["tac_gain"] = settings.spc["tac_gain"] + 1
        FLIMApp.IRF_INFO[] = other
        @test occursin("channel 1: tac_gain", FLIMApp.realtime_start_refusal(app, app_run))
        other = irf_info_for(settings)
        other["dcc"]["gain_c1_pourcent"] = 70.0
        FLIMApp.IRF_INFO[] = other
        @test occursin("detector: gain_c1_pourcent", FLIMApp.realtime_start_refusal(app, app_run))
        FLIMApp.IRF_INFO[] = irf_info_for(settings)
        @test occursin("DAQ not ready", FLIMApp.realtime_start_refusal(app, app_run))
        # The recording folder's free space, for the status line and the check.
        free, seconds, text = FLIMApp.recording_space(settings)
        @test free > 0 && seconds ≈ free / (4e6 * length(settings.series)) && occursin("GB free", text)
        @test FLIMApp.sessions_root(settings) == joinpath(FLIMCore.dossier_spc(settings), "sessions")
        FLIMApp.send_command!(ex, FLIMApp.ConnectCommand())
        @test await(() -> FLIMApp.loop_status(ex).state == FLIMApp.LOOP_READY)
        @test occursin("SPC engine not running", FLIMApp.realtime_start_refusal(app, app_run))
        FLIMApp.spc_connect!(app_run.spc)
        @test await(() -> FLIMApp.spc_state(app_run.spc) == :pret)
        @test FLIMApp.realtime_start_refusal(app, app_run) == ""

        app.roi.active = true
        app_run.rois[] = [square_roi(10.0 * k, 10.0 * k) for k in 1:16]
        @test occursin("16 ROIs", FLIMApp.realtime_start_refusal(app, app_run))
        app_run.rois[] = [square_roi(100.0, 100.0), square_roi(600.0, 300.0), square_roi(300.0, 800.0)]
        @test FLIMApp.realtime_start_refusal(app, app_run) == ""

        order = FLIMApp.roi_visit_order(app_run.rois[])
        dir = FLIMApp.new_run_dir(FLIMApp.journal_root(cfg), time())
        c = FLIMApp.clamp_command(app, app_run, order, dir)
        @test c.rois == order && c.ordre == order && c.dossier == joinpath(dir, "spc")
        @test c.scan_s == app.protocol.scan_time / 1000 && c.pause_s == app.protocol.shift_time / 1000
        @test c.echantillon_s == 1 / cfg.sample_rate_hz                         # M3 − M0 checked by the engine
        @test isempty(FLIMApp.clamp_command(app, app_run, Int[], dir).rois)      # ROI off: the no-ROI code
        @test FLIMApp.scan_request(app, app_run, order).invert_routing == app_run.spc.settings.inverser_routage
        app_run.run_rois = copy(app_run.rois[])
        info = FLIMApp.run_info(app, app_run, order)
        @test info["mode"] == "Realtime" && info["spc"]["source"] == "simulation" && info["roi"]["visit_order"] == order
        @test [e["code_read"] for e in info["roi"]["list"]] == [1, 2, 3] && info["roi"]["image_size"] == [1024, 1024]
        @test info["layout"]["binning"] == app.layout.binning && info["controller"]["P1"] == app.controller.P1
        @test info["daq"]["scan_samples"] == 9500 && info["spc"]["spc_module"]["tac_gain"] == settings.spc["tac_gain"]
        @test all(e -> e["fit_channel"] == "", info["roi"]["list"])
        @test haskey(info["versions"], "git_commit") && info["versions"]["spclite"] == FLIMCore.SPCLite.VERSION_LITE
        @test FLIMApp.TOML.parse(sprint(io -> FLIMApp.TOML.print(io, info; sorted = true)))["roi"]["visit_order"] == order

        # Offline (no driver): Realtime refused with the banner's reason.
        app_run.offline = "OFFLINE (test)"
        @test FLIMApp.realtime_start_refusal(app, app_run) == "OFFLINE (test)"
        app_run.offline = ""

        # Playback needs a session.
        @test occursin("Pick a session", FLIMApp.playback_start_refusal(app_run))
        app_run.playback.dir = mktempdir()
        @test occursin("Not a session", FLIMApp.playback_start_refusal(app_run))
    finally
        ctx.irf, ctx.irf_bin_size, ctx.tcspc_window_size = saved
        FLIMApp.IRF_INFO[] = saved_info
        FLIMApp.spc_disconnect!(app_run.spc)
        app_run.spc.stopping === nothing || timedwait(() -> istaskdone(app_run.spc.stopping), 10.0)
        FLIMApp.send_command!(ex, FLIMApp.QuitCommand())
        timedwait(() -> istaskdone(loop), 10.0)
    end
end

@testset "IRF from a Single .sdt (two channels)" begin
    # A Single measurement as SPCM saves it: one uncompressed decay block per
    # card, 4096 channels over a 50 ns TAC with gain 4 (12.5 ns); each block
    # with its card's measurement description (serial number, CFD, SYNC).
    adc_re = 4096
    curves = [[k == 200 ? 1000 : 3 for k in 1:adc_re], [k == 216 ? 500 : 2 for k in 1:adc_re]]
    serials = ["3N0318", "3N0317"]                    # in the file: channel 2's card first
    meas_len, header_len, block_header_len = 220, 42, 22
    data_len = 2 * adc_re
    io = IOBuffer()
    first_block = header_len + 2 * meas_len
    write(io, Int16(0), Int32(0), Int16(0), Int32(0), UInt16(0))                 # revision, info, setup
    write(io, Int32(first_block), Int16(2), UInt32(data_len))                     # data blocks
    write(io, Int32(header_len), Int16(2), Int16(meas_len))                       # measurement descriptions
    write(io, UInt16(0x5555), UInt32(0), UInt16(0), UInt16(0))
    put!(buffer, offset, value) = (buffer[offset + 1:offset + sizeof(value)] = reinterpret(UInt8, [value]))
    for serial in serials
        meas = zeros(UInt8, meas_len)
        meas[21:20 + length(serial)] = codeunits(serial)                          # mod_ser_no (offset 20)
        put!(meas, 38, Float32(-50))                                              # cfd_ll
        put!(meas, 64, Float32(50e-9))                                            # tac_r (s)
        put!(meas, 68, Int16(4))                                                  # tac_g
        put!(meas, 82, Int16(adc_re))                                             # adc_re
        put!(meas, 133, Float32(-60))                                             # syn_th
        write(io, meas)
    end
    for (b, curve) in enumerate(curves)
        start = first_block + (b - 1) * (block_header_len + data_len)
        next = b == 1 ? start + block_header_len + data_len : 0
        # Old-format block header; block_type 0x0001: measured data, a decay, UInt16, uncompressed.
        write(io, Int16(b - 1), Int32(start + block_header_len), Int32(next), UInt16(0x0001), Int16(b - 1), UInt32(0), UInt32(data_len))
        foreach(v -> write(io, UInt16(v)), curve)
    end
    path = joinpath(mktempdir(), "irf_single.sdt")
    write(path, take!(io))

    in_file, _ = FLIMApp.read_sdt_irf(path)                                     # no series: file order
    @test argmax(in_file[1][:, 2]) == 13 && argmax(in_file[2][:, 2]) == 14
    irfs, channels = FLIMApp.read_sdt_irf(path; series = ["3N0317", "3N0318"])  # by serial: channel 1 first
    @test [c["serial"] for c in channels] == ["3N0317", "3N0318"]
    @test length(irfs) == 2 && all(irf -> size(irf) == (256, 2), irfs)
    @test irfs[1][2, 1] ≈ 12.5 / 256 && irfs[1][1, 1] == 0.0
    @test argmax(irfs[2][:, 2]) == 13 && irfs[2][13, 2] == 1000 + 15 * 3 - 16 * 3     # median removed per channel
    @test argmax(irfs[1][:, 2]) == 14 && irfs[1][14, 2] == 500 + 15 * 2 - 16 * 2
    @test FLIMApp.compute_irf_bin_size(irfs[1]) ≈ 12.5 / 256
    settings = channels[1]["settings"]
    @test settings["tac_range"] ≈ 50 && settings["tac_gain"] == 4 && settings["cfd_limit_low"] == -50 && settings["sync_threshold"] == -60

    # Taken with the settings the cards measure with, or refused (and why).
    spc(; kw...) = FLIMCore.Reglages(; source = "cartes", series = ["3N0317", "3N0318"], spc = Dict{String, Any}("tac_range" => 50.0, "tac_gain" => 4, "cfd_limit_low" => -49.5,
                                                               "sync_threshold" => -60.0),
                                     dcc = Dict{String, Any}("gain_c1_pourcent" => 82.0), kw...)
    info = Dict{String, Any}("channels" => channels, "dcc" => Dict{String, Any}("gain_c1_pourcent" => 82.0))
    @test isempty(FLIMApp.irf_mismatches(info, spc()))                          # -49.5 vs -50: the DLL's rounding
    gain2 = spc(); gain2.spc["tac_gain"] = 2
    @test length(FLIMApp.irf_mismatches(info, gain2)) == 2                      # both channels
    @test length(FLIMApp.irf_mismatches(info, gain2; applied = Dict(1 => Dict("tac_gain" => 4.0)))) == 1   # read back: 4
    cfd = spc(); cfd.spc["cfd_limit_low"] = -80.0
    @test any(m -> occursin("cfd_limit_low", m), FLIMApp.irf_mismatches(info, cfd))
    @test any(m -> occursin("is card 3N0399", m), FLIMApp.irf_mismatches(info, spc(series = ["3N0399", "3N0318"])))
    detector = spc(); detector.dcc["gain_c1_pourcent"] = 85.0
    @test only(FLIMApp.irf_mismatches(info, detector)) == "detector: gain_c1_pourcent = 82.0 for the IRF, 85.0 now ([dcc] in config/spc.toml)"
    added = spc(); added.dcc["gain_c3_pourcent"] = 82.0
    @test any(m -> occursin("gain_c3_pourcent wasn't declared", m), FLIMApp.irf_mismatches(info, added))
    @test occursin("no record", only(FLIMApp.irf_mismatches(Dict{String, Any}(), spc())))

    # The record is kept next to the CSV.
    record = FLIMApp.write_irf_info(FLIMApp.irf_info_path(joinpath(mktempdir(), "irf.csv")), info)
    @test endswith(record, "irf.toml") && isempty(FLIMApp.irf_mismatches(FLIMApp.read_irf_info(record), spc()))

    # Kept as CSV (one column per channel), read back identical.
    csv = FLIMApp.write_irf_csv(joinpath(mktempdir(), "irf.csv"), irfs)
    @test readline(csv) == "time_ns,ch1,ch2" && FLIMApp.read_irf_csv(csv) == irfs

    # Each channel fits against its own IRF; a single-channel IRF serves both.
    saved = [(c.irf, c.irf_bin_size, c.tcspc_window_size) for c in (FLIMApp.RUNTIME[], FLIMApp.RUNTIME_CH2[])]
    saved_info = FLIMApp.IRF_INFO[]
    try
        FLIMApp.set_irfs!(irfs; info)
        @test FLIMApp.loaded_irf_info() == info
        @test FLIMApp.channel_fit_context(1) === FLIMApp.RUNTIME[] && FLIMApp.channel_fit_context(2) === FLIMApp.RUNTIME_CH2[]
        @test FLIMApp.with_fit_context(() -> FLIMApp.fit_context().irf, FLIMApp.channel_fit_context(2)) == irfs[2]
        @test FLIMApp.fit_context() === FLIMApp.RUNTIME[]
        FLIMApp.set_irfs!(irfs[1:1])
        @test FLIMApp.channel_fit_context(2) === FLIMApp.RUNTIME[] && length(FLIMApp.loaded_irfs()) == 1
    finally
        FLIMApp.IRF_INFO[] = saved_info
        for (c, v) in zip((FLIMApp.RUNTIME[], FLIMApp.RUNTIME_CH2[]), saved)
            c.irf, c.irf_bin_size, c.tcspc_window_size = v
        end
    end
    @test_throws Exception FLIMApp.read_sdt_irf(joinpath(mktempdir(), "missing.sdt"))
end

@testset "IRF from a Single of the SPC window (SPC-QC-104)" begin
    # A Single through the QC-104 (a recorded raw stream standing in for the card): one CSV per input,
    # resampled onto [qc] fenetre_ns like the Realtime decays, with the settings read back next to it.
    e = FLIMCore.EncodeurQC()
    for t in 1:60_000
        FLIMCore.photon_qc!(e, 40t, 250 + (t % 7) * 3 + (t % 2) * 40; entree = 1 + t % 2)     # a narrow peak on each input
    end
    spc = FLIMCore.Reglages(dossier = mktempdir(), seuil_cfd = 10.0)
    engine = FLIMCore.demarrer_moteur(spc; source = FLIMCore.SourceQC(FLIMCore.QCRejeu(e.mots)))
    @test timedwait(() -> FLIMCore.etat_moteur(engine) == :pret, 30.0) === :ok
    FLIMCore.commander!(engine, FLIMCore.Single(0.05, 1))
    fin = FLIMCore.attendre_fin(engine, :single; delai_s = 30, io = nothing)
    FLIMCore.arreter_moteur(engine)
    @test !fin.erreur
    csv = only(filter(f -> endswith(f, "_module1.csv"), fin.fichiers))         # either channel's CSV finds the other
    irfs, channels = FLIMApp.read_single_irf(csv; series = spc.series)
    @test [c["serial"] for c in channels] == ["3T0089/IN1", "3T0089/IN2"] && length(irfs) == 2
    @test all(irf -> size(irf) == (256, 2) && isapprox(irf[2, 1], 12.5 / 256; rtol = 1e-4) && sum(irf[:, 2]) > 0, irfs)
    @test argmax(irfs[2][:, 2]) > argmax(irfs[1][:, 2])                        # IN2's peak 40 TDC channels later
    @test all(c -> isapprox(c["settings"]["fenetre_ns"], 12.5; atol = 1e-3) && c["settings"]["cfd_limit_low"] == spc.qc_seuil_mV[1], channels)
    info = Dict{String, Any}("channels" => channels, "dcc" => Dict{String, Any}(spc.dcc))
    @test isempty(FLIMApp.irf_mismatches(info, spc))
    other = deepcopy(spc); other.qc_seuil_mV[2] = -80.0                       # IN2's threshold: cfd_limit_high
    @test any(m -> occursin("cfd_limit_high", m), FLIMApp.irf_mismatches(info, other))
    window = deepcopy(spc); window.qc_fenetre_ns = 16.0                      # another time axis
    @test any(m -> occursin("fenetre_ns", m), FLIMApp.irf_mismatches(info, window))
    swapped = deepcopy(spc); swapped.series = ["3T0089/IN2", "3T0089/IN1"]
    @test any(m -> occursin("channel 1 is card 3T0089/IN2", m), FLIMApp.irf_mismatches(info, swapped))
    @test FLIMApp.alert_problem_id("QC-104 : 3 photon(s) au-delà de [qc] fenetre_ns (12.5 ns) jetés") == "SPC-10"
    @test FLIMApp.alert_problem_id("module 1 (3T0089/IN2) : la carte affiche 2e5 /s … [qc] taux de config/spc.toml à corriger") == "SPC-09"
    # SPCM's Singles of the QC-104 (.sdt, 256 points of 64 ps on 16.385 ns), one detector per file as taken
    # at the bench: each channel takes its input's curve, from the picked file or the one named for its
    # channel, spread onto the 12.5 ns window; recorded with the settings SPCM had (its setup text included).
    sdt = joinpath(@__DIR__, "data", "qc104", "irf_16x_750nm_ch1.sdt")
    bench = FLIMCore.lire_reglages(joinpath(@__DIR__, "..", "config", "spc.toml"))
    irfs, channels = FLIMApp.read_sdt_irf_qc(sdt, bench)
    @test [c["serial"] for c in channels] == ["3T0089/IN1", "3T0089/IN2"]
    @test [c["file"] for c in channels] == ["irf_16x_750nm_ch1.sdt", "irf_16x_750nm_ch2.sdt"]
    @test all(irf -> size(irf) == (256, 2) && irf[2, 1] ≈ 12.5 / 256, irfs)
    @test [irf[argmax(irf[:, 2]), 1] for irf in irfs] ≈ [37, 43] .* (12.5 / 256)       # 1.81 and 2.10 ns
    @test channels[2]["settings"]["tdc_offset2"] == 1.536 && isapprox(channels[1]["settings"]["sync_holdoff"], 12.85; atol = 1e-3)
    info = Dict{String, Any}("channels" => channels, "dcc" => Dict{String, Any}(bench.dcc))
    @test isempty(FLIMApp.irf_mismatches(info, bench))                         # config/spc.toml: the SPCM values
    offsets = deepcopy(bench); offsets.qc_decalage_ns = zeros(4)
    @test any(m -> occursin("tdc_offset2", m), FLIMApp.irf_mismatches(info, offsets))
    # Loading an IRF takes its settings over ([qc]): what differs becomes the IRF's, the rest is kept.
    other = deepcopy(bench); other.qc_decalage_ns = zeros(4); other.qc_seuil_mV[2] = -50.0; other.qc_photon_unique = true
    taken, changes = FLIMApp.irf_settings_changes(other, channels)
    @test taken.qc_decalage_ns == [0.512, 1.536, 0.0, 0.0] && taken.qc_seuil_mV[2] == -139.216 && taken.qc_photon_unique
    @test sort([first(split(c, ":")) for c in changes]) == ["cfd_limit_high", "tdc_offset1", "tdc_offset2"]
    @test isempty(FLIMApp.irf_mismatches(info, taken)) && other.qc_decalage_ns == zeros(4)        # `other` untouched
    @test isempty(last(FLIMApp.irf_settings_changes(bench, channels)))                            # already the IRF's
    elsewhere = deepcopy(other); elsewhere.series = ["3T0089/IN2", "3T0089/IN1"]
    @test any(m -> occursin("is card 3T0089/IN2", m), FLIMApp.irf_mismatches(info, first(FLIMApp.irf_settings_changes(elsewhere, channels))))
    # The all-in-one file: both channels, their serials and settings, the [dcc]; read back as imported.
    bundle = FLIMApp.write_irf_bundle(joinpath(mktempdir(), "irf", "20261007_150000_irf.toml"), irfs, info)
    @test FLIMApp.is_irf_bundle(bundle) && !FLIMApp.is_irf_bundle(sdt)
    irfs2, channels2 = FLIMApp.read_irf_file(bundle, bench)
    @test irfs2 == irfs && [c["serial"] for c in channels2] == ["3T0089/IN1", "3T0089/IN2"]
    @test channels2[2]["settings"] == channels[2]["settings"]
    @test isempty(FLIMApp.irf_mismatches(Dict{String, Any}("channels" => channels2, "dcc" => Dict{String, Any}(bench.dcc)), bench))
    @test last(FLIMApp.irf_settings_changes(other, channels2)) == changes                # its settings, taken over as well
    @test_throws ErrorException FLIMApp.read_irf_bundle(FLIMApp.irf_info_path(joinpath(mktempdir(), "x.csv")) |> p -> (write(p, "a = 1"); p))
    disagree = deepcopy(channels); disagree[2]["settings"]["tdc_offset2"] = 3.072
    @test_throws ErrorException FLIMApp.irf_settings_changes(bench, disagree)
    @test FLIMApp.rebin_counts([4.0, 6.0, 8.0], 1.0, 1.5, 3) == [7.0, 11.0, 0.0]
    @test FLIMApp.sdt_setup_value("#SP [SP_TDC_OF2,F,1.536]", "TDC_OF2") == 1.536 && isnan(FLIMApp.sdt_setup_value("", "X"))
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

        # 1x3 SPC image (photons, summed arrival times at channel centers):
        # pixel 1 is a bright, late point-mass decay; pixel 2 an equally
        # bright but earlier one; pixel 3 is placed like pixel 1 but too dim
        # overall to trust.
        intensity = [1000.0 1000.0 5.0]
        sum_t = [1000 * 49.5 * bin 1000 * 19.5 * bin 5 * 49.5 * bin]

        result = FLIMApp.pixel_lifetime_map(intensity, sum_t; min_photons=50.0)
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
        @test_throws ErrorException FLIMApp.pixel_lifetime_map(intensity, sum_t)
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

include("test_flimcore.jl")

@testset "SPC window state, without a window" begin
    # The GUI side of the engine (gui/spc_view.jl), on the simulated
    # scanner: settings in a temporary file, never config/spc.toml.
    path = joinpath(mktempdir(), "spc.toml")
    FLIMCore.ecrire_reglages(path, FLIMCore.Reglages(source = "simulation", vitesse = 4.0, dossier = mktempdir(),
                                                     seuil_cfd = 10.0, trames_par_image = 0))
    queue = FLIMApp.JournalQueue(1000)
    view = FLIMApp.SpcView(path, queue)
    @test sort(collect(keys(view.cards))) == [0, 1] && view.status[] == "SPC: not connected"
    view.window_open = true                     # publish images as if the window were open
    tick() = FLIMApp.spc_tick!(view, time_ns())
    await(f) = timedwait(() -> (tick(); f()), 60.0; pollint = 0.02) === :ok

    FLIMApp.spc_connect!(view)
    @test await(() -> FLIMApp.spc_state(view) == :pret && view.check !== nothing)
    @test view.check.ok && view.check.source == "simulation"

    # UNLOCK only acts on a second click.
    FLIMApp.spc_unlock_pressed!(view)
    @test view.unlock_armed_until > time()
    FLIMApp.spc_unlock_pressed!(view)
    @test await(() -> any(a -> occursin("aucun module verrouillé", a.texte), view.alerts))

    FLIMApp.spc_toggle_imaging!(view)
    @test await(() -> FLIMApp.spc_state(view) == :imagerie)
    # x = pixel, y = line. lignes_par_image = 0: the simulated scanner's 576 lines per frame aren't
    # one of the bench's settings (reglages_scanner), so 576 − decalage_lignes (32) lines.
    @test await(() -> all(c -> size(c.intensity[]) == (1024, 544), values(view.cards)))
    card = view.cards[0]
    @test await(() -> count(isfinite, card.mean_time[]) > 100)      # running sum: enough photons per block
    @test card.intensity_range[][2] >= 1 && 0 < card.time_range[][1] < card.time_range[][2] < 12.5
    @test length(card.decay[]) == 256 && any(p -> p[2] > 1, card.decay[])
    @test await(() -> occursin("SPC: imaging", view.status[]) && occursin("card 1: CFD", view.status[]))
    @test await(() -> !isempty(card.rates[]))
    # The counts bar: each channel's card count rate, measuring or not; 1 (the bottom) once stale.
    @test FLIMApp.spc_channel_rates(view) == (view.cards[0].last_rates.cfd, view.cards[1].last_rates.cfd)
    @test all(>(1.0), FLIMApp.spc_channel_rates(view)) && FLIMApp.spc_channel_rates(view; max_age_s = -1) == (1.0, 1.0)

    # IRF: Singles on both channels at once, summed until each maximum passes the target; at its end
    # the sum is to be imported (`irf_acquisition_csv`: its CSV), a stopped one isn't.
    FLIMApp.spc_toggle_imaging!(view)           # STOP the imaging first
    @test await(() -> FLIMApp.spc_state(view) == :pret)
    view.settings.irf_temps_s, view.settings.irf_maximum = 0.05, 500
    FLIMApp.spc_toggle_irf!(view)
    @test view.irf_acquisition
    @test await(() -> view.irf_fin !== nothing)
    @test !view.irf_acquisition && sort(collect(keys(view.irf_sums))) == [0, 1]
    @test all(s -> maximum(s) > 500, values(view.irf_sums))
    csv = FLIMApp.irf_acquisition_csv(view.irf_fin)
    @test csv !== nothing && endswith(csv, ".csv")
    stopped = FLIMCore.Fin(:single, "arrêtée", false, [csv], time())
    @test FLIMApp.irf_acquisition_csv(stopped) === nothing
    status = (info_label = (text = FLIMApp.Observable(""),),)
    @test !FLIMApp.finish_irf_acquisition!(nothing, status, stopped) && occursin("IRF unchanged", status.info_label.text[])
    view.irf_fin = nothing
    view.last_fin = nothing                     # the imaging's own end is awaited below, not the IRF's
    FLIMApp.spc_toggle_imaging!(view)           # imaging again, as before
    @test await(() -> FLIMApp.spc_state(view) == :imagerie)

    # Settings edited in the window are written back; invalid ones refused. QC-104 only: each
    # channel's timing offset (its input's [qc] decalage_ns).
    @test !FLIMApp.spc_edit_offset!(view, 1, 1.024)                        # the simulation has no QC-104 input
    qc_path = joinpath(mktempdir(), "spc.toml")
    FLIMCore.ecrire_reglages(qc_path, FLIMCore.Reglages(dossier = mktempdir()))
    qc_view = FLIMApp.SpcView(qc_path, nothing)
    @test FLIMApp.spc_edit_offset!(qc_view, 2, 2.048) && FLIMCore.lire_reglages(qc_path).qc_decalage_ns[2] == 2.048
    @test !FLIMApp.spc_edit_offset!(qc_view, 1, 40.0) && FLIMCore.lire_reglages(qc_path).qc_decalage_ns[1] == 0.512
    FLIMApp.spc_adopt_settings!(qc_view, FLIMCore.Reglages(dossier = mktempdir(), qc_decalage_ns = [1.024, 0.0, 0.0, 0.0]))
    @test FLIMCore.lire_reglages(qc_path).qc_decalage_ns[1] == 1.024 && qc_view.settings.qc_decalage_ns[1] == 1.024
    @test FLIMApp.spc_edit_setting!(view, :binning_temps, 8)
    @test FLIMCore.lire_reglages(path).binning_temps == 8
    @test !FLIMApp.spc_edit_setting!(view, :binning_temps, 0) && view.settings.binning_temps == 8
    tick()
    @test occursin("setting refused", view.status[])
    @test FLIMApp.spc_edit_setting!(view, :binning_temps, 4)          # a good value clears the message
    tick()
    @test !occursin("refused", view.status[])

    FLIMApp.spc_toggle_imaging!(view)           # STOP
    @test await(() -> FLIMApp.spc_state(view) == :pret && view.last_fin !== nothing)
    @test !view.last_fin.erreur && any(f -> endswith(f, "module0.spc"), view.last_fin.fichiers)

    # The ROI popup's Image button: 100 frames per card, with the raw stream.
    @test FLIMApp.spc_request_roi_image!(view) == ""
    @test await(() -> view.roi_image[] !== nothing)
    parts = view.roi_image[]
    @test sort(collect(keys(parts))) == [0, 1]
    # The popup's channel menu: channel i is the card with the i-th serial of
    # [verification] series, the sum both.
    @test only(FLIMApp.roi_image_parts(parts, "Channel 1")).canal == 1 && only(FLIMApp.roi_image_parts(parts, "Channel 2")).canal == 2
    image = FLIMApp.RoiImage(FLIMApp.roi_image_parts(parts, "Channel 1"), 1)
    @test image.frames >= FLIMApp.ROI_IMAGE_FRAMES && size(image.intensity) == (1024, 544) && !isempty(image.streams[1].mots)
    disk = [(x, y) for x in 480:540 for y in 230:280]                 # inside the simulated disk
    h = only(FLIMApp.roi_histograms(image, [disk]))
    @test length(h) == 256 && sum(h) == sum(image.intensity[x, y] for (x, y) in disk) > 0
    both = FLIMApp.RoiImage(FLIMApp.roi_image_parts(parts, "Sum"), 0)
    @test both.cards == [0, 1] && both.intensity == image.intensity + FLIMApp.RoiImage(parts[1]).intensity
    @test sum(only(FLIMApp.roi_histograms(both, [disk]))) == sum(both.intensity[x, y] for (x, y) in disk)

    FLIMApp.spc_disconnect!(view)
    @test await(() -> view.engine === nothing)
    @test timedwait(() -> istaskdone(view.stopping), 10.0) === :ok && fetch(view.stopping)
    @test view.status[] == "SPC: not connected"
    entries = FLIMApp.drain_journal!(FLIMApp.JournalEntry[], queue)
    @test any(e -> e isa FLIMApp.JournalEvent && occursin("SPC imaging ended", e.message), entries)
end

end # @testset FLIMApp
