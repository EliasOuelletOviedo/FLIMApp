# dcc_eteindre.jl — éteint les détecteurs sans le logiciel DCC.
#
# DCC_init charge des réglages nuls, écrits explicitement (gains à 0,
# alimentations, sortie numérique et refroidissement coupés), et coupe
# toutes les sorties. Une surcharge restée signalée est ensuite effacée, sans
# risque puisque tout est à zéro et coupé. La coupure est vérifiée, puis les
# modules sont libérés.
#
# Un module tenu par SPCM ou le logiciel DCC ne peut pas être éteint d'ici :
# ferme-les d'abord. S'il reste pris alors qu'aucun programme ne tourne
# (script arrêté brutalement), lance dcc_deverrouiller.jl : quand il affiche
# RÉUSSI, le module est repris et ses sorties sont coupées.

Base.exit_on_sigint(false)          # Ctrl+C passe par le nettoyage, même hors REPL
isdefined(Main, :DCCLite) || include("DCCLite.jl")
using .DCCLite
(isdefined(DCCLite, :VERSION_LITE) && DCCLite.VERSION_LITE >= 8) ||
    error("Julia a gardé une ancienne version de DCCLite.jl : redémarre Julia, puis relance ce script.")

function dcc_eteindre()
    zero = Dict(k => Dict{String,Any}(c => 0 for (c, _, _) in CLES_DCC) for k in 0:7)
    ini = ecrire_ini_dcc_reglages(joinpath(@__DIR__, "resultats", "dcc", "eteindre.ini"), zero)
    echecs = Int16[]
    try
        code = initialiser_dcc(ini)
        code < 0 && println("DCC_init : $code ($(message_erreur_dcc(code)))")
        vus = modules_detectes_dcc()
        isempty(vus) && println("Aucune DCC-100 détectée.")
        for m in vus
            etat = etat_init_dcc(m)
            serie = info_dcc(m).serie
            if etat != 0
                println("Module DCC $m ($serie) : PAS éteint, ", get(MESSAGES_INIT_DCC, etat, "état $etat"),
                        etat == -4 ? " → ferme SPCM et le logiciel DCC, puis relance ; s'il reste pris, " *
                                     "lance dcc_deverrouiller.jl" : "")
                continue
            end
            s = surcharge_dcc(m)
            if s.c1 || s.c3
                effacer_surcharge_dcc(m)          # réglages à zéro, sorties coupées : sans risque
                couper_sorties_dcc(m) < 0 && push!(echecs, m)
                s = surcharge_dcc(m)
                println("Module DCC $m ($serie) : surcharge ",
                        s.c1 || s.c3 ? "TOUJOURS SIGNALÉE (C1 $(s.c1), C3 $(s.c3))" : "effacée")
            end
            couper_sorties_dcc(m) < 0 && push!(echecs, m)
            println("Module DCC $m ($serie) : réglages à zéro, sorties coupées")
        end
    finally
        append!(echecs, liberer_dcc())
        isempty(echecs) ||
            println("ATTENTION : la coupure des sorties a échoué sur les modules DCC $(Int.(unique(echecs))) : ",
                    "éteins-les avec le logiciel DCC.")
    end
    return nothing
end

dcc_eteindre()
