"""
handlers_controller.jl

Controller panel: the PI of the 1064 nm power command (AO 0) — its on/off
and inversion, P and I gains —, the opto laser's PWM (its duty cycle and
Gate frequency, always on with the controller), and the 1064 nm's two voltages: the command's
ceiling (Max voltage) and the gate's level (Gate voltage, AO 1), each at
most the bench's limit of that output (`[limits] command_max_v`,
`gate_1064_v`). Split out of handlers.jl's former single make_handlers
function.
"""

"""
    controller_panel_pressed!(app, app_run, blocks, panel, panel_grid; force=false)

Render the Controller panel (active/inverted toggles, P/I textboxes, the
PWM's duty cycle and frequency, the Max and Gate voltages) and wire
up its controls. No `D` textbox — see `ControllerSettings`'s docstring
(data_types.jl) for why. No-op if the Controller panel is already showing,
unless `force=true`.
"""
function controller_panel_pressed!(app, app_run, blocks, panel, panel_grid; force::Bool=false)
    if app.current_panel != :controller || force
        panel[app.current_panel].buttoncolor[] = COLOR_3
        panel[:controller].buttoncolor[] = COLOR_2
        foreach(delete!, contents(panel_grid))
        trim!(panel_grid)
        app.current_panel = :controller
        save_state(app)

        Label(panel_grid[1, 1:2]; merge(LABEL_ATTRS,  Dict{Symbol, Any}(:text => "Active"))...)
        Label(panel_grid[1, 4:5]; merge(LABEL_ATTRS,  Dict{Symbol, Any}(:text => "Inverted"))...)
        Label(panel_grid[2, 1:3]; merge(LABEL_ATTRS,  Dict{Symbol, Any}(:text => "P"))...)
        Label(panel_grid[2, 4:6]; merge(LABEL_ATTRS,  Dict{Symbol, Any}(:text => "I"))...)

        controller_params = Dict{Symbol, Any}(
            :ch1_on   => Toggle(panel_grid[1, 3];     merge(TOGGLE_ATTRS, Dict{Symbol, Any}(:active  => app.controller.ch1_on))...),
            :ch1_inv  => Toggle(panel_grid[1, 6];     merge(TOGGLE_ATTRS, Dict{Symbol, Any}(:active  => app.controller.ch1_inv))...),
            :P1       => Textbox(panel_grid[3, 1:3];  merge(TEXT_ATTRS,   Dict{Symbol, Any}(:displayed_string => string(app.controller.P1), :stored_string => string(app.controller.P1), :width => 64))...),
            :I1       => Textbox(panel_grid[3, 4:6];  merge(TEXT_ATTRS,   Dict{Symbol, Any}(:displayed_string => string(app.controller.I1), :stored_string => string(app.controller.I1), :width => 64))...)
        )

        for (symbol, block) in controller_params
            if typeof(block) == Toggle
                on(block.active) do state
                    setfield!(app.controller, symbol, state)
                    symbol == :ch1_on && (app.protocol.PWM_active = state)     # the PWM goes with the controller
                    save_state(app)
                end

            elseif typeof(block) == Textbox
                on(block.stored_string) do new_str
                    val = tryparse(Float64, new_str)

                    if val !== nothing
                        block.displayed_string[] = string(val)
                        setfield!(app.controller, symbol, val)
                    else
                        block.displayed_string[] = string(getfield(app.controller, symbol))
                        block.stored_string[]    = string(getfield(app.controller, symbol))
                    end

                    save_state(app)
                end
            end
        end

        # The opto laser's PWM, always on with the controller: the first "Duty cycle" % of each period the 1064 nm,
        # the rest the acquisition; its period, the Gate frequency. From the next START.
        Label(panel_grid[4, 1:3]; merge(LABEL_ATTRS, Dict{Symbol, Any}(:halign => :right, :text => "Duty cycle [%] :"))...)
        panel_spinner!(panel_grid, 4, app.protocol.PWM_duty, (1, 99), () -> app.protocol.PWM_duty,
                       duty -> (app.protocol.PWM_duty = duty; save_state(app); true))
        Label(panel_grid[5, 1:3]; merge(LABEL_ATTRS, Dict{Symbol, Any}(:halign => :right, :text => "Gate freq [Hz] :"))...)
        panel_spinner!(panel_grid, 5, app.protocol.PWM_frequency, (1, floor(Int, app_run.config.sample_rate_hz / 2)),
                       () -> app.protocol.PWM_frequency,
                       frequency -> (app.protocol.PWM_frequency = frequency; save_state(app); true))

        # The 1064 nm's voltages, live: the command's ceiling (AO 0) and the gate's level (AO 1), each at most the
        # bench's limit of that output ([limits] in config/bench.toml, the ranges declared to NI-DAQmx).
        cfg = app_run.config
        for (row, text, field, limit) in ((6, "Max voltage [V] :", :max_voltage, cfg.command_max_v),
                                          (7, "Gate voltage [V] :", :gate_voltage, cfg.gate_1064_v))
            value = getfield(app.controller, field)
            kept = isfinite(value) ? clamp(value, 0.0, limit) : limit      # a save above today's bench limit: its limit
            kept == value || (setfield!(app.controller, field, kept); save_state(app))
            Label(panel_grid[row, 1:3]; merge(LABEL_ATTRS, Dict{Symbol, Any}(:halign => :right, :text => text))...)
            box = Textbox(panel_grid[row, 4:6]; merge(TEXT_ATTRS, Dict{Symbol, Any}(
                :displayed_string => string(kept), :stored_string => string(kept), :width => 100,
                :validator => make_float_range_validator(0.0, limit)))...)
            on(box.stored_string) do text
                volts = tryparse(Float64, strip(text))
                if volts !== nothing && isfinite(volts) && 0.0 <= volts <= limit
                    setfield!(app.controller, field, volts)
                    box.displayed_string[] = string(volts)
                    save_state(app)
                else
                    box.displayed_string[] = string(getfield(app.controller, field))
                end
            end
        end

        foreach(n -> colsize!(panel_grid, n, 28), 1:6)
        colgap!(panel_grid, 8)
        rowgap!(panel_grid, 2, 8)
    end

    return nothing
end
