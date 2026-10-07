# reglages.jl — le fichier de réglages des cartes SPC (config/spc.toml).
#
# Un seul fichier, relu par le moteur à chaque démarrage de mesure ; le GUI
# peut l'éditer et le réécrire (`ecrire_reglages`, qui garde les
# commentaires). La SPC-QC-104 (source "qc104") prend ses réglages dans
# [qc], en noms clairs comme reglages_qc.jl ; les SPC-150N (source
# "cartes") dans [spc_module], les clés du manuel de la DLL SPCM.

"""
Les réglages du scanner du banc, reconnus à leur nombre de lignes par trame
(fronts M1 entre deux M2 ; la ligne dure 55,55 µs dans tous) :
`(lignes par trame, lignes de l'image, lignes ignorées en haut)`. Mesurés
le 2026-10-02 avec scripts/spc/horloges_scanner.jl pour les réglages 1024,
512, 256, 128, 60, 24 et 8 lignes (trames à 16,67, 33,33, 66,67, 125, 250,
500 et 900 Hz). Les lignes ignorées en haut : 32 pour 1024 (scan_borders de
SPCM) ; les autres, proportionnelles aux lignes en trop, sont à vérifier sur
une image complète (horloges_scanner.jl, avec un échantillon).
"""
const REGLAGES_SCANNER = NTuple{3,Int}[(1080, 1024, 32), (540, 512, 16), (270, 256, 8), (144, 128, 9),
                                       (72, 60, 7), (36, 24, 7), (20, 8, 7)]

"""
    Geometrie(; temps_pixel_ns=50.0, pixels_par_ligne=1024, decalage_pixels=21,
              lignes_par_image=0, decalage_lignes=32,
              ligne_front_montant=true, trame_front_montant=true,
              reglages_scanner=REGLAGES_SCANNER)

Rangement des photons en image, comme imagerie_photons.jl : horloge de
pixel interne (`temps_pixel_ns`), horloge de ligne sur M1, de trame sur M2.
`pixels_par_ligne = 0` : toute la période de ligne. `lignes_par_image = 0` :
selon l'horloge de trame — le réglage du scanner de `reglages_scanner` qui a
autant de lignes par trame que mesuré donne les lignes de l'image et celles
ignorées en haut ; un nombre de lignes absent de la table donne les lignes
mesurées moins `decalage_lignes`. Les décalages ignorent les premiers
pixels de chaque ligne et les premières lignes de chaque trame.
"""
Base.@kwdef struct Geometrie
    temps_pixel_ns::Float64 = 50.0
    pixels_par_ligne::Int = 1024
    decalage_pixels::Int = 21
    lignes_par_image::Int = 0
    decalage_lignes::Int = 32
    ligne_front_montant::Bool = true
    trame_front_montant::Bool = true
    reglages_scanner::Vector{NTuple{3,Int}} = copy(REGLAGES_SCANNER)
end

"""Le réglage du scanner de `g` qui a `lignes_trame` lignes par trame, ou `nothing`."""
function reglage_scanner(g::Geometrie, lignes_trame::Integer)
    k = findfirst(e -> e[1] == lignes_trame, g.reglages_scanner)
    return k === nothing ? nothing : g.reglages_scanner[k]
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
    source::String = "qc104"
    rejeu::Vector{String} = String[]
    vitesse::Float64 = 1.0
    connexion_au_demarrage::Bool = true
    # [spc_module] (SPC-150N)
    spc::Dict{String,Any} = copy(SPC_DEFAUT)
    # [qc] (SPC-QC-104 ; quadruplets : IN1, IN2, IN3, SYNC) : les valeurs de SPCM du banc
    # (celles des IRF du 2026-10-07, irf_16x_750nm_ch1/ch2.sdt)
    qc_seuil_mV::Vector{Float64} = [-139.22, -139.22, -139.22, -70.59]
    qc_zc_mV::Vector{Float64} = [12.85, 12.85, 12.85, -6.8]
    qc_decalage_ns::Vector{Float64} = [0.512, 1.536, 0.0, 0.0]
    qc_plage_tdc_ns::Float64 = 16.384
    qc_fenetre_ns::Float64 = 12.5
    qc_diviseur_sync::Int = 1
    qc_retard_routage_ns::Int = 0
    qc_limite_basse_pct::Float64 = 5.0
    qc_photon_unique::Bool = false
    qc_temps_taux_s::Float64 = 1.0
    qc_taux::Vector{Int} = [2, 3, 4, 1]
    # [verification]
    series::Vector{String} = ["3T0089/IN1", "3T0089/IN2"]
    seuil_cfd::Float64 = 10.0
    # [imagerie]
    modules_imagerie::Vector{Int} = [0, 1]
    duree_s::Float64 = 0.0
    temps_pixel_ns::Float64 = 50.0
    pixels_par_ligne::Int = 1024
    decalage_pixels::Int = 21
    lignes_par_image::Int = 0
    decalage_lignes::Int = 32
    ligne_front_montant::Bool = true
    trame_front_montant::Bool = true
    reglages_scanner::Vector{NTuple{3,Int}} = copy(REGLAGES_SCANNER)
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
    irf_temps_s::Float64 = 1.0
    irf_maximum::Int = 32768
    irf_histogrammes_max::Int = 600
    # [clamp]
    canaux_clamp::Int = 256
    inverser_routage::Bool = true
    fin_par_m3::Bool = true
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
    ("source", "type", :source, "\"qc104\" (la SPC-QC-104), \"cartes\" (les SPC-150N), \"rejeu\" (fichiers .spc ci-dessous) ou \"simulation\""),
    ("source", "rejeu", :rejeu, "fichiers .spc à rejouer, un par carte (écrits par l'imagerie, avec leur _acquisition.ini)"),
    ("source", "vitesse", :vitesse, "rejeu et simulation : 1 = temps réel ; 0 = le plus vite possible"),
    ("source", "connexion_au_demarrage", :connexion_au_demarrage, "le GUI lance le moteur et vérifie les cartes à l'ouverture"),
    ("qc", "seuil_mV", :qc_seuil_mV, "seuils des CFD, IN1, IN2, IN3, SYNC (-500 à 0 mV) : ceux de SPCM (System Parameters de la QC-104)"),
    ("qc", "zc_mV", :qc_zc_mV, "niveaux de zéro des CFD, IN1, IN2, IN3, SYNC (-96 à 96 mV)"),
    ("qc", "decalage_ns", :qc_decalage_ns, "décalage du temps par entrée, IN1, IN2, IN3, SYNC (0 à 32,256 ns, pas de 0,512) : place la montée du déclin au début de la fenêtre"),
    ("qc", "plage_tdc_ns", :qc_plage_tdc_ns, "plage du TDC (tac_range), 4096 canaux en FIFO : 16,384 ns = 4 ps par canal"),
    ("qc", "fenetre_ns", :qc_fenetre_ns, "fenêtre des déclins de FLIMApp, la période du laser : les 4096 canaux du TDC y sont rééchantillonnés (12,5 ns, comme la SPC-150N)"),
    ("qc", "diviseur_sync", :qc_diviseur_sync, "1, 2 ou 4 : à 1, chaque impulsion du laser sert de référence"),
    ("qc", "retard_routage_ns", :qc_retard_routage_ns, "lecture du routage après le photon (-57 à 65 ns, pas de 8,192)"),
    ("qc", "limite_basse_pct", :qc_limite_basse_pct, "« Limit Low » de SPCM, % de la plage du TDC coupés au début (la DLL met 10 % sans cette clé)"),
    ("qc", "photon_unique", :qc_photon_unique, "true : un photon par période du laser ; false : détection multiphoton"),
    ("qc", "temps_taux_s", :qc_temps_taux_s, "s, intégration des compteurs de taux (rate_count_time) : la QC-104 applique 1 s"),
    ("qc", "taux", :qc_taux, "quelle valeur de SPC_read_rates (1 à 8) est IN1, IN2, IN3, SYNC : [2, 3, 4, 1] confirmé au banc le 2026-10-07 (comparé au flux)"),
    ("verification", "series", :series, "canal 1 puis canal 2 : \"<n° de série>/IN<entrée>\" pour la QC-104 (3T0089/IN1), le n° de série de chaque carte pour les SPC-150N"),
    ("verification", "seuil_cfd", :seuil_cfd, "/s : en dessous, détecteurs éteints (Enable outputs dans le logiciel DCC ?)"),
    ("imagerie", "modules", :modules_imagerie, "cartes enregistrées"),
    ("imagerie", "duree_s", :duree_s, "0 : en continu jusqu'à « Arrêter »"),
    ("imagerie", "temps_pixel_ns", :temps_pixel_ns, "pixel_time de SPCM : horloge de pixel interne"),
    ("imagerie", "pixels_par_ligne", :pixels_par_ligne, "scan_size_x de SPCM : 1024"),
    ("imagerie", "decalage_pixels", :decalage_pixels, "scan_borders (gauche) de SPCM : pixels ignorés après chaque début de ligne (retour du balayage)"),
    ("imagerie", "lignes_par_image", :lignes_par_image, "scan_size_y de SPCM ; 0 : selon l'horloge de trame (réglage du scanner reconnu dans reglages_scanner)"),
    ("imagerie", "decalage_lignes", :decalage_lignes, "scan_borders (haut) de SPCM : lignes ignorées après chaque début de trame (lignes_par_image > 0, ou réglage absent de reglages_scanner)"),
    ("imagerie", "ligne_front_montant", :ligne_front_montant, "front actif de l'horloge de ligne (M1)"),
    ("imagerie", "trame_front_montant", :trame_front_montant, "front actif de l'horloge de trame (M2)"),
    ("imagerie", "reglages_scanner", :reglages_scanner, "réglages du scanner : [lignes par trame, lignes de l'image, lignes ignorées en haut], pour lignes_par_image = 0 (mesurés avec scripts/spc/horloges_scanner.jl ; lignes du haut à vérifier sauf pour 1024)"),
    ("affichage", "binning_temps", :binning_temps, "pixels regroupés (n × n) pour le temps moyen"),
    ("affichage", "photons_min", :photons_min, "sous ce nombre de photons, pas de temps moyen"),
    ("affichage", "trames_par_image", :trames_par_image, "trames additionnées par image affichée ; 0 : tout depuis le début"),
    ("single", "modules", :modules_single, "cartes mesurées en même temps"),
    ("single", "temps_collecte_s", :temps_collecte_s, "durée de chaque histogramme"),
    ("single", "n_histogrammes", :n_histogrammes, "histogrammes successifs, chacun repart de zéro"),
    ("single", "resolution_adc", :resolution_adc, "8 bits = 256 canaux, la résolution des déclins du Realtime et de l'IRF"),
    ("single", "arret_debordement", :arret_debordement, "arrêt dès qu'un canal atteint 65535 coups"),
    ("single", "inverser", :inverser, "déclin à l'envers (montée lente, chute brutale) : true"),
    ("single", "irf_temps_s", :irf_temps_s, "acquisition d'IRF (bouton IRF de la fenêtre SPC) : un Single de cette durée à la fois, sur les deux canaux ensemble"),
    ("single", "irf_maximum", :irf_maximum, "… additionnés jusqu'à ce que le maximum de la somme dépasse ce nombre de coups sur chaque canal (2^15)"),
    ("single", "irf_histogrammes_max", :irf_histogrammes_max, "… au plus ce nombre de Singles : au-delà, l'IRF n'est pas changée"),
    ("clamp", "canaux", :canaux_clamp, "canaux des déclins du Realtime (les 4096 du FIFO regroupés) : 256, la résolution de l'IRF"),
    ("clamp", "fin_par_m3", :fin_par_m3, "false : M0 seul, chaque passe dure le scan programmé ; true : sa fin vient de M3 (le même signal de passe câblé aussi sur M3, front descendant)"),
    ("clamp", "inverser_routage", :inverser_routage, "la NI écrit NON(c) sur P0.4-P0.7 et la carte, aux entrées actives à 0 V, lit c"),
    ("enregistrement", "dossier", :dossier, "\"\" : ~/FLIMApp_spc (sous-dossiers imagerie et single)"),
    ("enregistrement", "flux_brut", :flux_brut, "garder le flux FIFO de chaque carte (.spc) : environ 4 octets par photon"),
]

const EN_TETE_REGLAGES = """
# Réglages des cartes SPC pour FLIMCore (src/spc/FLIMCore.jl), relus à chaque
# démarrage de mesure. Le GUI réécrit ce fichier quand tu changes un réglage
# dans la fenêtre SPC : les commentaires sont regénérés, garde tes notes
# ailleurs.
#
# SPC-QC-104 ([source] type = "qc104") : réglages dans [qc], en noms clairs
# (ceux de reglages_qc.jl ; recopie les valeurs de SPCM qui te donnent un
# beau déclin sur chaque entrée). Chaque canal est une entrée de la carte,
# « n° de série/IN<entrée> » dans [verification] series.
# SPC-150N ([source] type = "cartes") : [spc_module], les clés du manuel de
# la DLL SPCM (inutilisé avec la QC-104). Une clé que la carte ne prend pas
# est signalée par le tableau « demandé → appliqué ».
"""

"""Géométrie d'image des réglages (section [imagerie])."""
geometrie(r::Reglages) = Geometrie(r.temps_pixel_ns, r.pixels_par_ligne, r.decalage_pixels,
                                   r.lignes_par_image, r.decalage_lignes,
                                   r.ligne_front_montant, r.trame_front_montant, copy(r.reglages_scanner))

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
_valeur_champ(::Type{Vector{NTuple{3,Int}}}, v) = NTuple{3,Int}[(Int(x[1]), Int(x[2]), Int(x[3])) for x in v if length(x) == 3 || error("3 nombres")]
_valeur_champ(::Type{Vector{String}}, v::AbstractVector) = String[String(x) for x in v]
_valeur_champ(::Type{Vector{Int}}, v::AbstractVector) = Int[Int(x) for x in v]
_valeur_champ(::Type{Vector{Float64}}, v::AbstractVector) = Float64[Float64(x) for x in v]
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
    r.source in ("qc104", "cartes", "rejeu", "simulation") ||
        error("réglages SPC : [source] type = \"qc104\", \"cartes\", \"rejeu\" ou \"simulation\", pas \"$(r.source)\"")
    est_qc104(r) && _valider_qc(r)
    r.vitesse >= 0 || error("réglages SPC : [source] vitesse doit être positive ou nulle")
    all(m -> 0 <= m <= 7, vcat(r.modules_imagerie, r.modules_single)) ||
        error("réglages SPC : numéros de modules de 0 à 7")
    r.duree_s >= 0 || error("réglages SPC : [imagerie] duree_s doit être positive ou nulle")
    r.temps_pixel_ns > 0 || error("réglages SPC : [imagerie] temps_pixel_ns doit être positif")
    min(r.decalage_pixels, r.decalage_lignes) >= 0 || error("réglages SPC : [imagerie] décalages positifs ou nuls")
    r.pixels_par_ligne == 1024 || error("réglages SPC : [imagerie] pixels_par_ligne (scan_size_x) : 1024")
    r.lignes_par_image >= 0 ||
        error("réglages SPC : [imagerie] lignes_par_image (scan_size_y) : un nombre de lignes, ou 0 pour celui de l'horloge de trame")
    for (trame, image, haut) in r.reglages_scanner
        (image > 0 && haut >= 0 && image + haut <= trame) ||
            error("réglages SPC : [imagerie] reglages_scanner : [$trame, $image, $haut] — lignes par trame, lignes de l'image, lignes ignorées en haut (image + haut ≤ trame)")
    end
    allunique(first.(r.reglages_scanner)) ||
        error("réglages SPC : [imagerie] reglages_scanner : deux réglages ont le même nombre de lignes par trame")
    r.binning_temps >= 1 || error("réglages SPC : [affichage] binning_temps d'au moins 1")
    r.photons_min >= 0 || error("réglages SPC : [affichage] photons_min positif ou nul")
    r.trames_par_image >= 0 || error("réglages SPC : [affichage] trames_par_image positif ou nul")
    r.temps_collecte_s > 0 || error("réglages SPC : [single] temps_collecte_s doit être positif")
    r.n_histogrammes >= 1 || error("réglages SPC : [single] n_histogrammes d'au moins 1")
    r.irf_temps_s > 0 || error("réglages SPC : [single] irf_temps_s doit être positif")
    (r.irf_maximum >= 1 && r.irf_histogrammes_max >= 1) ||
        error("réglages SPC : [single] irf_maximum et irf_histogrammes_max d'au moins 1")
    r.resolution_adc == 8 ||
        error("réglages SPC : [single] resolution_adc : 8 bits, des histogrammes de 256 canaux comme ceux du Realtime et de l'IRF")
    r.canaux_clamp in (64, 128, 256, 512, 1024, 4096) || error("réglages SPC : [clamp] canaux : 64 à 4096, un diviseur de 4096")
    return r
end

"""La [qc] et les canaux de la QC-104 : erreur lisible pour tout ce que la carte ne prendrait pas."""
function _valider_qc(r::Reglages)
    for (nom, v) in (("seuil_mV", r.qc_seuil_mV), ("zc_mV", r.qc_zc_mV), ("decalage_ns", r.qc_decalage_ns))
        length(v) == 4 || error("réglages SPC : [qc] $nom : 4 valeurs, IN1, IN2, IN3, SYNC")
    end
    isempty(r.series) && error("réglages SPC : [verification] series : au moins un canal, \"<n° de série>/IN1\"")
    voies = [voie_qc(s) for s in r.series]
    for (i, v) in enumerate(voies)
        v === nothing && error("réglages SPC : [verification] series : canal $i = \"$(r.series[i])\" ; avec la QC-104, " *
                               "\"<n° de série>/IN<entrée>\", par exemple \"3T0089/IN1\" (entrées 1 à 3)")
    end
    length(unique(v.serie for v in voies)) == 1 ||
        error("réglages SPC : [verification] series : tous les canaux sur la même QC-104 ($(join(r.series, ", ")))")
    allunique(v.entree for v in voies) || error("réglages SPC : [verification] series : deux canaux sur la même entrée ($(join(r.series, ", ")))")
    0 < r.qc_fenetre_ns <= r.qc_plage_tdc_ns ||
        error("réglages SPC : [qc] fenetre_ns ($(r.qc_fenetre_ns)) : positive et pas plus longue que plage_tdc_ns ($(r.qc_plage_tdc_ns))")
    r.qc_temps_taux_s > 0 || error("réglages SPC : [qc] temps_taux_s doit être positif")
    (length(r.qc_taux) == 4 && all(k -> 1 <= k <= 8, r.qc_taux) && allunique(r.qc_taux)) ||
        error("réglages SPC : [qc] taux : 4 indices différents de 1 à 8 (valeurs de SPC_read_rates de IN1, IN2, IN3, SYNC)")
    try
        parametres_base(r)                                   # plages vérifiées par SPCLite.parametres_qc
    catch e
        error("réglages SPC : [qc] " * sprint(showerror, e))
    end
    return r
end

_toml_valeur(v::Bool) = v ? "true" : "false"
_toml_valeur(v::Integer) = string(Int(v))
_toml_valeur(v::AbstractFloat) = isinteger(v) && abs(v) < 1e15 ? @sprintf("%.1f", v) : repr(Float64(v))
_toml_valeur(v::AbstractString) = "\"" * replace(v, "\\" => "\\\\", "\"" => "\\\"") * "\""
_toml_valeur(v::AbstractVector) = "[" * join((_toml_valeur(x) for x in v), ", ") * "]"
_toml_valeur(v::Tuple) = _toml_valeur(collect(v))
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

"""La source est-elle la SPC-QC-104 ?"""
est_qc104(r::Reglages) = r.source == "qc104"

"""Vraies cartes (SPC-QC-104 ou SPC-150N), par la DLL SPCM ?"""
source_materielle(r::Reglages) = r.source in ("qc104", "cartes")

"""
    voie_qc(serie) -> (serie, entree) ou nothing

Le canal de la QC-104 que désigne un n° de série de [verification] series :
« 3T0089/IN2 » → la carte 3T0089, son entrée IN2.
"""
function voie_qc(serie::AbstractString)
    m = match(r"^(.+)/IN([1-3])$", strip(serie))
    m === nothing && return nothing
    return (serie = String(m[1]), entree = parse(Int, m[2]))
end

"""
    serie_carte(serie) -> String

Le n° de série de la carte physique d'un canal : « 3T0089 » pour
« 3T0089/IN1 » (QC-104), le n° lui-même pour une SPC-150N.
"""
serie_carte(serie::AbstractString) = (v = voie_qc(serie); v === nothing ? String(serie) : v.serie)

"""
    parametres_base(r) -> Dict

Les réglages de la DLL communs à toutes les mesures. SPC-150N : [spc_module]
tel quel. QC-104 : [qc] traduit par `SPCLite.parametres_qc` (les clés de la
SPC-150 y ont un autre sens : cfd_limit_high est le seuil de IN2…), avec
les entrées des canaux de [verification] series actives et routées, et le
SYNC actif ; les autres entrées coupées.
"""
function parametres_base(r::Reglages)
    est_qc104(r) || return copy(r.spc)
    e = Set(v.entree for v in filter(!isnothing, voie_qc.(r.series)))
    p = SPCLite.parametres_qc(Dict{String,Any}(
        "seuil_mV" => r.qc_seuil_mV, "zc_mV" => r.qc_zc_mV, "decalage_ns" => r.qc_decalage_ns,
        "entrees_actives" => (1 in e, 2 in e, 3 in e, true), "routage_entrees" => (1 in e, 2 in e, 3 in e),
        "photon_unique" => r.qc_photon_unique, "plage_tdc_ns" => r.qc_plage_tdc_ns,
        "diviseur_sync" => r.qc_diviseur_sync, "retard_routage_ns" => r.qc_retard_routage_ns,
        "limite_basse_pct" => r.qc_limite_basse_pct))
    p["rate_count_time"] = r.qc_temps_taux_s
    return p
end

"""Temps d'intégration des compteurs de taux (s) : rate_count_time, de [qc] ou de [spc_module]."""
temps_taux_s(r::Reglages) = est_qc104(r) ? r.qc_temps_taux_s : Float64(get(r.spc, "rate_count_time", 1.0))

"""Valeur de routing_mode pour les marqueurs M1 (ligne) et M2 (trame), fronts compris."""
function routage_marqueurs(g::Geometrie)
    return Int(0x0600 |                                        # marqueurs M1 et M2
               (g.ligne_front_montant ? 0x2000 : 0x0000) |
               (g.trame_front_montant ? 0x4000 : 0x0000))
end

"""
    parametres_imagerie(r, g) -> (parametres, imposes)

Paramètres du mode FIFO avec les horloges du scanner, comme
imagerie_photons.jl : les réglages de la carte (`parametres_base`), plus
ceux que l'imagerie impose (`imposes`, affichés à part dans le tableau
« demandé → appliqué »).
"""
function parametres_imagerie(r::Reglages, g::Geometrie)
    imposes = Dict{String,Any}(
        "mode" => 1, "adc_resolution" => 12, "stop_on_time" => 0,
        "routing_mode" => routage_marqueurs(g), "macro_time_clk" => 0)
    return merge(parametres_base(r), imposes), imposes
end

"""
    parametres_single(r, temps_s) -> (parametres, imposes)

Paramètres du mode histogramme (mode 0, « Single » de SPCM), comme
histogrammes_single.jl. La QC-104 l'émule en FIFO (`SourceQC`) : un
histogramme par entrée, rééchantillonné sur [qc] fenetre_ns.
"""
function parametres_single(r::Reglages, temps_s::Real = r.temps_collecte_s)
    base = parametres_base(r)
    imposes = Dict{String,Any}(
        "mode" => 0, "adc_resolution" => r.resolution_adc, "collect_time" => Float64(temps_s),
        "stop_on_time" => 1, "stop_on_ovfl" => r.arret_debordement ? 1 : 0,
        "dead_time_comp" => get(base, "dead_time_comp", 1))
    return merge(base, imposes), imposes
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
    parametres_clamp(r; tous_marqueurs=false, fin_par_m3=r.fin_par_m3) -> (parametres, imposes)

Mode FIFO du Realtime : chaque photon porte son temps et son code de
routage ; les passes sont délimitées par le signal de passe (compteur de la
6321, cadencé par l'horloge de l'AO, sur PFI13) branché sur M0 (broche 12
de la QC-104), front
montant : le début de chaque passe. Sa fin : le scan programmé plus tard
(M0 seul), ou, avec `fin_par_m3`, le front descendant du même signal câblé
aussi sur M3 (broche 10 de la QC-104). Les marqueurs M1 et M2 (horloges du scanner) sont coupés —
sauf avec `tous_marqueurs`, pour le test du signal de passe (voir sur
quelle entrée il arrive), fronts montants.
"""
function parametres_clamp(r::Reglages; tous_marqueurs::Bool = false, fin_par_m3::Bool = r.fin_par_m3)
    # Bits 8–11 : M0–M3 enregistrés ; bits 12–15 : front montant de M0–M3.
    marqueurs = tous_marqueurs ? 0x0F00 | 0x1000 | 0x2000 | 0x4000 :
                fin_par_m3 ? 0x0100 | 0x0800 | 0x1000 : 0x0100 | 0x1000
    imposes = Dict{String,Any}(
        "mode" => 1, "adc_resolution" => 12, "stop_on_time" => 0, "macro_time_clk" => 0,
        "routing_mode" => Int(marqueurs))    # M0 front montant (M3 front descendant, si enregistré)
    return merge(parametres_base(r), imposes), imposes
end
