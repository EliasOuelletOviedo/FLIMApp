# A simulated clamp series, in the format of a real Realtime acquisition,
# to try Playback without the bench:
#
#     julia --project -t 4,1 scripts/simulate_clamp_session.jl [folder]
#
# Three ROIs, basal 2.45 / 2.50 / 2.55 ns. Channel 1: 1 min basal, then
# 4 × (1 min clamped at 2.0 ns + 1 min return), a first-order response
# (τ = 10 s) with 0.05 ns of white noise per pass; channel 2: not clamped,
# constant at the basal level. The protocol and channel 1's PI gains are
# recorded with it — see `clamp_series_model` (src/analysis/session.jl).
# Default folder: <recording folder>/sessions/simulation_clamp_<date>, next
# to the other simulations. Then in the app: mode "Playback: session", the
# session button -> that folder, START.
using FLIMApp
using Dates

cfg = FLIMApp.load_bench_config(FLIMApp.default_bench_config_path())
spc = FLIMApp.load_spc_settings(FLIMApp.spc_settings_path(cfg))
folder = length(ARGS) >= 1 ? ARGS[1] :
         joinpath(FLIMApp.sessions_root(spc), "simulation_clamp_" * Dates.format(Dates.now(), dateformat"yyyy-mm-dd_HHMMSS"))

model = FLIMApp.clamp_series_model()
duration_s = 60 + 4 * (60 + 60)
FLIMApp.simulate_session(folder; duration_s, lifetime_ns = model.lifetime_ns, protocol = model.protocol,
                         controller = model.controller, description = model.description)
println("Simulated clamp series ($(duration_s) s): ", folder)
println("  ", model.description)
for (root, _, files) in walkdir(folder), f in sort(files)
    path = joinpath(root, f)
    println("  ", rpad(relpath(path, folder), 32), lpad(filesize(path), 12), " bytes")
end
