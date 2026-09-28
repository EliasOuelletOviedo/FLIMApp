# Architecture logicielle du clamp de chlorure

Sep 28, 2026 · @Elias

Une seule application Julia, trois threads : l'interface GLMakie garde le thread principal pour elle seule, la boucle possède les cartes NI sur un thread de travail, et le journal écrit sur disque sur un autre. Ils ne se parlent que par des échanges non bloquants : l'affichage ne peut pas retarder un créneau, et la boucle ne peut pas figer l'affichage si les règles des sections 5 et 6 sont respectées.

## 1. Vue d'ensemble

plan.png

Tout tourne dans ton application Julia actuelle : le thread principal ne fait que l'interface, la boucle ne fait que les cartes et la commande, le journal ne fait que le disque. La SPC-QC-104 est laissée de côté pour l'instant : la mesure vient de la simulation du test 11, derrière une fonction que la réception TCSPC remplacera plus tard.

## 2. Threads

Lance l'application avec `julia --project -t 3,1` : trois threads de travail, plus le thread interactif. Depuis Julia 1.12, la tâche principale et le REPL tournent sur ce thread interactif ; le rendu GLMakie aussi, puisque GLMakie démarre sa boucle de rendu par `@async` depuis la tâche qui ouvre la fenêtre.

| Thread | Rôle | Attend sur | Ne doit jamais |
| --- | --- | --- | --- |
| Principal (interactif) | Construit la fenêtre une fois ; exécute le rendu, les rappels des boutons, et une minuterie à 30 Hz qui copie les données d'affichage et met à jour la figure | Les événements de la fenêtre et la minuterie | Lire ou écrire une carte, attendre la boucle, calculer plus de quelques millisecondes |
| Boucle (`Threads.@spawn`) | Crée et possède toutes les tâches NI-DAQmx. Une itération par créneau : relecture, mesure, correcteur, écriture du créneau s + R | La relecture du créneau en cours, par blocs de 20 ms | Toucher un `Observable` ou un objet Makie, écrire sur disque, afficher |
| Journal (`Threads.@spawn`) | Vide la file `journal` et écrit sur disque par lots d'environ une seconde | La file `journal` | Retenir la boucle : si la file est pleine, la boucle jette l'entrée et la compte |
| Travail libre | Calculs lourds lancés depuis l'interface (ajustement, export de figure) ; plus tard, la réception TCSPC | Rien en permanence | — |

Un rappel de bouton ne fait jamais le travail lui-même : il dépose une commande pour la boucle, ou lance un calcul lourd avec `Threads.@spawn`, puis rend la main aussitôt.

## 3. Le cycle d'un créneau

Avec 3 régions et des créneaux de 220 ms, la boucle dispose de 440 ms après la fin d'un créneau pour écrire la prochaine visite de la même région ; l'interface, elle, n'a aucune échéance. Le créneau s joue la région k = s mod R + 1, visite v = s ÷ R.

| Moment (depuis le début du créneau s) | Cartes | Boucle | Interface |
| --- | --- | --- | --- |
| 0 à 220 ms | Jouent le créneau s : lecture 100 ms, actionnement 100 ms, pause 20 ms | Lit la relecture de s par blocs de 20 ms ; entre deux blocs, regarde le drapeau d'arrêt | Rend à 30 images/s ce qu'elle a déjà reçu |
| 220 ms | Fin du créneau s | Mesure de s, correcteur, u(k, v + 1) ; construit et écrit le créneau s + 3 ; dépose le résumé pour l'affichage et le détail pour le journal | Voit le nouveau résumé au prochain tick de sa minuterie, 33 ms au plus tard |
| 660 ms | Le créneau s + 3 commence à jouer | Échéance : il devait être écrit avant | — |

L'échéance vaut (R − 1) × 220 ms, parce que les créneaux s + 1 et s + 2 sont déjà dans le tampon de sortie. Au test 10, préparer et écrire un créneau prenait 1,3 ms au plus : la marge est d'un facteur 300. La mesure vient pour l'instant de la simulation du test 11 ; quand elle viendra du TCSPC, elle passera par la même fonction, avec une règle de repli si elle arrive en retard.

## 4. Échanges entre threads

Quatre échanges suffisent, et aucun ne peut faire attendre la boucle. Les threads ne partagent rien d'autre.

| Échange | En Julia | Sens | Contenu | Règle |
| --- | --- | --- | --- | --- |
| Données d'affichage | Tampon circulaire préalloué + `ReentrantLock` | boucle → principal | Par créneau : s, k, v, mesure, estimation, consigne, u, durée d'itération ; relecture du dernier créneau, décimée | Sous le verrou, la boucle écrit et la minuterie copie, en quelques microsecondes. La figure est mise à jour hors du verrou. Les plus anciens points sont écrasés. |
| Commandes | `Channel{Commande}(16)` | principal → boucle | Démarrer, arrêter, changer une consigne ou un gain | La boucle les lit une fois par créneau, seulement si `isready` : elle n'attend jamais. |
| Arrêt | `Threads.Atomic{Bool}` | principal → boucle | Arrêt immédiat | Lu entre deux blocs de relecture, toutes les 20 ms |
| Journal | `Channel` + compteur `Threads.Atomic{Int}` des entrées en attente | boucle → journal | Relecture complète du créneau, ligne de visite, événements | Un `put!` sur une file pleine bloquerait la boucle : au-delà de la capacité, elle jette l'entrée et incrémente un compteur affiché. |

Le motif de l'affichage, des deux côtés :

```julia
# Côté boucle, une fois par créneau : quelques microsecondes sous le verrou
lock(aff.verrou) do
    aff.n += 1
    aff.resumes[mod1(aff.n, length(aff.resumes))] = resume   # resume : struct sans pointeur
end

# Côté interface : créée depuis le thread principal, spawn = false l'y garde
minuterie = Timer(0.0; interval = 1/30, spawn = false) do _
    n = lock(() -> copier_nouveaux!(copie, aff), aff.verrou)   # copie rapide
    n > 0 && mettre_a_jour_figure!(obs, copie, n)             # hors du verrou
end
```

## 5. Une interface sans saccades

Les saccades d'une interface GLMakie reliée à une boucle d'acquisition ont des causes connues, et chacune a sa parade. Parcours ton code actuel avec ce tableau.

| Cause | Ce que tu vois | Parade |
| --- | --- | --- |
| Travail long sur le thread principal : lecture de carte, ajustement ou écriture de fichier dans un rappel, ou dans le script qui a ouvert la fenêtre | La fenêtre fige tant que le travail dure | Tout travail de plus de quelques millisecondes part dans `Threads.@spawn`. Le script de lancement attend la boucle avec `wait(tache)`, qui laisse tourner le rendu. |
| `Observable` modifié depuis un autre thread | Comportement erratique, voire plantage : GLMakie n'est pas sûr entre threads | Seul le thread principal touche aux Observables, par la minuterie de la section 4. En mise au point, ajoute `@assert Threads.threadid() == 1` dans `mettre_a_jour_figure!`. |
| Mises à jour trop fréquentes ou trop grosses : un `obs[] = …` par point, des tableaux qui grandissent sans fin | L'affichage ralentit avec le temps, saccades régulières | Une seule mise à jour groupée par tick, à 30 Hz. Tampons de taille fixe (`Vector{Point2f}` préalloués, remplis en place, puis un seul `notify`). Relecture décimée à quelques milliers de points par courbe. |
| Tracés recréés à chaque mise à jour (`lines!`, `empty!`) | Mémoire et temps de mise à jour qui grandissent | Créer chaque tracé une fois, puis ne changer que ses Observables |
| Limites d'axes recalculées à chaque tick (`autolimits!`, `reset_limits!`) | Mise en page recalculée 30 fois par seconde | Limites fixes, ou recalcul au plus une fois par seconde |
| Ramasse-miettes : Julia arrête tous les threads pendant une collecte, et doit attendre qu'un thread bloqué dans un `ccall` en sorte | Saccade de quelques millisecondes ; jusqu'à la durée d'une lecture NI-DAQmx, environ 220 ms, si la boucle attend la carte dans un `ccall` ordinaire | `@ccall gc_safe=true` pour les appels bloquants de la boucle (section 6) ; peu d'allocations dans la boucle et dans la minuterie ; journal écrit par petits morceaux |
| Compilation au premier usage : premier clic, premier affichage d'un type de tracé | Un gel unique, de quelques centaines de millisecondes à quelques secondes | Au démarrage, affiche la figure et appelle une fois chaque rappel et `mettre_a_jour_figure!` avec des données factices |

Garde les réglages par défaut de GLMakie : rendu à la demande (`render_on_demand = true`) à 30 images par seconde (`framerate = 30`). Une cadence plus haute ne se voit pas et prend du temps au thread principal.

Si des saccades restent après tout cela, dernier recours : mettre l'interface dans un second processus Julia, puisque chaque processus a son propre ramasse-miettes. Ne le fais que si les mesures de la section 9 le justifient.

## 6. Une boucle régulière

Windows n'est pas un système temps réel, mais la boucle n'en a pas besoin : l'horloge des cartes fixe le rythme, il suffit que chaque itération reste courte. Ces règles servent aussi l'interface, puisque tout ce qui bloque le ramasse-miettes la bloque avec.

1. **Aucune allocation en régime permanent.** Tampons du créneau et de la relecture alloués une fois, remplis en place. Vérifie avec `@allocated` qu'une itération n'alloue presque rien.
2. **Lire par blocs de 20 ms, en `gc_safe`.** Chaque appel bloquant dure alors 20 ms au plus, le drapeau d'arrêt est lu entre deux blocs, et depuis Julia 1.12 le ramasse-miettes peut tourner pendant l'attente :

   ```julia
   const BLOC = 200                          # 20 ms à 10 kHz
   lus = Ref{Int32}(0)
   GC.@preserve tampon for i in 1:(longueur_creneau() ÷ BLOC)
       arret[] && break                      # drapeau posé par l'interface
       chk(@ccall gc_safe=true "nicaiu".DAQmxReadAnalogF64(
               tai::Ptr{Cvoid}, BLOC::Int32, 1.0::Float64,
               1::UInt32,                    # entrelacé : blocs mis bout à bout
               pointer(tampon, (i - 1) * BLOC * nv + 1)::Ptr{Float64},
               (BLOC * nv)::UInt32, lus::Ptr{Int32}, C_NULL::Ptr{UInt32})::Int32)
   end
   ```

   `gc_safe=true` ne convient qu'aux fonctions C qui ne rappellent pas Julia, ce qui est le cas des lectures et des attentes NI-DAQmx.
3. **Préchauffer avant le premier créneau.** Exécute une itération complète sur des données factices : la compilation ne doit pas tomber sur la première échéance.
4. **Rien de lent dans la boucle.** Pas de `println`, de tracé ni de fichier : seulement les échanges de la section 4.
5. **Mesurer chaque itération.** Garde, comme `durees` aujourd'hui, le temps de préparation et d'écriture, et affiche le maximum dans l'interface ; alarme au-delà de 220 ms, la moitié de l'échéance.
6. **Priorité haute.** Lance l'application depuis un fichier `.bat` :

   ```bat
   start "" /high julia --project -t 3,1 scripts\app.jl config\banc.toml
   ```
7. **Pas de rappels NI-DAQmx** de type « Every N Samples » : ils appelleraient Julia depuis un thread de NI. La lecture par blocs fait la même chose plus simplement.
8. **La configuration dans un fichier TOML**, lue au démarrage, plutôt que dans des `const` : ça évite aussi les conflits de constantes rencontrés entre les tests.

## 7. Sécurité

Les protections se superposent, du logiciel au mécanique, pour qu'un plantage de l'interface ou de la boucle ne laisse jamais un laser allumé.

1. **Limites logicielles** : `LIMITE_P850`, `LIMITE_P1064` et `clamp` à la préparation de chaque créneau ; `verifier_bloc` refuse un galvo hors limite ou une valeur non finie.
2. **Plage de la voie NI-DAQmx** : la voie de la Pockels déclarée de 0 à 1 V ; NI-DAQmx refuse toute écriture hors plage (erreur -200561).
3. **Créneaux qui finissent éteints** : chaque créneau se termine par la pause, lasers à zéro et portes basses. La régénération étant interdite, une boucle qui cesse d'écrire arrête la génération sur cet état éteint.
4. **Arrêt depuis l'interface** : le bouton pose le drapeau `arret` ; la boucle le voit en 20 ms au plus, arrête les tâches et appelle `mise_a_zero()`. Fermer la fenêtre doit faire la même chose : `on(events(fig).window_open) do ouverte; ouverte || (arret[] = true) end`.
5. **Chien de garde de la 6321** : si la boucle ne le réarme pas à temps (par exemple 1 s), les lignes numériques passent à l'état sûr choisi. Il ne couvre que les lignes numériques et PFI : la sécurité du 1064 nm doit donc passer par une ligne numérique, obturateur ou entrée de blocage.
6. **`try … finally` dans la boucle** : toute erreur appelle `mise_a_zero()`, libère les tâches et met le contrôleur en défaut ; l'interface l'affiche.
7. **Obturateur au démarrage du PC** : fermé tant que le pilote n'a pas initialisé les cartes, car les sorties de la 6110 peuvent être à ±0,4 V avant le chargement de l'étalonnage.

| État | Sorties | On en sort quand |
| --- | --- | --- |
| INIT | Tâches créées, tout à zéro, préchauffage | Configuration valide → PRÊT |
| PRÊT | Zéro, obturateur fermé | Bouton « démarrer » → EN MARCHE |
| EN MARCHE | Créneaux joués, boucle fermée | « arrêter » ou fenêtre fermée → ARRÊT ; erreur ou échéance manquée → DÉFAUT |
| ARRÊT | Tâches arrêtées, mise à zéro | Immédiatement → PRÊT |
| DÉFAUT | Mise à zéro, tâches libérées, journal fermé | Acquittement dans l'interface → INIT |

Une échéance manquée, c'est-à-dire un tampon vidé (erreur -200290), mène en défaut : la séquence n'est plus fiable. Teste chaque protection une fois, volontairement, avant la première expérience sur tranche.

## 8. Organisation du code

La règle de rangement suit les threads : chaque fichier appartient à un seul thread, sauf `echanges.jl`, qui est le seul point de contact. Le tout forme un module `Banc`, chargé une fois avec `using Banc` ; pendant le développement, Revise.jl recharge les fichiers modifiés sans redémarrer.

```text
banc-chlore/
├── Project.toml
├── config/banc.toml          # cartes, voies, limites, durées, régions, consignes
├── src/
│   ├── Banc.jl               # inclut tout le reste
│   ├── echanges.jl           # tampon d'affichage, commandes, arrêt, file du journal
│   ├── boucle/               # thread Boucle
│   │   ├── DAQmxLite.jl      # appels NI-DAQmx, lectures en gc_safe
│   │   ├── taches.jl         # tâches, horloge du compteur, RTSI, chien de garde
│   │   ├── securite.jl       # limites, verifier_bloc, mise_a_zero
│   │   ├── sequence.jl       # forme des créneaux, remplie en place
│   │   ├── generateur.jl     # demarrer, pas!, arreter
│   │   ├── mesure.jl         # simulation du test 11 ; le TCSPC plus tard
│   │   ├── correcteur.jl     # observateur + PI
│   │   └── boucle.jl         # l'itération par créneau, l'état du contrôleur
│   ├── journal.jl            # thread Journal
│   ├── interface/            # thread principal
│   │   ├── fenetre.jl        # construit la figure et ses tracés, une fois
│   │   ├── rafraichir.jl     # minuterie 30 Hz : tampon → Observables
│   │   └── rappels.jl        # boutons → commandes ou Threads.@spawn
│   └── app.jl                # ouvre la fenêtre, préchauffe, lance les threads
├── scripts/
│   ├── app.jl                # point d'entrée : using Banc; Banc.lancer(ARGS[1])
│   ├── lancer.bat            # priorité haute, -t 3,1
│   └── tests/                # test1 à test11
└── analyse/                  # traces.jl, verif.jl, lecteur SDT
```

Pour adapter ton application sans tout réécrire, repère dans ton code :

- chaque appel à une fonction NI-DAQmx : il doit se trouver dans `boucle/` et être appelé seulement depuis le thread Boucle ;
- chaque `obs[] = …`, `notify`, `lines!`, `autolimits!` : seulement dans `fenetre.jl` (construction) et `rafraichir.jl` (mise à jour) ;
- chaque rappel `on(...)` de bouton ou de curseur : il ne fait que déposer une commande ou lancer une tâche ;
- chaque écriture de fichier : seulement dans `journal.jl`, ou dans une tâche lancée depuis un rappel ;
- chaque variable globale lue par deux threads : elle doit passer par `echanges.jl`.

## 9. Ce que cette architecture garantit

Elle garantit la régularité des sorties et l'isolement entre la boucle et l'interface ; elle ne peut pas garantir un affichage absolument sans saccade, parce que le ramasse-miettes de Julia arrête tous les threads. Elle est optimisée pour la régularité, pas pour la vitesse brute : la boucle passe l'essentiel de son temps à attendre les cartes.

| Propriété | Garantie | Pourquoi, ou à quelle condition |
| --- | --- | --- |
| Instants des sorties (galvos, lasers, portes) | Oui, à la précision de l'horloge des cartes | Cadencés par l'horloge matérielle partagée par RTSI : un retard du logiciel inférieur à 440 ms ne change rien à ce qui sort |
| Aucun créneau manqué | Oui, tant qu'une itération reste sous 440 ms | 1,3 ms mesurée au test 10, sans l'ajustement de durée de vie |
| L'interface ne retarde jamais la boucle | Oui | La boucle ne touche à rien de l'interface, et ses échanges ne bloquent pas |
| La boucle ne fige pas l'interface | Oui, avec les lectures par blocs en `gc_safe` | Sans elles, une collecte peut attendre la fin d'une lecture : jusqu'à environ 220 ms de gel |
| Aucune saccade d'affichage | Non, pas absolument | Peu d'allocations rendent les collectes courtes et rares ; seul un second processus les retirerait de l'interface |

Ce sont les mesures qui confirmeront le résultat sur ton banc. Cibles proposées, à relever sur une heure de fonctionnement :

| Mesure | Comment | Cible |
| --- | --- | --- |
| Durée d'une itération de la boucle | `durees`, maximum affiché dans l'interface | Moins de 20 ms ; alarme au-delà de 220 ms |
| Intervalle entre deux ticks de la minuterie d'affichage | `time_ns()` relevé dans la minuterie | Environ 33 ms ; maximum sous 100 ms, au-delà une saccade se voit |
| Pauses du ramasse-miettes | `GC.enable_logging(true)` | Moins de 20 ms chacune |
| Entrées jetées par la boucle | Compteur atomique du journal | Zéro |
| Mémoire de l'application | Gestionnaire des tâches de Windows | Stable, sans croissance continue |

## 10. Ordre des modifications

Commence par mesurer ta version actuelle, puis applique les changements dans l'ordre où ils réduisent le plus les saccades ; chaque étape a un test qui doit passer avant la suivante.

| Étape | Modification | Terminée quand |
| --- | --- | --- |
| 1 | Ajouter les mesures de la section 9 à ta version actuelle | Tu connais le pire intervalle entre deux ticks et la plus longue pause du ramasse-miettes |
| 2 | Sortir tout accès aux cartes du thread principal : boucle lancée par `Threads.@spawn`, Julia démarré avec `-t 3,1` | La fenêtre reste réactive pendant toute la séquence du test 10 |
| 3 | Plus aucun Observable touché hors du thread principal : tampon d'affichage et minuterie à 30 Hz | `@assert Threads.threadid() == 1` ne se déclenche jamais en une heure |
| 4 | Lectures par blocs de 20 ms en `gc_safe` | Aucun intervalle entre ticks au-dessus de 100 ms ; pauses du ramasse-miettes sous 20 ms |
| 5 | Tampons de taille fixe, tracés créés une fois, limites d'axes fixes | Mémoire stable et temps de mise à jour constant sur une heure |
| 6 | Journal dans son propre thread | Une heure sans entrée jetée |
| 7 | Préchauffage et priorité haute | Aucun gel au premier clic ni au premier créneau |
| 8 | Arrêt par drapeau, fermeture de fenêtre, chien de garde, obturateur | Après « arrêter », la relecture montre toutes les sorties à zéro en moins de 50 ms |

## Sources

- [GLMakie — documentation](https://docs.makie.org/stable/explanations/backends/glmakie) : GLMakie n'est pas sûr entre threads ; rendu à la demande et 30 images par seconde par défaut.
- [Makie — ticket #3833](https://github.com/MakieOrg/Makie.jl/issues/3833) : plantage quand un Observable est modifié depuis `Threads.@spawn`.
- [GLMakie — screen.jl](https://github.com/MakieOrg/Makie.jl/blob/master/GLMakie/src/screen.jl) : boucle de rendu lancée par `@async`.
- [Julia 1.12 — notes de version](https://github.com/JuliaLang/julia/blob/v1.12.0/NEWS.md) : option `gc_safe` de `@ccall`, thread interactif par défaut.
- [Julia — documentation de `@ccall`](https://github.com/JuliaLang/julia/blob/v1.13.0/base/c.jl) : effet de `gc_safe=true` et précautions.
- [Julia — `Timer`](https://github.com/JuliaLang/julia/blob/v1.13.0/base/asyncevent.jl) : option `spawn` et thread d'exécution de la minuterie.
- X Series User Manual (documents du projet) : chien de garde, limité aux lignes numériques et PFI.
- Fiche technique de la PCI-6110 (documents du projet) : tension de sortie à la mise sous tension.
- [Banc DAQ sur Windows 11 — installation de A à Z](https://claude.ai/artifact/AFF23PKuLqVPXvseVRkWbi) : durées mesurées au test 10.
