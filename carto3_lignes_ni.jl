# carto3_lignes_ni.jl — quelles lignes de la 6321 arrivent sur quelles
# entrées de marqueur des SPC-150N.
#
# PILOTE les lignes P0.0 à P0.7 de la 6321, une à la fois. Laser coupé ou
# obturé et cellules de Pockels éteintes : dans ton générateur, P0.0 et P0.1
# sont des portes laser. Ces huit lignes sont déjà des sorties de ton banc,
# on ne crée donc pas de conflit ; les lignes de la 6110 ne sont pas touchées.
# SPCM fermé.
#
# Pour chaque ligne : 8 impulsions de 20 ms, pendant que chaque SPC-150N
# enregistre ses 4 marqueurs. Une ligne branchée sur un marqueur y donne
# exactement 8 fronts. Les entrées de routage et CNTE ne réagissent pas sans
# photons : elles seront vérifiées au test T5.

isdefined(Main, :DAQmxLite) || include("DAQmxLite.jl")
using .DAQmxLite
isdefined(Main, :SPCLite) || include("SPCLite.jl")
using .SPCLite
using Printf

carto3_reglages = (carte = "X6321", impulsions = 8, haut_s = 0.02, bas_s = 0.03)

function carto3(r)
    dossier = joinpath(@__DIR__, "resultats", "spc")
    p = Dict{String,Any}("mode" => 1, "adc_resolution" => 12, "stop_on_time" => 0,
                         "routing_mode" => 0xff00, "macro_time_clk" => 0)
    ini = ecrire_ini(joinpath(dossier, "c3_lignes.ini"), p)

    avec_spc_tous(ini) do modules
        tampon = zeros(UInt16, 1 << 20)

        # Une fenêtre d'acquisition : FIFO démarré sur toutes les cartes,
        # `action` exécutée, puis nombre de fronts par (module, marqueur).
        function fenetre(action)
            decs = Dict(m => Decodeur() for m in modules)
            foreach(demarrer, modules)
            sleep(0.05)
            action()
            sleep(0.05)
            for m in modules
                decoder!(decs[m], tampon, lire_fifo!(m, tampon))   # avant l'arrêt
                arreter(m)
            end
            return Dict((m, k) => length(decs[m].marqueurs[k + 1]) for m in modules for k in 0:3)
        end

        duree = r.impulsions * (r.haut_s + r.bas_s)
        withtask("carto3") do th
            add_do(th, "$(r.carte)/port0/line0:7")
            write_do(th, zeros(UInt8, 8))
            base = fenetre(() -> sleep(duree))   # rien de piloté : activité propre
            println("Activité sans rien piloter (même durée) :")
            for m in modules, k in 0:3
                base[(m, k)] > 0 && println("  module $m, M$k : $(base[(m, k)]) fronts (signal externe)")
            end

            println("\nLigne   Résultat")
            for ligne in 0:7
                comptes = fenetre() do
                    for _ in 1:r.impulsions
                        write_do(th, UInt8[k == ligne ? 0x01 : 0x00 for k in 0:7])
                        sleep(r.haut_s)
                        write_do(th, zeros(UInt8, 8))
                        sleep(r.bas_s)
                    end
                end
                trouves = String[]
                for m in modules, k in 0:3
                    c, b = comptes[(m, k)], base[(m, k)]
                    if b > 2
                        continue                     # entrée déjà occupée par un signal externe
                    elseif abs(c - r.impulsions) <= 1
                        push!(trouves, "module $m, M$k ($c fronts)")
                    elseif c > b
                        push!(trouves, "module $m, M$k : $c fronts inattendus")
                    end
                end
                @printf("P0.%d    %s\n", ligne,
                        isempty(trouves) ? "aucun marqueur (non branchée, ou sur routage ou CNTE)" :
                                           join(trouves, " ; "))
            end
            write_do(th, zeros(UInt8, 8))
        end
        println("\nToutes les lignes sont revenues à 0. Colle cette sortie dans la conversation.")
        return nothing
    end
end

carto3(carto3_reglages)
