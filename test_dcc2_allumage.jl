# test_dcc2_allumage.jl — allume les détecteurs sans le logiciel DCC, les
# surveille, puis les éteint (ou les laisse allumés : garder_allume = true).
#
# Déroulé :
#   1. réglages de reglages_dcc.jl vérifiés et affichés, puis confirmation
#      au clavier (« oui ») ;
#   2. SPC-150N initialisées avec reglages_spc.jl, pour lire le taux CFD ;
#   3. DCC-100 initialisées avec reglages_dcc.jl (sorties coupées par la
#      DLL), vérifiées (module libre, gain sous la limite de la carte, pas de
#      surcharge), taux CFD lu détecteurs éteints ;
#   4. sorties activées, comme le bouton « Enable outputs », puis
#      surveillance pendant surveillance_s : surcharge, limite de courant du
#      refroidisseur et taux CFD chaque seconde. Surcharge → tout est coupé ;
#   5. à la fin, sorties coupées et coupure vérifiée. Avec garder_allume =
#      true, la DLL DCC est refermée sans couper, puis le taux CFD est relu :
#      on voit si les détecteurs restent allumés une fois le script fini.
# Ctrl+C ou une erreur coupent les sorties. Fermer la fenêtre ou tuer Julia
# ne le permet pas : le module reste pris et peut-être allumé. Lance alors
# dcc_deverrouiller.jl : quand il affiche RÉUSSI, le module est repris et ses
# sorties sont coupées.
#
# Avant : test_dcc1_reglages.jl sans anomalie. SPCM et le logiciel DCC
# fermés ; laser allumé ; détecteurs à l'abri de la lumière ambiante, comme
# quand tu cliques « Enable outputs ». Pour éteindre plus tard : dcc_eteindre.jl.
# Colle la sortie dans la conversation.

Base.exit_on_sigint(false)          # Ctrl+C passe par le nettoyage, même hors REPL
isdefined(Main, :SPCLite) || include("SPCLite.jl")
isdefined(Main, :DCCLite) || include("DCCLite.jl")
using .SPCLite, .DCCLite
(isdefined(SPCLite, :VERSION_LITE) && SPCLite.VERSION_LITE >= 8 &&
 isdefined(DCCLite, :VERSION_LITE) && DCCLite.VERSION_LITE >= 8) ||
    error("Julia a gardé une ancienne version de SPCLite.jl ou DCCLite.jl : redémarre Julia, puis relance ce script.")
using Printf
include("reglages_spc.jl")
include("reglages_dcc.jl")

dcc2_reglages = (
    surveillance_s = 10.0,       # durée d'allumage surveillée (3 s au moins)
    verifier_spc = true,         # taux CFD des SPC-150N avant, pendant et après
    garder_allume = false,       # true : détecteurs laissés allumés à la fin
)

"""Taux des SPC-150N : compteurs remis à zéro, puis une lecture complète."""
function taux_dcc2(spc)
    t = Dict{Int16,Any}()
    isempty(spc) && return t
    foreach(effacer_taux, spc)
    sleep(0.7)                                   # rate_count_time = 0,25 s
    for m in spc
        v = taux(m)
        t0 = time()
        while v.code < 0 && time() - t0 < 3
            sleep(0.1)
            v = taux(m)
        end
        t[m] = v
    end
    return t
end

function afficher_taux_dcc2(titre, t)
    for (m, v) in sort!(collect(t); by = first)
        @printf("  %-32s SPC %d : SYNC %.3g /s, CFD %.3g /s, ADC %.3g /s%s\n",
                titre, m, v.sync, v.cfd, v.adc, v.code < 0 ? " (taux pas prêts)" : "")
    end
end

"""Une surcharge sur l'un des modules ? (numéro du module, ou nothing)"""
function surcharge_dcc2(modules)
    for m in modules
        s = surcharge_dcc(m)
        (s.c1 || s.c3) && return (module_dcc = m, c1 = s.c1, c3 = s.c3)
    end
    return nothing
end

"""
Surveille les modules allumés. Surcharge : coupe tout et renvoie false.
Une ligne par seconde : surcharge, limite de courant, taux CFD.
"""
function surveiller_dcc2(modules, spc, duree_s)
    t0 = time()
    prochain = 0.0
    while (t = time() - t0) < duree_s
        s = surcharge_dcc2(modules)
        if s !== nothing
            for k in modules
                try; couper_sorties_dcc(k); catch; end
            end
            println("  SURCHARGE sur le module DCC $(s.module_dcc) (C1 ", s.c1 ? "OUI" : "non", ", C3 ",
                    s.c3 ? "OUI" : "non", ") : sorties coupées. Trop de lumière sur un détecteur ?")
            return false
        end
        if t >= prochain
            ligne = @sprintf("  t = %4.1f s : pas de surcharge", t)
            for m in modules
                limite_courant_dcc(m) && (ligne *= " ; refroidisseur du module $m à sa limite de courant")
            end
            for m in spc
                v = taux(m)
                ligne *= v.code < 0 ? " ; CFD SPC $m —" : @sprintf(" ; CFD SPC %d %.3g /s", m, v.cfd)
            end
            println(ligne)
            prochain += 1.0
        end
        sleep(0.1)
    end
    return true
end

function sequence_dcc2(r, modules, reg_dcc, ini_dcc, spc)
    garder = false
    echecs = Int16[]
    try
        code = initialiser_dcc(ini_dcc)
        code < 0 && println("DCC_init : $code ($(message_erreur_dcc(code)))")
        for m in modules
            etat = etat_init_dcc(m)
            etat == 0 || error("module DCC $m : " * get(MESSAGES_INIT_DCC, etat, "état $etat") *
                               (etat == -4 ? " ; ferme SPCM et le logiciel DCC" : ""))
            for c in (1, 3)
                g = Float64(get(reg_dcc[m], "c$(c)_gain_HV", 0.0))
                lim = limite_gain_dcc(m, c)
                g <= lim || error("module DCC $m, connecteur $c : gain demandé $g %, au-dessus de la " *
                                  "limite de la carte ($lim %). Baisse-le dans reglages_dcc.jl.")
            end
            println("Module DCC $m : n° de série $(info_dcc(m).serie), prêt, sorties coupées")
        end
        s = surcharge_dcc2(modules)
        s === nothing || error("module DCC $(s.module_dcc) : surcharge déjà signalée (C1 $(s.c1), C3 $(s.c3)). " *
                               "Supprime la cause, lance dcc_eteindre.jl pour l'effacer, puis relance.")
        afficher_taux_dcc2("détecteurs éteints :", taux_dcc2(spc))

        foreach(activer_sorties_dcc, modules)
        println("\nSorties activées. Surveillance pendant $(r.surveillance_s) s :")
        ok = surveiller_dcc2(modules, spc, r.surveillance_s)
        ok && afficher_taux_dcc2("détecteurs allumés :", taux_dcc2(spc))
        if ok                                                # rien n'a sauté pendant la lecture ?
            s = surcharge_dcc2(modules)
            if s !== nothing
                println("  SURCHARGE sur le module DCC $(s.module_dcc) (C1 ", s.c1 ? "OUI" : "non", ", C3 ",
                        s.c3 ? "OUI" : "non", ") au dernier contrôle : les sorties vont être coupées.")
                ok = false
            end
        end
        garder = ok && r.garder_allume
    finally
        if garder
            liberer_dcc(couper = false)
        else
            for m in modules                   # coupure vérifiée, sur les seuls modules pris ici
                pris_ici = try
                    etat_init_dcc(m) == 0
                catch
                    false
                end
                pris_ici || continue
                code = try
                    couper_sorties_dcc(m)
                catch
                    -1
                end
                code < 0 && push!(echecs, m)
            end
            append!(echecs, liberer_dcc())
            isempty(echecs) ||
                println("\nATTENTION : la coupure des sorties a échoué sur les modules DCC $(Int.(unique(echecs))). ",
                        "Éteins-les avec dcc_eteindre.jl, ou avec le logiciel DCC.")
        end
    end

    if garder
        println("\nDLL DCC refermée sans couper les sorties.")
        if !isempty(spc)
            afficher_taux_dcc2("après fermeture de la DLL DCC :", taux_dcc2(spc))
            println("  CFD toujours élevé : les détecteurs restent allumés après le script.")
            println("  CFD retombé : la fermeture de la DLL les a éteints ; dis-le-moi.")
        end
        println("Pour les éteindre : dcc_eteindre.jl.")
    elseif isempty(echecs)
        println("\nSorties coupées (coupure confirmée par la DLL), modules DCC libérés : détecteurs éteints.")
    end
    return nothing
end

function test_dcc2(r, reg_dcc, reg_spc)
    r.surveillance_s >= 3 || error("surveillance_s : 3 s au moins")
    verifier_reglages_dcc(reg_dcc)                # clés et bornes, avant toute question
    modules = sort!(Int16.(collect(keys(reg_dcc))))
    foreach(m -> afficher_reglages_dcc(m, reg_dcc[m]), modules)
    println("\nCes réglages vont être appliqués et les sorties activées, comme avec « Enable outputs ».")
    println(r.garder_allume ?
            "garder_allume = true : les détecteurs RESTERONT ALLUMÉS à la fin du script." :
            "garder_allume = false : les détecteurs seront éteints à la fin du script.")
    println("SPCM et le logiciel DCC sont fermés, et les détecteurs à l'abri de la lumière ambiante ?")
    print("Tape oui pour allumer : ")
    flush(stdout)
    if lowercase(strip(readline())) != "oui"
        println("Annulé : rien n'a été allumé.")
        return nothing
    end

    dossier = joinpath(@__DIR__, "resultats", "dcc")
    ini_dcc = ecrire_ini_dcc_reglages(joinpath(dossier, "test_dcc2.ini"), reg_dcc)
    if r.verifier_spc
        ini_spc = ecrire_ini(joinpath(dossier, "test_dcc2_spc.ini"),
                             merge(reg_spc, Dict{String,Any}("mode" => 0, "rate_count_time" => 0.25)))
        avec_spc_tous(ini_spc) do spc
            sequence_dcc2(r, modules, reg_dcc, ini_dcc, spc)
        end
    else
        sequence_dcc2(r, modules, reg_dcc, ini_dcc, Int16[])
    end
    return nothing
end

test_dcc2(dcc2_reglages, REGLAGES_DCC, REGLAGES_SPC)
