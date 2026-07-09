"""
roi_popup.jl

Empty ROI popup shell.
"""

function roi_bring_popup_to_front!(screen::GLMakie.Screen)
    try
        GLMakie.to_native(screen).window.focused[] = true
    catch e
        @warn "Unable to focus ROI popup" error=string(e)
    end

    return nothing
end

function open_roi_popup!(app, app_run, roi_popup_screen::Base.RefValue{Union{Nothing, GLMakie.Screen}})
    existing_screen = roi_popup_screen[]
    if existing_screen !== nothing && isopen(existing_screen)
        roi_bring_popup_to_front!(existing_screen)
        return
    end

    roi_active = Bool(get(app.roi, :active, false))
    app.roi[:active] = roi_active
    save_state(app)

    popup_figure = Figure(size = (600, 400))
    popup_screen = GLMakie.Screen(resolution = (600, 400))
    roi_popup_screen[] = popup_screen

    GridLayout(popup_figure[1, 1])

    on(events(popup_figure).window_open) do is_open
        if !is_open && roi_popup_screen[] === popup_screen
            roi_popup_screen[] = nothing
        end
    end

    display(popup_screen, popup_figure.scene)

    return nothing
end
