# A simulated session, in the format of a real Realtime acquisition, to try
# Playback without the bench (a laptop works):
#
#     julia --project -t 4,1 scripts/simulate_session.jl [folder] [duration_s]
#
# Default folder: <recording folder>/sessions/simulation_<date>, where the
# app writes its sessions ([enregistrement] dossier of config/spc.toml,
# ~/FLIMApp_spc if empty); default duration 60 s. Three ROIs on a
# 1024 × 512 image, two cards (3N0317 = channel 1, 3N0318 = channel 2),
# 0.95 s scans and 0.05 s pauses — see `simulate_session`
# (src/analysis/session.jl). Then in the app: mode "Playback: session", the
# session button -> that folder, START.
using FLIMApp
using Dates

cfg = FLIMApp.load_bench_config(FLIMApp.default_bench_config_path())
spc = FLIMApp.load_spc_settings(FLIMApp.spc_settings_path(cfg))
folder = length(ARGS) >= 1 ? ARGS[1] :
         joinpath(FLIMApp.sessions_root(spc), "simulation_" * Dates.format(Dates.now(), dateformat"yyyy-mm-dd_HHMMSS"))
duration_s = length(ARGS) >= 2 ? parse(Float64, ARGS[2]) : 60.0

FLIMApp.simulate_session(folder; duration_s = duration_s)
println("Simulated session ($(duration_s) s): ", folder)
for (root, _, files) in walkdir(folder), f in sort(files)
    path = joinpath(root, f)
    println("  ", rpad(relpath(path, folder), 32), lpad(filesize(path), 12), " bytes")
end
