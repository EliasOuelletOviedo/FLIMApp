"""
handlers.jl

Event handlers and callbacks for the FLIM GUI.

Wires up:
- Panel switching (delegates to handlers_layout.jl / handlers_controller.jl /
  handlers_protocol.jl / handlers_console.jl for each panel's own controls)
- START/PAUSE/RESUME/STOP button actions
- IRF/data-folder path selection and DAQ connect/disconnect/acknowledge
- the SPC button, which opens the SPC window (gui/spc_window.jl)

Handlers never do the work themselves (plan §2): the DAQ buttons only drop
a command for the DAQ loop thread, START spawns the analysis worker; their
effects come back through the refresh tick (refresh.jl).
"""

"""
    show_status!(blocks, message::AbstractString)

Write a short user-facing message to the info label — used to surface
failures (no IRF, missing data folder, connection error) in the window
instead of only in the console log. The refresh tick (refresh.jl) overwrites
it with the live frequency/file readout once an acquisition is running.
"""
function show_status!(blocks, message::AbstractString)
    blocks.info_label.text[] = String(message)
    return nothing
end

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

    # Replaces app_run.ch1_rois/ch2_rois wholesale (the ROI count or the
    # ROI toggle may have changed since the last run) and empties the
    # global histories — render_plot! below rebinds the curves to match.
    reset_acquisition_state!(app, app_run)

    for series in channel_series(app_run)
        series.histogram[] = fill(NaN, n_hist)
        series.fit[] = fill(NaN, n_hist)
    end

    render_plot!(app, app_run, blocks, :plot1)
    render_plot!(app, app_run, blocks, :plot2)
    return nothing
end

"""
    make_handlers(app, app_run, blocks)

Attach all GUI event handlers: panel switching (one function per panel,
see handlers_layout.jl / handlers_controller.jl / handlers_protocol.jl /
handlers_console.jl), START/PAUSE/RESUME/STOP, and path/DAQ-connect
buttons.
"""
function make_handlers(app, app_run, blocks::GuiBlocks)
    panel = blocks.panel_buttons
    panel_grid = blocks.panel_grid
    protocol_popup_screen = Ref{Union{Nothing, GLMakie.Screen}}(nothing)
    roi_popup_screen = Ref{Union{Nothing, GLMakie.Screen}}(nothing)
    spc_window_screen = Ref{Union{Nothing, GLMakie.Screen}}(nothing)

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

    # CONNECT / RESET / DISCONNECT, depending on the DAQ loop's state
    # (connect_button_label, refresh.jl). Disconnecting mid-scan raises the
    # stop flag first, so the outputs go to zero within one readback block.
    on(blocks.connect_button.clicks) do _
        ex = app_run.exchange
        state = loop_status(ex).state
        if state == LOOP_DISCONNECTED
            send_command!(ex, ConnectCommand())
        elseif state == LOOP_FAULT
            send_command!(ex, AcknowledgeCommand())
        else
            request_stop!(ex)
            send_command!(ex, DisconnectCommand())
        end
    end

    # SPC window: SPC-150N controls and live images (gui/spc_window.jl).
    on(blocks.spc_button.clicks) do _
        open_spc_window!(app_run, spc_window_screen)
    end

    for (key, btn) in panel
        on(btn.clicks) do _
            panel_handlers[key]()
        end
    end

    panel_handlers[app.current_panel](force = true)

    return nothing
end
