"""
    DCCLite

Interface minimale vers la DLL des contrôleurs de détecteurs DCC-100 de
Becker & Hickl (dcc64.dll), par ccall.

Elle sert à l'inventaire : quels DCC-100 sont là, leur numéro de série,
leur place sur le bus PCI et l'état de leurs protections. Elle n'allume
jamais rien. Au contraire, DCC_init coupe toutes les sorties par sécurité :
pour allumer un détecteur, utilise le logiciel DCC de B&H.

Libération : DCC_close seul laisse les modules verrouillés. `liberer_dcc`
coupe les sorties, déverrouille (DCC_set_mode, in_use = 0), puis referme.
Comme pour les SPC, seules les fonctions qui lisent les structures internes
de la DLL (DCC_get_module_info, DCC_get_init_status) servent pour tous les
modules ; tout ce qui touche une carte ne vise qu'un module prêt.

Références :
- « DCC Dynamic Link Library », manuel 2023 (prototypes, codes d'état) ;
- adaptateur Micro-Manager BH_DCC_DCU : la première ligne du fichier .ini
  doit être un commentaire commençant par « DCC100 » (non documenté).

Numérotation : les modules sont classés par numéro de série croissant ;
le module 0 correspond à la section [dcc_module1] du fichier .ini.
"""
module DCCLite

using Libdl, Printf

export DLL_DCC, DCCError, message_erreur_dcc, ecrire_ini_dcc, avec_dcc
export initialiser_dcc, fermer_dcc, liberer_dcc, forcer_dcc, etat_init_dcc, actif_dcc
export info_dcc, modules_detectes_dcc, modules_prets_dcc
export surcharge_dcc, limite_courant_dcc, couper_sorties_dcc, MESSAGES_INIT_DCC

function _chercher_bh(nom::AbstractString)
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

function _trouver_dll()
    candidats = String[]
    haskey(ENV, "DCC_DLL") && push!(candidats, ENV["DCC_DLL"])
    for racine in (get(ENV, "ProgramFiles(x86)", raw"C:\Program Files (x86)"),
                   get(ENV, "ProgramFiles", raw"C:\Program Files"))
        push!(candidats, joinpath(racine, "BH", "DCC", "DLL", "dcc64.dll"))
        push!(candidats, joinpath(racine, "BH", "DCC", "dcc64.dll"))
    end
    for c in candidats
        isfile(c) && return c
    end
    p = _chercher_bh("dcc64.dll")
    p === nothing || return p
    h = Libdl.dlopen_e("dcc64")
    h == C_NULL || return Libdl.dlpath(h)
    error("""
        dcc64.dll introuvable (cherchée sous Program Files\\BH et dans le chemin
        de Windows). Réinstalle le TCSPC Package en cochant le logiciel et la DLL
        DCC, ou indique le chemin avant de charger DCCLite :
          ENV["DCC_DLL"] = raw"C:\\chemin\\vers\\dcc64.dll"
        """)
end

"""Chemin complet de dcc64.dll (fixé au chargement du module)."""
const DLL_DCC = _trouver_dll()

struct DCCError <: Exception
    code::Int
    fonction::String
    msg::String
end
Base.showerror(io::IO, e::DCCError) =
    print(io, "DCC ", e.code, " dans ", e.fonction, " : ", e.msg)

"""Texte de la DLL pour un code d'erreur DCC."""
function message_erreur_dcc(code::Integer)
    for id in (code, -code)
        buf = zeros(UInt8, 512)
        r = ccall((:DCC_get_error_string, DLL_DCC), Int16, (Int16, Ptr{UInt8}, Int16),
                  Int16(id), buf, Int16(length(buf) - 1))
        s = r < 0 ? "" : GC.@preserve buf unsafe_string(pointer(buf))
        isempty(s) || return s
    end
    return "erreur $code (pas de description dans la DLL)"
end

_chk(code, fonction) = code < 0 ?
    throw(DCCError(Int(code), String(fonction), message_erreur_dcc(code))) : code

"""Codes renvoyés par DCC_get_init_status (manuel DLL DCC)."""
const MESSAGES_INIT_DCC = Dict(
     0 => "aucune erreur",
    -1 => "initialisation pas faite (module absent ou inactif)",
    -2 => "somme de contrôle de l'EEPROM incorrecte",
    -3 => "impossible d'ouvrir la carte PCI (absente, châssis éteint, pilote)",
    -4 => "module déjà utilisé par un autre programme (logiciel DCC ou SPCM ouvert ?)",
)

"""
    ecrire_ini_dcc(chemin; modules=1:8, simulation=0) -> chemin

Fichier d'initialisation minimal : chaque module listé est déclaré actif,
sans aucun autre paramètre, donc toutes ses sorties restent coupées.
"""
function ecrire_ini_dcc(chemin::AbstractString; modules = 1:8, simulation::Integer = 0)
    mkpath(dirname(abspath(chemin)))
    open(chemin, "w") do io
        println(io, "; DCC100")                       # exigé en première ligne
        println(io, "; écrit par DCCLite.jl : modules actifs, sorties coupées")
        println(io)
        println(io, "[dcc_base]")
        println(io, "simulation = ", simulation)
        for k in 1:8
            println(io)
            println(io, "[dcc_module$k]")
            println(io, "active = ", k in modules ? 1 : 0)
        end
    end
    return abspath(chemin)
end

"""Appelle DCC_init ; renvoie le code sans lever (voir etat_init_dcc)."""
initialiser_dcc(ini::AbstractString) =
    Int(ccall((:DCC_init, DLL_DCC), Int16, (Cstring,), abspath(ini)))

"""État d'initialisation du module `m` (0 à 7) : 0 = prêt, voir MESSAGES_INIT_DCC."""
function etat_init_dcc(m::Integer)
    s = Ref{Int16}(0)
    r = ccall((:DCC_get_init_status, DLL_DCC), Int16, (Int16, Ptr{Int16}), Int16(m), s)
    return r < 0 ? Int(r) : Int(s[])
end

"""Le module `m` est-il actif après DCC_init ?"""
actif_dcc(m::Integer) =
    ccall((:DCC_test_if_active, DLL_DCC), Int16, (Int16,), Int16(m)) == 1

"""
    info_dcc(m) -> (type, bus, slot, utilise, init, serie)

DCCModInfo : 5 short, 1 unsigned short, puis char serial_no[12].
`type` vaut 100 pour une DCC-100.
"""
function info_dcc(m::Integer)
    b = zeros(UInt8, 64)
    _chk(ccall((:DCC_get_module_info, DLL_DCC), Int16, (Int16, Ptr{UInt8}), Int16(m), b),
         "DCC_get_module_info")
    court(o) = Int(reinterpret(Int16, b[o + 1:o + 2])[1])
    s = b[13:24]
    k = findfirst(==(0x00), s)
    serie = strip(String(s[1:(k === nothing ? 12 : k - 1)]))
    return (type = court(0), bus = court(2), slot = court(4), utilise = court(6),
            init = court(8), serie = serie)
end

"""
Bits de surcharge : (connecteur1, connecteur3), vrais si la protection a coupé.
Lit la carte : seulement sur un module prêt (état 0), jamais sur un module
absent ou pris par un autre programme.
"""
function surcharge_dcc(m::Integer)
    s = Ref{Int16}(0)
    _chk(ccall((:DCC_get_overload_state, DLL_DCC), Int16, (Int16, Ptr{Int16}), Int16(m), s),
         "DCC_get_overload_state")
    return (c1 = (s[] & 0x1) != 0, c3 = (s[] & 0x2) != 0)
end

"""Limite de courant du refroidisseur (connecteur 3) atteinte ? Module prêt seulement."""
function limite_courant_dcc(m::Integer)
    s = Ref{Int16}(0)
    _chk(ccall((:DCC_get_curr_lmt_state, DLL_DCC), Int16, (Int16, Ptr{Int16}), Int16(m), s),
         "DCC_get_curr_lmt_state")
    return s[] != 0
end

"""Coupe les sorties du module `m` (module prêt seulement)."""
couper_sorties_dcc(m::Integer) =
    ccall((:DCC_enable_outputs, DLL_DCC), Int16, (Int16, Int16), Int16(m), Int16(0))

"""Referme la DLL. Ne lève PAS le verrou des modules : voir `liberer_dcc`."""
fermer_dcc() = ccall((:DCC_close, DLL_DCC), Int16, ())

_set_mode_dcc(mode, force, table::Vector{Int16}) =
    Int(ccall((:DCC_set_mode, DLL_DCC), Int16, (Int16, Int16, Ptr{Int16}),
              Int16(mode), Int16(force), table))

"""Modules DCC-100 présents (type 100), d'après les structures internes de la DLL."""
function modules_detectes_dcc()
    vus = Int16[]
    for k in 0:7
        info = try
            info_dcc(k)
        catch
            nothing
        end
        info !== nothing && info.type == 100 && push!(vus, Int16(k))
    end
    return vus
end

"""Modules DCC-100 détectés ET initialisés par cette session (état 0)."""
modules_prets_dcc() = Int16[k for k in modules_detectes_dcc() if etat_init_dcc(k) == 0]

"""
Reprend de force des modules DCC-100 restés verrouillés (DCC_set_mode,
force_use = 1). La DLL n'accepte qu'un seul 1 par table : un appel par
module. Ne pas l'utiliser pendant que le logiciel DCC ou SPCM tourne.
"""
function forcer_dcc(modules)
    for m in modules
        table = zeros(Int16, 32)         # le manuel parle de 8 entrées ; 32 par prudence
        table[m + 1] = 1
        _chk(_set_mode_dcc(0, 1, table), "DCC_set_mode (forcer)")
    end
    return nothing
end

"""
Coupe les sorties des modules pris par cette session, les déverrouille
(DCC_set_mode, in_use = 0), puis referme la DLL. DCC_close seul ne lève
pas le verrou : le module resterait « utilisé » pour les programmes
suivants, logiciel DCC compris. DCC_close est appelé même sans module prêt.
"""
function liberer_dcc()
    prets = modules_prets_dcc()
    for m in prets
        try; couper_sorties_dcc(m); catch; end
    end
    if !isempty(prets)
        try; _set_mode_dcc(0, 0, zeros(Int16, 32)); catch; end
    end
    try; fermer_dcc(); catch; end
    return nothing
end

"""
    avec_dcc(f, ini)

DCC_init, puis `f(code_init)`, puis sorties coupées, modules déverrouillés
et DLL refermée, même en cas d'erreur.
"""
function avec_dcc(f, ini::AbstractString)
    code = initialiser_dcc(ini)
    try
        return f(code)
    finally
        liberer_dcc()
    end
end

end # module
