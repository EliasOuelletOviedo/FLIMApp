# test_spc5_photons.jl — vrais photons : taux, déclin, routage, CNTE.
#
# Il faut : le laser (SYNC branché), le détecteur (CFD branché), un
# échantillon fluorescent, et les réglages de reglages_spc.jl.
# Branchements NI facultatifs (tableau « Branchements » du plan) :
#   P0.4, P0.5, P0.6, P0.7 → broches 2, 3, 4, 7 (/R0 à /R3) : test du routage
#   P0.0                   → broche 14 (CNTE)              : test de CNTE
#   D GND                  → broche 15
# SPCM fermé. Commence avec le détecteur à faible gain et peu de lumière.
#
# Déroulé : SYNC et taux, puis une ou deux acquisitions FIFO de duree_s,
# avec le code de région écrit en continu sur P0.4 à P0.7.
#
# Réussi si : SYNC correct, des photons, un déclin propre dans
# resultats/spc/t5_declin.svg, et, si les fils de routage sont branchés,
# routage lu = NON(code écrit) pour plus de 99 % des photons.

isdefined(Main, :DAQmxLite) || include("DAQmxLite.jl")
using .DAQmxLite
isdefined(Main, :SPCLite) || include("SPCLite.jl")
using .SPCLite
using Printf
include("reglages_spc.jl")

spc5 = (module_no = 0, duree_s = 1.0, ni_present = true, carte = "X6321",
        code_region = 5,        # écrit sur P0.4 à P0.7 pendant la mesure (0 à 15)
        tester_cnte = false)    # true : une mesure avec P0.0 à 0 V, puis une à 5 V

"""Une acquisition FIFO de `duree_s` secondes, décodée au fil de l'eau."""
function acquerir_spc5(m, duree_s)
    dec = Decodeur()
    tampon = zeros(UInt16, 1 << 20)
    deborde = false
    demarrer(m)
    t0 = time()
    while time() - t0 < duree_s
        decoder!(dec, tampon, lire_fifo!(m, tampon))
        (etat_mesure(m) & SPC_FOVFL) != 0 && (deborde = true)
        sleep(0.01)
    end
    decoder!(dec, tampon, lire_fifo!(m, tampon))   # avant l'arrêt, qui vide le FIFO
    arreter(m)
    return dec, deborde
end

"""Déclin en SVG, axe vertical logarithmique, sans aucune dépendance."""
function svg_declin_spc5(chemin, t_ns, coups, titre)
    L, H = 760, 440
    g, d, h, b = 80, 24, 48, 56
    lx, ly = L - g - d, H - h - b
    xmax = maximum(t_ns)
    ymax = max(1.0, ceil(log10(maximum(coups) + 1)))
    X(t) = g + lx * t / xmax
    Y(c) = h + ly * (1 - log10(c + 1) / ymax)
    pas = xmax / 8
    for p in (0.1, 0.2, 0.5, 1, 2, 5, 10, 20, 50, 100, 200, 500, 1000)
        xmax / p <= 8 && (pas = p; break)
    end
    pts = join((@sprintf("%.1f,%.1f", X(t), Y(c)) for (t, c) in zip(t_ns, coups)), " ")
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
        println(io, """<polyline fill="none" stroke="#1d4ed8" stroke-width="1.2" points="$pts"/>""")
        println(io, "</svg>")
    end
    return chemin
end

function test_spc5(r, reglages)
    dossier = joinpath(@__DIR__, "resultats", "spc")
    p = merge(reglages, Dict{String,Any}(
        "mode" => 1, "adc_resolution" => 12, "stop_on_time" => 0,
        "routing_mode" => 0xff00, "macro_time_clk" => 0, "rate_count_time" => 0.25))
    ini = ecrire_ini(joinpath(dossier, "t5_photons.ini"), p)

    avec_spc(ini; module_no = r.module_no) do m
        lu = lire_parametres(m; fichier = joinpath(dossier, "t5_relu.ini"))
        fenetre_ns = get(lu, "tac_range", Float64(reglages["tac_range"])) /
                     get(lu, "tac_gain", Float64(reglages["tac_gain"]))
        dt_ns = fenetre_ns / 4096
        @printf("Fenêtre TAC : %.3f ns, soit %.2f ps par canal (4096 canaux)\n", fenetre_ns, dt_ns * 1e3)

        s = sync_etat(m)
        println("SYNC : ", get(MESSAGES_SYNC, s, string(s)))
        if s != 1
            println("ÉCHEC : il faut un SYNC correct. Vérifie le câble du laser et ",
                    "sync_threshold dans reglages_spc.jl (reprends la valeur de SPCM).")
            return false
        end
        effacer_taux(m)
        sleep(0.4)
        v = taux(m)
        v.code == 0 && @printf("Taux : SYNC %.4g /s, CFD %.4g /s, TAC %.4g /s, ADC %.4g /s\n",
                               v.sync, v.cfd, v.tac, v.adc)

        niveaux = r.tester_cnte ? (0, 1) : (nothing,)
        function mesures(ecrire_lignes)
            res = []
            for niveau in niveaux
                ecrire_lignes(niveau)
                sleep(0.05)
                dec, deborde = acquerir_spc5(m, r.duree_s)
                push!(res, (niveau = niveau, dec = dec, deborde = deborde))
            end
            return res
        end

        code = UInt8(r.code_region) & 0x0f
        bits_code = UInt8[(code >> k) & 0x01 for k in 0:3]
        res = if r.ni_present
            lignes = r.tester_cnte ? "$(r.carte)/port0/line0,$(r.carte)/port0/line4:7" :
                                     "$(r.carte)/port0/line4:7"
            withtask("lignes_spc5") do th
                add_do(th, lignes)
                mesures() do niveau
                    write_do(th, niveau === nothing ? bits_code : vcat(UInt8(niveau), bits_code))
                end
            end
        else
            mesures(niveau -> nothing)
        end

        println()
        for x in res
            d = x.dec
            nom = x.niveau === nothing ? "Acquisition" : "P0.0 à $(x.niveau == 0 ? "0 V" : "5 V")"
            @printf("%s : %d photons en %.1f s (%.4g /s) ; rejetés %d ; pertes %d%s\n",
                    nom, d.photons, r.duree_s, d.photons / r.duree_s, d.rejetes, d.pertes,
                    x.deborde ? " ; FIFO DÉBORDÉ (baisse la lumière)" : "")
        end

        adc = sum(x.dec.adc for x in res)
        total = sum(adc)
        if total == 0
            println("\nÉCHEC : aucun photon. Vérifie le câble du détecteur, sa haute tension, ",
                    "cfd_limit_low et la fenêtre tac_limit_low/high dans reglages_spc.jl.")
            return false
        end

        # Microtemps croissant = 4095 - ADC (start-stop inversé).
        micro = reverse(adc)
        t_canal = [(j - 0.5) * dt_ns for j in 1:4096]
        moyen = sum(micro .* t_canal) / total
        @printf("\nTemps moyen d'arrivée dans la fenêtre : %.3f ns (non corrigé de la réponse instrumentale)\n", moyen)

        open(joinpath(dossier, "t5_declin.csv"), "w") do io
            println(io, "canal,temps_ns,coups")
            for j in 1:4096
                @printf(io, "%d,%.5f,%d\n", j - 1, t_canal[j], micro[j])
            end
        end
        regroupe = [sum(micro[16(k - 1) + 1:16k]) for k in 1:256]
        t_regroupe = [(16(k - 1) + 8) * dt_ns for k in 1:256]
        svg = svg_declin_spc5(joinpath(dossier, "t5_declin.svg"), t_regroupe, regroupe,
                              "Déclin mesuré par la SPC-150N ($total photons)")
        println("Déclin enregistré : ", svg)

        ok = true
        dernier = res[end].dec
        if r.ni_present && dernier.photons > 0
            attendu = (~code) & 0x0f
            dominant = argmax(dernier.routage) - 1
            part = dernier.routage[dominant + 1] / dernier.photons
            @printf("\nRoutage : code écrit %d (%s), valeur la plus fréquente %d (%s) pour %.1f %% des photons\n",
                    code, string(code; base = 2, pad = 4), dominant,
                    string(dominant; base = 2, pad = 4), 100 * part)
            if dominant == attendu && part > 0.99
                println("  ok : chaque photon porte le code, inversé (entrées actives à l'état bas).")
            elseif dominant == code && part > 0.99
                println("  ok, mais sans inversion : note-le, le décodage de la région en dépend.")
            elseif dominant == 0
                println("  routage toujours 0 : fils P0.4-P0.7 non branchés, ou code écrit = 15.")
                ok = false
            else
                println("  INATTENDU : vérifie l'ordre des fils (/R0 = broche 2, /R1 = 3, /R2 = 4, /R3 = 7).")
                ok = false
            end
        end

        if r.tester_cnte && length(res) == 2
            n0, n1 = res[1].dec.photons, res[2].dec.photons
            println()
            if n1 > 5 * max(n0, 1)
                println("CNTE : comptage autorisé quand P0.0 est à 5 V (actif à l'état haut).")
            elseif n0 > 5 * max(n1, 1)
                println("CNTE : comptage autorisé quand P0.0 est à 0 V (actif à l'état bas).")
            else
                println("CNTE : aucun effet net. Fil de la broche 14 absent, ou entrée ignorée dans ce mode.")
            end
        end

        println()
        println(ok ? "RÉUSSI : photons, déclin et étiquetage reçus. Ouvre t5_declin.svg." :
                     "ÉCHEC partiel : voir les lignes ci-dessus.")
        return ok
    end
end

test_spc5(spc5, REGLAGES_SPC)
