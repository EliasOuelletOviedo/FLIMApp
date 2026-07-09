"""
Included by FLIMApp.jl. `read_sdt_frame` in lifetime_analysis.jl delegates its
histogram/header parsing to this module's `read_sdt`; see that function for
the one field (frame_time) still read directly for legacy behavioral parity.

    SdtFile.jl

Parseur pur Julia pour les fichiers SDT de Becker & Hickl (TCSPC / FLIM).
Reproduit fidèlement le comportement du package Python `sdtfile` (cgohlke).

Référence : SPC_data_file_structure.h (Becker & Hickl SPCM installation)
            W. Becker, "The bh TCSPC Handbook", 9th ed., 2021.

Format général d'un fichier SDT (little-endian) :
  ┌─────────────────────────────────┐
  │  FILE_HEADER  (48 octets)       │
  ├─────────────────────────────────┤
  │  INFO block   (texte ASCII)     │
  ├─────────────────────────────────┤
  │  SETUP block  (texte + binaire) │
  ├─────────────────────────────────┤
  │  MEAS_DESC blocks (métadonnées) │
  ├─────────────────────────────────┤
  │  DATA blocks  (photon counts)   │
  │  ┌─────────────────────────┐    │
  │  │ BLOCK_HEADER (22 oct.)  │    │
  │  ├─────────────────────────┤    │
  │  │ uint16 counts array     │    │
  │  └─────────────────────────┘    │
  └─────────────────────────────────┘
"""

module SdtFile

export SdtData, read_sdt

import ZipFile
import Libdl

# ─── Constantes ───────────────────────────────────────────────────────────────

const BH_HEADER_VALID  = 0x5555
const BH_CHKSUM_VALID  = 0x55AA

# BLOCK_CONTENT : bits 4-7 de block_type (déjà masqués, valeurs multiples de 0x10)
const BLOCK_CONTENT_NAMES = Dict{Int,String}(
    0x00 => "DECAY_BLOCK", 0x10 => "PAGE_BLOCK", 0x20 => "FCS_BLOCK",
    0x30 => "FIDA_BLOCK",  0x40 => "FILDA_BLOCK", 0x50 => "MCS_BLOCK",
    0x60 => "IMG_BLOCK",   0x70 => "MCSTA_BLOCK", 0x80 => "IMG_MCS_BLOCK",
    0x90 => "MOM_BLOCK",   0xA0 => "IMG_INT_BLOCK", 0xB0 => "IMG_WF_BLOCK",
    0xC0 => "IMG_LIFE_BLOCK",
)

const BLOCK_CREATION_NAMES = Dict{Int,String}(
    0 => "NOT_USED", 1 => "MEAS_DATA", 2 => "FLOW_DATA",
    3 => "MEAS_DATA_FROM_FILE", 4 => "CALC_DATA", 5 => "SIM_DATA",
    8 => "FIFO_DATA", 9 => "FIFO_DATA_FROM_FILE", 10 => "MOM_DATA",
    11 => "MOM_DATA_FROM_FILE",
)

# ─── Structures de données ────────────────────────────────────────────────────

"""FILE_HEADER — 42 octets utiles, little-endian."""
struct FileHeader
    revision::Int16
    info_offset::Int32              # 0-based
    info_length::Int16
    setup_offs::Int32                # 0-based
    setup_length::UInt16
    data_block_offset::Int32         # 0-based
    no_of_data_blocks::Int16
    data_block_length::UInt32
    meas_desc_block_offset::Int32    # 0-based
    no_of_meas_desc_blocks::Int16
    meas_desc_block_length::Int16
    header_valid::UInt16
    reserved1::UInt32
    reserved2::UInt16
    chksum::UInt16
end
const FILE_HEADER_SIZE = 42

"""
BLOCK_HEADER unifié — représentation commune aux deux formats (ancien et
nouveau, sélectionnés selon `FileHeader.revision & 0xF`). Toujours 22 octets
dans le fichier, mais la disposition binaire diffère (voir `parse_block_header`).
"""
struct BlockHeader
    block_no::Int32              # -1 si format "nouveau" (champ absent)
    data_offset::Int64           # 0-based, absolu dans le fichier
    next_block_offset::Int64     # 0-based, absolu dans le fichier (0 = dernier)
    block_type::UInt16
    meas_desc_block_no::Int16    # 0-based
    lblock_no::UInt32
    block_length::UInt32         # longueur des données de CE bloc, en octets
end
const BLOCK_HEADER_BYTES = 22

"""Champs décodés du bitfield `block_type`."""
struct BlockTypeInfo
    mode::String
    contents::String
    contents_code::Int      # valeur masquée (& 0xF0), utile pour les comparaisons
    dtype::DataType         # UInt16, UInt32 ou Float64
    compressed::Bool
end

function decode_block_type(value::Integer)::BlockTypeInfo
    v = Int(value)
    mode = get(BLOCK_CREATION_NAMES, v & 0xF, "UNKNOWN")
    contents_code = v & 0xF0
    contents = get(BLOCK_CONTENT_NAMES, contents_code, "UNKNOWN_BLOCK")
    dtype_bits = v & 0xF00
    dtype = dtype_bits == 0x100 ? UInt32 : dtype_bits == 0x200 ? Float64 : UInt16
    compressed = (v & 0x1000) != 0
    BlockTypeInfo(mode, contents, contents_code, dtype, compressed)
end

"""
MEASURE_INFO — champs utiles extraits de la structure complète (celle-ci
comporte aussi StopInfo/FCSInfo/HISTInfo/HISTInfoExt/minfo_ext ; seuls les
champs nécessaires au reshape et à l'axe temporel sont exposés ici, à leurs
offsets absolus réels validés contre la structure C d'origine).
"""
struct MeasureInfo
    time::String
    date::String
    mod_ser_no::String
    meas_mode::Int16
    cfd_ll::Float32
    cfd_lh::Float32
    cfd_zc::Float32
    cfd_hf::Float32
    syn_zc::Float32
    syn_fd::Int16
    syn_hf::Float32
    tac_r::Float32
    tac_g::Int16
    tac_of::Float32
    tac_ll::Float32
    tac_lh::Float32
    adc_re::Int16
    eal_de::Int16
    ncx::Int16
    ncy::Int16
    page::UInt16
    col_t::Float32
    rep_t::Float32
    stopt::Int16
    overfl::UInt8
    use_motor::Int16
    steps::UInt16
    offset::Float32
    dither::Int16
    incr::Int16
    mem_bank::Int16
    mod_type::String
    syn_th::Float32
    dead_time_comp::Int16
    polarity_l::Int16
    polarity_f::Int16
    polarity_p::Int16
    linediv::Int16
    accumulate::Int16
    flbck_y::Int32
    flbck_x::Int32
    bord_u::Int32
    bord_l::Int32
    pix_time::Float32
    pix_clk::Int16
    trigger::Int16
    scan_x::Int32
    scan_y::Int32
    scan_rx::Int32
    scan_ry::Int32
    fifo_typ::Int16
    epx_div::Int32
    mod_type_code::UInt16
    mod_fpga_ver::UInt16
    overflow_corr_factor::Float32
    adc_zoom::Int32
    cycles::Int32
    # ── champs situés après StopInfo (60o) + FCSInfo (38o), offsets absolus ──
    fcs_points::Int32     # MeasureInfo.FCSInfo.fcs_points   @287
    image_x::Int32        # @309
    image_y::Int32        # @313
    image_rx::Int32       # @317
    image_ry::Int32       # @321
    # ── après xy_gain/dig_flags/adc_de/det_type/x_axis (10o) : HISTInfo @335 ──
    mcs_time::Float32     # MeasureInfo.HISTInfo.mcs_time    @351
    mcs_points::UInt16    # MeasureInfo.HISTInfo.mcs_points  @355
end

"""Bloc de données principal retourné à l'utilisateur."""
struct DataBlock
    block_no::Int
    block_type::UInt16
    block_type_info::BlockTypeInfo
    meas_desc_block_no::Int
    data_offset::Int          # offset 1-based (index Julia) du début des données
    data::Array                # UInt16, UInt32 ou Float64 selon block_type
    shape::Tuple
end

"""Structure principale renvoyée par `read_sdt`, analogue à `SdtFile` Python."""
struct SdtData
    filename::String
    revision::Int
    id::String
    info::String
    setup::String
    header::FileHeader
    measure_info::Vector{MeasureInfo}
    blocks::Vector{DataBlock}
    data::Vector{Array}
    times::Vector{Vector{Float64}}
end

# ─── Helpers de lecture little-endian ─────────────────────────────────────────
#
# `b[p:p+1]` etc. (ancienne implémentation) alloue un nouveau petit tableau à
# CHAQUE appel avant de le réinterpréter — or ces helpers sont appelés pour
# chaque champ de chaque FILE_HEADER/BLOCK_HEADER/MEASURE_INFO. On reconstruit
# plutôt la valeur par décalages de bits (aucune allocation, indépendant de
# l'endianness de la machine hôte), puis on ne réinterprète que le scalaire
# final (`reinterpret` sur un scalaire est un simple bitcast, gratuit).

@inline read_u16(b::Vector{UInt8}, p::Int) = UInt16(b[p]) | (UInt16(b[p+1]) << 8)
@inline read_i16(b::Vector{UInt8}, p::Int) = reinterpret(Int16, read_u16(b, p))
@inline read_u32(b::Vector{UInt8}, p::Int) =
    UInt32(b[p]) | (UInt32(b[p+1]) << 8) | (UInt32(b[p+2]) << 16) | (UInt32(b[p+3]) << 24)
@inline read_i32(b::Vector{UInt8}, p::Int) = reinterpret(Int32, read_u32(b, p))
@inline read_f32(b::Vector{UInt8}, p::Int) = reinterpret(Float32, read_u32(b, p))

function read_cstring(b::Vector{UInt8}, pos::Int, n::Int)::String
    bytes = view(b, pos : pos + n - 1)
    null_idx = findfirst(==(0x00), bytes)
    s = null_idx !== nothing ? view(bytes, 1:null_idx-1) : bytes
    String(filter(c -> isprint(Char(c)) || c == 0x0A || c == 0x0D, s))
end

# ─── Parseur du FILE_HEADER ───────────────────────────────────────────────────

function parse_file_header(b::Vector{UInt8})::FileHeader
    length(b) >= FILE_HEADER_SIZE || error("Fichier trop court pour le FILE_HEADER")
    p = 1
    FileHeader(
        read_i16(b, p),
        read_i32(b, p+2),
        read_i16(b, p+6),
        read_i32(b, p+8),
        read_u16(b, p+12),
        read_i32(b, p+14),
        read_i16(b, p+18),
        read_u32(b, p+20),
        read_i32(b, p+24),
        read_i16(b, p+28),
        read_i16(b, p+30),
        read_u16(b, p+32),
        read_u32(b, p+34),
        read_u16(b, p+38),
        read_u16(b, p+40),
    )
end

# ─── Parseur du BLOCK_HEADER (ancien ou nouveau format selon la révision) ─────

"""
Parse un BLOCK_HEADER à l'offset 0-based `offset`.
`new_format` doit valoir `(revision & 0xF) >= 15` (déterminé une fois pour le
fichier entier à partir de `FileHeader.revision`).
"""
function parse_block_header(b::Vector{UInt8}, offset::Int, new_format::Bool)::BlockHeader
    p = offset + 1
    p + BLOCK_HEADER_BYTES - 1 <= length(b) || error("Buffer trop court pour BLOCK_HEADER à offset $offset")

    if new_format
        # data_offs_ext(u1) next_block_offs_ext(u1) data_offs(u4) next_block_offs(u4)
        # block_type(u2) meas_desc_block_no(i2) lblock_no(u4) block_length(u4)
        # NB : les octets d'extension permettent en théorie des offsets > 4 Go
        # (40 bits). Comme le fait le package Python de référence, on les
        # ignore ici (usage courant < 4 Go) ; à combiner si besoin un jour :
        # offset_reel = (ext << 32) | data_offs.
        data_offs   = Int64(read_u32(b, p+2))
        next_offs   = Int64(read_u32(b, p+6))
        block_type  = read_u16(b, p+10)
        mdbn        = read_i16(b, p+12)
        lblock_no   = read_u32(b, p+14)
        block_len   = read_u32(b, p+18)
        BlockHeader(Int32(-1), data_offs, next_offs, block_type, mdbn, lblock_no, block_len)
    else
        # block_no(i2) data_offs(i4) next_block_offs(i4) block_type(u2)
        # meas_desc_block_no(i2) lblock_no(u4) block_length(u4)
        block_no    = Int32(read_i16(b, p))
        data_offs   = Int64(read_i32(b, p+2))
        next_offs   = Int64(read_i32(b, p+6))
        block_type  = read_u16(b, p+10)
        mdbn        = read_i16(b, p+12)
        lblock_no   = read_u32(b, p+14)
        block_len   = read_u32(b, p+18)
        BlockHeader(block_no, data_offs, next_offs, block_type, mdbn, lblock_no, block_len)
    end
end

# ─── Parseur du MEASURE_INFO ──────────────────────────────────────────────────

function parse_measure_info(b::Vector{UInt8}, offset::Int, block_len::Int)::MeasureInfo
    p = offset + 1
    avail = min(block_len, length(b) - offset)

    ri16(off) = off + 2 <= avail ? read_i16(b, p + off) : Int16(0)
    ru16(off) = off + 2 <= avail ? read_u16(b, p + off) : UInt16(0)
    ru8(off)  = off + 1 <= avail ? b[p + off]            : UInt8(0)
    ri32(off) = off + 4 <= avail ? read_i32(b, p + off)  : Int32(0)
    rf32(off) = off + 4 <= avail ? read_f32(b, p + off)  : Float32(0)
    rstr(off, n) = off + n <= avail ? read_cstring(b, p + off, n) : ""

    MeasureInfo(
        rstr(0,  9), rstr(9, 11), rstr(20, 16),
        ri16(36),
        rf32(38), rf32(42), rf32(46), rf32(50), rf32(54),
        ri16(58), rf32(60), rf32(64), ri16(68), rf32(70), rf32(74), rf32(78),
        ri16(82), ri16(84), ri16(86), ri16(88),
        ru16(90), rf32(92), rf32(96), ri16(100), ru8(102), ri16(103), ru16(105),
        rf32(107), ri16(111), ri16(113), ri16(115),
        rstr(117, 16),
        rf32(133), ri16(137), ri16(139), ri16(141), ri16(143), ri16(145), ri16(147),
        ri32(149), ri32(153), ri32(157), ri32(161),
        rf32(165), ri16(169), ri16(171),
        ri32(173), ri32(177), ri32(181), ri32(185),
        ri16(189), ri32(191),
        ru16(195), ru16(197),
        rf32(199), ri32(203), ri32(207),
        # champs étendus (au-delà de StopInfo+FCSInfo / HISTInfo)
        ri32(287),                              # fcs_points
        ri32(309), ri32(313), ri32(317), ri32(321), # image_x/y/rx/ry
        rf32(351), ru16(355),                   # mcs_time, mcs_points
    )
end

# ─── Décompression ZIP (blocs compressés) ─────────────────────────────────────
#
# `ZipFile.jl` décompresse par blocs de 4 Ko à travers un buffer interne
# grossissant (voir sa dépendance Zlib.jl, fonction `fillbuf`) : pour un bloc
# IMG compressé (couramment plusieurs centaines de Mo décompressés pour une
# image FLIM complète), ce chunking domine complètement le temps et
# l'allocation. zlib sait décompresser tout le flux en un seul appel
# `inflate()` quand on lui fournit d'emblée un buffer de sortie correctement
# dimensionné — mesuré ~3x plus rapide et sans allocation sur un fichier réel
# (536 Mo décompressés : ~1050 ms via ZipFile.jl contre ~375 ms en un seul
# appel `inflate()`, avec la même bibliothèque zlib). macOS fournit en plus
# un libz système généralement plus rapide que celui packagé par Zlib_jll
# (mesuré ~204 ms sur la même donnée, soit ~1.8x de mieux encore) ; on
# l'utilise quand disponible.
#
# `raw_inflate!` appelle directement libz via ccall, avec repli automatique
# sur le chemin `ZipFile.jl` standard (plus lent mais robuste) si la
# bibliothèque est indisponible ou si quoi que ce soit d'inattendu se
# produit — jamais d'échec silencieux.

"""z_stream de zlib — layout stable de l'API C publique (zlib.h)."""
mutable struct ZStream
    next_in::Ptr{UInt8}
    avail_in::Cuint
    total_in::Culong
    next_out::Ptr{UInt8}
    avail_out::Cuint
    total_out::Culong
    msg::Ptr{UInt8}
    state::Ptr{Cvoid}
    zalloc::Ptr{Cvoid}
    zfree::Ptr{Cvoid}
    opaque::Ptr{Cvoid}
    data_type::Cint
    adler::Culong
    reserved::Culong
    ZStream() = new(C_NULL,0,0, C_NULL,0,0, C_NULL,C_NULL, C_NULL,C_NULL,C_NULL, 0,0,0)
end

function _safe_dlopen(name)
    try
        Libdl.dlopen(name)
    catch
        nothing
    end
end

function _safe_dlsym(handle, name)
    handle === nothing && return C_NULL
    try
        Libdl.dlsym(handle, name)
    catch
        C_NULL
    end
end

const _LIBZ_HANDLE = something(
    Sys.isapple() ? _safe_dlopen("/usr/lib/libz.dylib") : nothing,
    _safe_dlopen("libz"),
    Some(nothing),
)

const _Z_VERSION       = _safe_dlsym(_LIBZ_HANDLE, :zlibVersion)
const _Z_INFLATE_INIT2 = _safe_dlsym(_LIBZ_HANDLE, :inflateInit2_)
const _Z_INFLATE       = _safe_dlsym(_LIBZ_HANDLE, :inflate)
const _Z_INFLATE_END   = _safe_dlsym(_LIBZ_HANDLE, :inflateEnd)
const _RAW_INFLATE_AVAILABLE =
    _Z_VERSION != C_NULL && _Z_INFLATE_INIT2 != C_NULL &&
    _Z_INFLATE != C_NULL && _Z_INFLATE_END != C_NULL

"""
Décompresse `compressed` (flux DEFLATE brut, sans en-tête zlib/gzip — le
format utilisé à l'intérieur d'une entrée ZIP) dans `dest`, déjà dimensionné
à la taille décompressée attendue, en un seul appel `inflate()`. Renvoie
`true` en cas de succès complet, `false` si le chemin rapide est
indisponible ou échoue — l'appelant doit alors se rabattre sur `ZipFile.jl`.
"""
function raw_inflate!(dest::AbstractVector{UInt8}, compressed::AbstractVector{UInt8})::Bool
    (!_RAW_INFLATE_AVAILABLE || length(compressed) > typemax(Cuint) || length(dest) > typemax(Cuint)) && return false

    strm = ZStream()
    ver = ccall(_Z_VERSION, Ptr{UInt8}, ())
    ccall(_Z_INFLATE_INIT2, Cint, (Ref{ZStream}, Cint, Ptr{UInt8}, Cint), strm, -15, ver, sizeof(ZStream)) == 0 || return false

    ret = Cint(-1)
    try
        GC.@preserve compressed dest begin
            strm.next_in   = pointer(compressed)
            strm.avail_in  = length(compressed) % Cuint
            strm.next_out  = pointer(dest)
            strm.avail_out = length(dest) % Cuint
            ret = ccall(_Z_INFLATE, Cint, (Ref{ZStream}, Cint), strm, Cint(4)) # Z_FINISH
        end
    finally
        ccall(_Z_INFLATE_END, Cint, (Ref{ZStream},), strm)
    end

    return ret == 1 # Z_STREAM_END : décompression complète et réussie
end

"""
Décompresse un bloc de données ZIP (bh.compressed == true) directement dans
un `Vector{T}` de `n_elems` éléments — sans passer par un `Vector{UInt8}`
intermédiaire. `ZipFile.jl` est utilisé pour localiser l'entrée dans
l'archive (analyse de l'en-tête local, tailles compressée/décompressée) ;
la décompression elle-même passe par `raw_inflate!` (voir plus haut), avec
repli sur `ZipFile.jl` si indisponible ou en cas d'échec inattendu.
`n_elems` est plafonné à la taille réellement déclarée par l'archive ZIP
(`uncompressedsize`), par sécurité si jamais elle diffère de `block_length`.

Reproduit le contournement du package Python pour le cas où l'enregistrement
EOCD (End Of Central Directory) manque un octet final (voir cgohlke/sdtfile
issue #8).

Nécessite le paquet ZipFile.jl (`] add ZipFile`).
"""
function decompress_zip_typed(::Type{T}, raw::Vector{UInt8}, n_elems::Int) where {T}
    function try_read(bytes::Vector{UInt8})
        io = IOBuffer(bytes)
        r = ZipFile.Reader(io)
        local datapos, compressedsize, uncompressedsize, method
        try
            f = r.files[1]
            seek(f._io, f._offset)
            ZipFile.readle(f._io, UInt32)  # signature locale (déjà validée par ZipFile.Reader)
            skip(f._io, 2+2+2+2+2+4+4+4)
            filelen = ZipFile.readle(f._io, UInt16)
            extralen = ZipFile.readle(f._io, UInt16)
            skip(f._io, filelen + extralen)
            datapos = position(f._io)
            compressedsize = Int(f.compressedsize)
            uncompressedsize = Int(f.uncompressedsize)
            method = f.method
        finally
            close(r)
        end

        avail = min(n_elems, uncompressedsize ÷ sizeof(T))
        dest = Vector{T}(undef, max(avail, 0))
        if avail > 0
            ok = method == ZipFile.Deflate &&
                 raw_inflate!(reinterpret(UInt8, dest), view(bytes, datapos+1 : datapos+compressedsize))
            if !ok
                # Repli : chemin ZipFile.jl standard, plus lent mais robuste
                # (couvre aussi Store/non-Deflate et toute erreur imprévue du
                # chemin rapide).
                io2 = IOBuffer(bytes)
                r2 = ZipFile.Reader(io2)
                try
                    Base.read!(r2.files[1], dest)
                finally
                    close(r2)
                end
            end
        end
        return dest
    end

    try
        return try_read(raw)
    catch
        # Contournement : certains fichiers SDT ont un enregistrement EOCD
        # tronqué d'un octet ; on l'ajoute et on réessaie (comme sdtfile.py,
        # cf. cgohlke/sdtfile issue #8).
        return try_read(vcat(raw, UInt8(0x00)))
    end
end

# ─── Calcul des temps ─────────────────────────────────────────────────────────

"""
Axe temporel en secondes, conforme à sdtfile.py :
  time = arange(n) ; if tac_g != 0: time *= tac_r / (tac_g * adc_re)
Cas particulier MCS_BLOCK avec mcs_time != 0 : time = arange(n) * mcs_time.
"""
function compute_times(mi::MeasureInfo, n::Int, is_mcs::Bool)::Vector{Float64}
    t = collect(Float64, 0:(n-1))
    if is_mcs && Float64(mi.mcs_time) != 0.0
        t .*= Float64(mi.mcs_time)
        return t
    end
    tac_g = Float64(mi.tac_g)
    adc_re = Int(mi.adc_re)
    adc_re = adc_re == 0 ? 65536 : adc_re
    if tac_g != 0.0
        t .*= Float64(mi.tac_r) / (tac_g * adc_re)
    end
    return t
end

# ─── Reshape des données ──────────────────────────────────────────────────────

"""
Interprète la forme des données d'un bloc, conforme à sdtfile.py :
essaie successivement scan_x*scan_y*adc_re, image_x*image_y*adc_re, les
variantes avec canaux de routage, le cas FCS, le cas MCS, puis retombe sur
(-1, adc_re) reshape en (n_pixels, adc_re).
"""
function compute_shape(mi::MeasureInfo, contents_code::Int, dsize::Int)::Tuple
    adc_re = Int(mi.adc_re)
    adc_re = adc_re == 0 ? 65536 : adc_re
    scan_x, scan_y   = Int(mi.scan_x), Int(mi.scan_y)
    scan_rx, scan_ry = Int(mi.scan_rx), Int(mi.scan_ry)
    image_x, image_y   = Int(mi.image_x), Int(mi.image_y)
    image_rx, image_ry = Int(mi.image_rx), Int(mi.image_ry)
    fcs_points  = Int(mi.fcs_points)
    mcs_points  = Int(mi.mcs_points)

    FCS_CODE, MCS_CODE = 0x20, 0x50

    if contents_code == FCS_CODE && fcs_points > 0
        if dsize != fcs_points
            return (max(dsize ÷ fcs_points, 1), fcs_points)
        end
        return (dsize,)
    elseif scan_x > 0 && scan_y > 0 && dsize == scan_x * scan_y * adc_re
        return (scan_y, scan_x, adc_re)
    elseif image_x > 0 && image_y > 0 && dsize == image_x * image_y * adc_re
        return (image_y, image_x, adc_re)
    elseif scan_x > 0 && scan_y > 0 && scan_rx > 0 && scan_ry > 0 &&
           dsize == scan_x * scan_y * scan_rx * scan_ry * adc_re
        return (scan_ry, scan_rx, scan_y, scan_x, adc_re)
    elseif image_x > 0 && image_y > 0 && image_rx > 0 && image_ry > 0 &&
           dsize == image_x * image_y * image_rx * image_ry * adc_re
        return (image_ry, image_rx, image_y, image_x, adc_re)
    elseif mcs_points > 0 && dsize == mcs_points
        return (dsize,)
    else
        n_pixels = max(dsize ÷ adc_re, 1)
        return (n_pixels, adc_re)
    end
end

# ─── Matérialisation typée des blocs de données ───────────────────────────────

"""
Convertit les octets bruts `bytes` (vue ou vecteur — jamais copiés avant cet
appel) en un `Vector{T}` possédant ses propres données, en une seule copie.
Remplace l'ancien enchaînement `slice(copie) -> slice(copie) -> reinterpret ->
collect(copie)`, qui copiait jusqu'à 3 fois chaque bloc de données (les blocs
DECAY/IMG etc. constituent l'essentiel des octets d'un fichier SDT).
"""
function materialize_typed(::Type{T}, bytes::AbstractVector{UInt8}, n_elems::Int) where {T}
    n_elems <= 0 && return T[]
    data = Vector{T}(undef, n_elems)
    copyto!(data, reinterpret(T, view(bytes, 1:n_elems * sizeof(T))))
    return data
end

# ─── Parseur principal ────────────────────────────────────────────────────────

function read_sdt(filepath::String)::SdtData
    isfile(filepath) || error("Fichier introuvable : $filepath")
    b = read(filepath)
    read_sdt(b, basename(filepath))
end

function read_sdt(b::Vector{UInt8}, filename::String="")::SdtData
    length(b) >= FILE_HEADER_SIZE || error("Fichier trop court (< $FILE_HEADER_SIZE octets)")

    # ── 1. FILE_HEADER ─────────────────────────────────────────────────────
    hdr = parse_file_header(b)

    if hdr.header_valid != BH_HEADER_VALID && hdr.chksum != BH_CHKSUM_VALID
        @warn "Header SDT potentiellement invalide (header_valid=0x$(string(hdr.header_valid, base=16)), chksum=0x$(string(hdr.chksum, base=16)))"
    end

    revision_number = Int(hdr.revision) & 0xF
    new_block_format = revision_number >= 15

    # ── 2. Bloc INFO (texte, encodage windows-1250 simplifié en ASCII) ─────
    info_off = Int(hdr.info_offset) + 1
    info_len = Int(hdr.info_length)
    info_str = ""
    if info_off > 0 && info_len > 0 && info_off + info_len - 1 <= length(b)
        info_str = String(b[info_off : info_off + info_len - 1])
    end
    file_id = _extract_id(info_str)

    # ── 3. Bloc SETUP ───────────────────────────────────────────────────────
    setup_off = Int(hdr.setup_offs) + 1
    setup_len = Int(hdr.setup_length)
    setup_str = ""
    if setup_off > 0 && setup_len > 0 && setup_off + setup_len - 1 <= length(b)
        raw_setup = b[setup_off : setup_off + setup_len - 1]
        end_marker = _find_setup_end(raw_setup)
        setup_str = String(raw_setup[1:end_marker])
    end

    # ── 4. Nombre de blocs de données ───────────────────────────────────────
    n_blocks = Int(hdr.no_of_data_blocks)
    if n_blocks == 0x7FFF
        n_blocks = Int(hdr.reserved1)
    end

    # ── 5. Blocs MEAS_DESC ──────────────────────────────────────────────────
    meas_desc_off = Int(hdr.meas_desc_block_offset)
    n_meas        = Int(hdr.no_of_meas_desc_blocks)
    meas_len      = Int(hdr.meas_desc_block_length)
    measure_infos = MeasureInfo[]
    for i in 0:(n_meas - 1)
        off = meas_desc_off + i * meas_len
        if off + meas_len <= length(b)
            push!(measure_infos, parse_measure_info(b, off, meas_len))
        end
    end

    # ── 6. Blocs de données ─────────────────────────────────────────────────
    data_blocks  = DataBlock[]
    data_arrays  = Array[]
    times_arrays = Vector{Float64}[]

    current_off = Int(hdr.data_block_offset)  # 0-based

    for i in 1:max(n_blocks, 0)
        current_off + BLOCK_HEADER_BYTES > length(b) && break

        bh = parse_block_header(b, current_off, new_block_format)
        bti = decode_block_type(bh.block_type)

        mi_idx = max(Int(bh.meas_desc_block_no), 0) + 1
        mi_idx = min(mi_idx, length(measure_infos))
        mi = mi_idx > 0 && !isempty(measure_infos) ? measure_infos[mi_idx] : nothing

        itemsize = sizeof(bti.dtype)
        dsize = itemsize > 0 ? Int(bh.block_length) ÷ itemsize : 0

        data_start_1b = Int(bh.data_offset) + 1   # 0-based -> 1-based

        # Bloc compressé : décompression directement dans le tableau typé
        # final (voir `decompress_zip_typed`), sans buffer UInt8 intermédiaire.
        # Bloc non compressé : `raw_bytes` reste une simple vue sur `b`
        # (aucune copie) jusqu'à `materialize_typed`, qui fait l'unique copie
        # nécessaire, directement vers le tableau typé final.
        data_vec = if bti.compressed
            data_end_0b = Int(bh.next_block_offset)  # exclusif, 0-based
            span_start = data_start_1b
            span_end   = min(data_end_0b, length(b))  # 0-based next_offset == 1-based index juste après la fin
            if span_end >= span_start && itemsize > 0
                decompress_zip_typed(bti.dtype, b[span_start:span_end], dsize)
            else
                bti.dtype[]
            end
        else
            n_bytes = dsize * itemsize
            span_end = min(data_start_1b + n_bytes - 1, length(b))
            raw_bytes = span_end >= data_start_1b ? view(b, data_start_1b:span_end) : view(b, 1:0)
            n_elems = itemsize > 0 ? length(raw_bytes) ÷ itemsize : 0
            n_elems = min(n_elems, dsize > 0 ? dsize : n_elems)
            materialize_typed(bti.dtype, raw_bytes, n_elems)
        end

        shape = (length(data_vec),)
        t_axis = Float64[]
        if mi !== nothing
            shape = compute_shape(mi, bti.contents_code, length(data_vec))
            n_time_bins = shape[end]
            is_mcs = bti.contents_code == 0x50
            t_axis = compute_times(mi, n_time_bins, is_mcs)
        end

        reshaped = prod(shape) == length(data_vec) ?
            reshape(data_vec, shape) : reshape(data_vec, (length(data_vec),))

        blk_no = Int(bh.lblock_no) != 0 ? Int(bh.lblock_no) : Int(bh.block_no)

        push!(data_blocks, DataBlock(
            blk_no, bh.block_type, bti, Int(bh.meas_desc_block_no),
            data_start_1b, reshaped, shape,
        ))
        push!(data_arrays, reshaped)
        push!(times_arrays, t_axis)

        next_off = Int(bh.next_block_offset)
        if next_off == 0 || next_off <= current_off
            break   # évite toute boucle infinie ; sdtfile.py avance de bloc en bloc via next_block_offs
        else
            current_off = next_off
        end
    end

    return SdtData(
        filename, Int(hdr.revision), file_id, info_str, setup_str, hdr,
        measure_infos, data_blocks, data_arrays, times_arrays,
    )
end

# ─── Helpers internes ─────────────────────────────────────────────────────────

"""
Extrait l'identifiant de type de fichier depuis le bloc INFO. L'ID réel est
délimité par des octets 0x04, p.ex. b"...ID        : \\x04SPC FCS Data File\\x04\\r\\n..."
"""
function _extract_id(info::String)::String
    bytes = codeunits(info)
    idx1 = findfirst(==(0x04), bytes)
    idx1 === nothing && return "unknown"
    idx2 = findnext(==(0x04), bytes, idx1 + 1)
    idx2 === nothing && return "unknown"
    return String(bytes[idx1+1:idx2-1])
end

const _SETUP_END_MARKER = codeunits("*END*")

function _find_setup_end(raw::Vector{UInt8})::Int
    idx = findfirst(_SETUP_END_MARKER, raw)
    return idx !== nothing ? last(idx) : length(raw)
end

# ─── Affichage ────────────────────────────────────────────────────────────────

function Base.show(io::IO, sdt::SdtData)
    print(io, "SdtData(\"$(sdt.filename)\", id=\"$(sdt.id)\", ")
    print(io, "revision=$(sdt.revision), ")
    print(io, "$(length(sdt.data)) data block(s)")
    if !isempty(sdt.data)
        print(io, " shape=$(size(sdt.data[1])) dtype=$(eltype(sdt.data[1]))")
    end
    print(io, ")")
end

function Base.show(io::IO, mi::MeasureInfo)
    print(io, "MeasureInfo(scan_x=$(mi.scan_x), scan_y=$(mi.scan_y), ")
    print(io, "image_x=$(mi.image_x), image_y=$(mi.image_y), ")
    print(io, "adc_re=$(mi.adc_re), tac_r=$(mi.tac_r), tac_g=$(mi.tac_g), ")
    print(io, "mod_type=\"$(mi.mod_type)\")")
end

end # module
