# sources.jl — les sources de photons, derrière une même interface : les
# SPC-150N (SPCLite), le rejeu de fichiers .spc à vitesse réelle, une
# simulation ; la SPC-QC-104 dans source_qc.jl (une carte virtuelle par
# entrée). Le moteur ne voit pas la différence.
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
#   preparer_memoire!(s, m, bits, bits_routage) -> (canaux, courbes)
#   effacer_page!(s, m) ; lire_histo(s, m, n; bloc)
#   preparer_passes!(s, modules, codes, scan_s, pause_s)   simulation : les passes à fabriquer
#   verrouilles(s), forcer!(s, modules)
#   mesurer_taux!(s, modules, duree_s) -> Dict ou nothing   (QC-104 : photons comptés dans le flux)
#   message_ouverture(s)     ce que `ouvrir!` a vu d'anormal ("" : rien)
#   bilan_source!(s)         ce qu'elle a écarté pendant la mesure ("" : rien)

abstract type Source end

"""Nom court de la source, pour les messages et les fichiers."""
nom_source(::Source) = "source"
est_materiel(::Source) = false
epuisee(::Source, m) = false
message_ouverture(::Source) = ""

"""
Ce que la source a dû écarter depuis le bilan précédent ("" : rien), publié
à la fin de chaque mesure (QC-104 : photons hors de la fenêtre, d'une
entrée sans canal, enregistrements inconnus).
"""
bilan_source!(::Source) = ""

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

"""
Mémoire en courbes de 2^`bits` canaux, 2^`bits_routage` courbes par trame :
le routage choisit la courbe (le bloc) où va chaque photon.
"""
function preparer_memoire!(::SourceCartes, m::Integer, bits::Integer, bits_routage::Integer = 0)
    mem = SPCLite.configurer_memoire(m, bits, bits_routage)
    mem.longueur_bloc > 0 || error("module $m : mémoire mal configurée ($mem)")
    return (canaux = mem.longueur_bloc, courbes = mem.blocs_par_trame)
end

function effacer_page!(::SourceCartes, m::Integer)
    SPCLite.definir_page(m, 0)
    SPCLite.effacer_memoire(m; bloc = -1, page = 0)
    return nothing
end

lire_histo(::SourceCartes, m::Integer, n::Integer; bloc::Integer = 0) = SPCLite.lire_bloc(m, n; bloc = bloc, page = 0)

"""
Simulation seulement : les passes du Realtime à fabriquer (codes de routage
dans l'ordre de visite, durées de scan et de pause). Les cartes, elles,
reçoivent les marqueurs de passe et le routage par leurs entrées.
"""
preparer_passes!(::Source, modules, codes, scan_s, pause_s) = nothing

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
    single::Bool                  # mode histogramme (Single, clamp)
    bits_single::Int
    temps_single::Float64
    histo::Union{Nothing,Vector{Int}}   # 4096 canaux du dernier Single, temps croissant
    fini::Bool                    # tout livré, sans boucle
    serie::String                 # n° de série de la carte enregistrée
end

function FluxRejeu(mots::Vector{UInt16}, entete, tic_s, fenetre_ns; serie::AbstractString = "")
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
                     1, 0, 0, 0, 0.0, false, false, 12, 1.0, nothing, false, String(serie))
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
simulée à la n-ième lecture du FIFO ; `fovfl_a_lecture = n` : SPC_FOVFL
levé (et gardé) à partir de la n-ième lecture. `ouvertures`/`fermetures` comptent
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
    fovfl_a_lecture::Int
end

SourceRejeu(flux::Dict{Int,FluxRejeu}; nom::AbstractString = "rejeu", vitesse::Real = 1.0,
            boucle::Bool = true, trace::AbstractString = "") =
    SourceRejeu(flux, String(nom), Float64(vitesse), boucle, false, 0, 0, 0, 0, NaN, String(trace), 0)

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
        serie = get(lire_ini_textes(prefixe * "_acquisition.ini"; section = "clamp"), "serie", "")
        entete, mots = lire_spc(prefixe * ".spc")
        m = round(Int, get(meta, "module", Float64(i - 1)))
        haskey(flux, m) && error("rejeu : deux fichiers pour le module $m")
        flux[m] = FluxRejeu(mots, entete, meta["tic_s"], meta["fenetre_ns"]; serie = serie)
    end
    return SourceRejeu(flux; nom = "rejeu", vitesse = vitesse, boucle = boucle)
end

"""
    source_session(dossier; vitesse=1.0) -> SourceRejeu

Rejeu d'une session Realtime enregistrée (Playback) : les flux FIFO de ses
cartes (`dossier/spc/*.spc`, avec leurs _acquisition.ini), une seule fois,
marqueurs de passe et routage compris.
"""
function source_session(dossier::AbstractString; vitesse::Real = 1.0)
    rep = joinpath(dossier, "spc")
    isdir(rep) || error("session sans dossier spc/ : $dossier")
    fichiers = sort!([joinpath(rep, f) for f in readdir(rep) if endswith(lowercase(f), ".spc")])
    isempty(fichiers) && error("session sans flux .spc : $rep")
    return source_rejeu(fichiers; vitesse = vitesse, boucle = false)
end

"""
    source_simulation(modules; vitesse=1.0, series=String[], boucle=true) -> SourceRejeu

Un scanner imaginaire à 31,25 trames/s (576 lignes de 55,5 µs, tic de
25 ns) et un disque au centre de l'image, environ 5 × 10^5 photons/s par
carte : de quoi faire tourner le GUI sans les cartes. La carte `modules[i]`
porte le n° de série `series[i]` (comme [verification] series : le canal
i), "SIMULATION-<module>" sans. En Realtime, `preparer_passes!` remplace ces
flux par des passes ; `boucle = false` : une seule fois (session simulée).
"""
function source_simulation(modules::AbstractVector{<:Integer}; vitesse::Real = 1.0,
                           series::AbstractVector{<:AbstractString} = String[], boucle::Bool = true)
    flux = Dict{Int,FluxRejeu}()
    for (i, m) in enumerate(modules)
        mots = flux_synthetique(trames = 16, lignes_par_trame = 576, periode_ligne = 2222,
                                lignes_avant = 5, photons_par_ligne = 60, graine = 17 + i,
                                egalites = false, tau_ns = (1.2 + 0.3i, 3.0))
        flux[Int(m)] = FluxRejeu(mots, 0x00000000, 25e-9, 12.5; serie = i <= length(series) ? String(series[i]) : "")
    end
    return SourceRejeu(flux; nom = "simulation", vitesse = vitesse, boucle = boucle)
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

identifier(s::SourceRejeu, m::Integer) =
    (type = 151, serie = isempty(s.flux[m].serie) ? uppercase(s.nom) * "-$m" : s.flux[m].serie)

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
    f.histo = nothing
    return nothing
end

stopper!(s::SourceRejeu, m::Integer) = (s.flux[m].en_cours = false; nothing)

"""
Simulation : remplace le flux de chaque module par des passes (le
générateur de `flux_passes_synthetique`), une passe par créneau de la NI
avec le code de routage de sa ROI, un déclin propre à chaque ROI qui varie
lentement : de quoi faire tourner le Realtime sans les cartes. Sans effet
sur un rejeu de fichiers.
"""
function preparer_passes!(s::SourceRejeu, modules, codes, scan_s, pause_s)
    s.nom == "simulation" || return nothing
    passes = max(length(codes), ceil(Int, 20 / (scan_s + pause_s)))          # environ 20 s, puis en boucle
    for (i, m) in enumerate(modules)
        f = s.flux[m]
        mots = flux_passes_synthetique(codes = codes, passes = passes, scan_s = scan_s, pause_s = pause_s,
                                       tic_s = f.tic_s, fenetre_ns = f.fenetre_ns, graine = 100 + i,
                                       photons_pause_par_s = 1e4,
                                       tau_ns = (code, t) -> 1.8 + 0.25 * code + 0.15 * i + 0.2 * sin(2π * t / 15))
        s.flux[m] = FluxRejeu(mots, f.entete, f.tic_s, f.fenetre_ns; serie = f.serie)
    end
    return nothing
end

"""Bits de SPC_test_state simulés : armé tant que la mesure court."""
function lire_etat(s::SourceRejeu, m::Integer)
    f = s.flux[m]
    f.en_cours || return 0x0000
    if f.single
        ecoule = s.vitesse > 0 ? (time() - f.t0) * s.vitesse : Inf
        return ecoule >= f.temps_single ? SPC_TIME_OVER : SPC_ARMED
    end
    s.fovfl_a_lecture > 0 && s.lectures >= s.fovfl_a_lecture && return SPC_ARMED | SPC_FOVFL
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

preparer_memoire!(s::SourceRejeu, m::Integer, bits::Integer, bits_routage::Integer = 0) =
    (s.flux[m].bits_single = bits; (canaux = 1 << bits, courbes = 1 << bits_routage))
effacer_page!(::SourceRejeu, m) = nothing

"""Histogramme des photons du flux pendant le temps de collecte (temps croissant, comme la mémoire de la carte)."""
function lire_histo(s::SourceRejeu, m::Integer, n::Integer; bloc::Integer = 0)
    f = s.flux[m]
    if f.histo === nothing
        cible = f.t_dernier + round(Int64, f.temps_single / f.tic_s)
        mots = UInt16[]
        _avancer!(s, f, cible, typemax(Int) - 2) do w
            push!(mots, UInt16(w & 0xffff), UInt16(w >> 16))
        end
        f.histo = reverse(decoder!(Decodeur(), mots).adc)
        f.en_cours = false
    end
    bloc == 0 || return zeros(UInt16, n)
    groupe = 4096 ÷ n
    return UInt16[min(sum(view(f.histo, (k - 1) * groupe + 1:k * groupe)), 65535) for k in 1:n]
end

verrouilles(::SourceRejeu) = Int[]
forcer!(::SourceRejeu, modules) = nothing

function etat_modules(s::SourceRejeu)
    modules = sort!(collect(keys(s.flux)))
    return (code = 0, detectes = modules, prets = copy(modules), etats = Dict(m => 0 for m in modules))
end

"""
    source_depuis(r::Reglages) -> Source

La source que [source] type demande : "qc104", "cartes", "rejeu" ou "simulation".
"""
function source_depuis(r::Reglages)
    r.source == "qc104" && return SourceQC(QCDll())
    r.source == "cartes" && return SourceCartes()
    r.source == "rejeu" && return source_rejeu(r.rejeu; vitesse = r.vitesse)
    return source_simulation(sort!(unique(vcat(r.modules_imagerie, r.modules_single))); vitesse = r.vitesse, series = r.series)
end
