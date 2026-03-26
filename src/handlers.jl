"""
handlers.jl

Event handlers and callbacks for the FLIM GUI.

Implements all interactive behavior:
- Panel switching (Layout, Controller, Protocol, Console)
- Parameter adjustment via spinners and text inputs
- START/CLEAR button actions
- File path selection and validation

Uses Observables for reactive updates and on(...) bindings for event attachment.
"""

"""
    _pick_non_empty_path(picker::Function; error_msg::AbstractString)::Union{String, Nothing}

Execute a native picker and return a non-empty selected path, or `nothing`.
"""
function _pick_non_empty_path(picker::Function; error_msg::AbstractString)::Union{String, Nothing}
    selected = try
        picker()
    catch e
        @warn String(error_msg) error=string(e)
        nothing
    end

    if selected === nothing
        return nothing
    end

    path = String(selected)
    return isempty(strip(path)) ? nothing : path
end

"""
    open_irf_dialog()::Union{String, Nothing}

Open a file picker for IRF selection.
"""
function open_irf_dialog()::Union{String, Nothing}
    return _pick_non_empty_path(pick_file; error_msg="IRF file dialog failed")
end

"""
    open_folder_dialog()::Union{String, Nothing}

Open a folder picker for data-root selection.
"""
function open_folder_dialog()::Union{String, Nothing}
    return _pick_non_empty_path(pick_folder; error_msg="Folder dialog failed")
end

"""
    set_path_cache!(cache_path::AbstractString, path_value::AbstractString)

Write an absolute path value to the provided cache file.
"""
function set_path_cache!(cache_path::AbstractString, path_value::AbstractString)
    mkpath(dirname(cache_path))
    open(cache_path, "w") do io
        write(io, String(path_value))
    end
    return nothing
end

"""
    update_path_textbox!(textbox::Textbox, full_path::AbstractString)

Update a path textbox with only the basename for display.
"""
function update_path_textbox!(textbox::Textbox, full_path::AbstractString)
    short_name = basename(String(full_path))
    textbox.displayed_string[] = short_name
    textbox.stored_string[] = short_name
    return nothing
end

function make_handlers(app, app_run, blocks)
    panel = blocks[:panel_buttons]
    panel_grid = blocks[:panel_grid]
    protocol_popup_screen = Ref{Union{Nothing, GLMakie.Screen}}(nothing)

    # helper used by layout panel spinners – compute the "next"
    # value in a user‑friendly series (1,2,5,10,20,...).
    @inline function smart_next(val::T, min_val::S, max_val::S, ::Type{T}) where {T<:Number, S<:Number}
        if !(val > 0)
            return convert(T, min_val)
        end

        v = float(val)

        if !isfinite(v) || v <= 0.0
            return convert(T, min_val)
        end

        exp = floor(log10(v) + 1e-12)
        p = 10.0 ^ exp
        d = floor(v / p + 1e-12)

        new_v = (d + 1.0) * p

        minf = float(min_val)
        maxf = float(max_val)

        if new_v < minf
            new_v = minf
        elseif new_v > maxf
            new_v = maxf
        else
            new_v = new_v
        end

        return convert(T, new_v)
    end

    # companion to `smart_next` for stepping backwards
    @inline function smart_prev(val::T, min_val::S, max_val::S, ::Type{T}) where {T<:Number, S<:Number}
        if !(val > 0)
            return convert(T, min_val)
        end

        v = float(val)

        if !isfinite(v) || v <= 0.0
            return convert(T, min_val)
        end

        exp = floor(log10(v) + 1e-12)
        p = 10.0 ^ exp
        d = floor(v / p + 1e-12)

        if d > 1.0
            new_v = (d - 1.0) * p
        else
            new_v = 9.0 * (p / 10.0)
        end

        minf = float(min_val)
        maxf = float(max_val)

        if new_v < minf
            new_v = minf
        elseif new_v > maxf
            new_v = maxf
        else
            new_v = new_v
        end

        return convert(T, new_v)
    end

    function layout_pressed(;force::Bool=false)
        if app.current_panel != :layout || force
            panel[app.current_panel].buttoncolor[] = COLOR_3
            panel[:layout].buttoncolor[] = COLOR_2
            foreach(delete!, contents(panel_grid))
            trim!(panel_grid)
            app.current_panel = :layout
            save_state(app)

            Label(panel_grid[1, 1];   merge(LABEL_ATTRS, Dict{Symbol, Any}(:halign => :right, :text => "Time range [s] :"))...)
            Label(panel_grid[2, 1];   merge(LABEL_ATTRS, Dict{Symbol, Any}(:halign => :right, :text => "Binning :"))...)
            Label(panel_grid[3, 1];   merge(LABEL_ATTRS, Dict{Symbol, Any}(:halign => :right, :text => "Smoothing :"))...)

            Label(panel_grid[4, 1:2]; merge(LABEL_ATTRS, Dict{Symbol, Any}(:fontsize => 16,   :text => "Plot 1"))...)
            Label(panel_grid[6, 1:2]; merge(LABEL_ATTRS, Dict{Symbol, Any}(:fontsize => 16,   :text => "Plot 2"))...)

            Box(panel_grid[1, 2]; SPINNER_BOX_ATTRS...)
            Box(panel_grid[2, 2]; SPINNER_BOX_ATTRS...)
            Box(panel_grid[3, 2]; SPINNER_BOX_ATTRS...)

            Box(panel_grid[5, 1:2]; SPINNER_BOX_ATTRS...)
            Box(panel_grid[7, 1:2]; SPINNER_BOX_ATTRS...)

            options = ["Histogram", "Photon counts", "Lifetime", "Ion concentration", "Command"]

            layout_params = Dict{Symbol, Any}(
                :time_range => (Textbox(panel_grid[1, 2]; merge(SPINNER_TEXT_ATTRS, Dict(:displayed_string => string(app.layout[:time_range]), :stored_string => string(app.layout[:time_range])))...),
                                Button(panel_grid[1, 2];  SPINNER_UP_ATTRS...),
                                Button(panel_grid[1, 2];  SPINNER_DOWN_ATTRS...),
                                (1, 99999, Int)),
                :binning    => (Textbox(panel_grid[2, 2]; merge(SPINNER_TEXT_ATTRS, Dict(:displayed_string => string(app.layout[:binning]), :stored_string => string(app.layout[:binning])))...),
                                Button(panel_grid[2, 2];  SPINNER_UP_ATTRS...),
                                Button(panel_grid[2, 2];  SPINNER_DOWN_ATTRS...),
                                (1, 100, Int)),
                :smoothing  => (Textbox(panel_grid[3, 2]; merge(SPINNER_TEXT_ATTRS, Dict(:displayed_string => string(app.layout[:smoothing]), :stored_string => string(app.layout[:smoothing])))...),
                                Button(panel_grid[3, 2];  SPINNER_UP_ATTRS...),
                                Button(panel_grid[3, 2];  SPINNER_DOWN_ATTRS...),
                                (0, 10, Int)),
                :plot1      =>  Menu(panel_grid[5, 1:2];  merge(MENU_ATTRS, Dict(:default => app.layout[:plot1], :options => options))...),
                :plot2      =>  Menu(panel_grid[7, 1:2];  merge(MENU_ATTRS, Dict(:default => app.layout[:plot2], :options => options))...),
            )

            for (symbol, block) in layout_params
                if typeof(block) == Tuple{Textbox, Button, Button, Tuple{Int64, Int64, DataType}}
                    txt, up, down, (min_val, max_val, T) = block

                    on(up.clicks) do _
                        val = tryparse(T, txt.stored_string[])
                        if val === nothing
                            val = min_val
                        else
                            val = smart_next(val, min_val, max_val, T)
                        end

                        txt.displayed_string[] = string(val)
                        txt.stored_string[]  = string(val)

                        app.layout[symbol] = val
                        save_state(app)
                    end

                    on(down.clicks) do _
                        val = tryparse(T, txt.stored_string[])
                        if val === nothing
                            val = min_val
                        else
                            val = smart_prev(val, min_val, max_val, T)
                        end

                        txt.displayed_string[] = string(val)
                        txt.stored_string[]  = string(val)

                        app.layout[symbol] = val
                        save_state(app)
                    end

                    on(txt.stored_string) do new_str
                        val = tryparse(T, new_str)

                        if val !== nothing
                            val = clamp(val, min_val, max_val)
                            txt.displayed_string[] = string(val)

                            app.layout[symbol] = val
                            save_state(app)
                        end
                    end

                elseif typeof(block) == Menu
                    on(block.selection) do selection
                        plot = nothing

                        if symbol == :plot1
                            blocks[:plot_1_axis].title[] = "Plot 1\n($(selection))"
                            plot = blocks[:plot_1_axis]
                        elseif symbol == :plot2
                            blocks[:plot_2_axis].title[] = "Plot 2\n($(selection))"
                            plot = blocks[:plot_2_axis]
                        end

                        empty!(plot)

                        mapping = Dict(
                            "Histogram"       => (app_run.hist_time, app_run.histogram),
                            "Photon counts"   => (app_run.timestamps, app_run.photons),
                            "Lifetime"        => (app_run.timestamps, app_run.lifetime),
                            "Ion concentration" => (app_run.timestamps, app_run.concentration),
                            "Command"         => (app_run.timestamps, app_run.command1)
                        )

                        xy = get(mapping, selection, nothing)

                        if selection == "Command"
                            lines!(plot, app_run.timestamps, app_run.command1, color=Makie.wong_colors()[1])
                            lines!(plot, app_run.timestamps, app_run.command2, color=Makie.wong_colors()[2])
                        else
                            lines!(plot, xy..., color=Makie.wong_colors()[1])
                        end

                        if selection == "Histogram"
                            lines!(plot, app_run.hist_time, app_run.fit, color=Makie.wong_colors()[6])
                            lines!(plot, app_run.hist_time, lift(f -> normalized_irf_from_fit(f), app_run.fit), color=Makie.wong_colors()[3])
                        end

                        # if selection == "Histogram"
                        #     plt = lines!(plot, app_run.hist_time, app_run.histogram)
                        # elseif selection == "Photon counts"
                        #     plt = lines!(plot, app_run.timestamps, app_run.photons)
                        # elseif selection == "Lifetime"
                        #     plt = lines!(plot, app_run.timestamps, app_run.lifetime)
                        # elseif selection == "Ion concentration"
                        #     plt = lines!(plot, app_run.timestamps, app_run.concentration)
                        # elseif selection == "Command"
                        #     plt = lines!(plot, app_run.timestamps, app_run.command1)
                        # end
                        
                        app.layout[symbol] = selection
                        save_state(app)
                    end
                end
            end

            colsize!(panel_grid, 1, 80)
            colsize!(panel_grid, 2, 80)
            rowgap!(panel_grid, 3, 32)
            rowgap!(panel_grid, 4, 8)
            rowgap!(panel_grid, 6, 8)
        end
    end

    function controller_pressed(;force::Bool=false)
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
                :ch1_inv  => Toggle(panel_grid[2, 3];     merge(TOGGLE_ATTRS, Dict{Symbol, Any}(:active  => app.controller[:ch1_inv]))...),
                :ch1_on   => Toggle(panel_grid[2, 6];     merge(TOGGLE_ATTRS, Dict{Symbol, Any}(:active  => app.controller[:ch1_on]))...),
                :ch1_out  => Menu(panel_grid[3, 1:3];     merge(MENU_ATTRS,   Dict{Symbol, Any}(:default => app.controller[:ch1_out],  :options => ["Out 1", "Out 2", "Out 3", "Out 4"]))...),
                :ch1_mode => Menu(panel_grid[3, 4:6];     merge(MENU_ATTRS,   Dict{Symbol, Any}(:default => app.controller[:ch1_mode], :options => ["Digital", "Analog"]))...),
                :P1       => Textbox(panel_grid[5, 1:2];  merge(TEXT_ATTRS,   Dict{Symbol, Any}(:displayed_string => string(app.controller[:P1]), :stored_string => string(app.controller[:P1]), :width => 64))...),
                :I1       => Textbox(panel_grid[5, 3:4];  merge(TEXT_ATTRS,   Dict{Symbol, Any}(:displayed_string => string(app.controller[:I1]), :stored_string => string(app.controller[:I1]), :width => 64))...),
                :D1       => Textbox(panel_grid[5, 5:6];  merge(TEXT_ATTRS,   Dict{Symbol, Any}(:displayed_string => string(app.controller[:D1]), :stored_string => string(app.controller[:D1]), :width => 64))...),
                :ch2_inv  => Toggle(panel_grid[7, 3];     merge(TOGGLE_ATTRS, Dict{Symbol, Any}(:active  => app.controller[:ch2_inv]))...),
                :ch2_on   => Toggle(panel_grid[7, 6];     merge(TOGGLE_ATTRS, Dict{Symbol, Any}(:active  => app.controller[:ch2_on]))...),
                :ch2_out  => Menu(panel_grid[8, 1:3];     merge(MENU_ATTRS,   Dict{Symbol, Any}(:default => app.controller[:ch2_out],  :options => ["Out 1", "Out 2", "Out 3", "Out 4"]))...),
                :ch2_mode => Menu(panel_grid[8, 4:6];     merge(MENU_ATTRS,   Dict{Symbol, Any}(:default => app.controller[:ch2_mode], :options => ["Digital", "Analog"]))...),
                :P2       => Textbox(panel_grid[10, 1:2]; merge(TEXT_ATTRS,   Dict{Symbol, Any}(:displayed_string => string(app.controller[:P2]), :stored_string => string(app.controller[:P2]), :width => 64))...),
                :I2       => Textbox(panel_grid[10, 3:4]; merge(TEXT_ATTRS,   Dict{Symbol, Any}(:displayed_string => string(app.controller[:I2]), :stored_string => string(app.controller[:I2]), :width => 64))...),
                :D2       => Textbox(panel_grid[10, 5:6]; merge(TEXT_ATTRS,   Dict{Symbol, Any}(:displayed_string => string(app.controller[:D2]), :stored_string => string(app.controller[:D2]), :width => 64))...)
            )

            for (symbol, block) in controller_params
                if typeof(block) == Toggle
                    on(block.active) do state
                        app.controller[symbol] = state
                        save_state(app)
                    end

                elseif typeof(block) == Menu
                    on(block.i_selected) do idx
                        app.controller[symbol] = block.options[][idx]
                        save_state(app)
                    end
                    
                elseif typeof(block) == Textbox
                    on(block.stored_string) do new_str
                        val = tryparse(Float64, new_str)

                        if val !== nothing
                            block.displayed_string[] = string(val)
                            app.controller[symbol] = val
                        else
                            block.displayed_string[] = string(app.controller[symbol])
                            block.stored_string[]    = string(app.controller[symbol])
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
    end

    function protocol_pressed(;force::Bool=false)
        if app.current_panel != :protocol || force
            panel[app.current_panel].buttoncolor[] = COLOR_3
            panel[:protocol].buttoncolor[] = COLOR_2
            foreach(delete!, contents(panel_grid))
            trim!(panel_grid)
            app.current_panel = :protocol
            save_state(app)

            protocol_button = Button(panel_grid[1, 1]; merge(BUTTON_ATTRS, Dict{Symbol, Any}(:label => "Protocol"))...)
            protocol_active = Bool(get(app.protocol, :active, false))
            app.protocol[:active] = protocol_active
            protocol_toggle = Toggle(panel_grid[2, 1]; merge(TOGGLE_ATTRS, Dict{Symbol, Any}(:active => protocol_active))...)

            on(protocol_toggle.active) do is_active
                app.protocol[:active] = Bool(is_active)
                save_state(app)
            end
            
            on(protocol_button.clicks) do _
                open_protocol_popup!(app, protocol_popup_screen)
            end
        end
    end

    function console_pressed(;force::Bool=false)
        if app.current_panel != :console || force
            panel[app.current_panel].buttoncolor[] = COLOR_3
            panel[:console].buttoncolor[] = COLOR_2
            foreach(delete!, contents(panel_grid))
            trim!(panel_grid)
            app.current_panel = :console
            save_state(app)

            Label(panel_grid[1, 1]; text="CONSOLE")
        end
    end

    on(blocks[:start_button].clicks) do _
        start_pressed(app, app_run, blocks)
    end

    on(blocks[:stop_button].clicks) do _
        stop_pressed(app_run)
    end

    on(blocks[:irf_button].clicks) do _
        filepath = open_irf_dialog()
        if filepath === nothing
            return
        end

        try
            set_path_cache!(IRF_FILEPATH_CACHE, filepath)
            update_path_textbox!(blocks[:irf_path_textbox], filepath)
            @info "IRF filepath updated" path=filepath
        catch e
            @warn "Failed to update IRF filepath" error=string(e)
        end
    end

    on(blocks[:folder_button].clicks) do _
        folderpath = open_folder_dialog()
        if folderpath === nothing
            return
        end

        try
            set_path_cache!(FOLDERPATH_CACHE, folderpath)
            update_path_textbox!(blocks[:folder_path_textbox], folderpath)
            @info "Data folder path updated" path=folderpath
        catch e
            @warn "Failed to update data folder path" error=string(e)
        end
    end

    on(blocks[:connect_button].clicks) do _
        if app_run.serial_conn !== nothing
            try
                send_command(app_run.serial_conn, "A 0 AO 1 0\n")
                send_command(app_run.serial_conn, "A 0 AO 2 0\n")
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
            blocks[:connect_button].label[] = "CONNECT"
            return
        end

        selected_port = blocks[:port_menu].selection[]
        if !(selected_port isa AbstractString) || selected_port == "No port selected"
            @warn "No port selected"
            return
        end

        ser = connect_to_port(selected_port)
        if ser === nothing
            blocks[:connect_button].label[] = "CONNECT"
            return
        end

        app_run.serial_conn = ser
        blocks[:connect_button].label[] = "DISCONNECT"
    end

    handlers = Dict{Symbol, Function}(
        :layout     => layout_pressed,
        :controller => controller_pressed,
        :protocol   => protocol_pressed,
        :console    => console_pressed
    )

    for (key, btn) in panel
        on(btn.clicks) do _
            handlers[key]()
        end
    end

    handlers[app.current_panel](force = true)

    return nothing
end
