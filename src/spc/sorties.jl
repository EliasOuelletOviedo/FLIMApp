# sorties.jl — les fichiers de sortie d'imagerie_photons.jl et
# d'histogrammes_single.jl, inchangés : images BMP 24 bits, déclins SVG,
# CSV des histogrammes Single, matrices .jls. Aucune dépendance : ils
# s'ouvrent partout.

# ---------------------------------------------------------------------
# Temps moyen (premier moment, sans correction de la réponse instrumentale)
# ---------------------------------------------------------------------

function sommer_blocs_img(A, b)
    ny, nx = size(A, 1) ÷ b, size(A, 2) ÷ b
    return [sum(@view A[(i - 1) * b + 1:i * b, (j - 1) * b + 1:j * b]) for i in 1:ny, j in 1:nx]
end

"""
    temps_moyen(intensite, somme_t, binning, photons_min) -> (Sn, tm)

Photons (`Sn`) et temps moyen d'arrivée en ns (`tm`, NaN sous
`photons_min` photons) par blocs de `binning` × `binning` pixels. Un aperçu,
pas un ajustement.
"""
function temps_moyen(intensite::AbstractMatrix, somme_t::AbstractMatrix, binning::Integer, photons_min::Integer)
    b = clamp(binning, 1, max(1, min(size(intensite)...)))
    Sn = sommer_blocs_img(Float64.(intensite), b)
    St = sommer_blocs_img(somme_t, b)
    seuil = max(photons_min, 1)
    tm = [Sn[i] >= seuil ? St[i] / Sn[i] : NaN for i in eachindex(Sn)]
    return Sn, reshape(tm, size(Sn))
end

# ---------------------------------------------------------------------
# Images BMP 24 bits
# ---------------------------------------------------------------------

function ecrire_bmp_img(chemin, R::Matrix{UInt8}, G::Matrix{UInt8}, B::Matrix{UInt8})
    h, w = size(R)
    rang = 4 * cld(3w, 4)                         # octets par ligne, multiple de 4
    open(chemin, "w") do io
        write(io, UInt8('B'), UInt8('M'), UInt32(54 + rang * h), UInt16(0), UInt16(0), UInt32(54))
        write(io, UInt32(40), Int32(w), Int32(h), UInt16(1), UInt16(24), UInt32(0),
              UInt32(rang * h), Int32(2835), Int32(2835), UInt32(0), UInt32(0))
        ligne = zeros(UInt8, rang)
        for y in h:-1:1                           # BMP : de bas en haut
            fill!(ligne, 0x00)
            for x in 1:w
                ligne[3x - 2] = B[y, x]
                ligne[3x - 1] = G[y, x]
                ligne[3x] = R[y, x]
            end
            write(io, ligne)
        end
    end
    return chemin
end

octet_img(v) = round(UInt8, 255 * clamp(v, 0.0, 1.0))

"""Bleu, cyan, vert, jaune, rouge : court à long."""
function rampe_img(v)
    p = ((0.0, 0.0, 1.0), (0.0, 1.0, 1.0), (0.0, 1.0, 0.0), (1.0, 1.0, 0.0), (1.0, 0.0, 0.0))
    x = 4 * clamp(v, 0.0, 1.0)
    i = min(floor(Int, x), 3)
    f = x - i
    a, b = p[i + 1], p[i + 2]
    return (a[1] + f * (b[1] - a[1]), a[2] + f * (b[2] - a[2]), a[3] + f * (b[3] - a[3]))
end

"""Haut de l'échelle : 99,5e centile des valeurs non nulles, au moins 1."""
function haut_echelle_img(A)
    nz = filter(>(0), vec(A))
    return isempty(nz) ? 1.0 : max(1.0, centile_img(nz, 99.5))
end

"""
    images_bmp(prefixe, res, binning_temps, photons_min) -> (bas, haut)

*_intensite.bmp (niveaux de gris) et *_temps_moyen.bmp (couleur, bleu
court, rouge long ; brillance = intensité). Renvoie l'échelle du temps
moyen (2e et 98e centiles), NaN sans temps moyen.
"""
function images_bmp(prefixe, res, binning_temps::Integer, photons_min::Integer)
    I = Float64.(res.intensite)
    g = octet_img.(I ./ haut_echelle_img(I))
    ecrire_bmp_img(prefixe * "_intensite.bmp", g, g, g)

    b = clamp(binning_temps, 1, min(size(I)...))
    Sn = sommer_blocs_img(I, b)
    St = sommer_blocs_img(res.somme_t, b)
    seuil = max(photons_min, 1)
    tm = [Sn[i] >= seuil ? St[i] / Sn[i] : NaN for i in eachindex(Sn)]
    valides = filter(!isnan, tm)
    isempty(valides) && return (NaN, NaN)
    bas, haut = centile_img(valides, 2), centile_img(valides, 98)
    echelle = max(haut - bas, 1e-6)
    lum = haut_echelle_img(Sn)
    R = zeros(UInt8, size(Sn)); G = zeros(UInt8, size(Sn)); B = zeros(UInt8, size(Sn))
    for i in eachindex(Sn)
        isnan(tm[i]) && continue
        c = rampe_img((tm[i] - bas) / echelle)
        l = clamp(Sn[i] / lum, 0.0, 1.0)^0.7
        R[i], G[i], B[i] = octet_img(c[1] * l), octet_img(c[2] * l), octet_img(c[3] * l)
    end
    agrandir(M) = repeat(M; inner = (b, b))
    ecrire_bmp_img(prefixe * "_temps_moyen.bmp", agrandir(R), agrandir(G), agrandir(B))
    return (bas, haut)
end

# ---------------------------------------------------------------------
# Déclins SVG
# ---------------------------------------------------------------------

function svg_declin_img(chemin, t_ns, coups, titre)
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
        println(io, """<polyline fill="none" stroke="#1d4ed8" stroke-width="1.2" points="$pts"/>""")
        println(io, "</svg>")
    end
    return chemin
end

"""Déclin de 4096 canaux regroupé en 256 (16 canaux) pour le SVG : (t_ns, coups)."""
function declin_regroupe(declin::AbstractVector, dt_ns)
    t_ns = [(16(k - 1) + 8) * dt_ns for k in 1:256]
    regroupe = [sum(declin[16(k - 1) + 1:16k]) for k in 1:256]
    return t_ns, regroupe
end

function svg_histo_single(chemin, dt_ns, H::Matrix{UInt16}, titre)
    n, N = size(H)
    somme = vec(sum(Int.(H); dims = 2))
    L, Hs = 760, 440                              # largeur, hauteur
    mg, md, mh, mb = 80, 24, 56, 56               # marges gauche, droite, haut, bas
    lx, ly = L - mg - md, Hs - mh - mb
    xmax = n * dt_ns
    ymax = max(1.0, ceil(log10(maximum(somme) + 1)))
    X(t) = mg + lx * t / xmax
    Y(c) = mh + ly * (1 - log10(c + 1) / ymax)
    pas = xmax / 8
    for q in (0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 20, 50, 100, 200, 500, 1000)
        xmax / q <= 8 && (pas = q; break)
    end
    trace(c) = join((@sprintf("%.1f,%.1f", X((k - 0.5) * dt_ns), Y(c[k])) for k in 1:n), " ")
    open(chemin, "w") do io
        println(io, """<svg xmlns="http://www.w3.org/2000/svg" width="$L" height="$Hs" font-family="sans-serif" font-size="12">""")
        println(io, """<rect width="$L" height="$Hs" fill="white"/>""")
        # 20 courbes grises au plus, réparties sur la série, pour garder un SVG léger
        choisis = N > 1 ? unique(round.(Int, range(1, N; length = min(N, 20)))) : Int[]
        legende = length(choisis) == N ? "gris : chaque histogramme" :
                  "gris : $(length(choisis)) des $N histogrammes"
        println(io, """<text x="$mg" y="24" font-size="15">$titre</text>""")
        N > 1 && println(io, """<text x="$mg" y="42" fill="#4b5563">$legende ; bleu : somme</text>""")
        @printf(io, "<line x1=\"%d\" y1=\"%d\" x2=\"%d\" y2=\"%d\" stroke=\"black\"/>\n", mg, mh + ly, mg + lx, mh + ly)
        @printf(io, "<line x1=\"%d\" y1=\"%d\" x2=\"%d\" y2=\"%d\" stroke=\"black\"/>\n", mg, mh, mg, mh + ly)
        for t in 0:pas:xmax
            @printf(io, "<line x1=\"%.1f\" y1=\"%d\" x2=\"%.1f\" y2=\"%d\" stroke=\"black\"/>\n", X(t), mh + ly, X(t), mh + ly + 5)
            @printf(io, "<text x=\"%.1f\" y=\"%d\" text-anchor=\"middle\">%g</text>\n", X(t), mh + ly + 19, t)
        end
        for k in 0:Int(ymax)
            y = mh + ly * (1 - k / ymax)
            @printf(io, "<line x1=\"%d\" y1=\"%.1f\" x2=\"%d\" y2=\"%.1f\" stroke=\"#ddd\"/>\n", mg, y, mg + lx, y)
            @printf(io, "<text x=\"%d\" y=\"%.1f\" text-anchor=\"end\">1e%d</text>\n", mg - 8, y + 4, k)
        end
        @printf(io, "<text x=\"%.1f\" y=\"%d\" text-anchor=\"middle\">temps (ns)</text>\n", mg + lx / 2, Hs - 14)
        for i in choisis
            println(io, """<polyline fill="none" stroke="#9ca3af" stroke-width="0.8" points="$(trace(view(H, :, i)))"/>""")
        end
        println(io, """<polyline fill="none" stroke="#1d4ed8" stroke-width="1.2" points="$(trace(somme))"/>""")
        println(io, "</svg>")
    end
    return chemin
end

# ---------------------------------------------------------------------
# Single : CSV et fin de mesure
# ---------------------------------------------------------------------

"""
Une ligne par canal : canal, temps_ns (centre du canal), h1 … hN, somme. Les
lignes « # » du début donnent les réglages et la fin de chaque mesure (en
Julia : CSV.File(f; comment = "#")).
"""
function ecrire_csv_single(chemin, H::Matrix{UInt16}, dt_ns, entete)
    n, N = size(H)
    open(chemin, "w") do io
        for l in entete
            println(io, "# ", l)
        end
        println(io, "canal,temps_ns,", join(("h$i" for i in 1:N), ","), ",somme")
        for k in 1:n
            @printf(io, "%d,%.5f", k - 1, (k - 0.5) * dt_ns)
            s = 0
            for i in 1:N
                print(io, ",", H[k, i])
                s += Int(H[k, i])
            end
            println(io, ",", s)
        end
    end
    return chemin
end

"""Pourquoi une mesure Single s'est arrêtée, d'après les bits de SPC_test_state."""
function texte_fin_single(etat::UInt16)
    (etat & SPC_OVERFL) != 0 &&
        return "ARRÊT SUR DÉBORDEMENT : un canal a atteint 65535 coups, mesure écourtée"
    (etat & SPC_OVERFLOW) != 0 && return "DÉBORDEMENT : des canaux sont saturés à 65535"
    (etat & (SPC_TIME_OVER | SPC_COLTIM_OVER)) != 0 && return "temps écoulé"
    (etat & SPC_CMD_STOP) != 0 && return "arrêtée par le logiciel"
    return @sprintf("fin inattendue (état 0x%04X)", etat)
end

# ---------------------------------------------------------------------
# Traitement d'une acquisition d'imagerie (sans les cartes)
# ---------------------------------------------------------------------

"""Ce que le .jls d'une acquisition garde des réglages : des valeurs simples, sans type propre à FLIMCore."""
reglages_jls(g::Geometrie, binning_temps, photons_min) =
    (temps_pixel_ns = g.temps_pixel_ns, pixels_par_ligne = g.pixels_par_ligne,
     decalage_pixels = g.decalage_pixels, lignes_par_image = g.lignes_par_image,
     decalage_lignes = g.decalage_lignes, ligne_front_montant = g.ligne_front_montant,
     trame_front_montant = g.trame_front_montant, binning_temps = binning_temps, photons_min = photons_min)

"""
    ecrire_resultats_img(prefixe, res, dt_ns, m, g, binning_temps, photons_min) -> (bas, haut)

Fichiers d'une acquisition traitée, comme imagerie_photons.jl :
*_intensite.bmp, *_temps_moyen.bmp, *_declin.svg et *.jls. `res` a les
champs de `ranger_photons`.
"""
function ecrire_resultats_img(prefixe, res, dt_ns, m, g::Geometrie, binning_temps, photons_min)
    bas, haut = images_bmp(prefixe, res, binning_temps, photons_min)
    t_ns, regroupe = declin_regroupe(res.declin, dt_ns)
    svg_declin_img(prefixe * "_declin.svg", t_ns, regroupe,
                   "Module $m : déclin de $(res.photons) photons")
    serialize(prefixe * ".jls", (intensite = res.intensite, somme_t = res.somme_t,
              declin = res.declin, dt_ns = dt_ns, periode_ligne_s = res.periode_ligne_s,
              lignes_trame = res.lignes_trame, trames = res.trames,
              reglages = reglages_jls(g, binning_temps, photons_min)))
    return (bas, haut)
end

"""
    traiter(prefixe, brut, tic_s, fenetre_ns, duree_s, deborde, m, g;
            binning_temps=4, photons_min=20, io=stdout) -> NamedTuple

Traitement en bloc d'une acquisition, comme `traiter_img` du script :
`ranger_photons`, puis les fichiers et le résumé.
"""
function traiter(prefixe, brut, tic_s, fenetre_ns, duree_s, deborde, m, g::Geometrie;
                 binning_temps::Integer = 4, photons_min::Integer = 20, io::IO = stdout)
    dt_ns = fenetre_ns / 4096
    res = ranger_photons(brut, tic_s, dt_ns, g)
    bas, haut = ecrire_resultats_img(prefixe, res, dt_ns, m, g, binning_temps, photons_min)

    println(io, "\n== Module $m ==")
    @printf(io, "  %d photons (%.3g /s), dont %d dans l'image ; pertes %d%s\n",
            res.photons, res.photons / duree_s, res.dans_image, res.pertes,
            deborde ? " ; FIFO DÉBORDÉ : baisse la lumière" : "")
    @printf(io, "  Ligne : %.2f µs, soit %d pixels de %.0f ns ; %d lignes par trame ; %d trames\n",
            res.periode_ligne_s * 1e6, res.pixels_ligne, g.temps_pixel_ns, res.lignes_trame, res.trames)
    @printf(io, "  Image %d × %d pixels ; fenêtre TAC %.3f ns\n", res.nx, res.ny, fenetre_ns)
    isnan(bas) || @printf(io, "  Temps moyen (2e à 98e centile, binning %d) : %.3f à %.3f ns\n",
                          binning_temps, bas, haut)
    println(io, "  Fichiers : ", prefixe, "_intensite.bmp, _temps_moyen.bmp, _declin.svg, .jls")
    return res
end

"""
    retraiter(nom, g; dossier, binning_temps=4, photons_min=20, io=stdout)

Retraite une acquisition déjà faite avec une autre géométrie (décalages,
taille de l'image…), sans toucher aux cartes. `nom` : par exemple
"20260929_153012_module0" (cherché dans `dossier`), ou un chemin complet,
avec ou sans .spc.
"""
function retraiter(nom::AbstractString, g::Geometrie; dossier::AbstractString = ".",
                   binning_temps::Integer = 4, photons_min::Integer = 20, io::IO = stdout)
    base = prefixe_acquisition(nom)
    prefixe = occursin(r"[/\\]", base) ? abspath(base) : joinpath(dossier, base)
    isfile(prefixe * ".spc") || error("introuvable : $(prefixe).spc")
    meta = lire_ini(prefixe * "_acquisition.ini"; section = "acquisition")
    _, brut = lire_spc(prefixe * ".spc")
    println(io, "Retraitement de ", prefixe, ".spc (sans les cartes)")
    return traiter(prefixe, brut, meta["tic_s"], meta["fenetre_ns"], meta["duree_s"],
                   get(meta, "fifo_deborde", 0.0) != 0, round(Int, get(meta, "module", -1.0)), g;
                   binning_temps = binning_temps, photons_min = photons_min, io = io)
end
