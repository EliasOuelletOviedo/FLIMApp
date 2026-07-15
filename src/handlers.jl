"""
handlers.jl

Event handlers and callbacks for the FLIM GUI.

Wires up:
- Panel switching (delegates to handlers_layout.jl / handlers_controller.jl /
  handlers_protocol.jl / handlers_console.jl for each panel's own controls)
- START/PAUSE/RESUME/STOP button actions
- IRF/data-folder path selection and serial port connect/disconnect

Uses Observables for reactive updates and on(...) bindings for event attachment.
"""

function update_start_button_label!(app_run, blocks)
    if !app_run.running[]
        blocks.start_button.label[] = "START"
    elseif app_run.paused[]
        blocks.start_button.label[] = "CONTINUE"
    else
        blocks.start_button.label[] = "PAUSE"
    end
    return nothing
end

function update_stop_button_label!(app_run, blocks)
    if app_run.running[] && !app_run.paused[]
        blocks.stop_button.label[] = "STOP"
    else
        blocks.stop_button.label[] = "CLEAR"
    end
    return nothing
end

function clear_runtime_plots!(app, app_run, blocks)
    n_hist = length(app_run.hist_time[])

    for series in channel_series(app_run)
        reset_channel_series!(series)
        series.histogram[] = fill(NaN, n_hist)
        series.fit[] = fill(NaN, n_hist)
    end

    # Replaces app_run.ch1_rois/ch2_rois wholesale (e.g. the ROI count or the
    # ROI toggle may have changed since the last run) — render_plot_selection!
    # below rebuilds the axes to match, same as after
    # rebuild_roi_channel_series! in start_pressed (runtime.jl).
    rebuild_roi_channel_series!(app, app_run)

    empty!(app_run.protocol_setpoint[])
    empty!(app_run.command1[])
    empty!(app_run.command2[])
    empty!(app_run.timestamps[])
    app_run.i[] = 0
    app_run.save_progress[] = NaN

    foreach(notify_channel_series!, channel_series(app_run))
    foreach(notify_roi_channel_series!, roi_channel_series(app_run))
    notify(app_run.protocol_setpoint)
    notify(app_run.command1)
    notify(app_run.command2)
    notify(app_run.timestamps)
    notify(app_run.i)

    render_plot_selection!(app, app_run, blocks, :plot1)
    render_plot_selection!(app, app_run, blocks, :plot2)
    return nothing
end

"""
    make_handlers(app, app_run, blocks)

Attach all GUI event handlers: panel switching (one function per panel,
see handlers_layout.jl / handlers_controller.jl / handlers_protocol.jl /
handlers_console.jl), START/PAUSE/RESUME/STOP, and path/serial-connect
buttons.
"""
function make_handlers(app, app_run, blocks::GuiBlocks)
    panel = blocks.panel_buttons
    panel_grid = blocks.panel_grid
    protocol_popup_screen = Ref{Union{Nothing, GLMakie.Screen}}(nothing)
    roi_popup_screen = Ref{Union{Nothing, GLMakie.Screen}}(nothing)

    panel_handlers = Dict{Symbol, Function}(
        :layout     => (;force=false) -> layout_panel_pressed!(app, app_run, blocks, panel, panel_grid; force=force),
        :controller => (;force=false) -> controller_panel_pressed!(app, app_run, blocks, panel, panel_grid; force=force),
        :protocol   => (;force=false) -> protocol_panel_pressed!(app, app_run, blocks, panel, panel_grid, protocol_popup_screen, roi_popup_screen; force=force),
        :console    => (;force=false) -> console_panel_pressed!(app, app_run, blocks, panel, panel_grid; force=force)
    )

    update_start_button_label!(app_run, blocks)
    update_stop_button_label!(app_run, blocks)

    on(blocks.start_button.clicks) do _
        if !app_run.running[]
            start_pressed(app, app_run, blocks)
        elseif app_run.paused[]
            resume_pressed(app_run)
        else
            pause_pressed(app_run)
        end

        update_start_button_label!(app_run, blocks)
        update_stop_button_label!(app_run, blocks)
    end

    on(blocks.stop_button.clicks) do _
        if app_run.running[] && !app_run.paused[]
            stop_pressed(app_run)
        else
            if app_run.running[]
                stop_pressed(app_run)
            end
            clear_runtime_plots!(app, app_run, blocks)
        end

        update_start_button_label!(app_run, blocks)
        update_stop_button_label!(app_run, blocks)
    end

    # Live, mid-run update: app_run.target_frequency is a Threads.Atomic{Float64}
    # (not an Observable) that start_playback's worker thread re-reads every
    # cycle, so writing to it here immediately re-paces a running Playback
    # acquisition — see acquisition.jl's start_playback docstring.
    on(blocks.target_freq_textbox.stored_string) do new_string
        parsed = tryparse(Float64, strip(new_string))
        if parsed === nothing || !isfinite(parsed) || parsed <= 0
            @warn "Invalid target frequency; ignoring" value=new_string
            return
        end

        app_run.target_frequency[] = parsed
    end

    on(blocks.irf_button.clicks) do _
        filepath = open_irf_dialog()
        if filepath === nothing
            return
        end

        try
            set_path_cache!(irf_filepath_cache(), filepath)
            update_path_textbox!(blocks.irf_path_textbox, filepath)
            @info "IRF filepath updated" path=filepath
        catch e
            @warn "Failed to update IRF filepath" error=string(e)
        end
    end

    on(blocks.folder_button.clicks) do _
        folderpath = open_folder_dialog()
        if folderpath === nothing
            return
        end

        try
            set_path_cache!(folderpath_cache(), folderpath)
            update_path_textbox!(blocks.folder_path_textbox, folderpath)
            @info "Data folder path updated" path=folderpath
        catch e
            @warn "Failed to update data folder path" error=string(e)
        end
    end

    on(blocks.connect_button.clicks) do _
        if app_run.serial_conn !== nothing
            try
                send_command(app_run.serial_conn, "A 0 AO 1 0\n")
                send_command(app_run.serial_conn, "A 0 AO 2 0\n")
                send_command(app_run.serial_conn, "A 0 AO 3 0\n")
                send_command(app_run.serial_conn, "A 0 AO 4 0\n")
                send_command(app_run.serial_conn, "A 0 DO 1 0\n")
                send_command(app_run.serial_conn, "A 0 DO 2 0\n")
                send_command(app_run.serial_conn, "A 0 DO 3 0\n")
            catch e
                @warn "Failed to send zero-signal command during disconnect" error=string(e)
            end

            try
                close(app_run.serial_conn)
                @info "Serial port disconnected"
            catch e
                @warn "Error while disconnecting serial port" error=string(e)
            end

            app_run.serial_conn = nothing
            blocks.connect_button.label[] = "CONNECT"
            return
        end

        selected_port = blocks.port_menu.selection[]
        if !(selected_port isa AbstractString) || selected_port == "No port selected"
            @warn "No port selected"
            return
        end

        ser = connect_to_port(selected_port)
        if ser === nothing
            blocks.connect_button.label[] = "CONNECT"
            return
        end

        app_run.serial_conn = ser
        blocks.connect_button.label[] = "DISCONNECT"
    end

    for (key, btn) in panel
        on(btn.clicks) do _
            panel_handlers[key]()
        end
    end

    panel_handlers[app.current_panel](force = true)

    return nothing
end
