# Quick Navigation Guide

## Start Here
1. **README.md** - What the app does and how to use it
2. **DEVELOPMENT.md** - How the code is organized and how to modify it
3. **src/TIFFApp.jl** - Module definition and entry point; shows the authoritative include order

## Understanding the Architecture

### Read These First (In Order)
1. [src/config.jl](src/config.jl) - All constants and defaults (2 min)
2. [src/data_types.jl](src/data_types.jl) - Data structures (2 min)
3. [DEVELOPMENT.md](DEVELOPMENT.md#design-principles) - Design principles (5 min)

### Then by Responsibility

#### Configuration
- [src/config.jl](src/config.jl) - All settings, paths, constants

#### Data Types
- [src/data_types.jl](src/data_types.jl) - AppState (persistent), AppRun (runtime)

#### User Interface
- [src/GUI.jl](src/GUI.jl) - Makie figure layout and widgets
- [src/gui_themes.jl](src/gui_themes.jl) - Colors and styling
- [src/handlers.jl](src/handlers.jl) - Event handler orchestrator
- [src/handlers_layout.jl](src/handlers_layout.jl), [handlers_controller.jl](src/handlers_controller.jl), [handlers_protocol.jl](src/handlers_protocol.jl), [handlers_console.jl](src/handlers_console.jl) - One file per panel's own controls

#### Analysis & Processing
- [src/tiff_source.jl](src/tiff_source.jl) - Folder resolution, channel grouping, realtime collector
- [src/ratio_analysis.jl](src/ratio_analysis.jl) - Ratio reduction, ROI masks, Hill calibration
- [src/io/BigTiffFile.jl](src/io/BigTiffFile.jl) - TIFF/BigTIFF reader
- [src/acquisition.jl](src/acquisition.jl) - Playback/Realtime/Save worker tasks
- [src/serial.jl](src/serial.jl) - Serial port discovery + PID/PWM I/O
- [src/protocol.jl](src/protocol.jl) - Protocol schedule math
- [src/session_save.jl](src/session_save.jl) - Realtime-capture session saving

#### Background Tasks
- [src/runtime.jl](src/runtime.jl) - Task lifecycle (consumer_loop, infos_loop, start/pause/stop)
- [src/plotting.jl](src/plotting.jl) - Axis autoscaling + plot-series lookup

#### Application
- [src/TIFFApp.jl](src/TIFFApp.jl) - Module definition, entry point, state management, lifecycle

## Common Tasks

### "How do I add a new configuration parameter?"
→ Edit [src/config.jl](src/config.jl), then reference it by name

### "How do I add a new button?"
→ Create in [src/GUI.jl](src/GUI.jl) make_gui() (or its make_*_widgets! helpers), handle it in the relevant `handlers_*.jl` panel file

### "How do I add a new background task?"
→ Define in [src/runtime.jl](src/runtime.jl), launch in start_pressed()

### "How do I understand the ratio measurement?"
→ Start with `reduce_regions` in [src/acquisition.jl](src/acquisition.jl), then
`ratio_from_means` and `region_mean` in [src/ratio_analysis.jl](src/ratio_analysis.jl)

### "How are per-channel files paired into a frame?"
→ [src/tiff_source.jl](src/tiff_source.jl) header, then `instance_index_for`
and `detect_numbering`

### "How do I modify the data flow?"
→ Check [src/runtime.jl](src/runtime.jl) consumer_loop() and Channel usage

### "How do I modify acquisition behavior for one mode only?"
→ Check the thin `start_playback`/`start_realtime`/`start_save` wrappers in
[src/acquisition.jl](src/acquisition.jl); shared binning/reduction/PI logic lives
in `run_acquisition_loop!` in the same file

### "Why is something not working?"
→ Check [DEVELOPMENT.md](DEVELOPMENT.md#common-bugs) debugging section

## Code Reading Suggestions

### For Performance Understanding
1. [src/acquisition.jl](src/acquisition.jl) - Image buffer, incremental window sum
2. [src/io/BigTiffFile.jl](src/io/BigTiffFile.jl) - Zero-allocation frame reads

### For Reactive Programming
1. [src/data_types.jl](src/data_types.jl) - Observable definitions
2. [src/runtime.jl](src/runtime.jl) - Observable notifications
3. [src/handlers_layout.jl](src/handlers_layout.jl) - Binding and updates

### For Hardware Integration
1. [src/serial.jl](src/serial.jl) list_ports() - Serial enumeration
2. [src/io/BigTiffFile.jl](src/io/BigTiffFile.jl) read_frame!() - File reading

## Testing

Run the test suite from the repository root:

```julia
using Pkg; Pkg.activate("."); Pkg.test()
```

Tests live in [test/runtests.jl](test/runtests.jl) and cover the GUI-free
logic (the TIFF reader, channel grouping, ratio and Hill math, the image
binning buffer, protocol math, smoothing, state persistence, ROI slot tracking).

## Key Concepts

### State Management
- **AppState** - Saved to disk (theme, panel, settings)
- **AppRun** - In-memory only (observables, tasks, channels)

### Reactive Updates
- Observables (`Observable{T}`)
- Binding with `on(obs) do val ... end`
- Manual notification: `notify(obs)`

### Task Communication
- **Channel**: One-way pipe for worker→GUI data
- **Observables**: Two-way for GUI↔logic bindings
- **Atom{Bool}**: Thread-safe flag for control

### Include Order
Files MUST be included in order defined in [src/TIFFApp.jl](src/TIFFApp.jl). Changing this order causes errors!

## Debugging Checklist

- [ ] Check Julia console for error messages
- [ ] Verify include order in TIFFApp.jl
- [ ] Check irf is loaded: `println(TIFFApp.irf)` (after `using TIFFApp`)
- [ ] Check task status: `println(app_run.running[])`
- [ ] Check channel open: `println(isopen(ch))`
- [ ] Enable debug logging: `global_logger(ConsoleLogger(stderr, Logging.Debug))`

## Performance Profiling

```julia
using Profile
@profile run_app()
Profile.print()
```

## Release Checklist

- [ ] All files have docstrings
- [ ] No hardcoded paths
- [ ] Error handling complete
- [ ] Tests passing
- [ ] Documentation complete
- [ ] Version bumped
- [ ] README updated
