# carto4_detecteurs.jl — quel détecteur, sur quel connecteur de quel
# DCC-100, arrive sur quelle SPC-150N.
#
# Tu allumes les détecteurs toi-même, un à la fois, dans le logiciel DCC de
# B&H (pas dans SPCM : il bloquerait les SPC-150N). Pendant ce temps, le
# script mesure le taux CFD de chaque SPC-150N : le bruit d'obscurité d'un
# détecteur allumé suffit à le repérer.
#
# Sécurité : pièce sombre ou détecteurs couverts, laser coupé, gain habituel.
# Ne branche et ne débranche aucun câble de détecteur sous tension : B&H
# prévient que cela peut détruire le préamplificateur.
# Le seuil CFD vient de reglages_spc.jl : mets-y la valeur de SPCM si aucun
# détecteur ne se détache du bruit.

isdefined(Main, :SPCLite) || include("SPCLite.jl")
using .SPCLite
using Printf
include("reglages_spc.jl")

carto4_reglages = (duree_s = 2.0,)

function carto4(r, reglages)
    dossier = joinpath(@__DIR__, "resultats", "spc")
    p = merge(reglages, Dict{String,Any}("rate_count_time" => 0.25))
    ini = ecrire_ini(joinpath(dossier, "c4_detecteurs.ini"), p)

    avec_spc_tous(ini) do modules
        series = Dict(m => (try eeprom(m).serie catch; "?" end) for m in modules)

        function mesurer()
            foreach(effacer_taux, modules)
            somme = Dict(m => 0.0 for m in modules)
            lus = Dict(m => 0 for m in modules)
            t0 = time()
            while time() - t0 < r.duree_s
                sleep(0.3)
                for m in modules
                    v = taux(m)
                    v.code == 0 || continue
                    somme[m] += v.cfd
                    lus[m] += 1
                end
            end
            return Dict(m => lus[m] > 0 ? somme[m] / lus[m] : NaN for m in modules)
        end

        affiche(nom, v) = println("  ", rpad(nom, 18),
            join((@sprintf("module %d : %9.4g /s", m, v[m]) for m in modules), "   "))

        print("Dans le logiciel DCC, tout doit être éteint. Appuie sur Entrée… ")
        flush(stdout)
        readline()
        base = mesurer()
        affiche("tout éteint", base)

        etapes = Tuple{String,Vector{Int16}}[]
        while true
            print("\nAllume UN détecteur, tape son nom (ex. « DCC1 C3 ») puis Entrée ; ",
                  "Entrée seule pour finir : ")
            flush(stdout)
            nom = String(strip(readline()))
            isempty(nom) && break
            v = mesurer()
            affiche(nom, v)
            touches = Int16[m for m in modules if v[m] > max(5 * base[m], base[m] + 200)]
            println(isempty(touches) ? "  → aucune SPC-150N ne voit de coups" :
                    "  → arrive sur le module " * join(Int.(touches), " et "))
            push!(etapes, (nom, touches))
            println("Éteins-le avant le suivant.")
        end

        println("\n== Résumé ==")
        for m in modules
            println("  SPC module $m = n° de série $(series[m])")
        end
        for (nom, touches) in etapes
            println("  ", rpad(nom, 18), isempty(touches) ? "aucune SPC" :
                    "→ module " * join(Int.(touches), " et "))
        end
        println("Colle cette sortie dans la conversation.")
        return nothing
    end
end

carto4(carto4_reglages, REGLAGES_SPC)
