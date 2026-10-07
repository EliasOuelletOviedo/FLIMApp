# source_qc.jl — la SPC-QC-104 comme source de FLIMCore.
#
# Une seule carte, un détecteur par entrée : chaque canal de [verification]
# series (« 3T0089/IN1 », « 3T0089/IN2 ») devient une carte virtuelle — le
# module k - 1 pour le canal k — dont le flux est celui d'une SPC-150N
# (FIFO_150) : les photons de son entrée, tous les marqueurs, le macrotemps.
# Le moteur, les passes, le rangement en image, l'enregistrement et le
# rejeu des sessions, l'analyse : rien d'autre ne change.
#
# Traduction d'un enregistrement de la QC-104 (SPCLite.FORMAT_QC104) :
# - débordement du macrotemps : le temps de la carte avance de 4096 tics ;
#   chaque carte virtuelle suit (débordements regroupés) ;
# - marqueur M0–M3 : recopié sur chaque carte virtuelle, au même temps ;
# - photon de l'entrée e : sur la carte virtuelle de e, avec son routage.
#   Son canal du TDC (4096 canaux sur la plage, 4 ps à 16,384 ns) est
#   rééchantillonné sur [qc] fenetre_ns, la période du laser : temps =
#   (canal + u) × plage / 4096, u uniforme dans [0, 1). Sans ce tirage, les
#   canaux de 4 ps tomberaient 12 ou 13 par canal de l'analyse (un peigne
#   de ±4 %). Au-delà de la fenêtre : compté (`hors_fenetre`) et jeté.
#   ADC = 4095 − canal rééchantillonné : la convention de la SPC-150N ;
# - photon d'une entrée sans canal : compté (`autres_entrees`) et jeté ;
# - autre chose : compté (`inattendus`).
# La QC-104 ne marque pas les pertes dans le flux : un FIFO plein se voit
# par SPC_FOVFL, comme sur la SPC-150N.
#
# Single (mode 0) : émulé en FIFO — la mémoire de la QC-104 range ses
# entrées d'une façon que le manuel ne décrit pas. Le moteur arme, attend
# la fin (`lire_etat`) et lit l'histogramme (`lire_histo`) comme sur la
# carte ; chaque photon va dans l'histogramme de son entrée, rééchantillonné
# comme en FIFO.
#
# Le matériel derrière (`CarteQC`) : la DLL (`QCDll`), ou un flux brut
# rejoué (`QCRejeu` : les tests, les acquisitions brutes de qc4/qc5).

# ---------------------------------------------------------------------
# Le matériel
# ---------------------------------------------------------------------

abstract type CarteQC end

"""
    QCDll()

La SPC-QC-104 par la DLL (SPCLite) : SPC_init, puis seules les cartes de
type 104 sont gardées (`selectionner_modules!`) — avec des SPC-150N encore
installées, la DLL ne pilote qu'un type à la fois. Celle dont le n° de
série est demandé, sinon la première.
"""
mutable struct QCDll <: CarteQC
    module_no::Int
    ouverte::Bool
    tic_s::Float64
end
QCDll() = QCDll(-1, false, 2.048e-9)

function qc_ouvrir!(c::QCDll, ini::AbstractString, serie_voulue::AbstractString)
    SPCLite.chemin_dll()                           # DLL absente : erreur lisible avant SPC_init
    code = SPCLite.initialiser(ini)
    c.ouverte = true                               # SPC_close sera appelé, même si SPC_init a échoué
    voulus, autres = SPCLite.selectionner_modules!((SPCLite.TYPE_QC104,))
    autres_txt = join(("module $k : $(SPCLite.nom_module(SPCLite.info_module(k).type))" for k in autres), ", ")
    isempty(voulus) && return (code = code, present = false, etat = -1, module_no = -1, serie = "", autres = autres_txt)
    choix = first(voulus)
    serie = ""
    for k in voulus
        SPCLite.etat_init(k) == 0 || continue
        s = try
            String(SPCLite.eeprom(k).serie)
        catch
            ""
        end
        if s == serie_voulue || isempty(serie)
            choix, serie = k, s
            s == serie_voulue && break
        end
    end
    c.module_no = choix
    return (code = code, present = true, etat = SPCLite.etat_init(choix), module_no = choix, serie = serie, autres = autres_txt)
end

function qc_fermer!(c::QCDll)
    c.ouverte || return nothing
    c.ouverte = false
    try
        SPCLite.liberer()                          # la carte prête de la sélection ; SPC_close dans tous les cas
    finally
        SPCLite.oublier_selection!()
    end
    return nothing
end

qc_etat_init(c::QCDll) = c.module_no < 0 ? -1 : SPCLite.etat_init(c.module_no)

function qc_configurer!(c::QCDll, parametres::AbstractDict, fichier::AbstractString)
    ini = ecrire_ini(splitext(fichier)[1] * "_demande.ini", parametres)
    SPCLite.appliquer_ini(c.module_no, ini)
    lus = SPCLite.lire_parametres(c.module_no; fichier = fichier)
    if get(lus, "mode", 1.0) != 0.0
        # mt_clock de SPC_get_fifo_init_vars : 2 048 131 pour la QC-104, des fs (2,048131 ns ; les M0
        # de période connue de qc4 donnent 2,0482 ns). Valeur nominale s'il n'a pas ce sens.
        f = SPCLite.fifo_init(c.module_no)
        tic = f.mt_clock * 1e-15
        c.tic_s = 1.9e-9 < tic < 2.2e-9 ? tic : SPCLite.tic_macro_s(c.module_no)
    end
    return lus
end

qc_tic_s(c::QCDll) = c.tic_s
qc_demarrer!(c::QCDll) = (SPCLite.demarrer(c.module_no); nothing)
qc_arreter!(c::QCDll) = (SPCLite.arreter(c.module_no); nothing)
qc_lire!(c::QCDll, tampon::Vector{UInt16}) = SPCLite.lire_fifo!(c.module_no, tampon)
qc_etat(c::QCDll) = SPCLite.etat_mesure(c.module_no)
qc_sync(c::QCDll) = SPCLite.sync_etat(c.module_no)
qc_taux_bruts(c::QCDll) = SPCLite.taux_bruts(c.module_no)
qc_effacer_taux!(c::QCDll) = (SPCLite.effacer_taux(c.module_no); nothing)
qc_remplissage(c::QCDll) = SPCLite.remplissage_fifo(c.module_no)
qc_forcer!(c::QCDll) = (c.module_no < 0 || SPCLite.forcer_modules(Int16[c.module_no]); nothing)
qc_epuise(::QCDll) = false
qc_materiel(::QCDll) = true

"""
    QCRejeu(mots; serie="3T0089", vitesse=0.0, tic_s=2.048e-9, taux=zeros(8))

Une QC-104 imaginaire qui rend un flux brut (`mots`, au format
FORMAT_QC104) à `vitesse` fois le temps réel (0 : tout de suite), depuis
le début à chaque mesure (`qc_demarrer!`).
Les paramètres demandés sont « appliqués » tels quels ; `taux` : les 8
valeurs de SPC_read_rates. Pour les tests, et pour repasser une acquisition
brute (qc4/qc5) dans FLIMCore (`source_qc_brut`).
"""
mutable struct QCRejeu <: CarteQC
    mots::Vector{UInt16}
    serie::String
    vitesse::Float64
    tic_s::Float64
    taux::Vector{Float64}
    position::Int
    base::Int64
    t_origine::Int64
    t_dernier::Int64
    t0::Float64
    en_cours::Bool
    ouvertures::Int
    fermetures::Int
end

QCRejeu(mots::AbstractVector{UInt16}; serie::AbstractString = "3T0089", vitesse::Real = 0.0, tic_s::Real = 2.048e-9,
        taux::AbstractVector{<:Real} = zeros(8)) =
    QCRejeu(Vector{UInt16}(mots[1:end - isodd(length(mots))]), String(serie), Float64(vitesse), Float64(tic_s),
            Float64.(collect(taux)), 1, 0, 0, 0, 0.0, false, 0, 0)

function qc_ouvrir!(c::QCRejeu, ini::AbstractString, serie_voulue::AbstractString)
    c.ouvertures += 1
    c.position, c.base, c.t_dernier, c.en_cours = 1, 0, 0, false
    return (code = 0, present = true, etat = 0, module_no = 0, serie = c.serie, autres = "")
end
qc_fermer!(c::QCRejeu) = (c.fermetures += 1; c.en_cours = false; nothing)
qc_etat_init(::QCRejeu) = 0

function qc_configurer!(::QCRejeu, parametres::AbstractDict, fichier::AbstractString)
    lus = Dict{String,Float64}(String(k) => Float64(v) for (k, v) in parametres if v isa Real)
    ecrire_ini(fichier, lus)
    return lus
end

qc_tic_s(c::QCRejeu) = c.tic_s
function qc_demarrer!(c::QCRejeu)
    c.position, c.base, c.t_dernier, c.t_origine = 1, 0, 0, 0
    c.en_cours, c.t0 = true, time()
    return nothing
end
qc_arreter!(c::QCRejeu) = (c.en_cours = false; nothing)
qc_etat(c::QCRejeu) = c.en_cours ? SPC_ARMED : 0x0000
qc_sync(::QCRejeu) = 1
qc_taux_bruts(c::QCRejeu) = (code = 0, valeurs = copy(c.taux))
qc_effacer_taux!(::QCRejeu) = nothing
qc_remplissage(::QCRejeu) = 0.0
qc_forcer!(::QCRejeu) = nothing
qc_epuise(c::QCRejeu) = c.position > length(c.mots) - 1
qc_materiel(::QCRejeu) = false

"""Temps (tics) d'un enregistrement de la QC-104 et base des débordements après lui."""
function _temps_qc(base::Int64, w::UInt32)
    (w & 0xc0000000) == 0x80000000 && return base + PERIODE_MT_QC, base + PERIODE_MT_QC
    return base + Int64(w & 0x0fff), base
end

function qc_lire!(c::QCRejeu, tampon::Vector{UInt16})
    c.en_cours || return 0
    cible = c.vitesse > 0 ? c.t_origine + floor(Int64, (time() - c.t0) * c.vitesse / c.tic_s) : typemax(Int64)
    n = 0
    while n + 2 <= length(tampon) && c.position <= length(c.mots) - 1
        w = UInt32(c.mots[c.position]) | (UInt32(c.mots[c.position + 1]) << 16)
        t, base = _temps_qc(c.base, w)
        t > cible && break
        c.t_dernier, c.base = t, base
        tampon[n + 1], tampon[n + 2] = c.mots[c.position], c.mots[c.position + 1]
        n += 2
        c.position += 2
    end
    return n
end

# ---------------------------------------------------------------------
# La source
# ---------------------------------------------------------------------

"""Le macrotemps de la QC-104 : 12 bits, comme la SPC-150N."""
const PERIODE_MT_QC = Int64(4096)

"""Clés du mode Single que la source émule en FIFO : « appliquées » telles que demandées."""
const CLES_SINGLE_EMULEES = ("mode", "collect_time", "stop_on_time", "stop_on_ovfl", "adc_resolution", "dead_time_comp")

"""
    SourceQC(carte=QCDll())

La SPC-QC-104, une carte virtuelle par canal de [verification] series (voir
l'en-tête du fichier). Compteurs depuis l'ouverture : `hors_fenetre`
(photons au-delà de [qc] fenetre_ns), `autres_entrees` (photons d'une
entrée sans canal), `inattendus` (enregistrements d'un type inconnu),
`desordre` (événements plus anciens que le débordement précédent, gardés
au temps de ce débordement).
"""
mutable struct SourceQC <: Source
    carte::CarteQC
    voies::Vector{Int}                 # entrée de la carte virtuelle k - 1
    canal_de_entree::Vector{Int}       # entrée 1 à 4 → carte virtuelle + 1 (0 : aucune)
    serie_voulue::String
    serie_carte::String
    message::String
    ouverte::Bool
    etat::Int
    plage_ns::Float64
    fenetre_ns::Float64
    taux_idx::Vector{Int}
    alea::Alea
    tampon::Vector{UInt16}
    encodeurs::Vector{EncodeurFifo}    # flux FIFO_150 en attente, un par carte virtuelle
    base::Int64                        # macrotemps de la carte (tics)
    reste::UInt16
    a_reste::Bool
    lancees::Set{Int}
    en_mesure::Bool
    compter_seulement::Bool
    dernier_config::Union{Nothing,Dict{String,Any}}
    lus::Dict{String,Float64}
    single::Bool                       # dernière configuration : mode 0 (émulé)
    temps_single::Float64
    arret_debordement::Bool
    bits_single::Int
    histos::Vector{Vector{Int}}        # Single : 2^bits canaux par carte virtuelle, temps croissant
    single_en_cours::Bool
    debut_single::Float64
    etat_single::UInt16
    photons::Vector{Int}               # par carte virtuelle, depuis le dernier `lire_taux`
    t_taux::Vector{Float64}
    hors_fenetre::Int
    autres_entrees::Int
    inattendus::Int
    desordre::Int
    photons_total::Int                 # photons gardés depuis le dernier bilan
end

SourceQC(carte::CarteQC = QCDll()) =
    SourceQC(carte, Int[], zeros(Int, 4), "", "", "", false, -1, 16.384, 12.5, [2, 3, 4, 1], Alea(104),
             zeros(UInt16, 1 << 21), EncodeurFifo[], 0, 0x0000, false, Set{Int}(), false, false, nothing,
             Dict{String,Float64}(), false, 1.0, true, 8, Vector{Int}[], false, 0.0, 0x0000, Int[], Float64[],
             0, 0, 0, 0, 0)

"""
    source_qc_brut(fichier; vitesse=0.0) -> SourceQC

Rejoue un flux brut de la QC-104 (un .spc de qc4/qc5 : en-tête de 4 octets
puis les mots) comme si la carte le rendait, à travers la traduction de
`SourceQC` : de quoi vérifier sans le banc ce que FLIMCore en fait. Les
canaux : [verification] series des réglages du moteur.
"""
function source_qc_brut(fichier::AbstractString; vitesse::Real = 0.0)
    _, mots = lire_spc(fichier)
    return SourceQC(QCRejeu(mots; vitesse = vitesse))
end

nom_source(::SourceQC) = "qc104"
est_materiel(s::SourceQC) = qc_materiel(s.carte)
message_ouverture(s::SourceQC) = s.message

function ouvrir!(s::SourceQC, r::Reglages)
    voies = [voie_qc(x) for x in r.series]
    any(isnothing, voies) &&
        error("QC-104 : [verification] series = $(r.series) ; chaque canal \"<n° de série>/IN<entrée>\", par exemple \"3T0089/IN1\"")
    s.voies = [v.entree for v in voies]
    fill!(s.canal_de_entree, 0)
    for (k, e) in enumerate(s.voies)
        s.canal_de_entree[e] = k
    end
    s.serie_voulue = voies[1].serie
    s.plage_ns, s.fenetre_ns = r.qc_plage_tdc_ns, r.qc_fenetre_ns
    s.taux_idx = copy(r.qc_taux)
    dossier = joinpath(dossier_spc(r), "moteur")
    mkpath(dossier)
    ini = ecrire_ini(joinpath(dossier, "init_qc104.ini"), parametres_base(r))
    o = qc_ouvrir!(s.carte, ini, s.serie_voulue)
    s.ouverte = true
    s.etat = o.etat
    s.serie_carte = o.serie
    s.dernier_config = nothing
    s.message = !o.present ? "aucune SPC-QC-104 détectée" * (isempty(o.autres) ? "" : " (cartes vues : $(o.autres))") :
                o.etat != 0 || isempty(o.serie) || o.serie == s.serie_voulue ? "" :
                "la QC-104 trouvée porte le n° de série $(o.serie), pas $(s.serie_voulue) ([verification] series)"
    _reinitialiser_flux!(s)
    modules = o.present ? collect(0:length(s.voies) - 1) : Int[]
    return (code = o.code, detectes = modules, prets = o.etat == 0 ? copy(modules) : Int[],
            etats = Dict(k => o.etat for k in modules))
end

function fermer!(s::SourceQC)
    s.ouverte || return nothing
    s.ouverte = false
    try
        s.en_mesure && qc_arreter!(s.carte)
    catch
    end
    s.en_mesure = false
    empty!(s.lancees)
    qc_fermer!(s.carte)
    return nothing
end

function etat_modules(s::SourceQC)
    s.etat = qc_etat_init(s.carte)
    modules = collect(0:length(s.voies) - 1)
    return (code = 0, detectes = modules, prets = s.etat == 0 ? copy(modules) : Int[], etats = Dict(k => s.etat for k in modules))
end

verrouilles(s::SourceQC) = qc_etat_init(s.carte) == -6 ? collect(0:length(s.voies) - 1) : Int[]
forcer!(s::SourceQC, modules) = (isempty(modules) || (qc_forcer!(s.carte); s.dernier_config = nothing); nothing)

identifier(s::SourceQC, k::Integer) =
    (type = SPCLite.TYPE_QC104, serie = "$(isempty(s.serie_carte) ? "?" : s.serie_carte)/IN$(s.voies[k + 1])")

"""Remet la traduction à zéro : nouvelle mesure, le macrotemps repart de 0."""
function _reinitialiser_flux!(s::SourceQC)
    n = length(s.voies)
    s.encodeurs = [EncodeurFifo() for _ in 1:n]
    s.base, s.a_reste = 0, false
    s.photons = zeros(Int, n)
    s.t_taux = fill(time(), n)
    length(s.histos) == n || (s.histos = [zeros(Int, 1 << s.bits_single) for _ in 1:n])
    return s
end

function configurer!(s::SourceQC, k::Integer, parametres::AbstractDict, fichier::AbstractString)
    p = Dict{String,Any}(parametres)
    single = get(p, "mode", 1) == 0
    if single
        s.temps_single = Float64(get(p, "collect_time", 1.0))
        s.arret_debordement = get(p, "stop_on_ovfl", 1) == 1
        foreach(cle -> delete!(p, cle), CLES_SINGLE_EMULEES)
        merge!(p, Dict{String,Any}("mode" => 1, "adc_resolution" => 12, "stop_on_time" => 0,
                                   "macro_time_clk" => 0, "routing_mode" => 0))
    end
    s.single = single
    if p == s.dernier_config
        ecrire_ini(fichier, s.lus)                 # même configuration pour l'autre entrée : rien à renvoyer à la carte
    else
        s.lus = qc_configurer!(s.carte, p, fichier)
        s.dernier_config = p
        plage = get(s.lus, "tac_range", NaN)       # la plage que la carte applique vraiment
        isfinite(plage) && plage > 0 && (s.plage_ns = plage)
    end
    lus = copy(s.lus)
    if single
        for cle in CLES_SINGLE_EMULEES
            v = get(parametres, cle, nothing)
            v isa Real && (lus[cle] = Float64(v))
        end
    end
    return lus
end

fenetre_tac(s::SourceQC, k, lus) = s.fenetre_ns

function bilan_source!(s::SourceQC)
    parts = String[]
    # Quelques photons au-delà de la fenêtre, c'est le bord de la période (SYNC à 80,1 MHz : 12,48 ns) :
    # dit seulement au-delà de 0,1 % des photons.
    garde = s.photons_total
    s.hors_fenetre > 0.001 * max(garde, 1) && push!(parts, "$(s.hors_fenetre) photon(s) sur $(garde + s.hors_fenetre) au-delà de [qc] fenetre_ns ($(s.fenetre_ns) ns) jetés : " *
                                       "fenêtre plus courte que la période du laser, diviseur_sync > 1, ou decalage_ns qui pousse le déclin au bout")
    s.autres_entrees > 0 && push!(parts, "$(s.autres_entrees) photon(s) d'une entrée sans canal ([verification] series) jetés")
    s.inattendus > 0 && push!(parts, "$(s.inattendus) enregistrement(s) d'un type inconnu (format FIFO de la QC-104 à revoir)")
    s.desordre > 0 && push!(parts, "$(s.desordre) événement(s) antérieur(s) au débordement précédent, gardés à ce temps")
    s.hors_fenetre = s.autres_entrees = s.inattendus = s.desordre = 0
    s.photons_total = 0
    return isempty(parts) ? "" : "QC-104 : " * join(parts, " ; ")
end
infos_fifo(s::SourceQC, k::Integer) = (horloge_macro_s = qc_tic_s(s.carte), entete = 0x00000000)
lire_sync(s::SourceQC, k::Integer) = qc_sync(s.carte)
lire_remplissage(s::SourceQC, k::Integer) = qc_remplissage(s.carte)
effacer_taux!(s::SourceQC, k::Integer) = (qc_effacer_taux!(s.carte); nothing)
epuisee(s::SourceQC, k::Integer) = qc_epuise(s.carte) && isempty(s.encodeurs[k + 1].mots)

"""
Taux de la carte virtuelle `k`. Pendant une mesure FIFO, le CFD est compté
dans le flux (photons de son entrée depuis la lecture précédente) : exact.
Sinon, les valeurs de SPC_read_rates que [qc] taux attribue à son entrée et
au SYNC.
"""
function lire_taux(s::SourceQC, k::Integer)
    v = qc_taux_bruts(s.carte)
    valeur(i) = 1 <= i <= length(v.valeurs) ? v.valeurs[i] : NaN
    sync = valeur(s.taux_idx[4])
    if s.en_mesure && !s.single
        _pomper!(s)
        maintenant = time()
        dt = maintenant - s.t_taux[k + 1]
        cfd = dt > 0 ? s.photons[k + 1] / dt : 0.0
        s.photons[k + 1], s.t_taux[k + 1] = 0, maintenant
        return (code = 0, sync = sync, cfd = cfd, tac = cfd, adc = cfd)
    end
    cfd = valeur(s.taux_idx[s.voies[k + 1]])
    return (code = v.code, sync = sync, cfd = cfd, tac = cfd, adc = cfd)
end

"""
    mesurer_taux!(src, modules, duree_s) -> Dict ou nothing

Taux de photons de chaque module comptés dans le flux pendant `duree_s`
(la carte est configurée en FIFO) : la vérification les préfère aux
compteurs de la carte quand la source sait le faire (QC-104 : le sens des
valeurs de SPC_read_rates n'est pas documenté). `nothing` : pas pour cette
source.
"""
mesurer_taux!(::Source, modules, duree_s) = nothing

function mesurer_taux!(s::SourceQC, modules, duree_s)
    s.en_mesure && return nothing
    _reinitialiser_flux!(s)
    s.compter_seulement = true
    qc_demarrer!(s.carte)
    t0 = time()
    try
        while time() - t0 < duree_s
            _pomper!(s)
            sleep(0.01)
        end
        _pomper!(s)
    finally
        s.compter_seulement = false
        qc_arreter!(s.carte)
    end
    dt = time() - t0
    return Dict(k => s.photons[k + 1] / dt for k in modules)
end

function lancer!(s::SourceQC, k::Integer)
    if isempty(s.lancees)
        _reinitialiser_flux!(s)
        if s.single
            foreach(h -> fill!(h, 0), s.histos)
            s.single_en_cours, s.etat_single, s.debut_single = true, SPC_ARMED, time()
        end
        qc_demarrer!(s.carte)
        s.en_mesure = true
    end
    push!(s.lancees, Int(k))
    return nothing
end

function stopper!(s::SourceQC, k::Integer)
    delete!(s.lancees, Int(k))
    if isempty(s.lancees) && s.en_mesure
        s.en_mesure = false
        s.single_en_cours && (s.single_en_cours = false; s.etat_single = SPC_CMD_STOP)
        qc_arreter!(s.carte)
    end
    return nothing
end

"""
Bits d'état. FIFO : ceux de la carte (SPC_FOVFL…). Single émulé : armé
jusqu'à la fin du temps de collecte (ou un canal à 65535 coups avec
stop_on_ovfl), puis SPC_TIME_OVER (ou SPC_OVERFL), la carte arrêtée.
"""
function lire_etat(s::SourceQC, k::Integer)
    s.single || return qc_etat(s.carte)
    s.single_en_cours || return s.etat_single
    _pomper!(s)
    sature = s.arret_debordement && any(h -> any(>=(65535), h), s.histos)
    if sature || time() - s.debut_single >= s.temps_single
        s.single_en_cours = false
        s.etat_single = sature ? SPC_OVERFL | SPC_OVERFLOW : SPC_TIME_OVER
        s.en_mesure = false
        empty!(s.lancees)
        qc_arreter!(s.carte)
    end
    return s.single_en_cours ? SPC_ARMED : s.etat_single
end

function lire_mots!(s::SourceQC, k::Integer, tampon::Vector{UInt16})
    (s.en_mesure && !s.single) || return 0
    f = s.encodeurs[k + 1].mots
    isempty(f) && _pomper!(s)
    n = min(length(f), length(tampon) - isodd(length(tampon)))
    n -= isodd(n)
    copyto!(tampon, 1, f, 1, n)
    n == length(f) ? empty!(f) : deleteat!(f, 1:n)
    return n
end

function preparer_memoire!(s::SourceQC, k::Integer, bits::Integer, bits_routage::Integer = 0)
    1 <= bits <= 12 || error("QC-104, Single émulé : de 1 à 12 bits, pas $bits")
    if bits != s.bits_single || length(s.histos) != length(s.voies)
        s.bits_single = Int(bits)
        s.histos = [zeros(Int, 1 << bits) for _ in s.voies]
    end
    return (canaux = 1 << bits, courbes = 1 << bits_routage)
end

effacer_page!(s::SourceQC, k::Integer) = (fill!(s.histos[k + 1], 0); nothing)

function lire_histo(s::SourceQC, k::Integer, n::Integer; bloc::Integer = 0)
    bloc == 0 || return zeros(UInt16, n)
    h = s.histos[k + 1]
    n == length(h) || error("QC-104, Single émulé : $n canaux demandés, $(length(h)) préparés")
    return UInt16[min(x, 65535) for x in h]
end

# --- Traduction ---------------------------------------------------------

"""Lit ce que la carte a dans son FIFO et le traduit (cartes virtuelles, ou histogrammes du Single)."""
function _pomper!(s::SourceQC)
    n = qc_lire!(s.carte, s.tampon)
    n > 0 && _traduire!(s, s.tampon, n)
    return n
end

function _traduire!(s::SourceQC, mots::AbstractVector{UInt16}, n::Integer)
    i = 1
    if s.a_reste && n >= 1
        _enregistrement_qc!(s, UInt32(s.reste) | (UInt32(mots[1]) << 16))
        s.a_reste = false
        i = 2
    end
    while i + 1 <= n
        _enregistrement_qc!(s, UInt32(mots[i]) | (UInt32(mots[i + 1]) << 16))
        i += 2
    end
    if i == n
        s.reste, s.a_reste = mots[n], true
    end
    # Chaque carte virtuelle va jusqu'au temps de la carte : les passes (fin
    # au bout du scan) et les trames avancent même sans photon sur son entrée.
    s.compter_seulement || s.single || foreach(e -> _avancer_jusqua!(e, s.base), s.encodeurs)
    return nothing
end

@inline function _enregistrement_qc!(s::SourceQC, w::UInt32)
    genre = w & 0xc0000000
    if genre == 0x80000000                                  # débordement du macrotemps
        s.base += PERIODE_MT_QC
        (w & 0x3fffffff) == 0 || (s.inattendus += 1)        # jamais vu : bits bas d'un débordement
    elseif genre == 0x40000000                              # marqueurs M0–M3
        (s.compter_seulement || s.single) && return nothing
        t = s.base + Int64(w & 0x0fff)
        bits = BIT_MARK | BIT_INVALID | (w & 0x0000f000)
        for e in s.encodeurs
            _emettre!(s, e, t, bits)
        end
    elseif genre == 0x00000000                              # photon
        k = s.canal_de_entree[Int((w >> 28) & 0x3) + 1]
        if k == 0
            s.autres_entrees += 1
            return nothing
        end
        a = _reechantillonner(s, Int((w >> 16) & 0x0fff))
        if a < 0
            s.hors_fenetre += 1
            return nothing
        end
        s.photons[k] += 1
        s.photons_total += 1
        if s.single
            h = s.histos[k]
            h[(a * length(h)) ÷ 4096 + 1] += 1
        elseif !s.compter_seulement
            _emettre!(s, s.encodeurs[k], s.base + Int64(w & 0x0fff),
                      (UInt32(4095 - a) << 16) | (w & 0x0000f000))
        end
    else
        s.inattendus += 1
    end
    return nothing
end

"""Canal du TDC → canal de la fenêtre [qc] fenetre_ns (4096), tiré dans la largeur du canal ; -1 au-delà."""
@inline function _reechantillonner(s::SourceQC, canal::Int)
    s.plage_ns == s.fenetre_ns && return canal
    a = floor(Int, (canal + _uniforme!(s.alea)) * s.plage_ns / s.fenetre_ns)
    return a < 4096 ? a : -1
end

"""Un événement au temps absolu `t` (tics) sur une carte virtuelle ; plus ancien que son dernier débordement : à ce temps-là."""
@inline function _emettre!(s::SourceQC, e::EncodeurFifo, t::Int64, bits::UInt32)
    if t < e.base
        s.desordre += 1
        t = e.base
    end
    _evenement!(e, t, bits)
    return nothing
end

"""Débordements qui amènent `e` au tour du temps `t` (sans événement)."""
function _avancer_jusqua!(e::EncodeurFifo, t::Int64)
    tours = (t - e.base) ÷ PERIODE_MT_QC
    if tours >= 1
        _pousser!(e, BIT_INVALID | BIT_MTOV | UInt32(tours))
        e.base += tours * PERIODE_MT_QC
    end
    return e
end

# ---------------------------------------------------------------------
# Flux brut synthétique (tests)
# ---------------------------------------------------------------------

"""
    EncodeurQC()

Écrit un flux brut de la QC-104 (FORMAT_QC104) à partir de temps absolus
(tics) : un enregistrement 0x80000000 par débordement du macrotemps, comme
la carte.
"""
mutable struct EncodeurQC
    base::Int64
    mots::Vector{UInt16}
end
EncodeurQC() = EncodeurQC(0, UInt16[])

function _evenement_qc!(e::EncodeurQC, t::Int64, w::UInt32)
    t >= e.base || error("flux QC synthétique : temps décroissant ($t < $(e.base))")
    while t - e.base >= PERIODE_MT_QC
        push!(e.mots, 0x0000, 0x8000)
        e.base += PERIODE_MT_QC
    end
    w |= UInt32(t - e.base)
    push!(e.mots, UInt16(w & 0xffff), UInt16(w >> 16))
    return e
end

"""Photon de l'entrée `entree` (1 à 3) au temps `t`, canal du TDC `canal` (0-4095, temps croissant)."""
photon_qc!(e::EncodeurQC, t::Integer, canal::Integer; entree::Integer = 1, routage::Integer = 0) =
    _evenement_qc!(e, Int64(t), (UInt32(entree - 1) << 28) | (UInt32(canal & 0x0fff) << 16) | (UInt32(routage & 0xf) << 12))

"""Marqueurs au temps `t` : `bits` = 0b0001 pour M0, 0b1000 pour M3."""
marqueur_qc!(e::EncodeurQC, t::Integer, bits::Integer) =
    _evenement_qc!(e, Int64(t), 0x40000000 | (UInt32(bits & 0xf) << 12))

"""Les débordements du macrotemps jusqu'au temps `t` (la fin d'un flux)."""
function avancer_qc!(e::EncodeurQC, t::Integer)
    while t - e.base >= PERIODE_MT_QC
        push!(e.mots, 0x0000, 0x8000)
        e.base += PERIODE_MT_QC
    end
    return e
end
