"""
handlers_console.jl

Console panel: the live measurements of plan §9 — DAQ loop iteration time
and deadline margin, display tick interval, garbage-collector pauses,
journal backlog and dropped entries, memory — refreshed once a second by
the refresh tick (`diagnostics_text`, refresh.jl), plus a button that
restarts them.
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

        Label(panel_grid[1, 1:6]; merge(LABEL_ATTRS, Dict{Symbol, Any}(:text => "Diagnostics", :fontsize => 16))...)
        Label(panel_grid[2, 1:6]; merge(LABEL_ATTRS, Dict{Symbol, Any}(
            :text => app_run.display.diagnostics, :fontsize => 10, :justification => :left,
            :halign => :left, :valign => :top, :word_wrap => true, :tellwidth => false))...)
        reset_button = Button(panel_grid[3, 1:6]; merge(BUTTON_ATTRS, Dict{Symbol, Any}(:label => "Reset measurements", :width => nothing))...)

        on(reset_button.clicks) do _
            reset_diagnostics!(app_run.display)
            app_run.display.diagnostics[] = diagnostics_text(app_run)
        end

        app_run.display.diagnostics[] = diagnostics_text(app_run)
        foreach(n -> colsize!(panel_grid, n, 28), 1:6)
        colgap!(panel_grid, 8)
        rowgap!(panel_grid, 1, 8)
    end

    return nothing
end
