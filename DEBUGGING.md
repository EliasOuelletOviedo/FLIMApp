# Debugging at the bench

Every problem the app can identify carries a **code** — `DAQ-04`, `PASS-02`,
`ROUTE-01`… — shown in the top bar (the latest one), in the Console panel
(the last ones), in the debug log and in the debug report. To report a
problem, give its code and the line that comes with it ("PASS-02 on card 1:
2346 photons but no M0 edge in 3.0 s"), or send the debug report.

## Where to look

| What | Where |
|---|---|
| Latest problem | top bar of the main window (`⚠ [CODE] …`) |
| Last problems, DAQ loop timing, what the cards received, analysis counters | Console panel (refreshed every second) |
| **Debug log**: every message of every thread, with time, thread, source line and full stack traces | `<journal>/debug/<date>_debug.log` (journal: `[journal] directory` in `config/bench.toml`, `~/FLIMApp_journal` by default); its path is in the Console panel |
| **Debug report**: everything in one file (problems with what to check, DAQ, SPC cards and settings applied, alerts, Realtime counters and their diagnosis, analysis, IRF, settings, both config files, the last 300 log records) | end of every run: `debug_report.txt` in the run's folder; Console panel → **Debug report**; when the app closes: `<journal>/debug/<date>_report.txt` |
| A run's own record | `<recording folder>/sessions/<date>/`: `log.txt`, `frames.csv` (column `excluded_because`), `spc/*_acquisition.ini` (counts of thrown photons, passes off, unpaired) |

## What the app checks by itself

- **At start-up**: threads, NI-DAQmx and SPC DLL (and where they were found),
  both configuration files, the recording folder (space and write access),
  the IRF against the current settings. On CONNECT: the NI devices present
  with their product types, against the ones `config/bench.toml` names.
- **Every DAQ error** says which step failed — which task, which channels,
  which slot — before the DAQmx code; the debug log has the whole DAQmx
  message (task, channel, property).
- **During a Realtime measurement**, every second, from what each card
  received since the start (`FLIMCore.EtatClamp`): photons, M0–M3 edges,
  pass lengths, photons per routing code during passes, thrown and
  out-of-pass photons, GAP records, FIFO overflow, unpaired passes. That
  tells a missing pass signal (PASS-02/03/07), lost or glitching markers (PASS-04),
  swapped edges (PASS-05), routing lines unplugged (ROUTE-01), inverted
  (ROUTE-02) or stuck (ROUTE-03) — before any lifetime is wrong. Playback
  runs the same checks on a recorded session.
- **The analysis**: fits failing per channel, passes piling up, passes kept
  out of the PI and why, passes with an unknown routing code.
- **Any error in a GUI handler** is reported as GUI-01 with the handler's
  source file and line, instead of only scrolling by in the terminal.

## Bench tests (GUI closed: it holds the NI card and the SPC cards)

| Problem | Test | What it tells |
|---|---|---|
| PASS-0x, ROUTE-0x | `julia --project -t 4 scripts/test_passes.jl [s] [--code N] [--borne /X6321/PFIx] [--laser] [--sans-ni]` | The app's own pass counter and a fixed routing code, the cards recording all four markers: per card, the edges on M0, M1, M2, M3, the passes and their length, the code read — and a conclusion per card (signal not arriving, on the wrong input, a missing M3 with fin_par_m3 = true, the code inverted, read as 0, or another code) |
| IMG-0x, image size | `julia -t 4 scripts/spc/horloges_scanner.jl "<scanner setting>" [s]` | The scanner's line and frame clocks, lines per frame, the setting recognized in `reglages_scanner`; with a sample, where the photons fall in the whole frame |

## Problem codes

### Start-up and environment

| Code | Problem | What to check |
|---|---|---|
| ENV-01 | Too few threads | Start Julia with -t 4,1 (scripts/launch.bat does): the DAQ loop, the journal, the analysis and the SPC engine each need a thread. |
| ENV-02 | NI-DAQmx driver not found: running offline | Install NI-DAQmx (nicaiu.dll in System32 on the bench PC). Without it the app runs offline: Playback only. |
| ENV-03 | SPC-150N DLL not found: running offline | Install the Becker & Hickl TCSPC package (spcm64.dll), or set [source] type = "simulation" in config/spc.toml. |
| ENV-04 | Configuration file unreadable: defaults used | Fix the file the message names (a typo, an unknown key, a value out of range); the message says which. |
| ENV-05 | Recording folder: little space left, or not writable | Free space, or pick another recording folder (second path field). The raw stream takes about 4 bytes per photon per card. |
| ENV-06 | Unexpected error at start-up | The debug log has the stack trace; the app may run without the part that failed. |

### NI cards and DAQ loop

| Code | Problem | What to check |
|---|---|---|
| DAQ-01 | NI device not found | The device names in config/bench.toml ([channels]) must match NI MAX; the message lists the devices seen. |
| DAQ-02 | NI device reset or zeroing failed | Another program (NI MAX test panel, LabVIEW) may hold the device: close it, then RECONNECT. |
| DAQ-03 | NI task could not be created or configured | The message names the task, its channels and the DAQmx call: check those channels in config/bench.toml and in NI MAX. |
| DAQ-04 | Pass counter task failed | channels.passes (X6321/ctr1), passes_terminal ("" = PFI13, CTR 1 OUT) and channels.clock in config/bench.toml; no other task may use that counter. |
| DAQ-05 | Missed deadline: the card ran out of written samples | Longer slots or a larger timing.lead_slots (config/bench.toml); the Console panel shows the iteration time, the margin and the garbage-collector pauses. |
| DAQ-06 | Readback fell behind the card | As DAQ-05: the loop was late reading; check the CPU load and the Console panel. |
| DAQ-07 | Scan refused before reaching the card | The message says which limit: galvo range (ROI popup X/Y min/max), more than 15 ROIs, a scan or pause shorter than 2 samples. |
| DAQ-08 | DAQ error during a scan: outputs zeroed (FAULT) | The message gives the step and the DAQmx code; RESET acknowledges it. The debug log has the full DAQmx message. |
| DAQ-09 | DAQ connection failed | The message gives the step and the reason; RECONNECT once fixed. |

### SPC-150N cards and engine

| Code | Problem | What to check |
|---|---|---|
| SPC-01 | SPC cards: initialization failed | SPCM must be closed; the cards must be seen by the PC (chassis powered before the PC); UNLOCK if a crashed session left them locked. |
| SPC-02 | SPC card identity: serial number or channel | [verification] series in config/spc.toml lists the serial of channel 1 then channel 2; the message says which card was found where. |
| SPC-03 | No SYNC on a card | Laser on? SYNC cable to that card; sync_threshold / sync_zc_level in [spc_module]. |
| SPC-04 | CFD rate too low on a card | Detectors on (DCC software: Enable outputs, overload shutdown?), light reaching them, cfd_limit_low in [spc_module]. |
| SPC-05 | A card setting was not applied as requested | The SPC window lists requested → applied; a key unknown to the DLL or out of range in [spc_module]. |
| SPC-06 | SPC engine error | The message gives the step and the DLL function with its code; the debug log has the stack trace. |
| SPC-07 | Photons lost: FIFO overflow (SPC_FOVFL or GAP records) | The passes concerned are kept out of the PI. Count rate too high for the bus, or the engine reading too slowly (CPU load). |
| SPC-08 | ADC comb visible on a decay | Differential nonlinearity of the card's ADC: check the decay in the SPC window; if strong, the card's ADC settings or the card itself. |

### Imaging

| Code | Problem | What to check |
|---|---|---|
| IMG-01 | Imaging: no line or frame clock, no image | Scanner running? Its line clock on M1 and frame clock on M2 of the cards; ligne_/trame_front_montant in [imagerie]. |
| IMG-02 | Scanner setting not in the table: image lines guessed | Measure this setting with scripts/spc/horloges_scanner.jl and add [lines per frame, image lines, top lines] to reglages_scanner in config/spc.toml ([imagerie]). |

### Pass signal (counter → marker M0, and M3 with fin_par_m3)

| Code | Problem | What to check |
|---|---|---|
| PASS-01 | No photon on a card during the Realtime measurement | Laser and detectors on, CFD rate in the top bar, CFD/SYNC thresholds; the 850 nm gate (P0.0) high during scans. |
| PASS-02 | Photons but no M0 marker (start of pass) | The pass signal (PFI13 = CTR 1 OUT) doesn't reach M0 of that card: wiring, common ground (D GND, pin 15). scripts/test_passes.jl shows where it arrives. |
| PASS-03 | M0 markers but no M3 marker (end of pass) | Only with [clamp] fin_par_m3 = true: M3 of that card isn't wired. Without access to M3, set fin_par_m3 = false (M0 only). |
| PASS-04 | Pass markers lost or extra | M0 and M3 counts differ, or (M0 only) M0 missing or off the slot cadence (glitches, ignored): a marginal TTL on the marker inputs (one output feeds every card): ground, cable length, connector. |
| PASS-05 | Pass length M3 − M0 differs from the programmed scan | If it equals the pause, the edges are swapped (M0 must be the rising edge, M3 the falling one); otherwise check the pass counter's clock and the sample rate. |
| PASS-06 | Passes don't pair between the two cards | One card misses markers the other gets: compare their M0 counts (Console panel, debug report). |
| PASS-07 | Pass signal seen on M1/M2 instead of M0/M3 | The pass signal is wired to the line or frame clock inputs: move it to M0 (and M3 with fin_par_m3 = true). |
| PASS-08 | Many photons with a ROI code outside the passes | The routing code and the pass signal are offset in time; normally only a few photons at the edges. |
| PASS-09 | No pass signal generated: the DAQ loop played no slot during the measurement | The DAQ loop must be RUNNING during a Realtime measurement: see its state and any DAQ-0x problem (scan refused, task creation, fault). |

### Routing code (P0.4–P0.7 → R0–R3)

| Code | Problem | What to check |
|---|---|---|
| ROUTE-01 | Photons in passes carry the reserved code 0: no routing code received | P0.4–P0.7 of the NI don't reach R0–R3 of the cards (cable, BOB), or channels.lines doesn't drive port 0. |
| ROUTE-02 | The cards read the inverted routing code | Set inverser_routage the other way in config/spc.toml ([clamp]). |
| ROUTE-03 | A routing line looks stuck | The message names the line (R<b> = P0.<4+b>) and whether it is never or always high: that wire, pin or connector. |
| ROUTE-04 | Photons carry routing codes the NI doesn't write | Lines swapped between NI and cards (bit order), or crosstalk; the message lists the codes seen and written. |
| ROUTE-05 | Passes whose routing code is none of this run's ROIs: not analyzed | See ROUTE-02 to ROUTE-04; the message lists the codes seen. |

### Analysis

| Code | Problem | What to check |
|---|---|---|
| FIT-01 | IRF missing, or taken with other settings | Import the .sdt of a Single taken with the current [spc_module] settings and [dcc] gains (IRF button); the log lists every difference. |
| FIT-02 | Lifetime fits failing | Too few photons per pass, the IRF misaligned with the decays (other TAC settings), or a wrong number of lifetimes. |
| FIT-03 | The analysis can't keep up | Passes pile up: fewer lifetimes, longer scans, or a slower pass rate. |
| FIT-04 | Passes kept out of the PI | The reasons are counted: GAP or FIFO overflow → SPC-07, M3 − M0 → PASS-05. |
| FIT-05 | Analysis worker error | The debug log has the stack trace; the run stopped. |

### GUI

| Code | Problem | What to check |
|---|---|---|
| GUI-01 | Error in a GUI handler | The message gives the handler's source file and line; the debug log has the stack trace. |
| GUI-02 | Error in the display refresh | The debug log has the stack trace; the display may stop updating. |

### Playback

| Code | Problem | What to check |
|---|---|---|
| PLAY-01 | Playback: session unreadable or incomplete | A session folder holds run.toml, irf.csv and spc/*.spc (with their _acquisition.ini). |

### Journal

| Code | Problem | What to check |
|---|---|---|
| JRN-01 | Journal: entries dropped or not written | Disk full or slow, or the journal folder not writable ([journal] directory in config/bench.toml). |
