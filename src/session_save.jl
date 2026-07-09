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
        photons = app_run.photons[]
        lifetime = app_run.lifetime[]
        lifetime_smooth = app_run.lifetime_smooth[]
        protocol_setpoint = app_run.protocol_setpoint[]
        concentration = app_run.concentration[]
        command1 = app_run.command1[]
        command2 = app_run.command2[]

        maxlen = maximum(map(length, (ts, photons, lifetime, lifetime_smooth, protocol_setpoint, concentration, command1, command2)))

        df_runtime = DataFrame(
            timestamp = pad_to_length(Float64.(ts), maxlen),
            photons = pad_to_length(Float64.(photons), maxlen),
            lifetime = pad_to_length(Float64.(lifetime), maxlen),
            lifetime_smooth = pad_to_length(Float64.(lifetime_smooth), maxlen),
            protocol_setpoint = pad_to_length(Float64.(protocol_setpoint), maxlen),
            concentration = pad_to_length(Float64.(concentration), maxlen),
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
            :photons => copy(app_run.photons[]),
            :lifetime => copy(app_run.lifetime[]),
            :lifetime_smooth => copy(app_run.lifetime_smooth[]),
            :protocol_setpoint => copy(app_run.protocol_setpoint[]),
            :concentration => copy(app_run.concentration[]),
            :command1 => copy(app_run.command1[]),
            :command2 => copy(app_run.command2[]),
            :histogram_latest => copy(app_run.histogram[]),
            :fit_latest => copy(app_run.fit[]),
            :counts_latest => app_run.counts[],
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
