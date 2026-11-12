"""
handlers_protocol.jl

Protocol panel: the Protocol/ROI popup launch buttons and their active
toggles, the opto laser's PWM (its duty cycle and toggle; the frequency
fixed, `PWM_FREQUENCY_HZ`), how the ROIs are excited and detected
(Excitation / Detection: by the galvos or by the scanner's images —
`excitation_galvos`, `[clamp] images`), the image averaging of the
detection by image (`[clamp] images_par_bloc`), plus the ROI galvo-scan
spinners (each spiral's points fixed, `POINTS_PER_ROI`; START copies them
into the DAQ loop's ScanRequest, runtime.jl). The spinners the current
modes don't use are faded and refuse edits. Split out of handlers.jl's
former single make_handlers function.
"""

"""Alpha of a spinner the current modes don't use (`set_spinner_enabled!`)."""
const DISABLED_ALPHA = 0.5

"""`c` (any Makie color) at `DISABLED_ALPHA` of its own alpha."""
function faded(c)
    rgba = Makie.to_color(c)
    return RGBAf(rgba.r, rgba.g, rgba.b, rgba.alpha * DISABLED_ALPHA)
end

"""
    spinner_fades(label, box, textbox, up, down) -> Vector

The colors of a Protocol panel spinner — its label, box, text box and
arrows — as drawn, each with the color it takes faded: its own, or, for a
hover or click color, its widget's resting one (a faded spinner doesn't
light up under the mouse).
"""
function spinner_fades(label, box, textbox, up, down)
    fades = Tuple{Any, Any, RGBAf}[]
    add!(color, rest = color[]) = push!(fades, (color, color[], faded(rest)))
    add!(label.color)
    add!(box.strokecolor)
    add!(textbox.textcolor)
    add!(textbox.boxcolor)
    add!(textbox.boxcolor_hover, textbox.boxcolor[])
    for button in (up, down)
        add!(button.buttoncolor)
        add!(button.buttoncolor_hover, button.buttoncolor[])
        add!(button.buttoncolor_active, button.buttoncolor[])
        add!(button.labelcolor)
        add!(button.labelcolor_hover, button.labelcolor[])
        add!(button.labelcolor_active, button.labelcolor[])
        add!(button.strokecolor)
    end
    return fades
end

"""
    set_spinner_enabled!(fades, textbox, enabled)

Show a spinner as usable — its colors as drawn — or not (`faded`, 50 %):
the panel's handlers then refuse its edits, and its text box loses the
focus.
"""
function set_spinner_enabled!(fades, textbox, enabled::Bool)
    for (color, drawn, dim) in fades
        value = enabled ? drawn : dim
        color[] == value || (color[] = value)
    end
    !enabled && textbox.focused[] && (textbox.focused[] = false)
    return nothing
end

"""
    spinners_in_use(roi_active, excitation_galvos, detection_galvos) -> (galvos, averaging)

Which Protocol panel spinners the modes use: the galvo scan's (spiral
turns, scan and shift time) when the excitation or the detection goes by
the galvos; the image averaging when the detection goes by image. Without
ROIs (ROI off), both by image: the whole image, the galvos unused.
"""
function spinners_in_use(roi_active::Bool, excitation_galvos::Bool, detection_galvos::Bool)::Tuple{Bool, Bool}
    excitation, detection = roi_active && excitation_galvos, roi_active && detection_galvos
    return (excitation || detection, !detection)
end

"""
    protocol_panel_pressed!(app, app_run, blocks, panel, panel_grid,
                             protocol_popup_screen, roi_popup_screen; force=false)

Render the Protocol panel (Protocol/ROI buttons + active toggles, the
Excitation / Detection toggles, the image averaging and the ROI galvo-scan
spinners) and wire up its controls. No-op if the Protocol panel is already
showing, unless `force=true`.
"""
function protocol_panel_pressed!(app, app_run, blocks, panel, panel_grid,
                                  protocol_popup_screen, roi_popup_screen; force::Bool=false)
    if app.current_panel != :protocol || force
        panel[app.current_panel].buttoncolor[] = COLOR_3
        panel[:protocol].buttoncolor[] = COLOR_2
        foreach(delete!, contents(panel_grid))
        trim!(panel_grid)
        app.current_panel = :protocol
        save_state(app)

        Label(panel_grid[1, 1:6]; merge(LABEL_ATTRS, Dict{Symbol, Any}(:text => "Protocol", :fontsize => 16))...)
        Label(panel_grid[2, 1:2]; merge(LABEL_ATTRS, Dict{Symbol, Any}(:text => "Active"))...)
        protocol_toggle = Toggle(panel_grid[2, 3]; merge(TOGGLE_ATTRS, Dict{Symbol, Any}(:active => app.protocol.active))...)
        protocol_button = Button(panel_grid[2, 4:6]; merge(BUTTON_ATTRS, Dict{Symbol, Any}(:label => "Edit", :width => nothing))...)

        Label(panel_grid[4, 1:6]; merge(LABEL_ATTRS, Dict{Symbol, Any}(:text => "ROI", :fontsize => 16))...)
        Label(panel_grid[5, 1:2]; merge(LABEL_ATTRS, Dict{Symbol, Any}(:text => "Active"))...)
        roi_toggle = Toggle(panel_grid[5, 3]; merge(TOGGLE_ATTRS, Dict{Symbol, Any}(:active => app.roi.active))...)
        roi_button = Button(panel_grid[5, 4:6]; merge(BUTTON_ATTRS, Dict{Symbol, Any}(:label => "Edit", :width => nothing))...)
        # How the ROIs are excited (the 1064 nm) and detected (the 850 nm and the photons) — on: by the galvos, each
        # ROI's spiral; off: by the scanner's images, the whole field (the detection's ROIs as masks; [clamp] images,
        # the SPC window's box as well).
        Label(panel_grid[6, 1:2]; merge(LABEL_ATTRS, Dict{Symbol, Any}(:halign => :right, :text => "Excitation"))...)
        excitation_toggle = Toggle(panel_grid[6, 3]; merge(TOGGLE_ATTRS, Dict{Symbol, Any}(:active => app.protocol.excitation_galvos))...)
        Label(panel_grid[6, 4:5]; merge(LABEL_ATTRS, Dict{Symbol, Any}(:halign => :right, :text => "Detection"))...)
        detection_toggle = Toggle(panel_grid[6, 6]; merge(TOGGLE_ATTRS, Dict{Symbol, Any}(:active => !app_run.spc.settings.images))...)
        app_run.spc.panel_detection_toggle = detection_toggle    # the refresh tick keeps it on the setting

        # The opto laser's PWM, at PWM_FREQUENCY_HZ (fixed): on, the first "Duty cycle" % of each period the 1064 nm,
        # the rest the acquisition (a short label: two 28 px columns).
        Label(panel_grid[3, 1:2]; merge(LABEL_ATTRS, Dict{Symbol, Any}(:halign => :right, :text => "Duty cycle :"))...)
        pwm_toggle = Toggle(panel_grid[3, 3]; merge(TOGGLE_ATTRS, Dict{Symbol, Any}(:active => app.protocol.PWM_active))...)

        function spinner(row::Int, value)
            box = Box(panel_grid[row, 4:6]; SPINNER_BOX_ATTRS...)
            textbox = Textbox(panel_grid[row, 4:6]; merge(SPINNER_TEXT_ATTRS, Dict(:displayed_string => string(value), :stored_string => string(value)))...)
            return box, textbox, Button(panel_grid[row, 4:6]; SPINNER_UP_ATTRS...), Button(panel_grid[row, 4:6]; SPINNER_DOWN_ATTRS...)
        end
        spinner_label(row::Int, text::String) =
            Label(panel_grid[row, 1:3]; merge(LABEL_ATTRS, Dict{Symbol, Any}(:halign => :right, :text => text))...)

        # Each spinner: its row, its label ("" — the duty cycle's, beside its toggle), its range. The image
        # averaging is the SPC setting `images_par_bloc` (config/spc.toml, the SPC window's "Images / block");
        # the others, the protocol's fields. Each ROI's spiral has POINTS_PER_ROI points (fixed).
        rows = (
            (:PWM_duty,          3,  "",                  (1, 99)),
            (:images_par_bloc,   7,  "Image averaging :", (1, 100_000)),
            (:spiral_full_turns, 8,  "Spiral turns :",    (0, 10)),
            (:scan_time,         9,  "Scan time [ms] :",  (1, 1_000_000)),
            (:shift_time,        10, "Shift time [ms] :", (0, 1_000_000)),
        )
        current_value(key::Symbol) = key == :images_par_bloc ? app_run.spc.settings.images_par_bloc : getfield(app.protocol, key)
        enabled = Dict{Symbol, Bool}(key => true for (key, _, _, _) in rows)
        fades = Dict{Symbol, Any}()
        textboxes = Dict{Symbol, Any}()

        sync_runtime_protocol!(app, app_run)

        function commit_value!(key::Symbol, value::Int)::Bool
            if key == :images_par_bloc
                value == app_run.spc.settings.images_par_bloc && return true
                return spc_edit_setting!(app_run.spc, :images_par_bloc, value)
            end
            setfield!(app.protocol, key, value)
            save_state(app)
            return true
        end

        for (key, row, text, (min_value, max_value)) in rows
            label = isempty(text) ? nothing : spinner_label(row, text)
            box, textbox, up_button, down_button = spinner(row, current_value(key))
            textboxes[key] = textbox
            label === nothing || (fades[key] = spinner_fades(label, box, textbox, up_button, down_button))

            function show!(value)
                textbox.displayed_string[] = string(value)
                textbox.stored_string[] = string(value)        # its handler keeps the value
            end
            on(up_button.clicks) do _
                enabled[key] || return
                parsed_value = tryparse(Int, textbox.stored_string[])
                show!(parsed_value === nothing ? min_value : smart_next(parsed_value, min_value, max_value, Int))
            end
            on(down_button.clicks) do _
                enabled[key] || return
                parsed_value = tryparse(Int, textbox.stored_string[])
                show!(parsed_value === nothing ? min_value : smart_prev(parsed_value, min_value, max_value, Int))
            end
            on(textbox.stored_string) do new_string
                parsed_value = tryparse(Int, new_string)
                parsed_value === nothing && return
                kept = string(current_value(key))
                if !enabled[key]
                    new_string == kept || show!(kept)          # unused by the current modes: back to its value
                    return
                end
                clamped_value = clamp(parsed_value, min_value, max_value)
                if commit_value!(key, clamped_value)
                    textbox.displayed_string[] = string(clamped_value)
                else
                    show!(kept)                                # refused (the SPC setting's check): back to its value
                end
            end
            # A spinner the current modes don't use can't be edited: its text box doesn't keep the focus.
            on(textbox.focused) do focused
                focused && !enabled[key] && (textbox.focused[] = false)
            end
        end
        app_run.spc.panel_block_box = textboxes[:images_par_bloc]     # the refresh tick keeps it on the setting

        # The spinners the modes use, at full color; the others faded, their edits refused.
        function refresh_modes!()
            galvos, averaging = spinners_in_use(roi_toggle.active[], excitation_toggle.active[], detection_toggle.active[])
            for key in (:spiral_full_turns, :scan_time, :shift_time)
                enabled[key] = galvos
            end
            enabled[:images_par_bloc] = averaging
            for (key, fade) in fades
                set_spinner_enabled!(fade, textboxes[key], enabled[key])
            end
            return nothing
        end
        refresh_modes!()

        on(protocol_toggle.active) do is_active
            app.protocol.active = is_active
            sync_runtime_protocol!(app, app_run)
            save_state(app)
        end

        # The PWM applies from the next START (the DAQ loop's slots are built then).
        on(pwm_toggle.active) do is_active
            app.protocol.PWM_active = is_active
            save_state(app)
        end

        on(protocol_button.clicks) do _
            open_protocol_popup!(app, app_run, protocol_popup_screen)
        end

        on(roi_toggle.active) do is_active
            app.roi.active = is_active
            sync_runtime_protocol!(app, app_run)
            save_state(app)
            refresh_modes!()
        end

        on(roi_button.clicks) do _
            open_roi_popup!(app, app_run, roi_popup_screen)
        end

        # Excitation by the galvos or by image: from the next START.
        on(excitation_toggle.active) do active
            app.protocol.excitation_galvos = active
            save_state(app)
            refresh_modes!()
        end

        # Detection by the galvos or by image: the SPC setting [clamp] images (config/spc.toml), from the next START.
        on(detection_toggle.active) do active
            refresh_modes!()
            active == !app_run.spc.settings.images && return     # already so (the refresh tick follows the SPC window's)
            spc_edit_setting!(app_run.spc, :images, !active) || (detection_toggle.active[] = !app_run.spc.settings.images)
        end

        foreach(n -> colsize!(panel_grid, n, 28), 1:6)
        colgap!(panel_grid, 8)
        # [rowsize!(panel_grid, n, 32) for n in 1:4]
        rowgap!(panel_grid, 1, 8)
        rowgap!(panel_grid, 3, 32)
        rowgap!(panel_grid, 4, 8)
    end

    return nothing
end
