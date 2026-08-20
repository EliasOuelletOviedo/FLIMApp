"""
session_save.jl

Saving a realtime capture session to disk: snapshotting AppState, picking a
save path, and writing both the serialized .jls payload and companion CSV
exports (per-file dataframe + runtime vectors).
"""

using Dates
using DataFrames
using CSV
using NativeFileDialog
using Serialization

function snapshot_app_state(app)::AppState
    return AppState(
        app.dark,
        app.current_panel,
        deepcopy(app.layout),
        deepcopy(app.controller),
        deepcopy(app.protocol),
        deepcopy(app.roi),
        deepcopy(app.console)
    )
end

function realtime_default_save_name()::String
    stamp = Dates.format(Dates.now(), dateformat"yyyy-mm-dd_HHMMSS")
    return "realtime_capture_$(stamp).jls"
end

function pick_realtime_save_path()::Union{String, Nothing}
    chooser = () -> begin
        try
            return save_file("jls", realtime_default_save_name())
        catch
            return save_file()
        end
    end

    selected = pick_non_empty_path(chooser; error_msg="Realtime save dialog failed")
    if selected === nothing
        return nothing
    end

    path = String(selected)
    if !endswith(lowercase(path), ".jls")
        path *= ".jls"
    end

    return path
end

function pad_to_length(vec::AbstractVector{T}, n::Int) where T
    if length(vec) >= n
        return vec
    end
    out = Vector{T}(undef, n)
    out[1:length(vec)] = vec
    for i in (length(vec)+1):n
        out[i] = T(NaN)
    end
    return out
end

"""
    roi_series_dataframe(app_run)::DataFrame

Long-format export of every region's time series: one row per sample, tagged
with which region it belongs to, carrying the ratio, the concentration, and
each channel's mean intensity.

Long format (rather than the padded-wide format `write_realtime_capture_csv!`
uses for the global series below) because each region has its own independent
length AND its own independent timestamps (see `RoiSeries` in data_types.jl) —
there is no single shared row index or time base to pad against once there is
more than one region.

The per-channel columns are generated from the run's actual channel count, so
a two-channel acquisition does not carry an all-`NaN` third column.
"""
function roi_series_dataframe(app_run)::DataFrame
    channel_count = max(app_run.channel_count, 1)

    df = DataFrame(
        roi_index = Int[], roi_name = String[], timestamp = Float64[],
        ratio = Float64[], ratio_smooth = Float64[],
        concentration = Float64[], concentration_smooth = Float64[]
    )

    for c in 1:channel_count
        df[!, Symbol("mean_c", c)] = Float64[]
        df[!, Symbol("mean_c", c, "_smooth")] = Float64[]
    end

    roi_names = [r.name for r in app_run.rois[]]

    # `at` reads index k of a series that may be shorter than `timestamps`:
    # the raw and smoothed vectors are appended in lockstep, but a run
    # interrupted mid-append can leave one an element behind.
    at(v, k) = k <= length(v) ? Float64(v[k]) : NaN

    for (roi_idx, series) in enumerate(app_run.rois_series)
        name = roi_idx <= length(roi_names) ? roi_names[roi_idx] : "roi$roi_idx"
        ts = series.timestamps[]

        for k in eachindex(ts)
            row = Dict{Symbol, Any}(
                :roi_index => roi_idx,
                :roi_name => name,
                :timestamp => Float64(ts[k]),
                :ratio => at(series.ratio[], k),
                :ratio_smooth => at(series.ratio_smooth[], k),
                :concentration => at(series.concentration[], k),
                :concentration_smooth => at(series.concentration_smooth[], k)
            )

            for c in 1:channel_count
                if c <= length(series.channels)
                    row[Symbol("mean_c", c)] = at(series.channels[c].values[], k)
                    row[Symbol("mean_c", c, "_smooth")] = at(series.channels[c].smooth[], k)
                else
                    row[Symbol("mean_c", c)] = NaN
                    row[Symbol("mean_c", c, "_smooth")] = NaN
                end
            end

            push!(df, row)
        end
    end

    return df
end

function write_realtime_capture_csv!(csv_path::AbstractString, app_run, per_file_df::DataFrame)
    # Write per-file DataFrame to CSV
    try
        CSV.write(csv_path, per_file_df)
    catch e
        @warn "Failed to write per-file CSV" path=csv_path error=string(e)
    end

    # Global (not region-split) series: timestamps, protocol setpoint, and the
    # PI command outputs — command1/command2 stay a single shared series
    # regardless of region count (see AppRun's docstring, data_types.jl, for
    # why: they drive real hardware output, not just a plot).
    try
        ts = app_run.timestamps[]
        protocol_setpoint = app_run.protocol_setpoint[]
        command1 = app_run.command1[]
        command2 = app_run.command2[]

        maxlen = maximum(map(length, (ts, protocol_setpoint, command1, command2)))

        df_runtime = DataFrame(
            timestamp = pad_to_length(Float64.(ts), maxlen),
            protocol_setpoint = pad_to_length(Float64.(protocol_setpoint), maxlen),
            command1 = pad_to_length(Float64.(command1), maxlen),
            command2 = pad_to_length(Float64.(command2), maxlen)
        )

        runtime_csv_path = replace(String(csv_path), r"(?i)\.csv$" => "_runtime_vectors.csv")
        CSV.write(runtime_csv_path, df_runtime)
    catch e
        @warn "Failed to write runtime vectors CSV" error=string(e)
    end

    # Per-region time series, long format.
    try
        roi_csv_path = replace(String(csv_path), r"(?i)\.csv$" => "_roi_series.csv")
        CSV.write(roi_csv_path, roi_series_dataframe(app_run))
    catch e
        @warn "Failed to write ROI series CSV" error=string(e)
    end

    return nothing
end

function save_realtime_capture!(app, app_run, per_file_df::DataFrame)
    path = pick_realtime_save_path()
    if path === nothing
        @info "Realtime capture save cancelled"
        return nothing
    end

    payload = Dict{Symbol, Any}(
        :schema_version => 1,
        :mode => "Realtime",
        :saved_at_unix_s => time(),
        :saved_at_iso => string(Dates.now()),
        :app_state => snapshot_app_state(app),
        :runtime_vectors => Dict{Symbol, Any}(
            :timestamps => copy(app_run.timestamps[]),
            :protocol_setpoint => copy(app_run.protocol_setpoint[]),
            :command1 => copy(app_run.command1[]),
            :command2 => copy(app_run.command2[]),
            :roi_series => roi_series_dataframe(app_run),
            :histogram_ch1_latest => copy(app_run.ch1.histogram[]),
            :fit_ch1_latest => copy(app_run.ch1.fit[]),
            :counts_ch1_latest => app_run.ch1.counts[],
            :histogram_ch2_latest => copy(app_run.ch2.histogram[]),
            :fit_ch2_latest => copy(app_run.ch2.fit[]),
            :counts_ch2_latest => app_run.ch2.counts[],
            :frame_index_latest => app_run.i[]
        ),
        :per_file_dataframe => deepcopy(per_file_df),
        :irf => RUNTIME[].irf === nothing ? nothing : copy(RUNTIME[].irf),
        :irf_bin_size => RUNTIME[].irf_bin_size,
        :tcspc_window_size => RUNTIME[].tcspc_window_size,
        :data_root_path => get_data_root_path()
    )

    try
        mkpath(dirname(path))
        open(path, "w") do io
            serialize(io, payload)
        end

        csv_path = replace(path, r"(?i)\.jls$" => ".csv")
        write_realtime_capture_csv!(csv_path, app_run, per_file_df)

        @info "Realtime capture saved" path=path rows=nrow(per_file_df)
        @info "Realtime CSV export saved" path=csv_path
    catch e
        @error "Failed to save realtime capture" path=path error=string(e)
    end

    return nothing
end
