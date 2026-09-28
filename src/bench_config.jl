"""
bench_config.jl

`BenchConfig`: the bench's hardware wiring, timing, safety limits and
journal settings, read once at startup from a TOML file (config/bench.toml)
rather than kept in `const`s — so a rig change is a file edit, not a code
edit. Immutable once loaded: every thread reads the same values.
"""

using TOML

"""
    default_bench_config_path()::String

The config file shipped with the repository. For a compiled app moved away
from the source tree this may not exist; `load_bench_config` then falls
back to the built-in defaults.
"""
default_bench_config_path()::String = normpath(joinpath(@__DIR__, "..", "config", "bench.toml"))

# Built-in defaults, one entry per key of config/bench.toml (same values).
const BENCH_CONFIG_DEFAULTS = Dict{String, Dict{String, Any}}(
    "hardware" => Dict{String, Any}("backend" => "ni"),
    "channels" => Dict{String, Any}(
        "galvos" => "X6321/ao0:1",
        "lines" => "X6321/port0/line0:7",
        "counter" => "X6321/ctr0",
        "clock" => "/X6321/Ctr0InternalOutput",
        "commands" => "S6110/ao0:1",
        "readback" => "X6321/ai0:11",
        "readback_terminal" => "RSE",
        "readback_signals" => ["galvo_x", "galvo_y", "command_1", "command_2",
                               "line_0", "line_1", "line_2", "line_3",
                               "line_4", "line_5", "line_6", "line_7"],
        "shutter" => ""
    ),
    "timing" => Dict{String, Any}("sample_rate_hz" => 10_000.0, "block_ms" => 20, "lead_slots" => 0),
    "limits" => Dict{String, Any}("galvo_v" => 5.0, "command_full_scale_v" => 5.0, "command_max_v" => 5.0),
    "sync" => Dict{String, Any}("pulse_s" => 0.001),
    "watchdog" => Dict{String, Any}("enabled" => true, "timeout_s" => 1.0, "lines" => "X6321/port0/line0:7"),
    "journal" => Dict{String, Any}("directory" => "", "readback" => true, "queue_capacity" => 4096, "flush_interval_s" => 1.0),
    "display" => Dict{String, Any}("refresh_hz" => 30, "autoscale_interval_s" => 1.0, "max_points_per_line" => 4000)
)

# Signals a readback channel can be wired to (see readback_signals in the TOML).
const READBACK_SIGNAL_NAMES = vcat(["galvo_x", "galvo_y", "command_1", "command_2"], ["line_$b" for b in 0:7])

"""
    BenchConfig

Typed, validated view of config/bench.toml. See that file for what each
field means; `source` records where the values came from.
"""
Base.@kwdef struct BenchConfig
    backend::Symbol
    galvo_channels::String
    line_channels::String
    counter::String
    clock_source::String
    command_channels::String
    readback_channels::String
    readback_terminal::String
    readback_signals::Vector{String}
    shutter_line::String
    sample_rate_hz::Float64
    block_samples::Int
    lead_slots::Int
    galvo_limit_v::Float64
    command_full_scale_v::Float64
    command_max_v::Float64
    sync_pulse_s::Float64
    watchdog_enabled::Bool
    watchdog_timeout_s::Float64
    watchdog_lines::String
    journal_directory::String
    journal_readback::Bool
    journal_capacity::Int
    journal_flush_s::Float64
    refresh_hz::Float64
    autoscale_interval_s::Float64
    max_points_per_line::Int
    source::String
end

"""
    load_bench_config(path=default_bench_config_path())::BenchConfig

Read `path` over the built-in defaults and validate the result. A missing
file gives the defaults (with a warning); an unreadable file or an invalid
value throws, since running the bench on a half-understood config is worse
than not starting.
"""
function load_bench_config(path::AbstractString = default_bench_config_path())::BenchConfig
    raw = if isfile(path)
        TOML.parsefile(path)
    else
        @warn "Bench config file not found; using built-in defaults" path=path
        Dict{String, Any}()
    end
    return bench_config_from_dict(raw; source = isfile(path) ? abspath(path) : "defaults")
end

"""
    bench_config_from_dict(raw; source="dict")::BenchConfig

Build a `BenchConfig` from a parsed TOML dictionary, section by section
over `BENCH_CONFIG_DEFAULTS`. Unknown sections or keys are rejected, so a
typo can't silently leave a default in place.
"""
function bench_config_from_dict(raw::AbstractDict; source::AbstractString = "dict")::BenchConfig
    merged = Dict(section => copy(values) for (section, values) in BENCH_CONFIG_DEFAULTS)
    for (section, values) in raw
        haskey(merged, section) || error("bench config: unknown section [$section]")
        values isa AbstractDict || error("bench config: [$section] must be a table")
        for (key, value) in values
            haskey(merged[section], key) || error("bench config: unknown key $key in [$section]")
            merged[section][key] = value
        end
    end

    get_value(section, key) = merged[section][key]

    backend = Symbol(lowercase(String(get_value("hardware", "backend"))))
    backend in (:ni, :simulation) || error("bench config: hardware.backend must be \"ni\" or \"simulation\", got \"$backend\"")

    rate = Float64(get_value("timing", "sample_rate_hz"))
    rate > 0 || error("bench config: timing.sample_rate_hz must be positive")
    block = round(Int, Float64(get_value("timing", "block_ms")) * rate / 1000)
    block >= 1 || error("bench config: timing.block_ms is shorter than one sample")
    lead = Int(get_value("timing", "lead_slots"))
    (lead == 0 || lead >= 2) || error("bench config: timing.lead_slots must be 0 (automatic) or at least 2")

    signals = String.(get_value("channels", "readback_signals"))
    unknown = setdiff(signals, READBACK_SIGNAL_NAMES)
    isempty(unknown) || error("bench config: unknown readback signal(s) $(join(unknown, ", ")); expected any of $(join(READBACK_SIGNAL_NAMES, ", "))")
    isempty(signals) && error("bench config: channels.readback_signals is empty — the loop is paced by the readback")

    terminal = String(get_value("channels", "readback_terminal"))
    terminal in ("RSE", "NRSE", "Diff", "PseudoDiff", "Default") ||
        error("bench config: channels.readback_terminal must be RSE, NRSE, Diff, PseudoDiff or Default")

    positive(section, key) = (v = Float64(get_value(section, key)); v > 0 ? v : error("bench config: $section.$key must be positive"))

    return BenchConfig(
        backend = backend,
        galvo_channels = String(get_value("channels", "galvos")),
        line_channels = String(get_value("channels", "lines")),
        counter = String(get_value("channels", "counter")),
        clock_source = String(get_value("channels", "clock")),
        command_channels = String(get_value("channels", "commands")),
        readback_channels = String(get_value("channels", "readback")),
        readback_terminal = terminal,
        readback_signals = signals,
        shutter_line = String(get_value("channels", "shutter")),
        sample_rate_hz = rate,
        block_samples = block,
        lead_slots = lead,
        galvo_limit_v = positive("limits", "galvo_v"),
        command_full_scale_v = positive("limits", "command_full_scale_v"),
        command_max_v = positive("limits", "command_max_v"),
        sync_pulse_s = positive("sync", "pulse_s"),
        watchdog_enabled = Bool(get_value("watchdog", "enabled")),
        watchdog_timeout_s = positive("watchdog", "timeout_s"),
        watchdog_lines = String(get_value("watchdog", "lines")),
        journal_directory = String(get_value("journal", "directory")),
        journal_readback = Bool(get_value("journal", "readback")),
        journal_capacity = max(16, Int(get_value("journal", "queue_capacity"))),
        journal_flush_s = positive("journal", "flush_interval_s"),
        refresh_hz = positive("display", "refresh_hz"),
        autoscale_interval_s = positive("display", "autoscale_interval_s"),
        max_points_per_line = max(100, Int(get_value("display", "max_points_per_line"))),
        source = String(source)
    )
end

"""
    bench_devices(cfg::BenchConfig)::Vector{String}

Every NI device the channel map refers to.
"""
function bench_devices(cfg::BenchConfig)::Vector{String}
    specs = filter(!isempty, [cfg.galvo_channels, cfg.line_channels, cfg.counter, cfg.command_channels,
                              cfg.readback_channels, cfg.shutter_line])
    return unique([String(first(split(lstrip(spec, '/'), '/'))) for spec in specs])
end

"""
    journal_root(cfg::BenchConfig)::String

Directory holding one sub-folder per run (plus the app-wide log).
"""
journal_root(cfg::BenchConfig)::String = isempty(cfg.journal_directory) ? joinpath(homedir(), "FLIMApp_journal") : expanduser(cfg.journal_directory)
