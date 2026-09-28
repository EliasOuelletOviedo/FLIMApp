# Entry point on the bench (plan.md §8):
#
#     julia --project -t 3,1 scripts/app.jl [config/bench.toml]
#
# scripts/launch.bat runs this at high priority on Windows. Blocks until the
# window is closed and the DAQ loop has zeroed the outputs.
using FLIMApp

fig = FLIMApp.run_app(FLIMApp.config_path_from_args(ARGS))
FLIMApp.wait_for_window(fig)
