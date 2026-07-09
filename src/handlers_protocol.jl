"""
handlers_protocol.jl

Protocol panel: the Protocol/ROI popup launch buttons and their active
toggles. Split out of handlers.jl's former single make_handlers function.
"""

"""
    protocol_panel_pressed!(app, app_run, blocks, panel, panel_grid,
                             protocol_popup_screen, roi_popup_screen; force=false)

Render the Protocol panel (Protocol/ROI buttons + active toggles) and wire
up its controls. No-op if the Protocol panel is already showing, unless
`force=true`.
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

        protocol_button = Button(panel_grid[1, 1]; merge(BUTTON_ATTRS, Dict{Symbol, Any}(:label => "Protocol"))...)
        protocol_active = app.protocol.active
        sync_runtime_protocol!(app, app_run)
        protocol_toggle = Toggle(panel_grid[2, 1]; merge(TOGGLE_ATTRS, Dict{Symbol, Any}(:active => protocol_active))...)

        on(protocol_toggle.active) do is_active
            app.protocol.active = is_active
            sync_runtime_protocol!(app, app_run)
            save_state(app)
        end

        on(protocol_button.clicks) do _
            open_protocol_popup!(app, app_run, protocol_popup_screen)
        end

        roi_button = Button(panel_grid[3, 1]; merge(BUTTON_ATTRS, Dict{Symbol, Any}(:label => "ROI"))...)
        roi_active = app.roi.active
        roi_toggle = Toggle(panel_grid[4, 1]; merge(TOGGLE_ATTRS, Dict{Symbol, Any}(:active => roi_active))...)

        on(roi_toggle.active) do is_active
            app.roi.active = is_active
            save_state(app)
        end

        on(roi_button.clicks) do _
            open_roi_popup!(app, app_run, roi_popup_screen)
        end
    end

    return nothing
end
