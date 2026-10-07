# qc7_galvo_simule.jl — imite la séquence des galvos : 16 régions, routage et marqueurs,
# puis une image par route et une mosaïque des 16 images.
#
# AUCUN signal n'est envoyé aux galvos : le script ne crée aucune sortie
# analogique. La X6321 joue seulement ce que ton système enverra à la QC-104
# pendant un balayage :
#   - pour chaque région, une passe : M0 au début (front montant de CTR 1 OUT),
#     M3 à la fin (front descendant) ;
#   - entre deux passes, un temps de transit (le déplacement des galvos), marqueurs bas ;
#   - le code de routage de la région suivante, écrit sur P0.4-P0.7 au moment
#     même où la passe se termine (sortie numérique cadencée par le compteur :
#     le routage est stable pendant tout le transit et toute la passe suivante).
# Région k = route k (0 à 15) ; la carte lit le code de la route (la 6321
# écrit son complément : routage actif à l'état bas).
#
# Il faut : les branchements de qc4 et qc5 (CTR 1 OUT / PFI 13 → broches 12 et
# 10 ; P0.4-P0.7 → broches 2, 3, 4, 7 ; D GND → broche 5), le laser sur
# l'échantillon, les détecteurs allumés (logiciel DCC), reglages_qc.jl,
# format_fifo_qc104.jl, SPCLite v12. SPCM fermé.
#
# Les galvos ne bougent pas : chaque image est uniforme (même tache de
# lumière). Ce qui est vérifié, c'est le tri : chaque photon d'une passe doit
# porter la route de sa région, et tomber dans le pixel donné par son temps
# depuis M0. Pour que la mosaïque se lise d'un coup d'œil, la durée de passe
# croît avec la route (2 ms pour la route 0, 9,5 ms pour la route 15) : les
# pixels sont d'autant plus longs, donc plus clairs. Une erreur d'association
# route ↔ région casserait ce dégradé.
#
# Sorties (resultats/qc) : q7_mosaique.svg (intensité et temps moyen d'arrivée,
# par entrée), q7_routes.csv (une ligne par route), q7_images.csv (chaque
# pixel), q7_sequence.spc (données brutes, pour rejouer dans ton GUI).
#
# Réussi si : 16 × cycles passes reçues (M0 et M3), durées mesurées à 0,1 %
# près, plus de 99,9 % des photons de chaque passe sur la bonne route, même
# taux de photons (à 10 % près) pour les 16 routes.

Base.exit_on_sigint(false)
isdefined(Main, :DAQmxLite) || include("DAQmxLite.jl")
using .DAQmxLite
isdefined(Main, :SPCLite) || include("SPCLite.jl")
using .SPCLite
(isdefined(SPCLite, :VERSION_LITE) && SPCLite.VERSION_LITE >= 12) ||
    error("Julia a gardé une ancienne version de SPCLite.jl (il faut la v12) : redémarre Julia, puis relance ce script.")
using Printf
include("reglages_qc.jl")
isfile(joinpath(@__DIR__, "format_fifo_qc104.jl")) ||
    error("format_fifo_qc104.jl absent : lance d'abord qc4_format_fifo.jl.")
include("format_fifo_qc104.jl")

q7 = (carte = "X6321", compteur = "ctr1", sortie = "PFI13", lignes_routage = "port0/line4:7",
      routing_mode = 0x1900,                    # M0 front montant, M3 front descendant
      ordre = collect(0:15),                    # routes visitées dans un cycle, dans l'ordre
      duree_ms = [2.0 + 0.5 * k for k in 0:15], # durée de passe de chaque route (indice = route + 1)
      transit_ms = 0.5,                         # déplacement simulé entre deux régions
      cycles = 40,                              # répétitions de la séquence (≈ 4 s)
      retard_initial_ms = 5.0,
      nx = 16, ny = 16,                         # pixels de chaque image
      bidirectionnel = false,                   # true : lignes impaires parcourues à l'envers
      taille_pixel = 12,                        # taille d'un pixel dans le SVG
      plage_temps_ns = 1.0,                     # échelle du temps moyen : moyenne de l'entrée ± cette valeur
      numero_serie = "")

# Constantes NI-DAQmx (NIDAQmx.h)
const Q7_SECONDES = Int32(10364)
const Q7_BAS = Int32(10214)
const Q7_FINI = Int32(10178)
const Q7_DESCENDANT = Int32(10171)
const Q7_TOUTES_LIGNES = Int32(1)

"""Code à écrire sur P0.4-P0.7 pour que la carte lise `route` (actif à l'état bas)."""
code_ni_q7(route::Integer) = UInt8(~route & 0x0f)
lignes_q7(c::UInt8) = UInt8[(c >> k) & 0x01 for k in 0:3]

"""Route, durée haute (passe) et durée basse (transit) de chaque passe, en s."""
function sequence_q7(r)
    length(r.ordre) == 16 && sort(r.ordre) == collect(0:15) ||
        error("ordre : les 16 routes 0 à 15, chacune une fois")
    length(r.duree_ms) == 16 || error("duree_ms : 16 durées, une par route")
    all(>(0), r.duree_ms) && r.transit_ms > 0 || error("durées et transit : strictement positifs")
    routes = repeat(r.ordre, r.cycles)
    haut = [r.duree_ms[k + 1] * 1e-3 for k in routes]
    bas = fill(r.transit_ms * 1e-3, length(routes))
    return routes, haut, bas
end

"""Route de la première région, écrite avant le départ (lignes statiques)."""
function routage_initial_q7(r, route)
    withtask("q7_routage_initial") do th
        add_do(th, "$(r.carte)/$(r.lignes_routage)")
        write_do(th, lignes_q7(code_ni_q7(route)))
    end
end

"""
Compteur : un train de n impulsions (haute = passe, basse = transit).
Sortie numérique : un échantillon par front descendant du compteur (fin de
passe), qui écrit la route de la passe suivante ; route 0 après la dernière.
"""
function configurer_ni_q7!(r, th_do, th_co, routes, haut, bas)
    n = length(routes)
    voie = "$(r.carte)/$(r.compteur)"
    chk(ccall((:DAQmxCreateCOPulseChanTime, "nicaiu"), Int32,
              (Ptr{Cvoid}, Cstring, Cstring, Int32, Int32, Float64, Float64, Float64),
              th_co, voie, "", Q7_SECONDES, Q7_BAS, r.retard_initial_ms * 1e-3, bas[1], haut[1]))
    chk(ccall((:DAQmxSetCOPulseTerm, "nicaiu"), Int32, (Ptr{Cvoid}, Cstring, Cstring),
              th_co, voie, "/$(r.carte)/$(r.sortie)"))
    cfg_implicit_timing(th_co, Val_FiniteSamps, n)
    ecrits = Ref{Int32}(0)
    chk(ccall((:DAQmxWriteCtrTime, "nicaiu"), Int32,
              (Ptr{Cvoid}, Int32, UInt32, Float64, UInt32, Ptr{Float64}, Ptr{Float64}, Ptr{Int32}, Ptr{UInt32}),
              th_co, Int32(n), UInt32(0), 10.0, UInt32(0), haut, bas, ecrits, C_NULL))
    ecrits[] == n || error("compteur : $(ecrits[]) impulsions écrites sur $n")

    chk(ccall((:DAQmxCreateDOChan, "nicaiu"), Int32, (Ptr{Cvoid}, Cstring, Cstring, Int32),
              th_do, "$(r.carte)/$(r.lignes_routage)", "", Q7_TOUTES_LIGNES))
    horloge = "/$(r.carte)/Ctr$(r.compteur[4:end])InternalOutput"
    chk(ccall((:DAQmxCfgSampClkTiming, "nicaiu"), Int32, (Ptr{Cvoid}, Cstring, Float64, Int32, Int32, UInt64),
              th_do, horloge, 1.0e5, Q7_DESCENDANT, Q7_FINI, UInt64(n)))
    donnees = Vector{UInt8}(undef, 4n)          # une voie de 4 lignes : échantillon après échantillon
    for i in 1:n
        c = code_ni_q7(i < n ? routes[i + 1] : 0)
        for k in 0:3
            donnees[4(i - 1) + k + 1] = (c >> k) & 0x01
        end
    end
    chk(ccall((:DAQmxWriteDigitalLines, "nicaiu"), Int32,
              (Ptr{Cvoid}, Int32, UInt32, Float64, UInt32, Ptr{UInt8}, Ptr{Int32}, Ptr{UInt32}),
              th_do, Int32(n), UInt32(0), 10.0, UInt32(0), donnees, ecrits, C_NULL))
    ecrits[] == n || error("routage : $(ecrits[]) échantillons écrits sur $n")
    return nothing
end

"""
Trie les photons : passe j (M0[j] ≤ t < M3[j]) → région routes[j] ; pixel
donné par (t − M0) / (M3 − M0) ; image choisie par la route LUE dans le photon.
"""
function trier_q7(dec, routes, r, dt_ns)
    m0, m3 = dec.marqueurs[1], dec.marqueurs[4]
    n = length(routes)
    npix = r.nx * r.ny
    coups = [zeros(Int, r.ny, r.nx, 2) for _ in 1:16]
    somme_t = [zeros(Float64, r.ny, r.nx, 2) for _ in 1:16]
    dans = zeros(Int, 16)        # photons pendant les passes de la route k (attendue)
    mauvais = zeros(Int, 16)     # … dont la route lue n'est pas k
    hors = 0                     # photons hors des passes
    hors_ok = 0                  # … lus sur la route attendue (celle de la passe suivante)
    for i in eachindex(dec.t_photons)
        v = Int(dec.voie_photons[i])
        1 <= v <= 2 || continue
        t = dec.t_photons[i]
        lu = Int(dec.routage_photons[i])
        j = searchsortedlast(m0, t)
        if j < 1 || t >= m3[j]
            hors += 1
            attendu_hors = j < 1 ? routes[1] : (j < n ? routes[j + 1] : 0)
            lu == attendu_hors && (hors_ok += 1)
            continue
        end
        attendu = routes[j]
        dans[attendu + 1] += 1
        lu == attendu || (mauvais[attendu + 1] += 1)
        p = min(npix - 1, floor(Int, (t - m0[j]) / (m3[j] - m0[j]) * npix))
        y, x = divrem(p, r.nx)
        r.bidirectionnel && isodd(y) && (x = r.nx - 1 - x)
        coups[lu + 1][y + 1, x + 1, v] += 1
        somme_t[lu + 1][y + 1, x + 1, v] += (Int(dec.micro_photons[i]) + 0.5) * dt_ns
    end
    return (coups = coups, somme_t = somme_t, dans = dans, mauvais = mauvais, hors = hors, hors_ok = hors_ok)
end

# ---------------------------------------------------------------------
# Mosaïque en SVG
# ---------------------------------------------------------------------

const PALETTE_Q7 = ((68, 1, 84), (72, 40, 120), (62, 74, 137), (49, 104, 142), (38, 130, 142),
                    (31, 158, 137), (53, 183, 121), (109, 205, 89), (180, 222, 44), (253, 231, 37))

function couleur_q7(v, lo, hi, palette)
    isnan(v) && return "#d9d9d9"
    f = clamp((v - lo) / (hi - lo), 0.0, 1.0)
    if palette == :gris
        g = round(Int, 255 * f)
        return @sprintf("#%02x%02x%02x", g, g, g)
    end
    x = f * (length(PALETTE_Q7) - 1)
    i = min(floor(Int, x), length(PALETTE_Q7) - 2)
    a = x - i
    c1, c2 = PALETTE_Q7[i + 1], PALETTE_Q7[i + 2]
    return @sprintf("#%02x%02x%02x", round(Int, (1 - a) * c1[1] + a * c2[1]),
                    round(Int, (1 - a) * c1[2] + a * c2[2]), round(Int, (1 - a) * c1[3] + a * c2[3]))
end

"""
Panneaux de 4 × 4 images (route k : ligne k ÷ 4, colonne k % 4), deux
panneaux par rangée. Chaque panneau : titre, 16 images, échelle lo-hi,
palette (:gris ou :viridis), unité, une étiquette par image.
"""
function svg_mosaique_q7(chemin, titre, panneaux, nx, ny, s)
    m, sp, lh, entete, pied = 16, 10, 16, 44, 54
    tw, th_ = nx * s, ny * s
    pw = 2m + 4tw + 3sp
    ph = entete + 4 * (lh + th_ + sp) + pied
    ncol = min(2, length(panneaux))
    L, H = ncol * pw, 36 + cld(length(panneaux), 2) * ph
    open(chemin, "w") do io
        println(io, """<svg xmlns="http://www.w3.org/2000/svg" width="$L" height="$H" font-family="sans-serif" font-size="11" shape-rendering="crispEdges">""")
        println(io, """<rect width="$L" height="$H" fill="white"/>""")
        println(io, """<text x="$m" y="24" font-size="16">$titre</text>""")
        for (q, pan) in enumerate(panneaux)
            ox = ((q - 1) % 2) * pw
            oy = 36 + ((q - 1) ÷ 2) * ph
            println(io, """<text x="$(ox + m)" y="$(oy + 28)" font-size="14">$(pan.titre)</text>""")
            for k in 0:15
                a, b = divrem(k, 4)
                x0 = ox + m + b * (tw + sp)
                y0 = oy + entete + a * (lh + th_ + sp) + lh
                println(io, """<text x="$x0" y="$(y0 - 4)">$(pan.etiquettes[k + 1])</text>""")
                img = pan.images[k + 1]
                for yy in 1:ny, xx in 1:nx
                    @printf(io, "<rect x=\"%d\" y=\"%d\" width=\"%d\" height=\"%d\" fill=\"%s\"/>\n",
                            x0 + (xx - 1) * s, y0 + (yy - 1) * s, s, s,
                            couleur_q7(img[yy, xx], pan.lo, pan.hi, pan.palette))
                end
                @printf(io, "<rect x=\"%d\" y=\"%d\" width=\"%d\" height=\"%d\" fill=\"none\" stroke=\"#888\"/>\n",
                        x0, y0, tw, th_)
            end
            yb = oy + entete + 4 * (lh + th_ + sp) + 6
            largeur = 4tw + 3sp
            nb = 64
            for i in 0:nb - 1
                v = pan.lo + (pan.hi - pan.lo) * (i + 0.5) / nb
                @printf(io, "<rect x=\"%.2f\" y=\"%d\" width=\"%.2f\" height=\"12\" fill=\"%s\"/>\n",
                        ox + m + i * largeur / nb, yb, largeur / nb + 0.5, couleur_q7(v, pan.lo, pan.hi, pan.palette))
            end
            @printf(io, "<text x=\"%d\" y=\"%d\">%.3g %s</text>\n", ox + m, yb + 26, pan.lo, pan.unite)
            @printf(io, "<text x=\"%d\" y=\"%d\" text-anchor=\"end\">%.3g %s</text>\n",
                    ox + m + largeur, yb + 26, pan.hi, pan.unite)
        end
        println(io, "</svg>")
    end
    return chemin
end

# ---------------------------------------------------------------------
# Programme
# ---------------------------------------------------------------------

function test_q7(r, reglages, format)
    dossier = joinpath(@__DIR__, "resultats", "qc")
    mkpath(dossier)
    routes, haut, bas = sequence_q7(r)
    n = length(routes)
    duree_seq = r.retard_initial_ms * 1e-3 + sum(haut) + sum(bas)
    @printf("Séquence : %d cycles de 16 régions = %d passes, %.2f s ; ordre des routes : %s\n",
            r.cycles, n, duree_seq, join(r.ordre, " "))
    @printf("  passes de %.1f à %.1f ms, transit de %.2f ms ; images de %d × %d pixels\n",
            minimum(r.duree_ms), maximum(r.duree_ms), r.transit_ms, r.nx, r.ny)
    p = merge(parametres_qc(reglages), Dict{String,Any}(
        "mode" => 1, "adc_resolution" => 12, "stop_on_time" => 0, "collect_time" => 1.0,
        "macro_time_clk" => 0, "trigger" => 0, "routing_mode" => Int(r.routing_mode)))
    ini = ecrire_ini(joinpath(dossier, "q7_galvo.ini"), p)
    println("Format : ", format.nom)

    routage_initial_q7(r, routes[1])

    avec_spc_tous(ini; types = (TYPE_QC104,)) do modules
        m = modules[1]
        if !isempty(r.numero_serie)
            i = findfirst(k -> (try eeprom(k).serie catch; "" end) == r.numero_serie, modules)
            i === nothing && error("aucune QC-104 de n° de série $(r.numero_serie)")
            m = modules[i]
        end
        lu = lire_parametres(m; fichier = joinpath(dossier, "q7_relu.ini"))
        dt_ns = largeur_canal_s(TYPE_QC104, lu) * 1e9
        f = fifo_init(m)
        tic = tic_macro_s(m)
        s = sync_etat(m)
        println("SYNC : ", get(MESSAGES_SYNC, s, string(s)))
        s == 1 || (println("ÉCHEC : il faut un SYNC correct."); return false)

        dec = DecodeurFIFO(format; garder_photons = true)
        tampon = zeros(UInt16, 1 << 21)
        brut = UInt16[]
        deborde = false
        function lire()
            k = lire_fifo!(m, tampon)
            decoder!(dec, tampon, k)
            append!(brut, view(tampon, 1:k))
            (etat_mesure(m) & SPC_FOVFL) != 0 && (deborde = true)
            return k
        end

        withtasks("q7_routage", "q7_marqueurs") do th_do, th_co
            configurer_ni_q7!(r, th_do, th_co, routes, haut, bas)
            start_task(th_do)                     # attend les fronts du compteur
            demarrer(m)
            sleep(0.05)
            start_task(th_co)
            fin = time() + duree_seq + 0.3
            while time() < fin
                lire()
                sleep(0.01)
            end
            for th in (th_co, th_do)
                chk(ccall((:DAQmxWaitUntilTaskDone, "nicaiu"), Int32, (Ptr{Cvoid}, Float64), th, 5.0))
            end
            lire()                                # avant l'arrêt, qui vide le FIFO
            arreter(m)
        end
        isodd(length(brut)) && pop!(brut)
        spc = ecrire_spc(joinpath(dossier, "q7_sequence.spc"), f.entete, brut)

        println()
        @printf("Photons : %d (IN1 %d, IN2 %d) ; inattendus %d%s\n", dec.photons, dec.par_voie[1],
                dec.par_voie[2], dec.inattendus, deborde ? " ; FIFO DÉBORDÉ (baisse la lumière)" : "")
        m0, m3 = dec.marqueurs[1], dec.marqueurs[4]
        @printf("Marqueurs : M0 %d, M3 %d (attendu %d de chaque)\n", length(m0), length(m3), n)
        ok = !deborde && dec.inattendus == 0
        if length(m0) != n || length(m3) != n
            println("ÉCHEC : il manque des passes ; la séquence ne peut pas être associée aux marqueurs.")
            return false
        end
        if !all(j -> m3[j] > m0[j] && (j == n || m0[j + 1] > m3[j]), 1:n)
            println("ÉCHEC : M0 et M3 ne s'alternent pas (routing_mode, câblage des broches 12 et 10 ?).")
            return false
        end

        # Durées des passes et du transit
        duree_mes = (m3 .- m0) .* tic
        ecart_duree = maximum(abs.(duree_mes .- haut) ./ haut)
        transit = sum(m0[j + 1] - m3[j] for j in 1:n - 1) * tic / (n - 1)
        @printf("  passes : écart max à la durée programmée %.4f %% ; transit moyen %.4f ms (programmé %.3f ms)\n",
                100 * ecart_duree, 1e3 * transit, r.transit_ms)
        ok &= ecart_duree < 1e-3 + 3 * tic / minimum(haut)

        # Tri des photons
        t = trier_q7(dec, routes, r, dt_ns)
        duree_route = zeros(16)
        for j in 1:n
            duree_route[routes[j] + 1] += duree_mes[j]
        end
        taux = t.dans ./ duree_route
        taux_moyen = sum(t.dans) / sum(duree_route)
        ecart_taux = maximum(abs.(taux .- taux_moyen)) / taux_moyen
        bonne = 1 - sum(t.mauvais) / max(1, sum(t.dans))
        moyenne_t(k, v) = (c = sum(t.coups[k][:, :, v]); c == 0 ? NaN : sum(t.somme_t[k][:, :, v]) / c)

        println("\n route  rang  passe (ms)  mesurée (ms)  photons IN1  photons IN2  photons/ms  t moyen IN1  t moyen IN2  mauvaise route")
        for k in 1:16
            @printf("  %4d  %4d  %10.2f  %12.4f  %11d  %11d  %10.1f  %8.3f ns  %8.3f ns  %14d\n",
                    k - 1, findfirst(==(k - 1), r.ordre), r.duree_ms[k], 1e3 * duree_route[k] / r.cycles,
                    sum(t.coups[k][:, :, 1]), sum(t.coups[k][:, :, 2]), taux[k] / 1e3,
                    moyenne_t(k, 1), moyenne_t(k, 2), t.mauvais[k])
        end
        println()
        @printf("Routage dans les passes : %.4f %% des photons sur la route de leur région (%d sur %d)\n",
                100 * bonne, sum(t.dans) - sum(t.mauvais), sum(t.dans))
        @printf("Hors des passes (transit) : %d photons, dont %.2f %% déjà sur la route de la région suivante\n",
                t.hors, 100 * t.hors_ok / max(1, t.hors))
        @printf("Taux pendant les passes : %.1f photons/ms en moyenne, écart max d'une route %.2f %%\n",
                taux_moyen / 1e3, 100 * ecart_taux)
        ok &= bonne >= 0.999 && all(>(0), t.dans) && ecart_taux < 0.10

        # Images et mosaïque
        entrees = [v for v in 1:2 if dec.par_voie[v] > 0]
        panneaux = Any[]
        for v in entrees
            imgs = [Float64.(t.coups[k][:, :, v]) for k in 1:16]
            hi = maximum(maximum.(imgs))
            push!(panneaux, (titre = "IN$v : photons par pixel", images = imgs, lo = 0.0, hi = max(hi, 1.0),
                             palette = :gris, unite = "ph",
                             etiquettes = [@sprintf("route %d · %.1f ms · %d ph", k - 1, r.duree_ms[k],
                                                    sum(t.coups[k][:, :, v])) for k in 1:16]))
            tm = [[t.coups[k][y, x, v] >= 3 ? t.somme_t[k][y, x, v] / t.coups[k][y, x, v] : NaN
                   for y in 1:r.ny, x in 1:r.nx] for k in 1:16]
            c_v = sum(sum(t.coups[k][:, :, v]) for k in 1:16)
            t_v = sum(sum(t.somme_t[k][:, :, v]) for k in 1:16) / max(c_v, 1)
            lo, hi2 = t_v - r.plage_temps_ns, t_v + r.plage_temps_ns
            push!(panneaux, (titre = @sprintf("IN%d : temps moyen d'arrivée par pixel (%.2f ± %.1f ns)", v, t_v, r.plage_temps_ns),
                             images = tm, lo = lo, hi = hi2,
                             palette = :viridis, unite = "ns",
                             etiquettes = [@sprintf("route %d · %.3f ns", k - 1, moyenne_t(k, v)) for k in 1:16]))
        end
        svg = svg_mosaique_q7(joinpath(dossier, "q7_mosaique.svg"),
                              "Galvos simulés : 16 routes × $(r.cycles) cycles, $(dec.photons) photons",
                              panneaux, r.nx, r.ny, r.taille_pixel)

        open(joinpath(dossier, "q7_routes.csv"), "w") do io
            println(io, "route,rang,passe_ms,mesuree_ms,photons_in1,photons_in2,photons_par_ms,t_moyen_in1_ns,t_moyen_in2_ns,mauvaise_route")
            for k in 1:16
                @printf(io, "%d,%d,%.3f,%.5f,%d,%d,%.3f,%.4f,%.4f,%d\n", k - 1, findfirst(==(k - 1), r.ordre),
                        r.duree_ms[k], 1e3 * duree_route[k] / r.cycles, sum(t.coups[k][:, :, 1]),
                        sum(t.coups[k][:, :, 2]), taux[k] / 1e3, moyenne_t(k, 1), moyenne_t(k, 2), t.mauvais[k])
            end
        end
        open(joinpath(dossier, "q7_images.csv"), "w") do io
            println(io, "route,entree,y,x,coups,temps_moyen_ns")
            for k in 1:16, v in 1:2, y in 1:r.ny, x in 1:r.nx
                c = t.coups[k][y, x, v]
                @printf(io, "%d,%d,%d,%d,%d,%s\n", k - 1, v, y - 1, x - 1, c,
                        c == 0 ? "" : @sprintf("%.4f", t.somme_t[k][y, x, v] / c))
            end
        end
        if !isempty(entrees)
            v = entrees[1]
            par_pixel = [sum(t.coups[k][:, :, v]) / (r.nx * r.ny) for k in 1:16]
            @printf("IN%d : %.1f à %.1f photons par pixel selon la route\n", v, minimum(par_pixel), maximum(par_pixel))
        end
        println("Mosaïque : ", svg)
        println("Tableaux : q7_routes.csv, q7_images.csv ; données brutes : ", spc)
        println()
        println(ok ? "RÉUSSI : séquence, marqueurs, routage et tri des photons conformes. Ouvre q7_mosaique.svg." :
                     "ÉCHEC partiel : voir les lignes ci-dessus ; colle la sortie dans la conversation.")
        return ok
    end
end

test_q7(q7, REGLAGES_QC, FORMAT_QC104)
