"""
handlers_console.jl

Console panel (currently a placeholder). Split out of handlers.jl's former
single make_handlers function.
"""

"""
    console_panel_pressed!(app, app_run, blocks, panel, panel_grid; force=false)

Render the Console panel. No-op if the Console panel is already showing,
unless `force=true`.
"""
function console_panel_pressed!(app, app_run, blocks, panel, panel_grid; force::Bool=false)
    if app.current_panel != :console || force
        panel[app.current_panel].buttoncolor[] = COLOR_3
        panel[:console].buttoncolor[] = COLOR_2
        foreach(delete!, contents(panel_grid))
        trim!(panel_grid)
        app.current_panel = :console
        save_state(app)

        Label(panel_grid[1, 1]; text="CONSOLE")
    end

    return nothing
end
