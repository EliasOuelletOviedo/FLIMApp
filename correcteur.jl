# correcteur.jl — PI + observateur par région, et constante de temps du relâchement
# Ne dépend que de la bibliothèque standard.

"""Modèle d'une région : chlorure basal `C0` (mM), extrusion `tau` (s), gain `g` (mM/(V·s))."""
modele(C0, tau, g) = (; C0 = float(C0), tau = float(tau), g = float(g))

"""
    evoluer(C, u, mdl, Tc, Tact)

Chlorure à la visite suivante : puissance `u` pendant la passe d'actionnement
(`Tact`), puis extrusion seule jusqu'à la visite suivante (`Tc` après la
précédente). Exact pour un premier ordre et une puissance constante pendant la passe.
"""
function evoluer(C, u, mdl, Tc, Tact)
    cinf = mdl.C0 + mdl.tau * mdl.g * u
    c1 = cinf + (C - cinf) * exp(-Tact / mdl.tau)
    return mdl.C0 + (c1 - mdl.C0) * exp(-(Tc - Tact) / mdl.tau)
end

"""
Un correcteur par région.
- L'observateur corrige son estimation avec la mesure, puis la prédit à la
  visite suivante en tenant compte de la commande déjà écrite.
- P agit sur cette prédiction : c'est ce qui compense le délai d'une visite.
- I agit sur l'erreur *mesurée* : l'erreur finale s'annule même si le modèle
  est faux (une estimation à gain fixe resterait biaisée).
- Les gains se déduisent du modèle de la région et d'un seul réglage,
  `lambda`, la constante de temps visée en boucle fermée.
"""
mutable struct Correcteur
    mdl::NamedTuple
    kp::Float64
    ki::Float64
    L::Float64
    umax::Float64
    Tc::Float64
    Tact::Float64
    estime::Float64
    integrale::Float64
end

function Correcteur(mdl; lambda, L, umax, Tc, Tact, ki_mult = 2.0)
    a = exp(-Tc / mdl.tau)
    K = mdl.tau * mdl.g * (Tact / Tc)                  # gain statique, mM/V
    kp = (1 - exp(-Tc / lambda)) / (K * (1 - a))
    ki = ki_mult * kp * (1 - a)
    return Correcteur(mdl, kp, ki, L, umax, Tc, Tact, mdl.C0, 0.0)
end

"""
    pas!(c, y, u, consigne, actif) -> (estime, u_suivant)

Une fois par visite, après la passe de lecture. `y` est la mesure, `u` la
commande qui avait été écrite pour cette visite. Renvoie l'estimation
corrigée et la commande de la visite suivante (nulle si `actif` est faux).
"""
function pas!(c::Correcteur, y, u, consigne, actif::Bool)
    c.estime += c.L * (y - c.estime)
    estime = c.estime
    prediction = evoluer(c.estime, u, c.mdl, c.Tc, c.Tact)
    if actif
        ep = consigne - prediction
        em = consigne - y
        brut = c.kp * ep + c.integrale
        # anti-emballement : on n'intègre pas quand la commande est saturée dans le même sens
        if (0 < brut < c.umax) || (brut >= c.umax && em < 0) || (brut <= 0 && em > 0)
            c.integrale += c.ki * em
        end
        u_suivant = clamp(c.kp * ep + c.integrale, 0.0, c.umax)
    else
        c.integrale = 0.0
        u_suivant = 0.0
    end
    c.estime = prediction
    return estime, u_suivant
end

"""
    ajuster_relachement(t, y) -> τ

Ajuste y ≈ base + A·exp(-t/τ) sur toutes les mesures du relâchement. Pour un
τ donné, A et la base s'obtiennent exactement par moindres carrés ; τ est
cherché sur une grille logarithmique, puis affiné par section dorée.
Contrairement à une régression sur log(y − base), aucune mesure n'est écartée,
donc le bruit n'introduit pas de biais.
"""
function ajuster_relachement(t::AbstractVector, y::AbstractVector)
    n = length(t)
    function residu(tau)
        e = exp.(-t ./ tau)
        see, se, sey, sy = sum(abs2, e), sum(e), sum(e .* y), sum(y)
        det = see * n - se^2
        amp = (sey * n - se * sy) / det
        ord = (see * sy - se * sey) / det
        return sum(abs2, y .- ord .- amp .* e)
    end
    grille = exp.(range(log(0.3), log(300.0), length = 600))
    i = argmin(residu.(grille))
    lo, hi = grille[max(i - 1, 1)], grille[min(i + 1, length(grille))]
    phi = (sqrt(5) - 1) / 2
    for _ in 1:60
        c1, c2 = hi - phi * (hi - lo), lo + phi * (hi - lo)
        if residu(c1) < residu(c2)
            hi = c2
        else
            lo = c1
        end
    end
    return (lo + hi) / 2
end
