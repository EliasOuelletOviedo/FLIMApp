"""
gui/spc_view.jl

The GUI side of the SPC engine (FLIMCore, src/spc/) — main thread
only. The GUI never calls the SPC DLL: buttons send commands
(`FLIMCore.commander!`), and the refresh tick (`spc_tick!`, called from
gui/refresh.jl) drains `engine.resultats` without ever waiting:

- each `ImageTrame` is added to its card's display accumulator and its
  buffer handed straight back to the engine (`FLIMCore.rendre!`);
- every `trames_par_image` frames the accumulator becomes the image to show
  (0: everything since the start of the acquisition);
- images, decays and rate curves are recomputed at most 10 times a second,
  and only while the SPC window is open (31.25 frames/s come in per card,
  10 images/s are shown);
- alerts go to the journal as well as to the window.

The settings the SPC window edits are config/spc.toml (next to the bench
config), which the engine rereads at every measurement start.
"""

using GLMakie: Point2f
using Printf

"""Images, decays and rate curves are refreshed at most this often."""
const SPC_DISPLAY_PERIOD_S = 0.1

"""Rate history kept per card for the rates plot (at 0.5 s per reading)."""
const SPC_RATE_HISTORY = 240

"""Alerts kept for the SPC window."""
const SPC_ALERT_HISTORY = 30

const SPC_ENGINE_STATE_NAMES = Dict(
    :demarrage => "starting…", :pret => "ready", :imagerie => "imaging",
    :single => "Single", :clamp => "Realtime", :arrete => "stopped"
)

"""Frames summed into the ROI popup's image ("Image" button, gui/roi_popup.jl)."""
const ROI_IMAGE_FRAMES = 100

"""
    SpcCard

One card's display state: the frames being summed (`acc_*`), the last
complete sum waiting to be shown (`shown_*`, swapped with the accumulator),
and the Observables the SPC window plots.
"""
mutable struct SpcCard
    card::Int
    acc_intensity::Matrix{UInt32}
    acc_time::Matrix{Float64}
    acc_decay::Vector{Int}
    acc_frames::Int
    shown_intensity::Matrix{UInt32}
    shown_time::Matrix{Float64}
    shown_decay::Vector{Int}
    shown_frames::Int
    pending::Bool
    last_publish_ns::UInt64
    image::Matrix{Float32}
    mean_image::Matrix{Float32}
    scratch::Vector{Float32}
    dt_ns::Float64
    generation::Int
    last_frame::Int
    rate_t::Vector{Float64}
    rate_cfd::Vector{Float64}
    last_rates::Union{Nothing, FLIMCore.Taux}
    rates_dirty::Bool
    intensity::Observable{Matrix{Float32}}
    intensity_range::Observable{Tuple{Float32, Float32}}
    mean_time::Observable{Matrix{Float32}}
    time_range::Observable{Tuple{Float32, Float32}}
    decay::Observable{Vector{Point2f}}
    single::Observable{Vector{Point2f}}
    rates::Observable{Vector{Point2f}}
    title::Observable{String}
end

function SpcCard(card::Integer)
    empty_image() = zeros(Float32, 2, 2)
    return SpcCard(Int(card),
                   zeros(UInt32, 0, 0), zeros(Float64, 0, 0), zeros(Int, 4096), 0,
                   zeros(UInt32, 0, 0), zeros(Float64, 0, 0), zeros(Int, 4096), 0, false,
                   UInt64(0), zeros(Float32, 0, 0), zeros(Float32, 0, 0), Float32[],
                   12.5 / 4096, -1, 0, Float64[], Float64[], nothing, false,
                   Observable(empty_image()), Observable((0.0f0, 1.0f0)),
                   Observable(fill(NaN32, 2, 2)), Observable((0.0f0, 1.0f0)),
                   Observable(Point2f[]), Observable(Point2f[]), Observable(Point2f[]),
                   Observable("Card $card"))
end

"""The SPC window's widgets that the refresh tick keeps current (see gui/spc_window.jl)."""
mutable struct SpcWindowWidgets
    connect_button::Any
    image_button::Any
    single_button::Any
    irf_button::Any
    unlock_button::Any
    axes::Any                  # SpcWindowAxes, gui/spc_window.jl
end

"""
    SpcView

Everything the GUI keeps about the SPC engine: the settings file, the
engine handle (`nothing` when not connected), the per-card display state,
the last verification and alerts, and the texts shown in the top bar and
the SPC window.
"""
mutable struct SpcView
    settings_path::String
    settings::FLIMCore.Reglages
    engine::Union{Nothing, FLIMCore.Moteur}
    stopping::Union{Nothing, Task}
    journal::Union{Nothing, JournalQueue}
    cards::Dict{Int, SpcCard}
    check::Union{Nothing, FLIMCore.EtatCartes}
    alerts::Vector{FLIMCore.Alerte}
    last_fin::Union{Nothing, FLIMCore.Fin}
    last_error::String
    last_error_t::Float64
    t0::Float64
    last_publish_ns::UInt64
    window_open::Bool
    widgets::Union{Nothing, SpcWindowWidgets}
    unlock_armed_until::Float64
    last_state::Symbol
    texts_dirty::Bool
    clamp_stop_sent::Bool
    roi_image_pending::Bool
    roi_image_parts::Dict{Int, FLIMCore.ImageSomme}
    roi_image::Observable{Any}
    banner::String
    problem::String
    clamp_status::Union{Nothing, FLIMCore.EtatClamp}
    status::Observable{String}
    check_text::Observable{String}
    alerts_text::Observable{String}
    info_text::Observable{String}
    irf_acquisition::Bool                  # the running Single is the IRF button's (`spc_toggle_irf!`)
    irf_fin::Union{Nothing, FLIMCore.Fin}  # its end, for the refresh tick to import (`finish_irf_acquisition!`)
    irf_sums::Dict{Int, Vector{Int}}       # per card, the sum of its Singles so far (shown dashed)
end

"""
    spc_settings_path(cfg::BenchConfig)::String

config/spc.toml next to the bench config file in use (the repository's
config/ when the bench config came from the built-in defaults).
"""
function spc_settings_path(cfg::BenchConfig)::String
    base = isfile(cfg.source) ? dirname(cfg.source) : dirname(default_bench_config_path())
    return joinpath(base, "spc.toml")
end

"""
    load_spc_settings(path)::FLIMCore.Reglages

Read the SPC settings file; defaults (with a warning) if it is missing or
invalid, so a typo never keeps the app from starting.
"""
function load_spc_settings(path::AbstractString)::FLIMCore.Reglages
    isfile(path) || report_problem!("ENV-04", "$path not found: SPC settings at their defaults")
    try
        return FLIMCore.lire_reglages(path)
    catch e
        report_problem!("ENV-04", "$path: " * sprint(showerror, e) * " — SPC settings at their defaults"; level = :error)
        return FLIMCore.Reglages(fichier = abspath(path))
    end
end

function SpcView(settings_path::AbstractString, journal::Union{Nothing, JournalQueue} = nothing)
    settings = load_spc_settings(settings_path)
    view = SpcView(String(settings_path), settings, nothing, nothing, journal, Dict{Int, SpcCard}(),
                   nothing, FLIMCore.Alerte[], nothing, "", 0.0, time(), UInt64(0), false, nothing, 0.0,
                   :none, true, false, false, Dict{Int, FLIMCore.ImageSomme}(), Observable{Any}(nothing), "", "", nothing,
                   Observable("SPC: not connected"), Observable(""), Observable(""), Observable(""),
                   false, nothing, Dict{Int, Vector{Int}}())
    for card in spc_displayed_cards(view)
        view.cards[card] = SpcCard(card)
    end
    return view
end

"""Cards the SPC window shows: every module the settings image or measure."""
spc_displayed_cards(view::SpcView) = sort!(unique(vcat(view.settings.modules_imagerie, view.settings.modules_single)))

spc_card!(view::SpcView, card::Integer) = get!(() -> SpcCard(card), view.cards, Int(card))

"""
    spc_applied_settings(view)::Dict{Int, Dict{String, Float64}}

Per channel ([verification] series), the settings read back from its card
at the last check ("demandé → appliqué"); empty before any check. What
`irf_mismatches` compares an IRF with.
"""
function spc_applied_settings(view::SpcView)::Dict{Int, Dict{String, Float64}}
    applied = Dict{Int, Dict{String, Float64}}()
    check = view.check
    check === nothing && return applied
    for c in check.cartes
        (c.pret && c.canal > 0) || continue
        applied[c.canal] = Dict{String, Float64}(l.cle => l.applique for l in c.tableau if isfinite(l.applique))
    end
    return applied
end

"""Engine state, `:none` when no engine is running."""
spc_state(view::SpcView)::Symbol = view.engine === nothing ? :none : FLIMCore.etat_moteur(view.engine)

# -----------------------------------------------------------------------------
# Commands (called from the SPC window's buttons; none of them waits)
# -----------------------------------------------------------------------------

"""
    spc_connect!(view)

Reread config/spc.toml and start the engine: it opens the source (SPC_init
for the cards) and checks the cards on its own thread; its first results
arrive through the refresh tick.
"""
function spc_connect!(view::SpcView)
    view.engine === nothing || return nothing
    if view.stopping !== nothing && !istaskdone(view.stopping)
        spc_error!(view, "previous engine still stopping")
        return nothing
    end
    view.settings = load_spc_settings(view.settings_path)
    for card in spc_displayed_cards(view)
        spc_card!(view, card)
    end
    view.check = nothing
    view.last_fin = nothing
    spc_error!(view, "")
    view.engine = FLIMCore.demarrer_moteur(view.settings)
    view.texts_dirty = true
    spc_journal!(view, :info, "SPC engine started ($(view.settings.source), $(view.settings_path))")
    return nothing
end

"""
    spc_disconnect!(view)

Stop the engine on a background task (it stops any measurement and frees
the cards); the refresh tick keeps draining its last results until it has
stopped.
"""
function spc_disconnect!(view::SpcView)
    engine = view.engine
    engine === nothing && return nothing
    view.stopping = errormonitor(Threads.@spawn FLIMCore.arreter_moteur(engine))
    return nothing
end

"""Send a command to the engine, if there is one; returns whether it was queued."""
function spc_command!(view::SpcView, command::FLIMCore.Commande)::Bool
    view.engine === nothing && return false
    return FLIMCore.commander!(view.engine, command)
end

"""
    spc_adopt_settings!(view, settings)

Make `settings` the current SPC settings (an imported IRF's,
`adopt_irf!`): written to config/spc.toml — the engine rereads it at every
measurement start — and, the engine idle, the card checked again so the
settings read back from it (`spc_applied_settings`) follow.
"""
function spc_adopt_settings!(view::SpcView, settings::FLIMCore.Reglages)
    FLIMCore.ecrire_reglages(view.settings_path, settings)
    view.settings = settings
    spc_state(view) == :pret && spc_command!(view, FLIMCore.Verifier())
    view.texts_dirty = true
    return nothing
end

"""
    spc_edit_offset!(view, channel, value_ns)::Bool

The timing offset (ns) of a channel's input on the QC-104 ([qc]
decalage_ns, IN1 … IN3 as [verification] series says; 0 to 32.256 ns, the
card rounds to 0.512 ns steps), written to config/spc.toml like any other
setting of the window. Shifts the decays in the window: an IRF taken with
another offset no longer matches (FIT-01).
"""
function spc_edit_offset!(view::SpcView, channel::Integer, value_ns::Real)::Bool
    s = view.settings
    voie = 1 <= channel <= length(s.series) ? FLIMCore.voie_qc(s.series[channel]) : nothing
    if !FLIMCore.est_qc104(s) || voie === nothing
        spc_error!(view, "setting refused: channel $channel has no QC-104 input ([verification] series)")
        return false
    end
    offsets = copy(s.qc_decalage_ns)
    offsets[voie.entree] = Float64(value_ns)
    return spc_edit_setting!(view, :qc_decalage_ns, offsets)
end

"""IMAGE / STOP: continuous (or `duree_s`) imaging with the settings' geometry, or stop it."""
function spc_toggle_imaging!(view::SpcView)
    state = spc_state(view)
    if state == :imagerie
        spc_command!(view, FLIMCore.Arret())
    elseif state == :pret
        s = view.settings
        for card in values(view.cards)
            empty!(card.single[])
            notify(card.single)
        end
        spc_command!(view, FLIMCore.Imagerie(FLIMCore.geometrie(s); duree = s.duree_s > 0 ? s.duree_s : Inf))
    end
    return nothing
end

"""
    spc_toggle_irf!(view)

IRF / STOP: acquire the IRF — Singles of `[single] irf_temps_s` (1 s) on
both channels at once, summed until the maximum of the sum passes
`irf_maximum` (2^15) on each channel, `irf_histogrammes_max` Singles at
most. The refresh tick then imports the sum as the IRF of both channels
(`finish_irf_acquisition!`). A second click stops it, the IRF unchanged.
"""
function spc_toggle_irf!(view::SpcView)
    state = spc_state(view)
    if state == :single && view.irf_acquisition
        spc_command!(view, FLIMCore.Arret())
    elseif state == :pret
        s = view.settings
        empty!(view.irf_sums)
        for card in values(view.cards)
            empty!(card.single[])
            notify(card.single)
        end
        view.irf_acquisition = spc_command!(view, FLIMCore.Single(s.irf_temps_s, s.irf_histogrammes_max; jusqu_a = s.irf_maximum))
        view.last_state = :none                # relabel the buttons on the next tick
    end
    return nothing
end

"""SINGLE / STOP: `n_histogrammes` histograms of `temps_collecte_s`, or stop them."""
function spc_toggle_single!(view::SpcView)
    state = spc_state(view)
    if state == :single
        spc_command!(view, FLIMCore.Arret())
    elseif state == :pret
        spc_command!(view, FLIMCore.Single(view.settings.temps_collecte_s, view.settings.n_histogrammes))
    end
    return nothing
end

"""
    spc_unlock_pressed!(view)

UNLOCK asks for confirmation (never a silent forced takeover): a first
click arms it for 5 s, a second click sends `Deverrouiller`.
"""
function spc_unlock_pressed!(view::SpcView)
    view.engine === nothing && return nothing
    if time() < view.unlock_armed_until
        view.unlock_armed_until = 0.0
        spc_command!(view, FLIMCore.Deverrouiller())
    else
        view.unlock_armed_until = time() + 5.0
    end
    view.last_state = :none              # relabel the buttons on the next tick
    return nothing
end

"""
    spc_edit_setting!(view, field, value)

Change one setting and rewrite config/spc.toml (a few kB; the engine reads
it at the next measurement start). An invalid value (`FLIMCore.valider_reglages`:
e.g. an image height other than 1024, 512, 256 or 128 lines) is refused and
the previous one kept.
"""
function spc_edit_setting!(view::SpcView, field::Symbol, value)::Bool
    s = view.settings
    previous = getfield(s, field)
    try
        setfield!(s, field, convert(fieldtype(FLIMCore.Reglages, field), value))
        FLIMCore.valider_reglages(s)
        FLIMCore.ecrire_reglages(view.settings_path, s)
        spc_error!(view, "")
        return true
    catch e
        setfield!(s, field, previous)
        spc_error!(view, "setting refused: " * sprint(showerror, e))
        return false
    end
end

"""Show `message` in the status line for 15 s (an empty message clears it)."""
function spc_error!(view::SpcView, message::AbstractString)
    view.last_error = String(message)
    view.last_error_t = time()
    view.texts_dirty = true
    return nothing
end

function spc_journal!(view::SpcView, level::Symbol, message::AbstractString)
    view.journal === nothing || journal_event!(view.journal, level, message)
    return nothing
end

"""
    spc_stop_clamp!(view)

Stop the engine's Realtime measurement (STOP, end of a run); sent once per
run, the refresh tick calling this on every tick until the run closes.
"""
function spc_stop_clamp!(view::SpcView)
    view.clamp_stop_sent && return nothing
    spc_state(view) == :clamp || return nothing
    view.clamp_stop_sent = spc_command!(view, FLIMCore.Arret())
    return nothing
end

"""
    spc_request_roi_image!(view; frames=ROI_IMAGE_FRAMES)::String

Ask the engine for an image of `frames` complete frames, keeping its raw
stream (for the ROI popup's per-ROI decays): the result arrives as one
`ImageSomme` per card, gathered until the measurement ends and then put in
`view.roi_image` (a `Dict` card => `ImageSomme`). Returns "" when sent,
otherwise why not (engine missing or busy).
"""
function spc_request_roi_image!(view::SpcView; frames::Integer = ROI_IMAGE_FRAMES)::String
    state = spc_state(view)
    state == :none && return "SPC engine not running: CONNECT it in the SPC window"
    state == :pret || return "SPC engine busy ($(SPC_ENGINE_STATE_NAMES[state]))"
    empty!(view.roi_image_parts)
    view.roi_image_pending = spc_command!(view, FLIMCore.Imagerie(FLIMCore.geometrie(view.settings);
                                                                    trames = frames, garder_mots = true))
    return view.roi_image_pending ? "" : "SPC engine not taking commands"
end

"""Stop the engine at shutdown (window closed); returns the stopping task, if any."""
function stop_spc!(view::SpcView)
    spc_disconnect!(view)
    return view.stopping
end

# -----------------------------------------------------------------------------
# Results -> display state (refresh tick)
# -----------------------------------------------------------------------------

"""
    spc_tick!(view, now_ns)

Drain the engine's results (at most 1000 per tick), then refresh the
Observables that changed — images at most every `SPC_DISPLAY_PERIOD_S`.
Once a stopped engine has nothing left to read, forget it.
"""
function spc_tick!(view::SpcView, now_ns::UInt64)
    engine = view.engine
    if engine !== nothing
        n = 0
        while n < 1000 && isready(engine.resultats)
            result = take!(engine.resultats)
            spc_handle_result!(view, result)
            FLIMCore.rendre!(engine, result)
            n += 1
        end
        if FLIMCore.etat_moteur(engine) == :arrete && !isready(engine.resultats)
            view.engine = nothing
            view.texts_dirty = true
            # stopped on its own (an error): arreter_moteur also takes it off the atexit list
            (view.stopping === nothing || istaskdone(view.stopping)) &&
                (view.stopping = errormonitor(Threads.@spawn FLIMCore.arreter_moteur(engine)))
        end
    end

    if view.window_open
        # At most one image per tick (each ~2 ms on a full frame), each card
        # at most every SPC_DISPLAY_PERIOD_S: the tick never does both cards' work at once.
        for card in values(view.cards)
            if card.pending && now_ns - card.last_publish_ns >= SPC_DISPLAY_PERIOD_S * 1e9
                card.last_publish_ns = now_ns
                spc_publish_image!(view, card)
                break
            end
        end
        if now_ns - view.last_publish_ns >= SPC_DISPLAY_PERIOD_S * 1e9
            view.last_publish_ns = now_ns
            for card in values(view.cards)
                card.rates_dirty && spc_publish_rates!(view, card)
            end
            spc_autoscale_window!(view)
        end
    end

    view.unlock_armed_until > 0 && time() > view.unlock_armed_until && (view.unlock_armed_until = 0.0; view.last_state = :none)
    state = spc_state(view)
    if state != view.last_state || view.texts_dirty
        view.last_state = state
        spc_update_texts!(view)
        spc_update_widgets!(view, state)
        view.texts_dirty = false
    end
    status = spc_status_text(view)
    view.status[] == status || (view.status[] = status)
    return nothing
end

function spc_handle_result!(view::SpcView, r::FLIMCore.ImageTrame)
    card = spc_card!(view, r.carte)
    spc_accumulate!(card, r, view.settings.trames_par_image)
    return nothing
end

"""
    spc_channel_rates(view; max_age_s=2.0) -> (channel1, channel2)

The latest count rate (CFD, /s) of each channel's card — the card the last
check put on that channel ([verification] series), card k on channel k + 1
before any check — for the counts bar. The engine sends them every 0.5 s,
measuring or not. 1.0 (the bar's bottom) for a channel without a rate
younger than `max_age_s` (engine stopped, card absent).
"""
function spc_channel_rates(view::SpcView; max_age_s::Real = 2.0)
    out = [1.0, 1.0]
    channel_of = Dict{Int, Int}()
    view.check === nothing || foreach(c -> c.canal > 0 && (channel_of[c.carte] = c.canal), view.check.cartes)
    for (k, card) in view.cards
        r = card.last_rates
        (r === nothing || !r.valide || !isfinite(r.cfd) || time() - r.t > max_age_s) && continue
        channel = get(channel_of, k, k + 1)
        1 <= channel <= 2 && (out[channel] = max(r.cfd, 1.0))
    end
    return out[1], out[2]
end

function spc_handle_result!(view::SpcView, r::FLIMCore.Taux)
    card = spc_card!(view, r.carte)
    card.last_rates = r
    if r.valide
        push!(card.rate_t, r.t - view.t0)
        push!(card.rate_cfd, r.cfd)
        if length(card.rate_t) > SPC_RATE_HISTORY
            deleteat!(card.rate_t, 1)
            deleteat!(card.rate_cfd, 1)
        end
        card.rates_dirty = true
    end
    return nothing
end

function spc_handle_result!(view::SpcView, r::FLIMCore.Alerte)
    push!(view.alerts, r)
    length(view.alerts) > SPC_ALERT_HISTORY && deleteat!(view.alerts, 1)
    level = r.gravite == :erreur ? :error : r.gravite == :avertissement ? :warn : :info
    spc_journal!(view, level, "SPC: " * r.texte)
    # Every warning or error of the engine carries a problem code (diagnostics.jl).
    if level != :info
        id = alert_problem_id(r.texte)
        report_problem!(id, "SPC engine: " * r.texte; level, key = "$id/module $(r.carte)/" * first(r.texte, 30))
    end
    view.texts_dirty = true
    return nothing
end

"""The counters of the current Realtime measurement (diagnosed once a second by the refresh tick)."""
function spc_handle_result!(view::SpcView, r::FLIMCore.EtatClamp)
    view.clamp_status = r
    return nothing
end

function spc_handle_result!(view::SpcView, r::FLIMCore.ImageSomme)
    view.roi_image_pending && (view.roi_image_parts[r.carte] = r)
    return nothing
end

function spc_handle_result!(view::SpcView, r::FLIMCore.Fin)
    view.last_fin = r
    if view.irf_acquisition && r.mesure == :single
        view.irf_acquisition = false
        view.irf_fin = r                                     # the refresh tick imports it
    end
    if view.roi_image_pending && r.mesure == :imagerie
        view.roi_image_pending = false
        view.roi_image[] = copy(view.roi_image_parts)        # the ROI popup listens
        empty!(view.roi_image_parts)
    end
    what = r.mesure == :imagerie ? "imaging" : r.mesure == :single ? "Single" : r.mesure == :clamp ? "Realtime" : "engine"
    spc_journal!(view, r.erreur ? :error : :info, "SPC $what ended: $(r.raison); $(length(r.fichiers)) file(s)" *
                                                  (isempty(r.fichiers) ? "" : " in $(dirname(first(r.fichiers)))"))
    view.texts_dirty = true
    return nothing
end

function spc_handle_result!(view::SpcView, r::FLIMCore.EtatCartes)
    view.check = r
    for p in r.problemes
        id = alert_problem_id(p)
        report_problem!(id, "SPC check: " * p; key = "$id/check/" * first(p, 30))
    end
    @info "SPC check" source = r.source ok = r.ok cards = join(["module $(c.carte): $(c.serie) channel $(c.canal) " *
                                                                  (c.pret ? "ready, SYNC $(c.sync), CFD $(fmt_rate(c.cfd))" : "not ready ($(c.etat_init))")
                                                                  for c in r.cartes], "; ")
    view.texts_dirty = true
    return nothing
end

function spc_handle_result!(view::SpcView, r::FLIMCore.HistoSingle)
    card = spc_card!(view, r.carte)
    h = r.histogramme
    if view.irf_acquisition
        # The IRF acquisition: the running sum, and how far its maximum is from the target.
        sum_ = get!(() -> zeros(Int, length(h)), view.irf_sums, r.carte)
        length(sum_) == length(h) && (sum_ .+= h)
        h = sum_
    end
    group = max(1, length(h) ÷ 256)
    points = card.single[]
    empty!(points)
    for k in 1:group:length(h) - group + 1
        counts = sum(Int, view_range(h, k, group))
        push!(points, Point2f((k - 1 + group / 2) * r.dt_ns, counts + 1))
    end
    notify(card.single)
    card.title[] = view.irf_acquisition ?
        "Card $(r.carte) — IRF: $(r.numero) Single(s), maximum $(maximum(h)) / $(view.settings.irf_maximum)" :
        "Card $(r.carte) — Single $(r.numero)/$(r.total): $(r.fin)"
    return nothing
end

spc_handle_result!(::SpcView, ::FLIMCore.Resultat) = nothing

view_range(h, k, n) = view(h, k:k + n - 1)

"""
    spc_accumulate!(card, frame, frames_per_image)

Add one frame to the card's accumulator; once it holds `frames_per_image`
frames it becomes the image to show (swapped, not copied) and a fresh sum
starts. `frames_per_image = 0`: never reset, show the running sum.
"""
function spc_accumulate!(card::SpcCard, frame::FLIMCore.ImageTrame, frames_per_image::Integer)
    if frame.generation != card.generation || size(card.acc_intensity) != size(frame.intensite)
        # new acquisition: start over
        card.generation = frame.generation
        card.acc_intensity = zeros(UInt32, size(frame.intensite))
        card.acc_time = zeros(Float64, size(frame.intensite))
        card.shown_intensity = zeros(UInt32, size(frame.intensite))
        card.shown_time = zeros(Float64, size(frame.intensite))
        fill!(card.acc_decay, 0)
        card.acc_frames = 0
    end
    card.acc_intensity .+= frame.intensite
    card.acc_time .+= frame.somme_t
    card.acc_decay .+= frame.declin
    card.acc_frames += 1
    card.last_frame = frame.numero
    card.dt_ns = frame.dt_ns
    if frames_per_image > 0 && card.acc_frames >= frames_per_image
        card.acc_intensity, card.shown_intensity = card.shown_intensity, card.acc_intensity
        card.acc_time, card.shown_time = card.shown_time, card.acc_time
        card.acc_decay, card.shown_decay = card.shown_decay, card.acc_decay
        card.shown_frames = card.acc_frames
        fill!(card.acc_intensity, 0)
        fill!(card.acc_time, 0.0)
        fill!(card.acc_decay, 0)
        card.acc_frames = 0
        card.pending = true
    elseif frames_per_image <= 0
        card.pending = true
    end
    return nothing
end

"""
    display_range!(scratch, values; lo=2, hi=98, positive=false)

Low/high display limits: `lo`-th and `hi`-th percentiles of the finite
(positive, if asked) values; from 0 when `positive`. Linear-time selection
in a reused buffer, on a regular subsample of about 10^5 values: this runs
on the GUI thread on whole images, and only sets a color scale.
"""
function display_range!(scratch::Vector{Float32}, values::AbstractArray{Float32}; lo::Real = 2, hi::Real = 98, positive::Bool = false)
    empty!(scratch)
    step = max(1, length(values) ÷ 100_000)
    @inbounds for i in 1:step:length(values)
        x = values[i]
        isfinite(x) && (!positive || x > 0) && push!(scratch, x)
    end
    isempty(scratch) && return (0.0f0, 1.0f0)
    rank(p) = clamp(round(Int, p / 100 * (length(scratch) - 1)) + 1, 1, length(scratch))
    b = partialsort!(scratch, rank(hi))
    a = positive ? 0.0f0 : partialsort!(scratch, rank(lo))
    return b > a ? (a, b) : (a, a + 1.0f0)
end

"""The card's intensity sum as a Float32 image, x = pixel, y = line, in the card's reused buffer."""
function transposed_image!(card::SpcCard, intensity::Matrix{UInt32})
    ny, nx = size(intensity)
    size(card.image) == (nx, ny) || (card.image = zeros(Float32, nx, ny))
    img = card.image
    @inbounds for y in 1:ny, x in 1:nx
        img[x, y] = intensity[y, x]
    end
    return img
end

"""
Mean arrival time per `binning` × `binning` block, as `FLIMCore.temps_moyen`
computes it (NaN under `photons_min` photons), transposed like the
intensity image, in the card's reused buffer.
"""
function mean_time_image!(card::SpcCard, intensity::Matrix{UInt32}, sum_t::Matrix{Float64}, binning::Integer, photons_min::Integer)
    ny, nx = size(intensity)
    b = clamp(binning, 1, max(1, min(ny, nx)))
    by, bx = ny ÷ b, nx ÷ b
    size(card.mean_image) == (bx, by) || (card.mean_image = zeros(Float32, bx, by))
    img = card.mean_image
    threshold = max(photons_min, 1)
    @inbounds for j in 1:bx, i in 1:by
        n, t = 0, 0.0
        for x in (j - 1) * b + 1:j * b, y in (i - 1) * b + 1:i * b
            n += intensity[y, x]
            t += sum_t[y, x]
        end
        img[j, i] = n >= threshold ? Float32(t / n) : NaN32
    end
    return img
end

"""
    spc_publish_image!(view, card)

Recompute the card's displayed images from its last complete sum: intensity
(0 to the 99.5th percentile), mean arrival time per `binning_temps` block
(2nd to 98th percentile, NaN under `photons_min` photons: see
`FLIMCore.temps_moyen`), and the decay grouped in 256 bins. Images are
transposed (x = pixel, y = line) for the heatmaps.
"""
function spc_publish_image!(view::SpcView, card::SpcCard)
    s = view.settings
    running_sum = s.trames_par_image <= 0
    intensity = running_sum ? card.acc_intensity : card.shown_intensity
    sum_t = running_sum ? card.acc_time : card.shown_time
    decay = running_sum ? card.acc_decay : card.shown_decay
    frames = running_sum ? card.acc_frames : card.shown_frames
    card.pending = false
    isempty(intensity) && return nothing

    card.intensity[] = transposed_image!(card, intensity)
    card.intensity_range[] = display_range!(card.scratch, card.image; hi = 99.5, positive = true)
    card.mean_time[] = mean_time_image!(card, intensity, sum_t, s.binning_temps, s.photons_min)
    card.time_range[] = display_range!(card.scratch, card.mean_image)

    points = card.decay[]
    empty!(points)
    for k in 1:16:4096
        push!(points, Point2f((k + 7) * card.dt_ns, sum(view_range(decay, k, 16)) + 1))
    end
    notify(card.decay)
    card.title[] = "Card $(card.card) — frame $(card.last_frame), $frames frame(s), $(sum(Int, intensity)) photons"
    return nothing
end

function spc_publish_rates!(view::SpcView, card::SpcCard)
    card.rates_dirty = false
    points = card.rates[]
    empty!(points)
    for (t, cfd) in zip(card.rate_t, card.rate_cfd)
        push!(points, Point2f(t, max(cfd, 1.0)))
    end
    notify(card.rates)
    return nothing
end

# -----------------------------------------------------------------------------
# Texts
# -----------------------------------------------------------------------------

fmt_rate(x) = isfinite(x) ? @sprintf("%.3g", x) : "—"

"""
    spc_status_text(view)::String

One line for the main window's top bar: the latest problem (`view.problem`,
with its code, see diagnostics.jl), the offline banner if any
(`view.banner`, see `offline_reason`), engine state, each card's CFD rate
and SYNC, and the last error of the last 30 s.
"""
function spc_status_text(view::SpcView)::String
    state = spc_state(view)
    head = state == :none ? (view.last_fin !== nothing && view.last_fin.erreur ? "SPC: stopped — $(view.last_fin.raison)" : "SPC: not connected") :
           "SPC: " * SPC_ENGINE_STATE_NAMES[state]
    parts = isempty(view.banner) ? String[head] : String["⚠ " * view.banner, head]
    isempty(view.problem) || pushfirst!(parts, "⚠ " * view.problem)
    if state != :none
        for c in sort!(collect(keys(view.cards)))
            r = view.cards[c].last_rates
            r === nothing && continue
            sync = r.etat_sync == 1 ? "SYNC ok" : "NO SYNC"
            push!(parts, "card $c: CFD $(fmt_rate(r.cfd)) /s, $sync")
        end
    end
    if !isempty(view.alerts)
        a = view.alerts[end]
        a.gravite == :erreur && time() - a.t < 30 && push!(parts, "⚠ " * a.texte)
    end
    isempty(view.last_error) || time() - view.last_error_t > 15 || push!(parts, "⚠ " * view.last_error)
    return join(parts, "   ·   ")
end

"""Verification summary and alerts, for the SPC window."""
function spc_update_texts!(view::SpcView)
    lines = String[]
    check = view.check
    if check === nothing
        push!(lines, view.engine === nothing ? "Engine not running." : "Checking the cards…")
    else
        push!(lines, "Source: $(check.source) — " * (check.ok ? "all checks passed" : "$(length(check.problemes)) problem(s)"))
        for c in check.cartes
            if c.pret
                channel = c.canal > 0 ? "channel $(c.canal)" : "not in [verification] series"
                applied = count(l -> l.statut == :ok, c.tableau)
                push!(lines, "Card $(c.carte): $(c.serie) ($channel), $(get(FLIMCore.SPCLite.MESSAGES_SYNC, c.sync, "SYNC state $(c.sync)")), " *
                             "CFD $(fmt_rate(c.cfd)) /s, $applied/$(length(c.tableau)) settings applied")
            else
                push!(lines, "Card $(c.carte): not ready — $(c.etat_init)")
            end
        end
        for p in check.problemes
            push!(lines, "• " * p)
        end
    end
    fin = view.last_fin
    if fin !== nothing && fin.mesure != :moteur
        push!(lines, "")
        what = fin.mesure == :imagerie ? "imaging" : fin.mesure == :single ? "Single" : "Realtime"
        push!(lines, "Last $what: $(fin.raison)" *
                     (isempty(fin.fichiers) ? "" : " — files in $(dirname(first(fin.fichiers)))"))
    end
    view.check_text[] = join(lines, "\n")

    stamp(a) = Dates.format(Dates.unix2datetime(a.t) + local_utc_offset(), "HH:MM:SS")
    mark(a) = a.gravite == :erreur ? "✖" : a.gravite == :avertissement ? "▲" : "·"
    shown = Iterators.take(Iterators.reverse(view.alerts), 9)          # what fits the window's band
    view.alerts_text[] = "Alerts (newest first)\n" * join(("$(stamp(a)) $(mark(a)) $(a.texte)" for a in shown), "\n")

    engine = view.engine
    view.info_text[] = engine === nothing ? "Settings: $(view.settings_path)" :
        "Settings: $(view.settings_path)\nResults dropped: $(engine.perdus[]), frames not shown: $(engine.trames_sautees[])"
    return nothing
end

"""Button labels follow the engine state (only while the SPC window is open)."""
function spc_update_widgets!(view::SpcView, state::Symbol)
    w = view.widgets
    (w === nothing || !view.window_open) && return nothing
    set_label!(button, text) = button.label[] == text || (button.label[] = text)
    set_label!(w.connect_button, state == :none ? "CONNECT" : "DISCONNECT")
    set_label!(w.image_button, state == :imagerie ? "STOP" : "IMAGE")
    set_label!(w.single_button, state == :single && !view.irf_acquisition ? "STOP" : "SINGLE")
    set_label!(w.irf_button, state == :single && view.irf_acquisition ? "STOP" : "IRF")
    set_label!(w.unlock_button, view.unlock_armed_until > time() ? "CONFIRM?" : "UNLOCK")
    return nothing
end

"""SPC line of the Console panel's diagnostics."""
function spc_diagnostics_text(view::SpcView)::String
    engine = view.engine
    engine === nothing && return "SPC engine: not running"
    return "SPC engine: $(SPC_ENGINE_STATE_NAMES[FLIMCore.etat_moteur(engine)])   results dropped $(engine.perdus[])   " *
           "frames not shown $(engine.trames_sautees[])   Realtime histograms dropped $(engine.histos_perdus[])"
end

"""
    warm_up_spc_display!(view)

Run the result handling and image computation once on a dummy frame, so
JIT compilation doesn't land on the first real frame (plan.md §5). Leaves
the display as it was.
"""
function warm_up_spc_display!(view::SpcView)
    card = SpcCard(-1)
    frame = FLIMCore.ImageTrame(-1, 1, true, ones(UInt32, 8, 8), fill(2.0, 8, 8), ones(Int, 4096),
                                12.5 / 4096, 64, 64, 0, false, 0.0, 0)
    spc_accumulate!(card, frame, 1)
    spc_publish_image!(view, card)
    spc_publish_rates!(view, card)
    spc_status_text(view)
    spc_update_texts!(view)
    return nothing
end
