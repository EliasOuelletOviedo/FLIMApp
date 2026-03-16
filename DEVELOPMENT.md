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

Files must be included in this order in `main.jl`:

```julia
include("config.jl")              # 1. Constants and configuration
include("data_types.jl")          # 2. Data structures
include("gui_themes.jl")          # 3. UI styling (no dependencies)
include("lifetime_analysis.jl")   # 4. Analysis algorithms
include("data_processing.jl")     # 5. I/O (depends on lifetime_analysis)
include("runtime.jl")             # 6. Tasks (background workers)
include("handlers.jl")            # 7. Event handlers (depends on runtime)
include("GUI.jl")                 # 8. Main UI (depends on all above)
```

**Violation of this order will cause MethodError or undefined reference errors!**

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
2. Include in `main.jl` after `lifetime_analysis.jl`
3. Export public functions:
   ```julia
   export my_analysis_function
   ```

## Testing

Tests belong in `test/`:
- `test_app.jl` - Integration tests (requires display)
- `test_*.jl` - Unit tests for specific modules

Run tests from Julia REPL:
```julia
include("test/test_app.jl")
```

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
**Fix**: Check include order in `main.jl`

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
