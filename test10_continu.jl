include("DAQmxLite.jl")
using .DAQmxLite
using Printf, Statistics
include("sequence.jl")
include("verif.jl")
include("generateur.jl")

const R      = 3      # régions
const CYCLES = 8      # passages complets
const AVANCE = 3      # créneaux écrits d'avance

# Commande écrite d'avance : chaque visite reçoit sa propre puissance 1064 nm
# (+0,1 V par visite, +0,03 V par région). Deux créneaux différents ne
# partagent jamais la même valeur : un créneau décalé se verrait à la relecture.
commande_test(k, v) = (P850[k], 0.5 + 0.1 * v + 0.03 * (k - 1))

Ls = longueur_creneau()
nl, na = ne(T_LECT), ne(T_ACT)
@printf("%d régions × %d cycles, créneau de %.0f ms, %d créneaux d'avance\n",
        R, CYCLES, 1000 * Ls / FS, AVANCE)
@printf("Délai mesure → commande : %d visite(s) de la même région\n", cld(AVANCE, R))

res = jouer_en_continu(R, CYCLES, commande_test; avance = AVANCE)
m = res.mesure
n = size(m, 1)
debuts = [e.debut for e in res.journal]

# 1. Galvo X sur tout le flux, créneaux enchaînés compris
o_galvo, err_galvo = meilleur_decalage(res.x[1:n], m[:, 1])
@printf("\nGalvo X : décalage %d, erreur max %.1f mV sur %d échantillons\n",
        o_galvo, 1000 * err_galvo, n)

# 2. Porte 850 nm : un créneau de lecture par visite
dec_porte = decalages_fronts(m[:, 2], 1.5, debuts, nl)
println("Porte 850 : ", dec_porte === nothing ? "nombre de fronts inattendu" :
        "$(length(dec_porte)) fronts, décalages $(unique(dec_porte))")

# 3. Puissance 1064 nm : chaque visite a-t-elle reçu SA valeur ?
dec_p = decalages_fronts(m[:, 4], 0.25, debuts .+ nl, na)
if stable(dec_p)
    o = dec_p[1]
    ecarts = [mean(m[e.debut + nl + o + 10 : e.debut + nl + na + o - 10, 4]) - e.p1064
              for e in res.journal]
    @printf("P1064 : décalage %d, écart max %.1f mV sur %d visites\n",
            o, 1000 * maximum(abs, ecarts), length(ecarts))
    println(maximum(abs, ecarts) < 0.015 ?
        "Chaque visite a reçu sa propre valeur : aucun créneau décalé." :
        "Écart trop grand : un créneau a pu glisser, voir les détails.")
else
    println("P1064 : décalages instables ou fronts manquants : ", dec_p)
end

# 4. Marge de temps réel
@printf("\nPréparation + écriture d'un créneau : max %.1f ms (le créneau dure %.0f ms)\n",
        1000 * maximum(res.durees), 1000 * Ls / FS)
