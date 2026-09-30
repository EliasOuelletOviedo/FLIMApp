# imagerie_photons.jl — images à partir des photons (mode FIFO + horloges du scanner).
#
# Chaque SPC-150N choisie enregistre ses photons en FIFO, avec les horloges
# du scanner sur ses marqueurs : M1 = ligne (18 kHz), M2 = trame (31,25 Hz).
# Chaque photon est ensuite rangé dans son pixel, en logiciel, comme le fait
# SPCM avec une horloge de pixel interne :
#   ligne   = nombre de lignes depuis la dernière trame ;
#   colonne = temps depuis le début de la ligne / temps de pixel (50 ns).
# Toutes les trames de l'acquisition s'additionnent dans une seule image.
#
# Sorties, dans resultats/imagerie, pour chaque carte :
#   *_intensite.bmp     image d'intensité (niveaux de gris) ;
#   *_temps_moyen.bmp   temps moyen d'arrivée en couleur (bleu court, rouge
#                       long), brillance = intensité. Premier moment, sans
#                       correction de la réponse instrumentale : un aperçu, pas un fit ;
#   *_declin.svg        déclin de tous les photons ;
#   *.spc               flux brut (en-tête B&H + mots FIFO) ;
#   *_acquisition.ini   ce qu'il faut pour retraiter le .spc sans les cartes ;
#   *_parametres.ini    tous les paramètres relus dans la carte ;
#   *.jls               matrices complètes (Serialization), pour tes analyses.
#
# Avant : SPCM fermé ; détecteurs allumés (logiciel DCC, ou
# test_dcc2_allumage.jl avec garder_allume = true) ; scanner en marche ;
# laser allumé. Réglages du détecteur et du TAC : reglages_spc.jl ; au
# départ, le script affiche ce que chaque carte en a vraiment retenu.
#
# Géométrie de l'image : chaque réglage laissé à `nothing` ci-dessous vient
# de reglages_spc.jl si tu y as recopié le réglage SPCM correspondant, sinon
# de sa valeur par défaut (le script affiche d'où vient chaque valeur) :
#   temps_pixel_ns      ← pixel_time (en secondes)       sinon 50 ns
#   pixels_par_ligne    ← scan_size_x                    sinon 0 : toute la ligne
#   decalage_pixels     ← scan_borders, bord gauche      sinon 0
#   lignes_par_image    ← scan_size_y                    sinon 0 : toutes les lignes
#   decalage_lignes     ← scan_borders, bord haut        sinon 0
#   ligne/trame_front_montant ← scan_polarity, bits 0/1  sinon front montant
# Une valeur écrite ici l'emporte sur reglages_spc.jl.
#
# Premier essai sans réglage SPCM : tu vois toute la période de ligne et
# toutes les lignes, retours du scanner compris. Repère la zone utile, règle
# les décalages et la taille, puis mets dans `rejouer` le nom affiché à la
# fin (par exemple "20260929_153012_module0") : le script retraite alors
# cette acquisition sans toucher aux cartes. rejouer = "" : nouvelle acquisition.

Base.exit_on_sigint(false)          # Ctrl+C passe par la libération des cartes, même hors REPL
isdefined(Main, :SPCLite) || include("SPCLite.jl")
using .SPCLite
(isdefined(SPCLite, :VERSION_LITE) && SPCLite.VERSION_LITE >= 8) ||
    error("Julia a gardé une ancienne version de SPCLite.jl : redémarre Julia, puis relance ce script.")
using Printf, Dates, Serialization
include("reglages_spc.jl")

imagerie_reglages = (
    modules = [0, 1],               # cartes à enregistrer
    duree_s = 2.0,                  # acquisition (environ 60 trames à 31,25 Hz)
    temps_pixel_ns = nothing,       # horloge de pixel interne
    pixels_par_ligne = nothing,     # pixels gardés par ligne
    decalage_pixels = nothing,      # pixels ignorés après chaque début de ligne
    lignes_par_image = nothing,     # lignes gardées par image
    decalage_lignes = nothing,      # lignes ignorées après chaque début de trame
    ligne_front_montant = nothing,  # front actif de l'horloge de ligne (M1)
    trame_front_montant = nothing,  # front actif de l'horloge de trame (M2)
    binning_temps = 4,              # pixels regroupés (n × n) pour le temps moyen
    photons_min = 20,               # sous ce nombre de photons, pas de temps moyen
    rejouer = "",                   # "" : acquisition ; sinon nom d'une acquisition à retraiter
)

"""
    geometrie_img(r, reglages) -> (r_complet, provenance)

Remplace chaque réglage de géométrie laissé à `nothing` par le réglage
SPCM de `reglages` (reglages_spc.jl), ou à défaut par sa valeur par défaut.
`provenance` dit d'où vient chaque valeur.
"""
function geometrie_img(r, reglages)
    lire(cle) = get(reglages, cle, nothing)
    bords, pol, pt = lire("scan_borders"), lire("scan_polarity"), lire("pixel_time")
    pt === nothing || pt <= 1e-3 ||
        error("pixel_time = $pt dans reglages_spc.jl : il s'écrit en secondes (50 ns = 50e-9)")
    choix(ici, spcm, cle, defaut) =
        ici !== nothing ? (ici, "imagerie_reglages") :
        spcm !== nothing ? (spcm, "reglages_spc.jl, $cle") : (defaut, "valeur par défaut")
    c = (
        temps_pixel_ns = choix(r.temps_pixel_ns, pt === nothing ? nothing : pt * 1e9, "pixel_time", 50.0),
        pixels_par_ligne = choix(r.pixels_par_ligne, lire("scan_size_x"), "scan_size_x", 0),
        decalage_pixels = choix(r.decalage_pixels,
                                bords === nothing ? nothing : (Int(bords) >> 16) & 0xffff, "scan_borders", 0),
        lignes_par_image = choix(r.lignes_par_image, lire("scan_size_y"), "scan_size_y", 0),
        decalage_lignes = choix(r.decalage_lignes,
                                bords === nothing ? nothing : Int(bords) & 0xffff, "scan_borders", 0),
        ligne_front_montant = choix(r.ligne_front_montant,
                                    pol === nothing ? nothing : isodd(Int(pol)), "scan_polarity", true),
        trame_front_montant = choix(r.trame_front_montant,
                                    pol === nothing ? nothing : isodd(Int(pol) >> 1), "scan_polarity", true),
    )
    v = map(first, c)
    complet = merge(r, (temps_pixel_ns = Float64(v.temps_pixel_ns),
                        pixels_par_ligne = round(Int, v.pixels_par_ligne),
                        decalage_pixels = round(Int, v.decalage_pixels),
                        lignes_par_image = round(Int, v.lignes_par_image),
                        decalage_lignes = round(Int, v.decalage_lignes),
                        ligne_front_montant = Bool(v.ligne_front_montant),
                        trame_front_montant = Bool(v.trame_front_montant)))
    return complet, map(last, c)
end

function afficher_geometrie_img(r, provenance)
    println("Géométrie de l'image :")
    for (cle, texte) in ((:temps_pixel_ns, "temps de pixel (ns)"),
                         (:pixels_par_ligne, "pixels par ligne (0 : toute la ligne)"),
                         (:decalage_pixels, "bord gauche (pixels)"),
                         (:lignes_par_image, "lignes par image (0 : toutes)"),
                         (:decalage_lignes, "bord haut (lignes)"),
                         (:ligne_front_montant, "ligne (M1) sur front montant"),
                         (:trame_front_montant, "trame (M2) sur front montant"))
        x = getfield(r, cle)
        texte_x = x isa Bool ? (x ? "oui" : "non") : x isa AbstractFloat ? @sprintf("%.4g", x) : string(x)
        @printf("  %-38s %-6s (%s)\n", texte, texte_x, getfield(provenance, cle))
    end
end

# ---------------------------------------------------------------------
# Acquisition : on garde le flux brut, lu en continu sur chaque carte
# ---------------------------------------------------------------------

function acquerir_brut_img(modules, duree_s)
    bruts = Dict(m => UInt16[] for m in modules)
    deborde = Dict(m => false for m in modules)
    tampon = zeros(UInt16, 1 << 20)
    foreach(demarrer, modules)
    t0 = time()
    while time() - t0 < duree_s
        for m in modules
            n = lire_fifo!(m, tampon)
            append!(bruts[m], view(tampon, 1:n))
            (etat_mesure(m) & SPC_FOVFL) != 0 && (deborde[m] = true)
        end
        sleep(0.005)
    end
    for m in modules
        n = lire_fifo!(m, tampon)                  # avant l'arrêt, qui vide le FIFO
        append!(bruts[m], view(tampon, 1:n))
        arreter(m)
    end
    return bruts, deborde
end

"""Fichier .spc : en-tête B&H de 4 octets (SPC_get_fifo_init_vars), puis les mots FIFO."""
function ecrire_spc_img(chemin, entete::Integer, brut::Vector{UInt16})
    open(chemin, "w") do io
        write(io, htol(UInt32(entete)))
        write(io, htol.(brut))
    end
    return chemin
end

"""Relit un fichier .spc écrit par ecrire_spc_img : (en-tête, mots FIFO)."""
function lire_spc_img(chemin)
    octets = read(chemin)
    length(octets) >= 4 || error("$chemin : fichier trop court")
    entete = ltoh(reinterpret(UInt32, octets[1:4])[1])
    n = (length(octets) - 4) ÷ 2
    brut = ltoh.(collect(reinterpret(UInt16, octets[5:4 + 2n])))
    return entete, brut
end

"""Ce qu'il faut pour retraiter le .spc sans les cartes (relu par lire_ini)."""
function ecrire_acquisition_img(chemin, m, tic_s, fenetre_ns, duree_s, deborde)
    open(chemin, "w") do io
        println(io, "; écrit par imagerie_photons.jl, relu par retraiter_img")
        println(io, "[acquisition]")
        println(io, "module = ", Int(m))
        println(io, "tic_s = ", Float64(tic_s))
        println(io, "fenetre_ns = ", Float64(fenetre_ns))
        println(io, "duree_s = ", Float64(duree_s))
        println(io, "fifo_deborde = ", deborde ? 1 : 0)
    end
    return chemin
end

# ---------------------------------------------------------------------
# Rangement des photons dans les pixels
# ---------------------------------------------------------------------

mediane_img(v) = isempty(v) ? 0.0 : Float64(sort(v)[cld(length(v), 2)])

function centile_img(v, p)
    isempty(v) && return NaN
    s = sort(v)
    return Float64(s[clamp(round(Int, p / 100 * (length(s) - 1)) + 1, 1, length(s))])
end

"""
    ranger_photons(brut, tic_s, dt_ns, r) -> NamedTuple

Deux passes sur le flux brut. La première ne garde que les marqueurs, pour
mesurer la période de ligne et le nombre de lignes par trame. La seconde
décode par blocs et range chaque photon dans son pixel, sans garder les
photons en mémoire : la durée d'acquisition n'est limitée que par le flux brut.
"""
function ranger_photons(brut::Vector{UInt16}, tic_s, dt_ns, r)
    # Passe 1 : marqueurs seulement
    d1 = decoder!(Decodeur(), brut, length(brut))
    lignes, trames = d1.marqueurs[2], d1.marqueurs[3]
    nl, nt = length(lignes), length(trames)
    nl >= 2 || error("pas d'horloge de ligne sur M1 : scanner arrêté, ou mauvais marqueur")
    nt >= 1 || error("pas d'horloge de trame sur M2 : scanner arrêté, ou mauvais marqueur")
    periode = mediane_img(diff(lignes))                     # en tics
    rangs = [searchsortedfirst(lignes, t) for t in trames]  # 1re ligne après chaque trame
    lignes_trame = nt >= 2 ? round(Int, mediane_img(diff(rangs))) : nl - rangs[1] + 1
    # Colonnes calculées en entiers (dixièmes de ns) : en flottants, certains
    # rapports ne tombent pas juste (30e-9 / (100 × 1e-10) = 3,0000000000000004)
    # et un photon pile sur une frontière changerait de pixel.
    tic_01 = round(Int, tic_s * 1e10)                       # tic en dixièmes de ns
    pix_01 = round(Int, r.temps_pixel_ns * 10)              # pixel en dixièmes de ns
    (tic_01 > 0 && pix_01 > 0) || error("tic ($tic_s s) ou temps de pixel ($(r.temps_pixel_ns) ns) nul")
    pixels_ligne = fld(round(Int, periode) * tic_01, pix_01)   # pixels dans une période de ligne
    nx = r.pixels_par_ligne > 0 ? r.pixels_par_ligne : pixels_ligne - r.decalage_pixels
    ny = r.lignes_par_image > 0 ? r.lignes_par_image : lignes_trame - r.decalage_lignes
    (nx > 0 && ny > 0) || error("image vide ($nx × $ny) : vérifie decalage_pixels et decalage_lignes")
    nx * ny <= 1 << 26 || error("image de $nx × $ny pixels : trop grande, vérifie les réglages")

    # Passe 2 : photons, par blocs de 1 M mots
    intensite = zeros(UInt32, ny, nx)
    somme_t = zeros(Float64, ny, nx)
    d2 = Decodeur(garder_photons = true)
    k, j = 0, 1                   # dernière ligne passée, prochaine trame
    compteur = -1                 # -1 : avant la première trame, lignes ignorées
    y_cour, t_ligne = -1, Int64(0)
    dans_image = 0
    bloc = 1 << 20
    for debut in 1:bloc:length(brut)
        fin = min(debut + bloc - 1, length(brut))
        decoder!(d2, view(brut, debut:fin), fin - debut + 1)
        for (tp, adc) in zip(d2.t_photons, d2.adc_photons)
            while k < nl && lignes[k + 1] <= tp
                k += 1
                while j <= nt && trames[j] <= lignes[k]
                    compteur = 0          # nouvelle trame : cette ligne est la ligne 0
                    j += 1
                end
                y_cour = compteur
                compteur >= 0 && (compteur += 1)
                t_ligne = lignes[k]
            end
            k == 0 && continue
            y = y_cour - r.decalage_lignes
            (0 <= y < ny) || continue
            x = fld((tp - t_ligne) * tic_01, pix_01) - r.decalage_pixels
            (0 <= x < nx) || continue
            intensite[y + 1, x + 1] += 1
            somme_t[y + 1, x + 1] += (4095 - Int(adc) + 0.5) * dt_ns   # microtemps croissant
            dans_image += 1
        end
        empty!(d2.t_photons); empty!(d2.adc_photons); empty!(d2.routage_photons)
    end
    return (intensite = intensite, somme_t = somme_t, declin = reverse(d2.adc),
            photons = d2.photons, dans_image = dans_image, pertes = d2.pertes,
            trames = max(nt - 1, 0), lignes_trame = lignes_trame, pixels_ligne = pixels_ligne,
            periode_ligne_s = periode * tic_s, nx = nx, ny = ny)
end

# ---------------------------------------------------------------------
# Écriture des images (BMP 24 bits : aucune dépendance, s'ouvre partout)
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

function sommer_blocs_img(A, b)
    ny, nx = size(A, 1) ÷ b, size(A, 2) ÷ b
    return [sum(@view A[(i - 1) * b + 1:i * b, (j - 1) * b + 1:j * b]) for i in 1:ny, j in 1:nx]
end

"""Haut de l'échelle : 99,5e centile des valeurs non nulles, au moins 1."""
function haut_echelle_img(A)
    nz = filter(>(0), vec(A))
    return isempty(nz) ? 1.0 : max(1.0, centile_img(nz, 99.5))
end

function images_bmp(prefixe, res, r)
    I = Float64.(res.intensite)
    g = octet_img.(I ./ haut_echelle_img(I))
    ecrire_bmp_img(prefixe * "_intensite.bmp", g, g, g)

    b = clamp(r.binning_temps, 1, min(size(I)...))
    Sn = sommer_blocs_img(I, b)
    St = sommer_blocs_img(res.somme_t, b)
    seuil = max(r.photons_min, 1)
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

# ---------------------------------------------------------------------
# Traitement d'une acquisition (sans les cartes)
# ---------------------------------------------------------------------

function traiter_img(prefixe, brut, tic_s, fenetre_ns, duree_s, deborde, m, r)
    dt_ns = fenetre_ns / 4096
    res = ranger_photons(brut, tic_s, dt_ns, r)
    bas, haut = images_bmp(prefixe, res, r)
    t_ns = [(16(k - 1) + 8) * dt_ns for k in 1:256]
    regroupe = [sum(res.declin[16(k - 1) + 1:16k]) for k in 1:256]
    svg_declin_img(prefixe * "_declin.svg", t_ns, regroupe,
                   "Module $m : déclin de $(res.photons) photons")
    serialize(prefixe * ".jls", (intensite = res.intensite, somme_t = res.somme_t,
              declin = res.declin, dt_ns = dt_ns, periode_ligne_s = res.periode_ligne_s,
              lignes_trame = res.lignes_trame, trames = res.trames, reglages = r))

    println("\n== Module $m ==")
    @printf("  %d photons (%.3g /s), dont %d dans l'image ; pertes %d%s\n",
            res.photons, res.photons / duree_s, res.dans_image, res.pertes,
            deborde ? " ; FIFO DÉBORDÉ : baisse la lumière" : "")
    @printf("  Ligne : %.2f µs, soit %d pixels de %.0f ns ; %d lignes par trame ; %d trames\n",
            res.periode_ligne_s * 1e6, res.pixels_ligne, r.temps_pixel_ns, res.lignes_trame, res.trames)
    @printf("  Image %d × %d pixels ; fenêtre TAC %.3f ns\n", res.nx, res.ny, fenetre_ns)
    isnan(bas) || @printf("  Temps moyen (2e à 98e centile, binning %d) : %.3f à %.3f ns\n",
                          r.binning_temps, bas, haut)
    # Peigne du déclin (non-linéarité de l'ADC) : groupes de 1 à 16 canaux
    # (≤ 50 ps), signalé seulement au-dessus de 5 % et de 4 fois le bruit
    d = res.declin
    pic = maximum(d)
    if pic > 0
        seuil = max(1, pic ÷ 100)
        a, b = findfirst(>=(seuil), d), findlast(>=(seuil), d)
        gs = [g for g in (1, 2, 4, 8, 16) if g == 1 || g * dt_ns <= 0.05]
        nets = [(p = ecart_peigne(d, a, b, g); p.ecart > max(0.05, 4 * p.sigma) ? p.ecart : 0.0) for g in gs]
        ecart, ig = findmax(nets)
        @printf("  Déclin de %.2f à %.2f ns%s\n", (a - 1) * dt_ns, b * dt_ns,
                ecart > 0 ? @sprintf(" ; PEIGNE %.0f %% (groupes de %d canaux) : correction d'erreur de l'ADC coupée ?",
                                     100 * ecart, gs[ig]) : "")
    end
    println("  Fichiers : ", prefixe, "_intensite.bmp, _temps_moyen.bmp, _declin.svg, .jls")
    println("  Pour retraiter sans les cartes : rejouer = \"", basename(prefixe), "\"")
    return res
end

"""
    retraiter_img(nom, r)

Retraite une acquisition déjà faite avec les réglages `r` (décalages, taille
de l'image, binning…), sans toucher aux cartes. `nom` : par exemple
"20260929_153012_module0", ou un chemin complet sans extension.
"""
function retraiter_img(nom, r)
    prefixe = prefixe_img(nom)
    isfile(prefixe * ".spc") || error("introuvable : $(prefixe).spc")
    meta = lire_ini(prefixe * "_acquisition.ini"; section = "acquisition")
    _, brut = lire_spc_img(prefixe * ".spc")
    println("Retraitement de ", prefixe, ".spc, sans les cartes.")
    println("Aucune acquisition : reglages_spc.jl ne change rien à ces données (réglages de")
    println("l'acquisition : ", prefixe, "_parametres.ini). Pour mesurer à nouveau : rejouer = \"\".")
    return traiter_img(prefixe, brut, meta["tic_s"], meta["fenetre_ns"], meta["duree_s"],
                       get(meta, "fifo_deborde", 0.0) != 0, round(Int, get(meta, "module", -1.0)), r)
end

# ---------------------------------------------------------------------
# Programme
# ---------------------------------------------------------------------

function imagerie(r_demande, reglages)
    dossier = joinpath(@__DIR__, "resultats", "imagerie")
    mkpath(dossier)
    r, provenance = geometrie_img(r_demande, reglages)
    afficher_geometrie_img(r, provenance)
    front = 0x0600 |                                   # marqueurs M1 (ligne) et M2 (trame)
            (r.ligne_front_montant ? 0x2000 : 0x0000) |
            (r.trame_front_montant ? 0x4000 : 0x0000)
    imposes = Dict{String,Any}(                        # propres au mode FIFO de ce script
        "mode" => 1, "adc_resolution" => 12, "stop_on_time" => 0,
        "routing_mode" => Int(front), "macro_time_clk" => 0)
    p = merge(reglages, imposes)
    ini = ecrire_ini(joinpath(dossier, "imagerie.ini"), p)

    acq = avec_spc_tous(ini) do prets
        modules = Int16[m for m in r.modules if m in prets]
        isempty(modules) && error("aucune des cartes $(r.modules) n'est prête (prêtes : $(Int.(prets)))")
        for m in modules
            s = sync_etat(m)
            s == 1 || @warn "module $m : $(get(MESSAGES_SYNC, s, string(s)))"
        end
        infos = Dict(m => fifo_init(m) for m in modules)
        lus = Dict(m => lire_parametres(m; fichier = joinpath(dossier, "relu_$(m).ini")) for m in modules)
        for m in modules
            afficher_parametres(m, reglages, imposes, lus[m])   # ce que la carte a vraiment pris
            get(lus[m], "dither_range", NaN) == 0 &&
                @warn "module $m : dither_range = 0, la correction d'erreur de l'ADC est coupée : " *
                      "le déclin aura un peigne. Mets dans reglages_spc.jl la valeur de SPCM."
        end
        println("Acquisition de $(r.duree_s) s sur les modules $(Int.(modules))…")
        bruts, deborde = acquerir_brut_img(modules, r.duree_s)
        return (modules = modules, infos = infos, lus = lus, bruts = bruts, deborde = deborde)
    end

    # Les cartes sont libérées : tout le reste se fait hors ligne.
    horodatage = Dates.format(now(), "yyyymmdd_HHMMSS")
    for m in acq.modules
        prefixe = joinpath(dossier, "$(horodatage)_module$(m)")
        fenetre_ns = get(acq.lus[m], "tac_range", Float64(get(reglages, "tac_range", 50.0))) /
                     get(acq.lus[m], "tac_gain", Float64(get(reglages, "tac_gain", 1)))
        tic_s = acq.infos[m].horloge_macro_s
        ecrire_spc_img(prefixe * ".spc", acq.infos[m].entete, acq.bruts[m])
        ecrire_acquisition_img(prefixe * "_acquisition.ini", m, tic_s, fenetre_ns, r.duree_s, acq.deborde[m])
        releve = joinpath(dossier, "relu_$(m).ini")
        isfile(releve) && cp(releve, prefixe * "_parametres.ini"; force = true)
        try
            traiter_img(prefixe, acq.bruts[m], tic_s, fenetre_ns, r.duree_s, acq.deborde[m], m, r)
        catch err
            err isa InterruptException && rethrow()
            println("\n== Module $m ==")
            println("  Traitement impossible : ", sprint(showerror, err))
            println("  Le flux brut est gardé : ", prefixe, ".spc")
        end
    end
    return nothing
end

"""Préfixe complet d'une acquisition, à partir de son nom ou d'un chemin."""
function prefixe_img(nom)
    base = replace(nom, r"\.spc$"i => "")
    return occursin(r"[/\\]", base) ? (isabspath(base) ? base : joinpath(@__DIR__, base)) :
           joinpath(@__DIR__, "resultats", "imagerie", base)
end

"""
Retraite l'acquisition nommée dans `rejouer` avec la géométrie actuelle. Les
fronts de ligne et de trame, eux, ont été fixés par la carte à l'acquisition :
on les relit dans son _parametres.ini (routing_mode, bits 13 et 14).
"""
function rejouer_img(r_demande, reglages)
    r, provenance = geometrie_img(r_demande, reglages)
    fichier = prefixe_img(r_demande.rejouer) * "_parametres.ini"
    routage = isfile(fichier) ? get(lire_ini(fichier), "routing_mode", NaN) : NaN
    if !isnan(routage)
        bits = round(Int, routage)
        r = merge(r, (ligne_front_montant = (bits & 0x2000) != 0, trame_front_montant = (bits & 0x4000) != 0))
        provenance = merge(provenance, (ligne_front_montant = "acquisition", trame_front_montant = "acquisition"))
    end
    afficher_geometrie_img(r, provenance)
    return retraiter_img(r_demande.rejouer, r)
end

if isempty(imagerie_reglages.rejouer)
    imagerie(imagerie_reglages, REGLAGES_SPC)
else
    rejouer_img(imagerie_reglages, REGLAGES_SPC)
end
