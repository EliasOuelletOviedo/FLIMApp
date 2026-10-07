# qc8_image.jl — test d'imagerie : 100 images sommées, mosaïque IN1 / IN2 en
# intensité et en premier moment (temps de vie approché).
#
# Il faut : ton microscope en train de balayer, avec ses horloges de ligne et
# de trame branchées sur deux entrées marqueurs de la QC-104 (M1, broche 9, et
# M2, broche 8, a priori : le script trouve lui-même lesquelles battent), le
# laser sur l'échantillon, les détecteurs allumés (logiciel DCC),
# reglages_qc.jl, format_fifo_qc104.jl, SPCLite v12. SPCM fermé. La 6321 ne
# sert pas : rien n'est envoyé.
#
# Pas d'horloge pixel : un pixel = temps_pixel_ns après l'horloge de ligne
# (52 ns par défaut), à partir de retard_ligne_ns ; pixels_par_ligne pixels
# par ligne ; une ligne par horloge de ligne, comptée depuis l'horloge de trame.
#
# Déroulé : acquisition FIFO jusqu'à 100 images complètes (≈ 6 s à 16 Hz),
# puis tri des photons : image k = entre la trame k et la trame k + 1, somme
# des 100 images. Premier moment par pixel : moyenne de t − t0, t0 = mi-hauteur
# de la montée du déclin global de l'entrée (ou t0_ns si tu connais l'IRF),
# dans une fenêtre d'une période du laser qui commence marge_ns avant t0 (les
# photons un peu en avance sur t0, à cause de la largeur de l'IRF, restent
# près de 0 au lieu de passer en fin de période). Cette moyenne brute sous-
# estime les temps de vie longs, car la queue du déclin déborde sur la
# période suivante : la valeur corrigée de ce repliement (déclin mono-
# exponentiel, impulsions répétées) est donnée pour chaque entrée, sur
# l'ensemble de ses photons. Les images montrent la moyenne brute.
#
# Contrôle en passant : les bits de M1 et M2 du format (supposés jusqu'ici)
# sont comparés à la DLL sur le début de l'acquisition.
#
# Sorties (resultats/qc) : q8_mosaique.svg (les 4 images avec titres et
# échelles), q8_in1_photons.png, q8_in1_premier_moment.png (et IN2),
# q8_in1_photons.csv, q8_in1_premier_moment_ns.csv (et IN2 ; une ligne
# d'image par ligne de fichier), q8_declins.csv (déclins globaux).

Base.exit_on_sigint(false)
isdefined(Main, :SPCLite) || include("SPCLite.jl")
using .SPCLite
(isdefined(SPCLite, :VERSION_LITE) && SPCLite.VERSION_LITE >= 12) ||
    error("Julia a gardé une ancienne version de SPCLite.jl (il faut la v12) : redémarre Julia, puis relance ce script.")
using Printf, Base64
include("reglages_qc.jl")
isfile(joinpath(@__DIR__, "format_fifo_qc104.jl")) ||
    error("format_fifo_qc104.jl absent : lance d'abord qc4_format_fifo.jl.")
include("format_fifo_qc104.jl")

q8 = (images = 100,
      pixels_par_ligne = 512,
      temps_pixel_ns = 52.0,          # durée d'un pixel (horloge interne du balayage)
      retard_ligne_ns = 0.0,          # début du premier pixel après l'horloge de ligne
      lignes_par_image = 0,           # 0 : nombre de lignes compté entre deux trames
      marqueur_ligne = -1,            # -1 : détection automatique ; sinon 0 à 3 (M0 à M3)
      marqueur_trame = -1,
      fronts_montants = (true, true, true, true),   # front actif de M0 à M3
      t0_ns = (NaN, NaN),             # temps zéro de IN1, IN2 ; NaN : mi-hauteur de la montée
      marge_ns = 1.0,                 # la fenêtre du premier moment commence à t0 − marge_ns
      plage_tau_ns = (NaN, NaN),      # échelle des images de premier moment (min, max) ; NaN : automatique
      min_photons = 10,               # moins de photons dans un pixel : pas de premier moment (gris)
      taille_affichage = 480,         # largeur de chaque image dans la mosaïque, en pixels d'écran
      delai_max_s = 60.0,
      numero_serie = "")

# ---------------------------------------------------------------------
# Horloges, temps zéro, tri des photons
# ---------------------------------------------------------------------

"""
Marqueurs de ligne et de trame d'après leur fréquence, parmi ceux qui ont
battu au moins 3 fois : la ligne est le plus rapide, la trame le plus lent des
autres, au moins 8 fois plus lent que la ligne. Rend (ligne, trame) en 0 à 3,
ou `nothing`.
"""
function detecter_horloges_q8(dec, duree_s, r)
    freq = [length(dec.marqueurs[k]) / duree_s for k in 1:4]
    actifs = [k - 1 for k in 1:4 if length(dec.marqueurs[k]) >= 3]
    ligne = r.marqueur_ligne >= 0 ? r.marqueur_ligne :
            (isempty(actifs) ? nothing : actifs[argmax([freq[k + 1] for k in actifs])])
    trame = r.marqueur_trame >= 0 ? r.marqueur_trame : begin
        c = [k for k in actifs if k != ligne && (ligne === nothing || freq[k + 1] * 8 <= freq[ligne + 1])]
        isempty(c) ? nothing : c[argmin([freq[k + 1] for k in c])]
    end
    return ligne, trame, freq
end

"""Temps zéro (ns) : mi-hauteur de la montée du déclin global, fond retiré."""
function t0_montee_q8(h::AbstractVector{<:Integer}, dt_ns, periode_ns; g = 8)
    ncan = min(length(h), floor(Int, periode_ns / dt_ns))
    ng = ncan ÷ g
    ng < 8 && return NaN
    c = [Float64(sum(view(h, g * (k - 1) + 1:g * k))) for k in 1:ng]
    fond = sort(c)[max(1, ng ÷ 10)]
    p = argmax(c)
    c[p] - fond < 20 && return NaN
    seuil = fond + 0.5 * (c[p] - fond)
    k = p
    while k > 1 && c[k - 1] >= seuil
        k -= 1
    end
    k == 1 && return (g / 2) * dt_ns      # montée coupée par le début de la fenêtre
    f = (seuil - c[k - 1]) / (c[k] - c[k - 1])   # interpolation entre les centres des groupes k-1 et k
    return ((k - 1.5) + f) * g * dt_ns
end

"""
Tri d'un paquet de photons dans les images. N[y, x, v] photons, S[y, x, v]
somme des (t − t0) modulo la période. Rend le nombre de photons placés et
hors fenêtre de pixels (dans une image) ; remplit l'histogramme de position
dans la ligne.
"""
function trier_q8!(N, S, prof_ligne, dec, mL, mF, premier, g)
    places = 0; hors = 0
    for i in eachindex(dec.t_photons)
        v = Int(dec.voie_photons[i])
        1 <= v <= 2 || continue
        t = dec.t_photons[i]
        f = searchsortedlast(mF, t)
        (1 <= f <= g.images) || continue
        iL = searchsortedlast(mL, t)
        y = iL - premier[f]
        (0 <= y < g.ny && iL >= 1) || continue
        dl_ns = (t - mL[iL]) * g.tic_ns
        b = floor(Int, dl_ns / g.pas_prof_ns) + 1
        1 <= b <= length(prof_ligne) && (prof_ligne[b] += 1)
        x = floor(Int, (dl_ns - g.retard_ns) / g.dwell_ns)
        if 0 <= x < g.nx
            tm = (Int(dec.micro_photons[i]) + 0.5) * g.dt_ns - g.t0[v]
            tm = mod(tm + g.marge_ns, g.periode_ns) - g.marge_ns
            N[y + 1, x + 1, v] += 1
            S[y + 1, x + 1, v] += tm
            places += 1
        else
            hors += 1
        end
    end
    return places, hors
end

"""
Premier moment attendu d'un déclin mono-exponentiel de temps de vie τ excité
toutes les T ns, mesuré dans une fenêtre [−m, T − m) autour de t0 :
τ − T·exp(−(T − m)/τ) / (1 − exp(−T/τ)).
"""
moment_periodique_q8(tau, T, m) = tau - T * exp(-(T - m) / tau) / (1 - exp(-T / tau))

"""Temps de vie τ dont le premier moment attendu vaut m1 (bissection) ; NaN hors domaine."""
function tau_premier_moment_q8(m1, T, m)
    lo, hi = 0.01, 100.0
    (isnan(m1) || m1 <= moment_periodique_q8(lo, T, m) || m1 >= moment_periodique_q8(hi, T, m)) && return NaN
    for _ in 1:60
        mid = (lo + hi) / 2
        moment_periodique_q8(mid, T, m) < m1 ? (lo = mid) : (hi = mid)
    end
    return (lo + hi) / 2
end

# ---------------------------------------------------------------------
# PNG (sans bibliothèque : blocs deflate non compressés) et mosaïque SVG
# ---------------------------------------------------------------------

function table_crc_q8()
    t = zeros(UInt32, 256)
    for n in 0:255
        c = UInt32(n)
        for _ in 1:8
            c = (c & 0x00000001) != 0 ? (0xedb88320 ⊻ (c >> 1)) : (c >> 1)
        end
        t[n + 1] = c
    end
    return t
end

function crc32_q8(data::AbstractVector{UInt8}, table)
    c = 0xffffffff
    for b in data
        c = table[Int((c ⊻ b) & 0x000000ff) + 1] ⊻ (c >> 8)
    end
    return c ⊻ 0xffffffff
end

function adler32_q8(data::AbstractVector{UInt8})
    a, b = UInt32(1), UInt32(0)
    for x in data
        a = (a + x) % UInt32(65521)
        b = (b + a) % UInt32(65521)
    end
    return (b << 16) | a
end

octets_be_q8(x::UInt32) = UInt8[(x >> 24) & 0xff, (x >> 16) & 0xff, (x >> 8) & 0xff, x & 0xff]

function morceau_png_q8(io, type::String, data::Vector{UInt8}, table)
    write(io, octets_be_q8(UInt32(length(data))))
    td = vcat(Vector{UInt8}(codeunits(type)), data)
    write(io, td)
    write(io, octets_be_q8(crc32_q8(td, table)))
end

"""PNG RGB 8 bits de l'image `rgb` (3 × largeur × hauteur) ; rend les octets."""
function png_q8(chemin, rgb::Array{UInt8,3})
    _, w, h = size(rgb)
    brut = Vector{UInt8}(undef, h * (1 + 3w))
    k = 1
    for y in 1:h
        brut[k] = 0x00; k += 1                 # filtre « aucun »
        for x in 1:w, c in 1:3
            brut[k] = rgb[c, x, y]; k += 1
        end
    end
    z = UInt8[0x78, 0x01]
    i = 1
    n = length(brut)
    while i <= n
        m = min(65535, n - i + 1)
        push!(z, i + m - 1 == n ? 0x01 : 0x00)
        append!(z, UInt8[m & 0xff, (m >> 8) & 0xff, ~UInt8(m & 0xff), ~UInt8((m >> 8) & 0xff)])
        append!(z, view(brut, i:i + m - 1))
        i += m
    end
    append!(z, octets_be_q8(adler32_q8(brut)))
    table = table_crc_q8()
    io = IOBuffer()
    write(io, UInt8[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
    morceau_png_q8(io, "IHDR", vcat(octets_be_q8(UInt32(w)), octets_be_q8(UInt32(h)), UInt8[8, 2, 0, 0, 0]), table)
    morceau_png_q8(io, "IDAT", z, table)
    morceau_png_q8(io, "IEND", UInt8[], table)
    octets = take!(io)
    write(chemin, octets)
    return octets
end

const PALETTE_Q8 = ((68, 1, 84), (72, 40, 120), (62, 74, 137), (49, 104, 142), (38, 130, 142),
                    (31, 158, 137), (53, 183, 121), (109, 205, 89), (180, 222, 44), (253, 231, 37))

function couleur_q8(v, lo, hi, palette)
    isnan(v) && return (0x30, 0x30, 0x30)
    f = clamp((v - lo) / (hi - lo), 0.0, 1.0)
    if palette == :gris
        g = round(UInt8, 255 * f)
        return (g, g, g)
    end
    x = f * (length(PALETTE_Q8) - 1)
    i = min(floor(Int, x), length(PALETTE_Q8) - 2)
    a = x - i
    c1, c2 = PALETTE_Q8[i + 1], PALETTE_Q8[i + 2]
    return ntuple(k -> round(UInt8, (1 - a) * c1[k] + a * c2[k]), 3)
end

"""Image (ny × nx, NaN permis) → tableau RGB 3 × nx × ny."""
function rgb_q8(img::AbstractMatrix{Float64}, lo, hi, palette)
    ny, nx = size(img)
    rgb = zeros(UInt8, 3, nx, ny)
    for y in 1:ny, x in 1:nx
        c = couleur_q8(img[y, x], lo, hi, palette)
        rgb[1, x, y], rgb[2, x, y], rgb[3, x, y] = c
    end
    return rgb
end

hex_q8(c) = @sprintf("#%02x%02x%02x", c[1], c[2], c[3])

function centile_q8(v::AbstractVector{Float64}, p)
    isempty(v) && return NaN
    s = sort(v)
    return s[clamp(round(Int, p * (length(s) - 1)) + 1, 1, length(s))]
end

"""Mosaïque 2 × 2 : panneaux (titre, sous_titre, png, lo, hi, palette, unite), images intégrées."""
function svg_mosaique_q8(chemin, titre, panneaux, nx, ny, larg)
    haut_img = round(Int, larg * ny / nx)
    m, entete, pied, sp = 16, 52, 48, 24
    pw, ph = larg + 2m, entete + haut_img + pied
    L, H = 2pw + sp, 40 + 2ph
    open(chemin, "w") do io
        println(io, """<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="$L" height="$H" font-family="sans-serif" font-size="12">""")
        println(io, """<rect width="$L" height="$H" fill="white"/>""")
        println(io, """<text x="$m" y="26" font-size="16">$titre</text>""")
        for (q, p) in enumerate(panneaux)
            ox = ((q - 1) % 2) * (pw + sp)
            oy = 40 + ((q - 1) ÷ 2) * ph
            println(io, """<text x="$(ox + m)" y="$(oy + 22)" font-size="14">$(p.titre)</text>""")
            println(io, """<text x="$(ox + m)" y="$(oy + 40)" fill="#555">$(p.sous_titre)</text>""")
            donnees = base64encode(p.png)
            println(io, """<image x="$(ox + m)" y="$(oy + entete)" width="$larg" height="$haut_img" preserveAspectRatio="none" style="image-rendering:pixelated" href="data:image/png;base64,$donnees" xlink:href="data:image/png;base64,$donnees"/>""")
            println(io, """<rect x="$(ox + m)" y="$(oy + entete)" width="$larg" height="$haut_img" fill="none" stroke="#888"/>""")
            yb = oy + entete + haut_img + 8
            nb = 64
            for i in 0:nb - 1
                v = p.lo + (p.hi - p.lo) * (i + 0.5) / nb
                @printf(io, "<rect x=\"%.2f\" y=\"%d\" width=\"%.2f\" height=\"12\" fill=\"%s\"/>\n",
                        ox + m + i * larg / nb, yb, larg / nb + 0.5, hex_q8(couleur_q8(v, p.lo, p.hi, p.palette)))
            end
            @printf(io, "<text x=\"%d\" y=\"%d\">%.4g %s</text>\n", ox + m, yb + 28, p.lo, p.unite)
            @printf(io, "<text x=\"%d\" y=\"%d\" text-anchor=\"end\">%.4g %s</text>\n", ox + m + larg, yb + 28, p.hi, p.unite)
        end
        println(io, "</svg>")
    end
    return chemin
end

function ecrire_matrice_q8(chemin, img::AbstractMatrix)
    open(chemin, "w") do io
        for y in 1:size(img, 1)
            println(io, join((isnan(Float64(v)) ? "" : string(v) for v in view(img, y, :)), ","))
        end
    end
end

# ---------------------------------------------------------------------
# Contrôle des bits de M1 et M2 par la DLL, sur le début des données
# ---------------------------------------------------------------------

function controle_marqueurs_q8(brut, f, format, dossier)
    n = min(length(brut), 1 << 22)
    n -= isodd(n)
    spc = ecrire_spc(joinpath(dossier, "q8_extrait.spc"), f.entete, brut, n)
    d = DecodeurFIFO(format)
    decoder!(d, brut, n)
    ent, _ = photons_dll(spc; type_fifo = f.type_fifo, type_flux = type_flux_fichier(f.type_flux),
                         quoi = 0x3c, max = 10_000_000)
    ent = [e for e in ent if est_marqueur(e)]
    nd = [count(e -> (e.drapeaux & DRAPEAUX_MARQUEURS[k]) != 0, ent) for k in 1:4]
    nm = length.(d.marqueurs)
    nd == nm || return "comptes différents : DLL $(nd), SPCLite $(nm) (M0 à M3)"
    isempty(ent) && return "aucun marqueur dans l'extrait"
    k0 = findfirst(k -> (ent[1].drapeaux & DRAPEAUX_MARQUEURS[k]) != 0, 1:4)
    decal = Int64(ent[1].mtime) - d.marqueurs[k0][1]
    for k in 1:4
        dk = [Int64(e.mtime) - decal for e in ent if (e.drapeaux & DRAPEAUX_MARQUEURS[k]) != 0]
        dk == d.marqueurs[k] || return "temps différents pour M$(k - 1)"
    end
    return nm
end

# ---------------------------------------------------------------------
# Programme
# ---------------------------------------------------------------------

function test_q8(r, reglages, format)
    dossier = joinpath(@__DIR__, "resultats", "qc")
    mkpath(dossier)
    mode_routage = 0x0f00 | sum(UInt16(1) << (12 + k) for k in 0:3 if r.fronts_montants[k + 1]; init = UInt16(0))
    p = merge(parametres_qc(reglages), Dict{String,Any}(
        "mode" => 1, "adc_resolution" => 12, "stop_on_time" => 0, "collect_time" => 1.0,
        "macro_time_clk" => 0, "trigger" => 0, "routing_mode" => Int(mode_routage)))
    ini = ecrire_ini(joinpath(dossier, "q8_image.ini"), p)
    println("Format : ", format.nom)

    avec_spc_tous(ini; types = (TYPE_QC104,)) do modules
        m = modules[1]
        if !isempty(r.numero_serie)
            i = findfirst(k -> (try eeprom(k).serie catch; "" end) == r.numero_serie, modules)
            i === nothing && error("aucune QC-104 de n° de série $(r.numero_serie)")
            m = modules[i]
        end
        lu = lire_parametres(m; fichier = joinpath(dossier, "q8_relu.ini"))
        dt_ns = largeur_canal_s(TYPE_QC104, lu) * 1e9
        f = fifo_init(m)
        tic_ns = tic_macro_s(m) * 1e9
        s = sync_etat(m)
        println("SYNC : ", get(MESSAGES_SYNC, s, string(s)))
        s == 1 || (println("ÉCHEC : il faut un SYNC correct."); return false)

        # 1. Acquisition jusqu'à images + 2 horloges de trame
        dec = DecodeurFIFO(format)
        tampon = zeros(UInt16, 1 << 21)
        brut = UInt16[]
        sizehint!(brut, 1 << 24)
        deborde = false
        ligne = trame = nothing
        freq = zeros(4)
        effacer_taux(m)
        demarrer(m)
        t_debut = time()
        while true
            k = lire_fifo!(m, tampon)
            decoder!(dec, tampon, k)
            append!(brut, view(tampon, 1:k))
            (etat_mesure(m) & SPC_FOVFL) != 0 && (deborde = true)
            ecoule = time() - t_debut
            if trame === nothing && ecoule > 1.0
                ligne, trame, freq = detecter_horloges_q8(dec, ecoule, r)
                if (ligne === nothing || trame === nothing) && ecoule > 3.0
                    break
                end
                ligne === nothing && (trame = nothing)
            end
            trame !== nothing && length(dec.marqueurs[trame + 1]) >= r.images + 2 && break
            ecoule > r.delai_max_s && break
            sleep(0.005)
        end
        k = lire_fifo!(m, tampon)                # avant l'arrêt, qui vide le FIFO
        decoder!(dec, tampon, k)
        append!(brut, view(tampon, 1:k))
        duree = time() - t_debut
        arreter(m)
        isodd(length(brut)) && pop!(brut)
        rates = taux_bruts(m)

        println()
        @printf("Acquisition : %.2f s, %d photons (IN1 %d, IN2 %d), %.1f Mo de données%s\n", duree, dec.photons,
                dec.par_voie[1], dec.par_voie[2], 2 * length(brut) / 1e6, deborde ? " ; FIFO DÉBORDÉ : photons perdus" : "")
        fm = [length(dec.marqueurs[k]) / duree for k in 1:4]
        @printf("Marqueurs par seconde : M0 %.4g, M1 %.4g, M2 %.4g, M3 %.4g\n", fm[1], fm[2], fm[3], fm[4])
        if ligne === nothing || trame === nothing
            println("ÉCHEC : horloges de ligne et de trame introuvables. Le microscope balaie-t-il ? Ses horloges ",
                    "sont-elles sur des entrées marqueurs (broches 8, 9, 10 ou 12) ? Front actif (fronts_montants) ?")
            return false
        end
        mL, mF = dec.marqueurs[ligne + 1], dec.marqueurs[trame + 1]
        @printf("Horloge de ligne : M%d (%.1f Hz) ; horloge de trame : M%d (%.3f Hz)\n",
                ligne, length(mL) / duree, trame, length(mF) / duree)
        nimg = min(r.images, length(mF) - 1)
        nimg < r.images && @printf("ATTENTION : seulement %d images complètes en %.0f s.\n", nimg, duree)
        nimg >= 1 || (println("ÉCHEC : aucune image complète."); return false)

        # 2. Géométrie
        periode_ligne = sort(diff(mL))[max(1, length(mL) ÷ 2)] * tic_ns
        eps = round(Int64, 0.25 * periode_ligne / tic_ns)
        premier = [searchsortedfirst(mL, mF[i] - eps) for i in 1:nimg + 1]
        lignes = [premier[i + 1] - premier[i] for i in 1:nimg]
        ny = r.lignes_par_image > 0 ? r.lignes_par_image : sort(lignes)[(nimg + 1) ÷ 2]
        nx = r.pixels_par_ligne
        periode_trame = (mF[nimg + 1] - mF[1]) * tic_ns / nimg
        @printf("Images : %d × %d pixels ; %d à %d lignes par trame (%d retenues) ; ligne de %.3f µs, trame de %.3f ms\n",
                nx, ny, minimum(lignes), maximum(lignes), ny, periode_ligne / 1e3, periode_trame / 1e6)
        fenetre = r.retard_ligne_ns + nx * r.temps_pixel_ns
        @printf("Pixels : %.1f ns chacun, de %.3f à %.3f µs après l'horloge de ligne%s\n", r.temps_pixel_ns,
                r.retard_ligne_ns / 1e3, fenetre / 1e3,
                fenetre > periode_ligne ? " — PLUS LONG QUE LA LIGNE : réduis pixels_par_ligne ou temps_pixel_ns" : "")

        # 3. Période du laser et temps zéro de chaque entrée
        periode_ns = rates.code >= 0 && rates.valeurs[1] > 1e6 ? 1e9 / rates.valeurs[1] : NaN
        if isnan(periode_ns)
            dernier = maximum(something(findlast(>(0), view(dec.micro, :, v)), 1) for v in 1:2)
            periode_ns = dernier * dt_ns
        end
        t0 = ntuple(v -> isnan(r.t0_ns[v]) ? t0_montee_q8(view(dec.micro, :, v), dt_ns, periode_ns) : r.t0_ns[v], 2)
        @printf("Période du laser %.3f ns ; t0 : IN1 %.3f ns, IN2 %.3f ns%s\n", periode_ns, t0[1], t0[2],
                any(isnan, t0) ? " (NaN : trop peu de photons sur cette entrée)" : "")
        t0 = map(x -> isnan(x) ? 0.0 : x, t0)

        # 4. Tri des photons de toute l'acquisition, par paquets
        g = (images = nimg, ny = ny, nx = nx, tic_ns = tic_ns, dt_ns = dt_ns, t0 = t0, periode_ns = periode_ns,
             marge_ns = r.marge_ns, retard_ns = r.retard_ligne_ns, dwell_ns = r.temps_pixel_ns, pas_prof_ns = 250.0)
        N = zeros(Int, ny, nx, 2)
        S = zeros(Float64, ny, nx, 2)
        prof_ligne = zeros(Int, max(1, ceil(Int, 1.5 * periode_ligne / g.pas_prof_ns)))
        d2 = DecodeurFIFO(format; garder_photons = true)
        places = hors = 0
        paquet = 1 << 22
        for a in 1:paquet:length(brut)
            b = min(a + paquet - 1, length(brut))
            decoder!(d2, view(brut, a:b), b - a + 1)
            pl, ho = trier_q8!(N, S, prof_ligne, d2, mL, mF, premier, g)
            places += pl; hors += ho
            empty!(d2.t_photons); empty!(d2.micro_photons); empty!(d2.routage_photons); empty!(d2.voie_photons)
        end
        actifs = findall(>=(0.1 * maximum(prof_ligne; init = 0)), prof_ligne)
        if !isempty(actifs)
            @printf("Photons des images : %d dans les pixels, %d hors de la fenêtre des pixels (%.1f %%) ; ",
                    places, hors, 100 * hors / max(1, places + hors))
            @printf("la lumière arrive de %.2f à %.2f µs après l'horloge de ligne\n",
                    (first(actifs) - 1) * g.pas_prof_ns / 1e3, last(actifs) * g.pas_prof_ns / 1e3)
        end

        # 5. Images, PNG, mosaïque, tableaux
        panneaux = Any[]
        ok = !deborde && nimg == r.images
        for v in 1:2
            I = Float64.(view(N, :, :, v))
            tau = [N[y, x, v] >= r.min_photons ? S[y, x, v] / N[y, x, v] : NaN for y in 1:ny, x in 1:nx]
            tot = sum(view(N, :, :, v))
            valides = [z for z in tau if !isnan(z)]
            tau_moy = sum(view(S, :, :, v)) / max(tot, 1)
            tau_corr = tau_premier_moment_q8(tau_moy, periode_ns, r.marge_ns)
            hi = max(centile_q8(vec(I), 0.995), 1.0)
            lo_t, hi_t = isnan(r.plage_tau_ns[1]) ? (centile_q8(valides, 0.02), centile_q8(valides, 0.98)) : r.plage_tau_ns
            (isnan(lo_t) || !(hi_t > lo_t)) && ((lo_t, hi_t) = (0.0, periode_ns))
            png_i = png_q8(joinpath(dossier, "q8_in$(v)_photons.png"), rgb_q8(I, 0.0, hi, :gris))
            png_t = png_q8(joinpath(dossier, "q8_in$(v)_premier_moment.png"), rgb_q8(tau, lo_t, hi_t, :viridis))
            ecrire_matrice_q8(joinpath(dossier, "q8_in$(v)_photons.csv"), view(N, :, :, v))
            ecrire_matrice_q8(joinpath(dossier, "q8_in$(v)_premier_moment_ns.csv"), tau)
            push!(panneaux, (titre = "IN$v : photons (somme de $nimg images)",
                             sous_titre = @sprintf("%d photons, %.1f par pixel en moyenne ; échelle coupée au centile 99,5", tot, tot / (nx * ny)),
                             png = png_i, lo = 0.0, hi = hi, palette = :gris, unite = "ph"))
            push!(panneaux, (titre = "IN$v : premier moment, moyenne de t − t0 (brute)",
                             sous_titre = @sprintf("t0 %.3f ns ; moyenne %.3f ns, corrigée du repliement %.3f ns ; gris : moins de %d photons",
                                                   t0[v], tau_moy, tau_corr, r.min_photons),
                             png = png_t, lo = lo_t, hi = hi_t, palette = :viridis, unite = "ns"))
            @printf("IN%d : %d photons dans les images ; premier moment moyen %.3f ns brut, %.3f ns corrigé du repliement (%d pixels valides sur %d)\n",
                    v, tot, tau_moy, tau_corr, length(valides), nx * ny)
        end
        # ordre de la mosaïque : IN1 et IN2 en intensité en haut, leurs premiers moments en bas
        panneaux = panneaux[[1, 3, 2, 4]]
        svg = svg_mosaique_q8(joinpath(dossier, "q8_mosaique.svg"),
                              @sprintf("Somme de %d images (%d × %d), %.2f s", nimg, nx, ny, duree),
                              panneaux, nx, ny, r.taille_affichage)
        open(joinpath(dossier, "q8_declins.csv"), "w") do io
            println(io, "canal,temps_ns,in1,in2")
            for j in 1:size(dec.micro, 1)
                @printf(io, "%d,%.4f,%d,%d\n", j - 1, (j - 0.5) * dt_ns, dec.micro[j, 1], dec.micro[j, 2])
            end
        end

        # 6. Bits de M1 et M2 : contrôle par la DLL
        c = try
            controle_marqueurs_q8(brut, f, format, dossier)
        catch e
            "erreur : " * sprint(showerror, e)
        end
        if c isa String
            println("Marqueurs contre la DLL : ", c)
        else
            @printf("Marqueurs contre la DLL : identiques (M0 %d, M1 %d, M2 %d, M3 %d dans l'extrait) : bits de M%d et M%d confirmés\n",
                    c[1], c[2], c[3], c[4], ligne, trame)
        end

        println("\nMosaïque : ", svg)
        println("Images : q8_in1_photons.png, q8_in1_premier_moment.png, q8_in2_… ; tableaux .csv ; déclins : q8_declins.csv")
        println(ok ? "RÉUSSI : $(nimg) images acquises et sommées. Ouvre q8_mosaique.svg." :
                     "INCOMPLET : voir les lignes ci-dessus ; colle la sortie dans la conversation.")
        return ok
    end
end

test_q8(q8, REGLAGES_QC, FORMAT_QC104)
