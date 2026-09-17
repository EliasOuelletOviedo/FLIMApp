# traces.jl — fichiers de données et tracés SVG, sans aucune dépendance externe.
# N'utilise que la bibliothèque standard de Julia (Printf, Dates).
# À inclure après sequence.jl et generateur.jl (FS, SIGNAUX, valeurs_demandees).

using Printf, Dates

# =====================================================================
# Données : deux fichiers CSV, un échantillon par ligne
# =====================================================================

"""Écrit exactement ce qui a été envoyé sur toutes les sorties, analogiques et numériques."""
function enregistrer_demande(fichier::AbstractString, res; fs = FS, signaux = SIGNAUX)
    voies = [valeurs_demandees(res, s) for s in signaux]
    entetes = [s.bit === nothing ? "$(s.cle)_V" : string(s.cle) for s in signaux]
    open(fichier, "w") do io
        println(io, "echantillon,temps_s,", join(entetes, ","), ",port0,code_region")
        for i in eachindex(res.x)
            @printf(io, "%d,%.5f", i, (i - 1) / fs)
            for (s, v) in zip(signaux, voies)
                if s.bit === nothing
                    @printf(io, ",%.6f", v[i])
                else
                    print(io, v[i] > 0.5 ? ",1" : ",0")
                end
            end
            @printf(io, ",%d,%d\n", res.d[i], res.d[i] >> 4)
        end
    end
    return fichier
end

"""Écrit exactement ce que la 6321 a relu, une colonne par voie AI."""
function enregistrer_recu(fichier::AbstractString, res; fs = FS, signaux = SIGNAUX)
    lus = sort([s for s in signaux if haskey(res.colonne, s.cle)]; by = s -> s.ai)
    m = res.mesure
    open(fichier, "w") do io
        println(io, "echantillon,temps_s,", join(["ai$(s.ai)_$(s.cle)_V" for s in lus], ","))
        for i in 1:size(m, 1)
            @printf(io, "%d,%.5f", i, (i - 1) / fs)
            for s in lus
                @printf(io, ",%.5f", m[i, res.colonne[s.cle]])
            end
            print(io, "\n")
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
                 mesure = "#64748b", relu = "#0f172a")

"""Couleur d'un signal, la même dans les trois figures."""
couleur_signal(s) = s.cle === :galvo_x ? PALETTE.galvo_x :
                    s.cle === :galvo_y ? PALETTE.galvo_y :
                    s.cle === :p850    ? PALETTE.p850 :
                    s.cle === :p1064   ? PALETTE.p1064 :
                    startswith(string(s.cle), "code") ? PALETTE.code : PALETTE.porte

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
    serie(nom, t, v, couleur; mode=:ligne, epaisseur=1.4, ligne=0)

Une courbe. `t` doit être croissant, et peut être vide : rien n'est alors tracé.
Modes : `:escalier` (valeur tenue jusqu'à la suivante, comme une sortie de
convertisseur), `:points` (échantillons reliés, avec un point chacun quand on
zoome assez), `:ligne`, `:marques` (points seuls). `ligne` place la courbe sur
une rangée précise d'un panneau numérique (0 : une rangée par courbe).
"""
serie(nom, t, v, couleur; mode = :ligne, epaisseur = 1.4, ligne = 0) =
    (; nom = string(nom), t, v, couleur, mode, epaisseur, ligne)

"""
Un panneau : une ou plusieurs séries partageant un axe vertical. Un panneau
`numerique` empile des rangées ; `etiquettes` donne leurs libellés et
`plage_ligne` la valeur qui remplit une rangée (1 pour des bits, 5 pour des volts).
"""
panneau(titre, series; unite = "", numerique = false, entier = false,
        hauteur = 150, yplage = nothing, etiquettes = String[], plage_ligne = 1.0) =
    (; titre = string(titre), series, unite = string(unite), numerique, entier,
       hauteur, yplage, etiquettes, plage_ligne)

"""Bornes (en indices) d'une série dans la fenêtre [ta, tb]."""
function dans_fenetre(s, ta, tb)
    isempty(s.t) && return (1, 0)
    return (searchsortedfirst(s.t, ta), searchsortedlast(s.t, tb))
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
`marqueurs` : instants (s) tracés en pointillés sur tous les panneaux ;
`etiquettes` : leur libellé, affiché au-dessus du premier panneau.
"""
function figure_svg(fichier::AbstractString, titre, sous_titre, panneaux;
                    t0 = -Inf, t1 = Inf, marqueurs = Float64[], etiquettes = String[],
                    largeur::Integer = 1400)
    pleines = [s for p in panneaux for s in p.series if !isempty(s.t)]
    isempty(pleines) && error("aucune donnée à tracer")
    tmin = minimum(first(s.t) for s in pleines)
    tmax = maximum(last(s.t) for s in pleines)
    ta, tb = max(float(t0), tmin), min(float(t1), tmax)
    tb > ta || error("fenêtre de temps vide : [$ta, $tb]")

    G, D, HT, HA, ESP, BT = 250, 40, 96, 64, 14, 22     # BT : bandeau de titre
    W = largeur - G - D
    hauteur = HT + sum(BT + p.hauteur for p in panneaux) + ESP * (length(panneaux) - 1) + HA
    en_ms = (tb - ta) < 2.0
    k = en_ms ? 1000.0 : 1.0
    X = t -> G + (t - ta) / (tb - ta) * W
    xt, xpas = graduations(ta * k, tb * k; cible = 10)
    fenetre = @sprintf("fenêtre %s à %s %s", etiquette(ta * k, xpas / 10),
                       etiquette(tb * k, xpas / 10), en_ms ? "ms" : "s")
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
            @printf(io, "<text x=\"%d\" y=\"%d\" font-size=\"12.5\" font-weight=\"bold\" fill=\"#0f172a\">%s</text>\n",
                    G, y + 15, xml(isempty(p.unite) ? p.titre : string(p.titre, "  (", p.unite, ")")))
            if length(p.series) > 1 && !p.numerique
                xl = G + W
                for s in reverse(p.series)
                    largeur_txt = 7 * length(s.nom) + 30
                    if s.mode == :marques
                        @printf(io, "<circle cx=\"%.1f\" cy=\"%d\" r=\"3\" fill=\"%s\"/>\n",
                                xl - largeur_txt + 13, y + 11, s.couleur)
                    else
                        @printf(io, "<line x1=\"%.1f\" y1=\"%d\" x2=\"%.1f\" y2=\"%d\" stroke=\"%s\" stroke-width=\"2.5\"/>\n",
                                xl - largeur_txt + 5, y + 11, xl - largeur_txt + 21, y + 11, s.couleur)
                    end
                    @printf(io, "<text x=\"%.1f\" y=\"%d\" fill=\"#334155\">%s</text>\n",
                            xl - largeur_txt + 26, y + 15, xml(s.nom))
                    xl -= largeur_txt + 8
                end
            end
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

            if all(isempty(s.t) for s in p.series)
                @printf(io, "<text x=\"%.1f\" y=\"%.1f\" text-anchor=\"middle\" font-size=\"12\" fill=\"#94a3b8\">non relu</text>\n",
                        G + W / 2, y + h / 2 + 4)
            elseif p.numerique
                noms = isempty(p.etiquettes) ? [s.nom for s in p.series] : p.etiquettes
                hr = (h - 8) / length(noms)
                for (j, nom) in enumerate(noms)
                    @printf(io, "<line x1=\"%d\" y1=\"%.2f\" x2=\"%d\" y2=\"%.2f\" stroke=\"#e2e8f0\"/>\n",
                            G, y + 4 + j * hr, G + W, y + 4 + j * hr)
                    @printf(io, "<text x=\"%d\" y=\"%.2f\" text-anchor=\"end\" fill=\"#334155\">%s</text>\n",
                            G - 10, y + 4 + (j - 1) * hr + hr * 0.62, xml(nom))
                end
                for (idx, s) in enumerate(p.series)
                    j = s.ligne == 0 ? idx : s.ligne
                    base = y + 4 + (j - 1) * hr
                    Yj = w -> base + hr * (0.82 - 0.64 * w / p.plage_ligne)
                    nn = trace_serie(io, s, ta, tb, X, Yj, W)
                    reduit = reduit || nn > W
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
                for s in p.series
                    nn = trace_serie(io, s, ta, tb, X, Yp, W)
                    reduit = reduit || nn > W
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
# Les trois figures d'un essai : même disposition dans les trois
# =====================================================================

function marqueurs_creneaux(res; fs = FS)
    return ([(e.debut - 1) / fs for e in res.journal],
            ["R$(e.region) · v$(e.visite)" for e in res.journal])
end

"""Niveau haut d'une ligne numérique relue, pour superposer sans écart vertical."""
niveau_haut(v) = maximum(v) > 1.0 ? maximum(v) : 1.0

"""
    panneaux_essai(res, quoi; decalage=0)

Construit les panneaux d'un essai. `quoi` vaut `:demande`, `:recu` ou
`:comparaison`. Les trois donnent exactement la même disposition — même ordre,
mêmes hauteurs, mêmes libellés — puisqu'ils sortent de la même fonction.
`decalage` avance la relecture de N échantillons, pour comparer sans le retard
de conversion.
"""
function panneaux_essai(res, quoi::Symbol; fs = FS, signaux = SIGNAUX, decalage::Integer = 0)
    t_ecrit = collect(0:length(res.x)-1) ./ fs
    t_lu = collect(0:size(res.mesure, 1)-1) ./ fs .- decalage / fs
    rien = Float64[]
    panneaux = Any[]

    for s in signaux
        s.bit === nothing || continue
        lu = haskey(res.colonne, s.cle)
        series = Any[]
        if quoi !== :recu
            push!(series, serie(quoi === :comparaison ? "demandé" : s.nom, t_ecrit,
                                valeurs_demandees(res, s), couleur_signal(s);
                                mode = :escalier, epaisseur = 1.4))
        end
        if quoi !== :demande
            push!(series, serie(quoi === :comparaison ? "relu" : "AI $(s.ai)",
                                lu ? t_lu : rien,
                                lu ? res.mesure[:, res.colonne[s.cle]] : rien,
                                quoi === :comparaison ? PALETTE.relu : couleur_signal(s);
                                mode = :points, epaisseur = 1.2))
        end
        push!(panneaux, panneau("$(s.nom) — $(s.sortie)" * (lu ? " → AI $(s.ai)" : ""),
                                series; unite = "V",
                                hauteur = s.cle in (:galvo_x, :galvo_y) ? 150 : 115))
    end

    numeriques = [s for s in signaux if s.bit !== nothing]
    noms = ["$(s.nom) · $(s.sortie)" * (haskey(res.colonne, s.cle) ? " → AI $(s.ai)" : "")
            for s in numeriques]
    lignes = Any[]
    for (j, s) in enumerate(numeriques)
        lu = haskey(res.colonne, s.cle)
        if quoi !== :recu
            push!(lignes, serie("demandé", t_ecrit, valeurs_demandees(res, s),
                                couleur_signal(s); mode = :escalier, epaisseur = 1.3, ligne = j))
        end
        if quoi !== :demande && lu
            v = res.mesure[:, res.colonne[s.cle]]
            # En comparaison, la relecture est ramenée entre 0 et 1 par son propre
            # niveau haut : les deux courbes se superposent alors exactement si le
            # timing suit, et seul un écart de temps se voit.
            push!(lignes, serie("relu", t_lu, quoi === :comparaison ? v ./ niveau_haut(v) : v,
                                quoi === :comparaison ? PALETTE.relu : couleur_signal(s);
                                mode = :points, epaisseur = 1.1, ligne = j))
        end
    end
    titre_num = quoi === :recu ? "Port 0 — les huit lignes relues (une rangée par ligne, plage 0 à 5 V)" :
                quoi === :comparaison ? "Port 0 — les huit lignes, demandé et relu superposés" :
                "Port 0 — les huit lignes écrites"
    push!(panneaux, panneau(titre_num,
                            isempty(lignes) ? Any[serie("", rien, rien, PALETTE.porte)] : lignes;
                            numerique = true, hauteur = 30 * length(numeriques) + 8,
                            etiquettes = noms,
                            plage_ligne = quoi === :recu ? 5.0 : 1.0))
    return panneaux
end

const TITRES_ESSAI = (demande = "Demandé — ce qui a été écrit sur les sorties",
                      recu = "Reçu — ce que la 6321 a relu",
                      comparaison = "Comparaison — demandé et relu superposés")

function tracer_essai(fichier::AbstractString, res, quoi::Symbol; t0 = -Inf, t1 = Inf,
                      sous_titre = "", fs = FS, signaux = SIGNAUX, decalage::Integer = 0)
    mq, et = marqueurs_creneaux(res; fs)
    return figure_svg(fichier, getfield(TITRES_ESSAI, quoi), sous_titre,
                      panneaux_essai(res, quoi; fs, signaux, decalage);
                      t0, t1, marqueurs = mq, etiquettes = et)
end

tracer_demande(f, res; kw...)     = tracer_essai(f, res, :demande; kw...)
tracer_recu(f, res; kw...)        = tracer_essai(f, res, :recu; kw...)
tracer_comparaison(f, res; kw...) = tracer_essai(f, res, :comparaison; kw...)

"""
    enregistrer_essai(res; nom, dossier="resultats", infos="", zooms=[], decalage=0, donnees=true)

Écrit, avec un horodatage commun : `…_demande.csv` et `…_recu.csv` (les données
brutes, si `donnees`), puis `…_demande.svg`, `…_recu.svg` et
`…_comparaison.svg` sur toute la durée, et les mêmes trois tracés pour chaque
`(t0, t1)` de `zooms`.
"""
function enregistrer_essai(res; nom = "essai", dossier = "resultats", infos = "",
                           zooms = Tuple{Float64, Float64}[], decalage::Integer = 0,
                           donnees::Bool = true)
    mkpath(dossier)
    base = joinpath(dossier, string(nom, "_", Dates.format(now(), "yyyy-mm-dd_HH-MM-SS")))
    fin = (size(res.mesure, 1) - 1) / FS
    fichiers = String[]
    if donnees
        push!(fichiers, enregistrer_demande(base * "_demande.csv", res))
        push!(fichiers, enregistrer_recu(base * "_recu.csv", res))
    end
    fenetres = vcat([("", 0.0, fin)], [("_zoom$(j)", z[1], z[2]) for (j, z) in enumerate(zooms)])
    for (suffixe, a, b) in fenetres
        for quoi in (:demande, :recu, :comparaison)
            push!(fichiers, tracer_essai(base * suffixe * "_$(quoi).svg", res, quoi;
                                         t0 = a, t1 = b, sous_titre = infos, decalage))
        end
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
puissance 1064 nm (commandée, et réellement produite d'après la relecture).
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
             serie("produite (relue)", t, [e.u_mes for e in lignes], PALETTE.porte; mode = :marques)];
            unite = "V", hauteur = 90, yplage = (0.0, umax)))
    end
    return figure_svg(fichier, "Boucle fermée — clamp du chlorure", sous_titre, panneaux;
                      marqueurs = [t_maintien, t_relache], etiquettes = ["maintien", "relâchement"])
end
