"""
handlers_console.jl

Console panel: the live measurements of plan §9 — DAQ loop iteration time
and deadline margin, display tick interval, garbage-collector pauses,
journal backlog and dropped entries, memory — refreshed once a second by
the refresh tick (`diagnostics_text`, refresh.jl), with the problems seen
(their codes: DEBUGGING.md) and what the cards received during Realtime —
plus a button that restarts the measurements and one that writes the debug
report (gui/debug_report.jl).
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
        reset_button = Button(panel_grid[3, 1:3]; merge(BUTTON_ATTRS, Dict{Symbol, Any}(:label => "Reset measurements", :width => nothing))...)
        report_button = Button(panel_grid[3, 4:6]; merge(BUTTON_ATTRS, Dict{Symbol, Any}(:label => "Debug report", :width => nothing))...)

        on(reset_button.clicks) do _
            reset_diagnostics!(app_run.display)
            app_run.display.diagnostics[] = diagnostics_text(app_run)
        end

        # Everything needed to find a bench problem, in one file to read or send.
        on(report_button.clicks) do _
            path = write_debug_report(app_run, debug_report_path(app_run); app)
            show_status!(blocks, isempty(path) ? "Debug report not written: see the log" : "Debug report: $path")
        end

        app_run.display.diagnostics[] = diagnostics_text(app_run)
        foreach(n -> colsize!(panel_grid, n, 28), 1:6)
        colgap!(panel_grid, 8)
        rowgap!(panel_grid, 1, 8)
    end

    return nothing
end
