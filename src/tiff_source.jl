"""
tiff_source.jl

Locating the Bliq VMS acquisition folder, grouping its per-channel TIFF files
into frame instances, and feeding those instances to the acquisition loop.

This is the layer that replaces "list the `.sdt` files in the data folder":
where a FLIM frame was one self-contained file holding every TCSPC channel, a
ratiometric frame is a *group* of files — one per channel, in sibling
directories — that has to be reassembled before anything can be computed.

# Folder layout

    <selected folder>/
      <session folder, created when acquisition starts>/
        Bliq VMS/
          C1/  Name-C1-T001.tif
          C2/  Name-C2-T002.tif
          C3/  (optional)

The channel count is read from how many `C<n>` directories exist, so it is
known before a single pixel is read — unlike the SDT pipeline, which had to
inspect the first file to learn whether channel 2 existed.

# Two numbering conventions, detected rather than assumed

The acquisition software writes `T###` counters in one of two ways, and a
survey of 151 real sessions on this machine found both:

- **Global** (148 sessions) — one counter shared across channels, incremented
  once per file *written*. For `N` channels, instance `k` occupies the range
  `[N(k-1)+1, Nk]`, so a file's instance is `cld(T, N)`. Channels have
  disjoint, interleaved counter values (C1 = {1,3,5...}, C2 = {2,4,6...}).
- **Per-channel** (3 sessions) — each channel counts independently from 1, so
  every channel holds the *same* set of values and instance `k` is simply
  `T = k`.

Applying the wrong one is catastrophic and silent: reading a per-channel
session under the global rule groups three consecutive frames of C1 together
and pairs them with nothing, while reading a global session under the
per-channel rule pairs frames from different timepoints. Neither produces an
error — both produce plausible ratios of unrelated images.

`detect_numbering` distinguishes them from the data: under global numbering
no counter value can appear in two channels (one file, one number), whereas
per-channel numbering makes them coincide by construction. One instance's
worth of files is enough to decide, and the two conventions are equivalent
for a single-channel acquisition.

# Why the counter, not "the k-th file of each folder"

Under either convention the instance is derived from the counter rather than
from a file's position in its directory listing. Pairing the k-th file of
each directory would agree only while nothing is ever missing: the moment one
channel drops a file, that channel's positions shift by one relative to the
others and *every later instance is silently mispaired*. Deriving the
instance from the number leaves a hole at the lost file and keeps every other
group correctly aligned.

Confirmed against real acquisitions: the global rule reproduces the observed
interleavings, including irregular ones such as C1 = {1, 4, 6} with
C2 = {2, 3, 5} grouping as (1,2), (4,3), (6,5).

# Channel names are not positions

Channel directories are *not* guaranteed to be `C1..CN`: 33 of the surveyed
sessions hold `C1` and `C3` with no `C2` at all. So a channel's name and its
position in `channel_dirs` are different things, and the ratio combination
the user picks (`"C1/C3"`) has to be resolved through `channel_numbers`
rather than used as an index — see `channel_position`.
"""

# Directory holding one acquisition's channel subdirectories. Matched
# case-insensitively because the name comes from the acquisition software
# rather than from this app.
const BLIQ_DIR_NAME = "bliq vms"

# `Name-C2-T005.tif` -> channel 2, sequence 5. Anchored at the end of the
# name so an arbitrary prefix (which contains its own digits and hyphens,
# e.g. "60 Hz x 600 images-001") cannot be mistaken for either number.
const TIFF_NAME_REGEX = r"-C(\d+)-T(\d+)\.tiff?$"i

# Channel directory names: exactly "C" followed by digits.
const CHANNEL_DIR_REGEX = r"^C(\d+)$"i

"""
    ChannelLayout

One acquisition's resolved folder structure: the `Bliq VMS` directory, its
channel subdirectories in channel order, their names, the channel *numbers*
those names encode, and which counter convention the acquisition uses.

`channel_count` is the `N` in the `cld(T, N)` grouping rule, so it must
reflect every channel the acquisition is *writing*, not just the ones the
selected ratio happens to use.

`channel_numbers` is what the directory names say (`["C1", "C3"]` gives
`[1, 3]`), kept separately because it does not have to match position — see
this file's header.

`numbering` is `:global` or `:per_channel`, decided by `detect_numbering`.
"""
struct ChannelLayout
    root::String
    channel_dirs::Vector{String}
    channel_names::Vector{String}
    channel_numbers::Vector{Int}
    numbering::Symbol
end

channel_count(layout::ChannelLayout) = length(layout.channel_dirs)

"""
    channel_position(layout, channel_number) -> Union{Int, Nothing}

Where channel `channel_number` sits in the per-channel vectors
(`FrameInstance.paths`, `RegionFrame.channel_means`), or `nothing` when the
acquisition does not write that channel.

The indirection matters because channel names skip: an acquisition writing
`C1` and `C3` has channel 3 at position 2, and indexing `channel_means[3]`
would read past the end and silently produce a `NaN` ratio for a run that has
perfectly good data.
"""
function channel_position(layout::ChannelLayout, channel_number::Integer)::Union{Int, Nothing}
    idx = findfirst(==(Int(channel_number)), layout.channel_numbers)
    return idx
end

"""
    FrameInstance

One timepoint's worth of files: one path per channel, in channel order.

`sequence_numbers` holds each file's own `T###` value, kept because it is
what `instance_index` was derived from and what makes a gap in the sequence
visible downstream. `file_time` is the newest modification time in the group
— when the acquisition finished writing the instance, not when this app got
around to reading it — matching what `source_file_time` provided for SDT and
what `RoiSlotTracker` needs to detect skipped ROI scans.
"""
struct FrameInstance
    instance_index::Int
    paths::Vector{String}
    sequence_numbers::Vector{Int}
    file_time::Float64
end

"""
    instance_index_for(sequence_number, channel_count, numbering)

The frame instance a file belongs to, from its `T###` counter value.

Under `:global` numbering `cld` (ceiling division) maps `1:N` to instance 1,
`N+1:2N` to instance 2 and so on. Under `:per_channel` each channel counts
from 1 independently, so the counter *is* the instance index. See this file's
header for how the two are told apart and why guessing is not an option.
"""
function instance_index_for(sequence_number::Integer, channel_count::Integer, numbering::Symbol)::Int
    numbering === :per_channel && return Int(sequence_number)
    return cld(Int(sequence_number), max(Int(channel_count), 1))
end

instance_index_for(sequence_number::Integer, layout::ChannelLayout) =
    instance_index_for(sequence_number, channel_count(layout), layout.numbering)

"""
    detect_numbering(channel_dirs) -> Symbol

Decide whether an acquisition numbers its files with one shared counter
(`:global`) or one counter per channel (`:per_channel`).

The discriminator is how many *distinct* counter values the run holds relative
to how many files it has. Under global numbering each written file consumes
the next value, so the channels partition the range and the two counts are
equal. Under per-channel numbering every channel counts from 1 over the same
range, so `N` channels share each value and there are only `total / N` distinct
ones. The decision splits the difference between those two expectations.

# Why a proportion and not "does any value collide"

The obvious test — any counter value appearing in two channels means
per-channel numbering — is what this used to do, and it is far too brittle. A
real 1764-file acquisition on this rig produced exactly two counter glitches:
the software skipped a value and then wrote the *next* one twice, once for each
of two channels. Two anomalous files out of 1764 flipped the classification,
which then mapped every file to its own instance and reported all 588 of them
as incomplete — the whole run unreadable because of two files.

Grouping itself absorbs such a glitch (`cld` still lands both files in the
right instance), so only the detection needed to stop treating a single
collision as proof.

A single-channel acquisition returns `:global`, where the two conventions
coincide (`cld(T, 1) == T`). An acquisition with no files yet also returns
`:global`; Realtime re-runs the detection once files start arriving, since at
START there is usually nothing on disk to judge from.
"""
function detect_numbering(channel_dirs::AbstractVector{<:AbstractString})::Symbol
    n_channels = length(channel_dirs)
    n_channels <= 1 && return :global

    total = 0
    distinct = Set{Int}()

    for dir in channel_dirs
        for (seq, _) in list_channel_files(dir)
            total += 1
            push!(distinct, seq)
        end
    end

    total == 0 && return :global

    # Expected ratio of distinct values to files: ~1 for global numbering,
    # ~1/N for per-channel. Anything below the midpoint is per-channel.
    ratio = length(distinct) / total
    threshold = (1.0 + 1.0 / n_channels) / 2

    if ratio >= threshold
        collisions = total - length(distinct)
        if collisions > 0
            @warn "Acquisition reused some counter values across channels; treating the run as globally numbered anyway" collisions=collisions files=total
        end
        return :global
    end

    return :per_channel
end

"""
    parse_tiff_sequence_number(path) -> Union{Int, Nothing}

The `T###` counter embedded in `path`'s filename, or `nothing` when the name
does not carry one (a stray file in the channel directory, say).
"""
function parse_tiff_sequence_number(path::AbstractString)::Union{Int, Nothing}
    m = match(TIFF_NAME_REGEX, basename(path))
    return m === nothing ? nothing : parse(Int, m.captures[2])
end

"""
    parse_tiff_channel_number(path) -> Union{Int, Nothing}

The `C#` channel index embedded in `path`'s filename, used to cross-check
that a file actually sits in the channel directory its name claims.
"""
function parse_tiff_channel_number(path::AbstractString)::Union{Int, Nothing}
    m = match(TIFF_NAME_REGEX, basename(path))
    return m === nothing ? nothing : parse(Int, m.captures[1])
end

"""
    find_bliq_root(path) -> Union{String, Nothing}

Resolve `path` to the `Bliq VMS` directory holding the channel folders,
accepting either of the two things the user might reasonably select:

- `path` **is** the `Bliq VMS` directory, or
- `path` **contains** one (the session folder, which is what the acquisition
  software actually creates).

As a last resort it looks one level deeper, so selecting the folder *above* a
session still resolves — that is the shape of the parent folder the Realtime
watcher monitors, and being able to point Playback at the same folder avoids
making the two modes need different selections.

Returns `nothing` when no `Bliq VMS` directory is reachable, leaving the
caller to report it — a missing folder is a normal "you picked the wrong
place" condition, not an exceptional one.
"""
function find_bliq_root(path::AbstractString)::Union{String, Nothing}
    isdir(path) || return nothing

    lowercase(basename(rstrip(path, ['/', '\\']))) == BLIQ_DIR_NAME && return String(path)

    entries = try
        sort(readdir(path; join=true))
    catch
        return nothing
    end

    for entry in entries
        isdir(entry) || continue
        lowercase(basename(entry)) == BLIQ_DIR_NAME && return entry
    end

    # One more level down: `path` is the folder holding session directories.
    # Newest first, so pointing Playback at the parent replays the most recent
    # acquisition rather than the alphabetically first one.
    sessions = filter(isdir, entries)
    sort!(sessions; by=session_mtime, rev=true)
    for session in sessions
        for entry in (try sort(readdir(session; join=true)) catch; String[] end)
            isdir(entry) || continue
            lowercase(basename(entry)) == BLIQ_DIR_NAME && return entry
        end
    end

    return nothing
end

# Modification time of a directory, with a sentinel that sorts last so an
# unreadable entry never wins a "most recent" comparison.
function session_mtime(path::AbstractString)::Float64
    return try
        stat(path).mtime
    catch
        -Inf
    end
end

"""
    resolve_channel_layout(path) -> Union{ChannelLayout, Nothing}

Full resolution from a user-selected folder to a usable `ChannelLayout`:
find the `Bliq VMS` root, then collect its `C<n>` subdirectories in channel
order.

Returns `nothing` if either step fails, including when the root exists but
holds no channel directories at all (an acquisition that has created the
folder but not yet started writing).
"""
function resolve_channel_layout(path::AbstractString)::Union{ChannelLayout, Nothing}
    root = find_bliq_root(path)
    root === nothing && return nothing

    entries = try
        readdir(root; join=true)
    catch
        return nothing
    end

    numbered = Tuple{Int, String}[]
    for entry in entries
        isdir(entry) || continue
        m = match(CHANNEL_DIR_REGEX, basename(entry))
        m === nothing && continue
        push!(numbered, (parse(Int, m.captures[1]), entry))
    end

    isempty(numbered) && return nothing
    sort!(numbered; by=first)

    dirs = [d for (_, d) in numbered]
    numbering = detect_numbering(dirs)

    if numbering === :per_channel
        @info "Acquisition numbers files per channel (each channel counts from 1)" root=root channels=[basename(d) for d in dirs]
    end

    return ChannelLayout(root, dirs, [basename(d) for d in dirs], [n for (n, _) in numbered], numbering)
end

"""
    list_channel_files(dir) -> Vector{Tuple{Int, String}}

Every parseable TIFF in one channel directory as `(sequence_number, path)`,
sorted by sequence number. Files whose names carry no `T###` counter are
skipped rather than guessed at.
"""
function list_channel_files(dir::AbstractString)::Vector{Tuple{Int, String}}
    out = Tuple{Int, String}[]

    entries = try
        readdir(dir; join=true)
    catch
        return out
    end

    for entry in entries
        endswith(lowercase(entry), ".tif") || endswith(lowercase(entry), ".tiff") || continue
        seq = parse_tiff_sequence_number(entry)
        seq === nothing && continue
        push!(out, (seq, entry))
    end

    sort!(out; by=first)
    return out
end

"""
    group_instances(layout) -> Vector{FrameInstance}

Every *complete* instance currently on disk, in acquisition order.

Files are bucketed by `instance_index_for` and an instance is emitted only
once every channel has contributed a file to it. Incomplete buckets — a
channel that dropped a file, or the instance still being written when the
directory was listed — are skipped and logged rather than emitted with a
hole, since a ratio needs both of its channels by definition.

Used by Playback and Save, which see a static, finished directory. Realtime
uses `InstanceCollector` below instead, which has to make the same decision
without knowing whether a missing file is lost or merely late.
"""
function group_instances(layout::ChannelLayout)::Vector{FrameInstance}
    n_channels = channel_count(layout)
    buckets = Dict{Int, Vector{Union{Nothing, Tuple{Int, String}}}}()

    for (ch_idx, dir) in enumerate(layout.channel_dirs)
        for (seq, path) in list_channel_files(dir)
            k = instance_index_for(seq, layout)
            slot = get!(buckets, k) do
                Vector{Union{Nothing, Tuple{Int, String}}}(nothing, n_channels)
            end

            if slot[ch_idx] !== nothing
                @warn "Two files map to the same channel and instance; keeping the first" instance=k channel=layout.channel_names[ch_idx] kept=slot[ch_idx][2] dropped=path
                continue
            end

            slot[ch_idx] = (seq, path)
        end
    end

    instances = FrameInstance[]
    incomplete = 0

    for k in sort!(collect(keys(buckets)))
        slot = buckets[k]
        if any(isnothing, slot)
            incomplete += 1
            missing_names = [layout.channel_names[i] for i in 1:n_channels if slot[i] === nothing]
            @debug "Skipping incomplete instance" instance=k missing=missing_names
            continue
        end

        paths = [slot[i][2] for i in 1:n_channels]
        seqs  = [slot[i][1] for i in 1:n_channels]
        push!(instances, FrameInstance(k, paths, seqs, newest_mtime(paths)))
    end

    if incomplete > 0
        @warn "Skipped incomplete instances (a channel is missing its file)" count=incomplete total=length(buckets)
    end

    return instances
end

"""
    newest_mtime(paths) -> Float64

The most recent modification time across `paths` (unix seconds), or `NaN`
when none of them can be stat'ed. This is when the *group* finished being
written, which is the meaningful timestamp for an instance assembled from
several files.
"""
function newest_mtime(paths::AbstractVector{<:AbstractString})::Float64
    newest = NaN
    for path in paths
        t = try
            stat(path).mtime
        catch
            continue
        end
        if isnan(newest) || t > newest
            newest = t
        end
    end
    return newest
end

# =============================================================================
# REALTIME INSTANCE COLLECTION
# =============================================================================

"""
    INSTANCE_TIMEOUT_PERIODS

How many observed inter-instance periods to wait for a straggling channel
before declaring its file lost and moving on.

Derived from the observed cadence rather than fixed in seconds because this
app has run against acquisitions from ~20 ms to ~118 s per frame — any
constant would either abandon instances that were merely slow, or stall the
live plots for minutes on a genuinely lost file.
"""
const INSTANCE_TIMEOUT_PERIODS = 3.0

"""
    INSTANCE_TIMEOUT_WARMUP

Instances to observe before the timeout is trusted. Until this many periods
have been measured, a partial instance is held indefinitely: with no cadence
estimate yet, "late" and "lost" are indistinguishable, and wrongly skipping
the first instances of a run would corrupt the ROI round-robin alignment for
everything that follows.
"""
const INSTANCE_TIMEOUT_WARMUP = 3

"""
    INSTANCE_TIMEOUT_FLOOR_S

Lower bound on the derived timeout. A very fast acquisition would otherwise
produce a timeout of a few milliseconds — shorter than the gap between two
files of the *same* instance being written — and skip instances that were
about to complete.
"""
const INSTANCE_TIMEOUT_FLOOR_S = 0.25

"""
    InstanceCollector

Realtime counterpart to `group_instances`: accumulates per-channel files as
they appear on disk and releases instances once they are complete.

The hard part is deciding when a partial instance is *lost* rather than
merely late, with no way to tell the two apart from the filesystem. The
policy, matching the SDT pipeline's own gap handling in spirit:

- an instance is released the moment all of its channels have arrived;
- instances are released strictly in order, so the ROI round-robin
  downstream keeps its alignment;
- a partial instance older than `INSTANCE_TIMEOUT_PERIODS` times the observed
  inter-instance period is abandoned, letting later complete instances
  through instead of blocking the run forever;
- no instance is abandoned until `INSTANCE_TIMEOUT_WARMUP` periods have
  actually been measured.

`period_s` starts from the caller's nominal estimate (the ROI scan period
when a protocol drives the galvo, otherwise `NaN`) and is refined by the
median of observed gaps, so it tracks what the acquisition really does rather
than what it was configured to do.
"""
mutable struct InstanceCollector
    layout::ChannelLayout
    pending::Dict{Int, Vector{Union{Nothing, Tuple{Int, String}}}}
    first_seen_s::Dict{Int, Float64}
    seen_paths::Set{String}
    next_index::Int
    released_at_s::Vector{Float64}
    period_s::Float64
    skipped_total::Int
end

function InstanceCollector(layout::ChannelLayout; nominal_period_s::Float64=NaN)
    return InstanceCollector(
        layout,
        Dict{Int, Vector{Union{Nothing, Tuple{Int, String}}}}(),
        Dict{Int, Float64}(),
        Set{String}(),
        1,
        Float64[],
        nominal_period_s,
        0
    )
end

"""
    scan_new_files!(collector, now_s) -> Int

List the channel directories and fold any file not seen before into the
pending instance buckets. Returns how many new files were absorbed.

`now_s` timestamps first sight of each instance, which is what the timeout in
`take_ready_instances!` measures against — deliberately *this app's* clock
rather than the file's mtime, because the question being asked is "how long
have I been waiting", not "when was this written".
"""
function scan_new_files!(collector::InstanceCollector, now_s::Float64=time())::Int
    n_channels = channel_count(collector.layout)
    added = 0

    for (ch_idx, dir) in enumerate(collector.layout.channel_dirs)
        for (seq, path) in list_channel_files(dir)
            path in collector.seen_paths && continue
            push!(collector.seen_paths, path)

            k = instance_index_for(seq, collector.layout)

            # A file for an instance already released (or abandoned) cannot be
            # used: its group has moved on. Counting it as skipped keeps the
            # run's own accounting honest.
            if k < collector.next_index
                collector.skipped_total += 1
                @debug "Ignoring late file for an already-released instance" instance=k path=path
                continue
            end

            slot = get!(collector.pending, k) do
                collector.first_seen_s[k] = now_s
                Vector{Union{Nothing, Tuple{Int, String}}}(nothing, n_channels)
            end

            if slot[ch_idx] === nothing
                slot[ch_idx] = (seq, path)
                added += 1
            else
                @warn "Two files map to the same channel and instance; keeping the first" instance=k channel=collector.layout.channel_names[ch_idx] kept=slot[ch_idx][2] dropped=path
            end
        end
    end

    return added
end

"""
    take_ready_instances!(collector, now_s) -> Vector{FrameInstance}

Release every instance that is ready, in order, applying the abandonment
policy described on `InstanceCollector` to whatever sits at the head of the
queue.

Returns the released instances, oldest first — usually zero or one, but more
when the reader has fallen behind the acquisition.
"""
function take_ready_instances!(collector::InstanceCollector, now_s::Float64=time())::Vector{FrameInstance}
    n_channels = channel_count(collector.layout)
    ready = FrameInstance[]

    while true
        k = collector.next_index
        slot = get(collector.pending, k, nothing)

        if slot === nothing
            # Nothing pending at the head. Only skip past it if a *later*
            # instance has already arrived and the head is overdue — otherwise
            # the head is simply the next thing to be written.
            if !isempty(collector.pending) && any(>(k), keys(collector.pending)) && head_is_overdue(collector, k, now_s)
                collector.next_index += 1
                collector.skipped_total += 1
                @warn "No file ever arrived for instance; skipping" instance=k
                continue
            end
            break
        end

        if all(!isnothing, slot)
            paths = [slot[i][2] for i in 1:n_channels]
            seqs  = [slot[i][1] for i in 1:n_channels]
            push!(ready, FrameInstance(k, paths, seqs, newest_mtime(paths)))

            note_release!(collector, now_s)
            delete!(collector.pending, k)
            delete!(collector.first_seen_s, k)
            collector.next_index += 1
            continue
        end

        if head_is_overdue(collector, k, now_s)
            missing_names = [collector.layout.channel_names[i] for i in 1:n_channels if slot[i] === nothing]
            @warn "Instance timed out waiting for a channel; skipping" instance=k missing=missing_names waited_s=round(now_s - get(collector.first_seen_s, k, now_s), digits=3)
            delete!(collector.pending, k)
            delete!(collector.first_seen_s, k)
            collector.next_index += 1
            collector.skipped_total += 1
            continue
        end

        break
    end

    return ready
end

# Whether the instance at the head of the queue has waited longer than the
# derived timeout. Always false until enough periods have been observed to
# make the timeout meaningful — see INSTANCE_TIMEOUT_WARMUP.
function head_is_overdue(collector::InstanceCollector, k::Int, now_s::Float64)::Bool
    length(collector.released_at_s) < INSTANCE_TIMEOUT_WARMUP && return false

    period = collector.period_s
    (isfinite(period) && period > 0) || return false

    timeout = max(INSTANCE_TIMEOUT_PERIODS * period, INSTANCE_TIMEOUT_FLOOR_S)
    first_seen = get(collector.first_seen_s, k, now_s)
    return (now_s - first_seen) > timeout
end

# Record a release time and refresh the period estimate from the median of
# recent inter-release gaps. The median, not the mean: one stalled instance
# would drag a mean upward and inflate every later timeout.
function note_release!(collector::InstanceCollector, now_s::Float64)
    push!(collector.released_at_s, now_s)

    if length(collector.released_at_s) > 25
        popfirst!(collector.released_at_s)
    end

    n = length(collector.released_at_s)
    n >= 2 || return nothing

    gaps = Vector{Float64}(undef, n - 1)
    for i in 2:n
        gaps[i-1] = collector.released_at_s[i] - collector.released_at_s[i-1]
    end

    filter!(g -> isfinite(g) && g > 0, gaps)
    isempty(gaps) && return nothing

    sort!(gaps)
    mid = length(gaps) ÷ 2
    collector.period_s = isodd(length(gaps)) ? gaps[mid+1] : (gaps[mid] + gaps[mid+1]) / 2

    return nothing
end

"""
    wait_for_session_layout(parent_path, running; poll_interval_s, known_before)

Block until a usable `ChannelLayout` appears under `parent_path`, returning it
— or `nothing` if `running[]` goes false first.

This is Realtime's entry condition: at START the session folder generally does
not exist yet, because the acquisition software creates it when *it* starts.
Polling for it here, rather than failing fast the way Playback does, is what
lets the user arm this app before triggering the acquisition.

`known_before` is the set of session directories that already existed at
START. A directory in that set is not treated as new, so an old session
sitting in the parent folder is never picked up instead of the one about to
be created. When the selected folder already *is* (or directly contains) a
`Bliq VMS` directory, that resolves immediately and the watch never engages.
"""
function wait_for_session_layout(parent_path::AbstractString,
                                 running::Threads.Atomic{Bool};
                                 poll_interval_s::Float64=0.25,
                                 known_before::Set{String}=Set{String}())
    # Direct hit: the user selected the session (or the Bliq VMS folder
    # itself), so there is nothing to wait for.
    direct = resolve_channel_layout(parent_path)
    if direct !== nothing && !(direct.root in known_before)
        return direct
    end

    @info "Waiting for a new acquisition session to appear" folder=parent_path

    while running[]
        entries = try
            filter(isdir, readdir(parent_path; join=true))
        catch
            String[]
        end

        # Newest first: if several sessions appear between two polls, the one
        # the user just triggered is the most recent.
        sort!(entries; by=session_mtime, rev=true)

        for entry in entries
            entry in known_before && continue

            layout = resolve_channel_layout(entry)
            layout === nothing && continue

            @info "New acquisition session detected" session=entry channels=layout.channel_names
            return layout
        end

        sleep(poll_interval_s)
    end

    return nothing
end

"""
    existing_session_dirs(parent_path) -> Set{String}

Snapshot of the session directories present under `parent_path` right now,
passed to `wait_for_session_layout` as its `known_before` set.
"""
function existing_session_dirs(parent_path::AbstractString)::Set{String}
    entries = try
        filter(isdir, readdir(parent_path; join=true))
    catch
        String[]
    end
    return Set{String}(entries)
end
