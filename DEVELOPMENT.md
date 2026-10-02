"""
This file documents system architecture and development guidelines.
It should be read as a Julia docstring for reference.
"""

# FLIM Application - Development & Architecture Guide

## Design Principles

1. **Separation of Concerns**
   - Configuration → Data Types → Algorithms → I/O → Tasks → UI
   - Each file has clear, single responsibility
   - No circular dependencies

2. **Reactive Architecture**
   - Observables for GUI reactivity
   - Channels for task-to-GUI communication
   - State changes trigger automatic UI updates

3. **Professional Code Quality**
   - Comprehensive docstrings for all public functions
   - Type annotations for API clarity
   - Consistent error handling and logging
   - Clean separation between public and private functions

## Include Order (CRITICAL)

`src/FLIMApp.jl` defines `module FLIMApp` and its `include(...)` list is the
single source of truth for include order — read it there rather than
trusting this doc to stay perfectly in sync. As of the 2026-07 cleanup it
is, in order:

```julia
module FLIMApp

include("config.jl")              # 1. Constants and configuration
include("data_types.jl")          # 2. Data structures (AppState, AppRun, ChannelSeries)
include("gui_themes.jl")          # 3. UI styling (reuses config.jl's theme dicts)
include("gui_blocks.jl")          # 3b. GuiBlocks: typed container of GUI elements
include("path_utils.jl")          # 4. Path picker/cache helpers
include("smoothing.jl")           # 5. Lifetime smoothing/Kalman helpers
include("io/DAQmx.jl")            # 6. NI-DAQmx bindings (ccall on nicaiu)
include("daq.jl")                 # 6b. DAQ outputs: galvo scan, sync lines, PI commands
include("protocol.jl")            # 7. Protocol schedule math
include("plotting.jl")            # 8. Axis autoscaling + plot-series lookup
include("lifetime_analysis.jl")  # 10. Analysis algorithms, IRF import (.sdt of a Single)
include("acquisition.jl")         # 11. Realtime/Playback analysis worker (one pass per scan)
include("session.jl")             # 11b. Sessions: run.toml, Playback, simulated sessions
include("runtime.jl")             # 13. Background task lifecycle
include("protocol_popup.jl")      # 14. Protocol popup UI
include("roi_popup.jl")           # 15. ROI popup UI
include("handlers_layout.jl")     # 16. Per-panel handlers...
include("handlers_controller.jl") #     ...
include("handlers_protocol.jl")   #     ...
include("handlers_console.jl")    #     ...
include("handlers.jl")            # 17. Event handler orchestrator
include("GUI.jl")                 # 18. Main UI (depends on plotting.jl, handlers.jl)

end # module FLIMApp
```

Loading: `using FLIMApp` (from the repo root with `--project=.` active) —
**not** `include("src/FLIMApp.jl")` directly, since a bare `include` won't go
through Julia's package/precompilation machinery and `Revise` won't track it.
`run_app()` is exported; it is no longer called automatically on load — call
it yourself after `using FLIMApp`.

**Violation of this order will cause MethodError or undefined reference errors!**

## SPC-150N engine (FLIMCore)

`src/spc/FLIMCore.jl` is its own module (standard library only), included
by FLIMApp and loadable alone (`include("src/spc/FLIMCore.jl")`, as the
scripts in `scripts/spc/` and `test/test_flimcore.jl` do). Its rules, from
Plan.pdf:

- **One task touches the SPC DLL**: the engine (`_boucle_moteur`,
  `src/spc/moteur.jl`). GUI callbacks only call `FLIMCore.commander!`; the
  refresh tick drains `engine.resultats` (`spc_tick!`, `gui/spc_view.jl`).
- **Ready modules only**: a DLL call on an absent or uninitialized module
  can kill Julia; try/catch cannot help. The engine only calls a source on
  the modules `ouvrir!` returned as ready.
- **Release guaranteed**: try/finally around the engine's whole life;
  window close and `atexit` both call `arreter_moteur`.
- **The engine never waits for the GUI**: a full results channel drops
  (`perdus`), an `ImageTrame` without a free buffer is not published
  (`trames_sautees`); recording and the saved sums are unaffected. Read
  frames go back with `FLIMCore.rendre!`.
- **Photon sources** share one interface (`src/spc/sources.jl`): the
  cards, a `.spc` replay, a simulation; the SPC-QC-104 will be another one.
- `ranger_photons` is imagerie_photons.jl's block processing, unchanged;
  the `Rangeur` does the same frame by frame, and the tests check both give
  identical results, to the bit.
- **Realtime (`Clamp`)**: FIFO mode with routing, no software deadline. A
  6321 counter clocked by the AO sample clock (`channels.passes`, out on
  PFI13) is high during each scan; its rising edge is the cards' M0 (start
  of pass, `routing_mode` 0x1100), and each pass lasts `Clamp.scan_s` after
  it. M0s must follow the slot cadence (scan + pause, `echantillon_s` +
  100 ppm): one off it is a glitch, ignored; a gap of several slots counts
  missing M0s. With `[clamp] fin_par_m3 = true`, the falling edge of the
  same signal on M3 ends the pass instead (0x1900). The NI writes the
  ROI's routing code during the scan and the reserved code
  (`CODE_HORS_ROI`) during moves, pauses and the entry: those photons are
  thrown away when decoding (no CNTE line). The engine reads each card's
  FIFO, records it (`<serial>.spc` in the session's spc/), and cuts it into
  passes at the markers (`Passes`, spc/passes.jl): `canaux` × 16 histograms
  per card, one column per routing code. A late read only fills the FIFO.
  A pass gets `motifs` — and the worker keeps it out of the PI — for a GAP
  record, `SPC_FOVFL` during it (`_surveiller_fovfl!`), or (M3 mode) M3 −
  M0 off `Clamp.scan_s` by more than `echantillon_s` + 100 ppm. Passes are paired
  across cards by start time, offsets tracked for clock drift
  (`_publier_passes!`). One `HistoClamp` per pass (all cards) goes to
  `engine.histogrammes`, which only the analysis worker reads; it takes each
  pass's ROI from the routing code its photons carry (`pass_roi`). The NI
  writes NOT(code) (`inverser_routage`): the card reads the ROI's drawn
  index; code 0 (undriven lines) is reserved, hence 15 ROIs at most.
- **Playback**: the same engine on `source_session(dir; vitesse)` (the
  recorded streams), the same worker (`drive_outputs = false`: simulated PI),
  `source_done` ending it once the replay is over; the session's settings
  (`session_analysis_settings`) unless "Playback: current".
  `simulate_session` writes a session through the engine itself.
- **Diagnostics** (diagnostics.jl, gui/debug_report.jl, DEBUGGING.md): a
  bench problem is reported with `report_problem!(code, detail)` — add the
  code to `PROBLEM_LIST` and regenerate DEBUGGING.md's table (a test checks
  every code is there). Wrap hardware steps in `with_context` so errors say
  which step failed. `on` in FLIMApp is the guarded version (GUI-01). The
  SPC engine publishes `EtatClamp` every second of a Realtime measurement;
  `diagnose_passes` turns it into PASS-/ROUTE- problems.
- **IRF**: imported from a Single .sdt with the settings it was taken with
  (`read_sdt_irf`, irf.toml); `irf_mismatches` refuses it at import and at
  START against the cards' read-back settings and the declared `[dcc]`.
- Code updates: Revise during development, otherwise restart Julia; the
  launchers call `FLIMCore.garde_version()` (bump `VERSION_CORE` when
  FLIMCore changes).

## Global Variables

Global variables are minimized but necessary for:
- **FFT plans**: `fft_plan`, `ifft_plan` (performance: planned once)
- **IRF data**: `irf`, `irf_bin_size` (shared by all lifetime functions)
- **Theme colors**: `COLOR_1`, `COLOR_2`, etc. (set by config)

All globals should be:
- Declared with `const` or `var"name"` for clarity
- Documented in their definition
- Initialized only once (idempotent)
- Used read-only after initialization

## Adding New Features

### New Configuration Setting

1. Add to `src/config.jl`:
   ```julia
   const NEW_PARAM = default_value
   ```

2. Reference it in dependent modules:
   ```julia
   my_var = NEW_PARAM  # Automatic via include order
   ```

### New UI Widget

1. Create in `make_gui()` → Create in appropriate GridLayout
2. Store in `blocks` dict:
   ```julia
   blocks[:my_widget] = Button(grid[...]...)
   ```
3. Add handler in `make_handlers()`:
   ```julia
   on(blocks[:my_widget].clicks) do n
       # Handle click
   end
   ```

### New Background Task

1. Define in `runtime.jl`:
   ```julia
   function my_task(app_run, blocks; rate=30)
       while app_run.running[]
           # Do work
           sleep(1/rate)
       end
   end
   ```

2. Launch from START button in `runtime.jl:start_pressed()`:
   ```julia
   app_run.my_task = Threads.@spawn my_task(app_run, blocks)
   ```

3. Cleanup in STOP button:
   ```julia
   if app_run.my_task !== nothing && !istaskdone(app_run.my_task)
       wait(app_run.my_task)
   end
   ```

### New Analysis Algorithm

1. Add to `src/lifetime_analysis.jl` (or create `src/new_analysis.jl`)
2. Include in `FLIMApp.jl` after `lifetime_analysis.jl`
3. Export public functions:
   ```julia
   export my_analysis_function
   ```

## Testing

Tests live in `test/runtests.jl` and cover the GUI-free logic: protocol
schedule math, smoothing, state persistence round-trips, spinner stepping,
plot windowing, and the MLE fit on a synthetic decay with a known lifetime.
The GUI itself is exercised manually via `run_app()`.

Run the suite:
```julia
using Pkg; Pkg.activate("."); Pkg.test()
```

CI (`.github/workflows/CI.yml`) runs the same suite on every push/PR,
under `xvfb-run` so GLMakie has an OpenGL context on the headless runner.

## Performance Notes

### FFT Planning
```julia
# GOOD: Plan once, reuse many times
global fft_plan = plan_fft(zeros(Float64, N))
for data in stream
    result = fft_plan * data
end

# BAD: Plans for every call (very slow)
for data in stream
    result = fft(data)
end
```

### Observable Updates
```julia
# GOOD: Batch updates, notify once
for item in items
    push!(obs[], item)
end
notify(obs)  # Single notification

# BAD: Notify per update (GUI thrashing)
for item in items
    obs[] = item  # Triggers redraw each time
end
```

### Channel Communication
```julia
# GOOD: Simple tuple types (fast serialization)
put!(ch, (histogram, fit, photons, lifetime, ...))

# BAD: Complex Dict/struct (slower, more allocations)
put!(ch, Dict(:histogram=>h, :fit=>f, ...))
```

## Debugging

### Enable Debug Logging
```julia
using Logging
global_logger(ConsoleLogger(stderr, Logging.Debug))
```

### Inspect Application State
```julia
# In running app, from separate Julia terminal:
println(app.dark)         # Current theme
println(app.layout)       # Display settings
println(app_run.running[])  # Task status
println(Threads.nthreads())  # Thread count
```

### Trace Task Execution
```julia
# In task, add logging:
@debug "Processing" file=filepath data_points=length(data)
@info "State updated" lifetime=τ concentration=c
```

### Channel Debugging
```julia
# Check if channel is open
println(isopen(ch))

# Check pending items
println(length(ch))  # This is NOT safe; use try/catch instead
```

## Common Bugs

### MethodError: no method matching
**Cause**: Called a function before its module was included
**Fix**: Check include order in `FLIMApp.jl`

### UndefVarError: `irf` not defined
**Cause**: `get_irf()` not called before using `irf` global
**Fix**: Ensure `get_irf()` is called in `run_app()` before GUI creation

### Observable update not triggering plot
**Cause**: Modified Vector content without triggering notification
**Fix**: Use `obs[] = new_vector` or `notify(obs)` after modification

### Task hangs on exit
**Cause**: Task still waiting on closed channel
**Fix**: Always check `app_run.running[]` in while loop

### FFT plan size mismatch
**Cause**: Data size doesn't match plan size
**Fix**: Create separate plans for each resolution needed

## Code Style

### Docstrings
```julia
"""
    my_function(x::Int, y::String)::Bool

Brief description (one line).

Longer description with more detail about what this does,
including motivation and common usage patterns.

Args:
- `x::Int` - Description of x
- `y::String` - Description of y

Keyword Args:
- `verbose::Bool` - Enable debug output (default: false)

Returns:
- Bool indicating success

See also: related_function
"""
```

### Function Organization
```julia
# 1. Public API (exported)
export my_function
function my_function(...)
    ...
end

# 2. Private helpers (internal only)
function _helper_function(...)
    ...
end
```

### Type Annotations
```julia
# GOOD: Clear API contract
function process(data::Vector{Float64}, threshold::Float64)::Vector{Float64}
    ...
end

# OK for internal/complex types
function setup_task(app_run, blocks)
    ...
end
```

## Deployment Checklist

Before release:
- [ ] All docstrings complete
- [ ] No hardcoded paths (use config.jl)
- [ ] Error handling for user inputs
- [ ] State saved on exit
- [ ] Log messages for all major operations
- [ ] Test on clean Julia environment
- [ ] Update README with new features
- [ ] Version bump in Project.toml

## Future Improvements

Potential enhancements (in priority order):
1. Multi-threaded file reading (currently sequential)
2. GPU acceleration for convolution (CUDA via CuFFT)
3. Advanced fitting models (stretched exponentials)
4. Real-time spectral filtering
5. Batch processing mode
6. Plugin system for custom analysis
7. REST API for remote operation
