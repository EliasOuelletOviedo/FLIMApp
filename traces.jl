# traces.jl — fichiers de données et tracés SVG, sans aucune dépendance externe.
# N'utilise que la bibliothèque standard de Julia (Printf, Dates).
# À inclure après sequence.jl (FS et bits du port 0).

using Printf, Dates

# =====================================================================
# Données : deux fichiers CSV, un échantillon par ligne
# =====================================================================

"""Écrit exactement ce qui a été envoyé aux sorties."""
function enregistrer_demande(fichier::AbstractString, res; fs = FS)
    open(fichier, "w") do io
        println(io, "echantillon,temps_s,galvo_x_V,galvo_y_V,p850_V,p1064_V,",
                    "port0,porte_850,porte_1064,imp_sequence,imp_region,code_region")
        for i in eachindex(res.x)
            b = res.d[i]
            @printf(io, "%d,%.5f,%.6f,%.6f,%.6f,%.6f,%d,%d,%d,%d,%d,%d\n",
                    i, (i - 1) / fs, res.x[i], res.y[i], res.p850[i], res.p1064[i],
                    b, (b >> B_850) & 1, (b >> B_1064) & 1,
                    (b >> B_SEQ) & 1, (b >> B_REG) & 1, b >> 4)
        end
    end
    return fichier
end

"""Écrit exactement ce que la 6321 a relu."""
function enregistrer_recu(fichier::AbstractString, res; fs = FS)
    m = res.mesure
    open(fichier, "w") do io
        println(io, "echantillon,temps_s,ai0_galvo_x_V,ai1_porte_850_V,ai2_p850_V,ai3_p1064_V")
        for i in 1:size(m, 1)
            @printf(io, "%d,%.5f,%.6f,%.6f,%.6f,%.6f\n",
                    i, (i - 1) / fs, m[i, 1], m[i, 2], m[i, 3], m[i, 4])
        end
    end
    return fichier
end

# =====================================================================
# Tracés SVG
# =====================================================================

const PALETTE = (galvo_x = "#1d4ed8", galvo_y = "#0e7490", p850 = "#c2410c",
                 p1064 = "#be123c", porte = "#334155", code = "#6d28d9",
                 consigne = "#15803d", estime = "#7c3aed", vrai = "#0f172a",
                 mesure = "#64748b")

xml(s) = replace(string(s), "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", "\"" => "&quot;")

"""Graduations « rondes » (1, 2, 5 × 10^k) entre a et b. Renvoie (valeurs, pas)."""
function graduations(a::Real, b::Real; cible::Integer = 5)
    b > a || return ([float(a)], 1.0)
    brut = (b - a) / cible
    p = 10.0^floor(log10(brut))
    f = brut / p
    pas = (f < 1.5 ? 1.0 : f < 3.0 ? 2.0 : f < 7.0 ? 5.0 : 10.0) * p
    k0 = ceil(Int, a / pas - 1e-9)
    k1 = floor(Int, b / pas + 1e-9)
    return ([k * pas for k in k0:k1], pas)
end

function graduations_entieres(a::Real, b::Real)
    pas = max(1, ceil(Int, (b - a) / 4))
    return (Float64.(collect(ceil(Int, a):pas:floor(Int, b))), float(pas))
end

"""Libellé d'une graduation : même nombre de décimales partout, virgule décimale."""
function etiquette(v::Real, pas::Real)
    v == 0 && (v = 0.0)
    d = max(0, ceil(Int, -log10(pas) - 1e-9))
    txt = d == 0 ? string(round(Int, v)) : Printf.format(Printf.Format("%.$(d)f"), float(v))
    return replace(txt, "." => ",")
end

"""
    serie(nom, t, v, couleur; mode=:ligne, epaisseur=1.4)

Une courbe. `t` doit être croissant. Modes :
- `:escalier` — chaque valeur est tenue jusqu'à la suivante (sortie d'un convertisseur) ;
- `:points`   — échantillons reliés, avec un point chacun quand on zoome assez ;
- `:ligne`    — échantillons reliés ;
- `:marques`  — points seuls (mesures ponctuelles).
"""
serie(nom, t, v, couleur; mode = :ligne, epaisseur = 1.4) =
    (; nom = string(nom), t, v, couleur, mode, epaisseur)

"""Un panneau du graphique : une ou plusieurs séries partageant un axe vertical."""
panneau(titre, series; unite = "", numerique = false, entier = false,
        hauteur = 150, yplage = nothing) =
    (; titre = string(titre), series, unite = string(unite), numerique, entier, hauteur, yplage)

"""Nombre d'échantillons d'une série dans la fenêtre [ta, tb]."""
function dans_fenetre(s, ta, tb)
    i0 = searchsortedfirst(s.t, ta)
    i1 = searchsortedlast(s.t, tb)
    return i0, i1
end

"""
Écrit le tracé d'une série. Si la fenêtre contient plus d'échantillons que de
pixels, chaque colonne de pixels montre le premier, le minimum, le maximum et
le dernier des échantillons qu'elle couvre : aucun extrême n'est perdu.
"""
function trace_serie(io, s, ta, tb, X, Y, largeur_px)
    t, v = s.t, s.v
    i0, i1 = dans_fenetre(s, ta, tb)
    i1 < i0 && return 0
    n = i1 - i0 + 1

    if s.mode == :marques
        for i in i0:i1
            @printf(io, "<circle cx=\"%.2f\" cy=\"%.2f\" r=\"2.4\" fill=\"%s\" fill-opacity=\"0.75\"/>\n",
                    X(t[i]), Y(v[i]), s.couleur)
        end
        return n
    end

    d = IOBuffer()
    if n <= largeur_px
        if s.mode == :escalier
            @printf(d, "M%.2f,%.2f", X(t[i0]), Y(v[i0]))
            for i in i0+1:i1
                @printf(d, "H%.2fV%.2f", X(t[i]), Y(v[i]))
            end
            fin = i1 < length(t) ? min(t[i1 + 1], tb) : tb
            @printf(d, "H%.2f", X(fin))
        else
            for i in i0:i1
                @printf(d, "%s%.2f,%.2f", i == i0 ? "M" : "L", X(t[i]), Y(v[i]))
            end
        end
    else
        ncol = max(1, floor(Int, largeur_px))
        dt = (tb - ta) / ncol
        premier = true
        for c in 0:ncol-1
            a = max(i0, searchsortedfirst(t, ta + c * dt))
            b = c == ncol - 1 ? i1 : min(i1, searchsortedfirst(t, ta + (c + 1) * dt) - 1)
            b < a && continue
            seg = view(v, a:b)
            jmin, jmax = argmin(seg), argmax(seg)
            x = X(ta + (c + 0.5) * dt)
            quatre = jmin <= jmax ? (seg[1], seg[jmin], seg[jmax], seg[end]) :
                                    (seg[1], seg[jmax], seg[jmin], seg[end])
            for w in quatre
                @printf(d, "%s%.2f,%.2f", premier ? "M" : "L", x, Y(w))
                premier = false
            end
        end
    end
    @printf(io, "<path d=\"%s\" fill=\"none\" stroke=\"%s\" stroke-width=\"%.2f\" stroke-linejoin=\"round\"/>\n",
            String(take!(d)), s.couleur, s.epaisseur)

    if s.mode == :points && n <= largeur_px / 5
        for i in i0:i1
            @printf(io, "<circle cx=\"%.2f\" cy=\"%.2f\" r=\"1.9\" fill=\"%s\"/>\n",
                    X(t[i]), Y(v[i]), s.couleur)
        end
    end
    return n
end

"""
    figure_svg(fichier, titre, sous_titre, panneaux; t0, t1, marqueurs, etiquettes)

Empile les panneaux sur un axe du temps commun et écrit le fichier SVG.
`marqueurs` : instants (s) tracés en pointillés sur tous les panneaux,
`etiquettes` : leur libellé, affiché en haut du premier panneau.
"""
function figure_svg(fichier::AbstractString, titre, sous_titre, panneaux;
                    t0 = -Inf, t1 = Inf, marqueurs = Float64[], etiquettes = String[],
                    largeur::Integer = 1400)
    tmin = minimum(first(s.t) for p in panneaux for s in p.series)
    tmax = maximum(last(s.t) for p in panneaux for s in p.series)
    ta, tb = max(float(t0), tmin), min(float(t1), tmax)
    tb > ta || error("fenêtre de temps vide : [$ta, $tb]")

    G, D, HT, HA, ESP, BT = 150, 40, 96, 64, 14, 22     # BT : bandeau de titre
    W = largeur - G - D
    hauteur = HT + sum(BT + p.hauteur for p in panneaux) + ESP * (length(panneaux) - 1) + HA
    en_ms = (tb - ta) < 2.0
    k = en_ms ? 1000.0 : 1.0
    X = t -> G + (t - ta) / (tb - ta) * W
    xt, xpas = graduations(ta * k, tb * k; cible = 10)
    fenetre = @sprintf("fenêtre %s à %s %s", etiquette(ta * k, xpas / 10), etiquette(tb * k, xpas / 10),
                       en_ms ? "ms" : "s")
    reduit = false

    open(fichier, "w") do io
        println(io, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
        @printf(io, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%d\" height=\"%d\" viewBox=\"0 0 %d %d\" font-family=\"Segoe UI, Helvetica, Arial, sans-serif\" font-size=\"12\">\n",
                largeur, hauteur, largeur, hauteur)
        println(io, "<rect width=\"100%\" height=\"100%\" fill=\"#ffffff\"/>")
        @printf(io, "<text x=\"%d\" y=\"34\" font-size=\"20\" font-weight=\"bold\" fill=\"#0f172a\">%s</text>\n",
                G, xml(titre))
        @printf(io, "<text x=\"%d\" y=\"58\" font-size=\"12.5\" fill=\"#475569\">%s</text>\n",
                G, xml(isempty(sous_titre) ? fenetre : string(sous_titre, " — ", fenetre)))

        y = HT
        for (ip, p) in enumerate(panneaux)
            h = p.hauteur
            # titre dans un bandeau au-dessus du panneau : il ne masque jamais une donnée
            @printf(io, "<text x=\"%d\" y=\"%d\" font-size=\"12.5\" font-weight=\"bold\" fill=\"#0f172a\">%s</text>\n",
                    G, y + 15, xml(p.titre))
            y += BT
            @printf(io, "<rect x=\"%d\" y=\"%d\" width=\"%d\" height=\"%d\" fill=\"#f8fafc\" stroke=\"#cbd5e1\"/>\n",
                    G, y, W, h)
            for tv in xt
                @printf(io, "<line x1=\"%.2f\" y1=\"%d\" x2=\"%.2f\" y2=\"%d\" stroke=\"#e2e8f0\"/>\n",
                        X(tv / k), y, X(tv / k), y + h)
            end
            visibles = [j for j in eachindex(marqueurs) if ta <= marqueurs[j] <= tb]
            if length(visibles) <= 80
                for j in visibles
                    @printf(io, "<line x1=\"%.2f\" y1=\"%d\" x2=\"%.2f\" y2=\"%d\" stroke=\"#94a3b8\" stroke-dasharray=\"4,3\"/>\n",
                            X(marqueurs[j]), y, X(marqueurs[j]), y + h)
                    if ip == 1 && j <= length(etiquettes) && length(visibles) <= 40
                        @printf(io, "<text x=\"%.2f\" y=\"%d\" font-size=\"10.5\" fill=\"#64748b\">%s</text>\n",
                                X(marqueurs[j]) + 3, HT - 6, xml(etiquettes[j]))
                    end
                end
            end

            if p.numerique
                hr = (h - 8) / length(p.series)
                for (j, s) in enumerate(p.series)
                    base = y + 4 + (j - 1) * hr
                    Yj = w -> base + hr * (0.82 - 0.64 * w)
                    @printf(io, "<text x=\"%d\" y=\"%.2f\" text-anchor=\"end\" fill=\"#334155\">%s</text>\n",
                            G - 10, base + hr * 0.62, xml(s.nom))
                    n = trace_serie(io, s, ta, tb, X, Yj, W)
                    reduit = reduit || n > W
                end
            else
                if p.yplage === nothing
                    lo, hi = Inf, -Inf
                    for s in p.series
                        i0, i1 = dans_fenetre(s, ta, tb)
                        i1 >= i0 || continue
                        a, b = extrema(view(s.v, i0:i1))
                        lo = min(lo, a)
                        hi = max(hi, b)
                    end
                    if !isfinite(lo)
                        lo, hi = 0.0, 1.0
                    end
                else
                    lo, hi = float.(p.yplage)
                end
                if hi - lo < 1e-9
                    lo -= 0.5
                    hi += 0.5
                end
                marge = 0.08 * (hi - lo)
                lo -= marge
                hi += marge
                Yp = w -> y + h - (w - lo) / (hi - lo) * h
                yt, ypas = p.entier ? graduations_entieres(lo, hi) : graduations(lo, hi; cible = 4)
                for v in yt
                    @printf(io, "<line x1=\"%d\" y1=\"%.2f\" x2=\"%d\" y2=\"%.2f\" stroke=\"#e2e8f0\"/>\n",
                            G, Yp(v), G + W, Yp(v))
                    @printf(io, "<text x=\"%d\" y=\"%.2f\" text-anchor=\"end\" fill=\"#475569\">%s</text>\n",
                            G - 8, Yp(v) + 4, etiquette(v, ypas))
                end
                if !isempty(p.unite)
                    @printf(io, "<text transform=\"translate(%d,%.2f) rotate(-90)\" text-anchor=\"middle\" fill=\"#475569\">%s</text>\n",
                            G - 58, y + h / 2, xml(p.unite))
                end
                for s in p.series
                    n = trace_serie(io, s, ta, tb, X, Yp, W)
                    reduit = reduit || n > W
                end
                if length(p.series) > 1
                    xl = G + W
                    for (j, s) in enumerate(reverse(p.series))
                        largeur_txt = 7 * length(s.nom) + 30
                        yl = y - BT + 15
                        if s.mode == :marques
                            @printf(io, "<circle cx=\"%.1f\" cy=\"%d\" r=\"3\" fill=\"%s\"/>\n",
                                    xl - largeur_txt + 13, yl - 4, s.couleur)
                        else
                            @printf(io, "<line x1=\"%.1f\" y1=\"%d\" x2=\"%.1f\" y2=\"%d\" stroke=\"%s\" stroke-width=\"2.5\"/>\n",
                                    xl - largeur_txt + 5, yl - 4, xl - largeur_txt + 21, yl - 4, s.couleur)
                        end
                        @printf(io, "<text x=\"%.1f\" y=\"%d\" fill=\"#334155\">%s</text>\n",
                                xl - largeur_txt + 26, yl, xml(s.nom))
                        xl -= largeur_txt + 8
                    end
                end
            end

            y += h + ESP
        end

        ybas = y - ESP
        for tv in xt
            @printf(io, "<text x=\"%.2f\" y=\"%d\" text-anchor=\"middle\" fill=\"#475569\">%s</text>\n",
                    X(tv / k), ybas + 18, etiquette(tv, xpas))
        end
        @printf(io, "<text x=\"%.1f\" y=\"%d\" text-anchor=\"middle\" fill=\"#334155\">Temps (%s)</text>\n",
                G + W / 2, ybas + 40, en_ms ? "ms" : "s")
        if reduit
            @printf(io, "<text x=\"%d\" y=\"%d\" text-anchor=\"end\" font-size=\"11\" fill=\"#64748b\">%s</text>\n",
                    G + W, ybas + 58,
                    "Vue d'ensemble : chaque colonne de pixels montre le min et le max des échantillons qu'elle couvre. Réduis la fenêtre (t0, t1) pour voir chaque échantillon.")
        end
        println(io, "</svg>")
    end
    return fichier
end

# =====================================================================
# Figures du générateur continu
# =====================================================================

function marqueurs_creneaux(res; fs = FS)
    return ([(e.debut - 1) / fs for e in res.journal],
            ["R$(e.region) · v$(e.visite)" for e in res.journal])
end

"""Tout ce qui a été écrit : galvos, puissances, port 0, code de région."""
function tracer_demande(fichier::AbstractString, res; t0 = -Inf, t1 = Inf,
                        sous_titre = "", fs = FS)
    t = collect(0:length(res.x)-1) ./ fs
    bitv = k -> Float64.((res.d .>> k) .& 0x01)
    code = Float64.(res.d .>> 4)
    panneaux = [
        panneau("Galvo X", [serie("galvo X", t, res.x, PALETTE.galvo_x; mode = :escalier)]; unite = "V"),
        panneau("Galvo Y", [serie("galvo Y", t, res.y, PALETTE.galvo_y; mode = :escalier)]; unite = "V"),
        panneau("Puissance 850 nm (commande)",
                [serie("P850", t, res.p850, PALETTE.p850; mode = :escalier)]; unite = "V", hauteur = 110),
        panneau("Pockels 1064 nm (commande)",
                [serie("P1064", t, res.p1064, PALETTE.p1064; mode = :escalier)]; unite = "V", hauteur = 110),
        panneau("Port 0 — portes et impulsions",
                [serie("porte 850 · P0.0", t, bitv(B_850), PALETTE.porte; mode = :escalier),
                 serie("porte 1064 · P0.1", t, bitv(B_1064), PALETTE.porte; mode = :escalier),
                 serie("début séquence · P0.2", t, bitv(B_SEQ), PALETTE.porte; mode = :escalier),
                 serie("début région · P0.3", t, bitv(B_REG), PALETTE.porte; mode = :escalier)];
                numerique = true, hauteur = 124),
        panneau("Code de région · P0.4 à P0.7 (0 = région 1)",
                [serie("code", t, code, PALETTE.code; mode = :escalier)]; unite = "code", entier = true, hauteur = 96),
    ]
    mq, et = marqueurs_creneaux(res; fs)
    return figure_svg(fichier, "Demandé — ce qui a été écrit sur les sorties", sous_titre, panneaux;
                      t0, t1, marqueurs = mq, etiquettes = et)
end

"""Tout ce que la 6321 a relu, échantillon par échantillon."""
function tracer_recu(fichier::AbstractString, res; t0 = -Inf, t1 = Inf,
                     sous_titre = "", fs = FS)
    m = res.mesure
    t = collect(0:size(m, 1)-1) ./ fs
    panneaux = [
        panneau("AI 0 — galvo X relu", [serie("AI 0", t, m[:, 1], PALETTE.galvo_x; mode = :points)]; unite = "V"),
        panneau("AI 1 — porte 850 nm relue (P0.0)",
                [serie("AI 1", t, m[:, 2], PALETTE.porte; mode = :points)]; unite = "V", hauteur = 110),
        panneau("AI 2 — puissance 850 nm relue",
                [serie("AI 2", t, m[:, 3], PALETTE.p850; mode = :points)]; unite = "V", hauteur = 110),
        panneau("AI 3 — Pockels 1064 nm relue",
                [serie("AI 3", t, m[:, 4], PALETTE.p1064; mode = :points)]; unite = "V", hauteur = 110),
    ]
    mq, et = marqueurs_creneaux(res; fs)
    return figure_svg(fichier, "Reçu — ce que la 6321 a relu", sous_titre, panneaux;
                      t0, t1, marqueurs = mq, etiquettes = et)
end

"""
    enregistrer_essai(res; nom, dossier="resultats", infos="", zooms=[])

Écrit, avec un horodatage commun :
- `…_demande.csv` et `…_recu.csv` : les données brutes ;
- `…_demande.svg` et `…_recu.svg` : les tracés sur la même fenêtre de temps ;
- pour chaque `(t0, t1)` de `zooms`, une paire de tracés agrandis.
"""
function enregistrer_essai(res; nom = "essai", dossier = "resultats", infos = "",
                           zooms = Tuple{Float64, Float64}[])
    mkpath(dossier)
    base = joinpath(dossier, string(nom, "_", Dates.format(now(), "yyyy-mm-dd_HH-MM-SS")))
    fin = (size(res.mesure, 1) - 1) / FS
    fichiers = String[]
    push!(fichiers, enregistrer_demande(base * "_demande.csv", res))
    push!(fichiers, enregistrer_recu(base * "_recu.csv", res))
    push!(fichiers, tracer_demande(base * "_demande.svg", res; t1 = fin, sous_titre = infos))
    push!(fichiers, tracer_recu(base * "_recu.svg", res; t1 = fin, sous_titre = infos))
    for (j, (a, b)) in enumerate(zooms)
        push!(fichiers, tracer_demande(base * "_zoom$(j)_demande.svg", res; t0 = a, t1 = b, sous_titre = infos))
        push!(fichiers, tracer_recu(base * "_zoom$(j)_recu.svg", res; t0 = a, t1 = b, sous_titre = infos))
    end
    return fichiers
end

# =====================================================================
# Boucle fermée : une ligne par visite
# =====================================================================

"""Écrit le journal de la boucle (une ligne par visite de région)."""
function enregistrer_boucle(fichier::AbstractString, jb)
    open(fichier, "w") do io
        println(io, join(keys(first(jb)), ","))
        for e in jb
            println(io, join([x isa AbstractFloat ? @sprintf("%.6f", x) : string(x) for x in e], ","))
        end
    end
    return fichier
end

"""
    tracer_boucle(fichier, jb, R; consignes, t_maintien, t_relache, umax, taus, sous_titre)

Pour chaque région : chlorure (vrai si simulé, mesuré, estimé, consigne) et
puissance 1064 nm (commandée, et réellement produite d'après AI 3).
"""
function tracer_boucle(fichier::AbstractString, jb, R::Integer; consignes, t_maintien,
                       t_relache, umax, taus = nothing, sous_titre = "")
    panneaux = Any[]
    for k in 1:R
        lignes = [e for e in jb if e.region == k]
        t = [e.t for e in lignes]
        chl = Any[]
        if haskey(first(lignes), :vrai)
            push!(chl, serie("vrai (simulé)", t, [e.vrai for e in lignes], PALETTE.vrai; epaisseur = 1.6))
        end
        push!(chl, serie("mesuré", t, [e.mesure for e in lignes], PALETTE.mesure; mode = :marques))
        push!(chl, serie("estimé", t, [e.estime for e in lignes], PALETTE.estime; epaisseur = 1.1))
        push!(chl, serie("consigne", [t_maintien, t_relache], [consignes[k], consignes[k]],
                         PALETTE.consigne; epaisseur = 2.0))
        titre = taus === nothing ? "Région $k — chlorure" : "Région $k — chlorure (τ = $(taus[k]) s)"
        push!(panneaux, panneau(titre, chl; unite = "mM", hauteur = 150))
        push!(panneaux, panneau("Région $k — puissance 1064 nm",
            [serie("commandée", t, [e.u_cmd for e in lignes], PALETTE.p1064; mode = :escalier, epaisseur = 1.6),
             serie("produite (AI 3)", t, [e.u_mes for e in lignes], PALETTE.porte; mode = :marques)];
            unite = "V", hauteur = 90, yplage = (0.0, umax)))
    end
    return figure_svg(fichier, "Boucle fermée — clamp du chlorure", sous_titre, panneaux;
                      marqueurs = [t_maintien, t_relache], etiquettes = ["maintien", "relâchement"])
end
