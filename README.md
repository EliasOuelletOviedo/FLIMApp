# FLIM Application

**Fluorescence Lifetime Imaging Microscopy** - A Julia-based analysis and visualization platform for FLIM data.

## Overview

This application provides:
- **GUI-based interface** for real-time FLIM data visualization
- **Lifetime fitting** using Maximum Likelihood Estimation (MLE) with multi-exponential decay models
- **Hardware control** integration for photon detectors and signal processing
- **Data persistence** for experimental protocols and configurations

## Prerequisites

- **Julia** 1.13.1 or later

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
FLIMApp/
├── src/
│   ├── FLIMApp.jl               # Module definition, entry point, application lifecycle
│   ├── config.jl               # Configuration, constants, defaults
│   ├── data_types.jl           # Data structures (AppState, AppRun, ChannelSeries)
│   ├── gui_themes.jl           # UI theme definitions and styling
│   ├── gui_blocks.jl           # GuiBlocks: typed container of GUI elements
│   ├── path_utils.jl           # Shared path-picker/cache helpers
│   ├── smoothing.jl            # Lifetime smoothing/Kalman helpers
│   ├── daq.jl                  # NI-DAQmx outputs: ROI galvo scan, sync lines, PI commands
│   ├── protocol.jl             # Protocol schedule math
│   ├── plotting.jl             # Plot-axis autoscaling and plot-series lookup
│   ├── lifetime_analysis.jl   # Lifetime fitting algorithms (MLE), IRF loading
│   ├── acquisition.jl          # Realtime/Playback analysis worker (one pass per scan)
│   ├── session.jl              # Sessions: run.toml, read back for Playback, simulated sessions
│   ├── runtime.jl              # Background task lifecycle (start/pause/stop)
│   ├── protocol_popup.jl       # Protocol popup UI
│   ├── roi_popup.jl            # ROI popup UI (shell; ROI reading not wired in yet)
│   ├── handlers_layout.jl      # Layout panel controls
│   ├── handlers_controller.jl  # Controller panel controls
│   ├── handlers_protocol.jl    # Protocol panel controls
│   ├── handlers_console.jl     # Console panel controls
│   ├── handlers.jl             # Event handler orchestrator
│   ├── GUI.jl                  # Makie GUI construction
│   ├── io/
│   │   ├── DAQmx.jl            # Minimal NI-DAQmx bindings (ccall on nicaiu); used by daq.jl
│   │   └── ImageJROI.jl        # WIP: ImageJ ROI reader (not yet wired in)
│   ├── spc/                    # FLIMCore: SPC engine, SPC-QC-104 (see "SPC card" below)
│   └── gui/spc_view.jl, gui/spc_window.jl   # its GUI side: top bar + SPC window
├── config/
│   ├── bench.toml              # NI wiring, timing, limits, journal
│   └── spc.toml                # SPC card settings ([qc] for the QC-104, replaces reglages_qc.jl)
├── scripts/spc/                # imagerie.jl, single.jl: FLIMCore launchers (replace the bench scripts)
├── scripts/simulate_session.jl # a simulated session for Playback
├── DEBUGGING.md                # problem codes, debug log and report: what to check
├── test/
│   ├── runtests.jl             # Test suite (run with `Pkg.test()`)
│   └── test_flimcore.jl        # FLIMCore tests (also runnable alone: julia -t 4 test/test_flimcore.jl)
├── build/
│   ├── create_app.jl           # Standalone executable build (PackageCompiler)
│   └── precompile_app.jl       # Precompile workload for the app build
├── Project.toml                # Julia project manifest
├── Manifest.toml               # Dependency lock file
└── README.md                   # This file
```

Runtime state (saved settings, the imported IRF, IRF/session path caches) lives outside
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
julia> using FLIMApp
julia> run_app()
```

(`--project=.` activates the project automatically; otherwise run
`using Pkg; Pkg.activate(".")` first.) The GUI will open in a Makie window.

The `-t auto` flag (or `julia -t 4`, or setting the `JULIA_NUM_THREADS`
environment variable before starting Julia) is identical on macOS and
Windows. It matters here: the acquisition worker (file read + lifetime fit)
runs on its own thread via `Threads.@spawn` so the GUI stays responsive
while fitting, but that only has a second thread to run on if Julia was
started with one. With the default single thread, `run_app()` logs a
warning and acquisition falls back to sharing the GUI thread, which can
stutter during a fit.

For a hot-reloading dev workflow, `using Revise` before `using FLIMApp` —
edits to any `src/*.jl` file take effect without restarting Julia.
(Install Revise in your global environment: `julia -e 'using Pkg; Pkg.add("Revise")'` —
it is a dev tool, not a dependency of the package.)

### Standalone Executable (double-clickable app)

To build a standalone app that launches without installing Julia:

```
julia -t auto --project=build build/create_app.jl
```

- On **macOS** this produces `dist/FLIMApp.app` — double-click it in Finder
  (first launch: right-click → Open, since the bundle is unsigned).
- On **Windows** (run the same command on a Windows machine — the build is
  native-only) this produces `dist/FLIMApp/` with a double-clickable
  `FLIMApp.bat`.

The build takes tens of minutes and bundles Julia + all libraries
(~1 GB). See `build/create_app.jl` for details.

### Initial Setup

1. **Load IRF**: On first run, you'll be prompted to select the IRF: a
   Single measurement of it. With the SPC-QC-104, either SPCM's `.sdt`
   (one curve per input; one detector per file works too —
   `irf_ch1.sdt` and `irf_ch2.sdt`, the other found by its number), its TDC
   channels spread onto `[qc] fenetre_ns`; or the SPC window's Single
   (SINGLE button, `<date>_module<k>.csv` in `<recording folder>/single/`),
   resampled exactly as the Realtime decays — sharper than a 256-point
   `.sdt` (64 ps channels; take 4096 points in SPCM to keep 4 ps). With
   SPC-150N cards, SPCM's `.sdt` (one decay, or two for two channels,
   ordered by the cards' serial numbers). It is imported once —
   median background removed, summed down to 256 channels — and kept as
   `~/.flimapp/irf.csv` (`time_ns,ch1[,ch2]`), with `irf.toml`, the
   settings it was taken with. Each channel is fitted against its own IRF
   (a single-channel IRF serves both). **An IRF taken with other settings is
   refused**, at import and at every Realtime START: the card and input
   (serial number, "3T0089/IN1"), its timing settings (QC-104: thresholds
   and zero levels of the input and the SYNC, TDC offsets and range, the
   window `fenetre_ns`; SPC-150N: TAC range, gain, offset, limits, CFD and
   SYNC thresholds) — read back from the card at its last check, as
   `config/spc.toml` requests them otherwise — and the detector gains declared
   in `[dcc]` (the transit time changes with the high voltage, which the
   app can't read: keep `[dcc]` up to date). The IRF button imports another
   one and loads it right away (at the next START during a run).

2. **Recording folder**: the second path field is where everything is
   recorded (`[enregistrement] dossier` in `config/spc.toml`, rewritten by
   its button): the sessions in its `sessions/`, the SPC window's
   acquisitions next to them. The raw stream takes 4 bytes per photon and
   per channel: at 1 Mcps on two channels, about 8 MB/s, 29 GB/h. The free space
   is checked at start-up and shown in the status line (in the top bar's
   banner below an hour of recording); START refuses the Realtime mode
   below 10 minutes.

3. **Session to replay**: the third path field picks the session Playback
   replays (see "Playback" below).

4. **Configure Layout**: Use the Layout panel to adjust:
   - **Time range**: Duration of display window (seconds)
   - **Binning**: Number of frames to sum together
   - **Plot selection**: Choose what quantities to display

## SPC card: SPC-QC-104 (FLIMCore)

The TCSPC card is driven by **FLIMCore** (`src/spc/`), as laid out in
Plan.pdf. One task (`Threads.@spawn`, the SPC engine) is the only code that
calls the SPC DLL (`src/spc/SPCLite.jl`); the GUI sends it commands and
reads its results through two `Channel`s, and never makes a `ccall`. The
standalone DCC software keeps the detectors: the app never calls the
DCC-100 DLL, and only sees the detectors through their count rates.

**One card, one detector per input.** The SPC-QC-104 (serial 3T0089) takes
both detectors: channel 1 on IN1, channel 2 on IN2, the laser's SYNC on the
SYNC input — `[verification] series = ["3T0089/IN1", "3T0089/IN2"]`. The
engine reads the card's FIFO once and splits it into one *virtual card* per
channel (`SourceQC`, `src/spc/source_qc.jl`), each with the stream of an
SPC-150N: that input's photons, the markers and the macro time. Imaging,
Single, the Realtime passes, the recorded sessions, Playback and the
analysis are unchanged. The QC-104's FIFO format (`SPCLite.FORMAT_QC104`)
was established on qc4/qc5's acquisitions and checked record by record
against the DLL's own decoding (`test/data/qc104`). Its TDC has 4096
channels over `[qc] plage_tdc_ns` (4 ps at 16.384 ns); they are resampled
onto `[qc] fenetre_ns` (12.5 ns, the laser period: the analysis's window, as
with the SPC-150N), each photon drawn within its 4 ps channel so that no
comb appears. The Single is emulated in FIFO (the card's histogram memory
layout for several inputs isn't documented). Two SPC-150N still work with
`[source] type = "cartes"` and `[spc_module]`.

**Wiring of the QC-104** (Micro Sub-D 15): PFI13 (CTR 1 OUT) → pin 12 (Marker
0) and pin 10 (Marker 3); P0.4, P0.5, P0.6, P0.7 → pins 2, 3, 4, 7 (/R0 to
/R3); D GND → pin 5 or 15; nothing on pins 1, 6, 11 (supplies). For imaging,
the scanner's line and frame clocks go to Marker 1 and Marker 2.

**Start-up and shutdown on the bench**

1. Power the Magma and Simple-Tau chassis, then the PC.
2. Open the **standalone DCC software** (not SPCM's DCC panel). Set M1 (C1 and
   C3 at 82 %, b0, cooling 5 V / 1.98 A) and click "Enable outputs". SPCM
   must stay closed: it locks the SPC card.
3. Launch the app (`scripts\launch.bat`). With `connexion_au_demarrage = true`
   in `config/spc.toml`, the engine initializes the card and checks it: the
   QC-104 ready (other SPC cards still installed are left alone: the DLL
   drives one type at a time), its serial number, SYNC, settings applied as
   requested, and the photons of each input counted in the FIFO above
   `seuil_cfd` (the card's rate counters are compared with that count: SPC-09
   if `[qc] taux` attributes them wrongly). The top bar shows the result; the
   **SPC** button opens the SPC window with the details.
4. During measurements the engine rereads the rates every 0.5 s and raises
   an alert when SYNC is lost or the CFD rate collapses (overload shutdown in
   the DCC software).
5. Close the window: the engine stops any measurement and frees the cards,
   even after an error (also on Ctrl+C, through `atexit`). Then turn the
   outputs off in the DCC software.

**SPC window**: CONNECT/DISCONNECT, CHECK, IMAGE (continuous, or
`duree_s`), SINGLE, UNLOCK (cards left locked by a crashed session: asks for
a second click, SPCM must be closed). Per card, the intensity and mean
arrival time images (refreshed at most 10 times a second, summing
`trames_par_image` frames), the decays and the CFD rate. The geometry,
display and Single fields are written back to `config/spc.toml`.

**Settings**: `config/spc.toml`, reread at every measurement start. Copy your
SPCM values for the QC-104 into `[qc]` (thresholds, zero levels and offsets
of IN1, IN2, IN3 and SYNC, TDC range: the names of reglages_qc.jl; the app
translates them into the DLL's keys and turns on, with routing, the inputs
of `[verification] series`). `[dcc]` records the DCC settings the app
cannot read. At the end of each measurement, photons the translation set
aside (beyond `fenetre_ns`, an input without a channel) are reported
(SPC-10).

**Files**: every acquisition goes to `~/FLIMApp_spc/` (`[enregistrement]
dossier`): for imaging, per card, the raw FIFO stream (`.spc`), the
parameters read back from the card (`_parametres.ini`), what is needed to
reprocess it (`_acquisition.ini`, with the geometry and the declared DCC
settings), the summed images (`.jls`, `_intensite.bmp`, `_temps_moyen.bmp`)
and the decay (`_declin.svg`); for Single, `.csv`, `.svg` and
`_parametres.ini`, as the bench scripts wrote them.

**Without the cards**: `[source] type = "simulation"` (a synthetic scanner
at 31.25 frames/s) or `"rejeu"` (replays recorded `.spc` files listed in
`rejeu`, in real time) run the whole chain on any machine.

**Scripts**: `scripts/spc/imagerie.jl` and `scripts/spc/single.jl` replace
imagerie_photons.jl and histogrammes_single.jl (same outputs);
`julia -t 4 scripts/spc/horloges_scanner.jl "<scanner setting>" [s]` measures
what the cards see of the scanner's clocks for one scanner setting — line
(M1) and frame (M2) frequencies, lines per frame, the setting recognized in
`reglages_scanner` — and, with a sample, where the photons fall in the whole
frame (to check the skipped lines and pixels); it appends to
`<recording folder>/horloges/horloges_scanner.csv`;
`julia -t auto scripts/spc/imagerie.jl <name>` reprocesses a recorded
acquisition without the cards. `SPC_REGLAGES=<file>` points them to another
settings file.

## Realtime acquisition (START, mode Realtime)

The photons come straight from the SPC card's FIFO; no file is read and
nothing depends on a software deadline. START requires the DAQ loop READY
(the app tries CONNECT at launch) and the SPC engine ready, then runs three
parts together until STOP or until one of them stops (DAQ fault, SPC error):

- the **DAQ loop** plays slots of `Scan time` then `Shift time` (Protocol
  panel), all on the AO sample clock:
  - the **routing code** on P0.4–P0.7: during each scan, the ROI's code;
    while the galvos move, during the pause and the entry, the reserved
    code ("hors ROI"), whose photons are thrown away when the stream is
    decoded. In FIFO mode, that does what CNTE did, without a line: the
    cards' CNTE (pin 14) is no longer used, and P0.2/P0.3 keep their
    sequence and ROI pulses;
  - the **pass signal**: a 6321 counter (`channels.passes`, ctr1, out on
    PFI13 = CTR 1 OUT by default) clocked by the same sample clock, high
    during each scan, wired to M0 and M3 of the QC-104 (pins 12 and 10)
    with a common ground (D GND to pin 5 or 15). Its rising edge (M0) starts
    a pass and its falling edge (M3) ends it (`[clamp] fin_par_m3 = true`,
    the default; `routing_mode = 0x1900`, set by the engine). Without M3,
    `fin_par_m3 = false`: the pass lasts the programmed scan after M0
    (0x1100).
- the **SPC engine** measures in FIFO mode (`[clamp]` in `config/spc.toml`,
  256 channels by default) and cuts each card's photon stream into passes
  at the markers the card itself time-stamped: a late read only fills the
  card's FIFO. A pass is shown but **kept out of the PI** when a record
  carries the loss flag (GAP), when `SPC_FOVFL` appears during it, or (M3
  mode) when M3 − M0 is off the programmed scan by more than one AO sample
  and 100 ppm. With M0 only, each M0 must fall a whole number of slots
  (scan + pause, within one AO sample and 100 ppm) after the last good one:
  an M0 off that cadence is a glitch and is ignored, a gap of several slots
  counts missing M0s (lost passes). The channels' passes are paired by
  their start times — with the QC-104 they share the card's markers, so
  they pair exactly (two SPC-150N each start their clock at their own
  instant and drift); a pass without its partner is dropped. Channels are
  identified at start-up by `[verification] series` ("3T0089/IN1" = channel
  1, "3T0089/IN2" = channel 2), whatever the module numbers.
- the **analysis worker** fits each pass, per ROI and per channel (binning
  window and Kalman observer per ROI and channel), and runs **one PI per
  ROI**: the DAQ loop writes each ROI's own commands during that ROI's
  scans.

**ROI off** (or no ROI drawn): the galvos stay still and the slots keep the
same scan/pause rhythm; the routing lines carry code 1 during the scans
(the whole field) and the reserved code during the pauses; each pass gives
one histogram of every photon.

**ROI on**: the galvos scan the ROIs, one per slot, and P0.4–P0.7 carry the
ROI's routing code: its drawn index `c` (1–15). The cards' routing inputs
are active low, so the NI writes NOT(c) and the card reads `c`
(`inverser_routage = true` in `config/spc.toml`). Code 0 — what the card
reads when nothing drives the lines — is reserved: at most **15 ROIs**, and
a loose cable doesn't send photons into a real ROI. Each pass's ROI is the
code its photons carry.

**ROI popup**: the **Image ×100** button acquires 100 frames with the
scanner's line and frame clocks (as imagerie_photons.jl did), at the fixed
geometry of `[imagerie]`: 1024 pixels per line, and with `lignes_par_image
= 0` (the default) the lines of the scanner setting recognized from the
frame clock — `reglages_scanner` maps each setting's lines per frame (1080,
540, 270, 144, 72, 36, 20, measured on the bench; the line lasts 55.55 µs
in all) to its image lines (1024, 512, 256, 128, 60, 24, 8) and the lines
skipped at the top; a setting not in the table gives the lines per frame
minus `decalage_lignes` (IMG-02). `lignes_par_image > 0` fixes the height. A menu picks **Channel 1** (default, the FLIM channel),
**Channel 2** or **Sum**. The lifetime overlay is a **preview** (each
pixel's mean arrival time minus the IRF's center, pixels under *Min
photons* masked), meant to place ROIs; each ROI drawn, imported or
segmented gets its lifetime fitted on its own decay, rebuilt from the raw
photon stream. Both cards see the same pixels, so a ROI holds for both
channels; the session records the channel its fit used.

## Playback (START, mode "Playback: session" or "Playback: current")

Every Realtime run is a session, under `<recording folder>/sessions/`:
besides `run.toml`, `frames.csv` and the DAQ files, `spc/` holds each
card's FIFO stream (`<serial>.spc`), its `_acquisition.ini` and the
parameters read back from it (`_parametres.ini`), and `irf.csv`/`irf.toml`
the IRF. Playback replays a session through the same SPC engine (its own
instance, never the cards) and the same analysis, with the session's ROIs,
visiting order, IRF and calibration:

- **Playback: session** (default) also reapplies the session's layout
  (binning, Kalman), gains and protocol, to reproduce what happened; editing
  the panels doesn't change the replay.
- **Playback: current** uses the current settings instead, edits applying
  live, to try another binning or Kalman.
- The **PI outputs are simulated**: computed and plotted ("Command —
  simulated (Playback)"), never sent to the DAQ — the recorded stimulation
  doesn't change, so other gains can't show their effect on the cells.
- **Speed**: the frequency box (next to the frame rate) is the target pass
  rate in Hz; 0 replays at the experiment's own pace (1×).

Pick the session with the third folder button, choose the mode, START. It
works on a laptop. Each replay is journaled as `<date>_playback` in the
sessions folder.

**Simulated session**: `julia --project -t 4,1 scripts/simulate_session.jl
[folder] [duration_s]` writes one in the format of a real acquisition
(written by the SPC engine itself: three ROIs, two cards), by default in
`<recording folder>/sessions/simulation_<date>`.

**Without the hardware**: on a computer without the NI-DAQmx driver or the
SPC DLL, the app starts offline — no connection attempt, no fault —, a
banner in the top bar says so, START refuses the Realtime mode and Playback
stays available. On the bench PC, a failed DAQ connection shows "DAQ:
connection failed" and the button becomes **RECONNECT**.

## Debugging at the bench

Every problem the app identifies carries a code (`DAQ-04`, `PASS-02`,
`ROUTE-01`…): the latest one in the top bar, the last ones in the Console
panel, all of them in the **debug log** (`<journal>/debug/<date>_debug.log`:
every message of every thread with its source line and stack trace) and in
the **debug report** (written at the end of every run in its folder, when
the app closes, and with the Console panel's **Debug report** button).
During Realtime and Playback, the app diagnoses every second what the cards
received — photons, M0–M3 markers, pass lengths, routing codes — so a
missing or swapped pass signal, or an unplugged, inverted or stuck routing
line, is named before any lifetime goes wrong. **DEBUGGING.md** lists every
code with what to check.

## Files written

Everything is written during the run, into the session folder: a crash or
a forgotten click loses nothing, and there is no save dialog.

- **SPC acquisitions** (the recording folder, `~/FLIMApp_spc/` by default):
  see "SPC card" above.
- **Sessions** (`<recording folder>/sessions/<date>/`): `run.toml` (mode,
  code versions — FLIMApp version and git commit, FLIMCore, SPCLite, Julia —,
  ROIs with their routing codes and fitted channel, the pixel → galvo
  calibration, the card's settings as sent to the DLL (`spc_module`; QC-104:
  `[qc]` too) and the declared `[dcc]`, the DAQ's sample
  rate and programmed scan, layout, protocol and controller settings),
  `irf.csv` and `irf.toml`, `log.txt`, `frames.csv` (one line per analyzed
  pass: pass number and card times, ROI, setpoint, lifetimes, Kalman
  estimates, PI outputs, why it was kept out of the PI), `visits.csv` and
  `readback.bin` (the DAQ loop's slots), and `spc/` (the cards' streams,
  Realtime only).
- **Journal** (`~/FLIMApp_journal/app.log`): events outside any run.

## Architecture

### Module Dependencies

```
module FLIMApp
    config.jl
        ↓
    data_types.jl   gui_themes.jl   path_utils.jl   smoothing.jl   daq.jl   protocol.jl
        ↓
    plotting.jl
        ↓
    lifetime_analysis.jl
        ↓
    acquisition.jl   session.jl
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

See `src/FLIMApp.jl`'s `include(...)` list for the exact, authoritative order.

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
Maximum Likelihood Estimation fitting for fluorescence decay, plus IRF import (`.sdt` of a Single, one or two channels, kept as CSV) and one fit context per channel:
- Single to 4-exponential decay models
- IRF shift/delay compensation
- Convolution with photon transport
- Iterative optimization using BFGS/L-BFGS-B

#### `daq.jl`
Hardware output through NI-DAQmx (`io/DAQmx.jl`), with the device/channel map
at the top of the file:
- CONNECT/DISCONNECT: device check, reset, zeroing
- ROI galvo scan + port-0 sync lines, hardware-timed on a counter clock and
  looped by the card (waveform built in `roi.jl`)
- PI command outputs (analog, 0–100 % → 0–5 V), refreshed during acquisition

#### `protocol.jl`
Experimental protocol schedule math: converting the protocol UI's times/setpoints into a lookup used during acquisition.

#### `plotting.jl`
Plot-axis autoscaling and plot-series lookup, shared by `runtime.jl` and `GUI.jl`.

#### `acquisition.jl`
The Realtime and Playback analysis worker (`start_realtime`):
- Takes the SPC engine's passes (`FLIMCore.HistoClamp`, one per scan, cut at the cards' M0/M3 markers)
- Finds each pass's ROI from the routing code its photons carry (`pass_roi`)
- Per ROI and channel: sliding-window binning, MLE lifetime fit, Kalman observer; one PI per ROI

#### `runtime.jl`
Background task lifecycle:
- **consumer_loop**: Data streaming and plotting
- **infos_loop**: Status/frequency display
- START/PAUSE/RESUME/STOP button handlers, which launch/tear down the worker,
  consumer, command-output, and infos tasks together

#### `GUI.jl` & `gui_themes.jl`
Makie-based user interface:
- Real-time histogram and fitted curve plots
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
Load IRF (~/.flimapp/irf.csv, imported from the .sdt of a Single)
  ↓
Create GUI ← AppState determines panel/theme
  ↓
Attach handlers ← Channel + Observables connect tasks to GUI
  ↓
Block on display (event loop)
  ↓
On button press → start_pressed()
  ↓
SPC engine (Clamp) + DAQ loop slots + analysis worker (acquisition.jl)
  ↓
Worker takes one pass per scan, fits lifetimes per ROI and channel, one PI per ROI
  ↓
Consumer updates Observables → Plots update reactively
  ↓
On CLEAR press → stop all tasks, close channel
  ↓
Save AppState on exit
```

## Configuration

The SPC card settings ([qc] for the QC-104), the Realtime histogram resolution, the routing
inversion and the SPC data folder live in `config/spc.toml`; the NI wiring
(pass counter) and timing in `config/bench.toml`.

Physics constants and themes live in `src/config.jl`:

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
    ch1::ChannelSeries              # Channel 1 runtime observables
    ch2::ChannelSeries              # Channel 2 runtime observables
    timestamps, command1, ...       # Channel-agnostic observables
```

### Key Analysis Functions

```julia
get_irf()::Matrix{Float64}
    Load the Instrument Response Function from the cached CSV (load_irf).

vec_to_lifetime(x::Vector; kwargs)::Tuple{Vector, Vector{Vector}}
    Fit lifetime parameters to photon histogram.

mle_reconvolution_fit(irf, data; params, gating_function, ...)::Vector
    Maximum Likelihood Estimation fitting with multi-exponential models.

conv_irf_data(x_data, params, irf; ...)::Vector
    Convolve IRF with decay model.

connect_daq()::Union{DaqSession, Nothing}
    Check, reset and zero the NI devices named in daq.jl's hardware map.
```

## Troubleshooting

### "IRF filepath does not exist" / "IRF unreadable" / "IRF refused"
Pick the `.sdt` of a Single measurement of the IRF with the IRF button. It
must be taken with the settings the cards measure with (TAC, CFD and SYNC
thresholds, the same cards) and the detector gains declared in `[dcc]`;
the log lists every difference.

### START does nothing
The info label says why: offline, IRF missing or taken with other
settings, recording folder nearly full, DAQ not ready (CONNECT, RECONNECT,
or RESET after a fault), SPC engine not running (SPC window, CONNECT) or
busy, or more than 15 ROIs.

### Checking the pass signal's wiring
Cable everything, then run `scripts/test_passes.jl` (DEBUGGING.md): the
app's own pass signal, the cards recording all four markers, a verdict per
card — the signal must arrive on M0 (M3 only with `fin_par_m3 = true`),
with the common ground (D GND, pin 15).

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
4. **Becker & Hickl** - SPCM DLL manual (histogram mode, routing, FIFO format)

## License

See LICENSE file in repository root.

## Contact

For issues or questions, contact the development team.
