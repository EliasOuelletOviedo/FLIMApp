include("DAQmxLite.jl")
using .DAQmxLite
using Printf, Statistics
include("sequence.jl")
include("verif.jl")
include("generateur.jl")
include("traces.jl")

const R      = 3      # régions
const CYCLES = 8      # passages complets
const AVANCE = 3      # créneaux écrits d'avance

# Commande écrite d'avance : chaque visite reçoit sa propre puissance 1064 nm
# (+0,1 V par visite, +0,03 V par région). Deux créneaux différents ne
# partagent jamais la même valeur : un créneau décalé se verrait à la relecture.
commande_test(k, v) = (P850[k], 0.5 + 0.1 * v + 0.03 * (k - 1))

Ls = longueur_creneau()
nl, na, ni = ne(T_LECT), ne(T_ACT), ne(T_IMP)
@printf("%d régions × %d cycles, créneau de %.0f ms, %d créneaux d'avance\n",
        R, CYCLES, 1000 * Ls / FS, AVANCE)
@printf("Délai mesure → commande : %d visite(s) de la même région\n", cld(AVANCE, R))

res = jouer_en_continu(R, CYCLES, commande_test; avance = AVANCE)
m, c = res.mesure, res.colonne
n, nv = size(m)
debuts = [e.debut for e in res.journal]
@printf("\n%d voies lues, conversion à %.0f kHz : %.0f µs entre la première et la dernière voie\n",
        nv, res.conv / 1000, 1e6 * (nv - 1) / res.conv)

# 1. Les deux galvos, sur tout le flux, raccords entre créneaux compris
for (cle, prog, nom) in ((:galvo_x, res.x, "Galvo X"), (:galvo_y, res.y, "Galvo Y"))
    o, err = meilleur_decalage(prog[1:n], m[:, c[cle]])
    @printf("%-20s : décalage %d, erreur max %.1f mV sur %d échantillons\n", nom, o, 1000 * err, n)
end

# 2. Les quatre lignes de synchronisation du port 0
for (cle, deb, duree, nom) in ((:porte_850,  debuts,          nl, "Porte 850 (P0.0)"),
                               (:porte_1064, debuts .+ nl,    na, "Porte 1064 (P0.1)"),
                               (:imp_seq,    debuts[1:R:end], ni, "Imp. séquence (P0.2)"),
                               (:imp_region, debuts,          ni, "Imp. région (P0.3)"))
    d = decalages_fronts(m[:, c[cle]], 2.5, deb, duree)
    if d === nothing
        mt, ch = fronts(m[:, c[cle]], 2.5)
        @printf("%-20s : %d montées et %d descentes, %d attendues de chaque\n",
                nom, length(mt), length(ch), length(deb))
    else
        @printf("%-20s : %d fronts, décalages %s\n", nom, length(d), unique(d))
    end
end

# 3. Code de région : les quatre bits relus au milieu de chaque passe de lecture
codes = [sum(m[e.debut + nl ÷ 2, c[Symbol("code_b$b")]] > 2.5 ? 1 << b : 0 for b in 0:3)
         for e in res.journal]
attendus = [e.region - 1 for e in res.journal]
println(codes == attendus ?
        "Code de région        : bon aux $(length(codes)) créneaux" :
        "Code de région        : écarts aux créneaux $(findall(codes .!= attendus))")

# 4. Les deux puissances de la 6110 : chaque visite a-t-elle reçu SA valeur ?
for (cle, deb, duree, attendu, nom) in
        ((:p850,  debuts,       nl, [P850[e.region] for e in res.journal],  "P850 (6110 AO 0)"),
         (:p1064, debuts .+ nl, na, [e.p1064 for e in res.journal],         "P1064 (6110 AO 1)"))
    d = decalages_fronts(m[:, c[cle]], 0.25, deb, duree)
    if stable(d)
        o = d[1]
        ecarts = [mean(m[deb[j] + o + 10 : deb[j] + o + duree - 10, c[cle]]) - attendu[j]
                  for j in eachindex(deb)]
        @printf("%-20s : décalage %d, écart max %.1f mV sur %d visites%s\n",
                nom, o, 1000 * maximum(abs, ecarts), length(ecarts),
                maximum(abs, ecarts) < 0.015 ? " — chaque visite a sa valeur" : " — À VÉRIFIER")
    else
        println("$nom : décalages instables ou fronts manquants : ", d)
    end
end

@printf("\nPréparation + écriture d'un créneau : max %.1f ms (le créneau dure %.0f ms)\n",
        1000 * maximum(res.durees), 1000 * Ls / FS)

# 5. Fichiers : demandé, reçu, et les deux superposés
infos = @sprintf("Test 10 — %d régions × %d cycles — %d Hz — avance %d", R, CYCLES, FS, AVANCE)
fichiers = enregistrer_essai(res; nom = "test10", infos,
                             zooms = [(0.0, 0.5),          # entrée et deux premiers créneaux
                                      (0.2375, 0.2475)])   # 100 échantillons autour d'une frontière
println("\nFichiers enregistrés :")
foreach(f -> println("  ", f), fichiers)
