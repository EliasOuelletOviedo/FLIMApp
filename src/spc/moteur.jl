# moteur.jl — la tâche qui possède les cartes (étape 3 du plan).
#
# Une seule tâche (`Threads.@spawn`) appelle la source, donc la DLL SPC.
# Elle reçoit des commandes par `m.commandes` et publie tout ce qu'elle
# produit dans `m.resultats`. Elle n'attend jamais le GUI : un résultat qui
# ne trouve pas de place est jeté et compté (`m.perdus`), une trame sans
# tampon libre n'est pas publiée (`m.trames_sautees`), sans que
# l'enregistrement ni les cumuls n'en souffrent.
#
# Libération garantie : try/finally autour de toute la vie du moteur ;
# `arreter_moteur` est appelé par la fermeture de la fenêtre et par atexit.

"""Période de relecture des taux, mesure en cours ou non."""
const PERIODE_TAUX = 0.5

# ---------------------------------------------------------------------
# Résultats
# ---------------------------------------------------------------------

abstract type Resultat end

"""
    ImageTrame

Une trame d'une carte : `intensite` (lignes × pixels), `somme_t` (somme
des temps d'arrivée par pixel, en ns : temps moyen = somme_t / intensite),
`declin` (4096 canaux de `dt_ns`, temps croissant, tous les photons de la
trame), `photons`, `dans_image`, `pertes` (enregistrements GAP) et
`fifo_deborde`. `complete = false` pour la dernière trame d'une acquisition.
`t_s` : début de la trame, en secondes depuis le début de l'acquisition.

Les tampons viennent d'un pool : rends la trame avec `rendre!(m, trame)`
une fois lue, ou le moteur finit par ne plus en publier.
"""
mutable struct ImageTrame <: Resultat
    carte::Int
    numero::Int
    complete::Bool
    intensite::Matrix{UInt32}
    somme_t::Matrix{Float64}
    declin::Vector{Int}
    dt_ns::Float64
    photons::Int
    dans_image::Int
    pertes::Int
    fifo_deborde::Bool
    t_s::Float64
    generation::Int
end

"""
    ImageSomme

Fin d'une acquisition d'imagerie, pour une carte : la somme de toutes ses
trames (`intensite`, `somme_t`, `declin` comme une `ImageTrame`), et, si
l'`Imagerie` le demandait (`garder_mots`), le flux FIFO rangé dans l'image
(`mots`), avec la géométrie résolue (`geometrie`, tailles explicites) : de
quoi refaire un déclin par groupe de pixels (`histogrammes_pixels`).
`serie` et `canal` : la carte qui l'a faite (canal 0 : n° de série absent
de [verification] series).
"""
struct ImageSomme <: Resultat
    carte::Int
    serie::String
    canal::Int
    intensite::Matrix{UInt32}
    somme_t::Matrix{Float64}
    declin::Vector{Int}
    dt_ns::Float64
    tic_s::Float64
    trames::Int
    geometrie::Geometrie
    mots::Vector{UInt16}
end

"""Un histogramme Single (`numero` sur `total`), construit dans la carte ; temps croissant."""
struct HistoSingle <: Resultat
    carte::Int
    numero::Int
    total::Int
    histogramme::Vector{UInt16}
    dt_ns::Float64
    etat::UInt16
    duree_s::Float64
    fin::String
end

"""Taux d'une carte en coups/s, toutes les 0,5 s ; `valide = false` si la carte ne les avait pas prêts."""
struct Taux <: Resultat
    carte::Int
    t::Float64
    sync::Float64
    cfd::Float64
    tac::Float64
    adc::Float64
    remplissage_fifo::Float64
    etat_sync::Int
    en_mesure::Bool
    valide::Bool
end

"""Alerte : `gravite` :info, :avertissement ou :erreur ; `carte` -1 si elle les concerne toutes."""
struct Alerte <: Resultat
    gravite::Symbol
    carte::Int
    texte::String
    t::Float64
end
Alerte(gravite::Symbol, carte::Integer, texte::AbstractString) = Alerte(gravite, Int(carte), String(texte), time())

"""Fin d'une mesure (`mesure` :imagerie, :single) ou du moteur (:moteur), avec les fichiers écrits."""
struct Fin <: Resultat
    mesure::Symbol
    raison::String
    erreur::Bool
    fichiers::Vector{String}
    t::Float64
end

"""
    HistoClamp

Une passe du mode Realtime (un scan d'une ROI), délimitée par les cartes
elles-mêmes : marqueur M0 au début, M3 à la fin (`t_debut_s`, `t_fin_s`,
temps de la première carte depuis le début de la mesure). `histogrammes[i]`
est la carte `cartes[i]` (canal i : ordre de [verification] series) :
`canaux` × 16, une colonne par code de routage lu par la carte (colonne
`code + 1` ; la colonne du code réservé reste vide : ses photons sont
jetés). Temps croissant, canaux de `dt_ns`. `pertes` : enregistrements GAP
depuis la passe précédente, toutes cartes.

`motifs` : pourquoi la passe ne doit pas nourrir le PI (vide : elle peut).
Trois cas, sur n'importe quelle carte : un enregistrement porte le drapeau
de perte (GAP) ; SPC_FOVFL est apparu pendant la passe ; M3 − M0 s'écarte
de la durée programmée de plus d'un échantillon de l'AO et 100 ppm (un
marqueur perdu ou en trop). Publiés dans `m.histogrammes`, que lit
l'analyse.
"""
struct HistoClamp
    passe::Int
    t_debut_s::Float64
    t_fin_s::Float64
    cartes::Vector{Int}
    series::Vector{String}
    histogrammes::Vector{Matrix{UInt32}}
    pertes::Int
    dt_ns::Float64
    motifs::Vector{String}
end

HistoClamp(passe, t_debut_s, t_fin_s, cartes, series, histogrammes, pertes, dt_ns) =
    HistoClamp(passe, t_debut_s, t_fin_s, cartes, series, histogrammes, pertes, dt_ns,
               pertes > 0 ? ["GAP : $pertes enregistrement(s) perdus"] : String[])

"""
Les compteurs d'une carte pendant une mesure Realtime, depuis son début :
mots lus du FIFO, photons décodés, fronts de chaque marqueur M0–M3,
photons lus pendant les passes par code de routage (codes 0–15, le code
réservé compris), photons jetés (code réservé) et hors passe, passes
terminées et abandonnées (marqueur de fin perdu), enregistrements GAP,
SPC_FOVFL vu, durées M3 − M0 (s ; NaN avant la première passe), passes hors
tolérance, sans correspondante sur l'autre carte, et en attente de
l'appariement.
"""
struct CompteursCarte
    carte::Int
    serie::String
    canal::Int
    tic_s::Float64
    mots::Int
    photons::Int
    marqueurs::Vector{Int}
    photons_par_code::Vector{Int}
    hors_roi::Int
    hors_passe::Int
    passes::Int
    abandonnees::Int
    pertes::Int
    fifo_deborde::Bool
    duree_min_s::Float64
    duree_max_s::Float64
    duree_derniere_s::Float64
    hors_duree::Int
    sans_partenaire::Int
    en_attente::Int
end

"""
    EtatClamp

Ce que les cartes ont reçu depuis le début d'une mesure Realtime
(`CompteursCarte`, une par carte, dans l'ordre des canaux), publié chaque
seconde et à la fin (`fin`) : de quoi diagnostiquer le signal de passe et
le routage sans rien deviner (le GUI en tire des problèmes identifiés,
diagnostics.jl). `codes` : les codes de routage que la NI écrit pendant
les scans ; `scan_s`, `pause_s`, `tolerance_s` : les passes programmées
(NaN : inconnues) ; `publiees` : passes publiées pour l'analyse.
"""
struct EtatClamp <: Resultat
    t::Float64
    duree_s::Float64
    fin::Bool
    codes::Vector{Int}
    scan_s::Float64
    pause_s::Float64
    tolerance_s::Float64
    cartes::Vector{CompteursCarte}
    publiees::Int
end

"""Période de publication d'`EtatClamp` pendant un Realtime."""
const PERIODE_ETAT_CLAMP = 1.0

const LigneTableau = NamedTuple{(:cle, :demande, :applique, :statut),Tuple{String,Any,Float64,Symbol}}

"""
Une carte vue à la vérification : identité, canal (sa place dans
[verification] series, 0 si son n° de série n'y est pas), SYNC, CFD,
tableau « demandé → appliqué ».
"""
mutable struct EtatCarte
    carte::Int
    pret::Bool
    etat_init::String
    type::Int
    serie::String
    canal::Int
    sync::Int
    cfd::Float64
    tableau::Vector{LigneTableau}
end

"""Résultat de la vérification : `ok` si aucun problème."""
struct EtatCartes <: Resultat
    source::String
    cartes::Vector{EtatCarte}
    ok::Bool
    problemes::Vector{String}
    t::Float64
end

# ---------------------------------------------------------------------
# Commandes
# ---------------------------------------------------------------------

abstract type Commande end

"""
    Imagerie(geometrie; duree=Inf, trames=0, garder_mots=false)

Imagerie en FIFO avec les horloges du scanner, en continu (`duree = Inf`),
pour une durée, ou jusqu'à `trames` trames complètes. À la fin, une
`ImageSomme` par carte, avec le flux brut si `garder_mots`.
"""
struct Imagerie <: Commande
    geometrie::Geometrie
    duree::Float64
    trames::Int
    garder_mots::Bool
end
Imagerie(g::Geometrie = Geometrie(); duree::Real = Inf, trames::Integer = 0, garder_mots::Bool = false) =
    Imagerie(g, Float64(duree), Int(trames), garder_mots)

"""`n` histogrammes Single de `temps_s` secondes, construits dans les cartes."""
struct Single <: Commande
    temps_s::Float64
    n::Int
end
Single(temps_s::Real, n::Integer = 1) = Single(Float64(temps_s), Int(n))

"""
    Clamp(; rois=Int[], ordre=rois, dossier="", scan_s=0.95, pause_s=0.05, echantillon_s=NaN)

Mode Realtime en FIFO avec routage : les cartes horodatent chaque photon
avec son code de routage, et les fronts du signal de passe (M0 début, M3
fin). Le moteur lit le FIFO au fil de l'eau, découpe les passes (`Passes`)
et publie un `HistoClamp` par passe dans `m.histogrammes`. Aucune échéance
logicielle : un retard ne fait que remplir le FIFO des cartes.

- Sans ROI (`rois` vide) : la NI écrit `CODE_SANS_ROI` pendant les scans.
- Avec ROI : la carte lit le code de la ROI scannée (`code_routage` : son
  n° dessiné, 1 à 15). Plus de 15 ROI : refusé.
- Pendant les déplacements et les pauses : le code réservé
  (`CODE_HORS_ROI`), dont les photons sont jetés.

`dossier` : où enregistrer la session (pour chaque carte, le flux FIFO
`<série>.spc`, son `_acquisition.ini` et ses paramètres relus) ; "" : rien.
`echantillon_s` : la période d'échantillonnage de l'AO ; avec `scan_s`, la
durée programmée d'un scan, elle sert au contrôle de M3 − M0 (tolérance :
un échantillon et 100 ppm) ; NaN : pas de contrôle. `ordre` et `pause_s`
ne servent qu'à la simulation, qui fabrique les passes que la NI
produirait.
"""
struct Clamp <: Commande
    rois::Vector{Int}
    ordre::Vector{Int}
    dossier::String
    scan_s::Float64
    pause_s::Float64
    echantillon_s::Float64
end
Clamp(; rois::AbstractVector{<:Integer} = Int[], ordre::AbstractVector{<:Integer} = rois,
      dossier::AbstractString = "", scan_s::Real = 0.95, pause_s::Real = 0.05, echantillon_s::Real = NaN) =
    Clamp(Int.(rois), Int.(ordre), String(dossier), Float64(scan_s), Float64(pause_s), Float64(echantillon_s))

"""Écart toléré sur M3 − M0 : un échantillon de l'AO et 100 ppm de la durée programmée."""
tolerance_passe(c::Clamp) = c.echantillon_s + 100e-6 * c.scan_s

"""Arrête la mesure en cours (réponse : un `Fin`)."""
struct Arret <: Commande end

"""Refait la vérification des cartes (réponse : un `EtatCartes`)."""
struct Verifier <: Commande
    reponse::Union{Nothing,Channel{Any}}
end
Verifier() = Verifier(nothing)

"""Reprend de force les modules verrouillés (état -6). SPCM doit être fermé : le GUI demande confirmation."""
struct Deverrouiller <: Commande end

# ---------------------------------------------------------------------
# Le moteur
# ---------------------------------------------------------------------

"""Tampons d'image d'une carte, pour une acquisition (`generation`)."""
mutable struct PoolTrames
    verrou::ReentrantLock
    libres::Vector{ImageTrame}
    generation::Int
end

"""
    Moteur

Poignée du moteur rendue par `demarrer_moteur`. Le GUI n'utilise que
`commander!`, `m.resultats` (take!/isready), `rendre!`, `etat_moteur`,
`verifier` et `arreter_moteur` ; l'analyse du mode Realtime lit
`m.histogrammes` (un `HistoClamp` par période), que le GUI ne touche pas.
"""
mutable struct Moteur
    commandes::Channel{Commande}
    resultats::Channel{Resultat}
    histogrammes::Channel{HistoClamp}
    tache::Union{Nothing,Task}
    arret::Threads.Atomic{Bool}
    perdus::Threads.Atomic{Int}
    histos_perdus::Threads.Atomic{Int}
    trames_sautees::Threads.Atomic{Int}
    @atomic etat::Symbol
    reglages::Reglages
    source::Union{Nothing,Source}
    verrou_pools::ReentrantLock
    pools::Dict{Int,PoolTrames}
    tampons::Int
    generation::Int
    raison_arret::String          # écrite par la tâche avant de finir
end

"""État du moteur : :demarrage, :pret, :imagerie, :single, :clamp ou :arrete."""
etat_moteur(m::Moteur) = @atomic m.etat
_etat!(m::Moteur, e::Symbol) = (@atomic m.etat = e; nothing)

const _MOTEURS = Set{Moteur}()
const _VERROU_MOTEURS = ReentrantLock()

"""
    demarrer_moteur(reglages; source=nothing, capacite=1024, tampons=4) -> Moteur

Lance la tâche qui possède les cartes : elle ouvre la source (SPC_init pour
les cartes ; `source_depuis(reglages)` si `source` n'est pas donnée),
vérifie les cartes (un `EtatCartes` dans `m.resultats`), puis attend les
commandes. Si `reglages.fichier` est renseigné, elle le relit à chaque
démarrage de mesure.
"""
function demarrer_moteur(reglages::Reglages; source::Union{Nothing,Source} = nothing,
                         capacite::Integer = 1024, tampons::Integer = 4)
    Threads.nthreads() == 1 &&
        @warn "Julia tourne avec un seul fil : le moteur SPC partagera le fil du GUI. Lance julia -t auto."
    m = Moteur(Channel{Commande}(64), Channel{Resultat}(capacite), Channel{HistoClamp}(256), nothing,
               Threads.Atomic{Bool}(false), Threads.Atomic{Int}(0), Threads.Atomic{Int}(0), Threads.Atomic{Int}(0),
               :demarrage, copier_reglages(reglages), source, ReentrantLock(),
               Dict{Int,PoolTrames}(), max(1, tampons), 0, "")
    lock(() -> push!(_MOTEURS, m), _VERROU_MOTEURS)
    m.tache = Threads.@spawn _boucle_moteur(m)
    return m
end

"""
    arreter_moteur(m; delai_s=10.0) -> Bool

Arrête la mesure en cours, libère les cartes et termine la tâche ; attend
au plus `delai_s`. Sans effet sur un moteur déjà arrêté.
"""
function arreter_moteur(m::Moteur; delai_s::Real = 10.0)
    m.arret[] = true
    t = m.tache
    arrete = t === nothing || timedwait(() -> istaskdone(t), Float64(delai_s); pollint = 0.01) === :ok
    arrete || @warn "Le moteur SPC ne s'est pas arrêté en $delai_s s"
    lock(() -> delete!(_MOTEURS, m), _VERROU_MOTEURS)
    return arrete
end

"""Arrête tous les moteurs encore en marche (atexit)."""
function arreter_tous()
    for m in lock(() -> collect(_MOTEURS), _VERROU_MOTEURS)
        arreter_moteur(m; delai_s = 5.0)
    end
    return nothing
end

"""
    commander!(m, commande) -> Bool

Dépose une commande pour le moteur, sans jamais attendre : si la file est
pleine (moteur bloqué ou arrêté), la commande est jetée avec un avertissement.
"""
function commander!(m::Moteur, c::Commande)
    if Base.n_avail(m.commandes) >= m.commandes.sz_max
        @warn "Le moteur SPC ne prend pas de commandes ; jetée" commande = typeof(c)
        return false
    end
    put!(m.commandes, c)
    return true
end

"""
    verifier(m; delai_s=60.0) -> EtatCartes

Vérification des cartes (modules, n° de série, SYNC, CFD, tableau demandé
→ appliqué), en attendant la réponse du moteur : pour les scripts et le
REPL. Le GUI envoie plutôt `commander!(m, Verifier())` et lit l'`EtatCartes`
dans `m.resultats`.
"""
function verifier(m::Moteur; delai_s::Real = 60.0)
    reponse = Channel{Any}(1)
    commander!(m, Verifier(reponse)) || error("le moteur SPC ne prend pas de commandes")
    t = m.tache
    timedwait(() -> isready(reponse) || (t !== nothing && istaskdone(t)), Float64(delai_s); pollint = 0.01)
    isready(reponse) || error(t !== nothing && istaskdone(t) ? "le moteur SPC s'est arrêté : $(m.raison_arret)" :
                                                                "pas de réponse du moteur SPC ($(etat_moteur(m)))")
    x = take!(reponse)
    x isa Exception && throw(x)
    return x::EtatCartes
end

"""Rend au moteur le tampon d'une `ImageTrame` lue (sans effet sur les autres résultats)."""
function rendre!(m::Moteur, t::ImageTrame)
    lock(m.verrou_pools) do
        p = get(m.pools, t.carte, nothing)
        p === nothing || p.generation != t.generation || _rendre!(p, t)
    end
    return nothing
end
rendre!(::Moteur, ::Resultat) = nothing

"""Prochain résultat s'il y en a un, sinon `nothing` (n'attend pas)."""
recevoir(m::Moteur) = isready(m.resultats) ? take!(m.resultats) : nothing

function _rendre!(p::PoolTrames, t::ImageTrame)
    lock(() -> push!(p.libres, t), p.verrou)
    return nothing
end

function _acquerir!(p::PoolTrames)
    lock(p.verrou) do
        isempty(p.libres) ? nothing : pop!(p.libres)
    end
end

function _nouveau_pool!(m::Moteur, carte::Int, ny::Int, nx::Int, dt_ns::Float64)
    m.generation += 1
    g = m.generation
    trames = [ImageTrame(carte, 0, false, zeros(UInt32, ny, nx), zeros(Float64, ny, nx), zeros(Int, 4096),
                         dt_ns, 0, 0, 0, false, 0.0, g) for _ in 1:m.tampons]
    p = PoolTrames(ReentrantLock(), trames, g)
    lock(() -> (m.pools[carte] = p), m.verrou_pools)
    return p
end

"""Publie un résultat sans attendre ; jeté et compté si le canal est plein."""
function publier!(m::Moteur, r::Resultat)
    if Base.n_avail(m.resultats) >= m.resultats.sz_max
        Threads.atomic_add!(m.perdus, 1)
        return false
    end
    put!(m.resultats, r)
    return true
end

_prochaine_commande(m::Moteur) = isready(m.commandes) ? take!(m.commandes) : nothing

_texte_erreur(e) = (s = sprint(showerror, e); length(s) > 400 ? first(s, 400) * "…" : s)

# ---------------------------------------------------------------------
# La boucle
# ---------------------------------------------------------------------

"""Ce que le moteur sait des cartes et de la surveillance des taux."""
mutable struct Contexte
    reglages::Reglages
    code_init::Int
    detectes::Vector{Int}
    prets::Vector{Int}
    etats::Dict{Int,Int}
    sync_ok::Dict{Int,Bool}
    cfd_ok::Dict{Int,Bool}
    series::Dict{Int,String}
end

function _boucle_moteur(m::Moteur)
    ctx = Contexte(m.reglages, 0, Int[], Int[], Dict{Int,Int}(), Dict{Int,Bool}(), Dict{Int,Bool}(), Dict{Int,String}())
    raison, erreur = "arrêt demandé", false
    try
        m.source === nothing && (m.source = source_depuis(ctx.reglages))
        src = m.source
        _modules!(ctx, ouvrir!(src, ctx.reglages))
        _signaler_modules!(m, ctx)
        _executer!(m, src, ctx, Verifier())      # une erreur ici laisse le moteur en marche
        _etat!(m, :pret)
        prochain_taux = time()
        while !m.arret[]
            c = _prochaine_commande(m)
            if c === nothing
                if time() >= prochain_taux
                    _taux!(m, src, ctx, ctx.prets, false)
                    prochain_taux = time() + PERIODE_TAUX
                end
                sleep(0.01)
            else
                _executer!(m, src, ctx, c)
                prochain_taux = time()
            end
        end
    catch e
        raison, erreur = _texte_erreur(e), true
        publier!(m, Alerte(:erreur, -1, "moteur SPC arrêté : " * raison))
        @error "Moteur SPC arrêté : $raison" exception = (e, catch_backtrace())
    finally
        # Les cartes sont libérées quoi qu'il arrive.
        try
            m.source === nothing || fermer!(m.source)
        catch e
            publier!(m, Alerte(:erreur, -1, "libération des cartes : " * _texte_erreur(e)))
        end
        m.raison_arret = raison
        publier!(m, Fin(:moteur, raison, erreur, String[], time()))
        _etat!(m, :arrete)
    end
    return nothing
end

function _modules!(ctx::Contexte, o)
    ctx.code_init = o.code
    ctx.detectes = collect(o.detectes)
    ctx.prets = collect(o.prets)
    ctx.etats = Dict{Int,Int}(o.etats)
    return ctx
end

function _signaler_modules!(m::Moteur, ctx::Contexte)
    isempty(ctx.detectes) &&
        publier!(m, Alerte(:erreur, -1, "aucune carte SPC détectée (SPC_init : $(ctx.code_init))"))
    for k in ctx.detectes
        e = ctx.etats[k]
        e == 0 && continue
        texte = e == -6 ?
            "module $k verrouillé par un autre programme (SPCM ouvert ?) : ferme SPCM, puis « Déverrouiller »" :
            "module $k pas prêt : " * explication_init(e)
        publier!(m, Alerte(:erreur, k, texte))
    end
    return nothing
end

function _executer!(m::Moteur, src::Source, ctx::Contexte, c::Commande)
    try
        if c isa Imagerie
            _imagerie!(m, src, ctx, c)
        elseif c isa Single
            _single!(m, src, ctx, c)
        elseif c isa Verifier
            _verifier!(m, src, ctx, c.reponse)
        elseif c isa Clamp
            _clamp!(m, src, ctx, c)
        elseif c isa Deverrouiller
            _deverrouiller!(m, src, ctx)
        end                                  # Arret sans mesure en cours : rien à faire
    catch e
        texte = _texte_erreur(e)
        @error "Commande $(nameof(typeof(c))) en échec" exception = (e, catch_backtrace())
        publier!(m, Alerte(:erreur, -1, "$(nameof(typeof(c))) : " * texte))
        c isa Verifier && c.reponse !== nothing && !isready(c.reponse) && put!(c.reponse, ErrorException(texte))
        _etat!(m, :pret)
    end
    return nothing
end

"""Commande reçue pendant une mesure : refusée, avec une alerte."""
function _refuser!(m::Moteur, c::Commande, pourquoi::AbstractString)
    texte = "commande $(nameof(typeof(c))) ignorée : $pourquoi"
    publier!(m, Alerte(:avertissement, -1, texte))
    c isa Verifier && c.reponse !== nothing && put!(c.reponse, ErrorException(texte))
    return nothing
end

"""Relit le fichier de réglages (s'il y en a un) ; garde les précédents s'il est illisible."""
function _reglages_courants!(m::Moteur, ctx::Contexte)
    f = ctx.reglages.fichier
    (isempty(f) || !isfile(f)) && return ctx.reglages
    try
        r = lire_reglages(f)
        r.source, r.rejeu = ctx.reglages.source, ctx.reglages.rejeu      # la source ne change pas en route
        ctx.reglages = r
    catch e
        publier!(m, Alerte(:avertissement, -1, "réglages illisibles ($f), je garde les précédents : " * _texte_erreur(e)))
    end
    return ctx.reglages
end

# ---------------------------------------------------------------------
# Taux et surveillance
# ---------------------------------------------------------------------

function _taux!(m::Moteur, src::Source, ctx::Contexte, modules, fifo::Bool)
    seuil = ctx.reglages.seuil_cfd
    for k in modules
        v = lire_taux(src, k)
        s = lire_sync(src, k)
        f = fifo ? lire_remplissage(src, k) : 0.0
        publier!(m, Taux(k, time(), v.sync, v.cfd, v.tac, v.adc, f, s, fifo, v.code >= 0))
        _surveiller!(m, ctx, k, s, v, seuil)
    end
    return nothing
end

"""Alertes sur les transitions seulement : SYNC perdu ou rétabli, chute du CFD."""
function _surveiller!(m::Moteur, ctx::Contexte, k::Int, s::Int, v, seuil::Float64)
    sync_ok = s == 1
    avant = get(ctx.sync_ok, k, true)
    if !sync_ok && avant
        publier!(m, Alerte(:erreur, k, "module $k : SYNC perdu ($(get(MESSAGES_SYNC, s, "état $s"))) : laser coupé, ou câble du SYNC ?"))
    elseif sync_ok && !avant
        publier!(m, Alerte(:info, k, "module $k : SYNC rétabli"))
    end
    ctx.sync_ok[k] = sync_ok
    v.code >= 0 || return nothing
    haut = v.cfd >= seuil
    avant = get(ctx.cfd_ok, k, true)
    if !haut && avant
        publier!(m, Alerte(:erreur, k, @sprintf("module %d : chute du CFD (%.3g /s, seuil %.3g /s) : coupure par surcharge dans le logiciel DCC ? Vérifie « Enable outputs ».",
                                                k, v.cfd, seuil)))
    elseif haut && !avant
        publier!(m, Alerte(:info, k, @sprintf("module %d : CFD rétabli (%.3g /s)", k, v.cfd)))
    end
    ctx.cfd_ok[k] = haut
    return nothing
end

"""Une alerte par réglage que la carte n'a pas pris tel quel."""
function _signaler_tableau!(m::Moteur, k::Int, parametres, lus)
    for l in comparer_parametres(parametres, lus)
        l.statut == :ok && continue
        publier!(m, Alerte(:avertissement, k, _texte_ecart(k, l)))
    end
    return nothing
end

_texte_ecart(k, l) = l.statut == :absente ?
    "module $k : réglage non appliqué, clé $(l.cle) inconnue de la DLL (faute de frappe ?)" :
    @sprintf("module %d : réglage non appliqué, %s demandé %s, appliqué %.5g", k, l.cle, string(l.demande), l.applique)

"""Peigne de l'ADC sur la queue d'un déclin (du pic + 10 % à 90 % des canaux)."""
function _verifier_peigne!(m::Moteur, k::Int, h::AbstractVector)
    n = length(h)
    n >= 64 && sum(h) > 0 || return nothing
    a, b = argmax(h) + n ÷ 10, (9n) ÷ 10
    for g in (1, 2, 4, 8, 16)
        b - a + 1 >= 8g || continue
        p = ecart_peigne(h, a, b, g)
        if isfinite(p.sigma) && p.ecart > max(4 * p.sigma, 0.03)
            publier!(m, Alerte(:avertissement, k, @sprintf("module %d : peigne de l'ADC (écart %.1f %% par groupes de %d canaux, %.0f σ) : correction de l'ADC coupée (dither_range = 0) ?",
                                                        k, 100 * p.ecart, g, p.ecart / p.sigma)))
            return nothing
        end
    end
    return nothing
end

# ---------------------------------------------------------------------
# Vérification
# ---------------------------------------------------------------------

"""Canal d'un n° de série : sa place dans [verification] series (0 : absent)."""
canal_serie(r::Reglages, serie::AbstractString) = something(findfirst(==(serie), r.series), 0)

"""
Modules prêts dans l'ordre des canaux : celui dont le n° de série est
`series[1]`, puis `series[2]`… Les n° de module peuvent changer avec les
châssis, pas les n° de série. Si aucune carte prête n'a un n° de série de
la liste (simulation, rejeu ancien), l'ordre des modules.
"""
function _cartes_par_canal(ctx::Contexte, r::Reglages)
    par_serie = [k for s in r.series for k in ctx.prets if get(ctx.series, k, "") == s]
    return isempty(par_serie) ? sort(ctx.prets) : unique(par_serie)
end

function _verifier!(m::Moteur, src::Source, ctx::Contexte, reponse)
    r = _reglages_courants!(m, ctx)
    parametres, _ = parametres_imagerie(r, geometrie(r))
    dossier = joinpath(dossier_spc(r), "moteur")
    mkpath(dossier)
    cartes = EtatCarte[]
    problemes = String[]
    for k in sort!(unique(vcat(r.modules_imagerie, r.modules_single)))
        k in ctx.detectes || push!(problemes, "module $k non détecté (modules vus : $(ctx.detectes))")
    end
    for k in ctx.detectes
        etat = explication_init(get(ctx.etats, k, -1))
        if !(k in ctx.prets)
            push!(problemes, "module $k pas prêt : $etat")
            push!(cartes, EtatCarte(k, false, etat, 0, "", 0, -1, NaN, LigneTableau[]))
            continue
        end
        id = identifier(src, k)
        ctx.series[k] = id.serie
        s = lire_sync(src, k)
        ctx.sync_ok[k] = s == 1
        s == 1 || push!(problemes, "module $k : $(get(MESSAGES_SYNC, s, "SYNC état $s")) (laser allumé ? câble du SYNC ?)")
        lus = configurer!(src, k, parametres, joinpath(dossier, "verification_module$(k).ini"))
        tableau = LigneTableau[l for l in comparer_parametres(parametres, lus)]
        for l in tableau
            l.statut == :ok || push!(problemes, _texte_ecart(k, l))
        end
        push!(cartes, EtatCarte(k, true, etat, id.type, id.serie, canal_serie(r, id.serie), s, NaN, tableau))
    end
    # Les cartes sont identifiées par n° de série : chaque canal doit trouver la sienne.
    if est_materiel(src)
        for (i, serie) in enumerate(r.series)
            any(c -> c.pret && c.serie == serie, cartes) ||
                push!(problemes, "canal $i : carte n° $serie introuvable ou pas prête (vues : $(join([c.serie for c in cartes if c.pret], ", ")))")
        end
    end

    # CFD : des coups, laser allumé, sinon les détecteurs sont éteints.
    prets = [c for c in cartes if c.pret]
    foreach(c -> effacer_taux!(src, c.carte), prets)
    isempty(prets) || !est_materiel(src) || sleep(Float64(get(r.spc, "rate_count_time", 1.0)) + 0.15)
    for c in prets
        v = lire_taux(src, c.carte)
        c.cfd = v.code >= 0 ? v.cfd : NaN
        ctx.cfd_ok[c.carte] = v.code >= 0 && v.cfd >= r.seuil_cfd
        if v.code < 0
            push!(problemes, "module $(c.carte) : taux pas prêts ($(v.code))")
        elseif v.cfd < r.seuil_cfd
            push!(problemes, @sprintf("module %d : CFD %.3g /s sous le seuil (%.3g /s) : détecteurs éteints ? « Enable outputs » dans le logiciel DCC",
                                      c.carte, v.cfd, r.seuil_cfd))
        end
    end

    etat = EtatCartes(nom_source(src), cartes, isempty(problemes), problemes, time())
    publier!(m, etat)
    foreach(p -> publier!(m, Alerte(:avertissement, -1, p)), problemes)
    reponse === nothing || put!(reponse, etat)
    return etat
end

function _deverrouiller!(m::Moteur, src::Source, ctx::Contexte)
    v = verrouilles(src)
    if isempty(v)
        publier!(m, Alerte(:info, -1, "aucun module verrouillé"))
    else
        forcer!(src, v)
        publier!(m, Alerte(:avertissement, -1, "modules $v repris de force (SPCM doit être fermé)"))
        _modules!(ctx, etat_modules(src))
        _signaler_modules!(m, ctx)
    end
    _verifier!(m, src, ctx, nothing)
    return nothing
end

# ---------------------------------------------------------------------
# Imagerie
# ---------------------------------------------------------------------

"""Une carte pendant une acquisition d'imagerie."""
mutable struct AcqModule
    carte::Int
    prefixe::String
    tic_s::Float64
    fenetre_ns::Float64
    dt_ns::Float64
    ecrivain::Union{Nothing,EcrivainSpc}
    etalonnage::Etalonnage
    alerte_etalonnage::Bool
    rangeur::Union{Nothing,Rangeur}
    geo::Any
    pool::Union{Nothing,PoolTrames}
    deborde::Bool
    trames::Int
    mots::Int
    debut::Float64
    mots_gardes::Union{Nothing,Vector{UInt16}}   # flux rangé dans l'image (Imagerie(...; garder_mots))
    serie::Union{Nothing,String}
end

# Au-delà, les mots gardés pour mesurer la géométrie sont jetés (scanner arrêté).
const MOTS_ETALONNAGE_MAX = 1 << 24

function _imagerie!(m::Moteur, src::Source, ctx::Contexte, c::Imagerie)
    r = _reglages_courants!(m, ctx)
    modules = [k for k in r.modules_imagerie if k in ctx.prets]
    if isempty(modules)
        texte = "imagerie : aucune des cartes $(r.modules_imagerie) n'est prête (prêtes : $(ctx.prets))"
        publier!(m, Alerte(:erreur, -1, texte))
        publier!(m, Fin(:imagerie, texte, true, String[], time()))
        return nothing
    end
    g = c.geometrie
    parametres, _ = parametres_imagerie(r, g)
    dossier = joinpath(dossier_spc(r), "imagerie")
    mkpath(dossier)
    horodatage = Dates.format(now(), "yyyymmdd_HHMMSS")
    tampon = zeros(UInt16, 1 << 20)
    acqs = AcqModule[]
    raison, erreur = "arrêtée", false
    debut = time()
    try
        for k in modules
            prefixe = joinpath(dossier, "$(horodatage)_module$(k)")
            lus = configurer!(src, k, parametres, prefixe * "_parametres.ini")
            _signaler_tableau!(m, k, parametres, lus)
            info = infos_fifo(src, k)
            fenetre = fenetre_tac(src, k, lus)
            ecrivain = r.flux_brut ? ouvrir_spc(prefixe * ".spc", info.entete) : nothing
            push!(acqs, AcqModule(k, prefixe, info.horloge_macro_s, fenetre, fenetre / 4096, ecrivain,
                                  Etalonnage(), false, nothing, nothing, nothing, false, 0, 0, 0.0,
                                  c.garder_mots ? UInt16[] : nothing, get(ctx.series, k, nothing)))
            effacer_taux!(src, k)
        end
        _etat!(m, :imagerie)
        debut = time()
        for a in acqs
            a.debut = debut
            lancer!(src, a.carte)
        end
        prochain_taux = debut + PERIODE_TAUX
        while true
            m.arret[] && break
            cmd = _prochaine_commande(m)
            cmd isa Arret && break
            cmd === nothing || _refuser!(m, cmd, "imagerie en cours")
            if isfinite(c.duree) && time() - debut >= c.duree
                raison = "durée écoulée"
                break
            end
            if c.trames > 0 && all(a -> a.rangeur !== nothing && a.rangeur.trames_completes >= c.trames, acqs)
                raison = "$(c.trames) trames"
                break
            end
            for a in acqs
                _traiter_mots!(m, a, tampon, lire_mots!(src, a.carte, tampon), g)
                if !a.deborde && (lire_etat(src, a.carte) & SPC_FOVFL) != 0
                    a.deborde = true
                    publier!(m, Alerte(:erreur, a.carte, "module $(a.carte) : FIFO débordé, des photons sont perdus : baisse la lumière"))
                end
            end
            if all(a -> epuisee(src, a.carte), acqs)
                raison = "fin du rejeu"
                break
            end
            if time() >= prochain_taux
                _taux!(m, src, ctx, modules, true)
                prochain_taux += PERIODE_TAUX
            end
            sleep(0.005)
        end
    catch e
        raison, erreur = _texte_erreur(e), true
        @error "Imagerie interrompue" exception = (e, catch_backtrace())
        publier!(m, Alerte(:erreur, -1, "imagerie interrompue : " * raison))
    finally
        # Lire avant d'arrêter : l'arrêt vide le FIFO.
        for a in acqs
            try
                erreur || _traiter_mots!(m, a, tampon, lire_mots!(src, a.carte, tampon), g)
            catch e
                erreur || publier!(m, Alerte(:erreur, a.carte, "dernière lecture du FIFO : " * _texte_erreur(e)))
            end
            try
                stopper!(src, a.carte)
            catch e
                publier!(m, Alerte(:erreur, a.carte, "arrêt de la mesure : " * _texte_erreur(e)))
            end
        end
    end

    fichiers = String[]
    duree = time() - debut
    for a in acqs
        try
            _finir_acquisition!(m, a, r, g, duree, fichiers)
        catch e
            erreur = true
            @error "Fichiers du module $(a.carte)" exception = (e, catch_backtrace())
            publier!(m, Alerte(:erreur, a.carte, "fichiers du module $(a.carte) : " * _texte_erreur(e)))
        end
    end
    publier!(m, Fin(:imagerie, raison, erreur, fichiers, time()))
    _etat!(m, :pret)
    return nothing
end

function _traiter_mots!(m::Moteur, a::AcqModule, tampon::Vector{UInt16}, n::Integer, g::Geometrie)
    n > 0 || return nothing
    a.ecrivain === nothing || ajouter_spc!(a.ecrivain, tampon, n)
    a.mots += n
    publier(r, complete) = _publier_trame!(m, a, r, complete)
    if a.rangeur !== nothing
        a.mots_gardes === nothing || append!(a.mots_gardes, view(tampon, 1:n))
        ranger!(publier, a.rangeur, tampon, n)
        return nothing
    end
    # Géométrie pas encore mesurée : on garde les mots jusqu'à une trame complète.
    ajouter_etalonnage!(a.etalonnage, tampon, n)
    geo = geometrie_etalonnee(a.etalonnage, a.tic_s, g)
    if geo === nothing
        if !a.alerte_etalonnage && time() - a.debut > 2.0
            a.alerte_etalonnage = true
            publier!(m, Alerte(:erreur, a.carte, "module $(a.carte) : pas d'horloge de ligne (M1) ou de trame (M2) depuis 2 s : scanner arrêté ?"))
        end
        length(a.etalonnage.mots) > MOTS_ETALONNAGE_MAX && reinitialiser_etalonnage!(a.etalonnage)
        return nothing
    end
    a.geo = geo
    if g.lignes_par_image == 0
        publier!(m, geo.reglage === nothing ?
            Alerte(:avertissement, a.carte, "module $(a.carte) : $(geo.lignes_trame) lignes par trame, réglage du scanner absent de " *
                   "[imagerie] reglages_scanner : image de $(geo.ny) lignes ($(geo.lignes_trame) − decalage_lignes " *
                   "$(g.decalage_lignes)) ; mesure ce réglage avec scripts/spc/horloges_scanner.jl") :
            Alerte(:info, a.carte, "module $(a.carte) : réglage du scanner de $(geo.reglage[2]) lignes ($(geo.lignes_trame) lignes " *
                   "par trame, $(geo.reglage[3]) ignorées en haut)"))
    end
    a.rangeur = Rangeur(geo, a.tic_s, a.dt_ns, g)
    a.pool = _nouveau_pool!(m, a.carte, geo.ny, geo.nx, a.dt_ns)
    mots = a.etalonnage.mots
    a.etalonnage = Etalonnage()
    a.mots_gardes === nothing || append!(a.mots_gardes, mots)
    ranger!(publier, a.rangeur, mots, length(mots))
    return nothing
end

function _publier_trame!(m::Moteur, a::AcqModule, r::Rangeur, complete::Bool)
    a.trames += 1
    t = _acquerir!(a.pool)
    if t === nothing
        Threads.atomic_add!(m.trames_sautees, 1)
        return nothing
    end
    copyto!(t.intensite, r.intensite)
    copyto!(t.somme_t, r.somme_t)
    copyto!(t.declin, r.declin)
    t.numero = r.numero
    t.complete = complete
    t.dt_ns = a.dt_ns
    t.photons = r.photons_trame
    t.dans_image = r.dans_image_trame
    t.pertes = r.pertes_trame
    t.fifo_deborde = a.deborde
    t.t_s = r.t_debut_trame * a.tic_s
    publier!(m, t) || _rendre!(a.pool, t)
    return nothing
end

"""Fin d'une acquisition pour une carte : dernière trame, fichiers, contrôles."""
function _finir_acquisition!(m::Moteur, a::AcqModule, r::Reglages, g::Geometrie, duree, fichiers)
    a.rangeur === nothing || terminer!((rg, complete) -> _publier_trame!(m, a, rg, complete), a.rangeur)
    a.ecrivain === nothing || push!(fichiers, fermer_spc!(a.ecrivain))
    push!(fichiers, ecrire_acquisition_ini(a.prefixe * "_acquisition.ini", a.carte, a.tic_s, a.fenetre_ns,
                                           duree, a.deborde; geometrie = g, dcc = r.dcc))
    isfile(a.prefixe * "_parametres.ini") && push!(fichiers, a.prefixe * "_parametres.ini")
    if a.rangeur === nothing
        publier!(m, Alerte(:avertissement, a.carte, "module $(a.carte) : aucune image (pas d'horloge de ligne ou de trame)" *
                                                    (a.ecrivain === nothing ? "" : " ; flux brut gardé : $(a.prefixe).spc")))
        return nothing
    end
    rg = a.rangeur
    res = (intensite = rg.intensite_tot, somme_t = rg.somme_t_tot, declin = declin_total(rg),
           photons = rg.decodeur.photons, dans_image = rg.dans_image, pertes = rg.decodeur.pertes,
           trames = rg.trames_completes, lignes_trame = a.geo.lignes_trame, pixels_ligne = a.geo.pixels_ligne,
           periode_ligne_s = a.geo.periode * a.tic_s, nx = rg.nx, ny = rg.ny)
    # La géométrie appliquée (lignes et marge du haut du réglage du scanner reconnu) : de quoi refaire le rangement.
    resolue = Geometrie(g.temps_pixel_ns, rg.nx, g.decalage_pixels, rg.ny, rg.decalage_lignes,
                        g.ligne_front_montant, g.trame_front_montant, copy(g.reglages_scanner))
    serie = something(a.serie, "")
    publier!(m, ImageSomme(a.carte, serie, canal_serie(r, serie), res.intensite, res.somme_t, res.declin, a.dt_ns,
                           a.tic_s, res.trames, resolue, something(a.mots_gardes, UInt16[])))
    ecrire_resultats_img(a.prefixe, res, a.dt_ns, a.carte, g, r.binning_temps, r.photons_min)
    append!(fichiers, a.prefixe .* ["_intensite.bmp", "_temps_moyen.bmp", "_declin.svg", ".jls"])
    _verifier_peigne!(m, a.carte, res.declin)
    publier!(m, Alerte(:info, a.carte, @sprintf("module %d : %d photons (%.3g /s), %d dans l'image, %d trames de %d × %d pixels, pertes %d",
                                               a.carte, res.photons, res.photons / max(duree, 1e-3), res.dans_image,
                                               res.trames, res.ny, res.nx, res.pertes)))
    return nothing
end

# ---------------------------------------------------------------------
# Single
# ---------------------------------------------------------------------

const RAISONS_FIN_SINGLE = SPC_OVERFL | SPC_TIME_OVER | SPC_COLTIM_OVER | SPC_CMD_STOP

function _single!(m::Moteur, src::Source, ctx::Contexte, c::Single)
    r = _reglages_courants!(m, ctx)
    modules = [k for k in r.modules_single if k in ctx.prets]
    if isempty(modules) || c.n < 1 || !(c.temps_s > 0)
        texte = isempty(modules) ? "Single : aucune des cartes $(r.modules_single) n'est prête (prêtes : $(ctx.prets))" :
                                   "Single : temps de collecte et nombre d'histogrammes positifs"
        publier!(m, Alerte(:erreur, -1, texte))
        publier!(m, Fin(:single, texte, true, String[], time()))
        return nothing
    end
    parametres, _ = parametres_single(r, c.temps_s)
    dossier = joinpath(dossier_spc(r), "single")
    mkpath(dossier)
    debut_date = now()
    horodatage = Dates.format(debut_date, "yyyymmdd_HHMMSS")
    prefixe(k) = joinpath(dossier, "$(horodatage)_module$(k)")
    canaux, fenetre, serie = Dict{Int,Int}(), Dict{Int,Float64}(), Dict{Int,String}()
    lus = Dict{Int,Dict{String,Float64}}()
    H = Dict{Int,Matrix{UInt16}}()
    etats = Dict(k => zeros(UInt16, c.n) for k in modules)
    durees = Dict(k => zeros(c.n) for k in modules)
    faits, raison, erreur = 0, "terminée", false
    try
        for k in modules
            lus[k] = configurer!(src, k, parametres, prefixe(k) * "_parametres.ini")
            _signaler_tableau!(m, k, parametres, lus[k])
            s = lire_sync(src, k)
            s == 1 || publier!(m, Alerte(:avertissement, k, "module $k : $(get(MESSAGES_SYNC, s, "SYNC état $s")) ; sans SYNC, aucun photon n'est compté"))
            canaux[k] = preparer_memoire!(src, k, r.resolution_adc).canaux
            fenetre[k] = fenetre_tac(src, k, lus[k])
            serie[k] = identifier(src, k).serie
            H[k] = zeros(UInt16, canaux[k], c.n)
        end
        _etat!(m, :single)
        delai = 4 * c.temps_s + 5                        # le temps mort allonge la mesure
        prochain_taux = time() + PERIODE_TAUX
        for i in 1:c.n
            foreach(k -> effacer_page!(src, k), modules)
            foreach(k -> lancer!(src, k), modules)
            t0 = time()
            fin = Dict{Int,Tuple{UInt16,Float64}}()
            interrompue = false
            while length(fin) < length(modules)
                for k in modules
                    haskey(fin, k) && continue
                    s = lire_etat(src, k)
                    # Pendant les 50 premières ms, un module désarmé sans raison d'arrêt n'est pas encore armé.
                    fini = (s & SPC_ARMED) == 0 && ((s & RAISONS_FIN_SINGLE) != 0 || time() - t0 > 0.05)
                    fini && (fin[k] = (s, time() - t0))
                end
                length(fin) == length(modules) && break
                cmd = _prochaine_commande(m)
                if cmd isa Arret || m.arret[]
                    interrompue = true
                    break
                end
                cmd === nothing || _refuser!(m, cmd, "Single en cours")
                time() - t0 > delai && error("mesure encore en cours après $(round(delai; digits = 1)) s sur le(s) module(s) $([k for k in modules if !haskey(fin, k)])")
                if time() >= prochain_taux
                    _taux!(m, src, ctx, modules, false)
                    prochain_taux += PERIODE_TAUX
                end
                sleep(0.005)
            end
            if interrompue
                foreach(k -> stopper!(src, k), modules)
                raison = "arrêtée après $faits histogramme(s)"
                break
            end
            for k in modules
                h = lire_histo(src, k, canaux[k])
                r.inverser && (h = reverse(h))
                H[k][:, i] = h
                etats[k][i], durees[k][i] = fin[k]
                publier!(m, HistoSingle(k, i, c.n, h, fenetre[k] / canaux[k], fin[k][1], fin[k][2],
                                        texte_fin_single(fin[k][1])))
            end
            faits = i
        end
    catch e
        raison, erreur = _texte_erreur(e), true
        @error "Single interrompu" exception = (e, catch_backtrace())
        publier!(m, Alerte(:erreur, -1, "Single interrompu : " * raison))
        for k in modules
            try
                stopper!(src, k)
            catch
            end
        end
    end

    fichiers = String[]
    if faits > 0
        for k in modules
            try
                append!(fichiers, _fichiers_single(prefixe(k), k, H[k][:, 1:faits], fenetre[k], canaux[k],
                                                   serie[k], lus[k], parametres, etats[k], durees[k], c, r, debut_date))
                _verifier_peigne!(m, k, vec(sum(Int.(H[k][:, 1:faits]); dims = 2)))
            catch e
                erreur = true
                publier!(m, Alerte(:erreur, k, "fichiers Single du module $k : " * _texte_erreur(e)))
            end
        end
    end
    publier!(m, Fin(:single, raison, erreur, fichiers, time()))
    _etat!(m, :pret)
    return nothing
end

"""CSV, SVG et paramètres relus d'une série Single, comme histogrammes_single.jl."""
function _fichiers_single(prefixe, k, H, fenetre, canaux, serie, lus, parametres, etats, durees, c::Single, r::Reglages, debut)
    N = size(H, 2)
    dt_ns = fenetre / canaux
    valeur(cle) = haskey(lus, cle) ? @sprintf("%g", lus[cle]) : string(parametres[cle])
    entete = String[
        "FLIMCore, Single, $(Dates.format(debut, "yyyy-mm-dd HH:MM:SS"))",
        "module $k, SPC-150N n° de série $serie",
        @sprintf("fenêtre TAC %.4f ns, %d canaux de %.4f ps ; temps_ns = centre du canal", fenetre, canaux, dt_ns * 1e3),
        "$N histogramme(s) de $(c.temps_s) s, chacun repart de zéro" *
            (r.inverser ? " ; courbes inversées (inverser = true)" : ""),
        "paramètres relus : " * join(("$cle = $(valeur(cle))" for cle in sort!(collect(keys(parametres)))), ", "),
    ]
    for i in 1:N
        push!(entete, @sprintf("h%d : %.2f s, %s", i, durees[i], texte_fin_single(etats[i])))
    end
    ecrire_csv_single(prefixe * ".csv", H, dt_ns, entete)
    svg_histo_single(prefixe * ".svg", dt_ns, H, "Module $k : $N × $(c.temps_s) s, $(sum(Int, H)) coups au total")
    return [prefixe * ".csv", prefixe * ".svg", prefixe * "_parametres.ini"]
end

# ---------------------------------------------------------------------
# Realtime (clamp) : FIFO, routage, passes marquées par les cartes
# ---------------------------------------------------------------------

"""
Publie un `HistoClamp` pour l'analyse. Sur les cartes, jamais d'attente :
jeté et compté si l'analyse ne suit pas. En rejeu, attend la place — rien
ne presse, et une passe sautée fausserait la relecture.
"""
function _publier_histo!(m::Moteur, h::HistoClamp; attendre::Bool = false)
    while Base.n_avail(m.histogrammes) >= m.histogrammes.sz_max
        if !attendre || m.arret[]
            Threads.atomic_add!(m.histos_perdus, 1)
            return false
        end
        sleep(0.002)
    end
    put!(m.histogrammes, h)
    return true
end

"""Ce qui empêche une commande `Clamp` de démarrer ("" : rien)."""
function _refus_clamp(c::Clamp, cartes)
    isempty(cartes) && return "Realtime : aucune carte prête"
    length(c.rois) > ROI_MAX && return "Realtime : $(length(c.rois)) ROI, le routage en distingue $ROI_MAX (le code 0 est réservé)"
    all(i -> 1 <= i <= ROI_MAX, c.rois) || return "Realtime : n° de ROI hors de 1 à $ROI_MAX : $(c.rois)"
    return ""
end

"""Une passe terminée d'une carte, en attente des autres cartes."""
struct PasseCarte
    t_debut_s::Float64
    t_fin_s::Float64
    histo::Matrix{UInt32}
    pertes::Int
    motifs::Vector{String}
end

"""
Une carte pendant une mesure Realtime. SPC_FOVFL : quand il apparaît, les
passes terminées à cette lecture et à la suivante, et celles commencées
avant la fin de la suivante (`fovfl_jusqua`, tics), ne nourrissent pas le
PI — la perte a pu se produire entre la lecture et le contrôle de l'état.
`decalage` : début de passe de cette carte moins celui de la première carte
(les horloges des cartes partent à des instants voisins et dérivent),
suivi d'une passe appariée à l'autre.
"""
mutable struct ClampCarte
    carte::Int
    serie::String
    nom::String
    tic_s::Float64
    passes::Passes
    file::Vector{PasseCarte}
    ecrivain::Union{Nothing,EcrivainSpc}
    deborde::Bool
    fovfl_vu::Bool
    fovfl_jusqua::Int64
    fovfl_etendre::Bool
    decalage::Float64
    sans_partenaire::Int
    hors_duree::Int
    mots::Int
end

ClampCarte(carte, serie, nom, tic_s, passes, ecrivain) =
    ClampCarte(carte, serie, nom, tic_s, passes, PasseCarte[], ecrivain, false, false, typemin(Int64), false, NaN, 0, 0, 0)

"""Les compteurs de la carte `a` (canal `canal`), pour `EtatClamp`."""
function _compteurs(a::ClampCarte, canal::Int)
    p = a.passes
    s(x) = x < 0 ? NaN : x * a.tic_s
    return CompteursCarte(a.carte, a.serie, canal, a.tic_s, a.mots, p.decodeur.photons, copy(p.marqueurs_vus),
                          copy(p.photons_par_code), p.hors_roi, p.hors_passe, p.numero, p.passes_abandonnees,
                          p.decodeur.pertes, a.deborde, s(p.duree_min), s(p.duree_max), s(p.duree_derniere),
                          a.hors_duree, a.sans_partenaire, length(a.file))
end

_etat_clamp(cartes::Vector{ClampCarte}, codes, c::Clamp, debut, publiees, fin::Bool) =
    EtatClamp(time(), time() - debut, fin, collect(codes), c.scan_s, c.pause_s, tolerance_passe(c),
              [_compteurs(a, k) for (k, a) in enumerate(cartes)], publiees)

function _clamp!(m::Moteur, src::Source, ctx::Contexte, c::Clamp)
    r = _reglages_courants!(m, ctx)
    modules = _cartes_par_canal(ctx, r)
    refus = _refus_clamp(c, modules)
    if !isempty(refus)
        publier!(m, Alerte(:erreur, -1, refus))
        publier!(m, Fin(:clamp, refus, true, String[], time()))
        return nothing
    end
    parametres, _ = parametres_clamp(r)
    enregistrer = !isempty(c.dossier)
    dossier = enregistrer ? c.dossier : joinpath(dossier_spc(r), "moteur")
    mkpath(dossier)
    codes = isempty(c.rois) ? [CODE_SANS_ROI] : [code_routage(i) for i in c.ordre]
    tampon = zeros(UInt16, 1 << 20)
    cartes = ClampCarte[]
    fichiers = String[]
    raison, erreur = "arrêtée", false
    passes = 0
    dt_ns = NaN
    debut = time()
    attendre = !est_materiel(src)
    try
        preparer_passes!(src, modules, codes, c.scan_s, c.pause_s)
        for (canal, k) in enumerate(modules)
            serie = get(ctx.series, k, "")
            nom = isempty(serie) ? "module$k" : serie
            lus = configurer!(src, k, parametres, joinpath(dossier, "$(nom)_parametres.ini"))
            _signaler_tableau!(m, k, parametres, lus)
            info = infos_fifo(src, k)
            fenetre = fenetre_tac(src, k, lus)
            isnan(dt_ns) && (dt_ns = fenetre / r.canaux_clamp)
            ecrivain = nothing
            if enregistrer
                ecrivain = ouvrir_spc(joinpath(dossier, nom * ".spc"), info.entete)
                push!(fichiers, joinpath(dossier, "$(nom)_parametres.ini"))
            end
            push!(cartes, ClampCarte(k, serie, nom, info.horloge_macro_s, Passes(canaux = r.canaux_clamp), ecrivain))
            effacer_taux!(src, k)
        end
        _etat!(m, :clamp)
        debut = time()
        foreach(a -> lancer!(src, a.carte), cartes)
        prochain_taux = debut + PERIODE_TAUX
        prochain_etat = debut + PERIODE_ETAT_CLAMP
        while true
            m.arret[] && break
            cmd = _prochaine_commande(m)
            cmd isa Arret && break
            cmd === nothing || _refuser!(m, cmd, "Realtime en cours")
            if time() >= prochain_etat
                publier!(m, _etat_clamp(cartes, codes, c, debut, passes, false))
                prochain_etat += PERIODE_ETAT_CLAMP
            end
            for a in cartes
                avant = length(a.file)
                _lire_passes!(src, a, tampon, c)
                _surveiller_fovfl!(m, a, (lire_etat(src, a.carte) & SPC_FOVFL) != 0, avant)
            end
            passes += _publier_passes!(m, cartes, dt_ns, attendre)
            if all(a -> epuisee(src, a.carte), cartes)
                raison = "fin du rejeu"
                break
            end
            if time() >= prochain_taux
                _taux!(m, src, ctx, modules, true)
                prochain_taux += PERIODE_TAUX
            end
            sleep(0.002)
        end
    catch e
        raison, erreur = _texte_erreur(e), true
        @error "Realtime interrompu" exception = (e, catch_backtrace())
        publier!(m, Alerte(:erreur, -1, "Realtime interrompu : " * raison))
    finally
        for a in cartes
            try
                erreur || _lire_passes!(src, a, tampon, c)    # avant l'arrêt, qui vide le FIFO
            catch
            end
            try
                stopper!(src, a.carte)
            catch e
                publier!(m, Alerte(:erreur, a.carte, "arrêt de la mesure : " * _texte_erreur(e)))
            end
        end
    end
    try
        # Les événements du dernier tic attendaient la lecture suivante : il n'y en aura plus.
        for a in cartes
            terminer_passes!((p, t0, t1, pertes) -> _ranger_passe!(a, p, t0, t1, pertes, c), a.passes)
        end
        passes += _publier_passes!(m, cartes, dt_ns, attendre)
        isempty(cartes) || publier!(m, _etat_clamp(cartes, codes, c, debut, passes, true))
        for (canal, a) in enumerate(cartes)
            a.passes.passes_abandonnees > 0 &&
                publier!(m, Alerte(:avertissement, a.carte, "module $(a.carte) : $(a.passes.passes_abandonnees) passe(s) sans marqueur de fin, ignorées"))
            a.hors_duree > 0 &&
                publier!(m, Alerte(:avertissement, a.carte, "module $(a.carte) : $(a.hors_duree) passe(s) de durée M3 − M0 hors tolérance (marqueur perdu ou en trop), hors du PI"))
            a.sans_partenaire > 0 &&
                publier!(m, Alerte(:avertissement, a.carte, "module $(a.carte) : $(a.sans_partenaire) passe(s) sans passe correspondante sur l'autre carte, ignorées"))
            a.passes.hors_passe > 0 &&
                publier!(m, Alerte(:info, a.carte, "module $(a.carte) : $(a.passes.hors_passe) photons d'une ROI hors des passes (décalage entre le code et le signal de passe ?)"))
            a.ecrivain === nothing && continue
            push!(fichiers, fermer_spc!(a.ecrivain))
            push!(fichiers, ecrire_acquisition_ini(joinpath(dossier, a.nom * "_acquisition.ini"), a.carte, a.tic_s,
                                                   dt_ns * r.canaux_clamp, time() - debut, a.deborde;
                                                   dcc = r.dcc,
                                                   clamp = Dict{String,Any}("serie" => a.serie, "canal" => canal,
                                                                            "inverser_routage" => Int(r.inverser_routage),
                                                                            "canaux" => r.canaux_clamp,
                                                                            "passes" => a.passes.numero,
                                                                            "photons_hors_roi" => a.passes.hors_roi,
                                                                            "passes_hors_duree" => a.hors_duree,
                                                                            "passes_sans_partenaire" => a.sans_partenaire)))
        end
    catch e
        erreur = true
        @error "Fichiers du Realtime" exception = (e, catch_backtrace())
        publier!(m, Alerte(:erreur, -1, "fichiers du Realtime : " * _texte_erreur(e)))
    end
    publier!(m, Fin(:clamp, "$raison après $passes passe(s)", erreur, fichiers, time()))
    _etat!(m, :pret)
    return nothing
end

"""Lit le FIFO d'une carte, l'enregistre et range ses photons dans les passes."""
function _lire_passes!(src::Source, a::ClampCarte, tampon::Vector{UInt16}, c::Clamp)
    n = lire_mots!(src, a.carte, tampon)
    n > 0 || return nothing
    a.mots += n
    a.ecrivain === nothing || ajouter_spc!(a.ecrivain, tampon, n)
    passes!((p, t0, t1, pertes) -> _ranger_passe!(a, p, t0, t1, pertes, c), a.passes, tampon, n)
    return nothing
end

"""Une passe terminée de la carte `a` (temps en tics), avec ce qui l'exclut du PI."""
function _ranger_passe!(a::ClampCarte, p::Passes, t0::Int64, t1::Int64, pertes::Int, c::Clamp)
    motifs = String[]
    pertes > 0 && push!(motifs, "module $(a.carte) : GAP, $pertes enregistrement(s) perdus")
    t0 <= a.fovfl_jusqua && push!(motifs, "module $(a.carte) : FIFO débordé (SPC_FOVFL) pendant la passe")
    duree = (t1 - t0) * a.tic_s
    if isfinite(c.echantillon_s) && abs(duree - c.scan_s) > tolerance_passe(c)
        a.hors_duree += 1
        push!(motifs, "module $(a.carte) : M3 − M0 = $(round(duree * 1e3; digits = 4)) ms au lieu de $(round(c.scan_s * 1e3; digits = 4)) ms")
    end
    push!(a.file, PasseCarte(t0 * a.tic_s, t1 * a.tic_s, copy(p.histo), pertes, motifs))
    return nothing
end

"""
SPC_FOVFL après une lecture (`fovfl` : le bit, `avant` : les passes en file
avant cette lecture). Quand il apparaît : les passes terminées à cette
lecture sont exclues du PI, puis, après la lecture suivante, toutes celles
commencées jusque-là (la perte a pu se produire entre la lecture et le
contrôle de l'état). Les GAP marquent ensuite chaque perte à sa place.
"""
function _surveiller_fovfl!(m::Moteur, a::ClampCarte, fovfl::Bool, avant::Int)
    if a.fovfl_etendre
        a.fovfl_etendre = false
        _exclure_fovfl!(a, avant)
    end
    if fovfl && !a.fovfl_vu
        a.fovfl_etendre = true
        _exclure_fovfl!(a, avant)
        if !a.deborde
            a.deborde = true
            publier!(m, Alerte(:erreur, a.carte, "module $(a.carte) : FIFO débordé, des photons sont perdus : les passes touchées ne nourrissent pas le PI"))
        end
    end
    a.fovfl_vu = fovfl
    return nothing
end

function _exclure_fovfl!(a::ClampCarte, avant::Int)
    a.fovfl_jusqua = max(a.fovfl_jusqua, a.passes.dernier)
    motif = "module $(a.carte) : FIFO débordé (SPC_FOVFL) pendant la passe"
    for k in avant + 1:length(a.file)
        motif in a.file[k].motifs || push!(a.file[k].motifs, motif)
    end
    return nothing
end

"""
Publie les passes que toutes les cartes ont terminées. Le même signal de
passe arrive sur toutes ; chaque carte date ses passes avec sa propre
horloge, partie à un instant voisin. Les débuts de passe se correspondent
à une demi-durée de passe près, une fois retiré le décalage de chaque carte
(mesuré sur la première passe, puis suivi d'une passe à l'autre pour la
dérive des horloges). Une passe sans correspondante (marqueur perdu sur une
seule carte) est écartée. Rend le nombre de passes publiées.
"""
function _publier_passes!(m::Moteur, cartes::Vector{ClampCarte}, dt_ns::Float64, attendre::Bool)
    n = 0
    while !isempty(cartes) && all(a -> !isempty(a.file), cartes)
        tetes = [first(a.file) for a in cartes]
        ref = tetes[1].t_debut_s
        if isnan(cartes[1].decalage)
            foreach((a, t) -> a.decalage = t.t_debut_s - ref, cartes, tetes)
        end
        ecarts = [t.t_debut_s - ref - a.decalage for (a, t) in zip(cartes, tetes)]
        tolerance = minimum(t -> t.t_fin_s - t.t_debut_s, tetes) / 2
        if maximum(ecarts) - minimum(ecarts) > tolerance
            k = argmin(ecarts)                          # la plus ancienne n'a pas de correspondante
            popfirst!(cartes[k].file)
            cartes[k].sans_partenaire += 1
            cartes[k].sans_partenaire == 1 &&
                publier!(m, Alerte(:avertissement, cartes[k].carte, "module $(cartes[k].carte) : une passe sans correspondante sur l'autre carte (marqueur perdu ?), écartée"))
            continue
        end
        foreach((a, t) -> (popfirst!(a.file); a.decalage = t.t_debut_s - ref), cartes, tetes)
        n += 1
        numero = cartes[1].passes.numero - length(cartes[1].file)
        _publier_histo!(m, HistoClamp(numero, tetes[1].t_debut_s, tetes[1].t_fin_s, [a.carte for a in cartes],
                                      [a.serie for a in cartes], [t.histo for t in tetes], sum(t.pertes for t in tetes),
                                      dt_ns, reduce(vcat, (t.motifs for t in tetes))); attendre = attendre)
    end
    return n
end

# ---------------------------------------------------------------------
# Pour les scripts (lanceurs de scripts/spc)
# ---------------------------------------------------------------------

"""
    attendre_fin(m, mesure; delai_s=Inf, io=stdout, f=nothing) -> Fin

Lit les résultats jusqu'au `Fin` de `mesure` (:imagerie, :single ou
:moteur) : affiche les alertes sur `io` (`nothing` : rien), appelle `f(r)`
sur chaque résultat, puis rend les trames au moteur. Pour les scripts et le
REPL ; le GUI lit `m.resultats` à son rythme.
"""
function attendre_fin(m::Moteur, mesure::Symbol; delai_s::Real = Inf, io::Union{Nothing,IO} = stdout, f = nothing)
    t0 = time()
    while time() - t0 < delai_s
        r = recevoir(m)
        if r === nothing
            t = m.tache
            t !== nothing && istaskdone(t) && !isready(m.resultats) && error("le moteur SPC s'est arrêté : $(m.raison_arret)")
            sleep(0.005)
            continue
        end
        io === nothing || !(r isa Alerte) || println(io, r.gravite == :erreur ? "  ✖ " : r.gravite == :avertissement ? "  ▲ " : "  · ", r.texte)
        f === nothing || f(r)
        rendre!(m, r)
        r isa Fin && r.mesure == mesure && return r
    end
    error("pas de fin de $mesure en $delai_s s")
end

"""
    afficher_etat(etat; io=stdout)

La vérification, comme les scripts : chaque carte, puis le tableau « demandé
→ appliqué par la carte » avec les réglages refusés ou inconnus de la DLL.
"""
function afficher_etat(etat::EtatCartes; io::IO = stdout)
    println(io, "Source : ", etat.source, " — ", etat.ok ? "vérification réussie" : "$(length(etat.problemes)) problème(s)")
    valeur(a) = isnan(a) ? "—" : @sprintf("%.5g", a)
    for c in etat.cartes
        if !c.pret
            println(io, "Module $(c.carte) : pas prêt, $(c.etat_init)")
            continue
        end
        println(io, "Module $(c.carte) : n° de série $(c.serie), $(get(MESSAGES_SYNC, c.sync, "SYNC état $(c.sync)")), CFD $(valeur(c.cfd)) /s")
        for l in c.tableau
            note = l.statut == :absente ? "  ← CLÉ INCONNUE de la DLL, ligne ignorée (faute de frappe ?)" :
                   l.statut == :ecart ? "  ← DIFFÉRENT de la demande" : ""
            @printf(io, "  %-16s %10s → %-10s%s\n", l.cle, string(l.demande), valeur(l.applique), note)
        end
    end
    for p in etat.problemes
        println(io, "  • ", p)
    end
    return nothing
end
