"""
    SPCLite

Interface minimale vers la DLL SPCM de Becker & Hickl (spcm64.dll), par
ccall, sur le modèle de DAQmxLite. Couvre les SPC-150N et, depuis la
version 9, la SPC-QC-104 :

- initialisation par fichier .ini (aucune structure C à recopier) ;
- identification du module, EEPROM, état d'initialisation ;
- choix des cartes par type : la DLL ne pilote qu'un type de carte à la fois ;
- lecture et écriture des paramètres, toujours via des fichiers .ini ;
  pour la QC-104, traduction des noms clairs vers les clés de la DLL ;
- compteurs de taux et état du SYNC ;
- mesure FIFO, lecture du FIFO ;
- décodage des enregistrements 32 bits : `Decodeur` (SPC-150N, inchangé
  depuis la version 8) et `DecodeurFIFO`, décodeur commun piloté par un
  `FormatFIFO` (FORMAT_SPC150, ou le format de la QC-104 établi et vérifié
  par qc4_format_fifo.jl) ;
- décodage de référence par la DLL elle-même (`photons_dll`), à partir
  d'un fichier .spc.

Références :
- « SPCM Dynamic Link Libraries », manuel utilisateur 5.0, mars 2023
  (prototypes, codes d'erreur, clés du fichier .ini, sens des clés pour la
  SPC-QC-104) ;
- notes de version de la DLL SPCM (SPCM-DLL-news.txt) : 5.0.0 (prise en
  charge du « TDC-104 »), 5.1.0 (SPC_read_fifo renvoie les données brutes de
  la QC-104, tri des modules par numéro de série), 5.2.0 et 5.3.0 (firmware
  C3 puis C5 de la QC-104) ;
- manuel LabVIEW SPC-QC v11 (2025) : M_TDC104 = 104 ;
- manuel de la SPC-QC-104 (mai 2023) et schéma de connexion de la QC-104 ;
- format FIFO des SPC-130/140/15x/16x/830 : mêmes règles que libtcspc
  (bh_spc.hpp) et le lecteur Bio-Formats des fichiers .spc.

Les structures SPCdata et SPC_EEP_Data ne sont jamais recopiées en Julia :
la DLL les remplit dans un tampon d'octets opaque, puis écrit elle-même
les paramètres dans un fichier .ini qu'on relit. C'est ce qui rend ce
module insensible au changement de SPCdata de la DLL 5.1.0 (ajout des
champs de la QC-104). Les seules structures lues champ par champ sont
SPCModInfo (6 short), rate_values (float) et PhotInfo (photons_dll), qui
n'ont pas de trou d'alignement ; leurs tampons ont une marge.
"""
module SPCLite

using Libdl, Printf

"""Version de ce fichier : les scripts s'arrêtent si Julia en a chargé une plus ancienne."""
const VERSION_LITE = 12

export SPCError, chk_spc, message_erreur, DLL_SPCM
export ecrire_ini, lire_ini, avec_spc, avec_spc_tous, initialiser, liberer, liberer_tous
export modules_detectes, modules_prets, forcer_module, forcer_modules, prendre_modules, chercher_bh
export etat_init, info_module, type_module, eeprom, mode_dll, explication_init
export TYPE_QC104, TYPES_SPC150, nom_module, est_qc, types_presents
export lire_parametres, appliquer_ini, sync_etat, effacer_taux, taux, taux_bruts
export comparer_parametres, afficher_parametres, ecart_peigne
export CLES_QC, parametres_qc, controle_tdc, decrire_controle_tdc, relire_qc, afficher_qc
export demarrer, arreter, etat_mesure, lire_fifo!, fifo_init, remplissage_fifo, tic_macro_s
export largeur_canal_s
export configurer_memoire, definir_page, effacer_memoire, lire_bloc
export Decodeur, decoder!, reinitialiser!, PERIODE_MT
export FormatFIFO, FORMAT_SPC150, DecodeurFIFO, ecrire_format, copie_format
export PhotonDLL, ecrire_spc, photons_dll, type_flux_fichier
export DRAPEAU_INVALIDE, DRAPEAUX_MARQUEURS, est_marqueur
export SPC_OVERFL, SPC_OVERFLOW, SPC_TIME_OVER, SPC_COLTIM_OVER, SPC_CMD_STOP, SPC_HFILL_NRDY
export SPC_ARMED, SPC_FOVFL, SPC_FEMPTY, NOMS_MODULES, MESSAGES_INIT, MESSAGES_SYNC

# =====================================================================
# Chargement de la DLL
# =====================================================================

"""
Cherche un fichier (insensible à la casse) sous les dossiers BH de
Program Files, là où le TCSPC Package s'installe. `nothing` si absent.
"""
function chercher_bh(nom::AbstractString)
    for racine in (get(ENV, "ProgramFiles(x86)", raw"C:\Program Files (x86)"),
                   get(ENV, "ProgramFiles", raw"C:\Program Files"))
        bh = joinpath(racine, "BH")
        isdir(bh) || continue
        for (dossier, _, fichiers) in walkdir(bh; onerror = _ -> nothing)
            for f in fichiers
                lowercase(f) == lowercase(nom) && return joinpath(dossier, f)
            end
        end
    end
    return nothing
end

"""
Cherche spcm64.dll : variable d'environnement SPCM_DLL d'abord, puis les
dossiers d'installation habituels du TCSPC Package, puis le chemin de
recherche de Windows.
"""
function _trouver_dll()
    candidats = String[]
    haskey(ENV, "SPCM_DLL") && push!(candidats, ENV["SPCM_DLL"])
    for racine in (get(ENV, "ProgramFiles(x86)", raw"C:\Program Files (x86)"),
                   get(ENV, "ProgramFiles", raw"C:\Program Files"))
        push!(candidats, joinpath(racine, "BH", "SPCM", "DLL", "spcm64.dll"))
        push!(candidats, joinpath(racine, "BH", "SPCM", "spcm64.dll"))
    end
    for c in candidats
        isfile(c) && return c
    end
    p = chercher_bh("spcm64.dll")
    p === nothing || return p
    h = Libdl.dlopen_e("spcm64")
    h == C_NULL || return Libdl.dlpath(h)
    error("""
        spcm64.dll introuvable. Chemins essayés :
          $(join(candidats, "\n  "))
        Installe le TCSPC Package 64 bits en cochant « SPCM-DLL », ou indique
        le chemin avant de charger SPCLite :
          ENV["SPCM_DLL"] = raw"C:\\chemin\\vers\\spcm64.dll"
        Pour trouver le fichier, dans PowerShell :
          Get-ChildItem 'C:\\Program Files (x86)\\BH' -Recurse -Filter spcm64.dll""")
end

"""Chemin complet de la DLL chargée (fixé au chargement du module)."""
const DLL_SPCM = _trouver_dll()

# =====================================================================
# Erreurs
# =====================================================================

struct SPCError <: Exception
    code::Int
    fonction::String
    msg::String
end
Base.showerror(io::IO, e::SPCError) =
    print(io, "SPC ", e.code, " dans ", e.fonction, " : ", e.msg)

function _chaine_erreur(id::Integer)
    buf = zeros(UInt8, 512)
    r = ccall((:SPC_get_error_string, DLL_SPCM), Int16,
              (Int16, Ptr{UInt8}, Int16), Int16(id), buf, Int16(length(buf) - 1))
    r < 0 && return ""
    return GC.@preserve buf unsafe_string(pointer(buf))
end

"""Texte de la DLL pour un code d'erreur (négatif, tel que renvoyé)."""
function message_erreur(code::Integer)
    s = _chaine_erreur(code)
    # Selon la version de la DLL, l'identifiant attendu peut être positif.
    isempty(s) && code < 0 && (s = _chaine_erreur(-code))
    return isempty(s) ? "erreur $code (pas de description dans la DLL)" : s
end

"""Lève une SPCError si `code` < 0, sinon renvoie `code`."""
function chk_spc(code::Integer, fonction::AbstractString)
    code < 0 && throw(SPCError(Int(code), String(fonction), message_erreur(code)))
    return code
end

"""Codes renvoyés par SPC_get_init_status (manuel DLL, p. 29-30)."""
const MESSAGES_INIT = Dict(
      0 => "aucune erreur",
     -1 => "initialisation pas faite",
     -2 => "somme de contrôle de l'EEPROM incorrecte",
     -3 => "code d'identification du module incorrect",
     -4 => "échec du test matériel",
     -5 => "impossible d'ouvrir la carte PCI (pilote, carte absente ou mal enfichée)",
     -6 => "module déjà utilisé et verrouillé par un autre programme (SPCM ouvert ?)",
     -7 => "version de WinDriver incorrecte (logiciels B&H de versions mélangées)",
     -8 => "clé de licence corrompue",
     -9 => "version de firmware incorrecte (mise à jour par SPCM : bouton In Use, puis OK)",
    -10 => "clé de licence absente du registre",
    -11 => "licence non valide pour la DLL SPCM",
    -12 => "licence expirée",
    -13 => "impossible d'ouvrir la carte USB",
)

"""Phrase lisible pour un état d'initialisation (et le code de SPC_init)."""
function explication_init(etat::Integer, code_init::Integer = 0)
    txt = get(MESSAGES_INIT, etat,
              etat <= -100 ? "erreur de configuration du FPGA (Xilinx), code $(-etat - 100)" :
                             "état inconnu")
    s = "état $etat : $txt"
    code_init < 0 && (s *= " ; SPC_init a renvoyé $code_init ($(message_erreur(code_init)))")
    return s
end

"""Type de la SPC-QC-104 renvoyé par SPC_test_id et SPCModInfo (M_TDC104 de spcm_def.h)."""
const TYPE_QC104 = 104

"""Types de la famille SPC-150 (SPC-150 et SPC-150N)."""
const TYPES_SPC150 = (150, 151)

"""Types de module renvoyés par SPC_test_id (manuel DLL p. 31 ; manuel LabVIEW SPC-QC v11)."""
const NOMS_MODULES = Dict(
    130 => "SPC-130", 131 => "SPC-130-EM", 140 => "SPC-140", 150 => "SPC-150",
    151 => "SPC-150N", 160 => "SPC-160", 161 => "SPC-160X", 162 => "SPC-160PCIE",
    180 => "SPC-180N", 181 => "SPC-180NX", 182 => "SPC-180NXX", 185 => "SPC-180N-USB",
    186 => "SPC-180NX-USB", 187 => "SPC-180NXX-USB", 104 => "SPC-QC-104",
    600 => "SPC-600", 630 => "SPC-630", 700 => "SPC-700", 730 => "SPC-730",
    830 => "SPC-830", 930 => "SPC-930", 230 => "DPC-230")

"""Nom lisible d'un type de module."""
nom_module(t::Integer) = get(NOMS_MODULES, Int(t), "type $t")

"""Vrai pour la SPC-QC-104 (et la QC-004, que la DLL traite comme une QC-104 sans imagerie)."""
est_qc(t::Integer) = t == TYPE_QC104

const MESSAGES_SYNC = Dict(0 => "pas de SYNC", 1 => "SYNC correct",
                           2 => "SYNC en surcharge", 3 => "SYNC en surcharge")

# Bits de SPC_test_state utiles en mode FIFO (manuel DLL, p. 17 et 42).
const SPC_ARMED  = 0x0080   # mesure en cours
const SPC_FOVFL  = 0x0400   # FIFO débordé : des données ont été perdues
const SPC_FEMPTY = 0x0800   # FIFO vide
# Bits utiles en mode histogramme (mode 0, « Single ») :
const SPC_OVERFL      = 0x0001   # arrêt sur débordement d'un canal (65535 coups)
const SPC_OVERFLOW    = 0x0002   # un canal a débordé
const SPC_TIME_OVER   = 0x0004   # arrêt à la fin du temps de collecte
const SPC_COLTIM_OVER = 0x0008   # temps de collecte écoulé
const SPC_CMD_STOP    = 0x0010   # arrêt par SPC_stop_measurement
const SPC_HFILL_NRDY  = 0x8000   # effacement de la mémoire pas fini

# =====================================================================
# Fichiers .ini
# =====================================================================

_format_ini(v::Bool) = v ? "1" : "0"
_format_ini(v::Integer) = string(Int(v))     # décimal : 0xff00 s'écrirait « 0xff00 »
_format_ini(v::Real) = @sprintf("%.6g", v)
_format_ini(v) = string(v)

"""
    ecrire_ini(chemin, parametres; simulation=0, bus=-1, carte=-1) -> chemin

Écrit un fichier d'initialisation au format de spcm.ini. `parametres` va
dans la section [spc_module] (clés du manuel DLL : "mode", "tac_range"…).
Tout paramètre absent garde sa valeur par défaut. `simulation = 151`
simule une SPC-150N sans carte ; `bus = carte = -1` cherche partout.
Pour la QC-104, construire `parametres` avec `parametres_qc`.
"""
function ecrire_ini(chemin::AbstractString, parametres = Dict{String,Any}();
                    simulation::Integer = 0, bus::Integer = -1, carte::Integer = -1)
    mkpath(dirname(abspath(chemin)))
    open(chemin, "w") do io
        println(io, "; SPCM DLL initialisation file for SPC modules")
        println(io, "; (écrit par SPCLite.jl)")
        println(io)
        println(io, "[spc_base]")
        println(io, "simulation= ", simulation)
        println(io, "pci_bus_no= ", bus)
        println(io, "pci_card_no= ", carte)
        println(io)
        println(io, "[spc_module]")
        for (cle, val) in sort!(collect(parametres); by = first)
            println(io, cle, "= ", _format_ini(val))
        end
    end
    return abspath(chemin)
end

function _nombre(s::AbstractString)
    x = tryparse(Int, s)                 # accepte aussi 0x… (hexadécimal)
    x === nothing || return Float64(x)
    return tryparse(Float64, s)
end

"""
    lire_ini(chemin; section="spc_module") -> Dict{String,Float64}

Relit une section d'un fichier .ini (clés en minuscules, commentaires
après « ; » ignorés).
"""
function lire_ini(chemin::AbstractString; section::AbstractString = "spc_module")
    d = Dict{String,Float64}()
    dedans = false
    for ligne in eachline(chemin)
        s = strip(first(split(ligne, ';'; limit = 2)))
        isempty(s) && continue
        if startswith(s, "[")
            dedans = lowercase(strip(s, ['[', ']', ' '])) == lowercase(section)
            continue
        end
        dedans || continue
        m = match(r"^([A-Za-z_0-9]+)\s*=\s*(\S+)", s)
        m === nothing && continue
        v = _nombre(m.captures[2])
        v === nothing || (d[lowercase(m.captures[1])] = v)
    end
    return d
end

# =====================================================================
# Initialisation, verrou, fermeture
# =====================================================================

"""Appelle SPC_init avec le chemin absolu de `ini`. Ne lève pas : renvoie le code."""
initialiser(ini::AbstractString) =
    Int(ccall((:SPC_init, DLL_SPCM), Int16, (Cstring,), abspath(ini)))

"""Mode de la DLL : 0 = matériel, 151 = simulation d'une SPC-150N, etc."""
mode_dll() = Int(ccall((:SPC_get_mode, DLL_SPCM), Int16, ()))

_set_mode(mode, force, table::Vector{Int32}) =
    Int(ccall((:SPC_set_mode, DLL_SPCM), Int16, (Int16, Int16, Ptr{Int32}),
              Int16(mode), Int16(force), table))

function _table_in_use(modules)
    table = zeros(Int32, 32)          # le manuel parle de 8 entrées ; 32 par prudence
    for m in modules
        table[m + 1] = 1
    end
    return table
end

# Règle de sécurité de ce module : une fonction qui touche le matériel
# (SPC_stop_measurement, SPC_test_id, SPC_get_eeprom_data, mesures…) ne
# s'appelle QUE sur un module prêt, c'est-à-dire détecté et initialisé par
# cette session. Sur un module absent ou non initialisé, la DLL peut faire
# une violation d'accès, que try/catch ne rattrape pas. Seules
# SPC_get_module_info et SPC_get_init_status, qui lisent les structures
# internes de la DLL, se lisent sans risque pour les modules 0 à 7.
#
# Depuis la version 9 : quand une session choisit ses cartes par type
# (avec_spc_tous(...; types) ou avec_spc(...; types)), la liste choisie est
# gardée dans _SELECTION et `modules_prets` ne renvoie que celles-là. Ainsi
# `liberer` n'appelle SPC_stop_measurement que sur les cartes de la session.

const _SELECTION = Ref{Union{Nothing,Vector{Int16}}}(nothing)

"""
    modules_detectes(; types=nothing) -> Vector{Int16}

Modules présents d'après SPC_get_module_info (type > 0), après SPC_init.
`types` : ne garder que ces types (par exemple `(TYPE_QC104,)`).
Ne lit que les structures internes de la DLL : aucun accès au matériel.
"""
function modules_detectes(; types = nothing)
    vus = Int16[]
    for k in 0:7
        info = try
            info_module(k)
        catch
            nothing
        end
        info === nothing && continue
        info.type > 0 || continue
        (types === nothing || info.type in types) && push!(vus, Int16(k))
    end
    return vus
end

"""
    types_presents() -> Dict{Int16,Int}

Type de chaque module détecté (structures internes de la DLL seulement).
"""
types_presents() = Dict(k => info_module(k).type for k in modules_detectes())

"""
    modules_prets(; types=nothing) -> Vector{Int16}

Modules détectés ET initialisés par cette session (état 0), restreints à
la sélection de la session en cours s'il y en a une : les seuls sur
lesquels on peut appeler une fonction qui touche le matériel.
"""
function modules_prets(; types = nothing)
    sel = _SELECTION[]
    return Int16[k for k in modules_detectes(; types)
                 if etat_init(k) == 0 && (sel === nothing || k in sel)]
end

"""
    prendre_modules(voulus; forcer=false)

Un seul appel à SPC_set_mode : les modules `voulus` sont pris par cette
session (verrouillés, et initialisés avec le fichier .ini s'ils ne
l'étaient pas) ; tous les autres sont rendus. `forcer = true` reprend
aussi un module resté verrouillé (état -6). Ne passer que des modules
détectés. Ne jamais forcer pendant que SPCM se sert réellement des cartes.
"""
prendre_modules(voulus; forcer::Bool = false) =
    chk_spc(_set_mode(0, forcer ? 1 : 0, _table_in_use(voulus)),
            forcer ? "SPC_set_mode (forcer)" : "SPC_set_mode")

"""
Prend les modules listés même s'ils sont marqués « verrouillés » (par
exemple après une session qui s'est mal terminée). Les modules absents de
la liste sont rendus. Équivaut à `prendre_modules(modules; forcer=true)`.
"""
function forcer_modules(modules)
    isempty(modules) && return 0
    return prendre_modules(modules; forcer = true)
end

forcer_module(m::Integer) = forcer_modules((m,))

"""
    liberer_tous(modules)

Arrête la mesure sur chaque module de la liste, déverrouille les modules
pris par cette session, puis referme la DLL. Ne passer QUE des modules
prêts (voir `modules_prets`). Avec une liste vide, rien n'est arrêté ni
déverrouillé, mais SPC_close est quand même appelé.
"""
function liberer_tous(modules)
    for m in modules
        try; ccall((:SPC_stop_measurement, DLL_SPCM), Int16, (Int16,), Int16(m)); catch; end
    end
    if !isempty(modules)
        try; _set_mode(0, 0, zeros(Int32, 32)); catch; end   # in_use = 0 : déverrouille
    end
    try; ccall((:SPC_close, DLL_SPCM), Int16, ()); catch; end
    return nothing
end

"""
Libère tout ce que cette session tient : arrêt et déverrouillage des seuls
modules prêts (de la sélection en cours, s'il y en a une), puis SPC_close.
Sans cela, SPCM trouverait les cartes « déjà utilisées ».
"""
liberer() = liberer_tous(modules_prets())

_liste_types(types) = join((nom_module(t) for t in types), ", ")

function _resume_cartes(detectes)
    isempty(detectes) && return "aucune carte détectée"
    return join(("module $k : $(nom_module(info_module(k).type)), $(explication_init(etat_init(k)))"
                 for k in detectes), " ; ")
end

"""
Choisit les cartes d'une session parmi les cartes détectées. Erreur si des
cartes de types différents sont présentes et qu'aucun type n'est précisé :
la DLL ne pilote que des cartes d'un même type (manuel DLL, p. 3).
"""
function _choisir(detectes, types)
    type_de = Dict(k => info_module(k).type for k in detectes)
    if types === nothing
        if length(unique(values(type_de))) > 1
            liste = join(("module $k = $(nom_module(t))" for (k, t) in sort!(collect(type_de))), ", ")
            throw(SPCError(-1, "SPC_init",
                "cartes de types différents ($liste) : la DLL n'en pilote qu'un type à la fois. " *
                "Précise le type, par exemple types = (151,) pour les SPC-150N ou " *
                "types = (TYPE_QC104,) pour la QC-104."))
        end
        return Int16.(detectes), Int16[]
    end
    voulus = Int16[k for k in detectes if type_de[k] in types]
    autres = Int16[k for k in detectes if !(type_de[k] in types)]
    return voulus, autres
end

"""
Prend les cartes `voulus` s'il le faut : cartes d'un autre type tenues par
cette session (SPC_init initialise tout ce qu'il trouve), carte voulue pas
encore prête, ou verrou à reprendre (`forcer`). Ne lève pas : un échec se
lit ensuite dans l'état d'initialisation.
"""
function _prendre_si_utile(voulus, autres, forcer::Bool)
    verrouilles = Int16[k for k in voulus if etat_init(k) == -6]
    pas_prets = Int16[k for k in voulus if etat_init(k) != 0]
    autres_tenus = Int16[k for k in autres if info_module(k).utilise == 1]
    if forcer && !isempty(verrouilles)
        @warn "Modules $(Int.(verrouilles)) verrouillés : reprise forcée"
    end
    if (forcer && !isempty(verrouilles)) || !isempty(autres_tenus) ||
       !isempty(setdiff(pas_prets, verrouilles))
        r = _set_mode(0, (forcer && !isempty(verrouilles)) ? 1 : 0, _table_in_use(voulus))
        r < 0 && @warn "SPC_set_mode a renvoyé $r ($(message_erreur(r)))"
    end
    return nothing
end

"""
    avec_spc_tous(f, ini; types=nothing, forcer=false)

Comme `avec_spc`, pour toutes les cartes présentes d'un même type (deux
SPC-150N, par exemple) : `f` reçoit la liste des numéros de modules prêts.
`types` choisit les cartes : `(151,)` pour les SPC-150N, `(TYPE_QC104,)`
pour la QC-104. Obligatoire quand des cartes de types différents sont
installées. Lève une erreur s'il n'y a aucune carte prête. Tout est libéré
à la fin, même sur une erreur. `forcer = true` reprend les modules voulus
restés verrouillés (état -6).
"""
function avec_spc_tous(f, ini::AbstractString; types = nothing, forcer::Bool = false)
    code = initialiser(ini)
    try
        detectes = modules_detectes()
        voulus, autres = _choisir(detectes, types)
        if isempty(voulus)
            throw(SPCError(code < 0 ? code : -1, "SPC_init",
                           "aucune carte $(types === nothing ? "" : "de type " * _liste_types(types) * " ")" *
                           "($(_resume_cartes(detectes)))"))
        end
        _prendre_si_utile(voulus, autres, forcer)
        _SELECTION[] = voulus
        modules = modules_prets()
        if isempty(modules)
            throw(SPCError(code < 0 ? code : -1, "SPC_init",
                           "aucun module prêt ($(_resume_cartes(voulus)))"))
        end
        code < 0 && @warn "SPC_init a renvoyé $code ($(message_erreur(code))) ; modules prêts : $(Int.(modules))"
        return f(modules)
    finally
        try
            liberer()      # seulement les modules prêts de la session ; SPC_close dans tous les cas
        finally
            _SELECTION[] = nothing
        end
    end
end

"""
    avec_spc(f, ini; module_no=0, types=nothing, forcer=false)

Initialise la DLL avec `ini`, vérifie que le module est détecté et prêt,
appelle `f(module_no)`, puis libère tout, même en cas d'erreur. `types`
vérifie que `module_no` est bien du type attendu (les numéros de modules
suivent l'ordre des numéros de série : ajouter une carte peut les
décaler). Obligatoire quand des cartes de types différents sont
installées. `forcer = true` reprend un module resté verrouillé (état -6).
"""
function avec_spc(f, ini::AbstractString; module_no::Integer = 0, types = nothing,
                  forcer::Bool = false)
    code = initialiser(ini)
    try
        detectes = modules_detectes()
        module_no in detectes ||
            throw(SPCError(-1, "SPC_init",
                           "module $module_no non détecté (modules détectés : $(Int.(detectes)))"))
        t = info_module(module_no).type
        _choisir(detectes, types)          # erreur si des types différents sont présents sans précision
        if types !== nothing && !(t in types)
            throw(SPCError(-1, "SPC_init",
                           "le module $module_no est une $(nom_module(t)), pas une " *
                           "$(_liste_types(types)) ($(_resume_cartes(detectes)))"))
        end
        voulus = Int16[module_no]
        autres = Int16[k for k in detectes if info_module(k).type != t]
        _prendre_si_utile(voulus, autres, forcer)
        _SELECTION[] = voulus              # liberer n'arrêtera que ce module
        etat = etat_init(module_no)
        etat == 0 || throw(SPCError(etat, "SPC_init", explication_init(etat, code)))
        code < 0 && @warn "SPC_init a renvoyé $code, mais le module $module_no est prêt : $(message_erreur(code))"
        return f(Int16(module_no))
    finally
        try
            liberer()      # seulement les modules prêts ; SPC_close dans tous les cas
        finally
            _SELECTION[] = nothing
        end
    end
end

# =====================================================================
# Identification
# =====================================================================

"""État d'initialisation du module (0 = prêt ; voir MESSAGES_INIT)."""
etat_init(m::Integer) = Int(ccall((:SPC_get_init_status, DLL_SPCM), Int16, (Int16,), Int16(m)))

"""Type du module (151 = SPC-150N, 104 = SPC-QC-104) ; valeur < 0 = erreur. Lit le matériel : module prêt seulement."""
type_module(m::Integer) = Int(ccall((:SPC_test_id, DLL_SPCM), Int16, (Int16,), Int16(m)))

"""
    info_module(m) -> (type, bus, slot, utilise, init, adresse)

SPCModInfo. `utilise` : -1 verrouillé par un autre programme, 0 libre, 1 pris ici.
Lit les structures internes de la DLL : sans risque pour les modules 0 à 7.
"""
function info_module(m::Integer)
    buf = zeros(Int16, 16)            # 6 short utiles, marge
    chk_spc(ccall((:SPC_get_module_info, DLL_SPCM), Int16, (Int16, Ptr{Int16}),
                  Int16(m), buf), "SPC_get_module_info")
    return (type = Int(buf[1]), bus = Int(buf[2]), slot = Int(buf[3]),
            utilise = Int(buf[4]), init = Int(buf[5]),
            adresse = Int(reinterpret(UInt16, buf[6])))
end

"""
    eeprom(m) -> (type, serie, date)

Données de production écrites par B&H dans la carte : les lire prouve
qu'on parle bien au matériel, pas à un simulateur. Lit le matériel :
module prêt seulement.
"""
function eeprom(m::Integer)
    buf = zeros(UInt8, 1024)          # 3 × char[16] puis les réglages d'usine
    chk_spc(ccall((:SPC_get_eeprom_data, DLL_SPCM), Int16, (Int16, Ptr{UInt8}),
                  Int16(m), buf), "SPC_get_eeprom_data")
    function champ(i)
        b = buf[16i + 1:16i + 16]
        k = findfirst(==(0x00), b)
        return strip(String(b[1:(k === nothing ? 16 : k - 1)]))
    end
    return (type = champ(0), serie = champ(1), date = champ(2))
end

# =====================================================================
# Paramètres (toujours via des fichiers .ini)
# =====================================================================

const TAILLE_SPCDATA = 4096   # bien plus que sizeof(SPCdata) (256 octets) : marge volontaire

"""
    lire_parametres(m; fichier) -> Dict{String,Float64}

Paramètres réellement appliqués au module, après les recalculs de la DLL
(SPC_get_parameters, puis SPC_save_parameters_to_inifile). Pour la QC-104,
les clés gardent les noms de la DLL : `relire_qc` les traduit.
"""
function lire_parametres(m::Integer;
                         fichier::AbstractString = joinpath(tempdir(), "spc_relu_$(m).ini"))
    buf = zeros(UInt8, TAILLE_SPCDATA)
    chk_spc(ccall((:SPC_get_parameters, DLL_SPCM), Int16, (Int16, Ptr{UInt8}),
                  Int16(m), buf), "SPC_get_parameters")
    isfile(fichier) && rm(fichier)
    chk_spc(ccall((:SPC_save_parameters_to_inifile, DLL_SPCM), Int16,
                  (Ptr{UInt8}, Cstring, Ptr{UInt8}, Cint),
                  buf, abspath(fichier), C_NULL, Cint(0)),
            "SPC_save_parameters_to_inifile")
    return lire_ini(fichier)
end

"""
    comparer_parametres(demandes, lus) -> Vector

Pour chaque clé demandée (fichier .ini), la valeur que la carte applique
vraiment (relue par `lire_parametres`). statut : :ok ; :ecart, valeur
recalculée loin de la demande ; :absente, clé inconnue de la DLL (faute de
frappe, le plus souvent : la DLL ignore alors la ligne sans rien dire).
Tolérance : les entiers doivent être identiques ; les seuils en mV, les
pourcentages et les décalages (arrondis par les convertisseurs de la
carte) à 3 % ou une unité près ; les autres réels (temps en s ou en ns) à
3 % près. Les clés de la QC-104 en mV (cfd_holdoff, sync_holdoff) suivent
la règle des seuils.
"""
function comparer_parametres(demandes::AbstractDict, lus::AbstractDict)
    sortie = NamedTuple{(:cle, :demande, :applique, :statut),Tuple{String,Any,Float64,Symbol}}[]
    en_mv_ou_pourcent(cle) = occursin(r"limit|zc_level|threshold|offset|holdoff", cle)
    for cle in sort!(String.(collect(keys(demandes))))
        d = demandes[cle]
        a = Float64(get(lus, lowercase(cle), NaN))
        tolerance = d isa Real ? max(0.03 * abs(d), en_mv_ou_pourcent(lowercase(cle)) ? 1.0 : 1e-12) : 0.0
        statut = isnan(a) ? :absente :
                 d isa Integer ? (a == d ? :ok : :ecart) :
                 d isa Real ? (abs(a - d) <= tolerance ? :ok : :ecart) : :ok
        push!(sortie, (cle = cle, demande = d, applique = a, statut = statut))
    end
    return sortie
end

"""
    afficher_parametres(m, reglages, imposes, lus; io=stdout)

Tableau « demandé → appliqué par la carte » pour les clés de
reglages_spc.jl, puis les clés imposées par le script. Signale les clés
inconnues de la DLL et les valeurs que la carte n'a pas prises.
Pour la QC-104, voir `afficher_qc`.
"""
function afficher_parametres(m, reglages::AbstractDict, imposes::AbstractDict, lus::AbstractDict;
                             io::IO = stdout)
    valeur(a) = isnan(a) ? "—" : @sprintf("%.5g", a)
    println(io, "Module $m : reglages_spc.jl → valeur appliquée par la carte")
    for l in comparer_parametres(reglages, lus)
        note = haskey(imposes, l.cle) ? "  (remplacé par ce script : $(imposes[l.cle]))" :
               l.statut == :absente ? "  ← CLÉ INCONNUE de la DLL, ligne ignorée (faute de frappe ?)" :
               l.statut == :ecart ? "  ← DIFFÉRENT de la demande" : ""
        @printf(io, "  %-16s %10s → %-10s%s\n", l.cle, string(l.demande), valeur(l.applique), note)
    end
    println(io, "  imposés par ce script : ",
            join(("$k = $(imposes[k])" for k in sort!(String.(collect(keys(imposes))))), ", "))
    for l in comparer_parametres(imposes, lus)
        l.statut == :ok && continue
        println(io, "  ← ", l.cle, " : la carte applique ", valeur(l.applique), " au lieu de ", l.demande)
    end
    return nothing
end

"""
    ecart_peigne(h, a, b, g) -> (ecart, sigma)

Peigne d'une courbe entre les indices `a` et `b`, par groupes de `g`
canaux : `ecart` ≈ rapport des groupes forts aux groupes faibles, moins 1
(0 pour une courbe lisse) ; `sigma`, son incertitude due au bruit de
comptage. Chaque groupe est comparé à la moyenne de ses deux voisins, ce
qui annule la pente du déclin. Un écart de plusieurs %, bien au-dessus de
4 sigma, trahit la non-linéarité de l'ADC quand sa correction d'erreur est
coupée (dither_range = 0).
"""
function ecart_peigne(h::AbstractVector, a::Integer, b::Integer, g::Integer)
    J = (b - a + 1) ÷ g
    J >= 6 || return (ecart = 0.0, sigma = Inf)
    G = [sum(Float64, view(h, a + (j - 1) * g:a + j * g - 1)) for j in 1:J]
    moyenne = sum(G) / J
    moyenne > 0 || return (ecart = 0.0, sigma = Inf)
    D = 0.0
    for j in 2:J - 1
        D += (isodd(j) ? 1 : -1) * (G[j] - (G[j - 1] + G[j + 1]) / 2)
    end
    delta = min(abs(D) / (J - 2) / (2 * moyenne), 0.99)   # G ≈ moyenne × (1 ± delta)
    return (ecart = 2 * delta / (1 - delta), sigma = sqrt(4 / (moyenne * (J - 2))))
end

"""
    appliquer_ini(m, ini)

Envoie au module les paramètres d'un fichier .ini, sans réinitialiser la
DLL (SPC_read_parameters_from_inifile, puis SPC_set_parameters). Les
paramètres absents du fichier reprennent leur valeur par défaut.
"""
function appliquer_ini(m::Integer, ini::AbstractString)
    buf = zeros(UInt8, TAILLE_SPCDATA)
    chk_spc(ccall((:SPC_read_parameters_from_inifile, DLL_SPCM), Int16,
                  (Ptr{UInt8}, Cstring), buf, abspath(ini)),
            "SPC_read_parameters_from_inifile")
    chk_spc(ccall((:SPC_set_parameters, DLL_SPCM), Int16, (Int16, Ptr{UInt8}),
                  Int16(m), buf), "SPC_set_parameters")
    return nothing
end

# =====================================================================
# Paramètres de la SPC-QC-104
#
# La DLL réutilise des clés de la SPC-150 avec un autre sens (manuel DLL
# 5.0, p. 5-12, et notes « for SPC-QC-104 ») :
#   seuil (mV, -500 à 0)       : IN1 cfd_limit_low, IN2 cfd_limit_high,
#                                IN3 cfd_zc_level, SYNC (IN4) sync_threshold
#   niveau de zéro (mV, ±96)   : IN1 tac_limit_high, IN2 sync_holdoff,
#                                IN3 cfd_holdoff, SYNC (IN4) sync_zc_level
#   plage du TDC               : tac_range, 1,024 ns à 67 µs
#   points par courbe          : adc_resolution, en bits (FIFO : toujours 4096)
#   retard de lecture du routage : ext_latch_delay, -57 à 65 ns par pas de 8,192
#   décalage par entrée        : tdc_offset1 à tdc_offset4, 0 à 32,256 ns par pas de 0,512
#   limite basse de la fenêtre : tac_limit_low, en % de la plage (« Limit Low » de SPCM).
#                                Défaut de la DLL : 10 %, soit les 1,64 premières ns coupées à
#                                16,384 ns (vu sur la carte : rien sous le canal 411).
#                                parametres_qc écrit toujours 0 (ou limite_basse_pct).
#   entrées actives, routage, mode photon : tdc_control (bits ci-dessous)
#   mode                       : 0 histogramme, 1 FIFO, 13 FIFO en temps absolu
#   macro_time_clk             : 0 = 2,048 ns en FIFO, 4 ps en temps absolu
# =====================================================================

"""Clés de la DLL pour IN1, IN2, IN3 et SYNC (IN4) de la QC-104."""
const CLES_QC = (
    seuil    = ("cfd_limit_low", "cfd_limit_high", "cfd_zc_level", "sync_threshold"),
    zc       = ("tac_limit_high", "sync_holdoff", "cfd_holdoff", "sync_zc_level"),
    decalage = ("tdc_offset1", "tdc_offset2", "tdc_offset3", "tdc_offset4"),
)

"""
    controle_tdc(entrees, routage, photon_unique; routage_in4_abs=false) -> Int

Valeur de tdc_control (manuel DLL, p. 9 et 12) :
- bits 4 à 7 : entrées IN1, IN2, IN3, IN4 (SYNC) actives ;
- bits 16 à 18 : routage appliqué aux photons de IN1, IN2, IN3 (modes FIFO) ;
- bit 19 : routage de IN4 en FIFO temps absolu ;
- bit 20 : 1 = un photon par période (« single photon »), 0 = détection multiphoton.
`entrees` : 4 booléens (IN1, IN2, IN3, SYNC) ; `routage` : 3 booléens.
"""
function controle_tdc(entrees, routage, photon_unique::Bool; routage_in4_abs::Bool = false)
    length(entrees) == 4 || error("entrees : 4 valeurs (IN1, IN2, IN3, SYNC)")
    length(routage) == 3 || error("routage : 3 valeurs (IN1, IN2, IN3)")
    v = UInt32(0)
    for i in 1:4
        entrees[i] && (v |= UInt32(1) << (3 + i))
    end
    for i in 1:3
        routage[i] && (v |= UInt32(1) << (15 + i))
    end
    routage_in4_abs && (v |= UInt32(1) << 19)
    photon_unique && (v |= UInt32(1) << 20)
    return Int(v)
end

"""Décrit une valeur de tdc_control en clair."""
function decrire_controle_tdc(v::Integer)
    u = UInt32(v)
    b(i) = (u >> i) & 0x1 == 0x1
    actives = [n for (i, n) in enumerate(("IN1", "IN2", "IN3", "SYNC")) if b(3 + i)]
    rout = [n for (i, n) in enumerate(("IN1", "IN2", "IN3")) if b(15 + i)]
    s = "entrées actives : " * (isempty(actives) ? "aucune" : join(actives, ", ")) *
        " ; routage sur : " * (isempty(rout) ? "aucune" : join(rout, ", ")) *
        " ; " * (b(20) ? "un photon par période" : "détection multiphoton")
    b(19) && (s *= " ; routage de IN4 en temps absolu")
    autres = u & ~(UInt32(0xf0) | UInt32(0x1f0000))
    autres != 0 && (s *= @sprintf(" ; autres bits : 0x%x", autres))
    return s
end

"""
    parametres_qc(r) -> Dict{String,Any}

Traduit les réglages de reglages_qc.jl (noms clairs) en clés de la DLL
pour la QC-104. Clés attendues dans `r` : "seuil_mV", "zc_mV",
"decalage_ns" (4 valeurs : IN1, IN2, IN3, SYNC), "entrees_actives"
(4 booléens), "routage_entrees" (3 booléens), "photon_unique",
"plage_tdc_ns", "diviseur_sync", "retard_routage_ns", "limite_basse_pct".
Les clés absentes ne sont pas écrites (la DLL garde alors sa valeur par
défaut), sauf trois, toujours écrites : tdc_control (son défaut, 0, coupe
toutes les entrées), stop_on_ovfl = 0 et tac_limit_low (défaut de la DLL :
10 % de la plage coupés au début de la fenêtre ; ici 0 sauf si
"limite_basse_pct" dit autre chose).
"""
function parametres_qc(r::AbstractDict)
    p = Dict{String,Any}()
    function quatre(nom)
        v = r[nom]
        length(v) == 4 || error("$nom : 4 valeurs attendues (IN1, IN2, IN3, SYNC)")
        return Float64.(collect(v))
    end
    if haskey(r, "seuil_mV")
        for (cle, v) in zip(CLES_QC.seuil, quatre("seuil_mV"))
            -500.0 <= v <= 0.0 || error("seuil_mV : $v hors de -500 à 0 mV")
            p[cle] = v
        end
    end
    if haskey(r, "zc_mV")
        for (cle, v) in zip(CLES_QC.zc, quatre("zc_mV"))
            -96.0 <= v <= 96.0 || error("zc_mV : $v hors de -96 à 96 mV")
            p[cle] = v
        end
    end
    if haskey(r, "decalage_ns")
        for (cle, v) in zip(CLES_QC.decalage, quatre("decalage_ns"))
            0.0 <= v <= 32.256 || error("decalage_ns : $v hors de 0 à 32,256 ns")
            p[cle] = v
        end
    end
    haskey(r, "plage_tdc_ns") && (p["tac_range"] = Float64(r["plage_tdc_ns"]))
    haskey(r, "diviseur_sync") && (p["sync_freq_div"] = Int(r["diviseur_sync"]))
    if haskey(r, "retard_routage_ns")
        d = round(Int, r["retard_routage_ns"])           # entier en ns ; la DLL arrondit au pas de 8,192 ns
        -57 <= d <= 65 || error("retard_routage_ns : $d hors de -57 à 65 ns")
        p["ext_latch_delay"] = d
    end
    # Pas d'arrêt sur débordement : la valeur par défaut de la DLL (1) n'a pas de sens en
    # FIFO et pourrait empêcher la QC-104 de s'armer. qc6 (histogramme) la remet à 1.
    p["stop_on_ovfl"] = 0
    # Limite basse de la fenêtre (« Limit Low » de SPCM) : la DLL met 10 % par défaut, ce qui
    # coupe le début du déclin (1,64 ns à 16,384 ns de plage). Toujours écrite.
    lb = Float64(get(r, "limite_basse_pct", 0.0))
    0.0 <= lb <= 100.0 || error("limite_basse_pct : $lb hors de 0 à 100 %")
    p["tac_limit_low"] = lb
    p["tdc_control"] = controle_tdc(get(r, "entrees_actives", (true, true, true, true)),
                                    get(r, "routage_entrees", (true, true, true)),
                                    Bool(get(r, "photon_unique", false)))
    return p
end

"""
    relire_qc(lus) -> NamedTuple

Valeurs appliquées par la QC-104, relues par `lire_parametres`, en clair.
`NaN` quand la DLL n'a pas écrit la clé.
"""
function relire_qc(lus::AbstractDict)
    g(c) = Float64(get(lus, c, NaN))
    tdc = get(lus, "tdc_control", NaN)
    return (seuil_mV = map(g, CLES_QC.seuil), zc_mV = map(g, CLES_QC.zc),
            decalage_ns = map(g, CLES_QC.decalage), plage_tdc_ns = g("tac_range"),
            bits_points = g("adc_resolution"), diviseur_sync = g("sync_freq_div"),
            retard_routage_ns = g("ext_latch_delay"), mode = g("mode"),
            controle_tdc = isnan(tdc) ? missing : Int(tdc),
            tac_offset = g("tac_offset"), tac_limit_low = g("tac_limit_low"))
end

"""
    afficher_qc(reglages, lus; io=stdout) -> Bool

Tableau « demandé → appliqué » pour la QC-104, en noms clairs, avec la clé
de la DLL entre parenthèses. Renvoie `true` si tout est appliqué.
"""
function afficher_qc(reglages::AbstractDict, lus::AbstractDict; io::IO = stdout)
    p = parametres_qc(reglages)
    lignes = Tuple{String,String}[]
    for (i, n) in enumerate(("IN1", "IN2", "IN3", "SYNC"))
        push!(lignes, ("seuil $n (mV)", CLES_QC.seuil[i]))
        push!(lignes, ("zéro $n (mV)", CLES_QC.zc[i]))
        push!(lignes, ("décalage $n (ns)", CLES_QC.decalage[i]))
    end
    append!(lignes, [("plage du TDC (ns)", "tac_range"), ("diviseur du SYNC", "sync_freq_div"),
                     ("retard du routage (ns)", "ext_latch_delay"), ("limite basse (% plage)", "tac_limit_low"),
                     ("contrôle du TDC", "tdc_control")])
    ok = true
    valeur(a) = isnan(a) ? "—" : @sprintf("%.5g", a)
    for (nom, cle) in lignes
        haskey(p, cle) || continue
        d = p[cle]
        l = only(comparer_parametres(Dict(cle => d), lus))
        if cle == "tdc_control" && !isnan(l.applique)
            # Hors FIFO, la carte fixe les bits 16 à 19 elle-même (manuel DLL, p. 12) :
            # on compare les entrées (bits 4 à 7) et le mode photon (bit 20).
            masque = UInt32(0xf0) | (UInt32(1) << 20)
            fifo = get(lus, "mode", 1.0) != 0.0
            fifo && (masque |= UInt32(0x70000))
            bon = (UInt32(d) & masque) == (UInt32(round(Int, l.applique)) & masque)
            l = (cle = l.cle, demande = l.demande, applique = l.applique, statut = bon ? :ok : :ecart)
        end
        note = l.statut == :absente ? "  ← clé absente du fichier relu" :
               l.statut == :ecart ? "  ← DIFFÉRENT de la demande" : ""
        l.statut == :ok || (ok = false)
        @printf(io, "  %-24s %10s → %-10s (%s)%s\n", nom, string(d), valeur(l.applique), cle, note)
    end
    if haskey(lus, "tdc_control")
        println(io, "  tdc_control appliqué : ", decrire_controle_tdc(round(Int, lus["tdc_control"])))
    end
    return ok
end

# =====================================================================
# Taux et SYNC
# =====================================================================

"""0 pas de SYNC, 1 correct, 2 ou 3 surcharge (voir MESSAGES_SYNC)."""
function sync_etat(m::Integer)
    s = Ref{Int16}(0)
    chk_spc(ccall((:SPC_get_sync_state, DLL_SPCM), Int16, (Int16, Ptr{Int16}),
                  Int16(m), s), "SPC_get_sync_state")
    return Int(s[])
end

"""Remet les compteurs de taux à zéro ; obligatoire avant le premier `taux`."""
effacer_taux(m::Integer) =
    chk_spc(ccall((:SPC_clear_rates, DLL_SPCM), Int16, (Int16,), Int16(m)), "SPC_clear_rates")

"""
    taux(m) -> (code, sync, cfd, tac, adc)

Taux en coups/s, avec les noms de la SPC-150N. `code` < 0 : valeurs pas
encore prêtes (le temps d'intégration, rate_count_time, n'est pas écoulé)
ou erreur. Pour la QC-104, le sens des 4 valeurs n'est pas documenté :
voir `taux_bruts` et qc3_entrees.jl.
"""
function taux(m::Integer)
    v = zeros(Float32, 16)            # rate_values : 4 float ; marge
    r = Int(ccall((:SPC_read_rates, DLL_SPCM), Int16, (Int16, Ptr{Float32}), Int16(m), v))
    return (code = r, sync = Float64(v[1]), cfd = Float64(v[2]),
            tac = Float64(v[3]), adc = Float64(v[4]))
end

"""
    taux_bruts(m) -> (code, valeurs)

Les 8 premiers float écrits par SPC_read_rates, sans interprétation : la
structure rate_values en a 4, une DLL plus récente pourrait en écrire
davantage pour les 4 entrées de la QC-104.
"""
function taux_bruts(m::Integer)
    v = zeros(Float32, 16)
    r = Int(ccall((:SPC_read_rates, DLL_SPCM), Int16, (Int16, Ptr{Float32}), Int16(m), v))
    return (code = r, valeurs = Float64.(v[1:8]))
end

# =====================================================================
# Mesure FIFO
# =====================================================================

_start(m) = Int(ccall((:SPC_start_measurement, DLL_SPCM), Int16, (Int16,), Int16(m)))

"""
Démarre la mesure. Si la carte refuse de s'armer (code -20, « cannot arm »,
vu sur la QC-104), arrête une éventuelle mesure restée armée et réessaie une
fois. En cas d'échec, l'erreur donne les bits d'état et l'état du SYNC.
"""
function demarrer(m::Integer)
    r = _start(m)
    if r == -20
        try; ccall((:SPC_stop_measurement, DLL_SPCM), Int16, (Int16,), Int16(m)); catch; end
        sleep(0.1)
        r = _start(m)
    end
    if r < 0
        etat = try
            "0x" * string(etat_mesure(m); base = 16, pad = 4)
        catch
            "?"
        end
        sync = try
            s = sync_etat(m)
            get(MESSAGES_SYNC, s, string(s))
        catch
            "?"
        end
        throw(SPCError(r, "SPC_start_measurement",
                       message_erreur(r) * " (état $etat, $sync ; réessayé une fois après SPC_stop_measurement)"))
    end
    return r
end

"""Arrête la mesure. En mode FIFO, l'arrêt vide le FIFO : lire avant d'arrêter."""
arreter(m::Integer) = chk_spc(ccall((:SPC_stop_measurement, DLL_SPCM), Int16, (Int16,),
                                    Int16(m)), "SPC_stop_measurement")

"""Bits d'état de la mesure (SPC_ARMED, SPC_FOVFL, SPC_FEMPTY…)."""
function etat_mesure(m::Integer)
    s = Ref{Int16}(0)
    chk_spc(ccall((:SPC_test_state, DLL_SPCM), Int16, (Int16, Ptr{Int16}),
                  Int16(m), s), "SPC_test_state")
    return reinterpret(UInt16, s[])
end

"""
    fifo_init(m) -> (type_fifo, type_flux, horloge_macro_s, entete, mt_clock)

Format du flux (7 = FIFO_150 pour la famille SPC-15x ; 11 = FIFO_TDC et
12 = FIFO_TDC_ABS pour la QC-104), valeur brute de mt_clock (dixièmes de
ns) et durée d'un tic qui s'en déduit, en secondes. Pour la QC-104, cette
durée ne peut pas valoir 2,048 ns : utiliser `tic_macro_s`. `entete` est
le premier mot d'un fichier .spc. À appeler une fois le mode FIFO réglé.
"""
function fifo_init(m::Integer)
    ft = Ref{Int16}(0); st = Ref{Int16}(0); mt = Ref{Cint}(0); h = Ref{Cuint}(0)
    chk_spc(ccall((:SPC_get_fifo_init_vars, DLL_SPCM), Int16,
                  (Int16, Ptr{Int16}, Ptr{Int16}, Ptr{Cint}, Ptr{Cuint}),
                  Int16(m), ft, st, mt, h), "SPC_get_fifo_init_vars")
    return (type_fifo = Int(ft[]), type_flux = Int(st[]),
            horloge_macro_s = mt[] * 1e-10, entete = UInt32(h[]), mt_clock = Int(mt[]))
end

"""
    tic_macro_s(m) -> Float64

Durée d'un tic du macrotemps, en secondes. SPC-QC-104 : 2,048 ns en FIFO,
4 ps en FIFO temps absolu (manuel DLL, macro_time_clk = 0) ; à vérifier
avec des marqueurs de période connue (qc4, qc5). Autres cartes : mt_clock
de SPC_get_fifo_init_vars. À appeler une fois le mode FIFO réglé.
"""
function tic_macro_s(m::Integer)
    f = fifo_init(m)
    if est_qc(info_module(m).type)
        return f.type_fifo == 12 ? 4e-12 : 2.048e-9
    end
    return f.horloge_macro_s
end

"""
    largeur_canal_s(type, lus; canaux=4096) -> Float64

Largeur d'un canal du microtemps, en secondes, d'après les paramètres
relus : QC-104, tac_range / canaux ; SPC-150N, tac_range / tac_gain / canaux.
"""
function largeur_canal_s(t::Integer, lus::AbstractDict; canaux::Integer = 4096)
    plage = get(lus, "tac_range", NaN) * 1e-9
    est_qc(t) && return plage / canaux
    return plage / get(lus, "tac_gain", 1.0) / canaux
end

# =====================================================================
# Mode histogramme (mode 0, « Single » dans SPCM) : la carte construit
# elle-même le déclin dans sa mémoire pendant le temps de collecte.
# Manuel DLL : SPC_configure_memory, SPC_set_page, SPC_fill_memory,
# SPC_read_data_block. Module prêt seulement, comme partout.
# =====================================================================

"""
    configurer_memoire(m, resolution_adc, bits_routage=0)
        -> (blocs, blocs_par_trame, trames_par_page, pages, longueur_bloc)

Découpe la mémoire en courbes de 2^resolution_adc canaux. À appeler après
SPC_init et après tout changement de adc_resolution. SPCMemConfig : quatre
long (32 bits sous Windows) puis block_length, lus dans un tampon opaque.
"""
function configurer_memoire(m::Integer, resolution_adc::Integer, bits_routage::Integer = 0)
    b = zeros(UInt8, 64)
    chk_spc(ccall((:SPC_configure_memory, DLL_SPCM), Int16, (Int16, Int16, Int16, Ptr{UInt8}),
                  Int16(m), Int16(resolution_adc), Int16(bits_routage), b), "SPC_configure_memory")
    long(o) = Int(reinterpret(Int32, b[o + 1:o + 4])[1])
    return (blocs = long(0), blocs_par_trame = long(4), trames_par_page = long(8),
            pages = long(12), longueur_bloc = Int(reinterpret(Int16, b[17:18])[1]))
end

"""Page de mémoire où la prochaine mesure s'enregistre."""
definir_page(m::Integer, page::Integer) =
    chk_spc(ccall((:SPC_set_page, DLL_SPCM), Int16, (Int16, Clong), Int16(m), Clong(page)),
            "SPC_set_page")

"""
    effacer_memoire(m; bloc=-1, page=0)

Remplit de zéros un bloc (-1 : tous) d'une page (-1 : toutes), puis attend
que la carte ait fini (bit SPC_HFILL_NRDY).
"""
function effacer_memoire(m::Integer; bloc::Integer = -1, page::Integer = 0, delai_max_s = 5.0)
    r = chk_spc(ccall((:SPC_fill_memory, DLL_SPCM), Int16, (Int16, Clong, Clong, UInt16),
                      Int16(m), Clong(bloc), Clong(page), 0x0000), "SPC_fill_memory")
    t0 = time()
    while r > 0 && (etat_mesure(m) & SPC_HFILL_NRDY) != 0
        time() - t0 > delai_max_s && error("module $m : la mémoire ne finit pas de s'effacer")
        sleep(0.002)
    end
    return nothing
end

"""
    lire_bloc(m, n; bloc=0, page=0) -> Vector{UInt16}

Lit une courbe de `n` canaux dans la mémoire de la carte, sans réduction.
"""
function lire_bloc(m::Integer, n::Integer; bloc::Integer = 0, page::Integer = 0)
    d = zeros(UInt16, n)
    chk_spc(ccall((:SPC_read_data_block, DLL_SPCM), Int16,
                  (Int16, Clong, Clong, Int16, Int16, Int16, Ptr{UInt16}),
                  Int16(m), Clong(bloc), Clong(page), Int16(1), Int16(0), Int16(n - 1), d),
            "SPC_read_data_block")
    return d
end

"""Remplissage du FIFO de la carte, de 0 à 1."""
function remplissage_fifo(m::Integer)
    u = Ref{Float32}(0)
    chk_spc(ccall((:SPC_get_fifo_usage, DLL_SPCM), Int16, (Int16, Ptr{Float32}),
                  Int16(m), u), "SPC_get_fifo_usage")
    return Float64(u[])
end

"""
    lire_fifo!(m, tampon) -> n

Copie dans `tampon` ce que le FIFO contient, sans attendre. Renvoie le
nombre de mots de 16 bits écrits (un enregistrement = 2 mots). Pour la
QC-104, la DLL rend les données brutes, sans regrouper les débordements du
macrotemps, et lit au plus 12 Mo par appel (notes de version 5.1.0).
"""
function lire_fifo!(m::Integer, tampon::Vector{UInt16})
    n = Ref{Culong}(length(tampon) - isodd(length(tampon)))
    chk_spc(ccall((:SPC_read_fifo, DLL_SPCM), Int16, (Int16, Ptr{Culong}, Ptr{UInt16}),
                  Int16(m), n, tampon), "SPC_read_fifo")
    return Int(n[])
end

# =====================================================================
# Décodage du flux FIFO de la famille SPC-150 (type FIFO_150), version 8
# =====================================================================

"""Le macrotemps est un compteur 12 bits : il déborde tous les 4096 tics."""
const PERIODE_MT = Int64(4096)

"""
    Decodeur(; garder_photons=false)

Décode le flux FIFO 32 bits des SPC-130/140/15x/16x/830. Un
enregistrement, lu en petit-boutiste :

    bits  0-11  macrotemps (compteur 12 bits)
    bits 12-15  routage (photon) ou entrées M0-M3 (marqueur)
    bits 16-27  valeur de l'ADC (microtemps)
    bit  28 MARK   bit 29 GAP   bit 30 MTOV   bit 31 INVALID

- INVALID et MTOV sans MARK : plusieurs débordements du macrotemps d'un
  coup, leur nombre est dans les bits 0-27 ;
- sinon MTOV ajoute un débordement juste avant l'événement ;
- MARK et INVALID : un marqueur par bit à 1 dans les bits 12-15 ;
- ni MARK ni INVALID : photon valide ; INVALID seul : photon rejeté ;
- GAP : des données ont été perdues juste avant (FIFO plein).

Le routage est actif à l'état bas : le bit vaut 1 quand l'entrée TTL est
à 0 V. Le microtemps croissant vaut 4095 - ADC (start-stop inversé).
Gardé tel quel pour les scripts SPC-150N ; `DecodeurFIFO(FORMAT_SPC150)`
fait la même chose avec la sortie commune aux deux cartes.
"""
mutable struct Decodeur
    base::Int64                        # débordements cumulés × 4096, en tics
    reste::UInt16                      # mot isolé en attente de son partenaire
    a_reste::Bool
    photons::Int
    rejetes::Int
    pertes::Int                        # enregistrements portant GAP
    inattendus::Int                    # MARK sans INVALID (non documenté)
    routage::Vector{Int}               # 16 compteurs, indice = routage + 1
    adc::Vector{Int}                   # 4096 compteurs, indice = ADC + 1
    marqueurs::Vector{Vector{Int64}}   # temps (tics) des fronts, M0..M3
    garder_photons::Bool
    t_photons::Vector{Int64}
    adc_photons::Vector{UInt16}
    routage_photons::Vector{UInt8}
end

Decodeur(; garder_photons::Bool = false) =
    Decodeur(0, 0x0000, false, 0, 0, 0, 0, zeros(Int, 16), zeros(Int, 4096),
             [Int64[] for _ in 1:4], garder_photons, Int64[], UInt16[], UInt8[])

"""Remet le décodeur à zéro (nouvelle mesure : le macrotemps repart de 0)."""
function reinitialiser!(d::Decodeur)
    d.base = 0; d.a_reste = false
    d.photons = 0; d.rejetes = 0; d.pertes = 0; d.inattendus = 0
    fill!(d.routage, 0); fill!(d.adc, 0)
    foreach(empty!, d.marqueurs)
    empty!(d.t_photons); empty!(d.adc_photons); empty!(d.routage_photons)
    return d
end

"""
    decoder!(d, mots, n=length(mots))

Décode les `n` premiers mots de 16 bits de `mots` et cumule dans `d`.
Un mot isolé en fin de tampon est gardé pour l'appel suivant.
"""
function decoder!(d::Decodeur, mots::AbstractVector{UInt16}, n::Integer = length(mots))
    i = 1
    if d.a_reste && n >= 1
        _enregistrement!(d, UInt32(d.reste) | (UInt32(mots[1]) << 16))
        d.a_reste = false
        i = 2
    end
    while i + 1 <= n
        _enregistrement!(d, UInt32(mots[i]) | (UInt32(mots[i + 1]) << 16))
        i += 2
    end
    if i == n
        d.reste = mots[n]
        d.a_reste = true
    end
    return d
end

function _enregistrement!(d::Decodeur, w::UInt32)
    invalide = (w >> 31) & 0x1 == 0x1
    mtov     = (w >> 30) & 0x1 == 0x1
    gap      = (w >> 29) & 0x1 == 0x1
    mark     = (w >> 28) & 0x1 == 0x1
    if invalide && mtov && !mark                     # débordements multiples
        d.base += PERIODE_MT * Int64(w & 0x0fffffff)
        gap && (d.pertes += 1)
        return nothing
    end
    mtov && (d.base += PERIODE_MT)
    gap && (d.pertes += 1)
    t = d.base + Int64(w & 0x0fff)
    haut = Int((w >> 12) & 0xf)
    if !mark
        if invalide
            d.rejetes += 1
        else
            adc = Int((w >> 16) & 0x0fff)
            d.photons += 1
            d.routage[haut + 1] += 1
            d.adc[adc + 1] += 1
            if d.garder_photons
                push!(d.t_photons, t)
                push!(d.adc_photons, UInt16(adc))
                push!(d.routage_photons, UInt8(haut))
            end
        end
    elseif invalide
        for b in 0:3
            (haut >> b) & 1 == 1 && push!(d.marqueurs[b + 1], t)
        end
    else
        d.inattendus += 1
    end
    return nothing
end

# =====================================================================
# Décodeur commun : format décrit par un FormatFIFO
# =====================================================================

"""
    FormatFIFO(; nom, macrotemps, microtemps, ...)

Description d'un format d'enregistrement FIFO de 32 bits, assez générale
pour la famille SPC-150 (FORMAT_SPC150) et pour la QC-104 (format établi
puis vérifié contre la DLL par qc4_format_fifo.jl). Un champ est un couple
(décalage, nombre de bits) ; un bit vaut -1 quand il n'existe pas. Règles,
dans l'ordre :

1. `(w & masque_debord) == valeur_debord` : enregistrement de débordements
   seuls ; leur nombre est le champ `compte` ((0, 0) : un seul) ;
2. sinon, `bit_mtov` à 1 : un débordement juste avant l'événement ;
   `bit_perte` à 1 : des données perdues juste avant (FIFO plein) ;
3. temps de l'événement = débordements × 2^bits du macrotemps + macrotemps ;
4. `(w & masque_marqueur) == valeur_marqueur` : marqueur ; Mk est présent
   si le bit `bits_marqueurs[k+1]` vaut 1 ;
5. `(w & masque_photon) == valeur_photon` : photon ; `bit_invalide` à 1 :
   photon rejeté ; sinon microtemps (inversé si `micro_inverse`, pour que
   le temps croisse avec le canal), routage et voie ;
6. tout le reste est compté comme inattendu.

`mots_inverses` : le mot de 16 bits de poids fort arrive en premier.
`voie` : champ qui donne l'entrée du photon ((0, 0) : pas de champ, la
voie est celle passée au décodeur) ; `valeurs_voie[i]` est la valeur du
champ pour l'entrée i (IN1, IN2, IN3, IN4), -1 si inconnue.
"""
Base.@kwdef struct FormatFIFO
    nom::String
    mots_inverses::Bool = false
    macrotemps::Tuple{Int,Int}
    microtemps::Tuple{Int,Int}
    micro_inverse::Bool = false
    routage::Tuple{Int,Int} = (0, 0)
    voie::Tuple{Int,Int} = (0, 0)
    valeurs_voie::NTuple{4,Int} = (-1, -1, -1, -1)
    bit_invalide::Int = -1
    bit_mtov::Int = -1
    bit_perte::Int = -1
    masque_debord::UInt32 = 0x00000000
    valeur_debord::UInt32 = 0x00000000
    compte::Tuple{Int,Int} = (0, 0)
    masque_marqueur::UInt32 = 0x00000000
    valeur_marqueur::UInt32 = 0x00000000
    bits_marqueurs::NTuple{4,Int} = (-1, -1, -1, -1)
    masque_photon::UInt32 = 0x00000000
    valeur_photon::UInt32 = 0x00000000
    verification::String = ""
end

"""Format FIFO_150 des SPC-130/140/15x/16x/830, mêmes règles que `Decodeur`."""
const FORMAT_SPC150 = FormatFIFO(
    nom = "SPC-130/140/15x/16x/830 (FIFO_150)",
    macrotemps = (0, 12), microtemps = (16, 12), micro_inverse = true,
    routage = (12, 4),
    bit_invalide = 31, bit_mtov = 30, bit_perte = 29,
    masque_debord = 0xd0000000, valeur_debord = 0xc0000000, compte = (0, 28),
    masque_marqueur = 0x90000000, valeur_marqueur = 0x90000000, bits_marqueurs = (12, 13, 14, 15),
    masque_photon = 0x10000000, valeur_photon = 0x00000000,
    verification = "format publié (libtcspc, Bio-Formats), testé sur les SPC-150N du banc")

function Base.show(io::IO, f::FormatFIFO)
    print(io, "FormatFIFO(", repr(f.nom), ")")
end

"""
    copie_format(f; champs...) -> FormatFIFO

Copie de `f` avec quelques champs remplacés, par exemple
`copie_format(f; mots_inverses = true)`.
"""
function copie_format(f::FormatFIFO; champs...)
    d = Dict{Symbol,Any}(n => getfield(f, n) for n in fieldnames(FormatFIFO))
    for (k, v) in champs
        haskey(d, k) || error("FormatFIFO n'a pas de champ $k")
        d[k] = v
    end
    return FormatFIFO(; d...)
end

"""
    ecrire_format(chemin, f; nom_variable="FORMAT_QC104", commentaire="")

Écrit un fichier Julia qui recrée `f` (pour `include`). Variable globale
ordinaire, pas une constante : on peut réinclure le fichier après l'avoir
régénéré.
"""
function ecrire_format(chemin::AbstractString, f::FormatFIFO;
                       nom_variable::AbstractString = "FORMAT_QC104", commentaire::AbstractString = "")
    hex(x::UInt32) = "0x" * string(x; base = 16, pad = 8)
    mkpath(dirname(abspath(chemin)))
    open(chemin, "w") do io
        println(io, "# ", basename(chemin), " — écrit par qc4_format_fifo.jl, ne pas modifier à la main.")
        for l in split(commentaire, '\n')
            isempty(strip(l)) || println(io, "# ", l)
        end
        println(io, "isdefined(Main, :SPCLite) || include(\"SPCLite.jl\")")
        println(io, "using .SPCLite")
        println(io, nom_variable, " = FormatFIFO(")
        println(io, "    nom = ", repr(f.nom), ",")
        println(io, "    mots_inverses = ", f.mots_inverses, ",")
        println(io, "    macrotemps = ", f.macrotemps, ", microtemps = ", f.microtemps,
                ", micro_inverse = ", f.micro_inverse, ",")
        println(io, "    routage = ", f.routage, ", voie = ", f.voie, ", valeurs_voie = ", f.valeurs_voie, ",")
        println(io, "    bit_invalide = ", f.bit_invalide, ", bit_mtov = ", f.bit_mtov,
                ", bit_perte = ", f.bit_perte, ",")
        println(io, "    masque_debord = ", hex(f.masque_debord), ", valeur_debord = ", hex(f.valeur_debord),
                ", compte = ", f.compte, ",")
        println(io, "    masque_marqueur = ", hex(f.masque_marqueur), ", valeur_marqueur = ",
                hex(f.valeur_marqueur), ", bits_marqueurs = ", f.bits_marqueurs, ",")
        println(io, "    masque_photon = ", hex(f.masque_photon), ", valeur_photon = ", hex(f.valeur_photon), ",")
        println(io, "    verification = ", repr(f.verification), ")")
    end
    return abspath(chemin)
end

"""
    DecodeurFIFO(format; garder_photons=false, voie_fixe=1)

Décode un flux FIFO décrit par `format` (FORMAT_SPC150, FORMAT_QC104…) et
cumule une sortie commune aux deux familles de cartes :

- `photons`, `rejetes`, `pertes`, `inattendus`, `debordements` ;
- `par_voie[i]` : photons de l'entrée i (1 à 4) ; pour une SPC-150N, la
  voie est `voie_fixe` (le canal que tu donnes à la carte) ;
- `routage[r + 1]` : photons par valeur du routage, telle que lue (actif à
  l'état bas : le bit vaut 1 quand l'entrée TTL est à 0 V) ;
- `micro[c + 1, i]` : histogramme du microtemps par voie, déjà orienté (le
  temps croît avec le canal c) ;
- `marqueurs[k + 1]` : temps des marqueurs Mk, en tics du macrotemps ;
- avec `garder_photons = true`, chaque photon : `t_photons` (tics),
  `micro_photons` (canal orienté), `routage_photons`, `voie_photons`.
"""
mutable struct DecodeurFIFO
    f::FormatFIFO
    periode::Int64                     # 2^bits du macrotemps, en tics
    nmicro::Int                        # 2^bits du microtemps
    voie_fixe::UInt8
    table_voie::Vector{UInt8}          # valeur du champ voie + 1 → entrée (0 = inconnue)
    base::Int64
    reste::UInt16
    a_reste::Bool
    photons::Int
    rejetes::Int
    pertes::Int
    inattendus::Int
    debordements::Int
    par_voie::Vector{Int}
    routage::Vector{Int}
    micro::Matrix{Int}
    marqueurs::Vector{Vector{Int64}}
    garder_photons::Bool
    t_photons::Vector{Int64}
    micro_photons::Vector{UInt16}
    routage_photons::Vector{UInt8}
    voie_photons::Vector{UInt8}
end

function DecodeurFIFO(f::FormatFIFO; garder_photons::Bool = false, voie_fixe::Integer = 1)
    1 <= f.macrotemps[2] <= 32 || error("format $(f.nom) : macrotemps de $(f.macrotemps[2]) bits")
    1 <= f.microtemps[2] <= 16 || error("format $(f.nom) : microtemps de $(f.microtemps[2]) bits")
    f.routage[2] <= 8 || error("format $(f.nom) : routage de $(f.routage[2]) bits")
    f.voie[2] <= 8 || error("format $(f.nom) : voie de $(f.voie[2]) bits")
    1 <= voie_fixe <= 4 || error("voie_fixe : 1 à 4")
    table = zeros(UInt8, 1 << f.voie[2])
    if f.voie[2] > 0
        for (i, v) in enumerate(f.valeurs_voie)
            0 <= v < length(table) && (table[v + 1] = UInt8(i))
        end
    end
    nmicro = 1 << f.microtemps[2]
    return DecodeurFIFO(f, Int64(1) << f.macrotemps[2], nmicro, UInt8(voie_fixe), table,
                        0, 0x0000, false, 0, 0, 0, 0, 0,
                        zeros(Int, 4), zeros(Int, 1 << f.routage[2]), zeros(Int, nmicro, 4),
                        [Int64[] for _ in 1:4], garder_photons,
                        Int64[], UInt16[], UInt8[], UInt8[])
end

"""Remet le décodeur à zéro (nouvelle mesure : le macrotemps repart de 0)."""
function reinitialiser!(d::DecodeurFIFO)
    d.base = 0; d.a_reste = false
    d.photons = 0; d.rejetes = 0; d.pertes = 0; d.inattendus = 0; d.debordements = 0
    fill!(d.par_voie, 0); fill!(d.routage, 0); fill!(d.micro, 0)
    foreach(empty!, d.marqueurs)
    empty!(d.t_photons); empty!(d.micro_photons); empty!(d.routage_photons); empty!(d.voie_photons)
    return d
end

@inline _champ(w::UInt32, c::Tuple{Int,Int}) =
    c[2] == 0 ? UInt32(0) : (w >> c[1]) & ((UInt32(1) << c[2]) - UInt32(1))
@inline _bit(w::UInt32, b::Int) = b >= 0 && ((w >> b) & 0x00000001) == 0x00000001
@inline _mot32(inverse::Bool, a::UInt16, b::UInt16) =
    inverse ? (UInt32(b) | (UInt32(a) << 16)) : (UInt32(a) | (UInt32(b) << 16))

"""
    decoder!(d::DecodeurFIFO, mots, n=length(mots))

Décode les `n` premiers mots de 16 bits de `mots` et cumule dans `d`.
Un mot isolé en fin de tampon est gardé pour l'appel suivant.
"""
function decoder!(d::DecodeurFIFO, mots::AbstractVector{UInt16}, n::Integer = length(mots))
    inv = d.f.mots_inverses
    i = 1
    if d.a_reste && n >= 1
        _enregistrement!(d, _mot32(inv, d.reste, mots[1]))
        d.a_reste = false
        i = 2
    end
    while i + 1 <= n
        _enregistrement!(d, _mot32(inv, mots[i], mots[i + 1]))
        i += 2
    end
    if i == n
        d.reste = mots[n]
        d.a_reste = true
    end
    return d
end

function _enregistrement!(d::DecodeurFIFO, w::UInt32)
    f = d.f
    perte = _bit(w, f.bit_perte)
    if f.masque_debord != 0x00000000 && (w & f.masque_debord) == f.valeur_debord
        n = f.compte[2] == 0 ? Int64(1) : Int64(_champ(w, f.compte))
        d.base += d.periode * n
        d.debordements += n
        perte && (d.pertes += 1)
        return nothing
    end
    if _bit(w, f.bit_mtov)
        d.base += d.periode
        d.debordements += 1
    end
    perte && (d.pertes += 1)
    t = d.base + Int64(_champ(w, f.macrotemps))
    if f.masque_marqueur != 0x00000000 && (w & f.masque_marqueur) == f.valeur_marqueur
        for k in 1:4
            _bit(w, f.bits_marqueurs[k]) && push!(d.marqueurs[k], t)
        end
        return nothing
    end
    if (w & f.masque_photon) != f.valeur_photon
        d.inattendus += 1
        return nothing
    end
    if _bit(w, f.bit_invalide)
        d.rejetes += 1
        return nothing
    end
    brut = _champ(w, f.microtemps)
    c = f.micro_inverse ? UInt32(d.nmicro - 1) - brut : brut
    r = _champ(w, f.routage)
    v = f.voie[2] == 0 ? d.voie_fixe : d.table_voie[Int(_champ(w, f.voie)) + 1]
    if v == 0x00                                     # valeur de voie jamais observée
        d.inattendus += 1
        return nothing
    end
    d.photons += 1
    d.par_voie[v] += 1
    d.routage[Int(r) + 1] += 1
    d.micro[Int(c) + 1, v] += 1
    if d.garder_photons
        push!(d.t_photons, t)
        push!(d.micro_photons, UInt16(c))
        push!(d.routage_photons, UInt8(r))
        push!(d.voie_photons, v)
    end
    return nothing
end

# =====================================================================
# Décodage de référence par la DLL (fichiers .spc)
#
# Fonctions documentées dans le manuel DLL (p. 62-65) : SPC_init_phot_stream,
# SPC_get_photon, SPC_close_phot_stream. Lent (un appel par photon), mais
# c'est le décodage de B&H lui-même : il sert d'arbitre pour établir et
# vérifier un format. Structure PhotInfo (spcm_def.h, alignement 1 octet) :
#   unsigned long mtime_lo, mtime_hi ; unsigned short micro_time,
#   rout_chan, flags. Drapeaux : 1 photon invalide, 0x1000 à 0x8000
#   marqueurs M0 à M3. Tampon de 64 octets par sécurité ; les 16 premiers
#   octets sont gardés tels quels pour le diagnostic.
# =====================================================================

const DRAPEAU_INVALIDE = 0x0001
const DRAPEAUX_MARQUEURS = (0x1000, 0x2000, 0x4000, 0x8000)

"""Une entrée décodée par la DLL : photon ou marqueur."""
struct PhotonDLL
    mtime::UInt64        # macrotemps cumulé, en tics
    micro::UInt16        # micro_time tel que rendu par la DLL
    rout::UInt16         # rout_chan
    drapeaux::UInt16     # flags
    octets::NTuple{16,UInt8}
end

"""Vrai si l'entrée de la DLL est un marqueur (un des drapeaux M0 à M3)."""
est_marqueur(p::PhotonDLL) = (p.drapeaux & 0xf000) != 0

"""
Type de flux à passer à SPC_init_phot_stream pour un fichier .spc : celui
que donne SPC_get_fifo_init_vars, sans les bits des flux en mémoire
(12 et 13), avec le bit 0 (premier mot = en-tête B&H).
"""
type_flux_fichier(st::Integer) = (Int(st) & ~0x3000) | 0x0001

"""
    ecrire_spc(chemin, entete, mots, n=length(mots))

Fichier .spc comme ceux de SPCM : l'en-tête (premier mot, de
SPC_get_fifo_init_vars) puis les mots du FIFO tels que lus.
"""
function ecrire_spc(chemin::AbstractString, entete::Unsigned, mots::AbstractVector{UInt16},
                    n::Integer = length(mots))
    mkpath(dirname(abspath(chemin)))
    open(chemin, "w") do io
        write(io, htol(UInt32(entete)))
        write(io, htol.(view(mots, 1:n)))
    end
    return abspath(chemin)
end

_u32(b::Vector{UInt8}, o::Int) = UInt32(b[o + 1]) | (UInt32(b[o + 2]) << 8) |
                                 (UInt32(b[o + 3]) << 16) | (UInt32(b[o + 4]) << 24)
_u16(b::Vector{UInt8}, o::Int) = UInt16(b[o + 1]) | (UInt16(b[o + 2]) << 8)

"""
    photons_dll(chemin; type_fifo, type_flux, quoi=0x3f, max=10^7) -> (entrees, code_fin)

Décode un fichier .spc avec la DLL (SPC_init_phot_stream, puis
SPC_get_photon jusqu'à la fin). `quoi` : bit 0 photons valides, bit 1
photons invalides, bits 2 à 5 marqueurs M0 à M3. `code_fin` : valeur
renvoyée par le dernier SPC_get_photon (fin du fichier ou erreur).
"""
function photons_dll(chemin::AbstractString; type_fifo::Integer, type_flux::Integer,
                     quoi::Integer = 0x3f, max::Integer = 10^7)
    h = Int(ccall((:SPC_init_phot_stream, DLL_SPCM), Int16, (Int16, Cstring, Int16, Int16, Int16),
                  Int16(type_fifo), abspath(chemin), Int16(1), Int16(type_flux), Int16(quoi)))
    h < 0 && throw(SPCError(h, "SPC_init_phot_stream", message_erreur(h)))
    sortie = PhotonDLL[]
    buf = zeros(UInt8, 64)
    code_fin = 0
    try
        while length(sortie) < max
            fill!(buf, 0x00)
            r = Int(ccall((:SPC_get_photon, DLL_SPCM), Int16, (Int16, Ptr{UInt8}), Int16(h), buf))
            if r != 0
                code_fin = r
                break
            end
            push!(sortie, PhotonDLL(UInt64(_u32(buf, 0)) | (UInt64(_u32(buf, 4)) << 32),
                                    _u16(buf, 8), _u16(buf, 10), _u16(buf, 12),
                                    ntuple(i -> buf[i], 16)))
        end
    finally
        ccall((:SPC_close_phot_stream, DLL_SPCM), Int16, (Int16,), Int16(h))
    end
    return sortie, code_fin
end

end # module
