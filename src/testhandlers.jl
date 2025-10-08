function make_handlers(gui)
    app = gui.app
    fig = gui.fig
    start = gui.start
    stop  = gui.stop
    panel = gui.panel
    current_panel = gui.current_panel
    panel_grid = gui.panel_grid
    counts = gui.counts
    plot_1 = gui.plot_1
    plot_2 = gui.plot_2

    # smart_next / smart_prev for Makie textbox + up/down buttons
    # Implements "smart" stepping for Int64 and Float64 as requested.
    # Usage in your code (same signature as you call):
    #   newval = smart_next(val, min_val, max_val, T)
    #   newval = smart_prev(val, min_val, max_val, T)
    # where T is either Int64 or Float64.

    # The algorithm (shared idea for ints and floats):
    # - Group values by powers of ten (base = 10^k).
    # - For values in a bucket [base, 10*base): the "next" is (leading+1)*base,
    #   where leading = floor(val/base). This yields the behaviour:
    #     1 -> 2, 2 -> 3, ... 9 -> 10, 10 -> 20, 90 -> 100, 100 -> 200, 201 -> 300, etc.
    # - For values < 1 (floats), the same bucket logic with negative k works and
    #   reproduces the desired behaviour: 0.1 -> 0.09 (when stepping down), 0.09 -> 0.1 (up), etc.
    # - smart_prev is the inverse: it returns the largest "nice" number strictly less
    #   than the current value (clamped to min_val). Special handling is added for exact
    #   powers-of-ten to step into the previous decade (e.g. 100 -> 90).

    # Small numeric tolerance is used for floats to detect exact multiples of base.

    EPS_REL = 1e-12

    # -------------------- Int64 methods --------------------

    function smart_next(val::Integer, min_val::Integer, max_val::Integer, ::Type{Int64})::Int64
        v = Int(val)
        lo = Int(min_val)
        hi = Int(max_val)

        if v <= lo
            return lo
        end
        if v <= 0
            return max(lo, 1)
        end

        k = floor(Int, log10(float(v)))          # safe because v > 0
        base = Int(10)^k
        leading = div(v, base)
        # next nice value
        nxt = (leading + 1) * base
        return Int(clamp(nxt, lo, hi))
    end

    function smart_prev(val::Integer, min_val::Integer, max_val::Integer, ::Type{Int64})::Int64
        v = Int(val)
        lo = Int(min_val)
        hi = Int(max_val)

        if v <= lo
            return lo
        end
        if v <= 1
            return max(lo, 0)
        end

        if v < 10
            return Int(clamp(v - 1, lo, hi))
        end

        k = floor(Int, log10(float(v)))
        base = Int(10)^k
        leading = div(v, base)

        if v % base == 0
            # exact multiple of the base
            if leading > 1
                prev = (leading - 1) * base
            else
                # special case: val == 10^k -> go to 9 * 10^(k-1)
                prev = 9 * (base ÷ 10)
            end
        else
            # not an exact multiple, floor to the bucket start
            prev = leading * base
        end

        return Int(clamp(prev, lo, hi))
    end

    # -------------------- Float64 methods --------------------

    # helper: compute k and base robustly for positive floats
    @inline function _pow10base_and_leading(v::Float64)
        # v must be > 0
        k = floor(Int, log10(v))
        base = 10.0^k
        q = v / base
        # leading as integer; add a tiny epsilon before floor to avoid precision issues
        leading = floor(Int, q + EPS_REL)
        is_multiple = abs(q - leading) <= EPS_REL * max(1.0, abs(q))
        return k, base, leading, is_multiple
    end

    function smart_next(val::Float64, min_val::Float64, max_val::Float64, ::Type{Float64})::Float64
        v = Float64(val)
        lo = Float64(min_val)
        hi = Float64(max_val)

        if v <= lo
            return lo
        end
        if v <= 0.0
            return max(lo, 1.0)
        end

        k, base, leading, is_multiple = _pow10base_and_leading(v)

        # next always moves to (leading+1)*base
        nxt = (leading + 1) * base
        return Float64(clamp(nxt, lo, hi))
    end

    function smart_prev(val::Float64, min_val::Float64, max_val::Float64, ::Type{Float64})::Float64
        v = Float64(val)
        lo = Float64(min_val)
        hi = Float64(max_val)

        if v <= lo
            return lo
        end
        if v <= 0.0
            return lo
        end

        # small values in (0,1) and larger use the same bucket logic
        k, base, leading, is_multiple = _pow10base_and_leading(v)

        prev = 0.0
        if is_multiple
            if leading > 1
                prev = (leading - 1) * base
            else
                # leading == 1 and val is exact multiple -> step to previous decade
                prev = 9 * (base / 10.0)
            end
        else
            prev = leading * base
        end

        return Float64(clamp(prev, lo, hi))
    end

    function layout_pressed()
        if current_panel[] != :layout
            panel[current_panel[]].buttoncolor[] = COLOR_3
            panel[:layout].buttoncolor[] = COLOR_2
            foreach(delete!, contents(panel_grid))
            current_panel[] = :layout

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
                :time_range => (Textbox(panel_grid[1, 2]; merge(SPINNER_TEXT_ATTRS, Dict(:displayed_string => string(app.time_range), :stored_string => string(app.time_range)))...),
                                Button(panel_grid[1, 2];  SPINNER_UP_ATTRS...),
                                Button(panel_grid[1, 2];  SPINNER_DOWN_ATTRS...),
                                (1, 99999, Int)),
                :binning    => (Textbox(panel_grid[2, 2]; merge(SPINNER_TEXT_ATTRS, Dict(:displayed_string => string(app.binning), :stored_string => string(app.binning)))...),
                                Button(panel_grid[2, 2];  SPINNER_UP_ATTRS...),
                                Button(panel_grid[2, 2];  SPINNER_DOWN_ATTRS...),
                                (1, 100, Int)),
                :smoothing  => (Textbox(panel_grid[3, 2]; merge(SPINNER_TEXT_ATTRS, Dict(:displayed_string => string(app.smoothing), :stored_string => string(app.smoothing)))...),
                                Button(panel_grid[3, 2];  SPINNER_UP_ATTRS...),
                                Button(panel_grid[3, 2];  SPINNER_DOWN_ATTRS...),
                                (0.0, 10.0, Float64)),
                :plot1      =>  Menu(panel_grid[5, 1:2]; merge(MENU_ATTRS, Dict(:default => app.plot1, :options => options))...),
                :plot2      =>  Menu(panel_grid[7, 1:2]; merge(MENU_ATTRS, Dict(:default => app.plot2, :options => options))...),
            )

            for (symbol, block) in layout_params
                println(typeof(block))
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

                        setproperty!(app, symbol, val)
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
                        setproperty!(app, symbol, val)
                    end

                    on(txt.stored_string) do new_str
                        val = tryparse(T, new_str)

                        if val !== nothing
                            val = clamp(val, min_val, max_val)
                            txt.displayed_string[] = string(val)

                            setproperty!(app, symbol, val)
                        end
                    end

                elseif typeof(block) == Menu
                    on(block.i_selected) do idx
                        if idx > 0
                            setproperty!(app, symbol, options[idx])
                        end
                    end
                end
            end

            colsize!(panel_grid, 1, 80)
            colsize!(panel_grid, 2, 80)
            rowgap!(panel_grid, 3, 24)
            rowgap!(panel_grid, 5, 24)
        end
    end

    function controller_pressed()
        if current_panel[] != :controller
            panel[current_panel[]].buttoncolor[] = COLOR_3
            panel[:controller].buttoncolor[] = COLOR_2
            foreach(delete!, contents(panel_grid))
            current_panel[] = :controller

            Label(panel_grid[1, 1]; text="CONTROLLER")
        end
    end

    function protocol_pressed()
        if current_panel[] != :protocol
            panel[current_panel[]].buttoncolor[] = COLOR_3
            panel[:protocol].buttoncolor[] = COLOR_2
            foreach(delete!, contents(panel_grid))
            current_panel[] = :protocol

            Label(panel_grid[1, 1]; text="PROTOCOL")
        end
    end

    function console_pressed()
        if current_panel[] != :console
            panel[current_panel[]].buttoncolor[] = COLOR_3
            panel[:console].buttoncolor[] = COLOR_2
            foreach(delete!, contents(panel_grid))
            current_panel[] = :console

            Label(panel_grid[1, 1]; text="CONSOLE")
        end
    end

    handlers = Dict(
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

    layout_pressed()

    return nothing
end

