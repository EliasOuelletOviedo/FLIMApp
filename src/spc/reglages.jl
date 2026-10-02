# reglages.jl — le fichier de réglages des SPC-150N (config/spc.toml).
#
# Un seul fichier, relu par le moteur à chaque démarrage de mesure ; le GUI
# peut l'éditer et le réécrire (`ecrire_reglages`, qui garde les
# commentaires). Il remplace reglages_spc.jl : la section [spc_module]
# reprend ses clés, celles du manuel de la DLL SPCM.

"""
    Geometrie(; temps_pixel_ns=50.0, pixels_par_ligne=0, decalage_pixels=0,
              lignes_par_image=0, decalage_lignes=0,
              ligne_front_montant=true, trame_front_montant=true)

Rangement des photons en image, comme imagerie_photons.jl : horloge de
pixel interne (`temps_pixel_ns`), horloge de ligne sur M1, de trame sur M2.
`pixels_par_ligne = 0` : toute la période de ligne ; `lignes_par_image = 0` :
le nombre de lignes mesuré entre deux trames. Les décalages ignorent les
premiers pixels de chaque ligne et les premières lignes de chaque trame.
"""
Base.@kwdef struct Geometrie
    temps_pixel_ns::Float64 = 50.0
    pixels_par_ligne::Int = 1024
    decalage_pixels::Int = 21
    lignes_par_image::Int = 512
    decalage_lignes::Int = 32
    ligne_front_montant::Bool = true
    trame_front_montant::Bool = true
end

"""Réglages du détecteur et du TAC par défaut (reglages_spc.jl, plus rate_count_time)."""
const SPC_DEFAUT = Dict{String,Any}(
    "sync_threshold" => -70.9,
    "sync_zc_level" => -6.80,
    "sync_freq_div" => 1,
    "cfd_limit_low" => -139.22,
    "cfd_zc_level" => 12.85,
    "tac_range" => 50.034,
    "tac_gain" => 4,
    "tac_offset" => 3.33,
    "tac_limit_low" => 5.1,
    "tac_limit_high" => 94.9,
    "rate_count_time" => 0.25,
)

const COMMENTAIRES_SPC = Dict{String,String}(
    "sync_threshold" => "mV, seuil du SYNC (-500 à -20)",
    "sync_zc_level" => "mV, passage par zéro du SYNC (-96 à 96)",
    "sync_freq_div" => "diviseur du SYNC : 1, 2 ou 4",
    "cfd_limit_low" => "mV, seuil du CFD (-500 à 0)",
    "cfd_zc_level" => "mV, passage par zéro du CFD (-96 à 96)",
    "tac_range" => "ns (50 à 5000)",
    "tac_gain" => "1 à 15 ; fenêtre = tac_range / tac_gain (12,5 ns ici)",
    "tac_offset" => "% (0 à 50 pour la SPC-150N)",
    "tac_limit_low" => "% de la fenêtre",
    "tac_limit_high" => "% de la fenêtre",
    "rate_count_time" => "s, intégration des compteurs de taux (relus toutes les 0,5 s)",
)

"""Réglages du logiciel DCC déclarés : le GUI ne peut pas les lire, il les recopie dans chaque acquisition."""
const DCC_DEFAUT = Dict{String,Any}(
    "module" => "M1",
    "gain_c1_pourcent" => 82.0,
    "gain_c3_pourcent" => 82.0,
    "sorties_numeriques" => "b0",
    "refroidissement_v" => 5.0,
    "refroidissement_a" => 1.98,
)

"""
    Reglages

Contenu de config/spc.toml. `fichier` : d'où il vient ("" : en mémoire
seulement). Modifiable par le GUI, puis réécrit par `ecrire_reglages`. Le
moteur n'en garde jamais une référence partagée : il relit le fichier (ou
une copie) à chaque mesure.
"""
Base.@kwdef mutable struct Reglages
    fichier::String = ""
    # [source]
    source::String = "cartes"
    rejeu::Vector{String} = String[]
    vitesse::Float64 = 1.0
    connexion_au_demarrage::Bool = true
    # [spc_module]
    spc::Dict{String,Any} = copy(SPC_DEFAUT)
    # [verification]
    series::Vector{String} = ["3N0317", "3N0318"]
    seuil_cfd::Float64 = 100.0
    # [imagerie]
    modules_imagerie::Vector{Int} = [0, 1]
    duree_s::Float64 = 0.0
    temps_pixel_ns::Float64 = 50.0
    pixels_par_ligne::Int = 1024
    decalage_pixels::Int = 21
    lignes_par_image::Int = 512
    decalage_lignes::Int = 32
    ligne_front_montant::Bool = true
    trame_front_montant::Bool = true
    # [affichage]
    binning_temps::Int = 4
    photons_min::Int = 20
    trames_par_image::Int = 10
    # [single]
    modules_single::Vector{Int} = [0, 1]
    temps_collecte_s::Float64 = 1.0
    n_histogrammes::Int = 5
    resolution_adc::Int = 8
    arret_debordement::Bool = true
    inverser::Bool = false
    # [clamp]
    canaux_clamp::Int = 256
    inverser_routage::Bool = true
    # [enregistrement]
    dossier::String = ""
    flux_brut::Bool = true
    # [dcc]
    dcc::Dict{String,Any} = copy(DCC_DEFAUT)
end

"""
Clés du fichier, dans l'ordre où `ecrire_reglages` les écrit : (section,
clé, champ de `Reglages`, commentaire). [spc_module] et [dcc] sont libres.
"""
const CLES_REGLAGES = [
    ("source", "type", :source, "\"cartes\" (les SPC-150N), \"rejeu\" (fichiers .spc ci-dessous) ou \"simulation\""),
    ("source", "rejeu", :rejeu, "fichiers .spc à rejouer, un par carte (écrits par l'imagerie, avec leur _acquisition.ini)"),
    ("source", "vitesse", :vitesse, "rejeu et simulation : 1 = temps réel ; 0 = le plus vite possible"),
    ("source", "connexion_au_demarrage", :connexion_au_demarrage, "le GUI lance le moteur et vérifie les cartes à l'ouverture"),
    ("verification", "series", :series, "n° de série du canal 1 puis du canal 2 : identifient les cartes, quel que soit leur n° de module"),
    ("verification", "seuil_cfd", :seuil_cfd, "/s : en dessous, détecteurs éteints (Enable outputs dans le logiciel DCC ?)"),
    ("imagerie", "modules", :modules_imagerie, "cartes enregistrées"),
    ("imagerie", "duree_s", :duree_s, "0 : en continu jusqu'à « Arrêter »"),
    ("imagerie", "temps_pixel_ns", :temps_pixel_ns, "pixel_time de SPCM : horloge de pixel interne"),
    ("imagerie", "pixels_par_ligne", :pixels_par_ligne, "scan_size_x de SPCM : 1024"),
    ("imagerie", "decalage_pixels", :decalage_pixels, "scan_borders (gauche) de SPCM : pixels ignorés après chaque début de ligne (retour du balayage)"),
    ("imagerie", "lignes_par_image", :lignes_par_image, "scan_size_y de SPCM ; 0 : les lignes comptées entre deux marqueurs de trame (M2), moins decalage_lignes (scripts/spc/horloges_scanner.jl les mesure)"),
    ("imagerie", "decalage_lignes", :decalage_lignes, "scan_borders (haut) de SPCM : lignes ignorées après chaque début de trame"),
    ("imagerie", "ligne_front_montant", :ligne_front_montant, "front actif de l'horloge de ligne (M1)"),
    ("imagerie", "trame_front_montant", :trame_front_montant, "front actif de l'horloge de trame (M2)"),
    ("affichage", "binning_temps", :binning_temps, "pixels regroupés (n × n) pour le temps moyen"),
    ("affichage", "photons_min", :photons_min, "sous ce nombre de photons, pas de temps moyen"),
    ("affichage", "trames_par_image", :trames_par_image, "trames additionnées par image affichée ; 0 : tout depuis le début"),
    ("single", "modules", :modules_single, "cartes mesurées en même temps"),
    ("single", "temps_collecte_s", :temps_collecte_s, "durée de chaque histogramme"),
    ("single", "n_histogrammes", :n_histogrammes, "histogrammes successifs, chacun repart de zéro"),
    ("single", "resolution_adc", :resolution_adc, "8 bits = 256 canaux, la résolution des déclins du Realtime et de l'IRF"),
    ("single", "arret_debordement", :arret_debordement, "arrêt dès qu'un canal atteint 65535 coups"),
    ("single", "inverser", :inverser, "déclin à l'envers (montée lente, chute brutale) : true"),
    ("clamp", "canaux", :canaux_clamp, "canaux des déclins du Realtime (les 4096 du FIFO regroupés) : 256, la résolution de l'IRF"),
    ("clamp", "inverser_routage", :inverser_routage, "la NI écrit NON(c) sur P0.4-P0.7 et la carte, aux entrées actives à 0 V, lit c"),
    ("enregistrement", "dossier", :dossier, "\"\" : ~/FLIMApp_spc (sous-dossiers imagerie et single)"),
    ("enregistrement", "flux_brut", :flux_brut, "garder le flux FIFO de chaque carte (.spc) : environ 4 octets par photon"),
]

const EN_TETE_REGLAGES = """
# Réglages des SPC-150N pour FLIMCore (src/spc/FLIMCore.jl), relus à chaque
# démarrage de mesure. Le GUI réécrit ce fichier quand tu changes un réglage
# dans la fenêtre SPC : les commentaires sont regénérés, garde tes notes
# ailleurs.
#
# [spc_module] remplace reglages_spc.jl : recopie les valeurs de SPCM
# (panneau « System Parameters ») qui te donnent un beau déclin. Plages :
# manuel de la DLL SPCM, section [spc_module]. Une clé inconnue de la DLL
# est signalée par le tableau « demandé → appliqué ».
"""

"""Géométrie d'image des réglages (section [imagerie])."""
geometrie(r::Reglages) = Geometrie(r.temps_pixel_ns, r.pixels_par_ligne, r.decalage_pixels,
                                   r.lignes_par_image, r.decalage_lignes,
                                   r.ligne_front_montant, r.trame_front_montant)

"""Remplace les champs de géométrie de `r` par ceux de `g`."""
function geometrie!(r::Reglages, g::Geometrie)
    for f in fieldnames(Geometrie)
        setfield!(r, f, getfield(g, f))
    end
    return r
end

"""Dossier des acquisitions : `r.dossier`, ou ~/FLIMApp_spc."""
dossier_spc(r::Reglages) = isempty(r.dossier) ? joinpath(homedir(), "FLIMApp_spc") : expanduser(r.dossier)

_valeur_champ(::Type{T}, v) where {T} = convert(T, v)
_valeur_champ(::Type{Vector{String}}, v::AbstractVector) = String[String(x) for x in v]
_valeur_champ(::Type{Vector{Int}}, v::AbstractVector) = Int[Int(x) for x in v]
_valeur_champ(::Type{Float64}, v::Real) = Float64(v)
_valeur_champ(::Type{Int}, v::Real) = (isinteger(v) ? Int(v) : error("entier attendu, lu $v"))

"""
    reglages_depuis_dict(brut; fichier="") -> Reglages

Réglages à partir d'un fichier TOML déjà lu, par-dessus les valeurs par
défaut. Une section ou une clé inconnue est refusée (hors [spc_module] et
[dcc]), pour qu'une faute de frappe ne laisse pas un défaut en place.
"""
function reglages_depuis_dict(brut::AbstractDict; fichier::AbstractString = "")
    r = Reglages(fichier = String(fichier))
    champs = Dict((s, c) => champ for (s, c, champ, _) in CLES_REGLAGES)
    sections = Set(s for (s, _, _, _) in CLES_REGLAGES)
    for (section, valeurs) in brut
        valeurs isa AbstractDict || error("réglages SPC : [$section] doit être une table")
        if section == "spc_module"
            r.spc = Dict{String,Any}(String(k) => v for (k, v) in valeurs)
        elseif section == "dcc"
            r.dcc = Dict{String,Any}(String(k) => v for (k, v) in valeurs)
        else
            section in sections || error("réglages SPC : section [$section] inconnue")
            for (cle, v) in valeurs
                champ = get(champs, (section, cle), nothing)
                champ === nothing && error("réglages SPC : clé $cle inconnue dans [$section]")
                valeur = try
                    _valeur_champ(fieldtype(Reglages, champ), v)
                catch
                    error("réglages SPC : [$section] $cle = $(repr(v)) : type attendu $(fieldtype(Reglages, champ))")
                end
                setfield!(r, champ, valeur)
            end
        end
    end
    valider_reglages(r)
    return r
end

"""
    lire_reglages(chemin) -> Reglages

Lit config/spc.toml. Fichier absent : réglages par défaut (avec `fichier`
renseigné, pour que `ecrire_reglages` le crée).
"""
function lire_reglages(chemin::AbstractString)
    isfile(chemin) || return Reglages(fichier = abspath(chemin))
    return reglages_depuis_dict(TOML.parsefile(chemin); fichier = abspath(chemin))
end


"""Lève une erreur lisible pour une valeur hors plage."""
function valider_reglages(r::Reglages)
    r.source in ("cartes", "rejeu", "simulation") ||
        error("réglages SPC : [source] type = \"cartes\", \"rejeu\" ou \"simulation\", pas \"$(r.source)\"")
    r.vitesse >= 0 || error("réglages SPC : [source] vitesse doit être positive ou nulle")
    all(m -> 0 <= m <= 7, vcat(r.modules_imagerie, r.modules_single)) ||
        error("réglages SPC : numéros de modules de 0 à 7")
    r.duree_s >= 0 || error("réglages SPC : [imagerie] duree_s doit être positive ou nulle")
    r.temps_pixel_ns > 0 || error("réglages SPC : [imagerie] temps_pixel_ns doit être positif")
    min(r.decalage_pixels, r.decalage_lignes) >= 0 || error("réglages SPC : [imagerie] décalages positifs ou nuls")
    r.pixels_par_ligne == 1024 || error("réglages SPC : [imagerie] pixels_par_ligne (scan_size_x) : 1024")
    r.lignes_par_image >= 0 ||
        error("réglages SPC : [imagerie] lignes_par_image (scan_size_y) : un nombre de lignes, ou 0 pour celui de l'horloge de trame")
    r.binning_temps >= 1 || error("réglages SPC : [affichage] binning_temps d'au moins 1")
    r.photons_min >= 0 || error("réglages SPC : [affichage] photons_min positif ou nul")
    r.trames_par_image >= 0 || error("réglages SPC : [affichage] trames_par_image positif ou nul")
    r.temps_collecte_s > 0 || error("réglages SPC : [single] temps_collecte_s doit être positif")
    r.n_histogrammes >= 1 || error("réglages SPC : [single] n_histogrammes d'au moins 1")
    r.resolution_adc == 8 ||
        error("réglages SPC : [single] resolution_adc : 8 bits, des histogrammes de 256 canaux comme ceux du Realtime et de l'IRF")
    r.canaux_clamp in (64, 128, 256, 512, 1024, 4096) || error("réglages SPC : [clamp] canaux : 64 à 4096, un diviseur de 4096")
    return r
end

_toml_valeur(v::Bool) = v ? "true" : "false"
_toml_valeur(v::Integer) = string(Int(v))
_toml_valeur(v::AbstractFloat) = isinteger(v) && abs(v) < 1e15 ? @sprintf("%.1f", v) : repr(Float64(v))
_toml_valeur(v::AbstractString) = "\"" * replace(v, "\\" => "\\\\", "\"" => "\\\"") * "\""
_toml_valeur(v::AbstractVector) = "[" * join((_toml_valeur(x) for x in v), ", ") * "]"
_toml_valeur(v) = _toml_valeur(string(v))

function _ligne_toml(io, cle, valeur, commentaire)
    s = string(cle, " = ", _toml_valeur(valeur))
    isempty(commentaire) ? println(io, s) : println(io, rpad(s, 32), " # ", commentaire)
end

"""
    ecrire_reglages(chemin, r) -> chemin

Réécrit le fichier de réglages, commentaires compris (regénérés : ceux
ajoutés à la main sont perdus). Écriture dans un fichier temporaire puis
renommage : un moteur qui relit au même moment voit l'ancien ou le nouveau,
jamais un fichier à moitié écrit.
"""
function ecrire_reglages(chemin::AbstractString, r::Reglages)
    valider_reglages(r)
    mkpath(dirname(abspath(chemin)))
    temporaire = chemin * ".tmp"
    open(temporaire, "w") do io
        print(io, EN_TETE_REGLAGES)
        for section in unique(s for (s, _, _, _) in CLES_REGLAGES)
            println(io)
            println(io, "[", section, "]")
            for (s, cle, champ, commentaire) in CLES_REGLAGES
                s == section && _ligne_toml(io, cle, getfield(r, champ), commentaire)
            end
            section == "source" && _section_spc(io, r)    # [spc_module] juste après [source]
        end
        println(io)
        println(io, "[dcc]")
        println(io, "# Réglages du logiciel DCC autonome, déclarés ici : le GUI ne peut pas les")
        println(io, "# lire. Recopiés dans le _acquisition.ini de chaque acquisition.")
        for cle in sort!(collect(keys(r.dcc)))
            _ligne_toml(io, cle, r.dcc[cle], "")
        end
    end
    mv(temporaire, chemin; force = true)
    r.fichier = abspath(chemin)
    return chemin
end

function _section_spc(io, r::Reglages)
    println(io)
    println(io, "[spc_module]")
    for cle in sort!(collect(keys(r.spc)))
        _ligne_toml(io, cle, r.spc[cle], get(COMMENTAIRES_SPC, cle, ""))
    end
    return nothing
end

"""Copie indépendante (rien de partagé avec l'original)."""
copier_reglages(r::Reglages) = deepcopy(r)

# ---------------------------------------------------------------------
# Paramètres envoyés aux cartes (fichiers .ini de la DLL)
# ---------------------------------------------------------------------

"""Valeur de routing_mode pour les marqueurs M1 (ligne) et M2 (trame), fronts compris."""
function routage_marqueurs(g::Geometrie)
    return Int(0x0600 |                                        # marqueurs M1 et M2
               (g.ligne_front_montant ? 0x2000 : 0x0000) |
               (g.trame_front_montant ? 0x4000 : 0x0000))
end

"""
    parametres_imagerie(r, g) -> (parametres, imposes)

Paramètres du mode FIFO avec les horloges du scanner, comme
imagerie_photons.jl : les réglages de [spc_module], plus ceux que l'imagerie
impose (`imposes`, affichés à part dans le tableau « demandé → appliqué »).
"""
function parametres_imagerie(r::Reglages, g::Geometrie)
    imposes = Dict{String,Any}(
        "mode" => 1, "adc_resolution" => 12, "stop_on_time" => 0,
        "routing_mode" => routage_marqueurs(g), "macro_time_clk" => 0)
    return merge(r.spc, imposes), imposes
end

"""
    parametres_single(r, temps_s) -> (parametres, imposes)

Paramètres du mode histogramme (mode 0, « Single » de SPCM), comme
histogrammes_single.jl.
"""
function parametres_single(r::Reglages, temps_s::Real = r.temps_collecte_s)
    imposes = Dict{String,Any}(
        "mode" => 0, "adc_resolution" => r.resolution_adc, "collect_time" => Float64(temps_s),
        "stop_on_time" => 1, "stop_on_ovfl" => r.arret_debordement ? 1 : 0,
        "dead_time_comp" => get(r.spc, "dead_time_comp", 1))
    return merge(r.spc, imposes), imposes
end

"""
ROI que le routage distingue : 4 lignes (P0.4 à P0.7), 16 codes, dont le 0
réservé (voir `CODE_HORS_ROI`).
"""
const ROI_MAX = 15

"""
Code que la carte lit quand rien ne pilote les lignes de routage (entrées
actives à 0 V, au repos à l'état haut) : réservé, aucune ROI ne l'utilise.
La NI l'écrit pendant les déplacements des galvos et les pauses, et les
photons qui le portent sont jetés au décodage (`Passes`) : en FIFO, c'est
l'effet de CNTE sans ligne de plus. Un câble débranché n'envoie donc pas
de photons dans une vraie ROI.
"""
const CODE_HORS_ROI = 0

"""
Code des scans sans ROI (tout le champ) : un code ordinaire, puisque les
photons du code réservé sont jetés.
"""
const CODE_SANS_ROI = 1

"""Code de routage que la carte lit pour la ROI dessinée n° `roi` (1 à 15) : `roi` lui-même."""
function code_routage(roi::Integer)
    1 <= roi <= ROI_MAX || error("ROI n° $roi : le routage en distingue $ROI_MAX (codes 1 à 15, le 0 est réservé)")
    return Int(roi)
end

"""
    code_ecrit(code, inverser) -> UInt8

Valeur que la NI écrit sur P0.4 à P0.7 pour que la carte lise `code` :
NON(code) sur 4 bits avec `inverser` (entrées de routage actives à 0 V),
`code` sinon.
"""
code_ecrit(code::Integer, inverser::Bool) = UInt8(inverser ? (~code & 0x0f) : (code & 0x0f))

"""
    parametres_clamp(r) -> (parametres, imposes)

Mode FIFO du Realtime : chaque photon porte son temps et son code de
routage ; les passes sont délimitées par le signal de passe (compteur de la
6321, cadencé par l'horloge de l'AO) branché sur M0 et M3 : front montant
sur M0 (début de passe), front descendant sur M3 (fin). Les marqueurs M1 et
M2 (horloges du scanner) sont coupés.
"""
function parametres_clamp(r::Reglages)
    imposes = Dict{String,Any}(
        "mode" => 1, "adc_resolution" => 12, "stop_on_time" => 0, "macro_time_clk" => 0,
        "routing_mode" => Int(0x0100 | 0x0800 | 0x1000))    # M0 et M3 actifs ; M0 front montant, M3 front descendant
    return merge(r.spc, imposes), imposes
end
