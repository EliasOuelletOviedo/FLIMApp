"""
lifetime_analysis.jl

Fluorescence lifetime fitting and IRF (Instrument Response Function)
management: IRF loading, IRF-decay convolution, and MLE fitting of
multi-exponential decays (1, 2, 3+ lifetimes).

References: Bajzer et al. 1991 (MLE methodology); Maus et al. 2001 (MLE for
FLIM); Enderlein 1997 (IRF shift/delay compensation).
"""

using FFTW
using Dates
using TOML
using Statistics
using NativeFileDialog
using Optim
using LineSearches
using LinearAlgebra: mul!

const X_DATA_CACHE = Dict{Tuple{Int, Float64}, Vector{Float64}}()
const GATING_CACHE = Dict{Tuple{Int, Int, Int}, Vector{UInt8}}()
const IRF_CHANNEL_CACHE = Dict{Tuple{UInt, Int}, Matrix{Float64}}()   # (objectid(irf), channels)

# -----------------------------------------------------------------------------
# Helpers IRF
# -----------------------------------------------------------------------------

"""
The card settings an IRF depends on, as [spc_module] names them, and how
each is read from a .sdt's measurement description: the TAC (the time axis)
and the CFD and SYNC thresholds (the timing of each photon and of the
laser pulse).
"""
const IRF_CARD_SETTINGS = (
    ("tac_range", mi -> Float64(mi.tac_r) * 1e9),        # s in the .sdt, ns for the DLL
    ("tac_gain", mi -> Float64(mi.tac_g)),
    ("tac_offset", mi -> Float64(mi.tac_of)),
    ("tac_limit_low", mi -> Float64(mi.tac_ll)),
    ("tac_limit_high", mi -> Float64(mi.tac_lh)),
    ("cfd_limit_low", mi -> Float64(mi.cfd_ll)),
    ("cfd_limit_high", mi -> Float64(mi.cfd_lh)),
    ("cfd_zc_level", mi -> Float64(mi.cfd_zc)),
    ("sync_threshold", mi -> Float64(mi.syn_th)),
    ("sync_zc_level", mi -> Float64(mi.syn_zc)),
    ("sync_freq_div", mi -> Float64(mi.syn_fd)),
)

"""
The SPC-QC-104 settings an IRF depends on, as the DLL names them
(`FLIMCore.parametres_base`: cfd_limit_high is IN2's threshold…): the
thresholds and zero levels of the inputs and of the SYNC, the TDC offsets
(they shift the decay), the TDC range — and `fenetre_ns`, the window the
TDC channels are resampled onto ([qc] fenetre_ns): the time axis.
"""
const IRF_QC_SETTINGS = ("cfd_limit_low", "cfd_limit_high", "cfd_zc_level", "sync_threshold",
                         "tac_limit_high", "sync_holdoff", "cfd_holdoff", "sync_zc_level",
                         "tdc_offset1", "tdc_offset2", "tdc_offset3", "tdc_offset4",
                         "tac_range", "sync_freq_div", "fenetre_ns")

"""Integer settings, compared exactly; the others within 2 % or 0.5 (the DLL rounds them to its steps)."""
const IRF_EXACT_SETTINGS = ("tac_gain", "sync_freq_div")

"""
The settings an IRF is compared on, as the current configuration requests
them: the QC-104's ([qc], as `parametres_base` sends them, plus
`fenetre_ns`), or [spc_module] for the SPC-150N.
"""
function irf_requested_settings(spc::FLIMCore.Reglages)::Dict{String, Float64}
    if FLIMCore.est_qc104(spc)
        base = FLIMCore.parametres_base(spc)
        out = Dict{String, Float64}(k => Float64(base[k]) for k in IRF_QC_SETTINGS if haskey(base, k) && base[k] isa Real)
        out["fenetre_ns"] = spc.qc_fenetre_ns
        return out
    end
    return Dict{String, Float64}(k => Float64(v) for (k, v) in spc.spc if v isa Real)
end

same_card_setting(key, a::Real, b::Real) =
    key in IRF_EXACT_SETTINGS ? round(Int, a) == round(Int, b) : abs(a - b) <= max(0.5, 0.02 * abs(b))

"""
    read_sdt_irf(filepath; series=String[]) -> (irfs, channels)

IRF from a Single measurement saved by SPCM as .sdt: one histogram per
channel (one data block, or two for two channels; a block holding several
curves is summed). Blocks are ordered by their card's serial number as
`series` ([verification] series: channel 1, then 2) lists them, in file
order otherwise. For each, the median is subtracted as background and
negative counts clipped; a curve with a multiple of
`DEFAULT_HISTOGRAM_RESOLUTION` channels (a 12-bit Single has 4096) is
summed down to that resolution, the Realtime histograms'. The channel width
comes from the block's measurement description (TAC range / gain / ADC
resolution), 12.5 ns / channels if that isn't usable.

`irfs`: `[t_ns counts]` per channel, `t_ns` the start of each channel from
0. `channels`: per channel, the card's serial number and the settings it
measured with (`IRF_CARD_SETTINGS`), for `irf_mismatches`.
"""
function read_sdt_irf(filepath::AbstractString; series::AbstractVector{<:AbstractString} = String[])
    sdt = SdtFile.read_sdt(read(filepath), basename(filepath))
    isempty(sdt.data) && error("SDT file has no data block: $filepath")
    isempty(sdt.measure_info) && error("SDT file has no measurement description: $filepath")
    info_of(b) = sdt.measure_info[clamp(sdt.blocks[b].meas_desc_block_no + 1, 1, length(sdt.measure_info))]
    blocks = collect(eachindex(sdt.data))
    serials = [strip(info_of(b).mod_ser_no) for b in blocks]
    if !isempty(series) && all(in(series), serials)
        blocks = blocks[sortperm([findfirst(==(x), series) for x in serials])]
    end

    irfs = Matrix{Float64}[]
    channels = Dict{String, Any}[]
    for b in blocks[1:min(2, length(blocks))]
        block, mi = sdt.data[b], info_of(b)
        n_adc = Int(mi.adc_re)
        n_adc > 0 || error("SDT file: ADC resolution is $n_adc ($filepath)")
        bin_ns = Float64(mi.tac_r) / max(Int(mi.tac_g), 1) / n_adc * 1e9
        (isfinite(bin_ns) && 0 < bin_ns * n_adc <= 1000) || (bin_ns = LASER_PULSE_PERIOD / n_adc)
        # SdtFile shapes a block (curves…, channels): time is the last axis.
        size(block, ndims(block)) == n_adc ||
            error("SDT file: a block of size $(size(block)) is not $n_adc-channel curves ($filepath)")
        counts = vec(sum(reshape(Float64.(block), :, n_adc); dims = 1))
        counts .-= round(median(counts))
        counts[counts .<= 0] .= 0
        n, width = length(counts), bin_ns
        resolution = DEFAULT_HISTOGRAM_RESOLUTION
        if n > resolution && n % resolution == 0
            group = n ÷ resolution
            counts = [sum(@view counts[(k - 1) * group + 1:k * group]) for k in 1:resolution]
            width *= group
            n = resolution
        end
        sum(counts) > 0 || error("SDT file: an empty IRF curve ($filepath)")
        push!(irfs, hcat(collect(0:n-1) .* width, counts))
        push!(channels, Dict{String, Any}("serial" => String(strip(mi.mod_ser_no)),
                                          "settings" => Dict{String, Any}(k => f(mi) for (k, f) in IRF_CARD_SETTINGS)))
    end
    return irfs, channels
end

"""
    irf_mismatches(info, spc; applied=Dict{Int, Dict{String, Float64}}())::Vector{String}

What differs between the settings an IRF was taken with (`info`, recorded by
`import_irf`) and the ones the cards measure with: per channel, the card
(serial number against [verification] series: "3T0089/IN1" for an input of
the QC-104) and its timing settings (`IRF_CARD_SETTINGS` for the SPC-150N,
`IRF_QC_SETTINGS` for the QC-104) — as read back from that channel's card
when `applied[channel]` has them (the last check of the cards), as `spc`
requests them otherwise (`irf_requested_settings`) —, and the detector gains
declared in [dcc]: the transit time changes with the high voltage, which
the GUI can't read, so the declared values are compared. Empty: the IRF is
valid. An IRF without its record is refused.
"""
function irf_mismatches(info::AbstractDict, spc::FLIMCore.Reglages;
                        applied::AbstractDict = Dict{Int, Dict{String, Float64}}())::Vector{String}
    isempty(info) && return ["the IRF has no record of the settings it was taken with: import its .sdt again"]
    fmt(x) = x isa Real ? string(round(Float64(x); sigdigits = 5)) : string(x)
    out = String[]
    requested = irf_requested_settings(spc)
    for (c, channel) in enumerate(get(info, "channels", Any[]))
        serial = String(get(channel, "serial", ""))
        expected = c <= length(spc.series) ? spc.series[c] : ""
        !isempty(serial) && !isempty(expected) && serial != expected &&
            push!(out, "channel $c: IRF from card $serial, but channel $c is card $expected")
        reference = get(applied, c, requested)
        for (key, value) in get(channel, "settings", Dict{String, Any}())
            now = get(reference, key, get(requested, key, nothing))
            now === nothing && continue
            same_card_setting(key, value, now) ||
                push!(out, "channel $c: $key = $(fmt(value)) for the IRF, $(fmt(now)) now")
        end
    end
    declared = get(info, "dcc", Dict{String, Any}())
    for (key, value) in spc.dcc
        occursin("gain", key) || continue
        old = get(declared, key, nothing)
        if old === nothing
            push!(out, "detector: $key wasn't declared ([dcc]) when the IRF was imported")
        elseif !(isequal(old, value) || (old isa Real && value isa Real && isapprox(old, value; atol = 1e-6)))
            push!(out, "detector: $key = $(fmt(old)) for the IRF, $(fmt(value)) now ([dcc] in config/spc.toml)")
        end
    end
    return out
end

"""
    write_irf_csv(path, irfs)

The IRF as kept between sessions and in each session's journal: `time_ns`,
then one counts column per channel (`ch1`, `ch2`).
"""
function write_irf_csv(path::AbstractString, irfs::AbstractVector{<:AbstractMatrix})
    mkpath(dirname(path))
    open(path, "w") do io
        println(io, join(["time_ns"; ["ch$c" for c in eachindex(irfs)]], ","))
        for k in axes(irfs[1], 1)
            println(io, join([irfs[1][k, 1]; [irf[k, 2] for irf in irfs]], ","))
        end
    end
    return path
end

"""Read `write_irf_csv`'s file back: one `[t_ns counts]` matrix per channel."""
function read_irf_csv(path::AbstractString)::Vector{Matrix{Float64}}
    lines = filter(!isempty, strip.(readlines(path)))
    length(lines) >= 3 || error("IRF file has fewer than two rows: $path")
    rows = [parse.(Float64, split(l, ",")) for l in lines[2:end]]
    times = [r[1] for r in rows]
    return [hcat(times, [r[c] for r in rows]) for c in 2:length(rows[1])]
end

"""The record of an IRF's settings, next to its CSV (`irf.csv` → `irf.toml`)."""
irf_info_path(csv_path::AbstractString) = string(splitext(csv_path)[1], ".toml")

write_irf_info(path::AbstractString, info::AbstractDict) =
    (mkpath(dirname(path)); open(io -> TOML.print(io, info; sorted = true), path, "w"); path)

read_irf_info(path::AbstractString)::Dict{String, Any} = isfile(path) ? TOML.parsefile(path) : Dict{String, Any}()

"""
    load_irfs(spc; ask=true) -> (irfs, info)

The IRF of each channel and the record of its settings: `irf_csv_path()`
(and its .toml) when it exists, otherwise imported from the Single (.sdt of
SPCM, or .csv of the SPC window) whose path is cached
(`irf_filepath_cache()`) — or, with `ask`, picked in a dialog — through
`import_irf`.
"""
function load_irfs(spc::FLIMCore.Reglages; ask::Bool = true)
    csv = irf_csv_path()
    isfile(csv) && return read_irf_csv(csv), read_irf_info(irf_info_path(csv))
    cache_path = irf_filepath_cache()
    filepath = isfile(cache_path) ? strip(read(cache_path, String)) : ""
    if !isfile(filepath)
        ask || error("no IRF yet: pick the Single measurement of the IRF (.csv of the SPC window, or .sdt of SPCM)")
        filepath = pick_file(filterlist = "csv,sdt")
        isempty(filepath) && error("no IRF file picked")
    end
    return import_irf(filepath, spc)
end

"""
    import_irf(filepath, spc; applied=Dict()) -> (irfs, info)

Import an IRF from a Single measurement: the SPC window's (one CSV per
channel, `import_irf_single`) or SPCM's .sdt (`import_irf_sdt`: for the
QC-104, `read_sdt_irf_qc`), by the file's extension.
"""
import_irf(filepath::AbstractString, spc::FLIMCore.Reglages; applied::AbstractDict = Dict{Int, Dict{String, Float64}}()) =
    endswith(lowercase(filepath), ".csv") ? import_irf_single(filepath, spc; applied) : import_irf_sdt(filepath, spc; applied)

"""
    read_single_irf(filepath; series) -> (irfs, channels)

IRF from a Single of the SPC window: `<date>_module<k>.csv`, one per card
(QC-104: per input), with `<date>_module<k>_parametres.ini` (the settings
read back from the card) next to it. `filepath` is any of them: all the
CSVs of that Single are read, ordered as `series` lists their serials
("serie = …" in each CSV's header). Like `read_sdt_irf`: the median
subtracted, negative counts clipped, summed down to
`DEFAULT_HISTOGRAM_RESOLUTION` channels if finer; `channels` records each
one's serial and the settings it was taken with (the keys of
`IRF_CARD_SETTINGS` and `IRF_QC_SETTINGS`, plus `fenetre_ns`, the
window).
"""
function read_single_irf(filepath::AbstractString; series::AbstractVector{<:AbstractString} = String[])
    m = match(r"^(.*)_module\d+\.csv$", basename(filepath))
    m === nothing && error("not a Single of the SPC window (<date>_module<k>.csv): $filepath")
    dir = dirname(filepath)
    files = sort([joinpath(dir, f) for f in readdir(dir) if occursin(Regex("^" * m[1] * "_module\\d+\\.csv\$"), f)])
    keys_of_irf = union(first.(IRF_CARD_SETTINGS), IRF_QC_SETTINGS)
    found = Dict{String, Tuple{Matrix{Float64}, Dict{String, Any}}}()
    order = String[]
    for f in files
        serial, rows = "", Vector{Float64}[]
        for line in eachline(f)
            if startswith(line, "#")
                h = match(r"^#\s*serie = (.*)$", line)
                h === nothing || (serial = String(strip(h[1])))
            elseif !startswith(line, "canal")
                isempty(strip(line)) || push!(rows, parse.(Float64, split(line, ",")))
            end
        end
        length(rows) >= 2 || error("Single CSV without data: $f")
        bin_ns = rows[2][2] - rows[1][2]
        counts = [r[end] for r in rows]                        # the "somme" column: every histogram of the series
        counts .-= round(median(counts))
        counts[counts .<= 0] .= 0
        n, width, resolution = length(counts), bin_ns, DEFAULT_HISTOGRAM_RESOLUTION
        if n > resolution && n % resolution == 0
            group = n ÷ resolution
            counts = [sum(@view counts[(k - 1) * group + 1:k * group]) for k in 1:resolution]
            width *= group
            n = resolution
        end
        sum(counts) > 0 || error("Single CSV: an empty IRF curve ($f)")
        ini = replace(f, r"\.csv$" => "_parametres.ini")
        read_back = isfile(ini) ? FLIMCore.SPCLite.lire_ini(ini) : Dict{String, Float64}()
        settings = Dict{String, Any}(k => v for (k, v) in read_back if k in keys_of_irf)
        settings["fenetre_ns"] = width * n
        key = isempty(serial) ? basename(f) : serial
        found[key] = (hcat(collect(0:n-1) .* width, counts), Dict{String, Any}("serial" => serial, "settings" => settings))
        push!(order, key)
    end
    if !isempty(series) && all(in(order), series)
        order = String.(series)
    end
    order = order[1:min(2, length(order))]
    return [found[k][1] for k in order], [found[k][2] for k in order]
end

"""
    import_irf_single(filepath, spc; applied=Dict()) -> (irfs, info)

`import_irf_sdt` for a Single of the SPC window (`read_single_irf`): the
way to take the IRF with the QC-104, whose TDC channels the app resamples
onto [qc] fenetre_ns exactly as for the Realtime decays.
"""
function import_irf_single(filepath::AbstractString, spc::FLIMCore.Reglages;
                           applied::AbstractDict = Dict{Int, Dict{String, Float64}}())
    irfs, channels = read_single_irf(filepath; series = spc.series)
    return save_imported_irf(irfs, channels, filepath, spc; applied)
end

"""
    import_irf_sdt(filepath, spc; applied=Dict()) -> (irfs, info)

Import an IRF .sdt (a Single measurement): refused — with every difference
in the error — unless it was taken with the settings the cards measure with
(`irf_mismatches`, the detector gains being those declared in [dcc] now).
Kept as `irf_csv_path()`, with the record of its settings next to it.
"""
function import_irf_sdt(filepath::AbstractString, spc::FLIMCore.Reglages;
                        applied::AbstractDict = Dict{Int, Dict{String, Float64}}())
    irfs, channels = FLIMCore.est_qc104(spc) ? read_sdt_irf_qc(filepath, spc) : read_sdt_irf(filepath; series = spc.series)
    return save_imported_irf(irfs, channels, filepath, spc; applied)
end

"""
    rebin_counts(counts, from_ns, to_ns, n) -> Vector{Float64}

Counts in bins of `from_ns` (from 0) spread onto `n` bins of `to_ns` (from
0) in proportion to their overlap; what falls beyond `n × to_ns` is
dropped. Keeps the total within the new range.
"""
function rebin_counts(counts::AbstractVector{<:Real}, from_ns::Real, to_ns::Real, n::Integer)
    out = zeros(Float64, n)
    for (i, c) in enumerate(counts)
        c == 0 && continue
        a, b = (i - 1) * from_ns, i * from_ns
        for j in floor(Int, a / to_ns) + 1:min(n, floor(Int, b / to_ns) + 1)
            lo, hi = max(a, (j - 1) * to_ns), min(b, j * to_ns)
            hi > lo && (out[j] += c * (hi - lo) / from_ns)
        end
    end
    return out
end

"""The value of `SP_<key>` in a .sdt's setup text (what its measurement description lacks), NaN if absent."""
function sdt_setup_value(setup::AbstractString, key::AbstractString)::Float64
    m = match(Regex("\\[SP_" * key * ",[A-Z],([-+0-9.eE]+)\\]"), setup)
    return m === nothing ? NaN : parse(Float64, m[1])
end

"""
    read_sdt_irf_qc(filepath, spc) -> (irfs, channels)

IRF of the SPC-QC-104 from SPCM Single(s) saved as .sdt: one block, one
curve per input (IN1, IN2, IN3). Channel k takes the curve of its input
([verification] series: "3T0089/IN2" → curve 2) from the picked file — or,
when that curve is empty there, from the same name with its last number
replaced by k (irf_ch1.sdt, irf_ch2.sdt: one detector per measurement).
Its TDC channels (`tac_range / adc_resolution`: 64 ps for 256 points) are
spread by overlap onto [qc] fenetre_ns in `DEFAULT_HISTOGRAM_RESOLUTION`
channels, the Realtime decays' axis (`rebin_counts`); then, as in
`read_sdt_irf`, the median is subtracted and negative counts clipped. A
256-point Single blurs a sharp IRF over two 49 ps channels: 4096 points
(4 ps) or the SPC window's Single keep it sharp. `channels`: the serial
("3T0089/IN1") and the settings in the DLL's names (`IRF_QC_SETTINGS`; the
zero levels of IN2 and IN3 and the TDC offsets from SPCM's setup text),
plus `fenetre_ns`.
"""
function read_sdt_irf_qc(filepath::AbstractString, spc::FLIMCore.Reglages)
    window, n = spc.qc_fenetre_ns, DEFAULT_HISTOGRAM_RESOLUTION
    stem, ext = splitext(basename(filepath))
    last_number = match(r"(\d+)(\D*)$", stem)
    sibling(k) = last_number === nothing ? "" :
                 joinpath(dirname(filepath), stem[1:last_number.offset - 1] * string(k) * last_number[2] * ext)
    irfs = Matrix{Float64}[]
    channels = Dict{String, Any}[]
    for (k, serial) in enumerate(spc.series[1:min(2, length(spc.series))])
        voie = FLIMCore.voie_qc(serial)
        voie === nothing && error("[verification] series: \"$serial\" isn't an input of the QC-104 (\"3T0089/IN1\")")
        found = nothing
        for f in unique(filter(isfile, [String(filepath), sibling(k)]))
            sdt = SdtFile.read_sdt(read(f), basename(f))
            isempty(sdt.data) && continue
            mi = sdt.measure_info[clamp(sdt.blocks[1].meas_desc_block_no + 1, 1, length(sdt.measure_info))]
            occursin("QC", uppercase(String(mi.mod_type))) ||
                error("$(basename(f)) was taken with a $(strip(String(mi.mod_type))), not the SPC-QC-104 ([source] type = \"qc104\")")
            block = sdt.data[1]
            n_adc = size(block, ndims(block))
            curves = reshape(Float64.(block), :, n_adc)
            size(curves, 1) >= voie.entree || continue
            curve = vec(curves[voie.entree, :])
            sum(curve) > 0 || continue
            found = (f, mi, sdt.setup, curve, Float64(mi.tac_r) / max(Int(mi.tac_g), 1) / n_adc * 1e9)
            break
        end
        found === nothing &&
            error("no counts on IN$(voie.entree) (channel $k) in $(basename(filepath))" *
                  (isempty(sibling(k)) ? "" : " nor in $(basename(sibling(k)))"))
        f, mi, setup, curve, bin_ns = found
        (isfinite(bin_ns) && bin_ns > 0) || error("$(basename(f)): TDC range $(mi.tac_r) s, $(length(curve)) points")
        counts = rebin_counts(curve, bin_ns, window / n, n)
        counts .-= round(median(counts))
        counts[counts .<= 0] .= 0
        sum(counts) > 0 || error("$(basename(f)): an empty IRF curve on IN$(voie.entree) within [qc] fenetre_ns")
        push!(irfs, hcat(collect(0:n-1) .* (window / n), counts))
        settings = Dict{String, Any}(
            "cfd_limit_low" => mi.cfd_ll, "cfd_limit_high" => mi.cfd_lh, "cfd_zc_level" => mi.cfd_zc,
            "sync_threshold" => mi.syn_th, "tac_limit_high" => mi.tac_lh, "sync_zc_level" => mi.syn_zc,
            "sync_freq_div" => mi.syn_fd, "tac_range" => Float64(mi.tac_r) * 1e9,
            "sync_holdoff" => sdt_setup_value(setup, "SYN_HF"), "cfd_holdoff" => sdt_setup_value(setup, "CFD_HF"),
            "tdc_offset1" => sdt_setup_value(setup, "TDC_OF1"), "tdc_offset2" => sdt_setup_value(setup, "TDC_OF2"),
            "tdc_offset3" => sdt_setup_value(setup, "TDC_OF3"), "tdc_offset4" => sdt_setup_value(setup, "TDC_OF4"),
            "fenetre_ns" => window)
        filter!(kv -> isfinite(Float64(kv[2])), settings)
        push!(channels, Dict{String, Any}("serial" => String(serial), "settings" => Dict{String, Any}(k => Float64(v) for (k, v) in settings),
                                          "file" => basename(f)))
    end
    return irfs, channels
end

"""Check an imported IRF against the current settings (`irf_mismatches`), then keep it as `irf_csv_path()` with its record."""
function save_imported_irf(irfs, channels, filepath::AbstractString, spc::FLIMCore.Reglages; applied::AbstractDict)
    info = Dict{String, Any}("source" => String(filepath), "imported" => Dates.format(Dates.now(), dateformat"yyyy-mm-ddTHH:MM:SS"),
                             "channels" => channels, "dcc" => Dict{String, Any}(spc.dcc))
    mismatches = irf_mismatches(info, spc; applied)
    isempty(mismatches) || error("IRF taken with other settings: " * join(mismatches, "; "))
    write_irf_csv(irf_csv_path(), irfs)
    write_irf_info(irf_info_path(irf_csv_path()), info)
    set_path_cache!(irf_filepath_cache(), filepath)
    return irfs, info
end

"""The IRF of a file, by its kind: a Single's CSV, an SPCM .sdt of the QC-104, or of SPC-150N."""
function read_irf_file(filepath::AbstractString, spc::FLIMCore.Reglages)
    endswith(lowercase(filepath), ".csv") && return read_single_irf(filepath; series = spc.series)
    return FLIMCore.est_qc104(spc) ? read_sdt_irf_qc(filepath, spc) : read_sdt_irf(filepath; series = spc.series)
end

"""
Where each QC-104 setting of an IRF's record (the DLL's names,
`IRF_QC_SETTINGS`) goes in [qc]: (field of `Reglages`, index in its
quadruplet IN1, IN2, IN3, SYNC; 0 for a single value).
"""
const IRF_QC_FIELDS = Dict{String, Tuple{Symbol, Int}}(
    "cfd_limit_low" => (:qc_seuil_mV, 1), "cfd_limit_high" => (:qc_seuil_mV, 2),
    "cfd_zc_level" => (:qc_seuil_mV, 3), "sync_threshold" => (:qc_seuil_mV, 4),
    "tac_limit_high" => (:qc_zc_mV, 1), "sync_holdoff" => (:qc_zc_mV, 2),
    "cfd_holdoff" => (:qc_zc_mV, 3), "sync_zc_level" => (:qc_zc_mV, 4),
    "tdc_offset1" => (:qc_decalage_ns, 1), "tdc_offset2" => (:qc_decalage_ns, 2),
    "tdc_offset3" => (:qc_decalage_ns, 3), "tdc_offset4" => (:qc_decalage_ns, 4),
    "tac_range" => (:qc_plage_tdc_ns, 0), "sync_freq_div" => (:qc_diviseur_sync, 0),
    "fenetre_ns" => (:qc_fenetre_ns, 0))

"""
    irf_settings_changes(spc, channels) -> (settings, changes)

The settings an IRF was taken with (`channels`, its record), taken over: a
copy of `spc` with every timing setting of the record that differs
(beyond the DLL's rounding, `same_card_setting`) set to the IRF's — in [qc]
for the QC-104 (`IRF_QC_FIELDS`), in [spc_module] for SPC-150N — and the
list of changes ("key: now → IRF's"). The channels of one IRF must agree
on each setting (one Single for both). The card itself (serial number) and
the declared detector gains can't be taken over: `irf_mismatches` still
refuses those.
"""
function irf_settings_changes(spc::FLIMCore.Reglages, channels)
    taken = Dict{String, Float64}()
    for channel in channels, (key, value) in get(channel, "settings", Dict{String, Any}())
        v = Float64(value)
        haskey(taken, key) && !same_card_setting(key, taken[key], v) &&
            error("the IRF's channels were taken with different $key ($(taken[key]) and $v): take one Single for both channels")
        taken[key] = v
    end
    settings = deepcopy(spc)
    requested = irf_requested_settings(spc)
    fmt(x) = x === nothing ? "—" : string(round(Float64(x); sigdigits = 6))
    changes = String[]
    for (key, v) in sort!(collect(taken); by = first)
        now = get(requested, key, nothing)
        now !== nothing && same_card_setting(key, v, now) && continue
        if FLIMCore.est_qc104(spc)
            target = get(IRF_QC_FIELDS, key, nothing)
            target === nothing && continue
            field, i = target
            value = fieldtype(FLIMCore.Reglages, field) <: Integer ? round(Int, v) : round(v; digits = 3)
            i == 0 ? setfield!(settings, field, value) : (getfield(settings, field)[i] = value)
        else
            key in first.(IRF_CARD_SETTINGS) || continue
            value = key in IRF_EXACT_SETTINGS ? round(Int, v) : round(v; digits = 3)
            settings.spc[key] = value
        end
        push!(changes, "$key: $(fmt(now)) → $(fmt(value))")
    end
    FLIMCore.valider_reglages(settings)
    return settings, changes
end

"""
    import_irf_adopting_settings(filepath, spc) -> (irfs, info, settings, changes)

Import an IRF (a Single's CSV, or an SPCM .sdt) *with its settings*: the
timing settings it was taken with become the current ones
(`irf_settings_changes`: `settings`, to write to config/spc.toml, and the
list of `changes`), so the IRF matches what the card will measure with.
Refused only for what can't be taken over: another card or input than
[verification] series says, the detector gains. Kept as `irf_csv_path()`.
"""
function import_irf_adopting_settings(filepath::AbstractString, spc::FLIMCore.Reglages)
    irfs, channels = read_irf_file(filepath, spc)
    settings, changes = irf_settings_changes(spc, channels)
    irfs, info = save_imported_irf(irfs, channels, filepath, settings; applied = Dict{Int, Dict{String, Float64}}())
    return irfs, info, settings, changes
end

function compute_irf_bin_size(irf_data::Matrix{Float64})::Float64
    h = Inf
    for i in 2:size(irf_data, 1)
        dt = irf_data[i, 1] - irf_data[i-1, 1]
        if 0 < dt < h
            h = dt
        end
    end
    return h
end


# -----------------------------------------------------------------------------
# Etat global
# -----------------------------------------------------------------------------

isnotnan(x) = !isnan(x)
smaller_or_eq_zero(x) = x <= 0

# Concrete FFTW plan types, computed once rather than hardcoded — each is
# empirically stable across input lengths (length isn't part of a Vector's
# type), but deriving them this way stays correct even if FFTW.jl's internal
# parametrization changes across versions. `plan_fft` and `plan_ifft` are
# NOT the same type as each other: `plan_ifft` wraps its plan in an
# `AbstractFFTs.ScaledPlan` for the 1/N normalization, so they need separate
# aliases rather than one shared `FFTPlanType`.
const FFTPlanType = typeof(plan_fft(zeros(Float64, 1)))
const IFFTPlanType = typeof(plan_ifft(zeros(Float64, 1)))

"""
    RuntimeContext

IRF and FFT-plan state shared by the lifetime-fitting and acquisition code.
Held behind the `const` `RUNTIME` `Ref` below so every field access is
concretely typed (unlike a bare untyped `global`), which matters here since
this is read from the acquisition hot loop (every analyzed histogram).

Not thread-safe, by design rather than oversight: `run_acquisition_loop!`
runs on its own OS thread (`Threads.@spawn`, see gui/runtime.jl) so the GUI
thread stays responsive during a fit, but its fields (and the FFT/gating/
IRF-channel caches in this file) are only ever written from that single
worker thread (`ensure_fft_plans`/`ensure_runtime_state!`, called from
inside `vec_to_lifetime`) — `start_pressed` refuses to launch a second
worker while one is running, and `init_irf_runtime!()` only ever runs
before a worker starts. Everywhere else (GUI/consumer code) only reads
these fields. If that ever changes — e.g. a "reload IRF while running"
button that calls `init_irf_runtime!()` concurrently with a worker — these
fields and caches would need locking.

Fields:
- `irf` - Loaded Instrument Response Function, or `nothing` before/if loading fails
- `irf_bin_size` - IRF time-bin width in ns
- `tcspc_window_size` - Total TCSPC acquisition window in ns
- `fft_plan` / `ifft_plan` - Planned FFTW transforms, sized `fft_plan_size`
- `fft_plan_size` - Histogram resolution the current plans were built for
- `irf_cache_source_id` - `objectid(irf)` at last cache build, to detect a
  newly-loaded IRF and invalidate `IRF_CHANNEL_CACHE`
- `conv_scratch_in` / `conv_scratch_a` / `conv_scratch_b` - reusable
  `ComplexF64` buffers for `convolve`'s in-place FFTs (`mul!`, see below),
  sized `fft_plan_size`. `convolve` runs on every `Optim` objective
  evaluation (50-200+ times per fit) so avoiding a fresh heap allocation per
  buffer per call materially cuts GC pressure in the acquisition hot loop.
"""
mutable struct RuntimeContext
    irf::Union{Nothing, Matrix{Float64}}
    irf_bin_size::Union{Nothing, Float64}
    tcspc_window_size::Union{Nothing, Float64}
    fft_plan::FFTPlanType
    ifft_plan::IFFTPlanType
    fft_plan_size::Int
    irf_cache_source_id::UInt
    conv_scratch_in::Vector{ComplexF64}
    conv_scratch_a::Vector{ComplexF64}
    conv_scratch_b::Vector{ComplexF64}
end

"""
    RUNTIME::Ref{RuntimeContext}

Populated in `__init__()` below, not here, with a 256-point FFT plan default
(matching histogram resolution) and no IRF loaded yet. Always defined by the
time any application code runs — callers never need to guard against it not
existing, only against `RUNTIME[].irf` still being `nothing`.

FFTW plans wrap a raw C pointer (`fftw_plan`) that is only valid within the
process that created it. Building the initial plans here, in a top-level
`const` initializer, would run them once during precompilation and bake that
now-stale pointer into the precompiled package cache — the next process to
load the package from that cache would execute a dangling pointer and
segfault (confirmed empirically: this crashed 100% of the time on the first
FFT execution after a precompiled load, and disappeared once construction
moved into `__init__()`). `__init__()` is Julia's mechanism for exactly this
case: it reruns in every fresh process, precompiled or not.
"""
const RUNTIME = Ref{RuntimeContext}()

"""
Channel 2's context, its own IRF (`nothing` when the IRF .sdt had a single
channel: channel 2 then uses channel 1's, see `channel_fit_context`).
`RUNTIME` is channel 1's.
"""
const RUNTIME_CH2 = Ref{RuntimeContext}()

new_runtime_context() = RuntimeContext(
    nothing, nothing, nothing,
    plan_fft(zeros(Float64, 256)), plan_ifft(zeros(Float64, 256)), 256,
    UInt(0),
    Vector{ComplexF64}(undef, 256), Vector{ComplexF64}(undef, 256), Vector{ComplexF64}(undef, 256)
)

function __init__()
    RUNTIME[] = new_runtime_context()
    RUNTIME_CH2[] = new_runtime_context()
    return nothing
end

"""The fit context of channel `channel`: its own IRF, or channel 1's when it has none."""
channel_fit_context(channel::Integer) =
    channel == 2 && RUNTIME_CH2[].irf !== nothing ? RUNTIME_CH2[] : RUNTIME[]

"""
    with_fit_context(f, ctx)

Run `f()` with every fit function of this file using `ctx` (an IRF, its FFT
plans and scratch buffers) instead of channel 1's `RUNTIME[]` — how the
Realtime worker fits each channel against its own IRF. Task-local: other
tasks keep theirs.
"""
with_fit_context(f, ctx::RuntimeContext) = task_local_storage(f, :flimapp_fit_context, ctx)

"""The context the fit functions use in this task (`with_fit_context`), channel 1's otherwise."""
fit_context()::RuntimeContext = get(task_local_storage(), :flimapp_fit_context, RUNTIME[])::RuntimeContext

"""The record of the loaded IRF's settings (`import_irf_sdt`), empty if none."""
const IRF_INFO = Ref(Dict{String, Any}())

"""
    set_irfs!(irfs; info=Dict())

Load the IRF of each channel (`load_irfs`) into the fit contexts, with the
record of its settings (`irf_mismatches`). Only while no worker runs (see
`RuntimeContext`).
"""
function set_irfs!(irfs::AbstractVector{<:AbstractMatrix}; info::AbstractDict = Dict{String, Any}())
    IRF_INFO[] = Dict{String, Any}(info)
    for (ctx, irf) in zip((RUNTIME[], RUNTIME_CH2[]), (irfs[1], get(irfs, 2, nothing)))
        ctx.irf = irf === nothing ? nothing : Matrix{Float64}(irf)
        ctx.irf_bin_size = irf === nothing ? nothing : compute_irf_bin_size(ctx.irf)
        ctx.tcspc_window_size = irf === nothing ? nothing : round(irf[end, 1] + irf[2, 1], sigdigits=4)
    end
    return nothing
end

"""The loaded IRF of each channel (one or two), for the journal."""
loaded_irfs() = Matrix{Float64}[ctx.irf for ctx in (RUNTIME[], RUNTIME_CH2[]) if ctx.irf !== nothing]

"""The record of the loaded IRF's settings, for the journal and the checks at START."""
loaded_irf_info() = IRF_INFO[]

function ensure_fft_plans(size::Int)
    ctx = fit_context()
    if ctx.fft_plan_size != size
        ctx.fft_plan = plan_fft(zeros(Float64, size))
        ctx.ifft_plan = plan_ifft(zeros(Float64, size))
        ctx.fft_plan_size = size
        ctx.conv_scratch_in = Vector{ComplexF64}(undef, size)
        ctx.conv_scratch_a = Vector{ComplexF64}(undef, size)
        ctx.conv_scratch_b = Vector{ComplexF64}(undef, size)
    end
    return nothing
end

function get_x_data(total_channels::Int, bin_size::Float64)::Vector{Float64}
    key = (total_channels, bin_size)
    cached = get(X_DATA_CACHE, key, nothing)
    if cached !== nothing
        return cached
    end

    x_data = collect(bin_size:bin_size:total_channels * bin_size)
    X_DATA_CACHE[key] = x_data
    return x_data
end

function get_gating_function(total_channels::Int, low_cut_idx::Int, high_cut_idx::Int)::Vector{UInt8}
    if total_channels <= 0
        return UInt8[]
    end

    low_cut = clamp(low_cut_idx, 0, total_channels)
    high_cut = clamp(high_cut_idx, 1, total_channels + 1)

    key = (total_channels, low_cut, high_cut)
    cached = get(GATING_CACHE, key, nothing)
    if cached !== nothing
        return cached
    end

    gating = ones(UInt8, total_channels)
    if low_cut >= 1
        gating[1:low_cut] .= 0
    end
    if high_cut <= total_channels
        gating[high_cut:total_channels] .= 0
    end

    GATING_CACHE[key] = gating
    return gating
end

function get_irf_for_channels(total_channels::Int)::Matrix{Float64}
    ctx = fit_context()
    if size(ctx.irf, 1) == total_channels
        return ctx.irf
    end

    key = (objectid(ctx.irf), total_channels)
    cached = get(IRF_CHANNEL_CACHE, key, nothing)
    if cached !== nothing
        return cached
    end

    new_irf = zeros(Float64, total_channels, 2)
    new_irf[:, 1] = collect(ctx.irf_bin_size:ctx.irf_bin_size:ctx.irf_bin_size * total_channels)
    ncopy = min(total_channels, size(ctx.irf, 1))
    new_irf[1:ncopy, 2] = ctx.irf[1:ncopy, 2]

    IRF_CHANNEL_CACHE[key] = new_irf
    return new_irf
end

function fit_optim_options(number_of_lifetimes::Int, first_fit::Bool)
    if number_of_lifetimes == 1
        if first_fit
            return Optim.Options(outer_iterations=14, iterations=64, x_abstol=5e-7, outer_x_abstol=5e-7, f_reltol=1e-5, outer_f_reltol=1e-4, f_calls_limit=280, time_limit=0.060, allow_f_increases=true)
        end
        return Optim.Options(outer_iterations=8, iterations=32, x_abstol=5e-7, outer_x_abstol=5e-7, f_reltol=1e-5, outer_f_reltol=1e-4, f_calls_limit=140, time_limit=0.020, allow_f_increases=true)
    elseif number_of_lifetimes == 2
        if first_fit
            return Optim.Options(outer_iterations=10, iterations=40, f_reltol=1e-5, outer_f_reltol=1e-4, x_abstol=5e-7, outer_x_abstol=5e-7, f_calls_limit=220, time_limit=0.050)
        end
        return Optim.Options(outer_iterations=6, iterations=24, f_reltol=1e-5, outer_f_reltol=1e-4, x_abstol=5e-7, outer_x_abstol=5e-7, f_calls_limit=120, time_limit=0.015)
    end

    if first_fit
        return Optim.Options(outer_iterations=6, iterations=24, f_reltol=1e-4, outer_f_reltol=1e-3, x_abstol=1e-6, outer_x_abstol=1e-6, f_calls_limit=160, time_limit=0.030)
    end
    return Optim.Options(outer_iterations=4, iterations=16, f_reltol=1e-4, outer_f_reltol=1e-3, x_abstol=1e-6, outer_x_abstol=1e-6, f_calls_limit=80, time_limit=0.012)
end

function clamp_initial_point!(params_copy::Vector{Float64}, lower_bounds::Vector{Float64}, upper_bounds::Vector{Float64}; eps=1e-6)
    @inbounds for i in eachindex(params_copy)
        lo = lower_bounds[i] + eps
        hi = upper_bounds[i] - eps
        if lo > hi
            lo = lower_bounds[i]
            hi = upper_bounds[i]
        end
        params_copy[i] = clamp(params_copy[i], lo, hi)
    end
    return params_copy
end

function ensure_runtime_state!()
    ctx = fit_context()
    if ctx.irf === nothing
        error("IRF not loaded. Call init_irf_runtime!() (or set RUNTIME[].irf) before calling vec_to_lifetime.")
    end
    if ctx.irf_bin_size === nothing || !isfinite(ctx.irf_bin_size)
        error("irf_bin_size not initialized. Set RUNTIME[].irf_bin_size = compute_irf_bin_size(RUNTIME[].irf).")
    end
    if ctx.tcspc_window_size === nothing || !isfinite(ctx.tcspc_window_size) || ctx.tcspc_window_size <= 0
        error("tcspc_window_size not initialized. Set RUNTIME[].tcspc_window_size from RUNTIME[].irf.")
    end

    src_id = objectid(ctx.irf)
    if ctx.irf_cache_source_id != src_id
        empty!(IRF_CHANNEL_CACHE)
        ctx.irf_cache_source_id = src_id
    end

    ensure_fft_plans(size(ctx.irf, 1))
    return nothing
end

# -----------------------------------------------------------------------------
# Convolution et modeles
# -----------------------------------------------------------------------------

"""
    convolve(irf_vec, decay; ...)

Runs on every `Optim` objective evaluation (50-200+ times per fit, x2
channels), so the FFTs are done in-place via `mul!` into the fit context's
`conv_scratch_*` buffers (resized alongside the plans in `ensure_fft_plans`)
instead of the allocating `plan * x` form -- cuts this function from 5-6
heap allocations down to 1 (the freshly-owned `y` this function returns;
everything upstream of that stays in the reused scratch buffers). Verified
bit-identical output to the previous allocating form across a range of
inputs before landing this (see lifetime_analysis tests).

Not thread-safe, same as the rest of `RuntimeContext` (see its docstring):
scratch buffers are reused sequentially within one call and across calls
from the single acquisition worker thread, never concurrently.
"""
function convolve(irf_vec::Vector{Float64}, decay::Vector{Float64}; histogram_resolution::Int64=256, tcspc_low_cut_index::Int64=13, tcspc_high_cut_index::Int64=12)
    if length(irf_vec) != length(decay)
        error("IRF and decay vectors must have same length: $(length(irf_vec)) vs $(length(decay))")
    end

    ensure_fft_plans(length(irf_vec))
    ctx = fit_context()

    ctx.conv_scratch_in .= irf_vec
    mul!(ctx.conv_scratch_a, ctx.fft_plan, ctx.conv_scratch_in)

    ctx.conv_scratch_in .= decay
    mul!(ctx.conv_scratch_b, ctx.fft_plan, ctx.conv_scratch_in)

    ctx.conv_scratch_a .*= ctx.conv_scratch_b
    mul!(ctx.conv_scratch_b, ctx.ifft_plan, ctx.conv_scratch_a)

    y = real.(ctx.conv_scratch_b)

    lo = clamp(tcspc_low_cut_index, 1, histogram_resolution)
    hi = clamp(histogram_resolution - tcspc_high_cut_index, lo, histogram_resolution)
    denom = sum(view(y, lo:hi))
    if denom <= 0 || !isfinite(denom)
        return y
    end

    y ./= denom
    return y::Vector{Float64}
end

"""
    irf_shift(data_irf, shift)

Linear-interpolated circular shift of the IRF by `shift` bins. `shift` is
itself an optimized parameter, so (unlike `get_x_data`/`get_channel_range`
etc.) the result can't be cached across `Optim` evaluations -- but the
previous broadcast form still allocated ~8-9 temporary arrays per call
(the `channel .- ... .% n ...` chains, plus the fancy-indexing gathers)
purely to materialize `index_1`/`index_2` before combining them. Rewritten
as a single `@inbounds` loop computing both indices per-element (`channel`
was always just `1:n`, i.e. the loop variable itself, so `get_channel_range`
is no longer needed either) into one freshly-allocated output -- down to 1
allocation per call. This is a literal transliteration of the original
per-element arithmetic (including its two *different*, individually
redundant `rem`/`mod1` reduction chains for index_1 vs index_2) rather than
a hand-simplified formula, specifically to keep this verifiably
bit-identical to the previous implementation -- verified across a range of
n/shift values before landing this.
"""
function irf_shift(data_irf::Matrix{Float64}, shift)
    if isnan(shift)
        shift = 0
    end

    n = size(data_irf, 1)
    irf_counts = @view data_irf[:, 2]

    floor_off = floor(Int, shift) - 1
    ceil_off = ceil(Int, shift) - 1
    # Computed with the exact same operation order as the original
    # `(1 - shift) + floor(shift)` / `(shift - floor(shift))` -- not
    # algebraically simplified to `1 - w2` -- since floating-point +/- is
    # not associative and that reordering measurably produced a ~1e-15
    # (1-ULP) difference from the original in verification.
    w1 = 1 - shift + floor(shift)
    w2 = shift - floor(shift)

    out = Vector{Float64}(undef, n)
    @inbounds for i in 1:n
        idx1 = mod1(rem(rem(rem(i - floor_off, n), n), n) + 1, n)
        idx2 = mod1(rem(rem(i - ceil_off, n) + n, n) + 1, n)
        out[i] = w1 * irf_counts[idx1] + w2 * irf_counts[idx2]
    end

    return out::Vector{Float64}
end

function conv_irf_data(x_data::Vector{Float64}, params::Tuple{Float64, Float64, Float64}, data_irf::Matrix{Float64}; histogram_resolution::Int64=256, number_of_previous_pulses::Int64=5, laser_pulse_period::Float64=12.5, tcspc_low_cut_index::Int64=13, tcspc_high_cut_index::Int64=12)
    return convolve(irf_shift(data_irf, params[2]), exp.(-x_data ./ params[1]), histogram_resolution=histogram_resolution, tcspc_low_cut_index=tcspc_low_cut_index, tcspc_high_cut_index=tcspc_high_cut_index)
end

function conv_irf_data(x_data::Vector{Float64}, params::Tuple{Float64, Float64, Float64, Float64, Float64}, data_irf::Matrix{Float64}; histogram_resolution::Int64=256, number_of_previous_pulses::Int64=5, laser_pulse_period::Float64=12.5, tcspc_low_cut_index::Int64=13, tcspc_high_cut_index::Int64=12)
    t_1, a_1, t_2, d_0, _ = params
    irf_y_data = irf_shift(data_irf, d_0)

    exp_1 = @. a_1 * exp(-x_data / t_1)
    exp_2 = @. (1.0 - a_1) * exp(-x_data / t_2)

    # @. fuses the whole RHS (including the unary minus, which a plain `.`
    # chain does NOT fuse across -- confirmed by measurement) into one pass
    # written straight into exp_1/exp_2, instead of materializing an
    # intermediate array at every operator. This loop dominates conv_irf_data's
    # allocations (it runs on every Optim objective/gradient evaluation, i.e.
    # 50-200+ times per fit): measured 29% of total fit wall time spent in GC
    # before this change, with individual fits occasionally spending 250+ ms
    # in a single GC pause. Verified bit-identical output to the previous
    # unfused form across a range of parameter values before landing this.
    for previous_pulse in 1:number_of_previous_pulses
        shift = laser_pulse_period * previous_pulse
        @. exp_1 += a_1 * exp(-(x_data + shift) / t_1)
        @. exp_2 += (1.0 - a_1) * exp(-(x_data + shift) / t_2)
    end

    return convolve(irf_y_data, exp_1 .+ exp_2, histogram_resolution=histogram_resolution, tcspc_low_cut_index=tcspc_low_cut_index, tcspc_high_cut_index=tcspc_high_cut_index)
end

function conv_irf_data(x_data::Vector{Float64}, params::Tuple{Float64, Float64, Float64, Float64, Float64, Float64, Float64, Float64}, data_irf::Matrix{Float64}; histogram_resolution::Int64=256, number_of_previous_pulses::Int64=5, laser_pulse_period::Float64=12.5, tcspc_low_cut_index::Int64=13, tcspc_high_cut_index::Int64=12)
    t_1 = params[1]
    a_1 = abs(params[2])
    t_2 = params[3]
    a_2 = abs(params[4])
    t_3 = params[5]
    a_3 = params[6]
    d_0 = params[7]

    irf_y_data = irf_shift(data_irf, d_0)

    exp_1 = @. a_1 * exp(-x_data / t_1)
    exp_2 = @. a_2 * exp(-x_data / t_2)
    exp_3 = @. a_3 * exp(-x_data / t_3)

    # See the 5-parameter (2-lifetime) conv_irf_data above for why @. here
    # (full-expression fusion, no intermediate temp arrays) instead of the
    # previous per-operator .+ / .* / exp. chain.
    for previous_pulse in 1:number_of_previous_pulses
        shift = laser_pulse_period * previous_pulse
        @. exp_1 += a_1 * exp(-(x_data + shift) / t_1)
        @. exp_2 += a_2 * exp(-(x_data + shift) / t_2)
        @. exp_3 += a_3 * exp(-(x_data + shift) / t_3)
    end

    return convolve(irf_y_data, exp_1 .+ exp_2 .+ exp_3, histogram_resolution=histogram_resolution, tcspc_low_cut_index=tcspc_low_cut_index, tcspc_high_cut_index=tcspc_high_cut_index)
end

# -----------------------------------------------------------------------------
# Fit MLE
# -----------------------------------------------------------------------------

function three_lifetime_fraction_constraints!(c, x)
    c[1] = x[2] + x[4] + x[6]
    c
end

function mle_objective(free_params::Vector{Float64}, fixed_params::Vector{Float64}, x_data::Vector{Float64}, y_data::Vector{Float64}, data_irf::Matrix{Float64}, gating_function::Vector{UInt8}, histogram_resolution::Int64, number_of_previous_pulses::Int64, laser_pulse_period::Float64, tcspc_low_cut_index::Int64, tcspc_high_cut_index::Int64)
    if length(fixed_params) == 3
        number_of_lifetimes = 1
    elseif length(fixed_params) == 5
        number_of_lifetimes = 2
    else
        number_of_lifetimes = 3
    end

    params = zeros(Float64, length(fixed_params))
    if length(free_params) == length(fixed_params)
        params = free_params
    else
        free_idx = 1
        for i in eachindex(fixed_params)
            if isnan(fixed_params[i])
                params[i] = free_params[free_idx]
                free_idx += 1
            else
                params[i] = fixed_params[i]
            end
        end
    end

    n_counts = float(sum(y_data))
    n_active_bins = max(1, histogram_resolution - tcspc_low_cut_index - tcspc_high_cut_index)

    if number_of_lifetimes == 1
        exp_val_c = ((1 - params[3]) .* conv_irf_data(x_data, (params[1], params[2], params[3]), data_irf, histogram_resolution=histogram_resolution, number_of_previous_pulses=number_of_previous_pulses, laser_pulse_period=laser_pulse_period, tcspc_low_cut_index=tcspc_low_cut_index, tcspc_high_cut_index=tcspc_high_cut_index) .+ params[3] / n_active_bins) .* n_counts
    elseif number_of_lifetimes == 2
        exp_val_c = ((1 - params[5]) .* conv_irf_data(x_data, (params[1], params[2], params[3], params[4], params[5]), data_irf, histogram_resolution=histogram_resolution, number_of_previous_pulses=number_of_previous_pulses, laser_pulse_period=laser_pulse_period, tcspc_low_cut_index=tcspc_low_cut_index, tcspc_high_cut_index=tcspc_high_cut_index) .+ params[5] / n_active_bins) .* n_counts
    else
        exp_val_c = ((1 - params[8]) .* conv_irf_data(x_data, (params[1], params[2], params[3], params[4], params[5], params[6], params[7], params[8]), data_irf, histogram_resolution=histogram_resolution, number_of_previous_pulses=number_of_previous_pulses, laser_pulse_period=laser_pulse_period, tcspc_low_cut_index=tcspc_low_cut_index, tcspc_high_cut_index=tcspc_high_cut_index) .+ params[8] / n_active_bins) .* n_counts
    end

    # y_data itself is already sanitized once in mle_reconvolution_fit before
    # Optim.optimize is called, not re-sanitized here on every one of its
    # 50-200+ objective evaluations -- exp_val_c is the only value that's
    # freshly recomputed each evaluation and actually needs it.
    replace!(x -> smaller_or_eq_zero(x) ? 1e-256 : x, exp_val_c)

    dev = 2.0 / (sqrt(n_counts) * (histogram_resolution - length(params))) * sum(gating_function .* (y_data .* log.(y_data ./ exp_val_c) .- y_data .+ exp_val_c))
    if isnan(dev)
        throw(ErrorException("NaN in objective function"))
    end
    return dev::Float64
end

function find_mean_arrival_time(counts::AbstractVector{<:Real}; tcspc_high_cut_index::Int64=0)
    lim = length(counts) - tcspc_high_cut_index
    lim = max(lim, 1)
    den = sum(counts[1:lim])
    if den <= 0
        return 0.0
    end

    num = 0.0
    @inbounds for i in 1:lim
        num += i * counts[i]
    end
    return num / den
end

function lifetime_estimate(counts::AbstractVector{<:Real}; bin_size=0.039, tcspc_high_cut_index::Int64=0)
    mean_irf_arrival_time = find_mean_arrival_time(fit_context().irf[:, 2], tcspc_high_cut_index=tcspc_high_cut_index)
    mean_data_arrival_time = find_mean_arrival_time(counts, tcspc_high_cut_index=tcspc_high_cut_index)
    return ((mean_data_arrival_time - mean_irf_arrival_time) * bin_size)::Float64
end

"""
    pixel_lifetime_map(intensity, sum_t; min_photons=50.0)::Matrix{Float64}

Per-pixel approximate lifetime (ns), by the same first-moment analysis as
`lifetime_estimate`: each pixel's mean arrival time (`sum_t ./ intensity`,
as the SPC image gives them, see FLIMCore's `ImageSomme`) minus the IRF's
own mean arrival time. No MLE fit — the cheap, no-optimizer estimate, for a
quick per-pixel preview where fitting every pixel would be far too slow.

A pixel with fewer than `min_photons` photons gets `NaN` — first-moment
analysis is biased and noisy at low counts, so the caller (roi_popup.jl)
renders `NaN` as transparent rather than a misleading color.

Errors if the IRF hasn't been loaded (`ctx.irf`/`irf_bin_size`) —
there is no "reliable" lifetime without it. `ctx`: the IRF of the image's
channel (`channel_fit_context`).
"""
function pixel_lifetime_map(intensity::AbstractMatrix{<:Real}, sum_t::AbstractMatrix{<:Real}; min_photons::Real=50.0, ctx::RuntimeContext=fit_context())::Matrix{Float64}
    irf = ctx.irf
    bin_size = ctx.irf_bin_size
    if irf === nothing || bin_size === nothing
        error("IRF not loaded. Call init_irf_runtime!() before computing a pixel lifetime map.")
    end
    size(intensity) == size(sum_t) || error("intensity and sum_t sizes differ: $(size(intensity)) vs $(size(sum_t))")

    # Channel centers, like the SPC image's arrival times ((channel + 0.5) * dt).
    mean_irf_time_ns = (find_mean_arrival_time(irf[:, 2]) - 0.5) * bin_size

    result = fill(NaN, size(intensity))
    for i in eachindex(intensity)
        n = intensity[i]
        n < min_photons && continue
        n > 0 || continue
        result[i] = sum_t[i] / n - mean_irf_time_ns
    end
    return result
end

# `fixed_parameters`'s default MUST track `params`'s length via `fill(NaN,
# length(params))`, not a fixed literal: mle_objective (below) infers
# number_of_lifetimes purely from `length(fixed_parameters)`, so a caller
# that fits a 2- or 3-lifetime model without overriding this default would
# otherwise silently get a 1-lifetime-shaped `fixed_parameters` and have
# mle_objective evaluate the WRONG model — the actual, previously-shipped
# bug this fixes: every full (non-partial) 2-lifetime fit in
# run_acquisition_loop! never passed `fixed_parameters` explicitly, so it
# silently optimized a degenerate 3-parameter proxy internally treated as
# number_of_lifetimes==1, ignoring the real τ2/shift/offset dimensions.
# Confirmed empirically: same guess/data, properly-scoped fixed_parameters
# converges to a genuinely different (and correctly warm-started, ~97%
# convergent) 2-exponential result at ~8x the per-fit cost of the buggy
# proxy — the previous "2 lifetimes" mode was fast because it wasn't really
# fitting two lifetimes.
function mle_reconvolution_fit(data_irf::Matrix{Float64}, data_xy::Vector{Vector{Float64}}; params, gating_function=ones(UInt8, 320), histogram_resolution::Int64=256, number_of_previous_pulses::Int64=5, laser_pulse_period::Float64=12.5, fixed_parameters::Vector{Float64}=fill(NaN, length(params)), tcspc_low_cut_index::Int64=13, tcspc_high_cut_index::Int64=12, use_lifetime_estimation_as_guess::Bool=true, first_fit::Bool=false)
    x_data = vec(data_xy[1])
    y_data = vec(data_xy[2]) .* gating_function
    replace!(x -> smaller_or_eq_zero(x) ? 1e-256 : x, y_data)

    number_of_lifetimes = floor(Int, (length(params) - 1) / 2)
    params_copy = copy(params)

    if all(isnotnan.(fixed_parameters))
        return fixed_parameters
    end

    irf_bin_size = fit_context().irf_bin_size
    if number_of_lifetimes == 1
        if use_lifetime_estimation_as_guess
            params_copy[1] = lifetime_estimate(y_data, bin_size=irf_bin_size, tcspc_high_cut_index=tcspc_high_cut_index)
        end
        lower_bounds = Float64[2 * irf_bin_size, -16.0, 0.0]
        upper_bounds = Float64[laser_pulse_period * 2, 32.0, 1.0]
    elseif number_of_lifetimes == 2
        lower_bounds = Float64[2 * irf_bin_size, 0.0, 2 * irf_bin_size, -16.0, 0.0]
        upper_bounds = Float64[laser_pulse_period * 2, 1.0, laser_pulse_period * 2, 64.0, 1.0]
    else
        lower_bounds = Float64[2 * irf_bin_size, 0.0, 2 * irf_bin_size, 0.0, 2 * irf_bin_size, 0.0, -16.0, 0.0]
        upper_bounds = Float64[laser_pulse_period * 2, 1.0, laser_pulse_period * 2, 1.0, laser_pulse_period * 2, 1.0, 32.0, 1.0]
    end

    if any(.!isnan.(fixed_parameters))
        if length(params_copy) != length(fixed_parameters)
            error("params and fixed_parameters must be the same length")
        end
        fixed_indices = collect(1:length(fixed_parameters))[.!isnan.(fixed_parameters)]
        deleteat!(params_copy, fixed_indices)
        deleteat!(lower_bounds, fixed_indices)
        deleteat!(upper_bounds, fixed_indices)
    end

    clamp_initial_point!(params_copy, lower_bounds, upper_bounds)

    if number_of_lifetimes in (1, 2)
        fit = Optim.optimize(x -> mle_objective(x, fixed_parameters, x_data, y_data, data_irf, gating_function, histogram_resolution, number_of_previous_pulses, laser_pulse_period, tcspc_low_cut_index, tcspc_high_cut_index), lower_bounds, upper_bounds, params_copy, Fminbox(LBFGS(linesearch=LineSearches.BackTracking())), fit_optim_options(number_of_lifetimes, first_fit))
    else
        lower_c, upper_c = Float64[1.0], Float64[1.0]
        constraint = TwiceDifferentiableConstraints(three_lifetime_fraction_constraints!, lower_bounds, upper_bounds, lower_c, upper_c)
        fit = Optim.optimize(x -> mle_objective(x, fixed_parameters, x_data, y_data, data_irf, gating_function, histogram_resolution, number_of_previous_pulses, laser_pulse_period, tcspc_low_cut_index, tcspc_high_cut_index), constraint, params_copy, IPNewton(), fit_optim_options(number_of_lifetimes, first_fit))
    end

    res = Optim.minimizer(fit)

    output_res = zeros(Float64, length(params))
    if any(.!isnan.(fixed_parameters))
        free_counter = 1
        for p in eachindex(fixed_parameters)
            if isnan(fixed_parameters[p])
                output_res[p] = res[free_counter]
                free_counter += 1
            else
                output_res[p] = fixed_parameters[p]
            end
        end
    else
        output_res = res
    end

    if !Optim.converged(fit)
        if number_of_lifetimes == 1
            return Float64[NaN, NaN, NaN]
        elseif number_of_lifetimes == 2
            return Float64[NaN, NaN, NaN, NaN, NaN]
        end
        return Float64[NaN, NaN, NaN, NaN, NaN, NaN, NaN, NaN]
    end

    if number_of_lifetimes == 2 && output_res[3] > output_res[1]
        t_1 = output_res[1]
        t_2 = output_res[3]
        output_res[1] = t_2
        output_res[3] = t_1
        output_res[2] = 1 - output_res[2]
    elseif number_of_lifetimes == 3
        permutation = sortperm(output_res[1:2:5])
        found_params_copy = copy(output_res)
        adjusted = zeros(Int64, 3)
        for (idx, p) in enumerate(permutation)
            adjusted[idx] = p == 1 ? 1 : p == 2 ? 3 : 5
        end
        amplitudes = [found_params_copy[2], found_params_copy[4], found_params_copy[6]]
        output_res[1] = found_params_copy[adjusted[1]]
        output_res[2] = amplitudes[permutation[1]]
        output_res[3] = found_params_copy[adjusted[2]]
        output_res[4] = amplitudes[permutation[2]]
        output_res[5] = found_params_copy[adjusted[3]]
        output_res[6] = amplitudes[permutation[3]]
    end

    return output_res::Vector{Float64}
end

# -----------------------------------------------------------------------------
# API principale
# -----------------------------------------------------------------------------

# fixed_parameters's default tracks `guess`'s length -- see the comment on
# mle_reconvolution_fit above for why a fixed-length default is a bug.
function vec_to_lifetime(x; bin_size=0.04886091184430619, hist_size_threshold=500, method="MLE", guess=[3.0, 1.0, 1e-6], laser_pulse_period=12.5, histogram_resolution=256, number_of_previous_pulses=5, tac_low_cut=5.0980392, tac_high_cut=94.901962, IRF_delay=NaN, IRF_width=NaN, IRF_cutoff=NaN, lifetime_estimation=NaN, standard_deviation_estimation=NaN, fixed_parameters=fill(NaN, length(guess)), use_lifetime_estimation_as_guess::Bool=true, first_fit::Bool=false)
    ensure_runtime_state!()
    tcspc_window_size = fit_context().tcspc_window_size

    requested_channels = round(Int, laser_pulse_period * histogram_resolution / tcspc_window_size)
    total_channels = requested_channels

    if total_channels <= 0
        @warn "Computed invalid total_channels from IRF window; falling back to histogram resolution" requested_channels=total_channels tcspc_window_size=tcspc_window_size histogram_resolution=histogram_resolution
        total_channels = histogram_resolution
    end

    if abs(total_channels - histogram_resolution) <= 1
        total_channels = histogram_resolution
    end

    total_channels = max(total_channels, histogram_resolution, length(x), 32)

    x_vec = Float64.(vec(x))
    if length(x_vec) < total_channels
        append!(x_vec, zeros(total_channels - length(x_vec)))
    elseif length(x_vec) > total_channels
        x_vec = x_vec[1:total_channels]
    end

    ensure_fft_plans(total_channels)
    irf_local = get_irf_for_channels(total_channels)

    x_data = get_x_data(total_channels, Float64(bin_size))

    if sum(x_vec) < hist_size_threshold
        if method == "Estimate"
            return Float64[0.0], [x_data, x_vec]::Vector{Vector{Float64}}
        end
        return Float64[NaN], [x_data, x_vec]::Vector{Vector{Float64}}
    end

    if method == "Estimate"
        return Float64[lifetime_estimate(x_vec[1:histogram_resolution], bin_size=bin_size)], [x_data[1:histogram_resolution], x_vec[1:histogram_resolution]]::Vector{Vector{Float64}}
    end

    if method != "MLE"
        error("Unsupported method in simplified lifetime_analysis.jl: $method. Supported methods: \"MLE\", \"Estimate\".")
    end

    low_cut_index = round(Int, tac_low_cut / 100 * histogram_resolution)
    low_cut_index = max(low_cut_index, 1)

    if tac_high_cut != 0
        high_cut_start = round(Int, tac_high_cut / 100 * histogram_resolution)
        high_cut_start = clamp(high_cut_start, 1, total_channels + 1)
        tcspc_high_cut_index = total_channels - high_cut_start
    else
        high_cut_start = total_channels + 1
        tcspc_high_cut_index = 0
    end

    gating_function = get_gating_function(total_channels, low_cut_index, high_cut_start)

    data_xy = [x_data, x_vec]

    tau_fit = mle_reconvolution_fit(
        irf_local,
        data_xy,
        params=guess,
        gating_function=gating_function,
        histogram_resolution=total_channels,
        number_of_previous_pulses=number_of_previous_pulses,
        laser_pulse_period=laser_pulse_period,
        fixed_parameters=fixed_parameters,
        tcspc_low_cut_index=low_cut_index,
        tcspc_high_cut_index=tcspc_high_cut_index,
        use_lifetime_estimation_as_guess=use_lifetime_estimation_as_guess,
        first_fit=first_fit,
    )

    return tau_fit::Vector{Float64}, data_xy::Vector{Vector{Float64}}
end

# -----------------------------------------------------------------------------
# JIT warmup
# -----------------------------------------------------------------------------

"""
    warmup_lifetime_fitting!()

Run one throwaway fit per lifetime-count model (1- and 2-lifetime; 3-lifetime
is skipped, see below) so Julia JIT-compiles the whole `vec_to_lifetime` ->
`Optim.optimize` -> `mle_objective` -> `conv_irf_data` -> `convolve` call
chain once, up front, instead of on the user's first real acquisition frame.

Why this matters: `conv_irf_data` dispatches on the *type* of its `params`
tuple (`Tuple{Float64,Float64,Float64}` for 1-lifetime vs
`Tuple{Float64,Float64,Float64,Float64,Float64}` for 2-lifetime) — genuinely
different methods requiring separate compilation — so each guess length must
be warmed independently. Measured cost of skipping this: the very first
`vec_to_lifetime` call in a process took 3-13 seconds of wall time in
testing, and because Julia's compiler holds locks shared across threads,
that stall was observed on the *main* GUI thread too, even though the fit
itself runs on its own thread (see `spawn_acquisition_worker!` in
gui/runtime.jl) — i.e. moving the worker off the GUI thread does not by itself
prevent this specific freeze; only warming ahead of time does.

Only 1- and 2-lifetime are warmed: 3-lifetime has a separate, pre-existing
bug (`initial_guess_for_lifetimes("3 lifetimes")` returns a 7-element
guess but the model's bounds need 8) that throws before doing any fit work,
so there is nothing productive to warm there.

Uses a synthetic decay-shaped histogram, not real data — this only needs to
exercise the numeric code paths, not produce a scientifically meaningful
result (its output is discarded). Called once from `run_app()` after the
IRF is loaded and before the GUI is shown, so the delay reads as "app is
starting up" rather than "the app froze when I clicked Start".
"""
function warmup_lifetime_fitting!()
    ctx = fit_context()
    if ctx.irf === nothing
        return nothing
    end
    FIT_WARMED[] = true

    synthetic_counts = [max(0.0, 1000.0 * exp(-i * 0.02) + 5.0) for i in 0:(DEFAULT_HISTOGRAM_RESOLUTION - 1)]

    for guess in (Float64[3.0, 0.0, 5.0e-5], Float64[3.0, 0.5, 0.5, 0.0, 5.0e-5])
        try
            vec_to_lifetime(synthetic_counts; guess=copy(guess), histogram_resolution=DEFAULT_HISTOGRAM_RESOLUTION, first_fit=true)
        catch e
            @warn "Lifetime-fitting warmup failed for one model; first real fit of this shape may be slow" guess_length=length(guess) error=string(e)
        end
    end

    return nothing
end

const FIT_WARMED = Ref(false)

"""
    ensure_fit_warm!()

`warmup_lifetime_fitting!` once per process, if `run_app` couldn't (no IRF
at startup, e.g. a Playback with the session's IRF): the analysis worker
calls it before its first pass, which would otherwise spend its fit's time
budget compiling and come back at the initial guess.
"""
ensure_fit_warm!() = (FIT_WARMED[] || warmup_lifetime_fitting!(); nothing)
