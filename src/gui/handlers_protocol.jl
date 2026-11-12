"""
handlers_protocol.jl

Protocol panel: the protocol's active toggle and the Protocol popup's Edit
button, then the ion indicator (`Indicator`): its preset (MQAE, SCLm or
Manual), its type (FLIM, Ratio, Hybrid) and its conversion parameters to a
concentration — FLIM (Stern–Volmer on the lifetime) and Ratio (on the
photon ratio Ch1/Ch2). A preset fixes its values (faded, not editable);
MQAE also fixes the type (FLIM) and fades the Ratio section; Manual leaves
everything editable. Split out of handlers.jl's former single
make_handlers function.
"""

"""
    indicator_editable(preset) -> (type_editable, values_editable, ratio_shown)

What the Indicator section lets edit for `preset`: the type (not with
MQAE, FLIM only), the conversion values (Manual only), and whether the
Ratio section is in use (not with MQAE).
"""
indicator_editable(preset::AbstractString)::NTuple{3, Bool} =
    (preset != "MQAE", preset == "Manual", preset != "MQAE")

"""
    protocol_panel_pressed!(app, app_run, blocks, panel, panel_grid, protocol_popup_screen; force=false)

Render the Protocol panel (the protocol's active toggle and Edit button,
the Indicator section) and wire up its controls. No-op if the Protocol
panel is already showing, unless `force=true`.
"""
function protocol_panel_pressed!(app, app_run, blocks, panel, panel_grid, protocol_popup_screen; force::Bool=false)
    if app.current_panel != :protocol || force
        panel[app.current_panel].buttoncolor[] = COLOR_3
        panel[:protocol].buttoncolor[] = COLOR_2
        foreach(delete!, contents(panel_grid))
        trim!(panel_grid)
        app.current_panel = :protocol
        save_state(app)
        p = app.protocol

        Label(panel_grid[1, 1:2]; merge(LABEL_ATTRS, Dict{Symbol, Any}(:text => "Active"))...)
        protocol_toggle = Toggle(panel_grid[1, 3]; merge(TOGGLE_ATTRS, Dict{Symbol, Any}(:active => p.active))...)
        protocol_button = Button(panel_grid[1, 4:6]; merge(BUTTON_ATTRS, Dict{Symbol, Any}(:label => "Edit", :width => nothing))...)

        # The ion indicator: its preset, its type, its conversion to a concentration.
        Label(panel_grid[2, 1:6]; merge(LABEL_ATTRS, Dict{Symbol, Any}(:text => "Indicator", :fontsize => 16))...)
        label(row, text) = Label(panel_grid[row, 1:3]; merge(LABEL_ATTRS, Dict{Symbol, Any}(:halign => :right, :text => text))...)
        menu(row, options, default) = Menu(panel_grid[row, 4:6]; merge(MENU_ATTRS, Dict{Symbol, Any}(:options => options, :default => default))...)
        label(3, "Preset :")
        preset_menu = menu(3, INDICATOR_PRESET_NAMES, p.indicator_preset)
        type_label = label(4, "Indicator type :")
        type_menu = menu(4, INDICATOR_TYPES, p.indicator_type)

        flim_title = Label(panel_grid[5, 1:6]; merge(LABEL_ATTRS, Dict{Symbol, Any}(:text => "FLIM"))...)
        ratio_title = Label(panel_grid[8, 1:6]; merge(LABEL_ATTRS, Dict{Symbol, Any}(:text => "Ratio"))...)
        fields = (
            (:indicator_tau0, 6,  "τ0 [ns] :",     :flim),
            (:indicator_ksv,  7,  "Ksv [1/mM] :",  :flim),
            (:indicator_rmin, 9,  "Rmin :",        :ratio),
            (:indicator_rmax, 10, "Rmax :",        :ratio),
            (:indicator_kd,   11, "Kd [mM] :",     :ratio),
            (:indicator_beta, 12, "β :",           :ratio),
        )
        boxes = Dict{Symbol, Any}()
        fades = Dict{Symbol, Any}()                  # each field's label and box colors, as drawn and faded
        fade_pairs(widgets...) = [(c, c[], faded(c[])) for w in widgets for c in fade_colors(w)]
        for (field, row, text, _) in fields
            l = label(row, text)
            box = Textbox(panel_grid[row, 4:6]; merge(TEXT_ATTRS, Dict{Symbol, Any}(
                :displayed_string => string(getfield(p, field)), :stored_string => string(getfield(p, field)), :width => 100))...)
            boxes[field] = box
            fades[field] = fade_pairs(l, box)
        end
        type_fades = fade_pairs(type_label, type_menu)
        title_fades = Dict(:flim => fade_pairs(flim_title), :ratio => fade_pairs(ratio_title))

        show!(pairs, on) = foreach(((c, drawn, dim),) -> (v = on ? drawn : dim; c[] == v || (c[] = v)), pairs)
        function refresh_indicator!()
            type_ok, values_ok, ratio_shown = indicator_editable(p.indicator_preset)
            show!(type_fades, type_ok)
            show!(title_fades[:flim], values_ok)
            show!(title_fades[:ratio], values_ok && ratio_shown)
            for (field, _, _, section) in fields
                show!(fades[field], values_ok && (section == :flim || ratio_shown))
                boxes[field].displayed_string[] = string(getfield(p, field))
                boxes[field].stored_string[] = string(getfield(p, field))
                values_ok || (boxes[field].focused[] = false)
            end
            return nothing
        end
        publish!() = (sync_runtime_protocol!(app, app_run); save_state(app))

        on(preset_menu.selection) do preset
            preset isa AbstractString || return
            apply_indicator_preset!(p, preset)
            type_menu.i_selected[] = something(findfirst(==(p.indicator_type), INDICATOR_TYPES), 1)
            refresh_indicator!()
            publish!()
        end
        on(type_menu.selection) do type
            type isa AbstractString || return
            if !indicator_editable(p.indicator_preset)[1]       # fixed by the preset: back to its type
                type == p.indicator_type || (type_menu.i_selected[] = findfirst(==(p.indicator_type), INDICATOR_TYPES))
                return
            end
            p.indicator_type = String(type)
            publish!()
        end
        for (field, _, _, _) in fields
            box = boxes[field]
            on(box.focused) do focused
                focused && !indicator_editable(p.indicator_preset)[2] && (box.focused[] = false)
            end
            on(box.stored_string) do text
                value = tryparse(Float64, strip(text))
                if indicator_editable(p.indicator_preset)[2] && value !== nothing && isfinite(value)
                    setfield!(p, field, value)
                    box.displayed_string[] = string(value)
                    publish!()
                elseif text != string(getfield(p, field))
                    box.displayed_string[] = string(getfield(p, field))
                    box.stored_string[] = string(getfield(p, field))
                end
            end
        end
        refresh_indicator!()

        sync_runtime_protocol!(app, app_run)

        on(protocol_toggle.active) do is_active
            p.active = is_active
            sync_runtime_protocol!(app, app_run)
            save_state(app)
        end

        on(protocol_button.clicks) do _
            open_protocol_popup!(app, app_run, protocol_popup_screen)
        end

        foreach(n -> colsize!(panel_grid, n, 28), 1:6)
        colgap!(panel_grid, 8)
        rowgap!(panel_grid, 1, 32)
        rowgap!(panel_grid, 2, 8)
    end

    return nothing
end

"""The color attributes of a Label, Textbox or Menu that fade with it (`faded`)."""
fade_colors(w::Label) = (w.color,)
fade_colors(w::Textbox) = (w.textcolor, w.boxcolor, w.bordercolor)
fade_colors(w::Menu) = (w.textcolor, w.selection_cell_color_inactive, w.dropdown_arrow_color)
