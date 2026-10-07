"""
handlers.jl

Event handlers and callbacks for the FLIM GUI.

Wires up:
- Panel switching (delegates to handlers_layout.jl / handlers_controller.jl /
  handlers_protocol.jl / handlers_console.jl for each panel's own controls)
- START/PAUSE/RESUME/STOP button actions
- IRF (.sdt of a Single) and Playback session selection, DAQ
  connect/reconnect/disconnect/acknowledge
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

"""
    show_recording_space!(app_run, blocks)

The free space where the sessions go (`recording_space`): in the status
line, and in the top bar's banner while it holds less than
`RECORDING_WARN_S` of recording (`RECORDING_MIN_S`: START refuses).
"""
function show_recording_space!(app_run, blocks)
    free, seconds, text = recording_space(app_run.spc.settings)
    low = free >= 0 && seconds < RECORDING_WARN_S
    show_status!(blocks, "Recording folder: " * text)
    warning = low ? "recording folder: only " * text : ""
    banner = filter(!isempty, [app_run.offline, warning])
    app_run.spc.banner = join(banner, "   ·   ")
    folder = sessions_root(app_run.spc.settings)
    low && report_problem!("ENV-05", "$folder: $text")
    # Writable? A session that can't be written is lost data: check now, not at START.
    probe = joinpath(folder, ".flimapp_write_test")
    try
        mkpath(folder)
        write(probe, "ok")
        rm(probe; force = true)
    catch e
        report_problem!("ENV-05", "$folder is not writable: " * sprint(showerror, e); level = :error)
    end
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

    on(blocks.irf_button.clicks) do _
        filepath = open_irf_dialog()
        if filepath === nothing
            return
        end

        # Imported now (kept as ~/.flimapp/irf.csv): a file that isn't a
        # Single (the SPC window's CSV, or SPCM's .sdt), or an IRF taken with
        # other card or detector settings, is refused here, not at the next START.
        try
            irfs, _ = import_irf(filepath, app_run.spc.settings; applied = spc_applied_settings(app_run.spc))
            update_path_textbox!(blocks.irf_path_textbox, filepath)
            @info "IRF imported" path=filepath channels=length(irfs)
        catch e
            @warn "IRF file refused" path=filepath error=string(e)
            show_status!(blocks, "IRF refused: " * first(split(sprint(showerror, e), '\n')))
            return
        end

        # Reload it now — or, during a run, at the next START: the fit's
        # runtime state isn't safe to change under a running worker
        # (RuntimeContext, lifetime_analysis.jl).
        if app_run.run_open
            app_run.irf_reload_pending = true
            show_status!(blocks, "IRF saved: loaded at the next START")
        else
            init_irf_runtime!(app_run.spc.settings)
            show_status!(blocks, RUNTIME[].irf === nothing ? "IRF unreadable: see the log" : "IRF loaded")
        end
    end

    # The recording folder ([enregistrement] dossier, config/spc.toml): the
    # sessions go to its sessions/, the SPC window's acquisitions next to
    # it. Rewrites spc.toml; the free space is checked right away.
    on(blocks.record_button.clicks) do _
        folderpath = open_folder_dialog()
        folderpath === nothing && return
        if app_run.run_open
            show_status!(blocks, "Recording folder: change it between runs")
            return
        end
        if spc_edit_setting!(app_run.spc, :dossier, folderpath)
            update_path_textbox!(blocks.record_path_textbox, folderpath)
            @info "Recording folder updated" path=folderpath
            show_recording_space!(app_run, blocks)
        else
            show_status!(blocks, "Recording folder refused: " * app_run.spc.last_error)
        end
    end

    # The session Playback replays: a session folder (or one made by
    # simulate_session), with its cards' streams in spc/.
    on(blocks.folder_button.clicks) do _
        folderpath = open_folder_dialog()
        folderpath === nothing && return
        if !is_session_dir(folderpath)
            show_status!(blocks, "Not a session (no spc/*.spc): $(basename(folderpath))")
            return
        end
        app_run.playback.dir = folderpath
        update_path_textbox!(blocks.folder_path_textbox, folderpath)
        try
            set_path_cache!(session_folder_cache(), folderpath)
        catch e
            @warn "Failed to remember the session folder" error=string(e)
        end
        @info "Playback session selected" path=folderpath
        show_status!(blocks, "Playback session: $(basename(folderpath))")
    end

    # CONNECT (RECONNECT after a failed connection) / RESET / DISCONNECT,
    # depending on the DAQ loop's state (connect_button_label, refresh.jl).
    # Disconnecting mid-scan raises the stop flag first, so the outputs go
    # to zero within one readback block. Offline, there is nothing to connect.
    on(blocks.connect_button.clicks) do _
        ex = app_run.exchange
        state = loop_status(ex).state
        if state == LOOP_DISCONNECTED && app_run.config.backend == :ni && isempty(Libdl.find_library(DAQmx.LIB))
            show_status!(blocks, "No NI-DAQmx driver on this computer: Playback only")
        elseif state == LOOP_DISCONNECTED
            send_command!(ex, ConnectCommand())
        elseif state == LOOP_FAULT
            send_command!(ex, AcknowledgeCommand())
        else
            request_stop!(ex)
            send_command!(ex, DisconnectCommand())
        end
    end

    # SPC window: SPC card controls and live images (gui/spc_window.jl).
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
