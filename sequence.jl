# sequence.jl — définition d'une séquence de régions (preuve de concept)
# Tout ce qui décrit « quoi jouer » est ici ; les tests décident « sur quelles cartes ».

const FS      = 10_000      # Hz
const T_LECT  = 0.100       # s  passe de lecture (850 nm)
const T_ACT   = 0.100       # s  passe d'actionnement (1064 nm)
const T_PAUSE = 0.020       # s  lasers éteints, galvos en déplacement
const T_IMP   = 0.001       # s  largeur des impulsions de synchro
const TOURS   = 5           # tours de spirale par passe
const RAYON   = 0.3         # V  bouclage seulement, pas des galvos réels
const CENTRES = ((-2.0, -1.0), (0.0, 1.5), (2.0, -0.5))   # V, galvos X et Y
const P850    = (0.8, 1.2, 1.6)    # V, commande de puissance 850 nm, par région
const P1064   = (0.5, 1.0, 1.5)    # V, commande de la Pockels, par région
@assert length(P850) == length(P1064) == length(CENTRES)

# Port 0 : le bit k pilote la ligne P0.k. Bits 4 à 7 : numéro de région.
const B_850, B_1064, B_SEQ, B_REG = 0, 1, 2, 3
bit(b) = UInt8(1) << b
ne(t) = round(Int, t * FS)          # durée -> nombre d'échantillons

function spirale(nb, xc, yc)
    s = (0:nb-1) ./ nb
    r = RAYON .* sin.(π .* s)        # part du centre, s'ouvre, y revient
    θ = 2π * TOURS .* s
    return xc .+ r .* cos.(θ), yc .+ r .* sin.(θ)
end

function deplacement(nb, a, b)        # demi-cosinus : vitesse nulle aux deux bouts
    s = (1 .- cos.(π .* range(0, 1, length = nb))) ./ 2
    return a .+ (b - a) .* s
end

function construire()
    x, y, p8, p10 = Float64[], Float64[], Float64[], Float64[]
    d, debuts = UInt8[], Int[]
    nl, na, np, ni = ne(T_LECT), ne(T_ACT), ne(T_PAUSE), ne(T_IMP)

    # entrée : de (0, 0) au centre de la première région, tout éteint
    append!(x, deplacement(np, 0.0, CENTRES[1][1]))
    append!(y, deplacement(np, 0.0, CENTRES[1][2]))
    append!(p8, zeros(np)); append!(p10, zeros(np))
    append!(d, zeros(UInt8, np))

    for (k, (xc, yc)) in enumerate(CENTRES)
        code = UInt8(k - 1) << 4
        push!(debuts, length(x) + 1)

        sx, sy = spirale(nl, xc, yc)                  # passe de lecture
        append!(x, sx); append!(y, sy)
        append!(p8, fill(P850[k], nl)); append!(p10, zeros(nl))
        o = fill(code | bit(B_850), nl)
        o[1:ni] .|= bit(B_REG)
        k == 1 && (o[1:ni] .|= bit(B_SEQ))
        append!(d, o)

        sx, sy = spirale(na, xc, yc)                  # passe d'actionnement
        append!(x, sx); append!(y, sy)
        append!(p8, zeros(na)); append!(p10, fill(P1064[k], na))
        append!(d, fill(code | bit(B_1064), na))

        xs, ys = k < length(CENTRES) ? CENTRES[k + 1] : (0.0, 0.0)
        append!(x, deplacement(np, xc, xs))           # pause
        append!(y, deplacement(np, yc, ys))
        append!(p8, zeros(np)); append!(p10, zeros(np))
        append!(d, fill(code, np))
    end

    # on termine tout à zéro
    push!(x, 0.0); push!(y, 0.0); push!(p8, 0.0); push!(p10, 0.0); push!(d, 0x00)
    return (; x, y, p850 = p8, p1064 = p10, d, debuts, nl)
end

# ---- Briques pour la génération continue (phase 7) ------------------
# construire() ci-dessus reste pour les tests 8 et 9.

longueur_creneau() = ne(T_LECT) + ne(T_ACT) + ne(T_PAUSE)

"""
    creneau(k, suivant, p850, p1064; debut_sequence=false)

Un créneau pour la région `k` : passe de lecture, passe d'actionnement,
puis pause pendant laquelle les galvos rejoignent `suivant`, un couple
(x, y). Renvoie les cinq voies du créneau.
"""
function creneau(k::Integer, suivant, p850::Real, p1064::Real;
                 debut_sequence::Bool = false)
    nl, na, np, ni = ne(T_LECT), ne(T_ACT), ne(T_PAUSE), ne(T_IMP)
    xc, yc = CENTRES[k]
    code = UInt8(k - 1) << 4

    lx, ly = spirale(nl, xc, yc)
    ax, ay = spirale(na, xc, yc)
    x = vcat(lx, ax, deplacement(np, xc, suivant[1]))
    y = vcat(ly, ay, deplacement(np, yc, suivant[2]))

    p8  = vcat(fill(Float64(p850), nl), zeros(na + np))
    p10 = vcat(zeros(nl), fill(Float64(p1064), na), zeros(np))

    d = vcat(fill(code | bit(B_850), nl), fill(code | bit(B_1064), na), fill(code, np))
    d[1:ni] .|= bit(B_REG)
    debut_sequence && (d[1:ni] .|= bit(B_SEQ))
    return (; x, y, p850 = p8, p1064 = p10, d)
end

"""De (0, 0) au centre de la première région, tout éteint."""
function entree()
    np = ne(T_PAUSE)
    return (; x = deplacement(np, 0.0, CENTRES[1][1]),
              y = deplacement(np, 0.0, CENTRES[1][2]),
              p850 = zeros(np), p1064 = zeros(np), d = zeros(UInt8, np))
end

"""Du centre de la première région à (0, 0), puis `nzero` échantillons à zéro."""
function sortie(nzero::Integer)
    np = ne(T_PAUSE)
    return (; x = vcat(deplacement(np, CENTRES[1][1], 0.0), zeros(nzero)),
              y = vcat(deplacement(np, CENTRES[1][2], 0.0), zeros(nzero)),
              p850 = zeros(np + nzero), p1064 = zeros(np + nzero),
              d = zeros(UInt8, np + nzero))
end
