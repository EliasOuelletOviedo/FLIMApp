# FLIM Application

**Fluorescence Lifetime Imaging Microscopy** - A Julia-based analysis and visualization platform for FLIM data.

## Overview

This application provides:
- **GUI-based interface** for real-time FLIM data visualization
- **Lifetime fitting** using Maximum Likelihood Estimation (MLE) with multi-exponential decay models
- **Hardware control** integration for photon detectors and signal processing
- **Data persistence** for experimental protocols and configurations

## Prerequisites

- **Julia** 1.11.5 or later
- **Python** 3.8+ with `sdtfile` package (for Becker & Hickl .sdt file reading)

### Julia Packages

Install required packages in Julia:

```julia
using Pkg
Pkg.add("GLMakie")      # GUI framework
Pkg.add("Observables")  # Reactive programming
Pkg.add("FFTW")         # Fast Fourier Transform
Pkg.add("Optim")        # Optimization library
Pkg.add("LineSearches") # Line search algorithms
Pkg.add("PyCall")       # Python interoperability
Pkg.add("NativeFileDialog") # File dialogs
Pkg.add("ZipFile")      # ZIP archive reading
```

### Python Setup

Install the sdtfile library:

```bash
pip install sdtfile
```

## Directory Structure

```
FLIMApp/
├── src/
│   ├── main.jl                 # Entry point and application lifecycle
│   ├── config.jl               # Configuration, constants, defaults
│   ├── data_types.jl           # Data structures (AppState, AppRun)
│   ├── gui_themes.jl           # UI theme definitions and styling
│   ├── GUI.jl                  # Makie GUI construction
│   ├── handlers.jl             # Event handlers and callbacks
│   ├── runtime.jl              # Background task management
│   ├── data_processing.jl      # File I/O and data acquisition
│   └── lifetime_analysis.jl    # Lifetime fitting algorithms
├── test/
│   ├── runtests.jl             # Test suite
│   └── test_app.jl             # Application tests
├── docs/
│   ├── AppState.jls            # Serialized app state (auto-created)
│   └── irf_filepath.txt        # IRF file path cache (auto-created)
├── Project.toml                # Julia project manifest
├── Manifest.toml               # Dependency lock file
└── README.md                   # This file
```

## Quick Start

### Launch the Application

```julia
julia> include("src/main.jl")
julia> run_app()
```

The GUI will open in a Makie window.

### Initial Setup

1. **Load IRF**: On first run, you'll be prompted to select a .sdt file containing the Instrument Response Function. This is cached for future sessions.

2. **Select Data**: Use the "Folder path" button to specify where measurement .sdt files are located.

3. **Configure Layout**: Use the Layout panel to adjust:
   - **Time range**: Duration of display window (seconds)
   - **Binning**: Number of frames to sum together
   - **Plot selection**: Choose what quantities to display

## File Format

### .sdt Files (Becker & Hickl)

Binary format for time-correlated single photon counting (TCSPC) data. The application reads:
- Raw photon count histograms
- Time resolution information
- Multi-channel recording data

The reader in `data_processing.jl` handles both compressed (ZIP) and uncompressed formats.

## Architecture

### Module Dependencies

```
config.jl
    ↓
data_types.jl   gui_themes.jl
    ↓               ↓
lifetime_analysis.jl
    ↓
data_processing.jl   runtime.jl
    ↓                    ↓
    handlers.jl ←────────┘
    ↓
    GUI.jl
    ↓
main.jl (entry point)
```

### Key Components

#### `config.jl`
Centralized configuration:
- File paths and directory constants
- Physics parameters (laser period, histogram resolution)
- Theme definitions (dark/light modes)
- Default state values

#### `data_types.jl`
Core data structures:
- **AppState**: Persistent user settings (serialized to AppState.jls)
- **AppRun**: Runtime state with observables for reactive GUI updates

#### `lifetime_analysis.jl`
Maximum Likelihood Estimation fitting for fluorescence decay:
- Single to 4-exponential decay models
- IRF shift/delay compensation
- Convolution with photon transport
- Iterative optimization using BFGS/L-BFGS-B

#### `data_processing.jl`
File I/O and acquisition:
- Serial port enumeration (Windows/macOS/Linux)
- .sdt file reading with FFT optimizations
- Background worker task for streaming processing
- Sliding-window histogram binning

#### `runtime.jl`
Asynchronous task management:
- **autoscaler_loop**: Automatic axis limit adjustment
- **consumer_loop**: Data streaming and plotting
- **infos_loop**: Status/frequency display
- Channel-based communication between tasks

#### `GUI.jl` & `gui_themes.jl`
Makie-based user interface:
- Real-time histogram and fitted curve plots
- Control panels (Layout, Controller, Protocol, Console)
- Button handlers for START/CLEAR operations
- Theme switching (dark/light modes)

### Application State Flow

```
Startup
  ↓
Load/create AppState
  ↓
Load IRF (user selects .sdt file)
  ↓
Create GUI ← AppState determines panel/theme
  ↓
Attach handlers ← Channel + Observables connect tasks to GUI
  ↓
Block on display (event loop)
  ↓
On button press → start_pressed()
  ↓
Launch worker + consumer + autoscaler + infos tasks
  ↓
Worker reads .sdt iteratively, fits lifetimes, sends to channel
  ↓
Consumer updates Observables → Plots update reactively
  ↓
On CLEAR press → stop all tasks, close channel
  ↓
Save AppState on exit
```

## Configuration

Edit `src/config.jl` to customize:

```julia
# Data path
const DATA_ROOT_PATH = "/path/to/sdt/files"

# Physics
const LASER_PULSE_PERIOD = 12.5  # ns between pulses
const DEFAULT_HISTOGRAM_RESOLUTION = 256

# UI
const DARK_MODE_THEME = ...
const LIGHT_MODE_THEME = ...
```

## API Reference

### Main Functions

```julia
run_app()::Figure
    Launch and run the application.

save_state(state::AppState; path::String)
    Serialize application state to disk.

load_state(path::String)::Union{AppState, Nothing}
    Load application state from disk.
```

### Data Types

```julia
AppState
    dark::Bool              # Dark mode toggle
    current_panel::Symbol   # Active UI panel
    layout::Dict            # Display settings
    controller::Dict        # Hardware config
    protocol::Dict          # Experiment settings
    console::Dict           # Logging settings

AppRun
    channel::Channel        # Worker→Consumer communication
    running::Atomic{Bool}   # Task control flag
    *_task::Task            # Background tasks
    *::Observable           # Reactive UI data
```

### Key Analysis Functions

```julia
get_irf()::Matrix{Float64}
    Load Instrument Response Function from cached .sdt file.

vec_to_lifetime(x::Vector; kwargs)::Tuple{Vector, Vector{Vector}}
    Fit lifetime parameters to photon histogram.

MLE_iterative_reconvolution_jl(irf, data; params, gating_function, ...)::Vector
    Maximum Likelihood Estimation fitting with multi-exponential models.

conv_irf_data(x_data, params, irf; ...)::Vector
    Convolve IRF with decay model.

list_ports()::Vector{String}
    Enumerate available serial devices.
```

## Troubleshooting

### "IRF filepath does not exist"
The cached IRF path is invalid. Select a new .sdt file when prompted.

### "No .sdt files found"
Check that `DATA_ROOT_PATH` in config.jl points to a directory with .sdt files.

### Fitting returns NaN values
- Photon count too low (< 100 counts)
- Data gating window excludes all data
- Optimizer failed to converge (try different initial guess)

### Plots not updating
- Check that the "START" button was clicked
- Verify the consumer task is running: check Julia console for logs
- Ensure channel is open (`isopen(ch)`)

## References

1. **Bajzer et al. 1991** - Maximum likelihood method for the analysis of free-induction-decay signals
2. **Maus et al. 2001** - Quantitative analysis of biexponential-decay fluorescence at high photon count rates
3. **Enderlein 1997** - Fast tracking of fluorescence intensity variations in cells and in vitro
4. **Becker & Hickl** - SDT data format specification

## License

See LICENSE file in repository root.

## Contact

For issues or questions, contact the development team.
