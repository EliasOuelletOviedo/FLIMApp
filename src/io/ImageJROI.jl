
"""
Included by FLIMApp.jl. Backs the ROI popup (roi_popup.jl)'s "Import ROI"
button, which reads .roi/.zip files via `read_roi`/`read_roi_zip` below.

    ImageJROI.jl

Parseur pur Julia pour les fichiers ROI d'ImageJ (.roi et .zip de ROIs).
Basé sur la spécification officielle de RoiDecoder.java d'ImageJ.

Format du header 64 octets (big-endian) :
  0-3   "Iout" (magic)
  4-5   version (>=217)
  6-7   roi type (1 octet utilisé)
  8-9   top
  10-11 left
  12-13 bottom
  14-15 right
  16-17 NCoordinates
  18-33 x1,y1,x2,y2 (ligne) | x,y,w,h (rect double) | size (npoints)
  34-35 stroke width
  36-39 ShapeRoi size
  40-43 stroke color
  44-47 fill color
  48-49 subtype
  50-51 options
  52    arrow style / aspect ratio
  53    arrow head size
  54-55 rounded rect arc size
  56-59 position
  60-63 header2 offset
  64-   coordonnées x (Int16), puis y (Int16)
        [suivi optionnellement de float x, float y si SUB_PIXEL_RESOLUTION]
"""
module ImageJROI

using ZipFile

export ROIData, read_roi, read_roi_zip

# ─── Constantes du format ─────────────────────────────────────────────────────

# Offsets dans le header (1-based en Julia → offset 0-based + 1)
const OFFSET_MAGIC        = 1   # 0-3
const OFFSET_VERSION      = 5   # 4-5
const OFFSET_TYPE         = 7   # 6   (1 octet)
const OFFSET_TOP          = 9   # 8-9
const OFFSET_LEFT         = 11  # 10-11
const OFFSET_BOTTOM       = 13  # 12-13
const OFFSET_RIGHT        = 15  # 14-15
const OFFSET_N_COORDS     = 17  # 16-17
const OFFSET_X1           = 19  # 18-21
const OFFSET_Y1           = 23  # 22-25
const OFFSET_X2           = 27  # 26-29
const OFFSET_Y2           = 31  # 30-33
const OFFSET_STROKE_WIDTH = 35  # 34-35
const OFFSET_SHAPE_SIZE   = 37  # 36-39
const OFFSET_STROKE_COLOR = 41  # 40-43
const OFFSET_FILL_COLOR   = 45  # 44-47
const OFFSET_SUBTYPE      = 49  # 48-49
const OFFSET_OPTIONS      = 51  # 50-51
const OFFSET_ARROW_STYLE  = 53  # 52
const OFFSET_ARROW_HEAD   = 54  # 53
const OFFSET_ARC_SIZE     = 55  # 54-55
const OFFSET_POSITION     = 57  # 56-59
const OFFSET_HEADER2      = 61  # 60-63
const HEADER_SIZE         = 64

# Offsets dans le header2 (relatifs au début du header2)
const H2_C_POSITION           = 4   # +4
const H2_Z_POSITION           = 8   # +8
const H2_T_POSITION           = 12  # +12
const H2_NAME_OFFSET          = 16  # +16
const H2_NAME_LENGTH          = 20  # +20
const H2_OVERLAY_LABEL_COLOR  = 24  # +24
const H2_OVERLAY_FONT_SIZE    = 28  # +28
const H2_AVAILABLE_BYTE1      = 32  # +32
const H2_IMAGE_OPACITY        = 33  # +33
const H2_IMAGE_SIZE           = 34  # +34
const H2_FLOAT_STROKE_WIDTH   = 38  # +38
const H2_ROI_PROPS_OFFSET     = 42  # +42
const H2_ROI_PROPS_LENGTH     = 46  # +46
const H2_COUNTERS_OFFSET      = 50  # +50

# Types de ROI
const ROI_TYPES = Dict{Int,String}(
    0  => "polygon",
    1  => "rect",
    2  => "oval",
    3  => "line",
    4  => "freeline",
    5  => "polyline",
    6  => "no_roi",
    7  => "freehand",
    8  => "traced",
    9  => "angle",
    10 => "point",
)

# Subtypes
const ROI_SUBTYPES = Dict{Int,String}(
    0 => "none",
    1 => "text",
    2 => "arrow",
    3 => "ellipse",
    4 => "image",
    5 => "rotated_rect",
)

# Flags d'options
const OPT_SPLINE_FIT          = 1
const OPT_DOUBLE_HEADED       = 2
const OPT_OUTLINE             = 4
const OPT_OVERLAY_LABELS      = 8
const OPT_OVERLAY_NAMES       = 16
const OPT_OVERLAY_BACKGROUNDS = 32
const OPT_OVERLAY_BOLD        = 64
const OPT_SUB_PIXEL           = 128
const OPT_DRAW_OFFSET         = 256
const OPT_ZERO_TRANSPARENT    = 512
const OPT_SHOW_LABELS         = 1024
const OPT_SCALE_LABELS        = 2048
const OPT_PROMPT_BEFORE_DEL   = 4096
const OPT_SCALE_STROKE_WIDTH  = 8192

# ─── Structure de données ─────────────────────────────────────────────────────

"""
Structure contenant toutes les données d'un ROI ImageJ.
Reproduit fidèlement les champs exposés par le package Python `roifile`.
"""
struct ROIData
    # Identité
    name::String
    version::Int
    roitype::String         # "polygon", "rect", "oval", etc.
    subtype::String         # "none", "text", "arrow", "ellipse", etc.

    # Bounding box
    top::Int
    left::Int
    bottom::Int
    right::Int
    width::Int              # right - left
    height::Int             # bottom - top

    # Nombre de coordonnées / points
    n_coordinates::Int

    # Coordonnées (vides si rect/oval sans points)
    x_coordinates::Vector{Float32}
    y_coordinates::Vector{Float32}

    # Ligne droite (type == "line")
    x1::Float32
    y1::Float32
    x2::Float32
    y2::Float32

    # Style
    stroke_width::Int
    stroke_color::UInt32
    fill_color::UInt32
    arc_size::Int           # rounded rect

    # Flags
    options::Int
    spline_fit::Bool
    sub_pixel_resolution::Bool
    draw_offset::Bool
    show_labels::Bool

    # Position dans la stack
    position::Int
    c_position::Int
    z_position::Int
    t_position::Int

    # Propriétés textuelles (header2)
    roi_props::String

    # Taille ShapeRoi (>0 → composite)
    shape_roi_size::Int
end

# ─── Helpers de lecture big-endian ───────────────────────────────────────────

@inline function read_int16(buf::Vector{UInt8}, offset::Int)::Int
    # offset est 1-based (Julia)
    raw = (Int(buf[offset]) << 8) | Int(buf[offset+1])
    # conversion en signé 16 bits
    raw >= 32768 ? Int(raw - 65536) : Int(raw)
end

@inline function read_uint16(buf::Vector{UInt8}, offset::Int)::Int
    (Int(buf[offset]) << 8) | Int(buf[offset+1])
end

@inline function read_int32(buf::Vector{UInt8}, offset::Int)::Int32
    v = (Int32(buf[offset]) << 24) | (Int32(buf[offset+1]) << 16) |
        (Int32(buf[offset+2]) << 8) | Int32(buf[offset+3])
    v
end

@inline function read_uint32(buf::Vector{UInt8}, offset::Int)::UInt32
    (UInt32(buf[offset]) << 24) | (UInt32(buf[offset+1]) << 16) |
    (UInt32(buf[offset+2]) << 8) | UInt32(buf[offset+3])
end

@inline function read_float32(buf::Vector{UInt8}, offset::Int)::Float32
    bits = read_uint32(buf, offset)
    reinterpret(Float32, bits)
end

# Lecture d'une chaîne UTF-16BE (format Java)
function read_utf16be(buf::Vector{UInt8}, offset::Int, n_chars::Int)::String
    chars = Char[]
    for i in 0:(n_chars-1)
        codepoint = read_uint16(buf, offset + i*2)
        push!(chars, Char(codepoint))
    end
    String(chars)
end

# ─── Parseur principal ────────────────────────────────────────────────────────

"""
    read_roi(data::Vector{UInt8}, name::String="") -> ROIData

Parse un buffer binaire contenant un ROI ImageJ et retourne un `ROIData`.
"""
function read_roi(data::Vector{UInt8}, name::String="")::ROIData
    length(data) < HEADER_SIZE && error("Fichier ROI trop court (< 64 octets)")

    # ── Magic ──────────────────────────────────────────────────────────────
    magic = String(data[1:4])
    magic == "Iout" || error("Magic incorrecte : $(repr(magic)) (attendu \"Iout\")")

    # ── Header principal ────────────────────────────────────────────────────
    version      = read_uint16(data, OFFSET_VERSION)
    roi_type_int = Int(data[OFFSET_TYPE])          # octet 6
    top          = read_int16(data, OFFSET_TOP)
    left         = read_int16(data, OFFSET_LEFT)
    bottom       = read_int16(data, OFFSET_BOTTOM)
    right_val    = read_int16(data, OFFSET_RIGHT)
    n_coords     = read_int16(data, OFFSET_N_COORDS)

    # Ligne droite / rect double précision
    x1d = read_float32(data, OFFSET_X1)
    y1d = read_float32(data, OFFSET_Y1)
    x2d = read_float32(data, OFFSET_X2)
    y2d = read_float32(data, OFFSET_Y2)

    stroke_width  = read_int16(data, OFFSET_STROKE_WIDTH)
    shape_size    = Int(read_int32(data, OFFSET_SHAPE_SIZE))
    stroke_color  = read_uint32(data, OFFSET_STROKE_COLOR)
    fill_color    = read_uint32(data, OFFSET_FILL_COLOR)
    subtype_int   = read_uint16(data, OFFSET_SUBTYPE)
    options_int   = read_uint16(data, OFFSET_OPTIONS)
    arc_size      = read_uint16(data, OFFSET_ARC_SIZE)
    position      = Int(read_int32(data, OFFSET_POSITION))
    hdr2_offset   = Int(read_int32(data, OFFSET_HEADER2))

    roi_type_str = get(ROI_TYPES, roi_type_int, "unknown_$(roi_type_int)")
    subtype_str  = get(ROI_SUBTYPES, subtype_int, "unknown_$(subtype_int)")

    # Flags
    sub_pixel   = (options_int & OPT_SUB_PIXEL) != 0
    spline_fit  = (options_int & OPT_SPLINE_FIT) != 0
    draw_offset = (options_int & OPT_DRAW_OFFSET) != 0
    show_labels = (options_int & OPT_SHOW_LABELS) != 0

    # ── Coordonnées ────────────────────────────────────────────────────────
    x_coords = Float32[]
    y_coords = Float32[]

    # Pour rect/oval sans coordonnées explicites, n_coords <= 0
    n = max(n_coords, 0)

    if n > 0
        coord_base = HEADER_SIZE + 1  # 1-based

        if sub_pixel && n * 2 * 4 <= length(data) - HEADER_SIZE
            # Coordonnées float 32 bits (sub-pixel)
            # Layout : n float x puis n float y
            float_base = coord_base + n * 2 * 2  # après les int16
            # Vérifie si les floats sont présents après les int16
            if float_base + n * 2 * 4 - 1 <= length(data)
                for i in 0:(n-1)
                    xf = read_float32(data, float_base + i * 4)
                    push!(x_coords, xf)
                end
                for i in 0:(n-1)
                    yf = read_float32(data, float_base + n * 4 + i * 4)
                    push!(y_coords, yf)
                end
            end
        end

        # Si pas de floats ou sub_pixel=false → coordonnées int16
        if isempty(x_coords)
            for i in 0:(n-1)
                xi = read_int16(data, coord_base + i * 2)
                push!(x_coords, Float32(xi + left))
            end
            for i in 0:(n-1)
                yi = read_int16(data, coord_base + n * 2 + i * 2)
                push!(y_coords, Float32(yi + top))
            end
        end
    end

    # ── Header 2 ───────────────────────────────────────────────────────────
    c_pos     = 0
    z_pos     = 0
    t_pos     = 0
    roi_props = ""
    roi_name  = name

    if hdr2_offset > 0 && hdr2_offset + 64 <= length(data)
        h2 = hdr2_offset + 1  # 1-based

        c_pos = Int(read_int32(data, h2 + H2_C_POSITION))
        z_pos = Int(read_int32(data, h2 + H2_Z_POSITION))
        t_pos = Int(read_int32(data, h2 + H2_T_POSITION))

        name_offset = Int(read_int32(data, h2 + H2_NAME_OFFSET))
        name_length = Int(read_int32(data, h2 + H2_NAME_LENGTH))
        if name_offset > 0 && name_length > 0
            abs_name_offset = name_offset + 1
            if abs_name_offset + name_length * 2 - 1 <= length(data)
                roi_name = read_utf16be(data, abs_name_offset, name_length)
            end
        end

        props_offset = Int(read_int32(data, h2 + H2_ROI_PROPS_OFFSET))
        props_length = Int(read_int32(data, h2 + H2_ROI_PROPS_LENGTH))
        if props_offset > 0 && props_length > 0
            abs_props_offset = props_offset + 1
            if abs_props_offset + props_length * 2 - 1 <= length(data)
                roi_props = read_utf16be(data, abs_props_offset, props_length)
            end
        end
    end

    return ROIData(
        roi_name,
        version,
        roi_type_str,
        subtype_str,
        top, left, bottom, right_val,
        right_val - left,
        bottom - top,
        n,
        x_coords,
        y_coords,
        x1d, y1d, x2d, y2d,
        stroke_width,
        stroke_color,
        fill_color,
        arc_size,
        options_int,
        spline_fit,
        sub_pixel,
        draw_offset,
        show_labels,
        position,
        c_pos, z_pos, t_pos,
        roi_props,
        shape_size,
    )
end

"""
    read_roi(filepath::String) -> ROIData

Lit un fichier `.roi` depuis le disque.
"""
function read_roi(filepath::String)::ROIData
    endswith(lowercase(filepath), ".roi") ||
        @warn "Le fichier $(filepath) ne semble pas être un .roi"
    data = read(filepath)
    name = splitext(basename(filepath))[1]
    read_roi(data, name)
end

"""
    read_roi_zip(filepath::String) -> Dict{String, ROIData}

Lit un fichier `.zip` contenant plusieurs ROIs ImageJ.
Retourne un dictionnaire nom → ROIData (même ordre que roifile Python).
"""
function read_roi_zip(filepath::String)::Dict{String,ROIData}
    result = Dict{String,ROIData}()
    zf = ZipFile.Reader(filepath)
    try
        for f in zf.files
            fname = basename(f.name)
            if endswith(lowercase(fname), ".roi")
                data = read(f)
                name = splitext(fname)[1]
                result[name] = read_roi(data, name)
            end
        end
    finally
        close(zf)
    end
    return result
end

end # module