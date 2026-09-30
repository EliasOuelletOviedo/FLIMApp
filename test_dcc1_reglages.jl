# test_dcc1_reglages.jl — charge les réglages de reglages_dcc.jl dans les
# DCC-100, SANS rien allumer, et vérifie ce que la DLL en a fait.
#
# Les sorties restent coupées du début à la fin : DCC_init les coupe, et ce
# test ne les active jamais. Il vérifie :
#   - que chaque module réglé est là et libre (n° de série à comparer avec
#     « Show Info » dans le panneau DCC de SPCM) ;
#   - la limite de gain de chaque connecteur (EEPROM), face au gain demandé ;
#   - l'absence de surcharge ;
#   - que la DLL a retenu les gains et le refroidisseur demandés (contrôle
#     indirect : on retrouve ces valeurs dans ses paramètres internes).
#
# Avant : SPCM et le logiciel DCC fermés (ils tiennent les DCC-100).
# Colle la sortie dans la conversation.

Base.exit_on_sigint(false)          # Ctrl+C passe par le nettoyage, même hors REPL
isdefined(Main, :DCCLite) || include("DCCLite.jl")
using .DCCLite
(isdefined(DCCLite, :VERSION_LITE) && DCCLite.VERSION_LITE >= 8) ||
    error("Julia a gardé une ancienne version de DCCLite.jl : redémarre Julia, puis relance ce script.")
using Printf
include("reglages_dcc.jl")

function test_dcc1(reglages)
    dossier = joinpath(@__DIR__, "resultats", "dcc")
    ini = ecrire_ini_dcc_reglages(joinpath(dossier, "test_dcc1.ini"), reglages)  # vérifie les clés
    foreach(m -> afficher_reglages_dcc(m, reglages[m]), sort!(collect(keys(reglages))))
    println("Fichier d'initialisation : ", ini)

    rien_d_anormal = true
    try
        code = initialiser_dcc(ini)
        code < 0 && println("DCC_init : $code ($(message_erreur_dcc(code)))")
        vus = modules_detectes_dcc()
        for m in sort!(collect(keys(reglages)))
            println("\n== Module DCC $m ==")
            if !(m in vus)
                println("  absent (DCC-100 détectées : $(Int.(vus)))")
                rien_d_anormal = false
                continue
            end
            info = info_dcc(m)
            etat = etat_init_dcc(m)
            @printf("  n° de série %s, bus %d, slot %d : %s\n", info.serie, info.bus, info.slot,
                    etat == 0 ? "prêt" : get(MESSAGES_INIT_DCC, etat, "état $etat"))
            if etat != 0
                rien_d_anormal = false
                etat == -4 && println("  → ferme SPCM et le logiciel DCC ; si le module reste pris, lance dcc_deverrouiller.jl")
                continue
            end
            p = reglages[m]

            # Limites de gain écrites dans la carte
            for c in (1, 3)
                g = Float64(get(p, "c$(c)_gain_HV", 0.0))
                lim = limite_gain_dcc(m, c)
                @printf("  connecteur %d : gain demandé %.2f %%, limite de la carte %d %%%s\n",
                        c, g, lim, g > lim ? " ← AU-DESSUS DE LA LIMITE : baisse-le" : "")
                g > lim && (rien_d_anormal = false)
            end

            # Protections
            s = surcharge_dcc(m)
            println("  surcharge : C1 ", s.c1 ? "OUI" : "non", ", C3 ", s.c3 ? "OUI" : "non",
                    " ; limite de courant du refroidisseur : ", limite_courant_dcc(m) ? "atteinte" : "non")
            if s.c1 || s.c3
                rien_d_anormal = false
                println("  → supprime la cause (trop de lumière ?), puis lance dcc_eteindre.jl, qui efface la surcharge")
            end

            # Valeurs retenues par la DLL : gains et refroidisseur, retrouvés dans
            # ses paramètres internes (les alimentations et b0 ne se voient qu'à
            # l'allumage, avec test_dcc2)
            b = parametres_bruts_dcc(m)
            attendus = Dict{Float64,Int}()
            for cle in ("c1_gain_HV", "c3_gain_HV", "c3_coolVolt", "c3_coolCurr")
                v = Float64(get(p, cle, 0.0))
                v > 0 && (attendus[v] = get(attendus, v, 0) + 1)
            end
            for (v, k) in sort!(collect(attendus); by = first)
                n = compter_flottant_dcc(b, v)
                @printf("  valeur %.2f retrouvée %d fois dans la DLL (attendue %d fois)%s\n",
                        v, n, k, n >= k ? "" : " ← pas retrouvée : colle-moi cette sortie")
                n >= k || (rien_d_anormal = false)
            end
        end
    finally
        echecs = liberer_dcc()      # sorties coupées (elles l'étaient déjà), modules libérés
        isempty(echecs) || println("ATTENTION : coupure des sorties refusée sur les modules $(Int.(echecs))")
    end
    println()
    println("Rien n'a été allumé.")
    println(rien_d_anormal ? "Rien d'anormal : tu peux lancer test_dcc2_allumage.jl." :
                             "Un point ne va pas (voir plus haut) : colle cette sortie dans la conversation.")
    return rien_d_anormal
end

test_dcc1(REGLAGES_DCC)
