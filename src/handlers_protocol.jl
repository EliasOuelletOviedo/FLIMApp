"""
handlers_protocol.jl

Protocol panel: the Protocol/ROI popup launch buttons and their active
toggles, plus the ROI trigger-box scan-timing spinners (roi.jl reads these
back off app.protocol at Start). Split out of handlers.jl's former single
make_handlers function.
"""

"""
    protocol_panel_pressed!(app, app_run, blocks, panel, panel_grid,
                             protocol_popup_screen, roi_popup_screen; force=false)

Render the Protocol panel (Protocol/ROI buttons + active toggles + ROI
trigger-box scan-timing spinners) and wire up its controls. No-op if the
Protocol panel is already showing, unless `force=true`.
"""
function protocol_panel_pressed!(app, app_run, blocks, panel, panel_grid,
                                  protocol_popup_screen, roi_popup_screen; force::Bool=false)
    if app.current_panel != :protocol || force
        panel[app.current_panel].buttoncolor[] = COLOR_3
        panel[:protocol].buttoncolor[] = COLOR_2
        foreach(delete!, contents(panel_grid))
        trim!(panel_grid)
        app.current_panel = :protocol
        save_state(app)

        Label(panel_grid[1, 1:6]; merge(LABEL_ATTRS, Dict{Symbol, Any}(:text => "Protocol", :fontsize => 16))...)
        Label(panel_grid[2, 1:2]; merge(LABEL_ATTRS, Dict{Symbol, Any}(:text => "Active"))...)
        protocol_toggle = Toggle(panel_grid[2, 3]; merge(TOGGLE_ATTRS, Dict{Symbol, Any}(:active => app.protocol.active))...)
        protocol_button = Button(panel_grid[2, 4:6]; merge(BUTTON_ATTRS, Dict{Symbol, Any}(:label => "Edit", :width => nothing))...)

        Label(panel_grid[4, 1:6]; merge(LABEL_ATTRS, Dict{Symbol, Any}(:text => "ROI", :fontsize => 16))...)
        Label(panel_grid[5, 1:2]; merge(LABEL_ATTRS, Dict{Symbol, Any}(:text => "Active"))...)
        roi_toggle = Toggle(panel_grid[5, 3]; merge(TOGGLE_ATTRS, Dict{Symbol, Any}(:active => app.roi.active))...)
        roi_button = Button(panel_grid[5, 4:6]; merge(BUTTON_ATTRS, Dict{Symbol, Any}(:label => "Edit", :width => nothing))...)

        Label(panel_grid[3, 1:3]; merge(LABEL_ATTRS, Dict{Symbol, Any}(:halign => :right, :text => "PWM frequency :"))...)
        Label(panel_grid[6, 1:3]; merge(LABEL_ATTRS, Dict{Symbol, Any}(:halign => :right, :text => "Points per ROI :"))...)
        Label(panel_grid[7, 1:3]; merge(LABEL_ATTRS, Dict{Symbol, Any}(:halign => :right, :text => "Spiral turns :"))...)
        Label(panel_grid[8, 1:3]; merge(LABEL_ATTRS, Dict{Symbol, Any}(:halign => :right, :text => "Scan time  [ms] :"))...)
        Label(panel_grid[9, 1:3]; merge(LABEL_ATTRS, Dict{Symbol, Any}(:halign => :right, :text => "Shift time [ms] :"))...)

        Box(panel_grid[3, 4:6]; SPINNER_BOX_ATTRS...)
        Box(panel_grid[6, 4:6]; SPINNER_BOX_ATTRS...)
        Box(panel_grid[7, 4:6]; SPINNER_BOX_ATTRS...)
        Box(panel_grid[8, 4:6]; SPINNER_BOX_ATTRS...)
        Box(panel_grid[9, 4:6]; SPINNER_BOX_ATTRS...)
        
        protocol_params = Dict{Symbol, Any}(
            :PWM_frequency  => (Textbox(panel_grid[3, 4:6]; merge(SPINNER_TEXT_ATTRS, Dict(:displayed_string => string(app.protocol.PWM_frequency), :stored_string => string(app.protocol.PWM_frequency)))...),
                                 Button(panel_grid[3, 4:6];  SPINNER_UP_ATTRS...),
                                 Button(panel_grid[3, 4:6];  SPINNER_DOWN_ATTRS...),
                                 (1, 100_000, Int)),
            :points_per_roi  => (Textbox(panel_grid[6, 4:6]; merge(SPINNER_TEXT_ATTRS, Dict(:displayed_string => string(app.protocol.points_per_roi), :stored_string => string(app.protocol.points_per_roi)))...),
                                 Button(panel_grid[6, 4:6];  SPINNER_UP_ATTRS...),
                                 Button(panel_grid[6, 4:6];  SPINNER_DOWN_ATTRS...),
                                 (1, 100_000, Int)),
            :spiral_turns    => (Textbox(panel_grid[7, 4:6]; merge(SPINNER_TEXT_ATTRS, Dict(:displayed_string => string(app.protocol.spiral_turns), :stored_string => string(app.protocol.spiral_turns)))...),
                                 Button(panel_grid[7, 4:6];  SPINNER_UP_ATTRS...),
                                 Button(panel_grid[7, 4:6];  SPINNER_DOWN_ATTRS...),
                                 (0, 10, Int)),
            :scan_time       => (Textbox(panel_grid[8, 4:6]; merge(SPINNER_TEXT_ATTRS, Dict(:displayed_string => string(app.protocol.scan_time), :stored_string => string(app.protocol.scan_time)))...),
                                 Button(panel_grid[8, 4:6];  SPINNER_UP_ATTRS...),
                                 Button(panel_grid[8, 4:6];  SPINNER_DOWN_ATTRS...),
                                 (1, 1_000_000, Int)),
            :shift_time => (Textbox(panel_grid[9, 4:6]; merge(SPINNER_TEXT_ATTRS, Dict(:displayed_string => string(app.protocol.shift_time), :stored_string => string(app.protocol.shift_time)))...),
                                 Button(panel_grid[9, 4:6];  SPINNER_UP_ATTRS...),
                                 Button(panel_grid[9, 4:6];  SPINNER_DOWN_ATTRS...),
                                 (0, 1_000_000, Int)),
        )

        sync_runtime_protocol!(app, app_run)

        function commit_protocol_value!(key::Symbol, value)
            setfield!(app.protocol, key, value)
            save_state(app)
            return nothing
        end

        for (symbol, block) in protocol_params
            if block isa Tuple{Textbox, Button, Button, Tuple{Int64, Int64, DataType}}
                textbox, up_button, down_button, (min_value, max_value, value_type) = block

                on(up_button.clicks) do _
                    parsed_value = tryparse(value_type, textbox.stored_string[])
                    next_value = parsed_value === nothing ? min_value : smart_next(parsed_value, min_value, max_value, value_type)

                    textbox.displayed_string[] = string(next_value)
                    textbox.stored_string[] = string(next_value)
                    commit_protocol_value!(symbol, next_value)
                end

                on(down_button.clicks) do _
                    parsed_value = tryparse(value_type, textbox.stored_string[])
                    next_value = parsed_value === nothing ? min_value : smart_prev(parsed_value, min_value, max_value, value_type)

                    textbox.displayed_string[] = string(next_value)
                    textbox.stored_string[] = string(next_value)
                    commit_protocol_value!(symbol, next_value)
                end

                on(textbox.stored_string) do new_string
                    parsed_value = tryparse(value_type, new_string)
                    if parsed_value === nothing
                        return
                    end

                    clamped_value = clamp(parsed_value, min_value, max_value)
                    textbox.displayed_string[] = string(clamped_value)
                    commit_protocol_value!(symbol, clamped_value)
                end
            end
        end

        on(protocol_toggle.active) do is_active
            app.protocol.active = is_active
            sync_runtime_protocol!(app, app_run)
            save_state(app)
        end

        on(protocol_button.clicks) do _
            open_protocol_popup!(app, app_run, protocol_popup_screen)
        end

        on(roi_toggle.active) do is_active
            app.roi.active = is_active
            sync_runtime_protocol!(app, app_run)
            save_state(app)
        end

        on(roi_button.clicks) do _
            open_roi_popup!(app, app_run, roi_popup_screen)
        end

        [colsize!(panel_grid, n, 28) for n in 1:6]
        colgap!(panel_grid, 8)
        # [rowsize!(panel_grid, n, 32) for n in 1:4]
        rowgap!(panel_grid, 1, 8)
        rowgap!(panel_grid, 3, 32)
        rowgap!(panel_grid, 4, 8)
    end

    return nothing
end
