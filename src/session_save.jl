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
    roi_channel_series_dataframe(app_run)::DataFrame

Long-format export of every (channel, ROI) time series: one row per sample,
tagged with which channel/ROI it belongs to. Long format (rather than the
padded-wide format `write_realtime_capture_csv!` uses for the global
series below) because each ROI has its own independent length AND its own
independent timestamps (see `RoiChannelSeries` in data_types.jl) — there's
no single shared row index or time base to pad against once there's more
than one ROI.
"""
function roi_channel_series_dataframe(app_run)::DataFrame
    df = DataFrame(
        channel = Int[], roi_index = Int[], roi_name = String[],
        timestamp = Float64[], photons = Float64[], photons_smooth = Float64[],
        lifetime = Float64[], lifetime_smooth = Float64[],
        concentration = Float64[], concentration_smooth = Float64[]
    )

    roi_names = [r.name for r in app_run.rois[]]

    for (channel_idx, rois_vec) in ((1, app_run.ch1_rois), (2, app_run.ch2_rois))
        for (roi_idx, series) in enumerate(rois_vec)
            name = roi_idx <= length(roi_names) ? roi_names[roi_idx] : "roi$roi_idx"
            ts = series.timestamps[]
            photons = series.photons[]
            photons_smooth = series.photons_smooth[]
            lifetime = series.lifetime[]
            lifetime_smooth = series.lifetime_smooth[]
            concentration = series.concentration[]
            concentration_smooth = series.concentration_smooth[]

            for k in eachindex(ts)
                push!(df, (
                    channel = channel_idx,
                    roi_index = roi_idx,
                    roi_name = name,
                    timestamp = Float64(ts[k]),
                    photons = k <= length(photons) ? Float64(photons[k]) : NaN,
                    photons_smooth = k <= length(photons_smooth) ? Float64(photons_smooth[k]) : NaN,
                    lifetime = k <= length(lifetime) ? Float64(lifetime[k]) : NaN,
                    lifetime_smooth = k <= length(lifetime_smooth) ? Float64(lifetime_smooth[k]) : NaN,
                    concentration = k <= length(concentration) ? Float64(concentration[k]) : NaN,
                    concentration_smooth = k <= length(concentration_smooth) ? Float64(concentration_smooth[k]) : NaN
                ))
            end
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

    # Global (not ROI-split) series: timestamps, protocol setpoint, and the
    # PID command outputs — command1/command2 stay a single shared series
    # regardless of ROI count (see RoiChannelSeries's docstring, data_types.jl,
    # for why: they drive real hardware output, not just a plot).
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

    # Per-(channel, ROI) time series, long format.
    try
        roi_csv_path = replace(String(csv_path), r"(?i)\.csv$" => "_roi_channel_series.csv")
        CSV.write(roi_csv_path, roi_channel_series_dataframe(app_run))
    catch e
        @warn "Failed to write ROI channel series CSV" error=string(e)
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
            :roi_channel_series => roi_channel_series_dataframe(app_run),
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
