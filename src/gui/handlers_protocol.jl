"""
handlers_protocol.jl

Protocol panel: the protocol's active toggle, the Protocol popup's Edit
button, and the opto laser's PWM (its duty cycle and toggle; the frequency
fixed, `PWM_FREQUENCY_HZ`). Split out of handlers.jl's former single
make_handlers function.
"""

"""
    protocol_panel_pressed!(app, app_run, blocks, panel, panel_grid, protocol_popup_screen; force=false)

Render the Protocol panel (the protocol's active toggle and Edit button,
the PWM's toggle and duty cycle) and wire up its controls. No-op if the
Protocol panel is already showing, unless `force=true`.
"""
function protocol_panel_pressed!(app, app_run, blocks, panel, panel_grid, protocol_popup_screen; force::Bool=false)
    if app.current_panel != :protocol || force
        panel[app.current_panel].buttoncolor[] = COLOR_3
        panel[:protocol].buttoncolor[] = COLOR_2
        foreach(delete!, contents(panel_grid))
        trim!(panel_grid)
        app.current_panel = :protocol
        save_state(app)

        Label(panel_grid[1, 1:2]; merge(LABEL_ATTRS, Dict{Symbol, Any}(:text => "Active"))...)
        protocol_toggle = Toggle(panel_grid[1, 3]; merge(TOGGLE_ATTRS, Dict{Symbol, Any}(:active => app.protocol.active))...)
        protocol_button = Button(panel_grid[1, 4:6]; merge(BUTTON_ATTRS, Dict{Symbol, Any}(:label => "Edit", :width => nothing))...)
        # The opto laser's PWM, at PWM_FREQUENCY_HZ (fixed): on, the first "Duty cycle" % of each period the 1064 nm,
        # the rest the acquisition (a short label: two 28 px columns).
        Label(panel_grid[2, 1:2]; merge(LABEL_ATTRS, Dict{Symbol, Any}(:halign => :right, :text => "Duty cycle :"))...)
        pwm_toggle = Toggle(panel_grid[2, 3]; merge(TOGGLE_ATTRS, Dict{Symbol, Any}(:active => app.protocol.PWM_active))...)
        panel_spinner!(panel_grid, 2, app.protocol.PWM_duty, (1, 99), () -> app.protocol.PWM_duty,
                       duty -> (app.protocol.PWM_duty = duty; save_state(app); true))

        sync_runtime_protocol!(app, app_run)

        on(protocol_toggle.active) do is_active
            app.protocol.active = is_active
            sync_runtime_protocol!(app, app_run)
            save_state(app)
        end

        # The PWM applies from the next START (the DAQ loop's slots are built then).
        on(pwm_toggle.active) do is_active
            app.protocol.PWM_active = is_active
            save_state(app)
        end

        on(protocol_button.clicks) do _
            open_protocol_popup!(app, app_run, protocol_popup_screen)
        end

        foreach(n -> colsize!(panel_grid, n, 28), 1:6)
        colgap!(panel_grid, 8)
    end

    return nothing
end
