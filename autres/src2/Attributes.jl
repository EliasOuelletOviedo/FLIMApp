"""
Attributes.jl - Theme colors and Makie UI component attributes
"""

using Colors
using Makie

# ============================================================================
# COLOR THEME
# ============================================================================

"""
    get_theme_colors(dark::Bool=true)

Get color palette based on theme mode.
"""
function get_theme_colors(dark::Bool=true)
    if dark
        return Dict{Symbol, Any}(
            :backgroundcolor => :gray12,
            :textcolor       => :gray80,
            :fonts           => (; 
                regular = "Arial", 
                bold    = "Arial Bold", 
                italic  = "Arial Italic"
            )
        )
    else
        return Dict{Symbol, Any}(
            :backgroundcolor => :gray88,
            :textcolor       => :gray20,
            :fonts           => (; 
                regular = "Arial", 
                bold    = "Arial Bold", 
                italic  = "Arial Italic"
            )
        )
    end
end

"""
    get_color_palette(dark::Bool=true)

Get named colors for dark/light theme.
"""
function get_color_palette(dark::Bool=true)
    if dark
        return Dict{Symbol, Any}(
            :color_1 => :gray14,
            :color_2 => :gray18,
            :color_3 => :gray22,
            :color_4 => :gray26,
            :color_5 => :gray50,
            :text    => :white
        )
    else
        return Dict{Symbol, Any}(
            :color_1 => :gray80,
            :color_2 => :gray76,
            :color_3 => :gray72,
            :color_4 => :gray68,
            :color_5 => :gray50,
            :text    => :black
        )
    end
end

"""
    get_rgb_colors(dark::Bool=true)

Convert named colors to RGB for use in plots.
"""
function get_rgb_colors(dark::Bool=true)
    palette = get_color_palette(dark)
    return Dict{Symbol, Any}(
        :COLOR_1 => parse(RGB{Float64}, palette[:color_1]),
        :COLOR_2 => parse(RGB{Float64}, palette[:color_2]),
        :COLOR_3 => parse(RGB{Float64}, palette[:color_3]),
        :COLOR_4 => parse(RGB{Float64}, palette[:color_4]),
        :COLOR_5 => parse(RGB{Float64}, palette[:color_5]),
        :TEXT    => parse(RGB{Float64}, palette[:text])
    )
end

# ============================================================================
# INITIALIZE COLORS (at module load time)
# ============================================================================

const DARK_MODE = get_theme_colors(true)
const LIGHT_MODE = get_theme_colors(false)
const DEFAULT_COLORS = get_rgb_colors(true)

# Default theme colors (will be updated dynamically)
COLOR_1 = DEFAULT_COLORS[:COLOR_1]
COLOR_2 = DEFAULT_COLORS[:COLOR_2]
COLOR_3 = DEFAULT_COLORS[:COLOR_3]
COLOR_4 = DEFAULT_COLORS[:COLOR_4]
COLOR_5 = DEFAULT_COLORS[:COLOR_5]
TEXT    = DEFAULT_COLORS[:TEXT]

"""
    update_colors_for_theme(dark::Bool)

Update global color constants for current theme mode.
Call this when switching between dark/light mode.
"""
function update_colors_for_theme(dark::Bool)
    colors = get_rgb_colors(dark)
    global COLOR_1 = colors[:COLOR_1]
    global COLOR_2 = colors[:COLOR_2]
    global COLOR_3 = colors[:COLOR_3]
    global COLOR_4 = colors[:COLOR_4]
    global COLOR_5 = colors[:COLOR_5]
    global TEXT    = colors[:TEXT]
end

# ============================================================================
# AXIS ATTRIBUTES (plot area)
# ============================================================================

const AXIS_PLOTS_ATTRS = Dict{Symbol, Any}(
    :alignmode          => Inside(),
    :aspect             => nothing,
    :autolimitaspect    => nothing,
    :backgroundcolor    => COLOR_1,
    :bottomspinecolor   => COLOR_5,
    :bottomspinevisible => true,
    :flip_ylabel        => false,
    :halign             => :right,
    :height             => 300,
    :leftspinecolor     => COLOR_5,
    :leftspinevisible   => true,
    :limits             => (nothing, nothing),
    :panbutton          => Makie.Mouse.right,
    :rightspinecolor    => COLOR_5,
    :rightspinevisible  => true,
    :spinewidth         => 0.5,
    :subtitle           => "",
    :subtitlecolor      => TEXT,
    :subtitlefont       => :regular,
    :subtitlegap        => 0,
    :subtitlelineheight => 1,
    :subtitlesize       => 12,
    :subtitlevisible    => true,
    :tellheight         => true,
    :tellwidth          => true,
    :title              => "",
    :titlealign         => :center,
    :titlecolor         => TEXT,
    :titlefont          => :bold,
    :titlegap           => 4,
    :titlelineheight    => 1,
    :titlesize          => 16,
    :titlevisible       => true,
    :topspinecolor      => COLOR_5,
    :topspinevisible    => true,
    :valign             => :center,
    :width              => 840,
    :xautolimitmargin   => (0.05f0, 0.05f0),
    :xaxisposition      => :bottom,
    :xgridcolor         => COLOR_5,
    :xgridvisible       => true,
    :xgridwidth         => 0.5,
    :xlabel             => "",
    :xlabelcolor        => TEXT,
    :xlabelfont         => :regular,
    :xlabelpadding      => 3,
    :xlabelrotation     => Makie.automatic,
    :xlabelsize         => 16,
    :xlabelvisible      => true,
    :xminorgridvisible  => false,
    :xminorgridwidth    => 1,
    :xminortickalign    => 0,
    :xminortickcolor    => COLOR_5,
    :xminorticks        => IntervalsBetween(2),
    :xminorticksize     => 3,
    :xminorticksvisible => true,
    :xminortickwidth    => 1,
    :xpankey            => Makie.Keyboard.x,
    :xpanlock           => false,
    :xrectzoom          => true,
    :xreversed          => false,
    :xscale             => identity,
    :xtickalign         => 0,
    :xtickcolor         => COLOR_5,
    :xtickformat        => Makie.automatic,
    :xticklabelalign    => Makie.automatic,
    :xticklabelcolor    => TEXT,
    :xticklabelfont     => :regular,
    :xticklabelpad      => 2,
    :xticklabelrotation => 0,
    :xticklabelsize     => 16,
    :xticklabelspace    => Makie.automatic,
    :xticklabelsvisible => true,
    :xticks             => Makie.automatic,
    :xticksize          => 5,
    :xticksmirrored     => false,
    :xticksvisible      => true,
    :xtickwidth         => 1,
    :xtrimspine         => false,
    :xzoomkey           => Makie.Keyboard.x,
    :xzoomlock          => false,
    :yautolimitmargin   => (0.05f0, 0.05f0),
    :yaxisposition      => :left,
    :ygridcolor         => COLOR_5,
    :ygridvisible       => true,
    :ygridwidth         => 0.5,
    :ylabel             => "",
    :ylabelcolor        => TEXT,
    :ylabelfont         => :regular,
    :ylabelpadding      => 3,
    :ylabelrotation     => Makie.automatic,
    :ylabelsize         => 16,
    :ylabelvisible      => true,
    :yminorgridvisible  => false,
    :yminorgridwidth    => 1,
    :yminortickalign    => 0,
    :yminortickcolor    => COLOR_5,
    :yminorticks        => IntervalsBetween(2),
    :yminorticksize     => 3,
    :yminorticksvisible => true,
    :yminortickwidth    => 1,
    :ypankey            => Makie.Keyboard.y,
    :ypanlock           => false,
    :yrectzoom          => true,
    :yreversed          => false,
    :yscale             => identity,
    :ytickalign         => 0,
    :ytickcolor         => COLOR_5,
    :ytickformat        => Makie.automatic,
    :yticklabelalign    => Makie.automatic,
    :yticklabelcolor    => TEXT,
    :yticklabelfont     => :regular,
    :yticklabelpad      => 2,
    :yticklabelrotation => 0,
    :yticklabelsize     => 16,
    :yticklabelspace    => Makie.automatic,
    :yticklabelsvisible => true,
    :yticks             => Makie.automatic,
    :yticksize          => 5,
    :yticksmirrored     => false,
    :yticksvisible      => true,
    :ytickwidth         => 1,
    :ytrimspine         => false,
    :yzoomkey           => Makie.Keyboard.x,
    :yzoomlock          => false,
)

const AXIS_COUNTS_ATTRS = Dict{Symbol, Any}(
    :alignmode          => Inside(),
    :aspect             => nothing,
    :autolimitaspect    => nothing,
    :backgroundcolor    => COLOR_1,
    :bottomspinecolor   => COLOR_5,
    :bottomspinevisible => true,
    :flip_ylabel        => false,
    :halign             => :right,
    :height             => nothing,
    :leftspinecolor     => COLOR_5,
    :leftspinevisible   => true,
    :limits             => ((0, 1), (1, 1e7)),
    :panbutton          => Makie.Mouse.right,
    :rightspinecolor    => COLOR_5,
    :rightspinevisible  => true,
    :spinewidth         => 0.5,
    :subtitle           => "",
    :subtitlecolor      => TEXT,
    :subtitlefont       => :regular,
    :subtitlegap        => 0,
    :subtitlelineheight => 1,
    :subtitlesize       => 12,
    :subtitlevisible    => true,
    :tellheight         => true,
    :tellwidth          => true,
    :title              => "",
    :titlealign         => :center,
    :titlecolor         => TEXT,
    :titlefont          => :bold,
    :titlegap           => 4,
    :titlelineheight    => 1,
    :titlesize          => 16,
    :titlevisible       => true,
    :topspinecolor      => COLOR_5,
    :topspinevisible    => true,
    :valign             => :center,
    :width              => 32,
    :ylabel             => "Photon count",
    :ylabelcolor        => TEXT,
    :ylabelfont         => :regular,
    :ylabelpadding      => 12,
    :ylabelrotation     => Makie.automatic,
    :ylabelsize         => 16,
    :ylabelvisible      => true,
    :yscale             => log10,
    :yticks             => LogTicks(0:7),
    :ytickcolor         => COLOR_5,
    :yticklabelcolor    => TEXT,
    :yticklabelsize     => 16,
    :yticksvisible      => true,
)

# ============================================================================
# BUTTON, BOX, LABEL ATTRIBUTES
# ============================================================================



const BUTTON_ATTRS = Dict{Symbol, Any}(
    :alignmode          => Inside(),
    :buttoncolor        => COLOR_3,
    :buttoncolor_active => COLOR_1,
    :buttoncolor_hover  => COLOR_2,
    :clicks             => 0,
    :cornerradius       => 6,
    :cornersegments     => 10,
    :font               => :regular,
    :fontsize           => 16,
    :halign             => :center,
    :height             => 32,
    :label              => "",
    :labelcolor         => TEXT,
    :labelcolor_active  => TEXT,
    :labelcolor_hover   => TEXT,
    :padding            => (8.0f0, 8.0f0, 8.0f0, 8.0f0),
    :strokecolor        => COLOR_5,
    :strokewidth        => 0,
    :tellheight         => true,
    :tellwidth          => true,
    :valign             => :center, 
    :width              => 112
)

const BOX_ATTRS = Dict{Symbol, Any}(
    :alignmode     => Inside(),
    :color         => :transparent,
    :cornerradius  => 0,
    :halign        => :center,
    :height        => nothing,
    :linestyle     => nothing,
    :strokecolor   => COLOR_5,
    :strokevisible => true,
    :strokewidth   => 0.5,
    :tellheight    => true,
    :tellwidth     => true,
    :valign        => :center,
    :visible       => true,
    :width         => nothing
)

const PANEL_ATTRS = Dict{Symbol, Any}(
    :alignmode          => Inside(),
    :buttoncolor        => COLOR_3,
    :buttoncolor_active => COLOR_2,
    :buttoncolor_hover  => COLOR_2,
    :clicks             => 0,
    :cornerradius       => 0,
    :cornersegments     => 10,
    :font               => :regular,
    :fontsize           => 12,
    :halign             => :center,
    :height             => 20,
    :labelcolor         => TEXT,
    :labelcolor_active  => TEXT,
    :labelcolor_hover   => TEXT,
    :padding            => (8.0f0, 8.0f0, 8.0f0, 8.0f0),
    :strokecolor        => COLOR_5,
    :strokewidth        => 0,
    :tellheight         => true,
    :tellwidth          => true,
    :valign             => :center, 
    :width              => nothing
)

const LABEL_ATTRS = Dict{Symbol, Any}(
    :alignmode     => Inside(),
    :color         => TEXT,
    :font          => :regular,
    :fontsize      => 12,
    :halign        => :center,
    :height        => Auto(),
    :justification => :center,
    :lineheight    => 1,
    :padding       => (0, 0, 0, 0),
    :rotation      => 0,
    :tellheight    => true,
    :tellwidth     => true,
    :valign        => :center,
    :visible       => true,
    :width         => Auto(),
    :word_wrap     => false,
)

const MENU_ATTRS = Dict{Symbol, Any}(
    :alignmode                     => Inside(),
    :cell_color_active             => COLOR_2,
    :cell_color_hover              => COLOR_2,
    :cell_color_inactive_even      => COLOR_3,
    :cell_color_inactive_odd       => COLOR_3,
    :direction                     => :down,
    :dropdown_arrow_color          => TEXT,
    :dropdown_arrow_size           => 8,
    :fontsize                      => 12,
    :height                        => 24,
    :i_selected                    => 0,
    :is_open                       => false,
    :options                       => ["1", "2", "3"],
    :prompt                        => " ",
    :selection_cell_color_inactive => COLOR_1,
    :textcolor                     => TEXT,
    :tellwidth                     => false,
    :width                         => nothing
)

const SPINNER_BOX_ATTRS  = Dict(
    :alignmode     => Inside(),
    :color         => :transparent,
    :cornerradius  => 0,
    :halign        => :center,
    :height        => nothing,
    :linestyle     => nothing,
    :strokecolor   => COLOR_5,
    :strokevisible => true,
    :strokewidth   => 0.5,
    :tellheight    => true,
    :tellwidth     => true,
    :valign        => :center,
    :visible       => true,
    :width         => nothing
)

const SPINNER_TEXT_ATTRS = Dict{Symbol, Any}(
    :borderwidth                 => 0,
    :boxcolor                    => COLOR_1,
    :boxcolor_focused            => COLOR_2,
    :boxcolor_focused_invalid    => RGBf(0.22, 0.11, 0.11),
    :boxcolor_hover              => COLOR_3,
    :cornerradius                => 0,
    :halign                      => :left,
    :height                      => 24,
    :placeholder                 => " ",
    :reset_on_defocus            => true,
    :textcolor_placeholder       => TEXT,
    :textpadding                 => (8, 0, 0, 4),
    :width                       => 56
)

const SPINNER_UP_ATTRS = Dict{Symbol, Any}(
    :alignmode          => Inside(),
    :buttoncolor        => COLOR_2,
    :buttoncolor_active => COLOR_1,
    :buttoncolor_hover  => COLOR_3,
    :clicks             => 0,
    :cornerradius       => 0,
    :cornersegments     => 10,
    :font               => :bold,
    :fontsize           => 6,
    :halign             => :right,
    :height             => 12,
    :label              => "▲",
    :labelcolor         => TEXT,
    :labelcolor_active  => TEXT,
    :labelcolor_hover   => TEXT,
    :padding            => (8.0f0, 8.0f0, 8.0f0, 8.0f0),
    :strokecolor        => COLOR_5,
    :strokewidth        => 0.2,
    :tellheight         => true,
    :tellwidth          => true,
    :valign             => :top, 
    :width              => 24
)

const SPINNER_DOWN_ATTRS = Dict{Symbol, Any}(
    :alignmode          => Inside(),
    :buttoncolor        => COLOR_2,
    :buttoncolor_active => COLOR_1,
    :buttoncolor_hover  => COLOR_3,
    :clicks             => 0,
    :cornerradius       => 0,
    :cornersegments     => 10,
    :font               => :bold,
    :fontsize           => 6,
    :halign             => :right,
    :height             => 12,
    :label              => "▼",
    :labelcolor         => TEXT,
    :labelcolor_active  => TEXT,
    :labelcolor_hover   => TEXT,
    :padding            => (8.0f0, 8.0f0, 8.0f0, 8.0f0),
    :strokecolor        => COLOR_5,
    :strokewidth        => 0.2,
    :tellheight         => true,
    :tellwidth          => true,
    :valign             => :bottom, 
    :width              => 24
)

const TEXT_ATTRS = Dict{Symbol, Any}(
    :bordercolor                 => COLOR_5,
    :bordercolor_focused         => COLOR_5,
    :bordercolor_focused_invalid => COLOR_5,
    :bordercolor_hover           => COLOR_5,
    :borderwidth                 => 0.5,
    :boxcolor                    => COLOR_1,
    :boxcolor_focused            => COLOR_2,
    :boxcolor_focused_invalid    => RGBf(0.22, 0.11, 0.11),
    :boxcolor_hover              => COLOR_3,
    :cornerradius                => 0,
    :halign                      => :center,
    :height                      => 24,
    :placeholder                 => " ",
    :reset_on_defocus            => true,
    :textcolor_placeholder       => TEXT,
    :textpadding                 => (8, 0, 0, 4),
    :width                       => 56
)

const TOGGLE_ATTRS = Dict{Symbol, Any}(
    :active          => false,
    :alignmode       => Inside(),
    :buttoncolor     => COLOR_2,
    :cornersegments  => 2,
    :framecolor_active => COLOR_5,
    :framecolor_inactive => COLOR_4,
    :halign          => :center,
    :height          => 20,
    :length          => 20,
    :markersize      => 20,
    :orientation     => pi/4,
    :rimfraction     => 1,
    :tellheight      => false,
    :tellwidth       => true,
    :toggleduration  => 0.15,
    :valign          => :center, 
    :width           => 20
)

const PATH_TEXT_ATTRS = Dict{Symbol, Any}(
    :borderwidth                 => 0,
    :boxcolor                    => COLOR_2,
    :boxcolor_focused            => COLOR_3,
    :boxcolor_focused_invalid    => RGBf(0.22, 0.11, 0.11),
    :boxcolor_hover              => COLOR_3,
    :cornerradius                => 0,
    :halign                      => :left,
    :height                      => 24,
    :placeholder                 => " ",
    :reset_on_defocus            => true,
    :textcolor_placeholder       => TEXT,
    :textpadding                 => (8, 0, 0, 4),
    :width                       => 242 - 24
)

const PATH_BOX_ATTRS  = Dict(
    :alignmode     => Inside(),
    :color         => :transparent,
    :cornerradius  => 0,
    :halign        => :center,
    :height        => nothing,
    :linestyle     => nothing,
    :strokecolor   => COLOR_5,
    :strokevisible => true,
    :strokewidth   => 0.5,
    :tellheight    => true,
    :tellwidth     => true,
    :valign        => :center,
    :visible       => true,
    :width         => nothing
)

const PATH_BUTTON_ATTRS = Dict{Symbol, Any}(
    :alignmode          => Inside(),
    :buttoncolor        => COLOR_5,
    :buttoncolor_active => COLOR_2,
    :buttoncolor_hover  => COLOR_3,
    :clicks             => 0,
    :cornerradius       => 0,
    :cornersegments     => 10,
    :font               => :regular,
    :fontsize           => 16,
    :halign             => :right,
    :height             => 24,
    :label              => "A",
    :labelcolor         => TEXT,
    :labelcolor_active  => TEXT,
    :labelcolor_hover   => TEXT,
    :padding            => (8.0f0, 8.0f0, 8.0f0, 8.0f0),
    :strokecolor        => COLOR_5,
    :strokewidth        => 0,
    :tellheight         => true,
    :tellwidth          => true,
    :valign             => :center, 
    :width              => 24
)
