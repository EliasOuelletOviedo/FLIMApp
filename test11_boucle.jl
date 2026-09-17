include("DAQmxLite.jl")
using .DAQmxLite
using Printf, Statistics, Random
include("sequence.jl")
include("verif.jl")
include("generateur.jl")
include("traces.jl")
include("correcteur.jl")

# ---- Protocole ------------------------------------------------------------
const R        = 3
const AVANCE   = R            # indispensable : voir le texte
const T_BASE   = 6.0          # s, ligne de base, actionnement coupé
const T_MAINT  = 40.0         # s, maintien à la consigne
const T_REL    = 30.0         # s, relâchement libre
const CONSIGNE = (15.0, 12.0, 18.0)     # mM
const UMAX     = 1.5          # V, plafond de la commande Pockels

const TC   = R * longueur_creneau() / FS   # s entre deux visites d'une même région
const TACT = ne(T_ACT) / FS
const COL  = voies_lues()[2]               # colonne de chaque signal dans la relecture

# ---- Cellules simulées : c'est ce que remplacera la mesure FLIM ------------
const C0_VRAI  = 5.0                    # mM
const TAU_VRAI = (6.0, 8.0, 12.0)       # s, extrusion propre à chaque région
const HAUSSE   = 20.0                   # mM de hausse à puissance maximale, à l'équilibre
const BRUIT    = 0.4                    # mM, écart-type de la mesure
const VRAIS = [modele(C0_VRAI, TAU_VRAI[k], HAUSSE / (TAU_VRAI[k] * UMAX * TACT / TC)) for k in 1:R]

# ---- Ce que le correcteur croit savoir : 20 % d'erreur, volontairement ------
const MODELES = [modele(m.C0, 1.2 * m.tau, 0.8 * m.g) for m in VRAIS]
const LAMBDA  = 5.0                     # s, constante de temps visée en boucle fermée
const L_OBS   = 0.4                     # gain de l'observateur

Random.seed!(1)
chlorure    = [m.C0 for m in VRAIS]
correcteurs = [Correcteur(MODELES[k]; lambda = LAMBDA, L = L_OBS, umax = UMAX, Tc = TC, Tact = TACT)
               for k in 1:R]
commandes      = Dict{Tuple{Int, Int}, Float64}()    # (région, visite) → puissance 1064 nm
journal_boucle = NamedTuple[]

commande_boucle(k, v) = (P850[k], get(commandes, (k, v), 0.0))

function apres_creneau_boucle(s, bloc)
    k, v = s % R + 1, s ÷ R
    t = (ne(T_PAUSE) + s * longueur_creneau()) / FS
    nl, na = ne(T_LECT), ne(T_ACT)
    u_cmd = get(commandes, (k, v), 0.0)
    u_mes = mean(view(bloc, nl + 20 : nl + na - 20, COL[:p1064]))   # puissance réellement produite

    # cellule simulée : la lecture voit l'état d'avant l'actionnement de ce créneau
    vrai = chlorure[k]
    y = vrai + BRUIT * randn()
    chlorure[k] = evoluer(vrai, u_mes, VRAIS[k], TC, TACT)

    # correcteur : commande de la prochaine visite de cette région
    actif = T_BASE <= t + TC < T_BASE + T_MAINT
    estime, u_suivant = pas!(correcteurs[k], y, u_cmd, CONSIGNE[k], actif)
    commandes[(k, v + 1)] = u_suivant

    push!(journal_boucle, (; t, region = k, visite = v, vrai, mesure = y, estime, u_cmd, u_mes))
    return nothing
end

@assert AVANCE == R "avance doit valoir R : la commande de la visite v+1 doit être prête quand le générateur l'écrit"
ncycles = ceil(Int, (T_BASE + T_MAINT + T_REL) / TC)
@printf("Test 11 — %d régions, %d cycles (%.0f s), une visite toutes les %.2f s\n",
        R, ncycles, ncycles * TC, TC)

res = jouer_en_continu(R, ncycles, commande_boucle; avance = AVANCE,
                       apres_creneau = apres_creneau_boucle)

t_rel = T_BASE + T_MAINT
println("\nrégion   erreur (2e moitié du maintien)   commande d'équilibre   τ relâchement (vrai)")
for k in 1:R
    lignes = [e for e in journal_boucle if e.region == k]
    err  = mean(abs(e.vrai - CONSIGNE[k]) for e in lignes if T_BASE + T_MAINT / 2 <= e.t < t_rel)
    u_eq = mean(e.u_cmd for e in lignes if t_rel - 10 <= e.t < t_rel)
    rel  = [e for e in lignes if e.t >= t_rel + TC]
    tau  = ajuster_relachement([e.t - t_rel for e in rel], [e.mesure for e in rel])
    @printf("  %d          %5.2f mM                        %4.2f V             %5.1f s (%.1f s)\n",
            k, err, u_eq, tau, TAU_VRAI[k])
end
@printf("\nPréparation + écriture d'un créneau : max %.1f ms\n", 1000 * maximum(res.durees))

infos = @sprintf("Test 11 — %d régions — λ = %.0f s, L = %.1f", R, LAMBDA, L_OBS)
println("\nÉcriture des fichiers (les deux CSV complets font chacun environ 50 Mo)…")
fichiers = enregistrer_essai(res; nom = "test11", infos, zooms = [(T_BASE - 0.5, T_BASE + 2.0)])
base = replace(first(fichiers), "_demande.csv" => "")
push!(fichiers, enregistrer_boucle(base * "_boucle.csv", journal_boucle))
push!(fichiers, tracer_boucle(base * "_boucle.svg", journal_boucle, R;
                              consignes = CONSIGNE, t_maintien = T_BASE, t_relache = t_rel,
                              umax = UMAX, taus = TAU_VRAI, sous_titre = infos))
println("Fichiers enregistrés :")
foreach(f -> println("  ", f), fichiers)
