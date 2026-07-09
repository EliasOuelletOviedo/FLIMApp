"""
handlers_controller.jl

Controller panel: PID/output configuration for the two hardware channels.
Split out of handlers.jl's former single make_handlers function.
"""

"""
    controller_panel_pressed!(app, app_run, blocks, panel, panel_grid; force=false)

Render the Controller panel (per-channel invert/active toggles, output/mode
menus, and P/I/D textboxes) and wire up its controls. No-op if the
Controller panel is already showing, unless `force=true`.
"""
function controller_panel_pressed!(app, app_run, blocks, panel, panel_grid; force::Bool=false)
    if app.current_panel != :controller || force
        panel[app.current_panel].buttoncolor[] = COLOR_3
        panel[:controller].buttoncolor[] = COLOR_2
        foreach(delete!, contents(panel_grid))
        trim!(panel_grid)
        app.current_panel = :controller
        save_state(app)

        Box(panel_grid[3, 1:3]; BOX_ATTRS...)
        Box(panel_grid[3, 4:6]; BOX_ATTRS...)
        Box(panel_grid[8, 1:3]; BOX_ATTRS...)
        Box(panel_grid[8, 4:6]; BOX_ATTRS...)

        Label(panel_grid[1, 1:6]; merge(LABEL_ATTRS,  Dict{Symbol, Any}(:text => "Controller 1", :fontsize=>16))...)
        Label(panel_grid[2, 1:2]; merge(LABEL_ATTRS,  Dict{Symbol, Any}(:text => "Inverted"))...)
        Label(panel_grid[2, 4:5]; merge(LABEL_ATTRS,  Dict{Symbol, Any}(:text => "Active"))...)
        Label(panel_grid[4, 1:2]; merge(LABEL_ATTRS,  Dict{Symbol, Any}(:text => "P"))...)
        Label(panel_grid[4, 3:4]; merge(LABEL_ATTRS,  Dict{Symbol, Any}(:text => "I"))...)
        Label(panel_grid[4, 5:6]; merge(LABEL_ATTRS,  Dict{Symbol, Any}(:text => "D"))...)

        Label(panel_grid[6, 1:6]; merge(LABEL_ATTRS,  Dict{Symbol, Any}(:text => "Controller 2", :fontsize=>16))...)
        Label(panel_grid[7, 1:2]; merge(LABEL_ATTRS,  Dict{Symbol, Any}(:text => "Inverted"))...)
        Label(panel_grid[7, 4:5]; merge(LABEL_ATTRS,  Dict{Symbol, Any}(:text => "Active"))...)
        Label(panel_grid[9, 1:2]; merge(LABEL_ATTRS,  Dict{Symbol, Any}(:text => "P"))...)
        Label(panel_grid[9, 3:4]; merge(LABEL_ATTRS,  Dict{Symbol, Any}(:text => "I"))...)
        Label(panel_grid[9, 5:6]; merge(LABEL_ATTRS,  Dict{Symbol, Any}(:text => "D"))...)

        controller_params = Dict{Symbol, Any}(
            :ch1_inv  => Toggle(panel_grid[2, 3];     merge(TOGGLE_ATTRS, Dict{Symbol, Any}(:active  => app.controller.ch1_inv))...),
            :ch1_on   => Toggle(panel_grid[2, 6];     merge(TOGGLE_ATTRS, Dict{Symbol, Any}(:active  => app.controller.ch1_on))...),
            :ch1_out  => Menu(panel_grid[3, 1:3];     merge(MENU_ATTRS,   Dict{Symbol, Any}(:default => app.controller.ch1_out,  :options => ["Out 1", "Out 2", "Out 3", "Out 4"]))...),
            :ch1_mode => Menu(panel_grid[3, 4:6];     merge(MENU_ATTRS,   Dict{Symbol, Any}(:default => app.controller.ch1_mode, :options => ["Digital", "Analog"]))...),
            :P1       => Textbox(panel_grid[5, 1:2];  merge(TEXT_ATTRS,   Dict{Symbol, Any}(:displayed_string => string(app.controller.P1), :stored_string => string(app.controller.P1), :width => 64))...),
            :I1       => Textbox(panel_grid[5, 3:4];  merge(TEXT_ATTRS,   Dict{Symbol, Any}(:displayed_string => string(app.controller.I1), :stored_string => string(app.controller.I1), :width => 64))...),
            :D1       => Textbox(panel_grid[5, 5:6];  merge(TEXT_ATTRS,   Dict{Symbol, Any}(:displayed_string => string(app.controller.D1), :stored_string => string(app.controller.D1), :width => 64))...),
            :ch2_inv  => Toggle(panel_grid[7, 3];     merge(TOGGLE_ATTRS, Dict{Symbol, Any}(:active  => app.controller.ch2_inv))...),
            :ch2_on   => Toggle(panel_grid[7, 6];     merge(TOGGLE_ATTRS, Dict{Symbol, Any}(:active  => app.controller.ch2_on))...),
            :ch2_out  => Menu(panel_grid[8, 1:3];     merge(MENU_ATTRS,   Dict{Symbol, Any}(:default => app.controller.ch2_out,  :options => ["Out 1", "Out 2", "Out 3", "Out 4"]))...),
            :ch2_mode => Menu(panel_grid[8, 4:6];     merge(MENU_ATTRS,   Dict{Symbol, Any}(:default => app.controller.ch2_mode, :options => ["Digital", "Analog"]))...),
            :P2       => Textbox(panel_grid[10, 1:2]; merge(TEXT_ATTRS,   Dict{Symbol, Any}(:displayed_string => string(app.controller.P2), :stored_string => string(app.controller.P2), :width => 64))...),
            :I2       => Textbox(panel_grid[10, 3:4]; merge(TEXT_ATTRS,   Dict{Symbol, Any}(:displayed_string => string(app.controller.I2), :stored_string => string(app.controller.I2), :width => 64))...),
            :D2       => Textbox(panel_grid[10, 5:6]; merge(TEXT_ATTRS,   Dict{Symbol, Any}(:displayed_string => string(app.controller.D2), :stored_string => string(app.controller.D2), :width => 64))...)
        )

        for (symbol, block) in controller_params
            if typeof(block) == Toggle
                on(block.active) do state
                    setfield!(app.controller, symbol, state)
                    save_state(app)
                end

            elseif typeof(block) == Menu
                on(block.i_selected) do idx
                    setfield!(app.controller, symbol, block.options[][idx])
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

        [colsize!(panel_grid, n, 28) for n in 1:6]
        colgap!(panel_grid, 8)
        rowgap!(panel_grid, 4, 8)
        rowgap!(panel_grid, 5, 32)
        rowgap!(panel_grid, 9, 8)
    end

    return nothing
end
