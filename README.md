# TIFF Ratiometry Application

**Multi-channel intensity ratiometry** — a Julia-based analysis and visualization
platform for FRET-type ratio imaging, with PI feedback control.

Derived from [TIFFApp](../../tree/TIFFApp) (branch `TIFFApp`), which fitted
fluorescence lifetimes from Becker & Hickl `.sdt` TCSPC files. Everything
downstream of the measurement is shared with it; what changed is that a frame
is now a group of TIFF images — one per channel — reduced to an intensity
ratio, rather than a decay histogram fitted to a lifetime.

## Overview

This application provides:
- **GUI-based interface** for real-time ratio visualization
- **Ratiometric reduction** of 2–3 channel TIFF acquisitions, with a Hill
  calibration mapping the ratio to a concentration
- **Hardware control** integration for the galvo trigger box and PI outputs
- **Data persistence** for experimental protocols and configurations

## Input data

The app reads the folder layout the Bliq VMS acquisition software writes:

```
<selected folder>/
  <session folder, created when acquisition starts>/
    Bliq VMS/
      C1/  Name-C1-T001.tif
      C2/  Name-C2-T002.tif
      C3/  (optional)
```

Images are uncompressed TIFF/BigTIFF, 8- or 16-bit, read by a dependency-free
reader (`src/io/BigTiffFile.jl`). Files are grouped into *frame instances* —
one image per channel — from their `T###` counters. Two numbering conventions
occur in practice and are detected from the data rather than assumed; see
`src/tiff_source.jl` and `TIFFApp_SPEC.md` for the details and for why guessing
wrong is silent rather than loud.

## Prerequisites

- **Julia** 1.11.5 or later

### Julia Packages

All dependencies are declared in `Project.toml`/`Manifest.toml`. From the
repository root:

```julia
using Pkg
Pkg.activate(".")
Pkg.instantiate()   # installs the exact locked dependency versions
```

## Directory Structure

```
TIFFApp/
├── src/
│   ├── TIFFApp.jl              # Module definition, entry point, application lifecycle
│   ├── config.jl               # Configuration, constants, defaults
│   ├── data_types.jl           # Data structures (AppState, AppRun, RoiSeries)
│   ├── gui_themes.jl           # UI theme definitions and styling
│   ├── gui_blocks.jl           # GuiBlocks: typed container of GUI elements
│   ├── path_utils.jl           # Shared path-picker/cache helpers
│   ├── smoothing.jl            # Series smoothing/Kalman helpers
│   ├── serial.jl               # Serial port discovery + PID/PWM command I/O
│   ├── protocol.jl             # Protocol schedule math
│   ├── plotting.jl             # Plot-axis autoscaling and plot-series lookup
│   ├── tiff_source.jl          # Acquisition folder resolution, channel grouping
│   ├── ratio_analysis.jl       # Ratio reduction, ROI rasterization, Hill calibration
│   ├── acquisition.jl          # Playback/Realtime/Save acquisition worker tasks
│   ├── session_save.jl         # Realtime-capture session saving (.jls + CSV)
│   ├── runtime.jl              # Background task lifecycle (start/pause/stop)
│   ├── protocol_popup.jl       # Protocol popup UI
│   ├── roi_popup.jl            # ROI popup UI (TIFF/live-frame reference image, ROI drawing)
│   ├── handlers_layout.jl      # Layout panel controls
│   ├── handlers_controller.jl  # Controller panel controls
│   ├── handlers_protocol.jl    # Protocol panel controls
│   ├── handlers_console.jl     # Console panel controls
│   ├── handlers.jl             # Event handler orchestrator
│   ├── GUI.jl                  # Makie GUI construction
│   └── io/
│       ├── BigTiffFile.jl      # TIFF/BigTIFF reader (8/16-bit, uncompressed)
│       └── ImageJROI.jl        # ImageJ .roi/.zip ROI reader
├── test/
│   └── runtests.jl             # Test suite (run with `Pkg.test()`)
├── TIFFApp_SPEC.md             # Conversion spec: decisions, data-format findings
├── build/
│   ├── create_app.jl           # Standalone executable build (PackageCompiler)
│   └── precompile_app.jl       # Precompile workload for the app build
├── Project.toml                # Julia project manifest
├── Manifest.toml               # Dependency lock file
└── README.md                   # This file
```

Runtime state (saved settings, data-folder path cache) lives outside
the repository in `~/.flimapp/`, so running the app never dirties the git
working tree.

## Quick Start

### Launch the Application

Start Julia from the repository root with the project activated **and more
than one thread**, then:

```
julia -t auto --project=.
```

```julia
julia> using TIFFApp
julia> run_app()
```

(`--project=.` activates the project automatically; otherwise run
`using Pkg; Pkg.activate(".")` first.) The GUI will open in a Makie window.

The `-t auto` flag (or `julia -t 4`, or setting the `JULIA_NUM_THREADS`
environment variable before starting Julia) is identical on macOS and
Windows. It matters here: the acquisition worker (image read + reduction)
runs on its own thread via `Threads.@spawn` so the GUI stays responsive
while fitting, but that only has a second thread to run on if Julia was
started with one. With the default single thread, `run_app()` logs a
warning and acquisition falls back to sharing the GUI thread, which can
stutter during a fit.

For a hot-reloading dev workflow, `using Revise` before `using TIFFApp` —
edits to any `src/*.jl` file take effect without restarting Julia.
(Install Revise in your global environment: `julia -e 'using Pkg; Pkg.add("Revise")'` —
it is a dev tool, not a dependency of the package.)

### Standalone Executable (double-clickable app)

To build a standalone app that launches without installing Julia:

```
julia -t auto --project=build build/create_app.jl
```

- On **macOS** this produces `dist/TIFFApp.app` — double-click it in Finder
  (first launch: right-click → Open, since the bundle is unsigned).
- On **Windows** (run the same command on a Windows machine — the build is
  native-only) this produces `dist/TIFFApp/` with a double-clickable
  `TIFFApp.bat`.

The build takes tens of minutes and bundles Julia + all libraries
(~1 GB). See `build/create_app.jl` for details.

### Initial Setup

1. **Select Data**: Use the "Folder path" button to point at the acquisition
   output. Any of three shapes resolves: a `Bliq VMS` directory, a session
   folder containing one, or the parent folder holding session folders. In
   Realtime mode the session folder need not exist yet — the app waits for the
   acquisition software to create it.

2. **Pick the ratio**: The menu beside the mode selector offers all six ordered
   channel pairs (`C1/C2`, `C1/C3`, `C2/C1`, …). A pair naming a channel the
   acquisition does not write yields a `NaN` ratio rather than blocking the
   run; the per-channel intensity series stay usable.

3. **Configure Layout**: Use the Layout panel to adjust:
   - **Time range**: Duration of the display window (seconds in Realtime,
     frames in Playback)
   - **Binning**: Number of frames to sum together, capped by the image buffer
     depth
   - **Plot selection**: Image, Mean intensity, Ratio, Concentration, Command
   - **Channel toggles**: Per plot, which channels the Mean intensity plot
     draws (and which channel the Image plot shows)

## File format

Uncompressed TIFF or BigTIFF, one sample per pixel, read by
`src/io/BigTiffFile.jl`. Supported depths are 8-bit, 16-bit, and 32-bit in
either unsigned-integer or IEEE-float form — at 32 bits the `SampleFormat` tag
decides which, since the two are indistinguishable by width and reading one as
the other yields plausible numbers rather than an error. Compressed or
multi-sample files are rejected with a specific error rather than decoded
incorrectly: a wrong image silently feeding the ratio is worse than a failed
read.

Each depth carries its own accumulator width through the binning buffer and the
region reduction, resolved at compile time. 8- and 16-bit share `UInt32`
deliberately, so adding the wider formats left those paths byte-identical.

The reader is deliberately narrow rather than general: the pixel data is a
contiguous block at a fixed offset, so a frame read is a `seek` plus one bulk
read into a caller-owned buffer. That measures 0.081 ms for a 1 MB frame,
against an 8.33 ms budget at 60 Hz across two channels.

## Architecture

### Module Dependencies

```
module TIFFApp
    config.jl
        ↓
    data_types.jl   gui_themes.jl   path_utils.jl   smoothing.jl   serial.jl   protocol.jl
        ↓
    plotting.jl
        ↓
    io/BigTiffFile.jl   io/ImageJROI.jl
        ↓
    tiff_source.jl   ratio_analysis.jl
        ↓
    acquisition.jl   session_save.jl
        ↓
    runtime.jl
        ↓
    protocol_popup.jl   roi_popup.jl
        ↓
    handlers_layout.jl  handlers_controller.jl  handlers_protocol.jl  handlers_console.jl
        ↓
    handlers.jl
        ↓
    GUI.jl
end
```

See `src/TIFFApp.jl`'s `include(...)` list for the exact, authoritative order.

### Key Components

#### `config.jl`
Centralized configuration:
- File paths and directory constants
- Acquisition parameters (image buffer depth, preview size and throttle)
- Theme definitions (dark/light modes)
- Default state values

#### `data_types.jl`
Core data structures:
- **AppState**: Persistent user settings (serialized to AppState.jls)
- **AppRun**: Runtime state with observables for reactive GUI updates

#### `tiff_source.jl`
Acquisition folder resolution and per-channel file grouping:
- Locating the `Bliq VMS` directory from any of the accepted folder shapes
- Grouping per-channel files into frame instances from their `T###` counters,
  under either numbering convention (detected, not assumed)
- The Realtime instance collector, which holds a partially arrived instance
  until every channel has contributed and abandons it once overdue by a
  multiple of the observed cadence

#### `ratio_analysis.jl`
The ratiometric measurement itself:
- Ratio-of-means reduction over a region, for a chosen ordered channel pair
- ROI polygon rasterization to pixel masks
- The Hill calibration mapping a ratio to a concentration (**provisional
  constants** — see the file header)

#### `serial.jl`
Serial hardware I/O:
- Port enumeration (Windows/macOS/Linux)
- Connecting to a device
- PID/PWM command I/O

#### `protocol.jl`
Experimental protocol schedule math: converting the protocol UI's times/setpoints into a lookup used during acquisition.

#### `plotting.jl`
Plot-axis autoscaling and plot-series lookup, shared by `runtime.jl` and `GUI.jl`.

#### `acquisition.jl`
Playback/Realtime/Save acquisition worker tasks:
- Sliding-window image binning over whole frames, in their native sample type
- Per-region reduction to ratios and concentrations
- PI command computation
- Each mode is a thin wrapper around the shared `run_acquisition_loop!` core,
  differing in how the next instance is chosen and which time base it uses

#### `session_save.jl`
Saves a completed Realtime capture session (serialized `.jls` + companion CSV exports).

#### `runtime.jl`
Background task lifecycle:
- **consumer_loop**: Data streaming and plotting
- **infos_loop**: Status/frequency display
- START/PAUSE/RESUME/STOP button handlers, which launch/tear down the worker,
  consumer, serial, and infos tasks together

#### `GUI.jl` & `gui_themes.jl`
Makie-based user interface:
- Live image preview and ratio/intensity/concentration traces
- Control panels (Layout, Controller, Protocol, Console) — see `handlers_*.jl`
  for each panel's own controls
- Button handlers for START/CLEAR operations
- Theme switching (dark/light modes)

### Application State Flow

```
Startup
  ↓
Load/create AppState
  ↓
Create GUI ← AppState determines panel/theme
  ↓
Attach handlers ← Channel + Observables connect tasks to GUI
  ↓
Block on display (event loop)
  ↓
On button press → start_pressed()
  ↓
Launch worker (acquisition.jl) + consumer + serial + infos tasks
  ↓
Worker groups TIFFs into instances, reduces them to ratios, sends to channel
  ↓
Consumer updates Observables → Plots update reactively
  ↓
On CLEAR press → stop all tasks, close channel
  ↓
Save AppState on exit
```

## Configuration

The data folder is normally picked in the GUI ("Folder path" button) and
remembered across sessions. Before a folder has been picked, the fallback
is the `TIFF_DATA_PATH` environment variable when set, otherwise
`~/TIFFApp_data`.

Acquisition constants and themes live in `src/config.jl`:

```julia
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
    dark::Bool                      # Dark mode toggle
    current_panel::Symbol           # Active UI panel
    layout::LayoutSettings          # Display settings
    controller::ControllerSettings  # Hardware config
    protocol::ProtocolSettings      # Experiment settings
    roi::RoiSettings                # ROI settings
    console::ConsoleSettings        # Logging settings

AppRun
    channel::Channel                # Worker→Consumer communication
    running::Atomic{Bool}           # Task control flag
    *_task::Task                    # Background tasks
    preview::Observable             # Latest downsampled frame (image plot)
    rois_series::Vector{RoiSeries}  # Per-region time series (ratio, conc, per-channel means)
    channel_count::Int              # Channels this run writes
    timestamps, command1, ...       # Region-agnostic observables
```

### Key Analysis Functions

```julia
resolve_channel_layout(path)::Union{ChannelLayout, Nothing}
    Locate the Bliq VMS folder and its channel directories, detecting the
    file-numbering convention.

group_instances(layout)::Vector{FrameInstance}
    Group per-channel files into complete frame instances.

ratio_from_means(means, combination, channel_numbers)::Float64
    Ratio for one region, resolving the combination by channel name.

hill_ratio_to_concentration(ratio)::Float64
    Invert the (provisional) Hill calibration, clamped to its valid range.

region_mean(image, mask, frames_summed)::Float64
    Masked mean of a binned image, undoing the temporal binning.

list_ports()::Vector{String}
    Enumerate available serial devices.
```

## Troubleshooting

### "No Bliq VMS channel folders found"
The selected folder holds no acquisition. Pick a `Bliq VMS` directory, a
session folder containing one, or the parent folder holding sessions (or set
the `TIFF_DATA_PATH` environment variable before launching).

### Ratio is NaN
- The selected combination names a channel this acquisition does not write —
  check the channel folders (`C1`, `C2`, `C3`); note that some acquisitions
  write `C1` and `C3` with no `C2`
- The denominator channel is dark over the region (mean of zero)

### Concentration is flat at one end of its range
The Hill calibration constants in `src/ratio_analysis.jl` are **provisional**.
Ratios outside `[HILL_RMIN, HILL_RMAX]` are clamped, so a measured ratio range
that does not overlap the calibrated one saturates. Replace the four constants
with a real calibration.

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
