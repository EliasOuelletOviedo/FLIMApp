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

function write_realtime_capture_csv!(csv_path::AbstractString, app_run, per_file_df::DataFrame)
    # Write per-file DataFrame to CSV
    try
        CSV.write(csv_path, per_file_df)
    catch e
        @warn "Failed to write per-file CSV" path=csv_path error=string(e)
    end

    # Also write runtime vectors as a companion CSV
    try
        ts = app_run.timestamps[]
        photons_ch1 = app_run.ch1.photons[]
        lifetime_ch1 = app_run.ch1.lifetime[]
        lifetime_ch1_smooth = app_run.ch1.lifetime_smooth[]
        protocol_setpoint = app_run.protocol_setpoint[]
        concentration_ch1 = app_run.ch1.concentration[]
        concentration_ch1_smooth = app_run.ch1.concentration_smooth[]
        photons_ch2 = app_run.ch2.photons[]
        lifetime_ch2 = app_run.ch2.lifetime[]
        lifetime_ch2_smooth = app_run.ch2.lifetime_smooth[]
        concentration_ch2 = app_run.ch2.concentration[]
        concentration_ch2_smooth = app_run.ch2.concentration_smooth[]
        command1 = app_run.command1[]
        command2 = app_run.command2[]

        maxlen = maximum(map(length, (ts, photons_ch1, lifetime_ch1, lifetime_ch1_smooth, protocol_setpoint, concentration_ch1, concentration_ch1_smooth, photons_ch2, lifetime_ch2, lifetime_ch2_smooth, concentration_ch2, concentration_ch2_smooth, command1, command2)))

        df_runtime = DataFrame(
            timestamp = pad_to_length(Float64.(ts), maxlen),
            photons_ch1 = pad_to_length(Float64.(photons_ch1), maxlen),
            lifetime_ch1 = pad_to_length(Float64.(lifetime_ch1), maxlen),
            lifetime_ch1_smooth = pad_to_length(Float64.(lifetime_ch1_smooth), maxlen),
            protocol_setpoint = pad_to_length(Float64.(protocol_setpoint), maxlen),
            concentration_ch1 = pad_to_length(Float64.(concentration_ch1), maxlen),
            concentration_ch1_smooth = pad_to_length(Float64.(concentration_ch1_smooth), maxlen),
            photons_ch2 = pad_to_length(Float64.(photons_ch2), maxlen),
            lifetime_ch2 = pad_to_length(Float64.(lifetime_ch2), maxlen),
            lifetime_ch2_smooth = pad_to_length(Float64.(lifetime_ch2_smooth), maxlen),
            concentration_ch2 = pad_to_length(Float64.(concentration_ch2), maxlen),
            concentration_ch2_smooth = pad_to_length(Float64.(concentration_ch2_smooth), maxlen),
            command1 = pad_to_length(Float64.(command1), maxlen),
            command2 = pad_to_length(Float64.(command2), maxlen)
        )

        runtime_csv_path = replace(String(csv_path), r"(?i)\.csv$" => "_runtime_vectors.csv")
        CSV.write(runtime_csv_path, df_runtime)
    catch e
        @warn "Failed to write runtime vectors CSV" error=string(e)
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
            :photons_ch1 => copy(app_run.ch1.photons[]),
            :lifetime_ch1 => copy(app_run.ch1.lifetime[]),
            :lifetime_ch1_smooth => copy(app_run.ch1.lifetime_smooth[]),
            :protocol_setpoint => copy(app_run.protocol_setpoint[]),
            :concentration_ch1 => copy(app_run.ch1.concentration[]),
            :concentration_ch1_smooth => copy(app_run.ch1.concentration_smooth[]),
            :photons_ch2 => copy(app_run.ch2.photons[]),
            :lifetime_ch2 => copy(app_run.ch2.lifetime[]),
            :lifetime_ch2_smooth => copy(app_run.ch2.lifetime_smooth[]),
            :concentration_ch2 => copy(app_run.ch2.concentration[]),
            :concentration_ch2_smooth => copy(app_run.ch2.concentration_smooth[]),
            :command1 => copy(app_run.command1[]),
            :command2 => copy(app_run.command2[]),
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
