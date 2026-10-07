"""
session.jl

A session is one run folder of the journal (journal.jl): what Playback
replays. START describes it (`session_info`, written as its run.toml), the
SPC engine records the cards' streams in its spc/, and the journal adds
irf.csv and frames.csv. This file reads a session back (`read_session`)
and makes a simulated one in the same format (`simulate_session`), to try
Playback without the bench.

Playback replays the recorded photon streams through the same SPC engine
and analysis as the Realtime mode, with the session's settings (layout,
gains, IRF, calibration) by default, the current ones on request. It
redoes the estimation (fit, Kalman, PI outputs — simulated: the recorded
stimulation doesn't change, so other gains can't show their effect on the
cells).
"""

using TOML
using Printf

const SESSION_FORMAT = 1

const CODE_VERSIONS = Ref{Union{Nothing, Dict{String, Any}}}(nothing)

"""
    code_versions()::Dict{String, Any}

What code made a session: FLIMApp's version and git commit (with
`git_dirty` when the working tree had uncommitted changes; "" when git or
the repository isn't there, e.g. a built app), FLIMCore's and SPCLite's
versions, Julia's. Computed once.
"""
function code_versions()::Dict{String, Any}
    versions = CODE_VERSIONS[]
    versions === nothing || return versions
    root = something(pkgdir(@__MODULE__), dirname(@__DIR__))
    git(args) = try
        strip(read(pipeline(`git -C $root $args`; stderr = devnull), String))
    catch
        ""
    end
    commit = git(`rev-parse --short HEAD`)
    version = try
        string(something(pkgversion(@__MODULE__), "unknown"))
    catch
        "unknown"
    end
    versions = Dict{String, Any}(
        "flimapp" => version,
        "git_commit" => commit,
        "git_dirty" => !isempty(commit) && !isempty(git(`status --porcelain --untracked-files=no`)),
        "flimcore" => FLIMCore.VERSION_CORE,
        "spclite" => FLIMCore.SPCLite.VERSION_LITE,
        "julia" => string(VERSION)
    )
    CODE_VERSIONS[] = versions
    return versions
end

"""
    session_rois(rois, order, invert)::Vector{Dict{String, Any}}

The ROIs of a session, for its run.toml: drawn index, name, outline (0-based
image pixels, `roi_pixel_mask`), the routing code the cards read for it
(`FLIMCore.code_routage`) and the one the NI writes (`code_ecrit`, NOT of it
when `invert`), and the channel its lifetime was fitted on in the ROI popup
(`fit_channel_name`: a ROI covers the same pixels on both cards). Only the
ROIs of `order` (none without ROIs).
"""
function session_rois(rois::Vector{RoiCoordinates}, order::Vector{Int}, invert::Bool)::Vector{Dict{String, Any}}
    entries = Dict{String, Any}[]
    for k in sort(unique(order))
        code = FLIMCore.code_routage(k)
        push!(entries, Dict{String, Any}(
            "index" => k, "name" => rois[k].name,
            "code_read" => code, "code_written" => Int(FLIMCore.code_ecrit(code, invert)),
            "fit_channel" => fit_channel_name(rois[k]),
            "xs" => rois[k].xs, "ys" => rois[k].ys
        ))
    end
    return entries
end

"""Every field of a settings struct (`LayoutSettings`, `ControllerSettings`, `ProtocolSettings`), by name."""
settings_dict(x)::Dict{String, Any} = Dict{String, Any}(string(f) => getfield(x, f) for f in fieldnames(typeof(x)))

"""
    settings_from_dict(T, d)

A `T` (a `Base.@kwdef` settings struct) with the fields `d` holds
(`settings_dict`, read back from a run.toml); defaults for the others and
for any value of the wrong type (a session written by an older version).
"""
function settings_from_dict(::Type{T}, d::AbstractDict) where {T}
    x = T()
    for (key, value) in d
        field = Symbol(key)
        hasfield(T, field) || continue
        try
            setfield!(x, field, convert(fieldtype(T, field), value))
        catch
        end
    end
    return x
end

"""Samples of `ms` milliseconds at the DAQ loop's rate, as `build_scan_pattern` rounds them."""
samples_of(ms::Real, rate_hz::Real) = round(Int, ms * rate_hz / 1000)

"""
    session_info(; mode, rois, order, roi_active, roi_settings, image_size, spc, spc_settings_path,
                 layout, protocol, controller, irf_source, daq, sample_rate_hz)::Dict{String, Any}

A session's run.toml: mode, code versions, the ROIs with their routing codes
and fitted channel, the pixel -> galvo calibration (voltage range, image
size, calibration reference, `roi_scan_segments`), the SPC settings
([spc_module], declared [dcc], routing), the DAQ (`daq`, plus the sample
rate and the scan and pause in samples — the programmed pass length), the
layout, protocol and controller settings at START (`settings_dict`: what
Playback reapplies by default), and the IRF's source.
"""
function session_info(; mode::AbstractString, rois::Vector{RoiCoordinates}, order::Vector{Int}, roi_active::Bool,
                      roi_settings::RoiSettings, image_size::Tuple{Int, Int}, spc::FLIMCore.Reglages,
                      spc_settings_path::AbstractString = "", layout::LayoutSettings = LayoutSettings(),
                      protocol::ProtocolSettings, controller::ControllerSettings, irf_source::AbstractString = "",
                      daq::Dict{String, Any} = Dict{String, Any}(), sample_rate_hz::Real = 10_000.0)::Dict{String, Any}
    daq = merge(daq, Dict{String, Any}("sample_rate_hz" => Float64(sample_rate_hz),
                                       "scan_samples" => samples_of(protocol.scan_time, sample_rate_hz),
                                       "shift_samples" => samples_of(protocol.shift_time, sample_rate_hz)))
    return Dict{String, Any}(
        "format" => SESSION_FORMAT,
        "mode" => String(mode),
        "started" => timestamp_string(time()),
        "versions" => code_versions(),
        "pi_outputs" => mode == "Playback" ? "simulated: the recorded stimulation doesn't change" : "applied, one PI per ROI",
        "roi" => Dict{String, Any}(
            "active" => roi_active,
            "visit_order" => order,
            "list" => session_rois(rois, order, spc.inverser_routage),
            "drawn" => length(rois),
            "galvo_range_mV" => [roi_settings.v_min_x, roi_settings.v_max_x, roi_settings.v_min_y, roi_settings.v_max_y],
            "image_size" => collect(image_size),
            "calibration_size" => roi_voltage_calibration_size,
            "points_per_roi" => protocol.points_per_roi,
            "spiral_turns" => protocol.spiral_turns
        ),
        "spc" => Dict{String, Any}(
            "settings" => String(spc_settings_path),
            "source" => spc.source,
            "series" => spc.series,
            "canaux" => spc.canaux_clamp,
            "inverser_routage" => spc.inverser_routage,
            "fin_par_m3" => spc.fin_par_m3,
            "code_hors_roi" => FLIMCore.CODE_HORS_ROI,
            "code_sans_roi" => FLIMCore.CODE_SANS_ROI,
            "spc_module" => Dict{String, Any}(FLIMCore.parametres_base(spc)),   # the DLL keys sent (QC-104: [qc] translated)
            "qc" => FLIMCore.est_qc104(spc) ? Dict{String, Any}("plage_tdc_ns" => spc.qc_plage_tdc_ns, "fenetre_ns" => spc.qc_fenetre_ns,
                                                                "seuil_mV" => spc.qc_seuil_mV, "zc_mV" => spc.qc_zc_mV,
                                                                "decalage_ns" => spc.qc_decalage_ns) : Dict{String, Any}(),
            "dcc" => Dict{String, Any}(spc.dcc)
        ),
        "daq" => daq,
        "layout" => settings_dict(layout),
        "protocol" => settings_dict(protocol),
        "controller" => settings_dict(controller),
        "irf_source" => String(irf_source)
    )
end

"""Whether `dir` holds a session Playback can replay: at least one card stream in spc/."""
function is_session_dir(dir::AbstractString)::Bool
    spc = joinpath(dir, "spc")
    return isdir(spc) && any(f -> endswith(lowercase(f), ".spc"), readdir(spc))
end

"""
    Session

A session read back for Playback (`read_session`): its run.toml (`info`,
empty if missing), its ROIs by drawn index (`rois[k]`; the ROIs not listed
are empty outlines), the visiting order (empty without ROIs), the image the
ROIs were drawn on, the IRF of each channel (irf.csv; empty if absent) and
the settings it was taken with (irf.toml).
"""
struct Session
    dir::String
    info::Dict{String, Any}
    rois::Vector{RoiCoordinates}
    roi_order::Vector{Int}
    image_size::Tuple{Int, Int}
    irfs::Vector{Matrix{Float64}}
    irf_info::Dict{String, Any}
end

function read_session(dir::AbstractString)::Session
    is_session_dir(dir) || error("not a session (no card stream in $(joinpath(dir, "spc"))): $dir")
    path = joinpath(dir, "run.toml")
    info = isfile(path) ? TOML.parsefile(path) : Dict{String, Any}()
    roi = get(info, "roi", Dict{String, Any}())
    entries = get(roi, "list", Any[])
    n = max(Int(get(roi, "drawn", 0)), maximum((Int(e["index"]) for e in entries); init = 0))
    rois = [RoiCoordinates("ROI $k", Float64[], Float64[]) for k in 1:n]
    channel_of(name) = name == "channel 1" ? 1 : name == "channel 2" ? 2 : name == "sum" ? 0 : -1
    for e in entries
        rois[Int(e["index"])] = RoiCoordinates(String(e["name"]), Float64.(e["xs"]), Float64.(e["ys"]),
                                               channel_of(get(e, "fit_channel", "")))
    end
    order = get(roi, "active", false) ? Int.(get(roi, "visit_order", Int[])) : Int[]
    dims = Int.(get(roi, "image_size", [1024, 512]))
    irf_path = joinpath(dir, "irf.csv")
    irfs = isfile(irf_path) ? read_irf_csv(irf_path) : Matrix{Float64}[]
    return Session(String(dir), info, rois, order, (dims[1], dims[2]), irfs, read_irf_info(irf_info_path(irf_path)))
end

"""
    session_analysis_settings(session)::AnalysisSettings

The layout (binning, Kalman), controller (gains) and protocol settings the
session was recorded with — what Playback reapplies by default, to
reproduce what happened. Defaults for whatever the run.toml lacks.
"""
function session_analysis_settings(s::Session)::AnalysisSettings
    layout = settings_from_dict(LayoutSettings, get(s.info, "layout", Dict{String, Any}()))
    controller = settings_from_dict(ControllerSettings, get(s.info, "controller", Dict{String, Any}()))
    protocol = settings_from_dict(ProtocolSettings, get(s.info, "protocol", Dict{String, Any}()))
    return AnalysisSettings(layout, controller, normalize_protocol_config(protocol))
end

"""
    session_pass_timing(session) -> (pass_rate_hz, scan_s, sample_s)

The session's passes as programmed: their rate (one per slot), the scan
length and the DAQ's sample period (for the engine's check of M3 − M0;
NaN when the run.toml doesn't say).
"""
function session_pass_timing(s::Session)
    protocol = get(s.info, "protocol", Dict{String, Any}())
    daq = get(s.info, "daq", Dict{String, Any}())
    scan_ms = Float64(get(protocol, "scan_time", get(protocol, "scan_time_ms", NaN)))
    shift_ms = Float64(get(protocol, "shift_time", get(protocol, "shift_time_ms", NaN)))
    rate = Float64(get(daq, "sample_rate_hz", NaN))
    scan_samples = get(daq, "scan_samples", nothing)
    scan_s = scan_samples !== nothing && isfinite(rate) ? scan_samples / rate : scan_ms / 1000
    return 1000 / (scan_ms + shift_ms), scan_s, 1 / rate
end

"""
    playback_speed(target_hz, session)::Float64

The replay speed for a target pass rate (the frequency box): 0 = the
experiment's own pace (1×), otherwise `target_hz` over the session's pass
rate (as fast as the target as long as the analysis keeps up).
"""
function playback_speed(target_hz::Real, s::Session)::Float64
    (isfinite(target_hz) && target_hz > 0) || return 1.0
    rate = session_pass_timing(s)[1]
    return isfinite(rate) && rate > 0 ? target_hz / rate : Float64(target_hz)
end

# -----------------------------------------------------------------------------
# Routing lines, read back
# -----------------------------------------------------------------------------

"""Readback voltage above which a digital line counts as high (TTL)."""
const LINE_HIGH_V = 1.4

"""
    routing_readback(dir; max_s=60)

What the NI really drove on the routing lines during the session in `dir`,
from its readback.bin: the AI channels wired to P0.0 (the gate, high during
scans) and P0.4–P0.7 (`readback_signals` line_0, line_4 … line_7 in
config/bench.toml), over the first `max_s` seconds. Per line: the share of
scan and pause samples where it is high, and its voltage range. The 4-bit
code on P0.7…P0.4 during scans and during pauses (counts per code), and the
code the cards then read (`[clamp] inverser_routage` of the session's
run.toml), next to the codes the run should give them. `nothing` without
readback.bin or without those signals.
"""
function routing_readback(dir::AbstractString; max_s::Real = 60.0)
    txt, bin = joinpath(dir, "readback.txt"), joinpath(dir, "readback.bin")
    (isfile(txt) && isfile(bin)) || return nothing
    signals, rate = String[], NaN
    for line in eachline(txt)
        startswith(line, "signals = ") && (signals = String.(strip.(split(chopprefix(line, "signals = "), ","))))
        startswith(line, "sample_rate_hz = ") && (rate = parse(Float64, chopprefix(line, "sample_rate_hz = ")))
    end
    gate = findfirst(==("line_0"), signals)
    code_lines = [findfirst(==("line_$b"), signals) for b in 4:7]
    (gate === nothing || any(isnothing, code_lines) || !isfinite(rate)) && return nothing
    n_signals = length(signals)
    n = min(filesize(bin) ÷ (4 * n_signals), round(Int, max_s * rate))
    data = Vector{Float32}(undef, n * n_signals)
    open(io -> read!(io, data), bin)
    v = reshape(data, n_signals, n)

    info = isfile(joinpath(dir, "run.toml")) ? TOML.parsefile(joinpath(dir, "run.toml")) : Dict{String, Any}()
    spc = get(info, "spc", Dict{String, Any}())
    invert = Bool(get(spc, "inverser_routage", true))
    roi = get(info, "roi", Dict{String, Any}())
    expected = [Int(e["code_read"]) for e in get(roi, "list", Any[]) if get(roi, "active", false)]
    isempty(expected) && (expected = [Int(get(spc, "code_sans_roi", FLIMCore.CODE_SANS_ROI))])

    scan_codes, pause_codes = Dict{Int, Int}(), Dict{Int, Int}()
    high_scan, high_pause = zeros(Int, 4), zeros(Int, 4)
    vmin, vmax = fill(Inf, 4), fill(-Inf, 4)
    for j in 1:n
        scanning = v[gate, j] > LINE_HIGH_V
        code = 0
        for b in 1:4
            x = v[code_lines[b], j]
            vmin[b], vmax[b] = min(vmin[b], x), max(vmax[b], x)
            x > LINE_HIGH_V || continue
            code |= 1 << (b - 1)
            scanning ? (high_scan[b] += 1) : (high_pause[b] += 1)
        end
        counts = scanning ? scan_codes : pause_codes
        counts[code] = get(counts, code, 0) + 1
    end
    n_scan, n_pause = sum(values(scan_codes); init = 0), sum(values(pause_codes); init = 0)
    visits = joinpath(dir, "visits.csv")                     # one line per slot played, after the header
    slots = isfile(visits) ? max(0, countlines(visits) - 1) : -1
    lines = [(name = "P0.$(b + 3) (R$(b - 1))", scan_high = high_scan[b] / max(1, n_scan), pause_high = high_pause[b] / max(1, n_pause),
              vmin = vmin[b], vmax = vmax[b]) for b in 1:4]
    return (seconds = n / rate, scan_samples = n_scan, pause_samples = n_pause, scan_codes = scan_codes, pause_codes = pause_codes,
            invert = invert, expected = sort(unique(expected)), lines = lines, slots = slots)
end

"""The code the cards read for `written` on P0.7…P0.4 (NOT of it with `invert`: active-low inputs)."""
code_read_from(written::Integer, invert::Bool) = Int(FLIMCore.code_ecrit(written, invert))

"""
    routing_readback_lines(r)::Vector{String}

`routing_readback` as text, ending with what it means: the NI drives the
code the cards should read (then a card that reads another, or 0, loses it
after the BOB: cable, connector, ground), it drives another one, or it
doesn't drive the lines at all — or, the DAQ loop having played slots
(visits.csv) with the gate never high, the readback isn't wired.
"""
function routing_readback_lines(r)::Vector{String}
    r === nothing && return ["no readback.bin with line_0 and line_4…line_7 (bench.toml: [journal] readback, readback_signals)"]
    bits(c) = string(c; base = 2, pad = 4)
    share(counts, c) = round(Int, 100 * get(counts, c, 0) / max(1, sum(values(counts); init = 0)))
    out = [@sprintf("first %.1f s: %d scan samples (P0.0 gate high), %d pause samples; inverser_routage = %s; codes the cards should read during scans: %s",
                    r.seconds, r.scan_samples, r.pause_samples, r.invert, join(r.expected, ", "))]
    for l in r.lines
        push!(out, @sprintf("  %s: high in %.0f %% of the scan samples, %.0f %% of the pause samples; %.2f … %.2f V",
                            l.name, 100 * l.scan_high, 100 * l.pause_high, l.vmin, l.vmax))
    end
    if r.scan_samples == 0
        push!(out, r.slots > 0 ?
            "=> P0.0 (gate) never high, although the DAQ loop played $(r.slots) slot(s): the readback inputs aren't wired to the " *
            "port-0 lines (readback_signals line_0 … line_7 in config/bench.toml; they read about 0 V). Nothing can be said " *
            "about the routing from the readback: see what the cards read (ROUTE-0x, \"in passes by code\")." :
            "=> P0.0 (gate) never high: no scan played, or line_0 isn't read back.")
        return out
    end
    main(counts) = isempty(counts) ? -1 : first(argmax(last, collect(counts)))
    scan, pause = main(r.scan_codes), main(r.pause_codes)
    read_scan, read_pause = code_read_from(scan, r.invert), pause < 0 ? -1 : code_read_from(pause, r.invert)
    push!(out, "  during scans the NI writes $scan ($(bits(scan)) on P0.7…P0.4, $(share(r.scan_codes, scan)) % of them): the cards should read $read_scan")
    pause < 0 || push!(out, "  during pauses it writes $pause ($(bits(pause))): the cards should read $read_pause " *
                            (read_pause == FLIMCore.CODE_HORS_ROI ? "(the reserved code, thrown away)" : "(NOT the reserved code 0)"))
    flat = [l.name for l in r.lines if l.vmax < LINE_HIGH_V]
    if length(flat) == 4
        push!(out, "=> P0.4–P0.7 never high in the readback: the NI doesn't drive them (channels.lines), or their readback isn't wired.")
    elseif read_scan in r.expected && (pause < 0 || read_pause == FLIMCore.CODE_HORS_ROI)
        push!(out, "=> The NI drives the routing code as programmed. A card that reads another code, or 0 (ROUTE-01), loses it after " *
                   "the BOB: the cable or adapter to its routing inputs /R0–/R3, their pins, the common ground.")
    else
        push!(out, "=> The NI doesn't write what the run programs: check channels.lines (port 0, lines 0–7) and readback_signals' order" *
                   (isempty(flat) ? "." : "; never high: $(join(flat, ", "))."))
    end
    return out
end

# -----------------------------------------------------------------------------
# Recording folder
# -----------------------------------------------------------------------------

"""Where the sessions go: `sessions/` in the recording folder (`[enregistrement] dossier`, config/spc.toml)."""
sessions_root(spc::FLIMCore.Reglages)::String = joinpath(FLIMCore.dossier_spc(spc), "sessions")

"""The raw stream: 4 bytes per photon and per card (FIFO_150 records)."""
const BYTES_PER_PHOTON = 4

"""Count rate the free-space estimate assumes, per channel (1 Mcps: 8 MB/s on two channels, about 29 GB/h)."""
const NOMINAL_RATE_CPS = 1e6

"""Below this much recording time, START refuses the Realtime mode; below `RECORDING_WARN_S`, a warning."""
const RECORDING_MIN_S = 10 * 60
const RECORDING_WARN_S = 60 * 60

"""
    recording_space(spc) -> (free_bytes, seconds, text)

Free space where the sessions go (the recording folder, or the nearest
existing folder above it), and how long it lasts at `NOMINAL_RATE_CPS` per
channel of [verification] series (`BYTES_PER_PHOTON` per photon: one
stream per channel, an input of the QC-104 or an SPC-150N). `text` for
the GUI; `free_bytes` is -1 when it can't be read.
"""
function recording_space(spc::FLIMCore.Reglages)
    dir = sessions_root(spc)
    while !isdir(dir) && dirname(dir) != dir
        dir = dirname(dir)
    end
    free = try
        Int(diskstat(dir).available)
    catch
        -1
    end
    free < 0 && return free, NaN, "free space unknown ($(FLIMCore.dossier_spc(spc)))"
    rate = BYTES_PER_PHOTON * NOMINAL_RATE_CPS * max(1, length(spc.series))
    seconds = free / rate
    text = "$(round(free / 1e9; digits = 1)) GB free ≈ $(round(seconds / 3600; digits = 1)) h " *
           "at $(round(Int, NOMINAL_RATE_CPS / 1e6)) Mcps × $(max(1, length(spc.series))) channel(s)"
    return free, seconds, text
end

# -----------------------------------------------------------------------------
# Simulated session
# -----------------------------------------------------------------------------

"""Three round ROIs across a 1024 × 512 image, the default of `simulate_session`."""
function default_simulated_rois()::Vector{RoiCoordinates}
    circle(name, cx, cy, r) = RoiCoordinates(name, [cx + r * cos(a) for a in range(0, 2π; length = 33)[1:32]],
                                                   [cy + r * sin(a) for a in range(0, 2π; length = 33)[1:32]])
    return [circle("Cell 1", 300.0, 200.0, 40.0), circle("Cell 2", 520.0, 300.0, 50.0), circle("Cell 3", 760.0, 220.0, 35.0)]
end

"""Gaussian IRF like the simulated streams' (`FLIMCore.flux_passes_synthetique`), on the analysis resolution."""
function simulated_irf(; center_ns::Real = 1.0, sigma_ns::Real = 0.08, window_ns::Real = LASER_PULSE_PERIOD,
                       n::Integer = DEFAULT_HISTOGRAM_RESOLUTION)::Matrix{Float64}
    bin = window_ns / n
    t = collect(0:n-1) .* bin
    counts = [round(1e4 * exp(-0.5 * ((ti + bin / 2 - center_ns) / sigma_ns)^2)) for ti in t]
    return hcat(t, counts)
end

"""
The lifetime model of `simulate_session` by default: `1.8 + 0.25 code + 0.15
channel` ns, oscillating by ±0.2 ns over 15 s (`t`: seconds from the start
of the first pass).
"""
default_lifetime_model(channel, code, t) = 1.8 + 0.25 * code + 0.15 * channel + 0.2 * sin(2π * t / 15)

"""
    clamp_series_model(; basal_ns=[2.45, 2.50, 2.55], clamp_ns=2.0, basal_s=60, clamp_s=60, return_s=60,
                       clamps=4, tau_s=10, noise_ns=0.05, seed=1)
        -> (; lifetime_ns, protocol, controller, description)

A clamp series on channel 1, for `simulate_session`: `basal_s` of basal
level, then `clamps` times `clamp_s` clamped at `clamp_ns` followed by
`return_s` without setpoint. In ROI `k` (its routing code; ROI 1 without
ROIs), channel 1's lifetime follows a first-order response (time constant
`tau_s`) toward `clamp_ns` during each clamp and back toward its own basal
level `basal_ns[k]` in between, plus white noise of `noise_ns` on each pass
(reproducible: drawn from `seed`, the ROI and the pass time). Channel 2 is
not clamped and doesn't change: `basal_ns[k]`, no noise but the photons'.

`protocol`: the same schedule (delay `basal_s`, then [clamp, return] ×
`clamps`), what the session records and Playback compares with; `controller`:
channel 1's PI on — inverted, since more 1064 nm power lowers the lifetime —
with example gains (P1 = 50 %/ns, I1 = 5 %/(ns·s)), channel 2's off.
"""
function clamp_series_model(; basal_ns::AbstractVector{<:Real} = [2.45, 2.50, 2.55], clamp_ns::Real = 2.0,
                            basal_s::Real = 60, clamp_s::Real = 60, return_s::Real = 60, clamps::Integer = 4,
                            tau_s::Real = 10, noise_ns::Real = 0.05, seed::Integer = 1)
    period = clamp_s + return_s
    clamped(t) = t >= basal_s && t < basal_s + clamps * period && mod(t - basal_s, period) < clamp_s
    # Ends of the segments of constant target: the first-order response is exact within each.
    edges = sort!(unique(vcat([0.0], [basal_s + k * period for k in 0:clamps - 1],
                              [basal_s + k * period + clamp_s for k in 0:clamps - 1])))
    function first_order(basal, t)
        x, a = Float64(basal), 0.0
        for b in vcat(edges[2:end], Inf)
            target = clamped(a) ? Float64(clamp_ns) : Float64(basal)
            stop = min(b, t)
            x = target + (x - target) * exp(-(stop - a) / tau_s)
            t <= b && break
            a = b
        end
        return x
    end
    function noise(code, t)
        a = FLIMCore.Alea(seed * 1_000_003 + 7919 * code + round(Int, 1000 * t))
        u1, u2 = FLIMCore._uniforme!(a), FLIMCore._uniforme!(a)
        return noise_ns * sqrt(-2 * log(1 - u1)) * cos(2π * u2)
    end
    basal(code) = Float64(basal_ns[clamp(code, 1, length(basal_ns))])
    lifetime_ns(channel, code, t) = channel == 1 ? first_order(basal(code), t) + noise(code, t) : basal(code)

    times = fill(NaN, PROTOCOL_STEP_COUNT)
    setpoints = fill(NaN, PROTOCOL_STEP_COUNT)
    times[1:2] .= (clamp_s, return_s)
    setpoints[1] = clamp_ns
    protocol = ProtocolSettings(active = true, delay = round(Int, basal_s), repeats = clamps, times = times, setpoints = setpoints)
    controller = ControllerSettings(ch1_on = true, ch1_inv = true, P1 = 50.0, I1 = 5.0, ch2_on = false)
    description = "clamp series on channel 1: $(basal_s) s basal ($(join(basal_ns, " / ")) ns by ROI), then $clamps × " *
                  "($(clamp_s) s clamped at $(clamp_ns) ns + $(return_s) s return); first order τ = $(tau_s) s, " *
                  "white noise σ = $(noise_ns) ns per pass; channel 2 constant at the basal level"
    return (; lifetime_ns, protocol, controller, description)
end

"""
    simulate_session(dir; rois=default_simulated_rois(), roi_active=true, duration_s=60,
                     scan_s=0.95, pause_s=0.05, photons_per_s=5e4,
                     series=["3N0317", "3N0318"], image_size=(1024, 512),
                     lifetime_ns=default_lifetime_model, protocol=nothing, controller=ControllerSettings(),
                     layout=LayoutSettings(), description=...) -> dir

Make a session in `dir` (new or empty) in the format of a real Realtime
acquisition, for Playback without the bench: run.toml (`session_info`),
irf.csv and irf.toml, and in spc/ the FIFO stream of each card with its
_acquisition.ini and _parametres.ini — written by the SPC engine itself,
recording a replay of simulated streams exactly as it records the cards.
Each card (channel i = `series[i]`) sees `duration_s` of passes of
`scan_s` separated by `pause_s`, one ROI per pass in visiting order (its
routing code on every photon, M0/M3 around each scan; a few photons during
the pauses, with the reserved code). Each pass's lifetime is
`lifetime_ns(channel, code, t)` (`t`: seconds from the start of the first
pass, the time the protocol counts in; `code`: the ROI's drawn index, or
`FLIMCore.CODE_SANS_ROI` without ROIs). `protocol` (scan and pause set from
`scan_s`/`pause_s`), `controller` and `layout` are the settings the
session records — what "Playback: session" reapplies. No frames.csv:
Playback makes its own.
"""
function simulate_session(dir::AbstractString; rois::Vector{RoiCoordinates} = default_simulated_rois(),
                          roi_active::Bool = true, duration_s::Real = 60, scan_s::Real = 0.95, pause_s::Real = 0.05,
                          photons_per_s::Real = 5e4, series::Vector{String} = ["3N0317", "3N0318"],
                          image_size::Tuple{Int, Int} = (1024, 512), lifetime_ns = default_lifetime_model,
                          protocol::Union{Nothing, ProtocolSettings} = nothing,
                          controller::ControllerSettings = ControllerSettings(), layout::LayoutSettings = LayoutSettings(),
                          description::AbstractString = "1.8 + 0.25 code + 0.15 channel + 0.2 sin(2π t / 15 s) ns")
    isdir(dir) && !isempty(readdir(dir)) && error("simulate_session: $dir is not empty")
    roi_active && length(rois) > FLIMCore.ROI_MAX && error("simulate_session: at most $(FLIMCore.ROI_MAX) ROIs")
    order = roi_active && !isempty(rois) ? roi_visit_order(rois) : Int[]
    codes = isempty(order) ? [FLIMCore.CODE_SANS_ROI] : [FLIMCore.code_routage(k) for k in order]
    passes = max(length(codes), round(Int, duration_s / (scan_s + pause_s)))
    spc_dir = joinpath(dir, "spc")
    mkpath(spc_dir)

    first_pass_s = 0.05                    # `flux_passes_synthetique`'s first M0
    flux = Dict{Int, FLIMCore.FluxRejeu}()
    for (i, serial) in enumerate(series)
        words = FLIMCore.flux_passes_synthetique(codes = codes, passes = passes, scan_s = scan_s, pause_s = pause_s,
                                                 photons_par_s = photons_per_s, photons_pause_par_s = photons_per_s / 20,
                                                 graine = 100 + i, debut_s = first_pass_s,
                                                 tau_ns = (code, t) -> lifetime_ns(i, code, t - first_pass_s))
        flux[i - 1] = FLIMCore.FluxRejeu(words, 0x00000000, 25e-9, LASER_PULSE_PERIOD; serie = serial)
    end
    settings = FLIMCore.Reglages(source = "rejeu", series = series, modules_imagerie = collect(0:length(series) - 1),
                                 modules_single = collect(0:length(series) - 1))
    engine = FLIMCore.demarrer_moteur(settings; source = FLIMCore.SourceRejeu(flux; nom = "rejeu", vitesse = 0, boucle = false))
    fin = nothing
    try
        FLIMCore.commander!(engine, FLIMCore.Clamp(rois = order, ordre = order, dossier = spc_dir,
                                                   scan_s = scan_s, pause_s = pause_s, echantillon_s = 1e-4))
        deadline = time() + 600
        while fin === nothing && time() < deadline && FLIMCore.etat_moteur(engine) != :arrete
            while isready(engine.histogrammes)
                take!(engine.histogrammes)
            end
            if isready(engine.resultats)
                r = take!(engine.resultats)
                r isa FLIMCore.Alerte && r.gravite == :erreur && @warn "simulate_session: SPC engine" message=r.texte
                r isa FLIMCore.Fin && r.mesure == :clamp && (fin = r)
                FLIMCore.rendre!(engine, r)
            else
                sleep(0.005)
            end
        end
    finally
        FLIMCore.arreter_moteur(engine)
    end
    fin === nothing && error("simulate_session: the SPC engine didn't finish")
    fin.erreur && error("simulate_session: " * fin.raison)

    irf = simulated_irf()
    write_irf_csv(joinpath(dir, "irf.csv"), [irf for _ in series])
    keys_of_irf = first.(IRF_CARD_SETTINGS)
    write_irf_info(joinpath(dir, "irf.toml"), Dict{String, Any}(
        "source" => "simulated (Gaussian, 1.0 ns, σ 0.08 ns)",
        "channels" => [Dict{String, Any}("serial" => serial,
                                         "settings" => Dict{String, Any}(k => Float64(v) for (k, v) in settings.spc if k in keys_of_irf))
                       for serial in series],
        "dcc" => Dict{String, Any}(settings.dcc)))
    protocol = protocol === nothing ? ProtocolSettings() : deepcopy(protocol)
    protocol.scan_time, protocol.shift_time = round(Int, 1000 * scan_s), round(Int, 1000 * pause_s)
    info = session_info(; mode = "Simulation", rois, order, roi_active, roi_settings = RoiSettings(active = roi_active),
                        image_size, spc = settings, layout, protocol, controller,
                        irf_source = "simulated (Gaussian, 1.0 ns, σ 0.08 ns)",
                        daq = Dict{String, Any}("backend" => "none (simulated session)"), sample_rate_hz = 1e4)
    info["simulation"] = Dict{String, Any}("passes" => passes, "photons_per_s" => photons_per_s,
                                           "lifetime_ns" => String(description), "engine" => fin.raison)
    open(io -> TOML.print(io, info; sorted = true), joinpath(dir, "run.toml"), "w")
    return dir
end
