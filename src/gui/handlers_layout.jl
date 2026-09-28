"""
handlers_layout.jl

Layout panel: time range / binning / smoothing spinners and the Plot 1 / Plot 2
selection menus. Split out of handlers.jl's former single make_handlers function.
"""

# helper used by layout panel spinners – compute the "next"
# value in a user‑friendly series (1,2,5,10,20,...).
@inline function smart_next(val::T, min_val::S, max_val::S, ::Type{T}) where {T<:Number, S<:Number}
    if T <: Integer
        min_t = convert(T, ceil(float(min_val)))
        max_t = convert(T, floor(float(max_val)))

        # Explicit edge handling for integer spinners (e.g. smoothing 0 <-> 1).
        if val <= min_t
            return min(min_t + one(T), max_t)
        end
    end

    if !(val > 0)
        return convert(T, min_val)
    end

    v = float(val)

    if !isfinite(v) || v <= 0.0
        return convert(T, min_val)
    end

    exp = floor(log10(v) + 1e-12)
    p = 10.0 ^ exp
    d = floor(v / p + 1e-12)

    new_v = (d + 1.0) * p

    minf = float(min_val)
    maxf = float(max_val)

    if new_v < minf
        new_v = minf
    elseif new_v > maxf
        new_v = maxf
    else
        new_v = new_v
    end

    return convert(T, new_v)
end

# companion to `smart_next` for stepping backwards
@inline function smart_prev(val::T, min_val::S, max_val::S, ::Type{T}) where {T<:Number, S<:Number}
    if T <: Integer
        min_t = convert(T, ceil(float(min_val)))

        # Explicit edge handling for integer spinners (e.g. smoothing 1 -> 0).
        if val <= min_t + one(T)
            return min_t
        end
    end

    if !(val > 0)
        return convert(T, min_val)
    end

    v = float(val)

    if !isfinite(v) || v <= 0.0
        return convert(T, min_val)
    end

    exp = floor(log10(v) + 1e-12)
    p = 10.0 ^ exp
    d = floor(v / p + 1e-12)

    if d > 1.0
        new_v = (d - 1.0) * p
    else
        new_v = 9.0 * (p / 10.0)
    end

    minf = float(min_val)
    maxf = float(max_val)

    if new_v < minf
        new_v = minf
    elseif new_v > maxf
        new_v = maxf
    else
        new_v = new_v
    end

    if T <: Integer
        # For integer spinners, keep deterministic downward stepping and
        # avoid InexactError on values like 0.9 when min_val is 0.
        return convert(T, floor(new_v + 1e-12))
    end

    return convert(T, new_v)
end

"""
    layout_panel_pressed!(app, app_run, blocks, panel, panel_grid; force=false)

Render the Layout panel (time range/binning/smoothing spinners, Plot 1/Plot 2
selection menus) and wire up its controls. No-op if the Layout panel is
already showing, unless `force=true`.
"""
function layout_panel_pressed!(app, app_run, blocks, panel, panel_grid; force::Bool=false)
    if app.current_panel != :layout || force
        panel[app.current_panel].buttoncolor[] = COLOR_3
        panel[:layout].buttoncolor[] = COLOR_2
        foreach(delete!, contents(panel_grid))
        trim!(panel_grid)
        app.current_panel = :layout
        save_state(app)

        Label(panel_grid[1, 1:3]; merge(LABEL_ATTRS, Dict{Symbol, Any}(:halign => :right, :text => "Time range [s] :"))...)
        Label(panel_grid[2, 1:3]; merge(LABEL_ATTRS, Dict{Symbol, Any}(:halign => :right, :text => "Binning :"))...)
        Label(panel_grid[3, 1:3]; merge(LABEL_ATTRS, Dict{Symbol, Any}(:halign => :right, :text => "Smoothing :"))...)

        Label(panel_grid[4, 1:4]; merge(LABEL_ATTRS, Dict{Symbol, Any}(:fontsize => 16,   :text => "Plot 1"))...)
        Label(panel_grid[4, 5:6]; merge(LABEL_ATTRS, Dict{Symbol, Any}(:fontsize => 16,   :text => "Ch"))...)
        Label(panel_grid[6, 1:4]; merge(LABEL_ATTRS, Dict{Symbol, Any}(:fontsize => 16,   :text => "Plot 2"))...)
        Label(panel_grid[6, 5:6]; merge(LABEL_ATTRS, Dict{Symbol, Any}(:fontsize => 16,   :text => "Ch"))...)

        Box(panel_grid[1, 4:6]; SPINNER_BOX_ATTRS...)
        Box(panel_grid[2, 4:6]; SPINNER_BOX_ATTRS...)
        Box(panel_grid[3, 4:6]; SPINNER_BOX_ATTRS...)

        Box(panel_grid[5, 1:4]; SPINNER_BOX_ATTRS...)
        Box(panel_grid[5, 5]; merge(SPINNER_BOX_ATTRS, Dict{Symbol, Any}(:width => 24))...)
        Box(panel_grid[5, 6]; merge(SPINNER_BOX_ATTRS, Dict{Symbol, Any}(:width => 24))...)
        Box(panel_grid[7, 1:4]; SPINNER_BOX_ATTRS...)
        Box(panel_grid[7, 5]; merge(SPINNER_BOX_ATTRS, Dict{Symbol, Any}(:width => 24))...)
        Box(panel_grid[7, 6]; merge(SPINNER_BOX_ATTRS, Dict{Symbol, Any}(:width => 24))...)

        options = ["Histogram", "Photon counts", "Lifetime", "Ion concentration", "Command"]

        smoothing_value = clamp(app.layout.smoothing, 0, 10)
        app.layout.smoothing = smoothing_value

        layout_params = Dict{Symbol, Any}(
            :time_range => (Textbox(panel_grid[1, 4:6]; merge(SPINNER_TEXT_ATTRS, Dict(:displayed_string => string(app.layout.time_range), :stored_string => string(app.layout.time_range)))...),
                            Button(panel_grid[1, 4:6];  SPINNER_UP_ATTRS...),
                            Button(panel_grid[1, 4:6];  SPINNER_DOWN_ATTRS...),
                            (1, 99999, Int)),
            :binning    => (Textbox(panel_grid[2, 4:6]; merge(SPINNER_TEXT_ATTRS, Dict(:displayed_string => string(app.layout.binning), :stored_string => string(app.layout.binning)))...),
                            Button(panel_grid[2, 4:6];  SPINNER_UP_ATTRS...),
                            Button(panel_grid[2, 4:6];  SPINNER_DOWN_ATTRS...),
                            (1, 100, Int)),
            :smoothing  => (Textbox(panel_grid[3, 4:6]; merge(SPINNER_TEXT_ATTRS, Dict(:displayed_string => string(smoothing_value), :stored_string => string(smoothing_value)))...),
                            Button(panel_grid[3, 4:6];  SPINNER_UP_ATTRS...),
                            Button(panel_grid[3, 4:6];  SPINNER_DOWN_ATTRS...),
                            (0, 10, Int)),
            :plot1      =>  Menu(panel_grid[5, 1:4];  merge(MENU_ATTRS, Dict(:default => app.layout.plot1, :options => options))...),
            :plot2      =>  Menu(panel_grid[7, 1:4];  merge(MENU_ATTRS, Dict(:default => app.layout.plot2, :options => options))...),
            :plot1_ch1  =>  Toggle(panel_grid[5, 5];  merge(TOGGLE_ATTRS, Dict{Symbol, Any}(:active => app.layout.plot1_ch1, :height => 32, :width => 32, :markersize => 32, :length => 32, :framecolor_active => PLOT_COLOR_CH1))...),
            :plot1_ch2  =>  Toggle(panel_grid[5, 6];  merge(TOGGLE_ATTRS, Dict{Symbol, Any}(:active => app.layout.plot1_ch2, :height => 32, :width => 32, :markersize => 32, :length => 32, :framecolor_active => PLOT_COLOR_CH2))...),
            :plot2_ch1  =>  Toggle(panel_grid[7, 5];  merge(TOGGLE_ATTRS, Dict{Symbol, Any}(:active => app.layout.plot2_ch1, :height => 32, :width => 32, :markersize => 32, :length => 32, :framecolor_active => PLOT_COLOR_CH1))...),
            :plot2_ch2  =>  Toggle(panel_grid[7, 6];  merge(TOGGLE_ATTRS, Dict{Symbol, Any}(:active => app.layout.plot2_ch2, :height => 32, :width => 32, :markersize => 32, :length => 32, :framecolor_active => PLOT_COLOR_CH2))...),
        )

        Label(panel_grid[5, 5]; merge(LABEL_ATTRS, Dict{Symbol, Any}(:fontsize => 16, :text => "1"))...)
        Label(panel_grid[5, 6]; merge(LABEL_ATTRS, Dict{Symbol, Any}(:fontsize => 16, :text => "2"))...)
        Label(panel_grid[7, 5]; merge(LABEL_ATTRS, Dict{Symbol, Any}(:fontsize => 16, :text => "1"))...)
        Label(panel_grid[7, 6]; merge(LABEL_ATTRS, Dict{Symbol, Any}(:fontsize => 16, :text => "2"))...)

        function commit_layout_value!(key::Symbol, value)
            setfield!(app.layout, key, value)
            if key == :smoothing
                for series in roi_channel_series(app_run)
                    recompute_roi_smooth!(app, series)
                end
            end
            save_state(app)
            return nothing
        end

        for (symbol, block) in layout_params
            if block isa Tuple{Textbox, Button, Button, Tuple{Int64, Int64, DataType}}
                textbox, up_button, down_button, (min_value, max_value, value_type) = block

                on(up_button.clicks) do _
                    parsed_value = tryparse(value_type, textbox.stored_string[])
                    next_value = parsed_value === nothing ? min_value : smart_next(parsed_value, min_value, max_value, value_type)

                    textbox.displayed_string[] = string(next_value)
                    textbox.stored_string[] = string(next_value)
                    commit_layout_value!(symbol, next_value)
                end

                on(down_button.clicks) do _
                    parsed_value = tryparse(value_type, textbox.stored_string[])
                    next_value = parsed_value === nothing ? min_value : smart_prev(parsed_value, min_value, max_value, value_type)

                    textbox.displayed_string[] = string(next_value)
                    textbox.stored_string[] = string(next_value)
                    commit_layout_value!(symbol, next_value)
                end

                on(textbox.stored_string) do new_string
                    parsed_value = tryparse(value_type, new_string)
                    if parsed_value === nothing
                        return
                    end

                    clamped_value = clamp(parsed_value, min_value, max_value)
                    textbox.displayed_string[] = string(clamped_value)
                    commit_layout_value!(symbol, clamped_value)
                end

            elseif block isa Menu
                on(block.selection) do selection
                    # commit first: render_plot! (plotting.jl) reads
                    # app.layout.plot1/plot2 directly, so the new selection
                    # must already be stored before it runs.
                    commit_layout_value!(symbol, selection)
                    render_plot!(app, app_run, blocks, symbol)
                end

            elseif block isa Toggle
                on(block.active) do state
                    commit_layout_value!(symbol, state)
                    plot_slot = symbol in (:plot1_ch1, :plot1_ch2) ? :plot1 : :plot2
                    render_plot!(app, app_run, blocks, plot_slot)
                end
            end
        end

        foreach(n -> colsize!(panel_grid, n, 28), 1:6)
        colgap!(panel_grid, 8)
        rowgap!(panel_grid, 3, 32)
        rowgap!(panel_grid, 4, 8)
        rowgap!(panel_grid, 6, 8)
    end

    return nothing
end
