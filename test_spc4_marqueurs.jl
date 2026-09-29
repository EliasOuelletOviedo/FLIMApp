# test_spc4_marqueurs.jl — la SPC-150N horodate des impulsions venues de la 6321.
#
# Branchements (tableau « Branchements » du plan) :
#   BNC-2090A de la 6321, borne CTR 1 OUT (PFI 13) → SPC-150N broche 12 (Marker 0)
#   BNC-2090A de la 6321, borne D GND              → SPC-150N broche 15 (masse)
#   Rien d'autre sur la broche 12 pendant ce test.
# SPCM fermé. Laser et détecteur inutiles.
#
# Déroulé : la carte passe en mode FIFO avec les 4 marqueurs actifs sur
# front montant ; le compteur ctr1 de la 6321 envoie 200 impulsions de 1 ms
# à 100 Hz ; on lit le FIFO en continu, puis on décode.
#
# Réussi si : 200 marqueurs M0, intervalle moyen de 10 ms à 0,1 % près,
# écart-type sous 1 µs.
#
# Sans carte NI dans ce PC : mets ni_present = false et envoie un signal TTL
# de ton choix sur la broche 12 ; le test compte les fronts pendant duree_s.

isdefined(Main, :DAQmxLite) || include("DAQmxLite.jl")
using .DAQmxLite
isdefined(Main, :SPCLite) || include("SPCLite.jl")
using .SPCLite
using Printf

spc4 = (module_no = 0, ni_present = true, carte = "X6321", compteur = "ctr1",
        sortie = "PFI13", n = 200, frequence = 100.0, largeur_s = 0.001,
        duree_s = 3.0)   # duree_s : seulement quand ni_present = false

function test_spc4(r)
    dossier = joinpath(@__DIR__, "resultats", "spc")
    p = Dict{String,Any}("mode" => 1, "adc_resolution" => 12, "stop_on_time" => 0,
                         "routing_mode" => 0xff00,   # 4 marqueurs actifs, fronts montants
                         "macro_time_clk" => 0)
    ini = ecrire_ini(joinpath(dossier, "t4_marqueurs.ini"), p)

    avec_spc(ini; module_no = r.module_no) do m
        f = fifo_init(m)
        tic = f.horloge_macro_s
        @printf("Flux FIFO de type %d, tic du macrotemps %.1f ns\n", f.type_fifo, tic * 1e9)
        tic > 0 || error("durée du tic nulle : le mode FIFO n'est pas actif")

        dec = Decodeur()
        tampon = zeros(UInt16, 1 << 20)
        deborde = false
        function lire_pendant(secondes)
            fin = time() + secondes
            while time() < fin
                decoder!(dec, tampon, lire_fifo!(m, tampon))
                (etat_mesure(m) & SPC_FOVFL) != 0 && (deborde = true)
                sleep(0.02)
            end
        end

        demarrer(m)
        if r.ni_present
            withtask("marqueurs_spc") do th
                voie = "$(r.carte)/$(r.compteur)"
                add_co_pulse_freq(th, voie, r.frequence; duty = r.largeur_s * r.frequence)
                chk(ccall((:DAQmxSetCOPulseTerm, "nicaiu"), Int32,
                          (Ptr{Cvoid}, Cstring, Cstring), th, voie, "/$(r.carte)/$(r.sortie)"))
                cfg_implicit_timing(th, Val_FiniteSamps, r.n)
                start_task(th)
                lire_pendant(r.n / r.frequence + 0.5)
            end
        else
            println("Envoie maintenant ton signal TTL sur la broche 12 ($(r.duree_s) s)…")
            lire_pendant(r.duree_s)
        end
        decoder!(dec, tampon, lire_fifo!(m, tampon))   # avant l'arrêt, qui vide le FIFO
        arreter(m)

        t = dec.marqueurs[1]
        n = length(t)
        @printf("\nMarqueurs reçus : M0 = %d%s, M1 = %d, M2 = %d, M3 = %d\n", n,
                r.ni_present ? " (attendu $(r.n))" : "", length(dec.marqueurs[2]),
                length(dec.marqueurs[3]), length(dec.marqueurs[4]))
        @printf("Photons : %d (0 attendu sans laser) ; pertes signalées : %d ; FIFO débordé : %s\n",
                dec.photons, dec.pertes, deborde ? "OUI" : "non")

        ok = r.ni_present ? n == r.n : n >= 2
        if n >= 2
            dt = diff(t) .* tic
            moy = sum(dt) / length(dt)
            et = length(dt) > 1 ? sqrt(sum((dt .- moy) .^ 2) / (length(dt) - 1)) : 0.0
            @printf("Intervalle moyen : %.6f ms (%.4f Hz) ; écart-type : %.1f ns ; min %.6f ms ; max %.6f ms\n",
                    moy * 1e3, 1 / moy, et * 1e9, minimum(dt) * 1e3, maximum(dt) * 1e3)
            if r.ni_present
                ecart_ppm = (moy * r.frequence - 1) * 1e6
                @printf("Écart à 10 ms : %+.1f ppm (horloges NI et B&H, chacune à quelques dizaines de ppm)\n",
                        ecart_ppm)
                ok &= abs(ecart_ppm) < 1000 && et < 1e-6
            end
        end

        open(joinpath(dossier, "t4_marqueurs_M0.csv"), "w") do io
            println(io, "indice,temps_s")
            for (i, x) in enumerate(t)
                @printf(io, "%d,%.9f\n", i, x * tic)
            end
        end

        println()
        println(ok ? "RÉUSSI : la carte reçoit et horodate les impulsions." :
                     "ÉCHEC : voir « Si un test échoue » dans le plan (câblage de la broche 12, masse).")
        return ok
    end
end

test_spc4(spc4)
