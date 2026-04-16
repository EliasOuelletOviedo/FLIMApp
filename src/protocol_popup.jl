"""
protocol_popup.jl

Protocol popup construction and behavior.
"""

@inline function protocol_csv_float_or_blank(value::Float64)::String
    return isnan(value) ? "" : string(value)
end

@inline function protocol_parse_csv_float_or_nan(raw_text::AbstractString)::Float64
    parsed = tryparse(Float64, strip(String(raw_text)))
    return parsed === nothing ? NaN : parsed
end

function write_protocol_csv(
    csv_path::AbstractString;
    repeats::Int,
    delay::Int,
    times::Vector{Float64},
    setpoints::Vector{Float64}
)
    row_count = min(length(times), length(setpoints))
    mkpath(dirname(String(csv_path)))

    open(csv_path, "w") do io
        write(io, "repeats,delay\n")
        write(io, string(repeats), ",", string(delay), "\n")
        write(io, "time,setpoint\n")

        for idx in 1:row_count
            write(io, protocol_csv_float_or_blank(times[idx]), ",", protocol_csv_float_or_blank(setpoints[idx]), "\n")
        end
    end

    return nothing
end

function read_protocol_csv(csv_path::AbstractString; step_count::Int)
    lines = readlines(String(csv_path))
    if length(lines) < 2
        error("CSV protocol file is incomplete")
    end

    state_parts = split(lines[2], ","; keepempty=true)
    repeats = something(tryparse(Int, strip(get(state_parts, 1, ""))), 1)
    delay = something(tryparse(Int, strip(get(state_parts, 2, ""))), 0)

    times = fill(NaN, step_count)
    setpoints = fill(NaN, step_count)

    data_start = length(lines) >= 3 ? 4 : 3
    for (row_idx, line) in enumerate(lines[data_start:end])
        row_idx > step_count && break
        parts = split(line, ","; keepempty=true)
        times[row_idx] = protocol_parse_csv_float_or_nan(get(parts, 1, ""))
        setpoints[row_idx] = protocol_parse_csv_float_or_nan(get(parts, 2, ""))
    end

    return (repeats=repeats, delay=delay, times=times, setpoints=setpoints)
end

@inline function protocol_parse_int_or(raw_text::AbstractString, default::Int)
    return something(tryparse(Int, strip(String(raw_text))), default)
end

@inline function protocol_parse_float_or_nan(raw_text::AbstractString)
    return something(tryparse(Float64, strip(String(raw_text))), NaN)
end

@inline function protocol_int_from_any(raw_value, default::Int; min_value::Int=0)
    parsed = if raw_value isa Integer
        Int(raw_value)
    elseif raw_value isa AbstractFloat
        round(Int, raw_value)
    elseif raw_value isa AbstractString
        something(tryparse(Int, strip(raw_value)), default)
    else
        default
    end
    return max(parsed, min_value)
end

function protocol_normalize_vector(raw_value, step_count::Int)
    values = fill(NaN, step_count)

    if raw_value isa AbstractVector
        limit = min(length(raw_value), step_count)
        for idx in 1:limit
            v = raw_value[idx]
            values[idx] = v isa Number ? Float64(v) : NaN
        end
    end

    return values
end

@inline function protocol_format_cell(value::Float64; integer_display::Bool=false)
    if isnan(value)
        return " "
    end

    if integer_display
        return string(round(Int, value))
    end

    return string(value)
end

function protocol_bring_popup_to_front!(screen::GLMakie.Screen)
    try
        GLMakie.GLFW.RestoreWindow(screen.glscreen)
        GLMakie.GLFW.ShowWindow(screen.glscreen)
        GLMakie.GLFW.RequestWindowAttention(screen.glscreen)
    catch e
        @warn "Unable to focus protocol popup" error=string(e)
    end
    return nothing
end

@inline function make_int_range_validator(min_value::Integer, max_value::Integer)
    @assert min_value <= max_value
    return function(raw_text::String)
        value = tryparse(Int, strip(raw_text))
        return isempty(strip(raw_text)) || (value !== nothing && min_value <= value <= max_value)
    end
end

@inline function make_float_range_validator(min_value::Real, max_value::Real)
    @assert min_value <= max_value
    return function(raw_text::String)
        value = tryparse(Float64, strip(raw_text))
        return isempty(strip(raw_text)) || (value !== nothing && min_value <= value <= max_value)
    end
end

function open_protocol_popup!(app, app_run, protocol_popup_screen::Base.RefValue{Union{Nothing, GLMakie.Screen}})
    existing_screen = protocol_popup_screen[]
    if existing_screen !== nothing && isopen(existing_screen)
        protocol_bring_popup_to_front!(existing_screen)
        return
    end

    default_protocol = get_default_protocol()
    default_step_count = length(default_protocol[:times])

    saved_repeats = protocol_int_from_any(get(app.protocol, :repeats, default_protocol[:repeats]), default_protocol[:repeats]; min_value=0)
    saved_delay = protocol_int_from_any(get(app.protocol, :delay, default_protocol[:delay]), default_protocol[:delay]; min_value=0)
    saved_times = protocol_normalize_vector(get(app.protocol, :times, default_protocol[:times]), default_step_count)
    saved_setpoints = protocol_normalize_vector(get(app.protocol, :setpoints, default_protocol[:setpoints]), default_step_count)

    app.protocol[:repeats] = saved_repeats
    app.protocol[:delay] = saved_delay
    app.protocol[:times] = copy(saved_times)
    app.protocol[:setpoints] = copy(saved_setpoints)
    sync_runtime_protocol!(app, app_run)
    save_state(app)

    popup_figure = Figure(size = (600, 400))
    popup_screen = GLMakie.Screen(resolution = (600, 400))
    protocol_popup_screen[] = popup_screen

    popup_layout = GridLayout(popup_figure[1, 1])
    plot_layout = GridLayout(popup_layout[1, 1])
    controls_layout = GridLayout(popup_layout[2, 1]; tellwidth=false)
    table_layout = GridLayout(popup_layout[3, 1]; tellwidth=false)

    protocol_axis = Axis(plot_layout[1, 1:4]; merge(AXIS_PLOTS_ATTRS, Dict{Symbol, Any}(:height => nothing, :title => "Protocol",:xlabel => "Time [s]",:ylabel => "Setpoint", :width => nothing))...)

    Label(controls_layout[1, 1], "Repeats")
    Label(controls_layout[2, 1], "Delay")

    repeats_input = Textbox(
        controls_layout[1, 2];
        merge(TEXT_ATTRS, Dict{Symbol, Any}(
            :displayed_string => string(saved_repeats),
            :stored_string => string(saved_repeats),
            :width => 72,
            :validator => make_int_range_validator(0, 1000)
        ))...
    )

    delay_input = Textbox(
        controls_layout[2, 2];
        merge(TEXT_ATTRS, Dict{Symbol, Any}(
            :displayed_string => string(saved_delay),
            :stored_string => string(saved_delay),
            :width => 72,
            :validator => make_int_range_validator(0, 3600)
        ))...
    )

    import_button = Button(controls_layout[1, 3]; merge(BUTTON_ATTRS, Dict{Symbol, Any}(:label => "Import", :width => 96))...)
    export_button = Button(controls_layout[2, 3]; merge(BUTTON_ATTRS, Dict{Symbol, Any}(:label => "Export", :width => 96))...)
    clear_button = Button(controls_layout[1, 4]; merge(BUTTON_ATTRS, Dict{Symbol, Any}(:label => "Clear", :width => 96))...)
    close_button = Button(controls_layout[2, 4]; merge(BUTTON_ATTRS, Dict{Symbol, Any}(:label => "Fermer", :width => 96))...)

    step_count = default_step_count
    step_duration_values = copy(saved_times)
    step_setpoint_values = copy(saved_setpoints)
    generated_protocol = Ref(Vector{Float64}())

    duration_inputs = Textbox[]
    setpoint_inputs = Textbox[]

    Label(table_layout[1, 0], "Time [s]"; merge(LABEL_ATTRS, Dict(:halign => :right))...)
    Label(table_layout[2, 0], "Setpoint"; merge(LABEL_ATTRS, Dict(:halign => :right))...)

    for step_idx in 1:step_count
        duration_input = Textbox(
            table_layout[1, step_idx];
            merge(TEXT_ATTRS, Dict{Symbol, Any}(
                :width => 48,
                :displayed_string => protocol_format_cell(step_duration_values[step_idx]; integer_display=true),
                :stored_string => protocol_format_cell(step_duration_values[step_idx]; integer_display=true),
                :validator => make_int_range_validator(0, 3600)
            ))...
        )

        setpoint_input = Textbox(
            table_layout[2, step_idx];
            merge(TEXT_ATTRS, Dict{Symbol, Any}(
                :width => 48,
                :displayed_string => protocol_format_cell(step_setpoint_values[step_idx]),
                :stored_string => protocol_format_cell(step_setpoint_values[step_idx]),
                :validator => make_float_range_validator(0.0, 10.0)
            ))...
        )

        push!(duration_inputs, duration_input)
        push!(setpoint_inputs, setpoint_input)
    end

    colgap!(table_layout, 2)
    rowgap!(table_layout, 2)

    function refresh_protocol_preview!()
        empty!(protocol_axis)

        delay_seconds = protocol_parse_int_or(delay_input.stored_string[], 0)
        repeat_count = max(protocol_parse_int_or(repeats_input.stored_string[], 1), 0)

        elapsed_time = float(delay_seconds)
        vlines!(protocol_axis, 0.0, color = :transparent)
        vlines!(protocol_axis, elapsed_time, color = Makie.wong_colors()[6])

        for step_idx in 1:step_count
            duration = step_duration_values[step_idx]
            setpoint = step_setpoint_values[step_idx]

            duration = isnan(duration) ? 0.0 : max(duration, 0.0)

            lines!(protocol_axis, [elapsed_time, elapsed_time + duration], [setpoint, setpoint], color = Makie.wong_colors()[1])

            if !isnan(setpoint)
                vspan!(protocol_axis, elapsed_time, elapsed_time + duration, color = Makie.wong_colors()[1], alpha = 0.1)
            end

            elapsed_time += duration
        end

        vlines!(protocol_axis, elapsed_time, color = Makie.wong_colors()[6])

        preview_repeats = repeat_count == 0 ? 1 : repeat_count
        signal_length = round(Int, max((elapsed_time - delay_seconds) * preview_repeats + delay_seconds + 1, 1))
        signal = fill(NaN, signal_length)

        elapsed_time = float(delay_seconds)
        for _ in 1:preview_repeats
            for step_idx in 1:step_count
                duration = step_duration_values[step_idx]
                setpoint = step_setpoint_values[step_idx]

                duration = isnan(duration) ? 0.0 : max(duration, 0.0)
                start_idx = clamp(round(Int, elapsed_time) + 1, 1, signal_length)
                signal[start_idx:end] .= setpoint

                elapsed_time += duration
            end
        end

        generated_protocol[] = signal
        return nothing
    end

    function persist_protocol_state!()
        app.protocol[:repeats] = protocol_parse_int_or(repeats_input.stored_string[], 1)
        app.protocol[:delay] = protocol_parse_int_or(delay_input.stored_string[], 0)
        app.protocol[:times] = copy(step_duration_values)
        app.protocol[:setpoints] = copy(step_setpoint_values)
        sync_runtime_protocol!(app, app_run)
        save_state(app)
        return nothing
    end

    on(repeats_input.stored_string) do _
        refresh_protocol_preview!()
        persist_protocol_state!()
    end

    on(delay_input.stored_string) do _
        refresh_protocol_preview!()
        persist_protocol_state!()
    end

    for step_idx in 1:step_count
        on(duration_inputs[step_idx].stored_string) do raw_text
            step_duration_values[step_idx] = protocol_parse_float_or_nan(raw_text)
            refresh_protocol_preview!()
            persist_protocol_state!()
        end

        on(setpoint_inputs[step_idx].stored_string) do raw_text
            step_setpoint_values[step_idx] = protocol_parse_float_or_nan(raw_text)
            refresh_protocol_preview!()
            persist_protocol_state!()
        end
    end

    on(import_button.clicks) do _
        csv_path = pick_non_empty_path(pick_file; error_msg="Protocol import file dialog failed")
        if csv_path === nothing
            return
        end

        try
            imported = read_protocol_csv(csv_path; step_count=step_count)

            repeats_input.displayed_string[] = string(imported.repeats)
            repeats_input.stored_string[] = string(imported.repeats)
            delay_input.displayed_string[] = string(imported.delay)
            delay_input.stored_string[] = string(imported.delay)

            for step_idx in 1:step_count
                step_duration_values[step_idx] = imported.times[step_idx]
                step_setpoint_values[step_idx] = imported.setpoints[step_idx]

                duration_inputs[step_idx].displayed_string[] = protocol_format_cell(step_duration_values[step_idx]; integer_display=true)
                duration_inputs[step_idx].stored_string[] = protocol_format_cell(step_duration_values[step_idx]; integer_display=true)

                setpoint_inputs[step_idx].displayed_string[] = protocol_format_cell(step_setpoint_values[step_idx])
                setpoint_inputs[step_idx].stored_string[] = protocol_format_cell(step_setpoint_values[step_idx])
            end

            refresh_protocol_preview!()
            persist_protocol_state!()
            @info "Protocol imported" path=csv_path
        catch e
            @warn "Failed to import protocol CSV" path=csv_path error=string(e)
        end
    end

    on(export_button.clicks) do _
        target_folder = pick_non_empty_path(pick_folder; error_msg="Protocol export folder dialog failed")
        if target_folder === nothing
            return
        end

        csv_path = joinpath(target_folder, "protocol.csv")

        try
            repeats = protocol_parse_int_or(repeats_input.stored_string[], 1)
            delay = protocol_parse_int_or(delay_input.stored_string[], 0)

            write_protocol_csv(
                csv_path;
                repeats=repeats,
                delay=delay,
                times=step_duration_values,
                setpoints=step_setpoint_values
            )

            @info "Protocol exported" path=csv_path values_count=length(generated_protocol[])
        catch e
            @warn "Failed to export protocol CSV" path=csv_path error=string(e)
        end
    end

    on(clear_button.clicks) do _
        fill!(step_duration_values, NaN)
        fill!(step_setpoint_values, NaN)

        repeats_input.displayed_string[] = "1"
        repeats_input.stored_string[] = "1"
        delay_input.displayed_string[] = "0"
        delay_input.stored_string[] = "0"

        for input in duration_inputs
            input.displayed_string[] = " "
            input.stored_string[] = " "
        end

        for input in setpoint_inputs
            input.displayed_string[] = " "
            input.stored_string[] = " "
        end

        refresh_protocol_preview!()
        persist_protocol_state!()
    end

    on(close_button.clicks) do _
        if isopen(popup_screen)
            close(popup_screen)
        end

        if protocol_popup_screen[] === popup_screen
            protocol_popup_screen[] = nothing
        end
    end

    display(popup_screen, popup_figure.scene)
    refresh_protocol_preview!()

    return nothing
end
