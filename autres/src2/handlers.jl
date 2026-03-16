"""
handlers.jl - Event handlers for GUI panels

Manages:
- Layout panel (time range, binning, smoothing, plot selection)
- Controller panel (PID parameters, channel settings)
- Protocol panel (placeholder)
- Console panel (placeholder)
"""

"""
    make_handlers(app::AppState, app_run::AppRun, blocks::Dict)

Setup all event handlers for GUI panels and controls.
"""
function make_handlers(app::AppState, app_run::AppRun, blocks::Dict)
    panel = blocks[:panel_buttons]
    panel_grid = blocks[:panel_grid]
    
    # ========================================================================
    # SPINNER HELPERS
    # ========================================================================
    
    """Compute next magnitude step for a value"""
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
        
        if new_v < float(min_val)
            new_v = float(min_val)
        elseif new_v > float(max_val)
            new_v = float(max_val)
        end
        
        return convert(T, new_v)
    end
    
    """Compute previous magnitude step for a value"""
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
        
        new_v = if d > 1.0
            (d - 1.0) * p
        else
            9.0 * (p / 10.0)
        end
        
        if new_v < float(min_val)
            new_v = float(min_val)
        elseif new_v > float(max_val)
            new_v = float(max_val)
        end
        
        return convert(T, new_v)
    end
    
    # ========================================================================
    # LAYOUT PANEL
    # ========================================================================
    
    function layout_pressed(; force::Bool=false)
        if app.current_panel != :layout || force
            # Deselect previous panel
            if app.current_panel != :layout
                panel[app.current_panel].buttoncolor[] = COLOR_3
            end
            panel[:layout].buttoncolor[] = COLOR_2
            
            # Clear and rebuild
            foreach(delete!, contents(panel_grid))
            trim!(panel_grid)
            
            app.current_panel = :layout
            save_state_atomic(app)
            
            # Labels
            Label(panel_grid[1, 1]; merge(LABEL_ATTRS, Dict(:halign => :right, :text => "Time range [s] :"))...)
            Label(panel_grid[2, 1]; merge(LABEL_ATTRS, Dict(:halign => :right, :text => "Binning :"))...)
            Label(panel_grid[3, 1]; merge(LABEL_ATTRS, Dict(:halign => :right, :text => "Smoothing :"))...)
            Label(panel_grid[4, 1:2]; merge(LABEL_ATTRS, Dict(:fontsize => 16, :text => "Plot 1"))...)
            Label(panel_grid[6, 1:2]; merge(LABEL_ATTRS, Dict(:fontsize => 16, :text => "Plot 2"))...)
            
            Box(panel_grid[1, 2]; SPINNER_BOX_ATTRS...)
            Box(panel_grid[2, 2]; SPINNER_BOX_ATTRS...)
            Box(panel_grid[3, 2]; SPINNER_BOX_ATTRS...)
            Box(panel_grid[5, 1:2]; SPINNER_BOX_ATTRS...)
            Box(panel_grid[7, 1:2]; SPINNER_BOX_ATTRS...)
            
            options = ["Histogram", "Photon counts", "Lifetime", "Ion concentration", "Command"]
            
            layout_params = Dict{Symbol, Any}(
                :time_range => (
                    Textbox(panel_grid[1, 2]; merge(SPINNER_TEXT_ATTRS, 
                        Dict(:displayed_string => string(app.layout.time_range),
                             :stored_string => string(app.layout.time_range)))...),
                    Button(panel_grid[1, 2]; SPINNER_UP_ATTRS...),
                    Button(panel_grid[1, 2]; SPINNER_DOWN_ATTRS...),
                    (1, 99999, Int)
                ),
                :binning => (
                    Textbox(panel_grid[2, 2]; merge(SPINNER_TEXT_ATTRS,
                        Dict(:displayed_string => string(app.layout.binning),
                             :stored_string => string(app.layout.binning)))...),
                    Button(panel_grid[2, 2]; SPINNER_UP_ATTRS...),
                    Button(panel_grid[2, 2]; SPINNER_DOWN_ATTRS...),
                    (1, 100, Int)
                ),
                :smoothing => (
                    Textbox(panel_grid[3, 2]; merge(SPINNER_TEXT_ATTRS,
                        Dict(:displayed_string => string(app.layout.smoothing),
                             :stored_string => string(app.layout.smoothing)))...),
                    Button(panel_grid[3, 2]; SPINNER_UP_ATTRS...),
                    Button(panel_grid[3, 2]; SPINNER_DOWN_ATTRS...),
                    (0, 10, Int)
                ),
                :plot1 => Menu(panel_grid[5, 1:2]; merge(MENU_ATTRS,
                    Dict(:default => app.layout.plot1, :options => options))...),
                :plot2 => Menu(panel_grid[7, 1:2]; merge(MENU_ATTRS,
                    Dict(:default => app.layout.plot2, :options => options))...)
            )
            
            # Setup spinner handlers
            for (symbol, block) in layout_params
                if isa(block, Tuple{Textbox, Button, Button, Tuple{Int64, Int64, DataType}})
                    txt, up, down, (min_val, max_val, T) = block
                    
                    on(up.clicks) do _
                        val = tryparse(T, txt.stored_string[])
                        if val === nothing
                            val = min_val
                        else
                            val = smart_next(val, min_val, max_val, T)
                        end
                        txt.displayed_string[] = string(val)
                        txt.stored_string[] = string(val)
                        app.layout = LayoutState(
                            symbol == :time_range ? val : app.layout.time_range,
                            symbol == :binning ? val : app.layout.binning,
                            symbol == :smoothing ? val : app.layout.smoothing,
                            app.layout.plot1, app.layout.plot2
                        )
                        save_state_atomic(app)
                    end
                    
                    on(down.clicks) do _
                        val = tryparse(T, txt.stored_string[])
                        if val === nothing
                            val = min_val
                        else
                            val = smart_prev(val, min_val, max_val, T)
                        end
                        txt.displayed_string[] = string(val)
                        txt.stored_string[] = string(val)
                        app.layout = LayoutState(
                            symbol == :time_range ? val : app.layout.time_range,
                            symbol == :binning ? val : app.layout.binning,
                            symbol == :smoothing ? val : app.layout.smoothing,
                            app.layout.plot1, app.layout.plot2
                        )
                        save_state_atomic(app)
                    end
                    
                    on(txt.stored_string) do new_str
                        val = tryparse(T, new_str)
                        if val !== nothing
                            val = clamp(val, min_val, max_val)
                            txt.displayed_string[] = string(val)
                            app.layout = LayoutState(
                                symbol == :time_range ? val : app.layout.time_range,
                                symbol == :binning ? val : app.layout.binning,
                                symbol == :smoothing ? val : app.layout.smoothing,
                                app.layout.plot1, app.layout.plot2
                            )
                            save_state_atomic(app)
                        end
                    end
                
                elseif isa(block, Menu)
                    on(block.selection) do selection
                        plot = nothing
                        if symbol == :plot1
                            blocks[:plot_1_axis].title[] = "Plot 1\n($selection)"
                            plot = blocks[:plot_1_axis]
                        elseif symbol == :plot2
                            blocks[:plot_2_axis].title[] = "Plot 2\n($selection)"
                            plot = blocks[:plot_2_axis]
                        end
                        
                        if !isnothing(plot)
                            empty!(plot)
                            
                            mapping = Dict(
                                "Histogram"           => (app_run.hist_time, app_run.histogram),
                                "Photon counts"       => (app_run.timestamps, app_run.photons),
                                "Lifetime"            => (app_run.timestamps, app_run.lifetime),
                                "Ion concentration"   => (app_run.timestamps, app_run.concentration),
                                "Command"             => (app_run.timestamps, app_run.i)
                            )
                            
                            xy = get(mapping, selection, nothing)
                            if !isnothing(xy)
                                lines!(plot, xy..., color=Makie.wong_colors()[1])
                            end
                            
                            if selection == "Histogram" && !isnothing(xy)
                                lines!(plot, app_run.hist_time, app_run.fit, color=Makie.wong_colors()[6])
                            end
                        end
                        
                        # Update state
                        if symbol == :plot1
                            app.layout = LayoutState(app.layout.time_range, app.layout.binning, 
                                                    app.layout.smoothing, selection, app.layout.plot2)
                        else
                            app.layout = LayoutState(app.layout.time_range, app.layout.binning,
                                                    app.layout.smoothing, app.layout.plot1, selection)
                        end
                        save_state_atomic(app)
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
    
    # ========================================================================
    # CONTROLLER PANEL
    # ========================================================================
    
    function controller_pressed(; force::Bool=false)
        if app.current_panel != :controller || force
            if app.current_panel != :controller
                panel[app.current_panel].buttoncolor[] = COLOR_3
            end
            panel[:controller].buttoncolor[] = COLOR_2
            
            foreach(delete!, contents(panel_grid))
            trim!(panel_grid)
            
            app.current_panel = :controller
            save_state_atomic(app)
            
            # Layout boxes
            Box(panel_grid[3, 1:3]; BOX_ATTRS...)
            Box(panel_grid[3, 4:6]; BOX_ATTRS...)
            Box(panel_grid[8, 1:3]; BOX_ATTRS...)
            Box(panel_grid[8, 4:6]; BOX_ATTRS...)
            
            # Labels
            Label(panel_grid[1, 1:6]; merge(LABEL_ATTRS, Dict(:text => "Controller 1", :fontsize => 16))...)
            Label(panel_grid[2, 1:2]; merge(LABEL_ATTRS, Dict(:text => "Inverted"))...)
            Label(panel_grid[2, 4:5]; merge(LABEL_ATTRS, Dict(:text => "Active"))...)
            Label(panel_grid[4, 1:2]; merge(LABEL_ATTRS, Dict(:text => "P"))...)
            Label(panel_grid[4, 3:4]; merge(LABEL_ATTRS, Dict(:text => "I"))...)
            Label(panel_grid[4, 5:6]; merge(LABEL_ATTRS, Dict(:text => "D"))...)
            Label(panel_grid[6, 1:6]; merge(LABEL_ATTRS, Dict(:text => "Controller 2", :fontsize => 16))...)
            Label(panel_grid[7, 1:2]; merge(LABEL_ATTRS, Dict(:text => "Inverted"))...)
            Label(panel_grid[7, 4:5]; merge(LABEL_ATTRS, Dict(:text => "Active"))...)
            Label(panel_grid[9, 1:2]; merge(LABEL_ATTRS, Dict(:text => "P"))...)
            Label(panel_grid[9, 3:4]; merge(LABEL_ATTRS, Dict(:text => "I"))...)
            Label(panel_grid[9, 5:6]; merge(LABEL_ATTRS, Dict(:text => "D"))...)
            
            controller_params = Dict{Symbol, Any}(
                :ch1_inv  => Toggle(panel_grid[2, 3]; merge(TOGGLE_ATTRS, Dict(:active => app.controller.ch1_inv))...),
                :ch1_on   => Toggle(panel_grid[2, 6]; merge(TOGGLE_ATTRS, Dict(:active => app.controller.ch1_on))...),
                :ch1_out  => Menu(panel_grid[3, 1:3]; merge(MENU_ATTRS, Dict(:default => app.controller.ch1_out, :options => ["Out 1", "Out 2", "Out 3", "Out 4"]))...),
                :ch1_mode => Menu(panel_grid[3, 4:6]; merge(MENU_ATTRS, Dict(:default => app.controller.ch1_mode, :options => ["Digital", "Analog"]))...),
                :P1       => Textbox(panel_grid[5, 1:2]; merge(TEXT_ATTRS, Dict(:displayed_string => string(app.controller.P1), :stored_string => string(app.controller.P1)))...),
                :I1       => Textbox(panel_grid[5, 3:4]; merge(TEXT_ATTRS, Dict(:displayed_string => string(app.controller.I1), :stored_string => string(app.controller.I1)))...),
                :D1       => Textbox(panel_grid[5, 5:6]; merge(TEXT_ATTRS, Dict(:displayed_string => string(app.controller.D1), :stored_string => string(app.controller.D1)))...),
                :ch2_inv  => Toggle(panel_grid[7, 3]; merge(TOGGLE_ATTRS, Dict(:active => app.controller.ch2_inv))...),
                :ch2_on   => Toggle(panel_grid[7, 6]; merge(TOGGLE_ATTRS, Dict(:active => app.controller.ch2_on))...),
                :ch2_out  => Menu(panel_grid[8, 1:3]; merge(MENU_ATTRS, Dict(:default => app.controller.ch2_out, :options => ["Out 1", "Out 2", "Out 3", "Out 4"]))...),
                :ch2_mode => Menu(panel_grid[8, 4:6]; merge(MENU_ATTRS, Dict(:default => app.controller.ch2_mode, :options => ["Digital", "Analog"]))...),
                :P2       => Textbox(panel_grid[10, 1:2]; merge(TEXT_ATTRS, Dict(:displayed_string => string(app.controller.P2), :stored_string => string(app.controller.P2)))...),
                :I2       => Textbox(panel_grid[10, 3:4]; merge(TEXT_ATTRS, Dict(:displayed_string => string(app.controller.I2), :stored_string => string(app.controller.I2)))...),
                :D2       => Textbox(panel_grid[10, 5:6]; merge(TEXT_ATTRS, Dict(:displayed_string => string(app.controller.D2), :stored_string => string(app.controller.D2)))...)
            )
            
            for (symbol, widget) in controller_params
                if isa(widget, Toggle)
                    on(widget.active) do state
                        # Update immutable struct with new value
                        app.controller = ControllerState(
                            symbol == :ch1_inv ? state : app.controller.ch1_inv,
                            symbol == :ch1_on ? state : app.controller.ch1_on,
                            app.controller.ch1_out, app.controller.ch1_mode,
                            app.controller.P1, app.controller.I1, app.controller.D1,
                            symbol == :ch2_inv ? state : app.controller.ch2_inv,
                            symbol == :ch2_on ? state : app.controller.ch2_on,
                            app.controller.ch2_out, app.controller.ch2_mode,
                            app.controller.P2, app.controller.I2, app.controller.D2
                        )
                        save_state_atomic(app)
                    end
                elseif isa(widget, Menu)
                    on(widget.i_selected) do idx
                        new_value = widget.options[][idx]
                        app.controller = ControllerState(
                            app.controller.ch1_inv, app.controller.ch1_on,
                            symbol == :ch1_out ? new_value : app.controller.ch1_out,
                            symbol == :ch1_mode ? new_value : app.controller.ch1_mode,
                            app.controller.P1, app.controller.I1, app.controller.D1,
                            app.controller.ch2_inv, app.controller.ch2_on,
                            symbol == :ch2_out ? new_value : app.controller.ch2_out,
                            symbol == :ch2_mode ? new_value : app.controller.ch2_mode,
                            app.controller.P2, app.controller.I2, app.controller.D2
                        )
                        save_state_atomic(app)
                    end
                elseif isa(widget, Textbox)
                    on(widget.stored_string) do new_str
                        val = tryparse(Int, new_str)
                        if val !== nothing
                            widget.displayed_string[] = string(val)
                            # Update immutable struct
                            param_map = Dict(
                                :P1 => (app.controller.P1, :P1), :I1 => (app.controller.I1, :I1), :D1 => (app.controller.D1, :D1),
                                :P2 => (app.controller.P2, :P2), :I2 => (app.controller.I2, :I2), :D2 => (app.controller.D2, :D2)
                            )
                            if haskey(param_map, symbol)
                                app.controller = ControllerState(
                                    app.controller.ch1_inv, app.controller.ch1_on,
                                    app.controller.ch1_out, app.controller.ch1_mode,
                                    symbol == :P1 ? val : app.controller.P1,
                                    symbol == :I1 ? val : app.controller.I1,
                                    symbol == :D1 ? val : app.controller.D1,
                                    app.controller.ch2_inv, app.controller.ch2_on,
                                    app.controller.ch2_out, app.controller.ch2_mode,
                                    symbol == :P2 ? val : app.controller.P2,
                                    symbol == :I2 ? val : app.controller.I2,
                                    symbol == :D2 ? val : app.controller.D2
                                )
                                save_state_atomic(app)
                            end
                        else
                            widget.displayed_string[] = string(param_map[symbol][1])
                            widget.stored_string[] = string(param_map[symbol][1])
                        end
                    end
                end
            end
            
            foreach(n -> colsize!(panel_grid, n, 28), 1:6)
            colgap!(panel_grid, 8)
            rowgap!(panel_grid, 4, 8)
            rowgap!(panel_grid, 5, 32)
            rowgap!(panel_grid, 9, 8)
        end
    end
    
    # ========================================================================
    # PROTOCOL & CONSOLE PANELS
    # ========================================================================
    
    function protocol_pressed(; force::Bool=false)
        if app.current_panel != :protocol || force
            if app.current_panel != :protocol
                panel[app.current_panel].buttoncolor[] = COLOR_3
            end
            panel[:protocol].buttoncolor[] = COLOR_2
            foreach(delete!, contents(panel_grid))
            trim!(panel_grid)
            app.current_panel = :protocol
            save_state_atomic(app)
            Label(panel_grid[1, 1]; text="PROTOCOL")
        end
    end
    
    function console_pressed(; force::Bool=false)
        if app.current_panel != :console || force
            if app.current_panel != :console
                panel[app.current_panel].buttoncolor[] = COLOR_3
            end
            panel[:console].buttoncolor[] = COLOR_2
            foreach(delete!, contents(panel_grid))
            trim!(panel_grid)
            app.current_panel = :console
            save_state_atomic(app)
            Label(panel_grid[1, 1]; text="CONSOLE")
        end
    end
    
    # ========================================================================
    # PANEL DISPATCH
    # ========================================================================
    
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
    
    # Initialize first panel
    handlers[app.current_panel](force=true)
    
    return nothing
end
