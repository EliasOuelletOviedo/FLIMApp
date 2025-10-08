module GUI

"""
GUI.jl

Graphical user interface for the FLIM processing app.

Usage:
    using GLMakie, Observables
    using .Runner, .Controller, .IOUtils, .Processing
    s = Runner.init_state()
    GUI.create_gui(s)       # returns (fig, controls) where fig is a Makie Figure
    GUI.run_app()           # convenience that creates state and opens the GUI

Notes:
- This GUI binds to Runner.AppState and uses Observables to receive live updates.
- The GUI does not perform heavy processing; it only controls Runner and subscribes to state.latest_result.
"""
export create_gui, run_app

using GLMakie
using Observables
using Dates
using Logging

# Import local modules (adjust names if needed)
# using .Runner
# using .Controller
# using .IOU tils
# using .Processing

# ---------------------------
# Small helper utilities
# ---------------------------

# Safe folder picker: use NativeFileDialog if available, otherwise return nothing.
function _pick_folder_dialog()
    try
        @eval using NativeFileDialog
        p = NativeFileDialog.pick_folder()
        return p
    catch e
        @warn "NativeFileDialog not available; please type folder path manually." error=e
        return nothing
    end
end

# Small helper: create a command builder from a text-template.
# Template must include "{lifetime}" placeholder to substitute numeric lifetime.
function _make_command_builder(template::AbstractString)
    # returns a function that accepts a Processing.LifetimeResult and returns a string
    return function (res::Processing.LifetimeResult)
        if res === nothing
            return ""
        end
        try
            # replace placeholder
            s = replace(template, "{lifetime}" => string(res.lifetime))
            s = replace(s, "{amplitude}" => string(res.amplitude))
            s = replace(s, "{offset}" => string(res.offset))
            s = replace(s, "{residual}" => string(res.residual))
            return s
        catch e
            @warn "Command builder failed" template=template error=e
            return ""
        end
    end
end

# Nice safe wrapper for connecting to serial device and updating state.connected Observable
function _connect_device!(state::Runner.AppState, path::AbstractString; baud::Int=115200)
    try
        dev = Controller.connect_device(path; baud=baud)
        state.device = dev
        state.connected[] = true
        return true, "Connected"
    catch e
        state.device = nothing
        state.connected[] = false
        return false, string(e)
    end
end

function _disconnect_device!(state::Runner.AppState)
    if state.device !== nothing
        try
            Controller.close_device!(state.device)
        catch e
            @warn "Error when closing device" error=e
        end
    end
    state.device = nothing
    state.connected[] = false
    return nothing
end

# ---------------------------
# Main GUI builder
# ---------------------------
"""
    create_gui(state::Runner.AppState; title="FLIM App GUI") -> (fig, controls)

Create the GUI and bind it to `state`. Returns the Makie `Figure` and a `Dict` of control widgets
so you can access them programmatically for testing or automation.

The GUI includes:
- Live histogram with fitted curve overlay
- Lifetime history plot
- Controls for folder selection, monitor list, average window, IRF loading
- Serial connect/disconnect
- Start/Stop buttons for all start_* loops
- Protocol command template and activation
- Save / Analysis / Signal controls
"""
function create_gui(state::Runner.AppState; title::AbstractString="FLIM App GUI")

    # Observables local to GUI for display and reactive plotting
    hist_obs = Observable(copy(state.buffer))      # histogram data (Vector{Float64})
    fitted_obs = Observable(zeros(Float64, length(state.buffer)))  # fitted curve for overlay
    lifetime_history = Observable(Vector{Float64}())  # collect lifetimes over time
    files_obs = Observable(copy(state.monitor_files)) # displayed monitor list
    status_msg = Observable("Ready")

    # keep a simple mapping of widget objects for return
    controls = Dict{Symbol, Any}()

    # Figure & layout
    fig = Figure(resolution = (1200, 800), fontsize = 14, name = title)

    # Plots: Left (Histogram + fit), Right (Lifetime history)
    ax_hist = fig[1, 1] = Axis(fig, title = "Histogram (rolling buffer)")
    ax_lt   = fig[1, 2] = Axis(fig, title = "Lifetime history", xlabel="sample", ylabel="lifetime")

    # Plot initial lines
    # Use lift to map observables into plot data
    hist_line = lines!(ax_hist, lift(v->1:length(v), hist_obs), hist_obs; linewidth=1.5)[end]
    fit_line  = lines!(ax_hist, lift(v->1:length(v), fitted_obs), fitted_obs; linewidth=2, color=:red)[end]
    lt_line   = lines!(ax_lt, lift(v->1:length(v), lifetime_history), lifetime_history; linewidth=1.5, color=:green)[end]

    # Right side controls (in a vertical layout)
    ctrls_grid = fig[2:5, 1:2]  # reserved area for controls

    # Top row controls: Folder and Monitor list
    # Folder input: user can type or click pick
    fig[2,1] = Label(fig, "Folder (type or pick):")
    folder_textbox = TextBox(fig[2,2], text="")  # text box for folder path
    controls[:folder_textbox] = folder_textbox

    pick_btn = Button(fig[3,1], label="Pick folder")
    controls[:pick_folder] = pick_btn

    # Monitor list display and buttons
    fig[4,1] = Label(fig, "Monitor files (FIFO):")
    files_listbox = Node(files_obs[])  # fallback node for simple listing; we will update below
    # We can't rely on an advanced list widget across Makie versions; create a simple text area
    files_display = Label(fig[4,2], join(files_obs[], "\n"), tellwidth=true)
    controls[:files_display] = files_display

    add_file_btn = Button(fig[5,1], label="Add file")
    remove_file_btn = Button(fig[5,2], label="Remove first")
    clear_files_btn = Button(fig[5,3], label="Clear list")
    controls[:add_file] = add_file_btn
    controls[:remove_file] = remove_file_btn
    controls[:clear_files] = clear_files_btn

    # Middle-left: Parameters
    fig[6,1] = Label(fig, "Average window:")
    avg_input = TextBox(fig[6,2], text = string(state.average_window))
    controls[:avg_input] = avg_input

    fig[7,1] = Label(fig, "Buffer length:")
    buf_input = TextBox(fig[7,2], text = string(state.buffer_len))
    controls[:buffer_input] = buf_input

    fig[8,1] = Label(fig, "IRF file (optional):")
    irf_text = TextBox(fig[8,2], text = "")
    irf_load_btn = Button(fig[8,3], label = "Load IRF")
    controls[:irf_text] = irf_text
    controls[:irf_load] = irf_load_btn

    # Serial connect controls
    fig[9,1] = Label(fig, "Serial port (full path):")
    port_text = TextBox(fig[9,2], text = "")
    port_connect_btn = Button(fig[9,3], label="Connect")
    port_disconnect_btn = Button(fig[9,4], label="Disconnect")
    connected_label = Label(fig[9,5], "Not connected")
    controls[:port_text] = port_text
    controls[:port_connect] = port_connect_btn
    controls[:port_disconnect] = port_disconnect_btn
    controls[:connected_label] = connected_label

    # Start / Stop buttons for modes
    start_playback_btn = Button(fig[10,1], label="Start Playback")
    stop_playback_btn  = Button(fig[10,2], label="Stop Playback")

    start_real_btn = Button(fig[11,1], label="Start Real-time")
    stop_real_btn = Button(fig[11,2], label="Stop Real-time")

    start_protocol_playback_btn = Button(fig[12,1], label="Start Protocol Playback")
    stop_protocol_playback_btn  = Button(fig[12,2], label="Stop Protocol Playback")

    start_protocol_real_btn = Button(fig[13,1], label="Start Protocol Real-time")
    stop_protocol_real_btn = Button(fig[13,2], label="Stop Protocol Real-time")

    start_save_btn = Button(fig[14,1], label="Start Save")
    stop_save_btn  = Button(fig[14,2], label="Stop Save")

    start_analysis_btn = Button(fig[15,1], label="Start Analysis")
    stop_analysis_btn  = Button(fig[15,2], label="Stop Analysis")

    # Signal: command template and start/stop
    fig[16,1] = Label(fig, "Command template (use {lifetime}):")
    cmd_template = TextBox(fig[16,2], text = "CMD {lifetime}")
    start_signal_btn = Button(fig[17,1], label="Start Signal")
    stop_signal_btn  = Button(fig[17,2], label="Stop Signal")

    controls[:start_playback] = start_playback_btn
    controls[:stop_playback]  = stop_playback_btn
    controls[:start_real]     = start_real_btn
    controls[:stop_real]      = stop_real_btn
    controls[:start_protocol_playback] = start_protocol_playback_btn
    controls[:stop_protocol_playback]  = stop_protocol_playback_btn
    controls[:start_protocol_real] = start_protocol_real_btn
    controls[:stop_protocol_real]  = stop_protocol_real_btn
    controls[:start_save] = start_save_btn
    controls[:stop_save]  = stop_save_btn
    controls[:start_analysis] = start_analysis_btn
    controls[:stop_analysis]  = stop_analysis_btn
    controls[:cmd_template] = cmd_template
    controls[:start_signal] = start_signal_btn
    controls[:stop_signal]  = stop_signal_btn

    # Status bar
    status_label = Label(fig[18, 1:2], "Status: Ready")
    controls[:status_label] = status_label

    # Helper function to refresh files text display
    function _refresh_files_display!()
        files_display.text = join(state.monitor_files, "\n")
        files_obs[] = copy(state.monitor_files)
    end

    # Subscribe to changes in state.latest_result: update plots and lifetime history
    subscribe!(state.latest_result) do res
        if res === nothing
            # no new result
            return
        end
        # Update histogram view from state's buffer (copy to avoid aliasing)
        hist_obs[] = copy(state.buffer)
        # update fitted curve if available (make same length as buffer)
        fitted = res.fitted_curve
        if length(fitted) != length(state.buffer)
            # try to reshape or pad
            fitted_obs[] = vcat(float.(fitted), zeros(length(state.buffer) - length(fitted)))
        else
            fitted_obs[] = float.(fitted)
        end

        # Update lifetime history
        lh = lifetime_history[]
        push!(lh, res.lifetime)
        lifetime_history[] = lh

        # update status label
        status_label.text = "Last lifetime: $(round(res.lifetime, digits=3)) at $(Dates.format(now(), "HH:MM:SS"))"
    end

    # Update files_display when files_obs changes (rare; we update manually after modifications)
    subscribe!(files_obs) do _
        files_display.text = join(files_obs[], "\n")
    end

    # Button action bindings
    on(pick_btn.clicks) do _
        p = _pick_folder_dialog()
        if p !== nothing && p != ""
            folder_textbox.text = p
            # also store it via IOUtils if desired:
            try
                IOUtils.choose_and_store_folder("FLIM", p)
                status_label.text = "Folder stored: $p"
            catch e
                @warn "Could not store folder" error=e
            end
        else
            status_label.text = "Folder not chosen"
        end
    end

    on(add_file_btn.clicks) do _
        f = ui_show_file_picker()  # helper below to pick a file (or type)
        # fallback: prompt user to type path
        if f === nothing || f == ""
            status_label.text = "No file chosen to add"
        else
            push!(state.monitor_files, f)
            _refresh_files_display!()
            status_label.text = "Added file: $f"
        end
    end

    # We need a safe file picker for adding single files.
    function ui_show_file_picker()
        try
            @eval using NativeFileDialog
            f = NativeFileDialog.pick_file()
            return f
        catch e
            # fallback: user typed path into a dialog text box (we don't have one here)
            @warn "NativeFileDialog missing; cannot show file picker." error=e
            return nothing
        end
    end

    on(remove_file_btn.clicks) do _
        if !isempty(state.monitor_files)
            removed = popfirst!(state.monitor_files)
            _refresh_files_display!()
            status_label.text = "Removed: $removed"
        else
            status_label.text = "No files to remove"
        end
    end

    on(clear_files_btn.clicks) do _
        empty!(state.monitor_files)
        _refresh_files_display!()
        status_label.text = "Monitor list cleared"
    end

    # Parameter updates: average window & buffer length
    on(avg_input.texts) do s
        try
            val = parse(Int, s)
            state.average_window = max(1, val)
            status_label.text = "Average window set to $(state.average_window)"
        catch e
            status_label.text = "Invalid average window"
        end
    end

    on(buf_input.texts) do s
        try
            val = parse(Int, s)
            if val > 0
                state.buffer_len = val
                # resize internal buffer (careful: reset contents)
                state.buffer = zeros(Float64, val)
                hist_obs[] = copy(state.buffer)
                fitted_obs[] = zeros(Float64, val)
                status_label.text = "Buffer length set to $(val)"
            end
        catch e
            status_label.text = "Invalid buffer length"
        end
    end

    # IRF loading
    on(irf_load_btn.clicks) do _
        f = ui_show_file_picker()
        if f === nothing
            status_label.text = "No IRF file chosen"
        else
            try
                vec, histres, tm = IOUtils.open_sdt_file(f)
                # Convert to Float64 vector (normalize)
                irf_vec = float.(vec)
                # Normalization optional: scale to max 1.0
                if maximum(irf_vec) != 0
                    irf_vec ./= maximum(irf_vec)
                end
                state.irf = irf_vec
                irf_text.text = f
                status_label.text = "Loaded IRF from $(f)"
            catch e
                status_label.text = "Failed to load IRF: $(e)"
            end
        end
    end

    # Serial connect/disconnect
    on(port_connect_btn.clicks) do _
        p = port_text.text
        if isempty(p)
            status_label.text = "Please type a port path first"
        else
            ok, msg = _connect_device!(state, p)
            status_label.text = ok ? "Connected to $p" : "Connect failed: $msg"
            connected_label.text = ok ? "Connected" : "Not connected"
        end
    end

    on(port_disconnect_btn.clicks) do _
        _disconnect_device!(state)
        connected_label.text = "Not connected"
        status_label.text = "Disconnected"
    end

    # Start/Stop bindings for all Runner modes
    on(start_playback_btn.clicks) do _
        # start playback using files in state.monitor_files
        if haskey(state.tasks, :playback)
            status_label.text = "Playback already started"
        else
            task = Runner.start_playback(state)
            state.tasks[:playback] = task
            status_label.text = "Playback started"
        end
    end

    on(stop_playback_btn.clicks) do _
        if Runner.stop_task(state, :playback)
            status_label.text = "Playback stopped"
        else
            status_label.text = "No playback task to stop"
        end
    end

    # Real-time - user can supply a frame_reader (we provide a default that pops files from monitor_files)
    function _default_frame_reader()
        f = _pop_next_file!(state)
        if f === nothing return nothing end
        try
            return IOUtils.open_sdt_file(f)
        catch e
            @warn "Realtime frame read failed" error=e
            return nothing
        end
    end

    on(start_real_btn.clicks) do _
        if haskey(state.tasks, :real_time)
            status_label.text = "Real-time already running"
        else
            t = Runner.start_real_time(state, frame_reader=_default_frame_reader)
            state.tasks[:real_time] = t
            status_label.text = "Real-time started"
        end
    end

    on(stop_real_btn.clicks) do _
        if Runner.stop_task(state, :real_time)
            status_label.text = "Real-time stopped"
        else
            status_label.text = "No real-time task to stop"
        end
    end

    # Protocol playback - builder from cmd_template
    on(start_protocol_playback_btn.clicks) do _
        if haskey(state.tasks, :protocol_playback)
            status_label.text = "Protocol playback already running"
        else
            builder = _make_command_builder(cmd_template.text)
            protocol_cfg = Dict(:builder => builder)
            t = Runner.start_protocol_playback(state, protocol_cfg)
            state.tasks[:protocol_playback] = t
            status_label.text = "Protocol playback started"
        end
    end

    on(stop_protocol_playback_btn.clicks) do _
        if Runner.stop_task(state, :protocol_playback)
            state.protocol_active[] = false
            status_label.text = "Protocol playback stopped"
        else
            status_label.text = "No protocol playback task to stop"
        end
    end

    # Protocol real-time
    on(start_protocol_real_btn.clicks) do _
        if haskey(state.tasks, :protocol_real_time)
            status_label.text = "Protocol real-time already running"
        else
            builder = _make_command_builder(cmd_template.text)
            protocol_cfg = Dict(:builder => builder)
            t = Runner.start_protocol_real_time(state, protocol_cfg, frame_reader=_default_frame_reader)
            state.tasks[:protocol_real_time] = t
            status_label.text = "Protocol real-time started"
        end
    end

    on(stop_protocol_real_btn.clicks) do _
        if Runner.stop_task(state, :protocol_real_time)
            state.protocol_active[] = false
            status_label.text = "Protocol real-time stopped"
        else
            status_label.text = "No protocol real-time task to stop"
        end
    end

    # Save control: ask for path or use default
    save_path_box = TextBox(fig[14,3], text="results.csv")
    on(start_save_btn.clicks) do _
        outpath = save_path_box.text
        if isempty(outpath)
            status_label.text = "Please provide save path"
        else
            if haskey(state.tasks, :save)
                status_label.text = "Save task already running"
            else
                t = Runner.start_save(state, outpath; append=true)
                state.tasks[:save] = t
                status_label.text = "Save started to $outpath"
            end
        end
    end

    on(stop_save_btn.clicks) do _
        if Runner.stop_task(state, :save)
            status_label.text = "Save stopped"
        else
            status_label.text = "No save task to stop"
        end
    end

    # Analysis (batch)
    analysis_path_box = TextBox(fig[15,3], text="analysis.csv")
    on(start_analysis_btn.clicks) do _
        outpath = analysis_path_box.text
        if haskey(state.tasks, :analysis)
            status_label.text = "Analysis already running"
        else
            t = Runner.start_analysis(state; outpath=outpath)
            state.tasks[:analysis] = t
            status_label.text = "Analysis started"
        end
    end

    on(stop_analysis_btn.clicks) do _
        if Runner.stop_task(state, :analysis)
            status_label.text = "Analysis stopped"
        else
            status_label.text = "No analysis task to stop"
        end
    end

    # Signal start/stop
    on(start_signal_btn.clicks) do _
        if haskey(state.tasks, :signal)
            status_label.text = "Signal already running"
        else
            builder = _make_command_builder(cmd_template.text)
            t = Runner.start_signal(state, builder; interval_ms=1000, max_count=nothing)
            state.tasks[:signal] = t
            status_label.text = "Signal started"
        end
    end

    on(stop_signal_btn.clicks) do _
        if Runner.stop_task(state, :signal)
            status_label.text = "Signal stopped"
        else
            status_label.text = "No signal task to stop"
        end
    end

    # Graceful window close: stop all tasks
    on(fig.events[:close]) do _
        Runner.stop_all!(state)
    end

    # Return figure and control dictionary for automation/testing
    return fig, controls
end

# ---------------------------
# Convenience runner: create state and show GUI
# ---------------------------
"""
    run_app(; average_window=10, buffer_len=256)

Create AppState, open the GUI and return (state, fig, controls).
Useful for quick start in REPL.
"""
function run_app(; average_window::Int=10, buffer_len::Int=256)
    state = Runner.init_state(average_window=average_window, buffer_len=buffer_len)
    fig, controls = create_gui(state)
    display(fig)
    return state, fig, controls
end

end # module GUI
