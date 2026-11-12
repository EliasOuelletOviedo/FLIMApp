"""
handlers_roi.jl

ROI panel: the ROI popup's Edit button and the ROIs' active toggle, how
the ROIs are excited and detected (Excitation / Detection: by the galvos or
by the scanner's images — `excitation_galvos`, `[clamp] images`), the image
averaging of the detection by image (`[clamp] images_par_bloc`), plus the
ROI galvo-scan spinners (each spiral's points fixed, `POINTS_PER_ROI`;
START copies them into the DAQ loop's ScanRequest, runtime.jl). The
spinners the current modes don't use are faded and refuse edits.
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

The colors of a ROI panel spinner — its label, box, text box and arrows —
as drawn, each with the color it takes faded: its own, or, for a hover or
click color, its widget's resting one (a faded spinner doesn't light up
under the mouse).
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
its handlers then refuse its edits (`panel_spinner!`), and its text box
loses the focus.
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

Which ROI panel spinners the modes use: the galvo scan's (spiral turns,
scan and shift time) when the excitation or the detection goes by the
galvos; the image averaging when the detection goes by image. Without ROIs
(ROI off), both by image: the whole image, the galvos unused.
"""
function spinners_in_use(roi_active::Bool, excitation_galvos::Bool, detection_galvos::Bool)::Tuple{Bool, Bool}
    excitation, detection = roi_active && excitation_galvos, roi_active && detection_galvos
    return (excitation || detection, !detection)
end

"""
    roi_panel_pressed!(app, app_run, blocks, panel, panel_grid, roi_popup_screen; force=false)

Render the ROI panel (the ROIs' active toggle and Edit button, the
Excitation / Detection toggles, the image averaging and the ROI galvo-scan
spinners) and wire up its controls. No-op if the ROI panel is already
showing, unless `force=true`.
"""
function roi_panel_pressed!(app, app_run, blocks, panel, panel_grid, roi_popup_screen; force::Bool=false)
    if app.current_panel != :roi || force
        panel[app.current_panel].buttoncolor[] = COLOR_3
        panel[:roi].buttoncolor[] = COLOR_2
        foreach(delete!, contents(panel_grid))
        trim!(panel_grid)
        app.current_panel = :roi
        save_state(app)

        Label(panel_grid[1, 1:2]; merge(LABEL_ATTRS, Dict{Symbol, Any}(:text => "Active"))...)
        roi_toggle = Toggle(panel_grid[1, 3]; merge(TOGGLE_ATTRS, Dict{Symbol, Any}(:active => app.roi.active))...)
        roi_button = Button(panel_grid[1, 4:6]; merge(BUTTON_ATTRS, Dict{Symbol, Any}(:label => "Edit", :width => nothing))...)
        # How the ROIs are excited (the 1064 nm) and detected (the 850 nm and the photons) — on: by the galvos, each
        # ROI's spiral; off: by the scanner's images, the whole field (the detection's ROIs as masks; [clamp] images,
        # the SPC window's box as well).
        Label(panel_grid[2, 1:2]; merge(LABEL_ATTRS, Dict{Symbol, Any}(:halign => :right, :text => "Excitation"))...)
        excitation_toggle = Toggle(panel_grid[2, 3]; merge(TOGGLE_ATTRS, Dict{Symbol, Any}(:active => app.protocol.excitation_galvos))...)
        Label(panel_grid[2, 4:5]; merge(LABEL_ATTRS, Dict{Symbol, Any}(:halign => :right, :text => "Detection"))...)
        detection_toggle = Toggle(panel_grid[2, 6]; merge(TOGGLE_ATTRS, Dict{Symbol, Any}(:active => !app_run.spc.settings.images))...)
        app_run.spc.panel_detection_toggle = detection_toggle    # the refresh tick keeps it on the setting

        # Each spinner: its row, its label, its range. The image averaging is the SPC setting `images_par_bloc`
        # (config/spc.toml, the SPC window's "Images / block"); the others, the protocol's fields. Each ROI's
        # spiral has POINTS_PER_ROI points (fixed).
        rows = (
            (:images_par_bloc,   3, "Image averaging :", (1, 100_000)),
            (:spiral_full_turns, 4, "Spiral turns :",    (0, 10)),
            (:scan_time,         5, "Scan time [ms] :",  (1, 1_000_000)),
            (:shift_time,        6, "Shift time [ms] :", (0, 1_000_000)),
        )
        current_value(key::Symbol) = key == :images_par_bloc ? app_run.spc.settings.images_par_bloc : getfield(app.protocol, key)
        function commit_value!(key::Symbol, value::Int)::Bool
            if key == :images_par_bloc
                value == app_run.spc.settings.images_par_bloc && return true
                return spc_edit_setting!(app_run.spc, :images_par_bloc, value)
            end
            setfield!(app.protocol, key, value)
            save_state(app)
            return true
        end
        enabled = Dict{Symbol, Base.RefValue{Bool}}()
        fades = Dict{Symbol, Any}()
        textboxes = Dict{Symbol, Any}()
        for (key, row, text, range) in rows
            label = Label(panel_grid[row, 1:3]; merge(LABEL_ATTRS, Dict{Symbol, Any}(:halign => :right, :text => text))...)
            enabled[key] = Ref(true)
            box, textbox, up, down = panel_spinner!(panel_grid, row, current_value(key), range, () -> current_value(key),
                                                    value -> commit_value!(key, value); enabled = enabled[key])
            fades[key] = spinner_fades(label, box, textbox, up, down)
            textboxes[key] = textbox
        end
        app_run.spc.panel_block_box = textboxes[:images_par_bloc]     # the refresh tick keeps it on the setting

        # The spinners the modes use, at full color; the others faded, their edits refused.
        function refresh_modes!()
            galvos, averaging = spinners_in_use(roi_toggle.active[], excitation_toggle.active[], detection_toggle.active[])
            for key in (:spiral_full_turns, :scan_time, :shift_time)
                enabled[key][] = galvos
            end
            enabled[:images_par_bloc][] = averaging
            for (key, fade) in fades
                set_spinner_enabled!(fade, textboxes[key], enabled[key][])
            end
            return nothing
        end
        refresh_modes!()

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
    end

    return nothing
end
