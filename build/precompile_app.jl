# Precompile workload executed by PackageCompiler during the app build
# (see create_app.jl's `precompile_execution_file`). Everything traced here
# is compiled into the app's sysimage, so the shipped binary skips JIT
# compilation for these paths at startup.
#
# Deliberately headless: no GLMakie window is opened, because the build may
# run on a machine/session without a display. GLMakie's own precompile
# workload already covers its rendering paths; this file warms FLIMApp's
# fitting/state code on top of that.

using FLIMApp

# --- state persistence round-trip -------------------------------------------
let tmp = joinpath(mktempdir(), "state.jls")
    app = AppState(true)
    save_state(app; path=tmp)
    load_state(tmp)
end

# --- lifetime fitting on a synthetic IRF/decay ------------------------------
let ctx = FLIMApp.RUNTIME[]
    n = FLIMApp.DEFAULT_HISTOGRAM_RESOLUTION
    bin = FLIMApp.LASER_PULSE_PERIOD / n

    irf = zeros(n, 2)
    irf[:, 1] = (0:(n - 1)) .* bin
    for i in 1:n
        irf[i, 2] = exp(-((i - 10)^2) / 8)
    end

    ctx.irf = irf
    ctx.irf_bin_size = bin
    ctx.tcspc_window_size = round(irf[end, 1] + irf[2, 1], sigdigits=4)

    # Warms the 1- and 2-lifetime fit paths (the same warmup run_app uses).
    FLIMApp.warmup_lifetime_fitting!()

    # Leave the runtime clean so the shipped app starts from "no IRF loaded".
    ctx.irf = nothing
    ctx.irf_bin_size = nothing
    ctx.tcspc_window_size = nothing
end

# --- protocol schedule math ---------------------------------------------------
let protocol = FLIMApp.ProtocolSettings(
        active=true,
        repeats=2,
        delay=1,
        times=vcat([10.0, 20.0], fill(NaN, FLIMApp.PROTOCOL_STEP_COUNT - 2)),
        setpoints=vcat([3.5, 4.0], fill(NaN, FLIMApp.PROTOCOL_STEP_COUNT - 2))
    )
    FLIMApp.protocol_setpoint_at_timestamp(protocol, 15.0)
    FLIMApp.normalize_protocol_config(protocol)
end
