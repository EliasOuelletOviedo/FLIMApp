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
    realtime_save_snapshot(app, app_run)

Copies of everything the end-of-run save writes, taken on the GUI thread
(the histories are only touched there) so the writing itself can run on
another thread.
"""
function realtime_save_snapshot(app, app_run)
    return (
        app_state = snapshot_app_state(app),
        roi_names = [r.name for r in app_run.rois[]],
        ch1_rois = deepcopy(app_run.ch1_rois),
        ch2_rois = deepcopy(app_run.ch2_rois),
        timestamps = copy(app_run.timestamps),
        protocol_setpoint = copy(app_run.protocol_setpoint),
        command1 = copy(app_run.command1),
        command2 = copy(app_run.command2),
        histogram_ch1_latest = copy(app_run.ch1.histogram[]),
        fit_ch1_latest = copy(app_run.ch1.fit[]),
        counts_ch1_latest = app_run.ch1.counts[],
        histogram_ch2_latest = copy(app_run.ch2.histogram[]),
        fit_ch2_latest = copy(app_run.ch2.fit[]),
        counts_ch2_latest = app_run.ch2.counts[],
        frame_index_latest = app_run.i,
        irf = RUNTIME[].irf === nothing ? nothing : copy(RUNTIME[].irf),
        irf_bin_size = RUNTIME[].irf_bin_size,
        tcspc_window_size = RUNTIME[].tcspc_window_size,
        data_root_path = get_data_root_path()
    )
end

"""
    roi_channel_series_dataframe(snapshot)::DataFrame

Long-format export of every (channel, ROI) time series: one row per sample,
tagged with which channel/ROI it belongs to. Long format (rather than the
padded-wide format `write_realtime_capture_csv!` uses for the global
series below) because each ROI has its own independent length AND its own
independent timestamps (see `RoiChannelSeries` in gui/app_run.jl) — there's
no single shared row index or time base to pad against once there's more
than one ROI. `snapshot` is `realtime_save_snapshot`'s result (or anything
with the same `roi_names`/`ch1_rois`/`ch2_rois` fields, e.g. an `AppRun`
through `realtime_save_snapshot`).
"""
function roi_channel_series_dataframe(snapshot)::DataFrame
    df = DataFrame(
        channel = Int[], roi_index = Int[], roi_name = String[],
        timestamp = Float64[], photons = Float64[], photons_smooth = Float64[],
        lifetime = Float64[], lifetime_smooth = Float64[],
        concentration = Float64[], concentration_smooth = Float64[]
    )

    value_at(v, k) = k <= length(v) ? Float64(v[k]) : NaN

    for (channel_idx, rois_vec) in ((1, snapshot.ch1_rois), (2, snapshot.ch2_rois))
        for (roi_idx, series) in enumerate(rois_vec)
            name = roi_idx <= length(snapshot.roi_names) ? snapshot.roi_names[roi_idx] : "roi$roi_idx"
            for k in eachindex(series.timestamps)
                push!(df, (
                    channel = channel_idx,
                    roi_index = roi_idx,
                    roi_name = name,
                    timestamp = Float64(series.timestamps[k]),
                    photons = value_at(series.photons, k),
                    photons_smooth = value_at(series.photons_smooth, k),
                    lifetime = value_at(series.lifetime, k),
                    lifetime_smooth = value_at(series.lifetime_smooth, k),
                    concentration = value_at(series.concentration, k),
                    concentration_smooth = value_at(series.concentration_smooth, k)
                ))
            end
        end
    end

    return df
end

function write_realtime_capture_csv!(csv_path::AbstractString, snapshot, per_file_df::DataFrame, roi_df::DataFrame)
    # Write per-file DataFrame to CSV
    try
        CSV.write(csv_path, per_file_df)
    catch e
        @warn "Failed to write per-file CSV" path=csv_path error=string(e)
    end

    # Global (not ROI-split) series: timestamps, protocol setpoint, and the
    # PI command outputs — command1/command2 stay a single shared series
    # regardless of ROI count: they drive real hardware output, not just a plot.
    try
        maxlen = maximum(map(length, (snapshot.timestamps, snapshot.protocol_setpoint, snapshot.command1, snapshot.command2)))

        df_runtime = DataFrame(
            timestamp = pad_to_length(Float64.(snapshot.timestamps), maxlen),
            protocol_setpoint = pad_to_length(Float64.(snapshot.protocol_setpoint), maxlen),
            command1 = pad_to_length(Float64.(snapshot.command1), maxlen),
            command2 = pad_to_length(Float64.(snapshot.command2), maxlen)
        )

        runtime_csv_path = replace(String(csv_path), r"(?i)\.csv$" => "_runtime_vectors.csv")
        CSV.write(runtime_csv_path, df_runtime)
    catch e
        @warn "Failed to write runtime vectors CSV" error=string(e)
    end

    # Per-(channel, ROI) time series, long format.
    try
        roi_csv_path = replace(String(csv_path), r"(?i)\.csv$" => "_roi_channel_series.csv")
        CSV.write(roi_csv_path, roi_df)
    catch e
        @warn "Failed to write ROI channel series CSV" error=string(e)
    end

    return nothing
end

"""
    write_realtime_capture(path, snapshot, per_file_df)

Write the serialized `.jls` payload and its companion CSVs. Heavy I/O: runs
on a worker thread (`start_realtime_save!`), from copies only.
"""
function write_realtime_capture(path::AbstractString, snapshot, per_file_df::DataFrame)
    roi_df = roi_channel_series_dataframe(snapshot)
    payload = Dict{Symbol, Any}(
        :schema_version => 1,
        :mode => "Realtime",
        :saved_at_unix_s => time(),
        :saved_at_iso => string(Dates.now()),
        :app_state => snapshot.app_state,
        :runtime_vectors => Dict{Symbol, Any}(
            :timestamps => snapshot.timestamps,
            :protocol_setpoint => snapshot.protocol_setpoint,
            :command1 => snapshot.command1,
            :command2 => snapshot.command2,
            :roi_channel_series => roi_df,
            :histogram_ch1_latest => snapshot.histogram_ch1_latest,
            :fit_ch1_latest => snapshot.fit_ch1_latest,
            :counts_ch1_latest => snapshot.counts_ch1_latest,
            :histogram_ch2_latest => snapshot.histogram_ch2_latest,
            :fit_ch2_latest => snapshot.fit_ch2_latest,
            :counts_ch2_latest => snapshot.counts_ch2_latest,
            :frame_index_latest => snapshot.frame_index_latest
        ),
        :per_file_dataframe => per_file_df,
        :irf => snapshot.irf,
        :irf_bin_size => snapshot.irf_bin_size,
        :tcspc_window_size => snapshot.tcspc_window_size,
        :data_root_path => snapshot.data_root_path
    )

    try
        mkpath(dirname(path))
        open(path, "w") do io
            serialize(io, payload)
        end

        csv_path = replace(path, r"(?i)\.jls$" => ".csv")
        write_realtime_capture_csv!(csv_path, snapshot, per_file_df, roi_df)

        @info "Realtime capture saved" path=path rows=nrow(per_file_df)
        @info "Realtime CSV export saved" path=csv_path
    catch e
        @error "Failed to save realtime capture" path=path error=string(e)
    end

    return nothing
end

"""
    start_realtime_save!(app, app_run, per_file_df)

End of a Real-time run: ask where to save (native dialog, GUI thread), copy
the histories, and write everything from a worker thread — the GUI keeps
rendering while the file is written.
"""
function start_realtime_save!(app, app_run, per_file_df::DataFrame)
    @async begin
        path = pick_realtime_save_path()
        if path === nothing
            @info "Realtime capture save cancelled"
            return nothing
        end
        snapshot = realtime_save_snapshot(app, app_run)
        Threads.@spawn write_realtime_capture(path, snapshot, per_file_df)
        return nothing
    end
    return nothing
end
