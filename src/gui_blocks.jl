"""
gui_blocks.jl

The `GuiBlocks` struct: a typed container for every GUI element that event
handlers and background tasks need to reach (grids, widgets, axes, labels).

Previously this was a `Dict{Symbol, Any}`, which meant a typo'd key failed
at click time deep inside a handler instead of at construction, and the set
of available blocks was only discoverable by grepping call sites. A struct
turns every lookup into a compile-checked field access and documents the
GUI's surface in one place.
"""

using GLMakie

"""
    GuiBlocks

Every GUI element shared between `make_gui` (GUI.jl), the event handlers
(handlers*.jl), and the background tasks (runtime.jl). Constructed once in
`make_gui` and passed around read-only.
"""
Base.@kwdef struct GuiBlocks
    # Grids
    top_grid::GridLayout
    left_grid::GridLayout
    right_grid::GridLayout
    button_grid::GridLayout
    path_grid::GridLayout
    panelbtn_grid::GridLayout
    panel_grid::GridLayout
    # Widgets
    start_button::Button
    stop_button::Button
    irf_path_textbox::Textbox
    irf_button::Button
    folder_path_textbox::Textbox
    folder_button::Button
    port_menu::Menu
    connect_button::Button
    mode_menu::Menu
    lifetimes_menu::Menu
    panel_buttons::Dict{Symbol, Button}
    info_label::Label
    # Axes
    counts_axis::Axis
    plot_1_axis::Axis
    plot_2_axis::Axis
    save_progress_axis::Axis
end
