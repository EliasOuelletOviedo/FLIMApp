# spc_deverrouiller.jl — lève un verrou resté sur des cartes SPC (état -6)
# alors qu'aucun programme ne s'en sert. Version 9 : SPC-150N et SPC-QC-104.
#
# À lancer seulement si SPCM est fermé et qu'aucun autre programme B&H ni
# autre session Julia ne tourne (commande PowerShell du plan). Forcer une
# carte réellement utilisée par SPCM couperait sa mesure.
#
# Déroulé :
#   1. SPC_init, puis état de chaque module (utilisé -1 = verrouillé ailleurs) ;
#   2. reprise forcée des modules verrouillés (SPC_set_mode, force_use = 1)
#      et lecture de leur n° de série, pour prouver l'accès ;
#   3. libération normale, puis nouvelle initialisation SANS forcer : si les
#      modules sont prêts, le verrou a disparu pour de bon.
# Colle la sortie dans la conversation.

isdefined(Main, :SPCLite) || include("SPCLite.jl")
using .SPCLite
(isdefined(SPCLite, :VERSION_LITE) && SPCLite.VERSION_LITE >= 9) ||
    error("Julia a gardé une ancienne version de SPCLite.jl : redémarre Julia, puis relance ce script.")
using Printf

function spc_deverrouiller()
    dossier = joinpath(@__DIR__, "resultats", "spc")
    ini = ecrire_ini(joinpath(dossier, "deverrouiller.ini"))

    # N'interroge que les structures internes de la DLL ; l'EEPROM (lue sur
    # la carte) seulement pour un module prêt et tenu par cette session.
    function montrer(titre, tenus = nothing)
        println("\n", titre)
        vus = modules_detectes()
        isempty(vus) && println("  aucune carte SPC détectée")
        for k in vus
            info = info_module(k)
            etat = etat_init(k)
            lisible = etat == 0 && (tenus === nothing || k in tenus)
            serie = lisible ? (try eeprom(k).serie catch; "?" end) : "?"
            @printf("  module %d : %-11s bus %d, slot %d, utilisé %2d, n° de série %-10s %s\n",
                    k, nom_module(info.type), info.bus, info.slot, info.utilise, serie,
                    etat == 0 ? "prête" : explication_init(etat))
        end
        return vus
    end

    # 1 et 2 : état de départ, puis reprise forcée des seuls modules détectés
    initialiser(ini)
    verrouilles = Int16[]
    try
        vus = montrer("Avant (utilisé -1 = verrouillé par un autre programme) :")
        append!(verrouilles, Int16[k for k in vus if etat_init(k) == -6])
        if isempty(verrouilles)
            println("\nAucun module verrouillé : rien à faire. Relance qc1_inventaire.jl.")
            return true
        end
        forcer_modules(verrouilles)          # les autres cartes sont rendues
        montrer("Après la reprise forcée (utilisé 1 = pris par cette session) :", verrouilles)
    finally
        # Arrête seulement les modules tenus ; SPC_close dans tous les cas.
        liberer_tous(Int16[k for k in verrouilles if etat_init(k) == 0])
    end

    # 3 : vérification sans forcer
    initialiser(ini)
    ok = false
    try
        vus = montrer("Vérification, nouvelle initialisation sans forcer :")
        ok = !isempty(vus) && all(etat_init(k) != -6 for k in vus)
    finally
        liberer()
    end
    println()
    println(ok ? "RÉUSSI : verrou levé. Relance qc1_inventaire.jl, puis la suite." :
                 "Le verrou revient : un programme tient encore les cartes, ou il faut éteindre " *
                 "le PC puis les châssis, rallumer les châssis puis le PC, et recommencer.")
    return ok
end

spc_deverrouiller()
