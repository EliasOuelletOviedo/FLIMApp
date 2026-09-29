# carto2_entrees.jl — ce qui arrive déjà sur les entrées des SPC-150N.
#
# Ne pilote rien : ni ligne NI, ni DCC-100. SPCM fermé.
# À lancer deux fois : laser coupé, puis laser allumé (faisceau bloqué avant
# l'échantillon si tu préfères). La carte dont le SYNC s'allume est celle
# qui reçoit la référence du laser.
#
# Donne, pour chaque SPC-150N : taux SYNC et CFD, état du SYNC, photons, et
# l'activité de ses 4 entrées de marqueur (par exemple les horloges de ligne
# et de trame d'un scanner). Colle la sortie dans la conversation.

isdefined(Main, :SPCLite) || include("SPCLite.jl")
using .SPCLite
using Printf
include("reglages_spc.jl")

carto2_reglages = (duree_taux_s = 2.0, duree_fifo_s = 3.0)

function carto2(r, reglages)
    dossier = joinpath(@__DIR__, "resultats", "spc")
    p = merge(reglages, Dict{String,Any}(
        "mode" => 1, "adc_resolution" => 12, "stop_on_time" => 0,
        "routing_mode" => 0xff00,          # 4 marqueurs actifs, fronts montants
        "macro_time_clk" => 0, "rate_count_time" => 0.25))
    ini = ecrire_ini(joinpath(dossier, "c2_entrees.ini"), p)

    avec_spc_tous(ini) do modules
        # 1. Compteurs de taux, moyennés
        foreach(effacer_taux, modules)
        somme = Dict(m => zeros(4) for m in modules)
        lus = Dict(m => 0 for m in modules)
        t0 = time()
        while time() - t0 < r.duree_taux_s
            sleep(0.3)
            for m in modules
                v = taux(m)
                v.code == 0 || continue
                somme[m] .+= (v.sync, v.cfd, v.tac, v.adc)
                lus[m] += 1
            end
        end
        etats = Dict(m => sync_etat(m) for m in modules)

        # 2. FIFO sur toutes les cartes à la fois : marqueurs et photons
        tics = Dict(m => fifo_init(m).horloge_macro_s for m in modules)
        decs = Dict(m => Decodeur() for m in modules)
        tampon = zeros(UInt16, 1 << 20)
        foreach(demarrer, modules)
        t0 = time()
        while time() - t0 < r.duree_fifo_s
            for m in modules
                decoder!(decs[m], tampon, lire_fifo!(m, tampon))
            end
            sleep(0.02)
        end
        for m in modules
            decoder!(decs[m], tampon, lire_fifo!(m, tampon))   # avant l'arrêt
            arreter(m)
        end

        # 3. Rapport
        for m in modules
            serie = try
                eeprom(m).serie
            catch
                "?"
            end
            moy = lus[m] > 0 ? somme[m] ./ lus[m] : fill(NaN, 4)
            println("\n== SPC module $m (n° de série $serie) ==")
            @printf("  SYNC %.4g /s (%s) ; CFD %.4g /s ; TAC %.4g /s ; ADC %.4g /s\n",
                    moy[1], get(MESSAGES_SYNC, etats[m], string(etats[m])), moy[2], moy[3], moy[4])
            d = decs[m]
            @printf("  Photons en %.0f s : %d ; pertes signalées : %d\n", r.duree_fifo_s, d.photons, d.pertes)
            for k in 0:3
                t = d.marqueurs[k + 1]
                if length(t) >= 2
                    periode = (t[end] - t[1]) / (length(t) - 1) * tics[m]
                    @printf("  M%d : %d fronts, %.4g Hz (période %.4g ms)\n", k, length(t), 1 / periode, periode * 1e3)
                else
                    @printf("  M%d : %d front%s\n", k, length(t), length(t) > 1 ? "s" : "")
                end
            end
        end
        println("""

            Lecture :
              - SYNC correct sur un seul module : c'est lui qui reçoit la référence du laser.
              - Un marqueur à quelques kHz ressemble à une horloge de ligne de scanner ;
                à quelques Hz, à une horloge de trame.
              - CFD au-dessus de quelques dizaines par seconde laser coupé : un détecteur
                est déjà alimenté (voir carto4).
            Colle cette sortie dans la conversation.""")
        return nothing
    end
end

carto2(carto2_reglages, REGLAGES_SPC)
