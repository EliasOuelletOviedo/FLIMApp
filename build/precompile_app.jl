# Precompile workload executed by PackageCompiler during the app build
# (see create_app.jl's `precompile_execution_file`). Everything traced here
# is compiled into the app's sysimage, so the shipped binary skips JIT
# compilation for these paths at startup.
#
# Deliberately headless: no GLMakie window is opened, because the build may
# run on a machine/session without a display. GLMakie's own precompile
# workload already covers its rendering paths; this file warms TIFFApp's
# fitting/state code on top of that.

using TIFFApp

# --- state persistence round-trip -------------------------------------------
let tmp = joinpath(mktempdir(), "state.jls")
    app = AppState(true)
    save_state(app; path=tmp)
    load_state(tmp)
end

# --- lifetime fitting on a synthetic IRF/decay ------------------------------
# Ratio reduction and the Hill calibration: cheap to run, and precompiling
# them here keeps the first START from paying their JIT cost. There is no
# equivalent of the FLIM build's fit warmup — the MLE reconvolution solver it
# warmed up no longer exists.
let means = [120.0, 60.0, 30.0]
    TIFFApp.ratio_from_means(means, "C1/C2", [1, 2, 3])
    TIFFApp.hill_ratio_to_concentration(1.2)
    TIFFApp.hill_concentration_to_ratio(46.4)
end

# Image binning and the masked reduction, on a frame small enough to stay fast.
let buffer = TIFFApp.ImageFrameBuffer{UInt8}(8, 8, 4)
    pixels = fill(UInt8(7), 64)
    window = TIFFApp.push_frame!(buffer, pixels, 2)
    mask = TIFFApp.whole_image_mask(8, 8)
    TIFFApp.region_mean(vec(buffer.sum_image), mask, window)
end

# Channel grouping arithmetic, both numbering conventions.
let
    TIFFApp.instance_index_for(5, 2, :global)
    TIFFApp.instance_index_for(5, 2, :per_channel)
    TIFFApp.parse_tiff_sequence_number("sample-C1-T042.tif")
end

let protocol = TIFFApp.ProtocolSettings(
        active=true,
        repeats=2,
        delay=1,
        times=vcat([10.0, 20.0], fill(NaN, TIFFApp.PROTOCOL_STEP_COUNT - 2)),
        setpoints=vcat([3.5, 4.0], fill(NaN, TIFFApp.PROTOCOL_STEP_COUNT - 2))
    )
    TIFFApp.protocol_setpoint_at(protocol, 15.0)
    TIFFApp.normalize_protocol_config(protocol)
end
