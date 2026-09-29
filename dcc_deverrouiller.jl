# dcc_deverrouiller.jl — lève un verrou resté sur les DCC-100 (état -4)
# alors qu'aucun programme ne s'en sert.
#
# Cause ici : les versions précédentes de DCCLite refermaient la DLL sans
# déverrouiller les modules, et DCC_close seul ne le fait pas. À lancer avec
# le logiciel DCC et SPCM fermés. Rien n'est allumé : les sorties restent
# coupées du début à la fin.
#
# Déroulé :
#   1. DCC_init, puis état de chaque module (utilisé -1 = verrouillé ailleurs) ;
#   2. reprise forcée des modules verrouillés, un par un, car la DLL
#      n'accepte qu'un module à la fois (DCC_set_mode, force_use = 1) ;
#   3. libération normale (DCC_set_mode, in_use = 0), puis nouvelle
#      initialisation SANS forcer : si les modules sont prêts, c'est réglé.
# Colle la sortie dans la conversation.

isdefined(Main, :DCCLite) || include("DCCLite.jl")
using .DCCLite
using Printf

function dcc_deverrouiller()
    dossier = joinpath(@__DIR__, "resultats", "spc")
    ini = ecrire_ini_dcc(joinpath(dossier, "deverrouiller_dcc.ini"))

    function ligne(k)
        info = info_dcc(k)
        etat = etat_init_dcc(k)
        @printf("  module %d : n° de série %-8s bus %d, slot %d, utilisé %2d, %s\n",
                k, info.serie, info.bus, info.slot, info.utilise,
                etat == 0 ? "prête" : get(MESSAGES_INIT_DCC, etat, "état $etat"))
    end

    # 1 et 2 : état de départ, puis reprise forcée des seuls modules détectés
    initialiser_dcc(ini)
    try
        println("\nAvant (utilisé -1 = verrouillé par un autre programme) :")
        vus = modules_detectes_dcc()
        isempty(vus) && println("  aucun DCC-100 détecté")
        foreach(ligne, vus)
        verrouilles = Int16[k for k in vus if etat_init_dcc(k) == -4]
        if isempty(verrouilles)
            println("\nAucun module verrouillé : rien à faire. Relance carto1_inventaire.jl.")
            return true
        end
        println("\nReprise forcée, un module à la fois (utilisé 1 = pris par cette session) :")
        for k in verrouilles
            forcer_dcc((k,))
            ligne(k)
        end
    finally
        liberer_dcc()      # sorties coupées, modules déverrouillés, DCC_close
    end

    # 3 : vérification sans forcer
    initialiser_dcc(ini)
    ok = false
    try
        println("\nVérification, nouvelle initialisation sans forcer :")
        vus = modules_detectes_dcc()
        foreach(ligne, vus)
        ok = !isempty(vus) && all(etat_init_dcc(k) == 0 for k in vus)
    finally
        liberer_dcc()
    end
    println()
    println(ok ? "RÉUSSI : verrou levé. Relance carto1_inventaire.jl, puis la suite." :
                 "Le verrou revient : le logiciel DCC ou SPCM tient encore les modules, ou il faut " *
                 "éteindre le PC puis les châssis, rallumer les châssis puis le PC, et recommencer.")
    return ok
end

dcc_deverrouiller()
