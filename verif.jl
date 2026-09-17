# verif.jl — outils pour comparer une relecture à ce qui a été programmé

"""Décalage (en échantillons) qui aligne le mieux la mesure sur la consigne."""
function meilleur_decalage(consigne, mesure; max_dec = 3)
    erreurs = [maximum(abs.(mesure[1 + o:end] .- consigne[1:end - o])) for o in 0:max_dec]
    e, i = findmin(erreurs)
    return i - 1, e
end

function fronts(v, seuil)
    h = v .> seuil
    montes = [i for i in 2:length(h) if h[i] && !h[i - 1]]
    chutes = [i for i in 2:length(h) if !h[i] && h[i - 1]]
    return montes, chutes
end

"""
    decalages_fronts(v, seuil, debuts, duree)

Décalage de chaque front mesuré par rapport au front programmé, pour des
créneaux qui commencent en `debuts` et durent `duree` échantillons.
Renvoie `nothing` si le nombre de fronts n'est pas le bon.
"""
function decalages_fronts(v, seuil, debuts, duree)
    montes, chutes = fronts(v, seuil)
    length(montes) == length(chutes) == length(debuts) || return nothing
    return vcat(montes .- debuts, chutes .- (debuts .+ duree))
end

stable(v) = v !== nothing && all(==(v[1]), v)
