# Quick Navigation Guide

## Start Here
1. **README_PROFESSIONAL.md** - What the app does and how to use it
2. **DEVELOPMENT.md** - How the code is organized and how to modify it
3. **src/main.jl** - Entry point; shows initialization sequence

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
- [src/handlers.jl](src/handlers.jl) - Button callbacks and interactions

#### Analysis & Processing
- [src/lifetime_analysis.jl](src/lifetime_analysis.jl) - MLE fitting algorithms
- [src/data_processing.jl](src/data_processing.jl) - File I/O and worker task

#### Background Tasks
- [src/runtime.jl](src/runtime.jl) - Async loops (autoscaler, consumer, infos)

#### Application
- [src/main.jl](src/main.jl) - Entry point, state management, lifecycle

## Common Tasks

### "How do I add a new configuration parameter?"
→ Edit [src/config.jl](src/config.jl), then reference it by name

### "How do I add a new button?"
→ Create in [src/GUI.jl](src/GUI.jl) make_gui(), handle in [src/handlers.jl](src/handlers.jl) make_handlers()

### "How do I add a new background task?"
→ Define in [src/runtime.jl](src/runtime.jl), launch in start_pressed()

### "How do I understand the lifetime fitting?"
→ Start with [src/lifetime_analysis.jl](src/lifetime_analysis.jl) vec_to_lifetime()

### "How do I modify the data flow?"
→ Check [src/runtime.jl](src/runtime.jl) consumer_loop() and Channel usage

### "Why is something not working?"
→ Check [DEVELOPMENT.md](DEVELOPMENT.md#common-bugs) debugging section

## Code Reading Suggestions

### For Performance Understanding
1. [src/data_processing.jl](src/data_processing.jl) - Sliding window optimization
2. [src/lifetime_analysis.jl](src/lifetime_analysis.jl) - FFT planning

### For Reactive Programming
1. [src/data_types.jl](src/data_types.jl) - Observable definitions
2. [src/runtime.jl](src/runtime.jl) - Observable notifications
3. [src/handlers.jl](src/handlers.jl) - Binding and updates

### For Hardware Integration
1. [src/data_processing.jl](src/data_processing.jl) list_ports() - Serial enumeration
2. [src/data_processing.jl](src/data_processing.jl) open_SDT_file() - File reading

## File Statistics

| File | Lines | Purpose | Complexity |
|------|-------|---------|------------|
| config.jl | ~150 | Configuration | Low |
| data_types.jl | ~130 | Data structures | Low |
| gui_themes.jl | ~500 | UI Theme | Medium |
| GUI.jl | ~300 | Interface | High |
| handlers.jl | ~400 | Events | High |
| runtime.jl | ~200 | Tasks | Medium |
| data_processing.jl | ~350 | I/O | High |
| lifetime_analysis.jl | ~700 | Analysis | Very High |
| main.jl | ~150 | Integration | Medium |

## Testing

See [test/](test/) directory:
- test_app.jl - Run with `julia> include("test/test_app.jl")`

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
Files MUST be included in order defined in [src/main.jl](src/main.jl). Changing this order causes errors!

## Debugging Checklist

- [ ] Check Julia console for error messages
- [ ] Verify include order in main.jl
- [ ] Check irf is loaded: `println(irf)`
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
