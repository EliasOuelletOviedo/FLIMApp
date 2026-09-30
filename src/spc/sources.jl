# sources.jl — les sources de photons, derrière une même interface : les
# SPC-150N (SPCLite), le rejeu de fichiers .spc à vitesse réelle, une
# simulation. Le moteur ne voit pas la différence ; la SPC-QC-104 viendra
# ici, plus tard, comme une source de plus.
#
# Seul le moteur appelle ces fonctions, et seulement sur des modules prêts
# (renvoyés par `ouvrir!`) : sur un module absent ou non initialisé, la DLL
# peut tuer Julia, et try/catch n'y peut rien.
#
#   ouvrir!(s, r)            -> (code, detectes, prets, etats)   SPC_init
#   fermer!(s)                arrêt, déverrouillage, SPC_close, même après une erreur
#   est_materiel(s)           vraies cartes ? (séries vérifiées, attente des taux)
#   identifier(s, m)         -> (type, serie)
#   configurer!(s, m, p, f)  -> paramètres relus dans la carte (f : fichier .ini relu)
#   fenetre_tac(s, m, lus)   -> fenêtre du TAC en ns
#   lire_taux(s, m)          -> (code, sync, cfd, tac, adc) ; effacer_taux!(s, m)
#   lire_sync(s, m), lire_remplissage(s, m), lire_etat(s, m)
#   infos_fifo(s, m)         -> (horloge_macro_s, entete)
#   lancer!(s, m), stopper!(s, m), lire_mots!(s, m, tampon) -> n, epuisee(s, m)
#   preparer_memoire!(s, m, bits) -> canaux ; effacer_page!(s, m) ; lire_histo(s, m, n)
#   verrouilles(s), forcer!(s, modules)

abstract type Source end

"""Nom court de la source, pour les messages et les fichiers."""
nom_source(::Source) = "source"
est_materiel(::Source) = false
epuisee(::Source, m) = false

# ---------------------------------------------------------------------
# Les SPC-150N
# ---------------------------------------------------------------------

"""
    SourceCartes()

Les SPC-150N, par SPCLite. `ouvrir!` fait SPC_init avec [spc_module] ;
`fermer!` arrête et déverrouille les seuls modules prêts, puis SPC_close.
"""
mutable struct SourceCartes <: Source
    ouverte::Bool
    dossier::String
end
SourceCartes() = SourceCartes(false, "")

nom_source(::SourceCartes) = "cartes"
est_materiel(::SourceCartes) = true

function ouvrir!(s::SourceCartes, r::Reglages)
    s.dossier = joinpath(dossier_spc(r), "moteur")
    mkpath(s.dossier)
    ini = ecrire_ini(joinpath(s.dossier, "init.ini"), r.spc)
    SPCLite.chemin_dll()                    # DLL absente : erreur lisible avant SPC_init
    code = SPCLite.initialiser(ini)
    s.ouverte = true                        # SPC_close sera appelé, même si SPC_init a échoué
    detectes = Int.(SPCLite.modules_detectes())
    etats = Dict(k => SPCLite.etat_init(k) for k in detectes)
    prets = [k for k in detectes if etats[k] == 0]
    return (code = code, detectes = detectes, prets = prets, etats = etats)
end

function fermer!(s::SourceCartes)
    s.ouverte || return nothing
    s.ouverte = false
    SPCLite.liberer()                       # modules prêts seulement ; SPC_close dans tous les cas
    return nothing
end

function identifier(::SourceCartes, m::Integer)
    type = SPCLite.type_module(m)
    serie = try
        SPCLite.eeprom(m).serie
    catch
        "?"
    end
    return (type = type, serie = String(serie))
end

function configurer!(::SourceCartes, m::Integer, parametres::AbstractDict, fichier::AbstractString)
    ini = ecrire_ini(splitext(fichier)[1] * "_demande.ini", parametres)
    SPCLite.appliquer_ini(m, ini)
    return SPCLite.lire_parametres(m; fichier = fichier)
end

fenetre_tac(::SourceCartes, m, lus::AbstractDict) =
    get(lus, "tac_range", 50.0) / get(lus, "tac_gain", 1.0)

lire_taux(::SourceCartes, m::Integer) = SPCLite.taux(m)
effacer_taux!(::SourceCartes, m::Integer) = (SPCLite.effacer_taux(m); nothing)
lire_sync(::SourceCartes, m::Integer) = SPCLite.sync_etat(m)
lire_remplissage(::SourceCartes, m::Integer) = SPCLite.remplissage_fifo(m)
lire_etat(::SourceCartes, m::Integer) = SPCLite.etat_mesure(m)
infos_fifo(::SourceCartes, m::Integer) = (i = SPCLite.fifo_init(m); (horloge_macro_s = i.horloge_macro_s, entete = UInt32(i.entete)))
lancer!(::SourceCartes, m::Integer) = (SPCLite.demarrer(m); nothing)
stopper!(::SourceCartes, m::Integer) = (SPCLite.arreter(m); nothing)
lire_mots!(::SourceCartes, m::Integer, tampon::Vector{UInt16}) = SPCLite.lire_fifo!(m, tampon)

function preparer_memoire!(::SourceCartes, m::Integer, bits::Integer)
    mem = SPCLite.configurer_memoire(m, bits, 0)
    mem.longueur_bloc > 0 || error("module $m : mémoire mal configurée ($mem)")
    return mem.longueur_bloc
end

function effacer_page!(::SourceCartes, m::Integer)
    SPCLite.definir_page(m, 0)
    SPCLite.effacer_memoire(m; bloc = -1, page = 0)
    return nothing
end

lire_histo(::SourceCartes, m::Integer, n::Integer) = SPCLite.lire_bloc(m, n; bloc = 0, page = 0)

"""Modules détectés restés verrouillés par un autre programme (état -6)."""
verrouilles(::SourceCartes) = Int[k for k in SPCLite.modules_detectes() if SPCLite.etat_init(k) == -6]

"""État des modules sans refaire SPC_init (après une reprise forcée) : comme `ouvrir!`."""
function etat_modules(::SourceCartes)
    detectes = Int.(SPCLite.modules_detectes())
    etats = Dict(k => SPCLite.etat_init(k) for k in detectes)
    return (code = 0, detectes = detectes, prets = [k for k in detectes if etats[k] == 0], etats = etats)
end

forcer!(::SourceCartes, modules) = (isempty(modules) || SPCLite.forcer_modules(Int16.(modules)); nothing)

# ---------------------------------------------------------------------
# Rejeu et simulation
# ---------------------------------------------------------------------

"""Suit le macrotemps d'un flux FIFO sans décoder les photons (mêmes règles que Decodeur)."""
function _temps_enregistrement(base::Int64, w::UInt32)
    invalide = (w >> 31) & 0x1 == 0x1
    mtov = (w >> 30) & 0x1 == 0x1
    mark = (w >> 28) & 0x1 == 0x1
    if invalide && mtov && !mark                     # débordements multiples
        base += SPCLite.PERIODE_MT * Int64(w & 0x0fffffff)
        return base, base
    end
    mtov && (base += SPCLite.PERIODE_MT)
    return base + Int64(w & 0x0fff), base
end

"""Un flux rejoué : les mots d'une carte, et où en est la lecture."""
mutable struct FluxRejeu
    mots::Vector{UInt16}
    entete::UInt32
    tic_s::Float64
    fenetre_ns::Float64
    photons_par_s::Float64
    position::Int                 # prochain mot à livrer
    base::Int64                   # macrotemps : débordements cumulés
    t_dernier::Int64              # macrotemps du dernier enregistrement livré
    t_origine::Int64              # macrotemps au lancement
    t0::Float64                   # heure du lancement
    en_cours::Bool
    single::Bool                  # mode histogramme (Single)
    bits_single::Int
    temps_single::Float64
    fini::Bool                    # tout livré, sans boucle
end

function FluxRejeu(mots::Vector{UInt16}, entete, tic_s, fenetre_ns)
    mots = isodd(length(mots)) ? mots[1:end - 1] : mots
    d = decoder!(Decodeur(), mots)
    base = Int64(0)
    t_fin = Int64(0)
    for i in 1:2:length(mots) - 1
        t_fin, base = _temps_enregistrement(base, UInt32(mots[i]) | (UInt32(mots[i + 1]) << 16))
    end
    duree = t_fin * tic_s
    return FluxRejeu(mots, UInt32(entete), Float64(tic_s), Float64(fenetre_ns),
                     duree > 0 ? d.photons / duree : 0.0,
                     1, 0, 0, 0, 0.0, false, false, 12, 1.0, false)
end

"""
    SourceRejeu(flux; nom="rejeu", vitesse=1.0, boucle=true)

Rejoue des flux FIFO, un par module (`Dict{Int,FluxRejeu}`), à `vitesse`
fois le temps réel (0 : tout de suite). Avec `boucle`, le flux reprend au
début une fois fini, un débordement du macrotemps injecté entre deux tours
pour que le temps continue de croître. En Single, la « carte » range dans
un histogramme les photons du flux pendant le temps de collecte.

Taux : SYNC à 80 MHz, CFD, TAC et ADC au débit moyen de photons du flux
(`cfd_impose` le remplace, pour les tests). `panne_apres = n` : erreur
simulée à la n-ième lecture du FIFO. `ouvertures`/`fermetures` comptent
les SPC_init et SPC_close simulés, et `trace`, si non vide, est un fichier
où chacun est noté (tests d'arrêt brutal).
"""
mutable struct SourceRejeu <: Source
    flux::Dict{Int,FluxRejeu}
    nom::String
    vitesse::Float64
    boucle::Bool
    ouverte::Bool
    ouvertures::Int
    fermetures::Int
    lectures::Int
    panne_apres::Int
    cfd_impose::Float64
    trace::String
end

SourceRejeu(flux::Dict{Int,FluxRejeu}; nom::AbstractString = "rejeu", vitesse::Real = 1.0,
            boucle::Bool = true, trace::AbstractString = "") =
    SourceRejeu(flux, String(nom), Float64(vitesse), boucle, false, 0, 0, 0, 0, NaN, String(trace))

"""
    source_rejeu(fichiers; vitesse=1.0, boucle=true) -> SourceRejeu

Rejeu d'acquisitions enregistrées (prefixe.spc et prefixe_acquisition.ini) ;
le module de chacune est celui de son _acquisition.ini.
"""
function source_rejeu(fichiers::AbstractVector{<:AbstractString}; vitesse::Real = 1.0, boucle::Bool = true)
    isempty(fichiers) && error("rejeu : aucun fichier .spc dans [source] rejeu")
    flux = Dict{Int,FluxRejeu}()
    for (i, f) in enumerate(fichiers)
        prefixe = prefixe_acquisition(expanduser(f))
        isfile(prefixe * ".spc") || error("rejeu : introuvable : $(prefixe).spc")
        meta = lire_ini(prefixe * "_acquisition.ini"; section = "acquisition")
        entete, mots = lire_spc(prefixe * ".spc")
        m = round(Int, get(meta, "module", Float64(i - 1)))
        haskey(flux, m) && error("rejeu : deux fichiers pour le module $m")
        flux[m] = FluxRejeu(mots, entete, meta["tic_s"], meta["fenetre_ns"])
    end
    return SourceRejeu(flux; nom = "rejeu", vitesse = vitesse, boucle = boucle)
end

"""
    source_simulation(modules; vitesse=1.0) -> SourceRejeu

Un scanner imaginaire à 31,25 trames/s (576 lignes de 55,5 µs, tic de
25 ns) et un disque au centre de l'image, environ 5 × 10^5 photons/s par
carte : de quoi faire tourner le GUI sans les cartes.
"""
function source_simulation(modules::AbstractVector{<:Integer}; vitesse::Real = 1.0)
    flux = Dict{Int,FluxRejeu}()
    for (i, m) in enumerate(modules)
        mots = flux_synthetique(trames = 16, lignes_par_trame = 576, periode_ligne = 2222,
                                lignes_avant = 5, photons_par_ligne = 60, graine = 17 + i,
                                egalites = false, tau_ns = (1.2 + 0.3i, 3.0))
        flux[Int(m)] = FluxRejeu(mots, 0x00000000, 25e-9, 12.5)
    end
    return SourceRejeu(flux; nom = "simulation", vitesse = vitesse, boucle = true)
end

nom_source(s::SourceRejeu) = s.nom

function _tracer(s::SourceRejeu, texte)
    isempty(s.trace) && return nothing
    open(io -> println(io, texte), s.trace, "a")
    return nothing
end

function ouvrir!(s::SourceRejeu, ::Reglages)
    s.ouvertures += 1
    s.ouverte = true
    _tracer(s, "ouvrir")
    for f in values(s.flux)
        f.en_cours = false
        f.fini = false
    end
    modules = sort!(collect(keys(s.flux)))
    return (code = 0, detectes = modules, prets = copy(modules), etats = Dict(m => 0 for m in modules))
end

function fermer!(s::SourceRejeu)
    s.ouverte || return nothing
    s.ouverte = false
    s.fermetures += 1
    foreach(f -> (f.en_cours = false), values(s.flux))
    _tracer(s, "fermer")
    return nothing
end

identifier(s::SourceRejeu, m::Integer) = (type = 151, serie = uppercase(s.nom) * "-$m")

function configurer!(s::SourceRejeu, m::Integer, parametres::AbstractDict, fichier::AbstractString)
    f = s.flux[m]
    f.single = get(parametres, "mode", 1) == 0
    f.bits_single = Int(get(parametres, "adc_resolution", 12))
    f.temps_single = Float64(get(parametres, "collect_time", 1.0))
    lus = Dict{String,Float64}(String(k) => Float64(v) for (k, v) in parametres if v isa Real)
    # Le rejeu garde la fenêtre du TAC de l'acquisition, quels que soient les réglages.
    lus["tac_gain"] = get(lus, "tac_gain", 1.0)
    lus["tac_range"] = f.fenetre_ns * lus["tac_gain"]
    ecrire_ini(fichier, lus)
    return lus
end

fenetre_tac(s::SourceRejeu, m, lus) = s.flux[m].fenetre_ns

function lire_taux(s::SourceRejeu, m::Integer)
    cfd = isnan(s.cfd_impose) ? s.flux[m].photons_par_s : s.cfd_impose
    return (code = 0, sync = 8.0e7, cfd = cfd, tac = cfd, adc = cfd)
end
effacer_taux!(::SourceRejeu, m) = nothing
lire_sync(::SourceRejeu, m) = 1
lire_remplissage(::SourceRejeu, m) = 0.0
infos_fifo(s::SourceRejeu, m) = (horloge_macro_s = s.flux[m].tic_s, entete = s.flux[m].entete)
epuisee(s::SourceRejeu, m) = s.flux[m].fini

function lancer!(s::SourceRejeu, m::Integer)
    f = s.flux[m]
    f.en_cours = true
    f.t0 = time()
    f.t_origine = f.t_dernier
    return nothing
end

stopper!(s::SourceRejeu, m::Integer) = (s.flux[m].en_cours = false; nothing)

"""Bits de SPC_test_state simulés : armé tant que la mesure court."""
function lire_etat(s::SourceRejeu, m::Integer)
    f = s.flux[m]
    f.en_cours || return 0x0000
    if f.single
        ecoule = s.vitesse > 0 ? (time() - f.t0) * s.vitesse : Inf
        return ecoule >= f.temps_single ? SPC_TIME_OVER : SPC_ARMED
    end
    return SPC_ARMED
end

# Livre les enregistrements dont le macrotemps est <= cible, sans dépasser
# `place` mots ; reboucle au besoin. Appelle `livrer(w)` pour chacun.
function _avancer!(livrer, s::SourceRejeu, f::FluxRejeu, cible::Int64, place::Int)
    n = 0
    while n + 2 <= place
        if f.position > length(f.mots) - 1
            if !s.boucle
                f.fini = true
                break
            end
            w = BIT_INVALID | BIT_MTOV | 0x00000001      # un tour de plus : le temps continue de croître
            f.t_dernier, f.base = _temps_enregistrement(f.base, w)
            livrer(w)
            n += 2
            f.position = 1
            continue
        end
        w = UInt32(f.mots[f.position]) | (UInt32(f.mots[f.position + 1]) << 16)
        t, base = _temps_enregistrement(f.base, w)
        t > cible && break
        f.t_dernier, f.base = t, base
        livrer(w)
        n += 2
        f.position += 2
    end
    return n
end

function lire_mots!(s::SourceRejeu, m::Integer, tampon::Vector{UInt16})
    f = s.flux[m]
    (f.en_cours && !f.single) || return 0
    s.lectures += 1
    s.panne_apres > 0 && s.lectures >= s.panne_apres && error("rejeu : panne simulée à la lecture $(s.lectures)")
    cible = s.vitesse > 0 ? f.t_origine + floor(Int64, (time() - f.t0) * s.vitesse / f.tic_s) : typemax(Int64)
    k = 0
    return _avancer!(s, f, cible, length(tampon) - isodd(length(tampon))) do w
        tampon[k + 1] = UInt16(w & 0xffff)
        tampon[k + 2] = UInt16(w >> 16)
        k += 2
    end
end

preparer_memoire!(s::SourceRejeu, m::Integer, bits::Integer) = (s.flux[m].bits_single = bits; 1 << bits)
effacer_page!(::SourceRejeu, m) = nothing

"""Histogramme des photons du flux pendant le temps de collecte (temps croissant, comme la mémoire de la carte)."""
function lire_histo(s::SourceRejeu, m::Integer, n::Integer)
    f = s.flux[m]
    h = zeros(Int, n)
    decalage = 12 - round(Int, log2(n))
    cible = f.t_dernier + round(Int64, f.temps_single / f.tic_s)
    mots = UInt16[]
    _avancer!(s, f, cible, typemax(Int) - 2) do w
        push!(mots, UInt16(w & 0xffff), UInt16(w >> 16))
    end
    d = decoder!(Decodeur(), mots)
    for (i, c) in enumerate(d.adc)
        c == 0 && continue
        canal = (4095 - (i - 1)) >> decalage
        h[canal + 1] += c
    end
    f.en_cours = false
    return UInt16[min(x, 65535) for x in h]
end

verrouilles(::SourceRejeu) = Int[]
forcer!(::SourceRejeu, modules) = nothing

function etat_modules(s::SourceRejeu)
    modules = sort!(collect(keys(s.flux)))
    return (code = 0, detectes = modules, prets = copy(modules), etats = Dict(m => 0 for m in modules))
end

"""
    source_depuis(r::Reglages) -> Source

La source que [source] type demande : "cartes", "rejeu" ou "simulation".
"""
function source_depuis(r::Reglages)
    r.source == "cartes" && return SourceCartes()
    r.source == "rejeu" && return source_rejeu(r.rejeu; vitesse = r.vitesse)
    return source_simulation(sort!(unique(vcat(r.modules_imagerie, r.modules_single))); vitesse = r.vitesse)
end
