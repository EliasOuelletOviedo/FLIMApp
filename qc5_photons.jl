# qc5_photons.jl — vrais photons sur la QC-104, avec le format établi par qc4.
#
# Il faut : format_fifo_qc104.jl (écrit par qc4_format_fifo.jl), le laser,
# les détecteurs allumés (logiciel DCC), un échantillon fluorescent, les
# réglages de reglages_qc.jl, et les branchements de qc4 :
#   CTR 1 OUT (PFI 13) → broches 12 (M0) et 10 (M3) ; P0.4-P0.7 → broches 2, 3, 4, 7 ;
#   D GND → broche 5 ou 15. SPCM fermé.
#
# Déroulé : une acquisition FIFO pendant que la 6321 envoie 200 impulsions de
# 1 ms à 100 Hz (M0 sur le front montant, M3 sur le front descendant, comme
# les passes de ton GUI) et écrit un code de région sur P0.4-P0.7. Décodage
# au fil de l'eau par SPCLite.DecodeurFIFO, puis contrôle par la DLL.
#
# Réussi si : 200 M0 et 200 M3 ; M3 - M0 = 1 ms et période de 10 ms à
# 0,1 % près (horloges NI et B&H) ; tic de 2,048 ns ; des photons sur IN1 et
# IN2 avec un déclin propre (resultats/qc/q5_declins.svg) ; routage lu =
# code écrit, ou son complément, pour plus de 99 % des photons ; mêmes
# comptes que la DLL.

Base.exit_on_sigint(false)
isdefined(Main, :DAQmxLite) || include("DAQmxLite.jl")
using .DAQmxLite
isdefined(Main, :SPCLite) || include("SPCLite.jl")
using .SPCLite
(isdefined(SPCLite, :VERSION_LITE) && SPCLite.VERSION_LITE >= 9) ||
    error("Julia a gardé une ancienne version de SPCLite.jl : redémarre Julia, puis relance ce script.")
using Printf
include("reglages_qc.jl")
isfile(joinpath(@__DIR__, "format_fifo_qc104.jl")) ||
    error("format_fifo_qc104.jl absent : lance d'abord qc4_format_fifo.jl.")
include("format_fifo_qc104.jl")

qc5 = (ni_present = true, carte = "X6321", compteur = "ctr1", sortie = "PFI13",
       lignes_routage = "port0/line4:7", code_region = 5,
       n = 200, frequence = 100.0, largeur_s = 0.001,
       routing_mode = 0x1900,      # M0 front montant, M3 front descendant
       numero_serie = "", duree_s = 3.0)   # duree_s : seulement si ni_present = false

"""Déclins en SVG, axe vertical logarithmique, une couleur par entrée."""
function svg_declins_qc5(chemin, t_ns, courbes, noms, titre)
    L, H = 760, 440
    g, d, h, b = 80, 24, 48, 56
    lx, ly = L - g - d, H - h - b
    xmax = maximum(t_ns)
    ymax = max(1.0, ceil(log10(maximum(maximum.(courbes)) + 1)))
    X(t) = g + lx * t / xmax
    Y(c) = h + ly * (1 - log10(c + 1) / ymax)
    pas = xmax / 8
    for p in (0.1, 0.2, 0.5, 1, 2, 5, 10, 20, 50, 100)
        xmax / p <= 8 && (pas = p; break)
    end
    couleurs = ("#1d4ed8", "#c2410c", "#15803d", "#7c3aed")
    open(chemin, "w") do io
        println(io, """<svg xmlns="http://www.w3.org/2000/svg" width="$L" height="$H" font-family="sans-serif" font-size="12">""")
        println(io, """<rect width="$L" height="$H" fill="white"/>""")
        println(io, """<text x="$g" y="28" font-size="15">$titre</text>""")
        @printf(io, "<line x1=\"%d\" y1=\"%d\" x2=\"%d\" y2=\"%d\" stroke=\"black\"/>\n", g, h + ly, g + lx, h + ly)
        @printf(io, "<line x1=\"%d\" y1=\"%d\" x2=\"%d\" y2=\"%d\" stroke=\"black\"/>\n", g, h, g, h + ly)
        for t in 0:pas:xmax
            @printf(io, "<line x1=\"%.1f\" y1=\"%d\" x2=\"%.1f\" y2=\"%d\" stroke=\"black\"/>\n", X(t), h + ly, X(t), h + ly + 5)
            @printf(io, "<text x=\"%.1f\" y=\"%d\" text-anchor=\"middle\">%g</text>\n", X(t), h + ly + 19, t)
        end
        for k in 0:Int(ymax)
            y = h + ly * (1 - k / ymax)
            @printf(io, "<line x1=\"%d\" y1=\"%.1f\" x2=\"%d\" y2=\"%.1f\" stroke=\"#ddd\"/>\n", g, y, g + lx, y)
            @printf(io, "<text x=\"%d\" y=\"%.1f\" text-anchor=\"end\">1e%d</text>\n", g - 8, y + 4, k)
        end
        @printf(io, "<text x=\"%.1f\" y=\"%d\" text-anchor=\"middle\">microtemps (ns)</text>\n", g + lx / 2, H - 14)
        @printf(io, "<text x=\"18\" y=\"%.1f\" text-anchor=\"middle\" transform=\"rotate(-90 18 %.1f)\">coups + 1 (log)</text>\n", h + ly / 2, h + ly / 2)
        for (i, (c, nom)) in enumerate(zip(courbes, noms))
            pts = join((@sprintf("%.1f,%.1f", X(t), Y(v)) for (t, v) in zip(t_ns, c)), " ")
            col = couleurs[mod1(i, length(couleurs))]
            println(io, """<polyline fill="none" stroke="$col" stroke-width="1.2" points="$pts"/>""")
            println(io, """<text x="$(g + lx - 120)" y="$(h + 16 * i)" fill="$col">$nom</text>""")
        end
        println(io, "</svg>")
    end
    return chemin
end

function test_qc5(r, reglages, format)
    dossier = joinpath(@__DIR__, "resultats", "qc")
    p = merge(parametres_qc(reglages), Dict{String,Any}(
        "mode" => 1, "adc_resolution" => 12, "stop_on_time" => 0, "collect_time" => 1.0,
        "macro_time_clk" => 0, "trigger" => 0, "routing_mode" => Int(r.routing_mode)))
    ini = ecrire_ini(joinpath(dossier, "q5_photons.ini"), p)
    println("Format : ", format.nom, "\n  ", format.verification)

    avec_spc_tous(ini; types = (TYPE_QC104,)) do modules
        m = modules[1]
        if !isempty(r.numero_serie)
            i = findfirst(k -> (try eeprom(k).serie catch; "" end) == r.numero_serie, modules)
            i === nothing && error("aucune QC-104 de n° de série $(r.numero_serie)")
            m = modules[i]
        end
        lu = lire_parametres(m; fichier = joinpath(dossier, "q5_relu.ini"))
        println("\nRéglages appliqués :")
        afficher_qc(reglages, lu)
        dt_ns = largeur_canal_s(TYPE_QC104, lu) * 1e9
        f = fifo_init(m)
        tic = tic_macro_s(m)
        s = sync_etat(m)
        println("\nSYNC : ", get(MESSAGES_SYNC, s, string(s)))
        s == 1 || (println("ÉCHEC : il faut un SYNC correct (câble du laser, seuil SYNC dans reglages_qc.jl)."); return false)

        dec = DecodeurFIFO(format)
        tampon = zeros(UInt16, 1 << 21)
        brut = UInt16[]
        deborde = false
        function lire_pendant(secondes)
            fin = time() + secondes
            while time() < fin
                n = lire_fifo!(m, tampon)
                decoder!(dec, tampon, n)
                append!(brut, view(tampon, 1:n))
                (etat_mesure(m) & SPC_FOVFL) != 0 && (deborde = true)
                sleep(0.01)
            end
        end

        code = UInt8(r.code_region) & 0x0f
        duree = r.ni_present ? r.n / r.frequence + 0.5 : r.duree_s
        if r.ni_present
            withtasks("routage_qc5", "marqueurs_qc5") do th_do, th_co
                add_do(th_do, "$(r.carte)/$(r.lignes_routage)")
                write_do(th_do, UInt8[(code >> k) & 0x01 for k in 0:3])
                voie = "$(r.carte)/$(r.compteur)"
                add_co_pulse_freq(th_co, voie, r.frequence; duty = r.largeur_s * r.frequence)
                chk(ccall((:DAQmxSetCOPulseTerm, "nicaiu"), Int32,
                          (Ptr{Cvoid}, Cstring, Cstring), th_co, voie, "/$(r.carte)/$(r.sortie)"))
                cfg_implicit_timing(th_co, Val_FiniteSamps, r.n)
                demarrer(m)
                sleep(0.05)
                start_task(th_co)
                lire_pendant(duree)
                n = lire_fifo!(m, tampon)                # avant l'arrêt, qui vide le FIFO
                decoder!(dec, tampon, n); append!(brut, view(tampon, 1:n))
                arreter(m)
                write_do(th_do, UInt8[0, 0, 0, 0])
            end
        else
            demarrer(m)
            lire_pendant(duree)
            n = lire_fifo!(m, tampon)
            decoder!(dec, tampon, n); append!(brut, view(tampon, 1:n))
            arreter(m)
        end
        isodd(length(brut)) && pop!(brut)

        println()
        @printf("Photons : %d en %.1f s (IN1 %d, IN2 %d, IN3 %d) ; rejetés %d ; inattendus %d ; pertes %d%s\n",
                dec.photons, duree, dec.par_voie[1], dec.par_voie[2], dec.par_voie[3], dec.rejetes,
                dec.inattendus, dec.pertes, deborde ? " ; FIFO DÉBORDÉ (baisse la lumière)" : "")
        ok = !deborde && dec.inattendus == 0

        # Marqueurs : nombre, période, largeur M3 - M0, durée du tic
        m0, m3 = dec.marqueurs[1], dec.marqueurs[4]
        @printf("Marqueurs : M0 %d, M1 %d, M2 %d, M3 %d%s\n", length(m0), length(dec.marqueurs[2]),
                length(dec.marqueurs[3]), length(m3), r.ni_present ? " (attendu $(r.n) M0 et $(r.n) M3)" : "")
        if r.ni_present
            ok &= length(m0) == r.n && length(m3) == r.n
            if length(m0) >= 2
                periode_tics = (m0[end] - m0[1]) / (length(m0) - 1)
                tic_mesure = 1 / r.frequence / periode_tics
                @printf("  tic mesuré : %.5f ns (retenu %.5f ns, écart %+.3f %%)\n", tic_mesure * 1e9, tic * 1e9,
                        (tic_mesure / tic - 1) * 100)
                ok &= abs(tic_mesure / tic - 1) < 1e-3
            end
            if length(m0) == length(m3) && !isempty(m0)
                largeurs = (m3 .- m0) .* tic
                moy = sum(largeurs) / length(largeurs)
                @printf("  M3 - M0 : %.6f ms en moyenne, de %.6f à %.6f ms (attendu %.3f ms)\n",
                        moy * 1e3, minimum(largeurs) * 1e3, maximum(largeurs) * 1e3, r.largeur_s * 1e3)
                ok &= abs(moy / r.largeur_s - 1) < 1e-3 && all(>(0), largeurs)
            end
        end

        # Déclins par entrée
        if dec.photons == 0
            println("\nÉCHEC : aucun photon. Détecteurs allumés dans le logiciel DCC ? Seuils et entrées ",
                    "actives dans reglages_qc.jl ? CNTE (broche 14) laissée libre ?")
            return false
        end
        nmicro = size(dec.micro, 1)
        t_canal = [(j - 0.5) * dt_ns for j in 1:nmicro]
        open(joinpath(dossier, "q5_declins.csv"), "w") do io
            println(io, "canal,temps_ns,in1,in2,in3")
            for j in 1:nmicro
                @printf(io, "%d,%.5f,%d,%d,%d\n", j - 1, t_canal[j], dec.micro[j, 1], dec.micro[j, 2], dec.micro[j, 3])
            end
        end
        g = 16
        regroupe(c) = [sum(view(c, g * (k - 1) + 1:g * k)) for k in 1:nmicro ÷ g]
        t_r = [(g * (k - 1) + g / 2) * dt_ns for k in 1:nmicro ÷ g]
        actives = [i for i in 1:3 if dec.par_voie[i] > 0]
        svg = svg_declins_qc5(joinpath(dossier, "q5_declins.svg"), t_r,
                              [regroupe(view(dec.micro, :, i)) for i in actives],
                              ["IN$i ($(dec.par_voie[i]))" for i in actives],
                              "Déclins mesurés par la SPC-QC-104 ($(dec.photons) photons)")
        println("\nDéclins : ", svg, " ; canal de ", @sprintf("%.2f ps", dt_ns * 1e3))
        for i in actives
            h = view(dec.micro, :, i)
            pic = argmax(h)
            moyen = sum(h .* t_canal) / sum(h)
            @printf("  IN%d : pic à %.3f ns, temps moyen %.3f ns\n", i, t_canal[pic], moyen)
        end
        for i in (1, 2)
            dec.par_voie[i] == 0 && (println("  IN$i : aucun photon (détecteur, câble, seuil ?)"); ok = false)
        end

        # Routage
        if r.ni_present
            dominant = argmax(dec.routage) - 1
            part = dec.routage[dominant + 1] / dec.photons
            @printf("\nRoutage : code écrit %s, valeur la plus fréquente %s pour %.1f %% des photons\n",
                    string(code; base = 2, pad = 4), string(dominant; base = 2, pad = 4), 100 * part)
            if dominant == (~code & 0x0f) && part > 0.99
                println("  ok : le routage lu est le complément du code (entrées actives à l'état bas), comme sur les SPC-150N.")
            elseif dominant == code && part > 0.99
                println("  ok, SANS inversion : le routage lu égale le code écrit. Note-le pour ton GUI.")
            else
                println("  INATTENDU : vérifie l'ordre des fils (/R0 = broche 2, /R1 = 3, /R2 = 4, /R3 = 7).")
                ok = false
            end
        end

        # Contrôle par la DLL sur les mêmes données
        spc = ecrire_spc(joinpath(dossier, "q5_photons.spc"), f.entete, brut)
        ent, _ = photons_dll(spc; type_fifo = f.type_fifo, type_flux = type_flux_fichier(f.type_flux),
                             quoi = 0x3f, max = 50_000_000)
        n_dll = count(e -> !est_marqueur(e) && (e.drapeaux & DRAPEAU_INVALIDE) == 0, ent)
        nm_dll = [count(e -> (e.drapeaux & DRAPEAUX_MARQUEURS[k]) != 0, ent) for k in 1:4]
        nm = length.(dec.marqueurs)
        accord = n_dll == dec.photons && nm_dll == nm
        @printf("\nDLL : %d photons, marqueurs %s ; SPCLite : %d photons, marqueurs %s  %s\n",
                n_dll, string(nm_dll), dec.photons, string(nm), accord ? "identiques" : "DIFFÉRENTS")
        ok &= accord

        println()
        println(ok ? "RÉUSSI : photons, déclins, marqueurs et routage conformes. Ouvre q5_declins.svg." :
                     "ÉCHEC partiel : voir les lignes ci-dessus ; colle la sortie dans la conversation.")
        return ok
    end
end

test_qc5(qc5, REGLAGES_QC, FORMAT_QC104)
