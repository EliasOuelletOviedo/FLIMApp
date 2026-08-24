"""
io/BigTiffFile.jl

Minimal TIFF / BigTIFF reader for the uncompressed, single-image files the
acquisition consumes, used by tiff_source.jl's frame reading and by the ROI
popup's image import.

Deliberately not a general TIFF library. The Bliq VMS acquisition writes a
very narrow subset of the format — verified across six sessions and 54
sampled headers, every file identical in shape:

    BigTIFF (version 43), little-endian, 1024x1024, 8 bits/sample,
    1 sample/pixel, Compression=1 (none), one strip, pixel data contiguous
    at a fixed offset, a single IFD (one image per file).

For that subset the whole read collapses to a `seek` plus one bulk
`unsafe_read` into a caller-owned buffer, which benchmarked at 0.081 ms per
1 MB frame against an 8.33 ms budget (60 Hz x 2 channels) — roughly 1% of
the frame budget, and four times cheaper than the `mean()` reduction that
follows it. A general-purpose library would allocate a fresh array per frame
and run colorimetric conversions this pipeline never needs, so the narrow
reader is both faster and one less dependency to carry into the
PackageCompiler build.

What it accepts beyond the exact acquisition format, and why:

- **Classic TIFF (42) as well as BigTIFF (43)**: the ROI popup lets the user
  import an arbitrary image to draw ROIs on, and files coming out of ImageJ
  are ordinarily classic TIFF.
- **8-, 16- and 32-bit samples**: the acquisition is 8-bit today, but that is a
  camera setting rather than a property of the pipeline, so a switch to a
  deeper format must not require touching this code. At 32 bits the
  `SampleFormat` tag decides between unsigned integers and IEEE floats — the
  two are indistinguishable by width, and reading one as the other yields
  plausible numbers rather than an error, so the tag is honored rather than
  assumed.
- **Multiple strips**: ImageJ writes `RowsPerStrip` well below the image
  height, so an imported reference image is routinely multi-strip even
  though acquisition frames never are.

Anything outside that — compression, more than one sample per pixel, a bit
depth that is none of 8, 16 or 32, or a sample format the depth does not allow
— is rejected with a specific error rather than decoded incorrectly, on the
principle that a wrong image silently feeding the ratio is far worse than a
failed read.
"""
module BigTiffFile

export TiffInfo, read_info, read_frame!, read_frame, sample_type

# TIFF tags this reader consults. Everything else in the IFD is skipped.
const TAG_IMAGE_WIDTH       = 256
const TAG_IMAGE_LENGTH      = 257
const TAG_BITS_PER_SAMPLE   = 258
const TAG_COMPRESSION       = 259
const TAG_STRIP_OFFSETS     = 273
const TAG_SAMPLES_PER_PIXEL = 277
const TAG_STRIP_BYTE_COUNTS = 279
const TAG_SAMPLE_FORMAT     = 339

const COMPRESSION_NONE = 1

# SampleFormat values (tag 339). Only these two are meaningful here: at 32 bits
# the same bit width means completely different numbers depending on which one
# it is, and reading a float buffer as integers produces plausible-looking
# garbage rather than an error.
const SAMPLE_FORMAT_UINT = 1
const SAMPLE_FORMAT_IEEE = 3

const MAGIC_CLASSIC = 42
const MAGIC_BIG     = 43

# Byte width of each TIFF field type code, indexed by the code itself.
# Types 1-12 are classic TIFF; 16-18 (LONG8/SLONG8/IFD8) are BigTIFF-only.
const TYPE_SIZES = Dict{UInt16, Int}(
    1 => 1, 2 => 1, 3 => 2, 4 => 4, 5 => 8, 6 => 1, 7 => 1,
    8 => 2, 9 => 4, 10 => 8, 11 => 4, 12 => 8,
    16 => 8, 17 => 8, 18 => 8
)

const HOST_IS_LITTLE_ENDIAN = (ENDIAN_BOM == 0x04030201)

"""
    TiffInfo

Everything needed to pull the pixels out of one TIFF image: geometry, sample
depth, byte order, and the strip table locating the pixel data.

`strip_offsets` and `strip_byte_counts` are parallel and in image order, so
concatenating the strips in sequence reproduces the image rows top to bottom.
For the acquisition's own files both vectors have length 1.
"""
struct TiffInfo
    width::Int
    height::Int
    bits_per_sample::Int
    sample_format::Int
    little_endian::Bool
    strip_offsets::Vector{Int}
    strip_byte_counts::Vector{Int}
end

"""
    sample_type(info::TiffInfo)

The Julia element type matching `info`'s sample depth and format: `UInt8` for
8-bit, `UInt16` for 16-bit, and at 32 bits either `UInt32` or `Float32`
depending on `SampleFormat`.

Callers use this to size a frame buffer once, from the first file of a run,
then reuse it for every later frame — the element type is what carries the
depth through the rest of the pipeline, so nothing downstream has to branch on
it at runtime.
"""
function sample_type(info::TiffInfo)
    info.bits_per_sample == 8 && return UInt8
    info.bits_per_sample == 16 && return UInt16
    return info.sample_format == SAMPLE_FORMAT_IEEE ? Float32 : UInt32
end

"""
    pixel_count(info::TiffInfo)

Number of samples in the image — the exact length a buffer passed to
`read_frame!` must have.
"""
pixel_count(info::TiffInfo) = info.width * info.height

# Reinterpret a value read in the file's byte order into host order. TIFF
# stores its own endianness in the first two bytes rather than mandating one,
# so every multi-byte field has to go through this.
@inline fix_endian(x, little::Bool) = little ? ltoh(x) : ntoh(x)

@inline function read_scalar(io::IO, ::Type{T}, little::Bool) where {T}
    return fix_endian(read(io, T), little)
end

# Assemble integers byte by byte out of a raw buffer, honoring the file's
# byte order. `reinterpret` on a slice would be more direct, but slicing
# allocates a fresh array per field — and this runs once per tag, per frame,
# on the acquisition hot path. Manual assembly keeps IFD parsing allocation
# free apart from the entry table itself and the strip vectors.
@inline function load_uint(b::Vector{UInt8}, i::Int, nbytes::Int, little::Bool)::UInt64
    value = UInt64(0)
    if little
        @inbounds for k in 0:(nbytes - 1)
            value |= UInt64(b[i + k]) << (8 * k)
        end
    else
        @inbounds for k in 0:(nbytes - 1)
            value = (value << 8) | UInt64(b[i + k])
        end
    end
    return value
end

"""
    ifd_values!(out, io, entries, base, little, is_big, field_type, count) -> Vector{Int}

Resolve one IFD entry's value(s) into `out`, which is resized to `count`.

A TIFF entry stores its value inline when it fits in the entry's payload slot
(4 bytes classic, 8 bytes BigTIFF) and stores a file offset otherwise. Which
of the two applies is not flagged anywhere — it must be recomputed from the
field's type size times its count, which is what the `total_bytes <= slot`
test below does. Getting this wrong is the classic way to misparse a TIFF:
a single-strip image stores its offset inline, a multi-strip one stores a
pointer to an array of them, and both use the same tag.

`base` is the entry's 0-based start within `entries`; the payload slot sits
at a fixed offset from it that differs between the two TIFF flavors.
"""
function ifd_values!(out::Vector{Int}, io::IO, entries::Vector{UInt8}, base::Int,
                     little::Bool, is_big::Bool, field_type::UInt16, count::Int)
    type_size = get(TYPE_SIZES, field_type, 0)
    type_size == 0 && throw(ArgumentError("Unsupported TIFF field type $field_type"))

    slot = is_big ? 8 : 4
    payload_at = base + (is_big ? 13 : 9)
    total_bytes = type_size * count

    resize!(out, count)

    if total_bytes <= slot
        @inbounds for i in 1:count
            out[i] = Int(load_uint(entries, payload_at + (i - 1) * type_size, type_size, little))
        end
        return out
    end

    offset = Int(load_uint(entries, payload_at, slot, little))
    seek(io, offset)
    raw = read(io, total_bytes)
    length(raw) < total_bytes && throw(ArgumentError("Truncated TIFF field (tag data past end of file)"))

    @inbounds for i in 1:count
        out[i] = Int(load_uint(raw, (i - 1) * type_size + 1, type_size, little))
    end

    return out
end

"""
    read_info(io::IO, label) -> TiffInfo

Parse the header and first IFD of an open TIFF, leaving `io`'s position
undefined (every later read seeks absolutely, so this never matters).

`label` is only used to name the file in error messages.

Only the first IFD is read. The acquisition writes one image per file, and
for an imported reference image the first page is the one the user means.
"""
function read_info(io::IO, label::AbstractString="<tiff>")
    seekstart(io)

    byte_order = read(io, 2)
    little = if byte_order == b"II"
        true
    elseif byte_order == b"MM"
        false
    else
        throw(ArgumentError("Not a TIFF file (bad byte-order mark): $label"))
    end

    magic = read_scalar(io, UInt16, little)
    is_big = if magic == MAGIC_BIG
        true
    elseif magic == MAGIC_CLASSIC
        false
    else
        throw(ArgumentError("Not a TIFF file (magic $magic, expected 42 or 43): $label"))
    end

    ifd_offset = if is_big
        # BigTIFF's header carries an offset size and a reserved word before
        # the IFD pointer; only offset size 8 is defined by the spec.
        offset_size = read_scalar(io, UInt16, little)
        offset_size == 8 || throw(ArgumentError("Unsupported BigTIFF offset size $offset_size: $label"))
        read_scalar(io, UInt16, little)  # reserved, must be 0
        Int(read_scalar(io, UInt64, little))
    else
        Int(read_scalar(io, UInt32, little))
    end

    seek(io, ifd_offset)
    entry_count = is_big ? Int(read_scalar(io, UInt64, little)) : Int(read_scalar(io, UInt16, little))
    entry_size = is_big ? 20 : 12

    # Slurp the entry table in one read: resolving an out-of-line value seeks
    # away from the IFD, so parsing entries lazily would mean seeking back
    # and forth once per tag.
    entries = read(io, entry_count * entry_size)
    length(entries) < entry_count * entry_size &&
        throw(ArgumentError("Truncated TIFF IFD: $label"))

    # Scanned into locals rather than collected into a Dict: only seven tags
    # matter and a Dict would allocate a bucket array plus a boxed vector per
    # entry, once per frame. -1 marks "not present" so the spec defaults
    # below can be applied only where the spec actually allows an absent tag.
    width = -1
    height = -1
    bits_per_sample = -1
    samples_per_pixel = -1
    compression = -1
    sample_format = -1
    strip_offsets = Int[]
    strip_byte_counts = Int[]
    scratch = Int[]

    for i in 1:entry_count
        base = (i - 1) * entry_size
        tag = Int(load_uint(entries, base + 1, 2, little))

        # Skipped before any offset chasing: large fields this reader has no
        # use for (ImageDescription, resolution rationals) would otherwise
        # cost a seek and a read each.
        if !(tag in (TAG_IMAGE_WIDTH, TAG_IMAGE_LENGTH, TAG_BITS_PER_SAMPLE,
                     TAG_COMPRESSION, TAG_STRIP_OFFSETS, TAG_SAMPLES_PER_PIXEL,
                     TAG_STRIP_BYTE_COUNTS, TAG_SAMPLE_FORMAT))
            continue
        end

        field_type = UInt16(load_uint(entries, base + 3, 2, little))
        count = Int(load_uint(entries, base + 5, is_big ? 8 : 4, little))

        if tag == TAG_STRIP_OFFSETS
            ifd_values!(strip_offsets, io, entries, base, little, is_big, field_type, count)
        elseif tag == TAG_STRIP_BYTE_COUNTS
            ifd_values!(strip_byte_counts, io, entries, base, little, is_big, field_type, count)
        else
            ifd_values!(scratch, io, entries, base, little, is_big, field_type, count)
            isempty(scratch) && continue
            value = scratch[1]
            if tag == TAG_IMAGE_WIDTH
                width = value
            elseif tag == TAG_IMAGE_LENGTH
                height = value
            elseif tag == TAG_BITS_PER_SAMPLE
                bits_per_sample = value
            elseif tag == TAG_SAMPLES_PER_PIXEL
                samples_per_pixel = value
            elseif tag == TAG_COMPRESSION
                compression = value
            elseif tag == TAG_SAMPLE_FORMAT
                sample_format = value
            end
        end
    end

    width  >= 0 || throw(ArgumentError("TIFF missing required tag ImageWidth: $label"))
    height >= 0 || throw(ArgumentError("TIFF missing required tag ImageLength: $label"))

    # Defaults per the TIFF spec for the tags that are allowed to be absent.
    samples_per_pixel < 0 && (samples_per_pixel = 1)
    bits_per_sample   < 0 && (bits_per_sample = 1)
    compression       < 0 && (compression = COMPRESSION_NONE)
    # The spec's default for an absent SampleFormat is unsigned integer, which
    # is also what every 8- and 16-bit file this app has seen omits it as.
    sample_format     < 0 && (sample_format = SAMPLE_FORMAT_UINT)

    compression == COMPRESSION_NONE ||
        throw(ArgumentError("Compressed TIFF (compression=$compression) is not supported: $label"))
    samples_per_pixel == 1 ||
        throw(ArgumentError("Multi-sample TIFF (samples/pixel=$samples_per_pixel) is not supported: $label"))
    bits_per_sample in (8, 16, 32) ||
        throw(ArgumentError("Unsupported TIFF bit depth $bits_per_sample (expected 8, 16 or 32): $label"))
    if bits_per_sample == 32
        sample_format in (SAMPLE_FORMAT_UINT, SAMPLE_FORMAT_IEEE) ||
            throw(ArgumentError("Unsupported 32-bit TIFF sample format $sample_format (expected 1 = unsigned or 3 = IEEE float): $label"))
    elseif sample_format != SAMPLE_FORMAT_UINT
        throw(ArgumentError("Unsupported $(bits_per_sample)-bit TIFF sample format $sample_format (expected 1 = unsigned): $label"))
    end

    isempty(strip_offsets) &&
        throw(ArgumentError("TIFF missing required tag StripOffsets: $label"))
    isempty(strip_byte_counts) &&
        throw(ArgumentError("TIFF missing required tag StripByteCounts: $label"))

    length(strip_offsets) == length(strip_byte_counts) ||
        throw(ArgumentError("TIFF strip table mismatch ($(length(strip_offsets)) offsets vs $(length(strip_byte_counts)) counts): $label"))

    expected_bytes = width * height * (bits_per_sample ÷ 8)
    actual_bytes = sum(strip_byte_counts)
    actual_bytes == expected_bytes ||
        throw(ArgumentError("TIFF strip bytes ($actual_bytes) do not match $(width)x$(height)x$(bits_per_sample)-bit geometry ($expected_bytes): $label"))

    return TiffInfo(width, height, bits_per_sample, sample_format, little, strip_offsets, strip_byte_counts)
end

read_info(path::AbstractString) = open(io -> read_info(io, path), path, "r")

"""
    read_pixels!(dest, io, info)

Copy `info`'s pixel data into `dest`, which must already be the right length
and element type. Returns `dest`.

`unsafe_read` rather than `read!(io, view(dest, range))`: the strips write
into consecutive slices of one buffer, and taking a view per strip would
allocate a `SubArray` per strip on a path that runs once per frame. The
pointer arithmetic is bounded by the length check above it and the buffer is
kept alive across the read by `GC.@preserve`.
"""
function read_pixels!(dest::AbstractVector{T}, io::IO, info::TiffInfo) where {T<:Real}
    sizeof(T) * 8 == info.bits_per_sample ||
        throw(ArgumentError("Buffer element type $T does not match TIFF bit depth $(info.bits_per_sample)"))
    T === sample_type(info) ||
        throw(ArgumentError("Buffer element type $T does not match the TIFF's sample format (expected $(sample_type(info)))"))
    length(dest) == pixel_count(info) ||
        throw(ArgumentError("Buffer length $(length(dest)) does not match image size $(info.width)x$(info.height)"))

    GC.@preserve dest begin
        base = Base.unsafe_convert(Ptr{T}, dest)
        byte_pos = 0
        for (offset, nbytes) in zip(info.strip_offsets, info.strip_byte_counts)
            seek(io, offset)
            unsafe_read(io, Ptr{UInt8}(base) + byte_pos, nbytes)
            byte_pos += nbytes
        end
    end

    # Multi-byte samples written on a machine of the opposite endianness need a
    # swap; 8-bit data never does. The acquisition and this app are both
    # little-endian in practice, so this is normally skipped entirely.
    #
    # Floats go through their integer bit pattern: `bswap` is defined on
    # integers, and byte-reversing a float any other way would round-trip
    # through arithmetic and corrupt NaNs and denormals.
    if sizeof(T) > 1 && info.little_endian != HOST_IS_LITTLE_ENDIAN
        byteswap_samples!(dest)
    end

    return dest
end

byteswap_samples!(dest::AbstractVector{<:Integer}) = (@inbounds for i in eachindex(dest); dest[i] = bswap(dest[i]); end; dest)

function byteswap_samples!(dest::AbstractVector{Float32})
    raw = reinterpret(UInt32, dest)
    @inbounds for i in eachindex(raw)
        raw[i] = bswap(raw[i])
    end
    return dest
end

"""
    read_frame!(dest, path) -> TiffInfo

Read `path`'s pixels into the preallocated `dest`, returning the geometry
that was parsed on the way.

This is the acquisition hot path: one `open`, one IFD parse, one bulk read,
zero allocation of pixel storage. The IFD is re-parsed per frame rather than
cached from the first file of the run — it costs a few hundred bytes of
reading next to a megabyte of pixels, and it means a file that unexpectedly
changes geometry mid-acquisition raises an error here instead of being read
into a wrongly-sized buffer.
"""
function read_frame!(dest::AbstractVector{T}, path::AbstractString) where {T<:Real}
    return open(path, "r") do io
        info = read_info(io, path)
        read_pixels!(dest, io, info)
        return info
    end
end

"""
    read_frame(path) -> (pixels::Matrix, info::TiffInfo)

Allocating convenience wrapper: read `path` into a fresh matrix indexed
`[x, y]` with `x` the column (fast axis) and `y` the row.

TIFF stores rows consecutively, so a `reshape` to `(width, height)` — Julia
being column-major — lands element `(x, y)` exactly where the file put it,
with no transpose or copy. That indexing convention matches
`RoiCoordinates`'s `xs`/`ys` (data_types.jl), so ROI masks apply directly.

Used for one-off reads (the ROI popup's reference image, tests); the
acquisition loop uses `read_frame!` instead to avoid the per-frame
allocation.
"""
function read_frame(path::AbstractString)
    info = read_info(path)
    T = sample_type(info)
    buffer = Vector{T}(undef, pixel_count(info))
    open(path, "r") do io
        read_pixels!(buffer, io, info)
    end
    return reshape(buffer, info.width, info.height), info
end

end # module
