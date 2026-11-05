# balayage.jl — l'image faite par les galvos de la NI (bouton « Galvo scan »
# de la fenêtre ROI) : le repère des ROI. La NI balaie, ligne par ligne, le
# champ de tensions où elle envoie ensuite les galvos sur chaque ROI ; la
# carte range chaque photon au pixel que visaient les galvos.
#
# Une ligne par passe (`BalayageGalvos`, reglages.jl) : le signal de passe
# est haut pendant la rampe de la ligne (M0 à son début, M3 à sa fin), bas
# pendant le retour, où la NI écrit le code de routage réservé. La colonne
# d'un photon est sa place dans la passe — temps depuis M0 sur la durée
# M3 − M0, mesurés par la carte elle-même : pas de dérive entre l'horloge de
# la NI et celle de la carte ; sa ligne, le rang de la passe, compté sur la
# cadence des M0 : un M0 perdu ne décale pas les lignes suivantes.

"""Ce qui empêche un balayage de servir ("" : rien)."""
function refus_balayage(b::BalayageGalvos)
    (b.pixels >= 1 && b.lignes >= 1) || return "balayage des galvos : au moins 1 pixel et 1 ligne"
    b.pixels * b.lignes <= 1 << 24 || return "balayage des galvos : image de $(b.pixels) × $(b.lignes) pixels, trop grande"
    0 < b.scan_s < b.periode_s || return "balayage des galvos : rampe ($(b.scan_s) s) plus courte que la ligne ($(b.periode_s) s)"
    return ""
end

"""
    lignes_balayage(debuts, fins, tic_s, b) -> (lignes, ecartees)

Les lignes d'un balayage d'après les marqueurs de passe (temps en tics,
croissants) : `lignes`, un `(ligne, t_debut, t_fin)` (ligne à partir de 0)
par passe retenue, dans l'ordre du temps ; `ecartees`, le nombre de passes
de l'image écartées. La ligne d'une passe : l'écart de son M0 au premier
M0, en périodes de ligne, arrondi — la période mesurée (médiane des écarts
entre M0 voisins) si elle est à 1 % de `periode_s`, sinon `periode_s` ; un
M0 perdu ne décale donc pas les lignes suivantes. Une passe au-delà de la
dernière ligne est ignorée (le signal de passe de la NI repart une fois
après la dernière ligne, le temps que la boucle s'arrête). La fin d'une
passe : le premier M3 après son M0 (`fin_par_m3`), s'il vient avant le M0
suivant et à 1 % près de la rampe programmée — sinon la passe est écartée
—, ou `scan_s` après son M0. Une ligne déjà vue est écartée.
"""
function lignes_balayage(debuts::AbstractVector{Int64}, fins::AbstractVector{Int64}, tic_s::Real, b::BalayageGalvos)
    lignes = NTuple{3,Int64}[]
    ecartees = 0
    isempty(debuts) && return lignes, ecartees
    scan = b.scan_s / tic_s
    programmee = b.periode_s / tic_s
    mesuree = length(debuts) >= 2 ? mediane_img(diff(debuts)) : programmee
    periode = abs(mesuree - programmee) <= 0.01 * programmee ? mesuree : programmee
    vues = falses(b.lignes)
    j = 1
    for (i, td) in enumerate(debuts)
        y = round(Int64, (td - debuts[1]) / periode)
        y < b.lignes || continue
        if b.fin_par_m3
            suivant = i < length(debuts) ? debuts[i + 1] : typemax(Int64)
            while j <= length(fins) && fins[j] <= td
                j += 1
            end
            if j > length(fins) || fins[j] >= suivant || abs(fins[j] - td - scan) > 0.01 * scan
                ecartees += 1
                continue
            end
            te = fins[j]
        else
            te = td + round(Int64, scan)
        end
        if vues[y + 1]
            ecartees += 1
            continue
        end
        vues[y + 1] = true
        push!(lignes, (y, td, te))
    end
    return lignes, ecartees
end

"""
    parcourir_balayage(f, brut, tic_s, b) -> (decodeur, lignes, ecartees)

Comme `parcourir_photons`, pour une image des galvos : la première passe ne
garde que les marqueurs (`lignes_balayage`), la seconde décode par blocs de
1 M mots et appelle `f(y, x, adc)` (indices à partir de 1) pour chaque
photon d'une ligne retenue, colonne `x − 1 = pixels × (t − M0) / (fin − M0)`
arrondi vers le bas : un photon pile sur le M0 est dans la ligne, pile sur
sa fin il n'y est plus. Rend le décodeur (photons, pertes, ADC de tous les
photons) et les lignes.
"""
function parcourir_balayage(f, brut::AbstractVector{UInt16}, tic_s::Real, b::BalayageGalvos)
    d1 = decoder!(Decodeur(), brut, length(brut))
    lignes, ecartees = lignes_balayage(d1.marqueurs[MARQUEUR_DEBUT], d1.marqueurs[MARQUEUR_FIN], tic_s, b)
    d2 = Decodeur(garder_photons = true)
    k = 1                                   # première ligne qui ne finit pas avant le photon
    bloc = 1 << 20
    for debut in 1:bloc:length(brut)
        fin = min(debut + bloc - 1, length(brut))
        decoder!(d2, view(brut, debut:fin), fin - debut + 1)
        for (tp, adc) in zip(d2.t_photons, d2.adc_photons)
            while k <= length(lignes) && lignes[k][3] <= tp
                k += 1
            end
            k <= length(lignes) || continue
            y, t0, t1 = lignes[k]
            tp >= t0 || continue
            f(Int(y) + 1, Int(fld((tp - t0) * b.pixels, t1 - t0)) + 1, adc)
        end
        empty!(d2.t_photons); empty!(d2.adc_photons); empty!(d2.routage_photons)
    end
    return d2, lignes, ecartees
end

"""
    ranger_balayage(brut, tic_s, dt_ns, b) -> NamedTuple

L'image des galvos d'un flux FIFO, comme `ranger_photons` : `intensite` et
`somme_t` (`lignes` × `pixels`), `declin` (tous les photons, temps
croissant), `photons`, `dans_image`, `pertes`, `lignes_vues` (lignes
retenues) et `lignes_ecartees` ; plus ce qu'en garde le .jls d'une
acquisition (`trames` = 1, `lignes_trame`, `periode_ligne_s`).
"""
function ranger_balayage(brut::AbstractVector{UInt16}, tic_s::Real, dt_ns::Real, b::BalayageGalvos)
    intensite = zeros(UInt32, b.lignes, b.pixels)
    somme_t = zeros(Float64, b.lignes, b.pixels)
    dans_image = Ref(0)
    d, lignes, ecartees = parcourir_balayage(brut, tic_s, b) do y, x, adc
        intensite[y, x] += 1
        somme_t[y, x] += (4095 - Int(adc) + 0.5) * dt_ns   # microtemps croissant
        dans_image[] += 1
    end
    return (intensite = intensite, somme_t = somme_t, declin = reverse(d.adc), photons = d.photons,
            dans_image = dans_image[], pertes = d.pertes, lignes_vues = length(lignes), lignes_ecartees = ecartees,
            trames = 1, lignes_trame = b.lignes, pixels_ligne = b.pixels, periode_ligne_s = b.periode_s,
            nx = b.pixels, ny = b.lignes)
end

"""
    histogrammes_pixels(brut, tic_s, b::BalayageGalvos, etiquettes, n; canaux=256) -> Matrix{Float64}

`histogrammes_pixels` d'une image des galvos : un déclin par groupe de
pixels, `etiquettes` de la taille de l'image (`lignes` × `pixels`).
"""
function histogrammes_pixels(brut::AbstractVector{UInt16}, tic_s, b::BalayageGalvos, etiquettes::AbstractMatrix{<:Integer},
                             n::Integer; canaux::Integer = 256)
    4096 % canaux == 0 || error("canaux : un diviseur de 4096")
    size(etiquettes) == (b.lignes, b.pixels) ||
        error("étiquettes de $(size(etiquettes)) pour une image des galvos de $((b.lignes, b.pixels))")
    H = zeros(Float64, canaux, n)
    groupe = 4096 ÷ canaux
    parcourir_balayage(brut, tic_s, b) do y, x, adc
        e = etiquettes[y, x]
        e > 0 && (H[(4095 - Int(adc)) ÷ groupe + 1, e] += 1)
    end
    return H
end

"""Les cellules de la simulation : centre et rayon, en fraction de l'image."""
const CELLULES_SIMULEES = NTuple{3,Float64}[(0.30, 0.28, 0.07), (0.68, 0.33, 0.06), (0.50, 0.58, 0.08),
                                            (0.24, 0.72, 0.06), (0.76, 0.76, 0.07)]

"""
    flux_balayage_synthetique(b; tic_s=25e-9, photons_par_ligne=400, tau_ns=(2.0, 3.5), fenetre_ns=12.5,
                              graine=1, debut_s=0.01, photons_retour_par_s=0, cellules=CELLULES_SIMULEES)
        -> Vector{UInt16}

Flux FIFO d'un balayage des galvos, au format des cartes : pour chaque
ligne, M0 au début de sa rampe et M3 à sa fin (`b.scan_s`), une ligne
toutes les `b.periode_s` à partir de `debut_s`. Les photons tombent au
hasard sur la rampe, plus nombreux dans des disques (`cellules`), avec un
déclin de `tau_ns[1]` dans les disques et de `tau_ns[2]` autour ; pendant
les retours, `photons_retour_par_s` au code de routage réservé.
"""
function flux_balayage_synthetique(b::BalayageGalvos; tic_s::Real = 25e-9, photons_par_ligne::Real = 400,
                                   tau_ns = (2.0, 3.5), fenetre_ns::Real = 12.5, graine::Integer = 1,
                                   debut_s::Real = 0.01, photons_retour_par_s::Real = 0,
                                   cellules::AbstractVector = CELLULES_SIMULEES)
    a = Alea(graine)
    e = EncodeurFifo()
    dt_ns = fenetre_ns / 4096
    scan = round(Int64, b.scan_s / tic_s)
    periode = round(Int64, b.periode_s / tic_s)
    t0 = round(Int64, debut_s / tic_s)
    function photon_au_hasard!(t, tau, code)
        canal = floor(Int, -tau * log(1 - _uniforme!(a)) / dt_ns)
        canal < 4096 && photon!(e, t, 4095 - canal; routage = code)
    end
    for ligne in 0:b.lignes - 1
        debut = t0 + ligne * periode
        y = (ligne + 0.5) / b.lignes
        marqueur!(e, debut, 0b0001)
        n = round(Int, photons_par_ligne * (0.9 + 0.2 * _uniforme!(a)))
        for dt in sort!([floor(Int64, _uniforme!(a) * scan) for _ in 1:n])
            x = (dt + 0.5) / scan
            dedans = any(c -> (x - c[1])^2 + (y - c[2])^2 < c[3]^2, cellules)
            (dedans || _uniforme!(a) < 0.15) || continue
            photon_au_hasard!(debut + dt, dedans ? tau_ns[1] : tau_ns[2], CODE_SANS_ROI)
        end
        marqueur!(e, debut + scan, 0b1000)
        retour = periode - scan
        n_retour = round(Int, photons_retour_par_s * retour * tic_s)
        for dt in sort!([1 + floor(Int64, _uniforme!(a) * (retour - 1)) for _ in 1:n_retour])
            photon_au_hasard!(debut + scan + dt, tau_ns[2], CODE_HORS_ROI)
        end
    end
    return e.mots
end
