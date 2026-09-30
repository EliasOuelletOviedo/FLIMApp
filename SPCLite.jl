"""
    SPCLite

Interface minimale vers la DLL SPCM de Becker & Hickl (spcm64.dll), par
ccall, sur le modèle de DAQmxLite. Couvre ce qu'il faut pour vérifier la
communication avec une SPC-150N et faire une acquisition FIFO :

- initialisation par fichier .ini (aucune structure C à recopier) ;
- identification du module, EEPROM, état d'initialisation ;
- lecture et écriture des paramètres, toujours via des fichiers .ini ;
- compteurs de taux et état du SYNC ;
- mesure FIFO, lecture du FIFO, décodage des enregistrements 32 bits.

Références :
- « SPCM Dynamic Link Libraries », manuel utilisateur 5.0, mars 2023
  (prototypes, codes d'erreur, clés du fichier .ini) ;
- format FIFO des SPC-130/140/15x/16x/830 : mêmes règles que libtcspc
  (bh_spc.hpp) et le lecteur Bio-Formats des fichiers .spc.

Les structures SPCdata et SPC_EEP_Data ne sont jamais recopiées en Julia :
la DLL les remplit dans un tampon d'octets opaque, puis écrit elle-même
les paramètres dans un fichier .ini qu'on relit. Les seules structures
lues champ par champ sont SPCModInfo (6 short) et rate_values (4 float),
qui n'ont pas de trou d'alignement.
"""
module SPCLite

using Libdl, Printf

"""Version de ce fichier : les scripts s'arrêtent si Julia en a chargé une plus ancienne."""
const VERSION_LITE = 8

export SPCError, chk_spc, message_erreur, DLL_SPCM
export ecrire_ini, lire_ini, avec_spc, avec_spc_tous, initialiser, liberer, liberer_tous
export modules_detectes, modules_prets, forcer_module, forcer_modules, chercher_bh
export etat_init, info_module, type_module, eeprom, mode_dll, explication_init
export lire_parametres, appliquer_ini, sync_etat, effacer_taux, taux
export comparer_parametres, afficher_parametres, ecart_peigne
export demarrer, arreter, etat_mesure, lire_fifo!, fifo_init, remplissage_fifo
export configurer_memoire, definir_page, effacer_memoire, lire_bloc
export Decodeur, decoder!, reinitialiser!, PERIODE_MT
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
     -9 => "version de firmware incorrecte",
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

"""Types de module renvoyés par SPC_test_id (manuel DLL, p. 31)."""
const NOMS_MODULES = Dict(
    130 => "SPC-130", 131 => "SPC-130-EM", 140 => "SPC-140", 150 => "SPC-150",
    151 => "SPC-150N", 160 => "SPC-160", 600 => "SPC-600", 630 => "SPC-630",
    700 => "SPC-700", 730 => "SPC-730", 830 => "SPC-830", 930 => "SPC-930",
    230 => "DPC-230")

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
    x = tryparse(Int, s)
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

# Règle de sécurité de ce module : une fonction qui touche le matériel
# (SPC_stop_measurement, SPC_test_id, SPC_get_eeprom_data, mesures…) ne
# s'appelle QUE sur un module prêt, c'est-à-dire détecté et initialisé par
# cette session. Sur un module absent ou non initialisé, la DLL peut faire
# une violation d'accès, que try/catch ne rattrape pas. Seules
# SPC_get_module_info et SPC_get_init_status, qui lisent les structures
# internes de la DLL, se lisent sans risque pour les modules 0 à 7.

"""
    modules_detectes() -> Vector{Int16}

Modules présents d'après SPC_get_module_info (type > 0), après SPC_init.
Ne lit que les structures internes de la DLL : aucun accès au matériel.
"""
function modules_detectes()
    vus = Int16[]
    for k in 0:7
        info = try
            info_module(k)
        catch
            nothing
        end
        info !== nothing && info.type > 0 && push!(vus, Int16(k))
    end
    return vus
end

"""
    modules_prets() -> Vector{Int16}

Modules détectés ET initialisés par cette session (état 0) : les seuls sur
lesquels on peut appeler une fonction qui touche le matériel.
"""
modules_prets() = Int16[k for k in modules_detectes() if etat_init(k) == 0]

"""
Prend les modules listés même s'ils sont marqués « verrouillés » (par
exemple après une session qui s'est mal terminée), en un seul appel à
SPC_set_mode avec force_use = 1. Ne passer que des modules détectés.
Ne jamais l'utiliser pendant que SPCM se sert réellement des cartes.
"""
function forcer_modules(modules)
    isempty(modules) && return 0
    table = zeros(Int32, 32)          # le manuel parle de 8 entrées ; 32 par prudence
    for m in modules
        table[m + 1] = 1
    end
    return chk_spc(_set_mode(0, 1, table), "SPC_set_mode (forcer)")
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
modules prêts, puis SPC_close. Sans cela, SPCM trouverait les cartes
« déjà utilisées ».
"""
liberer() = liberer_tous(modules_prets())

"""
    avec_spc_tous(f, ini; forcer=false)

Comme `avec_spc`, pour toutes les cartes présentes (deux SPC-150N, par
exemple) : `f` reçoit la liste des numéros de modules prêts. Lève une
erreur s'il n'y en a aucun. Tout est libéré à la fin, même sur une erreur.
`forcer = true` reprend les modules détectés restés verrouillés (état -6).
"""
function avec_spc_tous(f, ini::AbstractString; forcer::Bool = false)
    code = initialiser(ini)
    try
        detectes = modules_detectes()
        if forcer
            verrouilles = Int16[k for k in detectes if etat_init(k) == -6]
            if !isempty(verrouilles)
                @warn "Modules $(Int.(verrouilles)) verrouillés : reprise forcée"
                forcer_modules(verrouilles)
            end
        end
        modules = modules_prets()
        if isempty(modules)
            etats = isempty(detectes) ? "aucune carte détectée" :
                    join(("module $k : $(explication_init(etat_init(k)))" for k in detectes), " ; ")
            throw(SPCError(code < 0 ? code : -1, "SPC_init", "aucun module prêt ($etats)"))
        end
        code < 0 && @warn "SPC_init a renvoyé $code ($(message_erreur(code))) ; modules prêts : $(Int.(modules))"
        return f(modules)
    finally
        liberer()      # seulement les modules prêts ; SPC_close dans tous les cas
    end
end

"""
    avec_spc(f, ini; module_no=0, forcer=false)

Initialise la DLL avec `ini`, vérifie que le module est détecté et prêt,
appelle `f(module_no)`, puis libère tout, même en cas d'erreur.
`forcer = true` reprend un module resté verrouillé (état -6).
"""
function avec_spc(f, ini::AbstractString; module_no::Integer = 0, forcer::Bool = false)
    code = initialiser(ini)
    try
        detectes = modules_detectes()
        module_no in detectes ||
            throw(SPCError(-1, "SPC_init",
                           "module $module_no non détecté (modules détectés : $(Int.(detectes)))"))
        etat = etat_init(module_no)
        if etat == -6 && forcer
            @warn "Module $module_no verrouillé : reprise forcée"
            forcer_module(module_no)
            etat = etat_init(module_no)
        end
        etat == 0 || throw(SPCError(etat, "SPC_init", explication_init(etat, code)))
        code < 0 && @warn "SPC_init a renvoyé $code, mais le module $module_no est prêt : $(message_erreur(code))"
        return f(Int16(module_no))
    finally
        liberer()      # seulement les modules prêts ; SPC_close dans tous les cas
    end
end

# =====================================================================
# Identification
# =====================================================================

"""État d'initialisation du module (0 = prêt ; voir MESSAGES_INIT)."""
etat_init(m::Integer) = Int(ccall((:SPC_get_init_status, DLL_SPCM), Int16, (Int16,), Int16(m)))

"""Type du module (151 = SPC-150N) ; valeur < 0 = erreur. Lit le matériel : module prêt seulement."""
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

const TAILLE_SPCDATA = 4096   # bien plus que sizeof(SPCdata) : marge volontaire

"""
    lire_parametres(m; fichier) -> Dict{String,Float64}

Paramètres réellement appliqués au module, après les recalculs de la DLL
(SPC_get_parameters, puis SPC_save_parameters_to_inifile).
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
Tolérance : les entiers doivent être identiques ; les seuils en mV et les
pourcentages (arrondis par les convertisseurs de la carte) à 3 % ou une
unité près ; les autres réels (temps en s ou en ns) à 3 % près.
"""
function comparer_parametres(demandes::AbstractDict, lus::AbstractDict)
    sortie = NamedTuple{(:cle, :demande, :applique, :statut),Tuple{String,Any,Float64,Symbol}}[]
    en_mv_ou_pourcent(cle) = occursin(r"limit|zc_level|threshold|offset", cle)
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

Taux en coups/s. `code` < 0 : valeurs pas encore prêtes (le temps
d'intégration, rate_count_time, n'est pas écoulé) ou erreur.
"""
function taux(m::Integer)
    v = zeros(Float32, 8)             # rate_values : 4 float
    r = Int(ccall((:SPC_read_rates, DLL_SPCM), Int16, (Int16, Ptr{Float32}), Int16(m), v))
    return (code = r, sync = Float64(v[1]), cfd = Float64(v[2]),
            tac = Float64(v[3]), adc = Float64(v[4]))
end

# =====================================================================
# Mesure FIFO
# =====================================================================

demarrer(m::Integer) = chk_spc(ccall((:SPC_start_measurement, DLL_SPCM), Int16, (Int16,),
                                     Int16(m)), "SPC_start_measurement")

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
    fifo_init(m) -> (type_fifo, type_flux, horloge_macro_s, entete)

Format du flux (7 = FIFO_150 pour la famille SPC-15x) et durée d'un tic
du macrotemps, en secondes. À appeler une fois le mode FIFO réglé.
"""
function fifo_init(m::Integer)
    ft = Ref{Int16}(0); st = Ref{Int16}(0); mt = Ref{Cint}(0); h = Ref{Cuint}(0)
    chk_spc(ccall((:SPC_get_fifo_init_vars, DLL_SPCM), Int16,
                  (Int16, Ptr{Int16}, Ptr{Int16}, Ptr{Cint}, Ptr{Cuint}),
                  Int16(m), ft, st, mt, h), "SPC_get_fifo_init_vars")
    return (type_fifo = Int(ft[]), type_flux = Int(st[]),
            horloge_macro_s = mt[] * 1e-10, entete = h[])   # mt en dixièmes de ns
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
nombre de mots de 16 bits écrits (un enregistrement = 2 mots).
"""
function lire_fifo!(m::Integer, tampon::Vector{UInt16})
    n = Ref{Culong}(length(tampon) - isodd(length(tampon)))
    chk_spc(ccall((:SPC_read_fifo, DLL_SPCM), Int16, (Int16, Ptr{Culong}, Ptr{UInt16}),
                  Int16(m), n, tampon), "SPC_read_fifo")
    return Int(n[])
end

# =====================================================================
# Décodage du flux FIFO (type FIFO_150)
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

end # module
