# rangement.jl — les photons dans les pixels.
#
# `ranger_photons` est le traitement en bloc d'imagerie_photons.jl, inchangé :
# deux passes sur tout le flux. `Rangeur` fait le même rangement trame par
# trame, au fil des lectures du FIFO (étape 2 du plan) : il rend chaque
# trame dès qu'elle est complète, et son cumul est identique au traitement
# en bloc pour la même géométrie.
#
# Règle commune, celle du script : une ligne commence à son marqueur M1 ;
# la première ligne qui suit un marqueur M2 est la ligne 0 d'une trame ;
# colonne = temps depuis le début de la ligne / temps de pixel. À temps
# égal, les marqueurs de trame passent avant ceux de ligne, et ceux de ligne
# avant les photons, quel que soit leur ordre dans le flux.

mediane_img(v) = isempty(v) ? 0.0 : Float64(sort(v)[cld(length(v), 2)])

function centile_img(v, p)
    isempty(v) && return NaN
    s = sort(v)
    return Float64(s[clamp(round(Int, p / 100 * (length(s) - 1)) + 1, 1, length(s))])
end

"""
    geometrie_resolue(lignes, trames, tic_s, g) -> NamedTuple

Taille de l'image et horloges mesurées à partir des temps des marqueurs
(en tics) : période de ligne (médiane), lignes par trame (médiane des
lignes entre deux trames), pixels dans une période de ligne. Mêmes calculs
et mêmes erreurs que la première passe d'imagerie_photons.jl.
"""
function geometrie_resolue(lignes::AbstractVector{Int64}, trames::AbstractVector{Int64}, tic_s, g::Geometrie)
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
    pix_01 = round(Int, g.temps_pixel_ns * 10)              # pixel en dixièmes de ns
    (tic_01 > 0 && pix_01 > 0) || error("tic ($tic_s s) ou temps de pixel ($(g.temps_pixel_ns) ns) nul")
    pixels_ligne = fld(round(Int, periode) * tic_01, pix_01)   # pixels dans une période de ligne
    nx = g.pixels_par_ligne > 0 ? g.pixels_par_ligne : pixels_ligne - g.decalage_pixels
    ny = g.lignes_par_image > 0 ? g.lignes_par_image : lignes_trame - g.decalage_lignes
    (nx > 0 && ny > 0) || error("image vide ($nx × $ny) : vérifie decalage_pixels et decalage_lignes")
    nx * ny <= 1 << 26 || error("image de $nx × $ny pixels : trop grande, vérifie les réglages")
    return (nx = nx, ny = ny, periode = periode, lignes_trame = lignes_trame,
            pixels_ligne = pixels_ligne, tic_01 = tic_01, pix_01 = pix_01)
end

"""
    mesurer_horloges(mots, tic_s; temps_pixel_ns=50.0) -> NamedTuple

Les horloges du scanner telles que la carte les a vues dans un flux FIFO,
pour relier un réglage du scanner à un nombre de lignes
(scripts/spc/horloges_scanner.jl) :

- `ligne`, `trame` : pour M1 et M2, le nombre de fronts, la fréquence (Hz,
  d'après la période médiane) et la période médiane, minimale et maximale (s) ;
- `lignes_par_trame` : fronts M1 entre deux M2 successifs (la ligne qui
  tombe sur le tic d'un M2 compte dans la trame qui commence, comme au
  rangement) — minimum, médiane, maximum — et `repartition`, combien de
  trames ont chaque nombre de lignes ;
- `pixels_par_periode_ligne` : les pixels de `temps_pixel_ns` dans une
  période de ligne (ce que `pixels_par_ligne` et `decalage_pixels` doivent
  tenir) ;
- `fronts_m0`, `fronts_m3`, `photons`, `pertes` (enregistrements GAP),
  `duree_s` (du premier au dernier marqueur M1/M2).
"""
function mesurer_horloges(mots::AbstractVector{UInt16}, tic_s::Real; temps_pixel_ns::Real = 50.0)
    d = decoder!(Decodeur(), mots, length(mots))
    m0, lignes, trames, m3 = d.marqueurs
    function horloge(v)
        p = length(v) >= 2 ? diff(v) .* Float64(tic_s) : Float64[]
        isempty(p) && return (fronts = length(v), frequence_hz = NaN, periode_s = NaN, periode_min_s = NaN, periode_max_s = NaN)
        med = mediane_img(p)
        return (fronts = length(v), frequence_hz = 1 / med, periode_s = med, periode_min_s = minimum(p), periode_max_s = maximum(p))
    end
    par_trame = [searchsortedfirst(lignes, trames[k + 1]) - searchsortedfirst(lignes, trames[k]) for k in 1:length(trames) - 1]
    repartition = Dict{Int,Int}()
    foreach(n -> repartition[n] = get(repartition, n, 0) + 1, par_trame)
    ligne = horloge(lignes)
    marques = vcat(lignes, trames)
    duree = isempty(marques) ? 0.0 : (maximum(marques) - minimum(marques)) * Float64(tic_s)
    return (ligne = ligne, trame = horloge(trames),
            lignes_par_trame = isempty(par_trame) ? (min = 0, mediane = 0, max = 0) :
                               (min = minimum(par_trame), mediane = round(Int, mediane_img(par_trame)), max = maximum(par_trame)),
            repartition = sort!(collect(repartition)),
            pixels_par_periode_ligne = isnan(ligne.periode_s) ? 0 : floor(Int, ligne.periode_s * 1e9 / temps_pixel_ns + 1e-9),
            fronts_m0 = length(m0), fronts_m3 = length(m3), photons = d.photons, pertes = d.pertes, duree_s = duree)
end

"""Première passe : les temps (tics) des marqueurs de ligne (M1) et de trame (M2)."""
function marqueurs_flux(brut::Vector{UInt16})
    d1 = decoder!(Decodeur(), brut, length(brut))
    return d1.marqueurs[2], d1.marqueurs[3]
end

"""
    parcourir_photons(f, brut, lignes, trames, geo, g) -> Decodeur

Seconde passe d'imagerie_photons.jl : décode par blocs de 1 M mots et appelle
`f(y, x, adc)` (indices à partir de 1) pour chaque photon qui tombe dans
l'image, sans garder les photons en mémoire. Rend le décodeur (photons,
pertes, ADC de tous les photons).
"""
function parcourir_photons(f, brut::Vector{UInt16}, lignes::Vector{Int64}, trames::Vector{Int64}, geo, g::Geometrie)
    nl, nt = length(lignes), length(trames)
    nx, ny, tic_01, pix_01 = geo.nx, geo.ny, geo.tic_01, geo.pix_01
    d2 = Decodeur(garder_photons = true)
    k, j = 0, 1                   # dernière ligne passée, prochaine trame
    compteur = -1                 # -1 : avant la première trame, lignes ignorées
    y_cour, t_ligne = -1, Int64(0)
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
            y = y_cour - g.decalage_lignes
            (0 <= y < ny) || continue
            x = fld((tp - t_ligne) * tic_01, pix_01) - g.decalage_pixels
            (0 <= x < nx) || continue
            f(y + 1, x + 1, adc)
        end
        empty!(d2.t_photons); empty!(d2.adc_photons); empty!(d2.routage_photons)
    end
    return d2
end

"""
    ranger_photons(brut, tic_s, dt_ns, g::Geometrie) -> NamedTuple

Traitement en bloc d'imagerie_photons.jl. La première passe ne garde que
les marqueurs, pour mesurer la période de ligne et le nombre de lignes par
trame. La seconde décode par blocs et range chaque photon dans son pixel,
sans garder les photons en mémoire.
"""
function ranger_photons(brut::Vector{UInt16}, tic_s, dt_ns, g::Geometrie)
    lignes, trames = marqueurs_flux(brut)
    geo = geometrie_resolue(lignes, trames, tic_s, g)
    intensite = zeros(UInt32, geo.ny, geo.nx)
    somme_t = zeros(Float64, geo.ny, geo.nx)
    dans_image = Ref(0)
    d2 = parcourir_photons(brut, lignes, trames, geo, g) do y, x, adc
        intensite[y, x] += 1
        somme_t[y, x] += (4095 - Int(adc) + 0.5) * dt_ns   # microtemps croissant
        dans_image[] += 1
    end
    return (intensite = intensite, somme_t = somme_t, declin = reverse(d2.adc),
            photons = d2.photons, dans_image = dans_image[], pertes = d2.pertes,
            trames = max(length(trames) - 1, 0), lignes_trame = geo.lignes_trame, pixels_ligne = geo.pixels_ligne,
            periode_ligne_s = geo.periode * tic_s, nx = geo.nx, ny = geo.ny)
end

"""
    histogrammes_pixels(brut, tic_s, g, etiquettes, n; canaux=256) -> Matrix{Float64}

Un déclin de `canaux` canaux (temps croissant) par groupe de pixels :
`etiquettes[y, x]` (lignes × pixels, la taille de l'image que donne `g`)
vaut 1 à `n` pour les pixels d'un groupe (une ROI), 0 ailleurs. Mêmes
règles de rangement que `ranger_photons`.
"""
function histogrammes_pixels(brut::Vector{UInt16}, tic_s, g::Geometrie, etiquettes::AbstractMatrix{<:Integer}, n::Integer;
                             canaux::Integer = 256)
    4096 % canaux == 0 || error("canaux : un diviseur de 4096")
    lignes, trames = marqueurs_flux(brut)
    geo = geometrie_resolue(lignes, trames, tic_s, g)
    size(etiquettes) == (geo.ny, geo.nx) ||
        error("étiquettes de $(size(etiquettes)) pour une image de $((geo.ny, geo.nx))")
    H = zeros(Float64, canaux, n)
    groupe = 4096 ÷ canaux
    parcourir_photons(brut, lignes, trames, geo, g) do y, x, adc
        e = etiquettes[y, x]
        e > 0 && (H[(4095 - Int(adc)) ÷ groupe + 1, e] += 1)
    end
    return H
end

# ---------------------------------------------------------------------
# Géométrie au fil de l'eau
# ---------------------------------------------------------------------

"""
    Etalonnage()

Marqueurs des premières lectures d'une acquisition, le temps de mesurer la
géométrie (`geometrie_etalonnee`) : il faut deux marqueurs de trame et une
ligne après le second, soit une trame complète (32 ms à 31,25 Hz). Les mots
lus pendant ce temps sont gardés, puis donnés au `Rangeur`.
"""
mutable struct Etalonnage
    decodeur::Decodeur
    mots::Vector{UInt16}
end
Etalonnage() = Etalonnage(Decodeur(), UInt16[])

function ajouter_etalonnage!(e::Etalonnage, mots::AbstractVector{UInt16}, n::Integer)
    append!(e.mots, view(mots, 1:n))
    decoder!(e.decodeur, mots, n)
    empty!(e.decodeur.marqueurs[1]); empty!(e.decodeur.marqueurs[4])
    return e
end

function reinitialiser_etalonnage!(e::Etalonnage)
    e.decodeur = Decodeur()
    empty!(e.mots)
    return e
end

"""
    geometrie_etalonnee(e, tic_s, g) -> NamedTuple ou nothing

La géométrie, comme `geometrie_resolue`, dès qu'une trame complète a été
vue ; `nothing` avant. Le nombre de lignes par trame est la médiane sur les
trames complètes vues : il suit le traitement en bloc tant qu'il ne varie
pas d'une trame à l'autre.
"""
function geometrie_etalonnee(e::Etalonnage, tic_s, g::Geometrie)
    lignes, trames = e.decodeur.marqueurs[2], e.decodeur.marqueurs[3]
    length(lignes) >= 2 && length(trames) >= 2 || return nothing
    completes = [t for t in trames if searchsortedfirst(lignes, t) <= length(lignes)]
    length(completes) >= 2 || return nothing
    return geometrie_resolue(lignes, completes, tic_s, g)
end

# ---------------------------------------------------------------------
# Rangement trame par trame
# ---------------------------------------------------------------------

"""
    Rangeur(geo, tic_s, dt_ns, g)

Range les photons d'un flux FIFO au fil des lectures (`ranger!`) : le
rangement de `ranger_photons`, mais trame par trame. `geo` vient de
`geometrie_resolue` ou `geometrie_etalonnee`.

Une trame est complète quand la ligne 0 de la suivante arrive ; `ranger!`
appelle alors `f(r, true)` avec la trame dans `r.intensite`, `r.somme_t`,
`r.declin` (4096 canaux, temps croissant), `r.photons_trame` (tous les
photons arrivés pendant la trame), `r.dans_image_trame`, `r.pertes_trame`
et `r.numero` ; puis la remet à zéro. `terminer!` rend la dernière trame,
incomplète (`f(r, false)`).

Le cumul depuis le début (`intensite_tot`, `somme_t_tot`, `dans_image`,
`declin_total(r)`, `r.decodeur.photons`, `r.decodeur.pertes`,
`r.trames_completes`) est celui de `ranger_photons` sur le même flux.

Les événements du même tic peuvent arriver dans n'importe quel ordre et
être coupés entre deux lectures : ceux du dernier tic lu attendent la
lecture suivante (ou `terminer!`).
"""
mutable struct Rangeur
    nx::Int
    ny::Int
    tic_01::Int
    pix_01::Int
    decalage_pixels::Int
    decalage_lignes::Int
    dt_ns::Float64
    decodeur::Decodeur
    # événements décodés pas encore rangés (temps croissants)
    lignes::Vector{Int64}
    trames::Vector{Int64}
    t_photons::Vector{Int64}
    adc_photons::Vector{UInt16}
    # balayage
    lignes_vues::Int
    compteur::Int
    y_cour::Int
    t_ligne::Int64
    trame_en_attente::Bool
    numero::Int
    t_debut_trame::Int64
    # trame en cours
    intensite::Matrix{UInt32}
    somme_t::Matrix{Float64}
    declin::Vector{Int}
    photons_trame::Int
    dans_image_trame::Int
    pertes_trame::Int
    pertes_debut::Int
    # cumul
    intensite_tot::Matrix{UInt32}
    somme_t_tot::Matrix{Float64}
    dans_image::Int
    trames_completes::Int
end

function Rangeur(geo, tic_s, dt_ns, g::Geometrie)
    nx, ny = geo.nx, geo.ny
    return Rangeur(nx, ny, round(Int, tic_s * 1e10), round(Int, g.temps_pixel_ns * 10),
                   g.decalage_pixels, g.decalage_lignes, Float64(dt_ns),
                   Decodeur(garder_photons = true),
                   Int64[], Int64[], Int64[], UInt16[],
                   0, -1, -1, Int64(0), false, 0, Int64(0),
                   zeros(UInt32, ny, nx), zeros(Float64, ny, nx), zeros(Int, 4096), 0, 0, 0, 0,
                   zeros(UInt32, ny, nx), zeros(Float64, ny, nx), 0, 0)
end

"""Déclin de tous les photons depuis le début, temps croissant (comme `ranger_photons`)."""
declin_total(r::Rangeur) = reverse(r.decodeur.adc)

"""
    ranger!(f, r, mots, n=length(mots))

Décode les `n` premiers mots et range les photons ; `f(r, complete)` à
chaque trame complète (voir `Rangeur`).
"""
function ranger!(f, r::Rangeur, mots::AbstractVector{UInt16}, n::Integer = length(mots))
    d = r.decodeur
    decoder!(d, mots, n)
    append!(r.lignes, d.marqueurs[2]); append!(r.trames, d.marqueurs[3])
    append!(r.t_photons, d.t_photons); append!(r.adc_photons, d.adc_photons)
    foreach(empty!, d.marqueurs)
    empty!(d.t_photons); empty!(d.adc_photons); empty!(d.routage_photons)
    limite = typemin(Int64)
    isempty(r.lignes) || (limite = max(limite, last(r.lignes)))
    isempty(r.trames) || (limite = max(limite, last(r.trames)))
    isempty(r.t_photons) || (limite = max(limite, last(r.t_photons)))
    _ranger_avant!(f, r, limite)
    return r
end

"""Range tout ce qui attend, puis rend la trame en cours, incomplète."""
function terminer!(f, r::Rangeur)
    _ranger_avant!(f, r, typemax(Int64))
    r.numero > 0 && r.compteur >= 0 && _fin_trame!(f, r, false)
    return r
end

# Range les événements de temps < limite (tous si limite = typemax).
function _ranger_avant!(f, r::Rangeur, limite::Int64)
    L, F, P, A = r.lignes, r.trames, r.t_photons, r.adc_photons
    tous = limite == typemax(Int64)
    il, jf, ip = 1, 1, 1
    @inbounds while ip <= length(P) && (tous || P[ip] < limite)
        tp = P[ip]
        while il <= length(L) && L[il] <= tp
            jf = _ligne!(f, r, L[il], F, jf)
            il += 1
        end
        _photon!(r, tp, A[ip])
        ip += 1
    end
    @inbounds while il <= length(L) && (tous || L[il] < limite)
        jf = _ligne!(f, r, L[il], F, jf)
        il += 1
    end
    @inbounds while jf <= length(F) && (tous || F[jf] < limite)
        r.trame_en_attente = true
        jf += 1
    end
    il > 1 && deleteat!(L, 1:il - 1)
    jf > 1 && deleteat!(F, 1:jf - 1)
    if ip > 1
        deleteat!(P, 1:ip - 1)
        deleteat!(A, 1:ip - 1)
    end
    return nothing
end

function _ligne!(f, r::Rangeur, tl::Int64, F::Vector{Int64}, jf::Int)
    @inbounds while jf <= length(F) && F[jf] <= tl
        r.trame_en_attente = true
        jf += 1
    end
    if r.trame_en_attente                  # nouvelle trame : cette ligne est la ligne 0
        r.trame_en_attente = false
        r.compteur >= 0 && _fin_trame!(f, r, true)
        r.compteur = 0
        r.numero += 1
        r.t_debut_trame = tl
    end
    r.y_cour = r.compteur
    r.compteur >= 0 && (r.compteur += 1)
    r.t_ligne = tl
    r.lignes_vues += 1
    return jf
end

@inline function _photon!(r::Rangeur, tp::Int64, adc::UInt16)
    if r.compteur >= 0                     # pendant une trame (hors image compris)
        @inbounds r.declin[4096 - Int(adc)] += 1
        r.photons_trame += 1
    end
    r.lignes_vues == 0 && return nothing
    y = r.y_cour - r.decalage_lignes
    (0 <= y < r.ny) || return nothing
    x = fld((tp - r.t_ligne) * r.tic_01, r.pix_01) - r.decalage_pixels
    (0 <= x < r.nx) || return nothing
    v = (4095 - Int(adc) + 0.5) * r.dt_ns   # microtemps croissant
    @inbounds begin
        r.intensite[y + 1, x + 1] += 1
        r.somme_t[y + 1, x + 1] += v
        r.intensite_tot[y + 1, x + 1] += 1
        r.somme_t_tot[y + 1, x + 1] += v
    end
    r.dans_image += 1
    r.dans_image_trame += 1
    return nothing
end

function _fin_trame!(f, r::Rangeur, complete::Bool)
    r.pertes_trame = r.decodeur.pertes - r.pertes_debut
    r.pertes_debut = r.decodeur.pertes
    complete && (r.trames_completes += 1)
    f(r, complete)
    fill!(r.intensite, 0)
    fill!(r.somme_t, 0.0)
    fill!(r.declin, 0)
    r.photons_trame = 0
    r.dans_image_trame = 0
    return nothing
end
