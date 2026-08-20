# TIFFApp — spécification de la conversion FLIM → ratiométrie TIFF

Branche `TIFFApp`, dérivée de `FLIMApp` (= état de `main` au commit `82131c2`).

Ce document consigne les décisions prises avant l'implémentation. Il remplace
la lecture de fichiers `.sdt` et le fit de temps de vie par la lecture d'images
TIFF multi-canaux et le calcul de ratios de type FRET. Tout le reste de
l'application (protocole, ROIs, contrôle PI, série, lissage Kalman, thèmes,
persistance d'état) est conservé.

---

## 1. Source de données

### 1.1 Arborescence sur disque

```
<dossier sélectionné>/
  <dossier de session, créé au début de l'acquisition>/
    Bliq VMS/
      C1/  Nom_du_fichier-C1-T001.tif
           Nom_du_fichier-C1-T004.tif
           Nom_du_fichier-C1-T006.tif
      C2/  Nom_du_fichier-C2-T002.tif
           Nom_du_fichier-C2-T003.tif
           Nom_du_fichier-C2-T005.tif
      C3/  (optionnel)
```

### 1.2 Découverte du dossier de session

- **Realtime** : le dossier de session n'existe pas encore au START. L'app
  surveille le dossier sélectionné, attend l'apparition d'un nouveau
  sous-dossier, vérifie qu'il contient `Bliq VMS`, puis travaille dedans.
- **Playback / Save** : le dossier est sélectionné directement. Le code doit
  accepter **les deux cas** : un dossier qui *contient* `Bliq VMS`, ou un
  dossier qui *est* `Bliq VMS`.

### 1.3 Numérotation `T###` et groupement des canaux

Le compteur `T###` est **global** — partagé entre les canaux au moment de
l'écriture, pas remis à zéro par canal. Conséquence : pour l'instance `k`
(1-based) avec `N` canaux, chaque canal possède exactement un fichier dont le
numéro `T` est dans `[N·(k−1)+1, N·k]`.

**Règle de groupement** : trier les fichiers de chaque dossier de canal par
numéro `T` ; le `k`-ième fichier de chaque canal forme l'instance `k`. Valider
que chaque `T` tombe bien dans la plage attendue et journaliser une anomalie
sinon.

Exemple à 2 canaux : C1 = {T001, T004, T006}, C2 = {T002, T003, T005}
→ instance 1 = (T001, T002), instance 2 = (T004, T003), instance 3 = (T006, T005).

### 1.4 Nombre de canaux

Détecté automatiquement (2 ou 3) depuis la première instance lue, puis figé
pour toute l'acquisition — même logique que `has_channel2` aujourd'hui.

### 1.5 Groupes incomplets (Realtime)

Attendre que tous les canaux aient leur fichier, avec **timeout dérivé de la
cadence observée** (multiple de l'intervalle médian entre instances, dans
l'esprit de `update_roi_slot_period!`). Au-delà du timeout, l'instance est
marquée manquante et la boucle passe à la suivante.

---

## 2. Calcul du ratio

### 2.1 Réduction spatiale

**Ratio des moyennes** : on moyenne chaque canal sur la région, puis on divise.

```
num   = mean(C_num[masque])
den   = mean(C_den[masque])
ratio = num / den
```

Pas de soustraction de fond, pas de seuil, pas de correction de bleedthrough,
pas de binning spatial pour l'instant.

### 2.2 Sélection des canaux

Le menu qui servait à choisir le nombre de temps de vie
(`1 lifetime` / `2 lifetimes` / `3 lifetimes`) devient le sélecteur de
combinaison, avec les **6 combinaisons ordonnées** :

```
C1/C2   C1/C3   C2/C1   C2/C3   C3/C1   C3/C2
```

Les 6 options restent toujours affichées. Si la combinaison choisie fait
référence à un canal absent, l'acquisition démarre quand même et le ratio vaut
`NaN` — les intensités moyennes par canal restent tracées et exploitables.

### 2.3 Concentration dérivée du ratio

Fonction de Hill inversée, **avec bornage** (pas de `NaN` hors plage) :

```julia
# Constantes de calibration — provisoires, à ajuster.
const HILL_KD    = 46.4
const HILL_N     = 1.21
const HILL_RMIN  = 0.55   # R à [concentration] = 0
const HILL_RMAX  = 1.86   # R à [concentration] = ∞

function hill_ratio_to_concentration(R)
    Rc = clamp(R, HILL_RMIN + eps(), HILL_RMAX - eps())
    return HILL_KD * ((Rc - HILL_RMIN) / (HILL_RMAX - Rc))^(1 / HILL_N)
end
```

L'équation doit rester **facile à modifier dans le code** : constantes nommées
en tête de fichier, une seule fonction à remplacer.

---

## 3. ROIs

Le comportement dépend de l'état des bascules `app.roi.active` et
`app.protocol.active` :

| ROI actif | Protocole actif | Comportement |
|---|---|---|
| oui | oui | **Round-robin temporel** : chaque instance de fichiers appartient à un seul ROI (le galvo scanne séquentiellement). `RoiSlotTracker`, la boîte de trigger et la réparation des trous sont conservés tels quels. |
| sinon | | **Masques spatiaux** : chaque image contient tous les ROIs ; on applique chaque masque à chaque instance et tous les ROIs sont mis à jour à chaque frame. |

Le popup ROI accepte **les deux** sources d'image de fond : import manuel d'un
fichier TIFF, et capture de la dernière frame reçue de l'acquisition.

---

## 4. Contrôle PI

Un seul ratio calculé → les deux sorties PI existantes appliquent chacune leurs
propres gains sur cette erreur commune. C'est exactement le comportement actuel
lorsqu'un fichier SDT n'a qu'un seul canal (voir `pid_command_from_state`).

Les setpoints du protocole sont **en unités de ratio** (typiquement entre
`R_min = 0.55` et `R_max = 1.86`). Aucune conversion Hill dans la boucle de
contrôle.

---

## 5. Axe temporel

- **Realtime** : temps réel écoulé depuis la détection du premier fichier.
- **Playback** : numéro d'image, `dt = 1`. Le réglage « Time range » devient un
  nombre de frames ; le terme intégral du PI utilise `dt = 1` par frame.

---

## 6. Binning temporel et mémoire

Tampon d'**images complètes** (pas de réduction préalable aux scalaires),
profondeur **maximale 50 frames**, avec réduction agressive de l'allocation :

- allocation dynamique à la première image lue (taille variable selon
  l'expérience) ;
- stockage en `UInt16` plutôt qu'en `Float64` (÷4) ;
- tampon circulaire préalloué, réutilisé — aucune allocation par frame ;
- somme glissante entretenue de façon incrémentale (ajout du nouveau, retrait
  du plus ancien), comme le fait déjà `process_frame!` ;
- lecture TIFF dans un tampon réutilisé quand la bibliothèque le permet.

---

## 7. Graphiques

Menus Plot 1 / Plot 2 :

| Nouveau | Remplace | Contenu |
|---|---|---|
| Ratio | Lifetime | Série temporelle du ratio + ligne de setpoint + vspan protocole, une courbe par ROI |
| Intensité moyenne | Photon counts | Moyenne brute par canal, une courbe par (canal, ROI) |
| Image / carte de ratio | Histogram | Dernière image reçue, ou carte de ratio 2D colorée |
| Concentration | Ion concentration | Hill inversée bornée, appliquée au ratio |
| Command | *(conservé)* | Sorties PI, calculées sur l'erreur de ratio |

---

## 8. Suppressions

Le code de temps de vie est **supprimé complètement** :

- `src/lifetime_analysis.jl` (888 lignes)
- `src/io/SdtFile.jl` (~1200 lignes)
- Le warmup JIT du fit (`warmup_lifetime_fitting!`) et son appel dans `run_app`
- Les contrôles IRF du GUI (champ de chemin + bouton), et le rattrapage de
  grille correspondant
- Dépendances retirées de `Project.toml` : `Optim`, `LineSearches`, `FFTW`,
  `AbstractFFTs`, `ZipFile`

---

## 9. Renommage

Renommage complet en `TIFFApp` : `module TIFFApp`, `src/TIFFApp.jl`,
`Project.toml` (nom + nouvel UUID), scripts de build et tests.

---

## 10. Mode Save

Séries scalaires en CSV — ratios, intensités par canal, concentrations,
commandes et horodatages par ROI. Réutilise l'infrastructure existante
(`write_realtime_capture_csv!`, `roi_channel_series_dataframe`), en remplaçant
les colonnes `lifetime_*` par `ratio` / `C1_mean` / `C2_mean` / `C3_mean`.

---

## 11. Point ouvert

**Bibliothèque TIFF** : à choisir sur critère de vitesse pure, pour tenir le
régime temps réel. Décision à prendre après benchmark sur un jeu de données
réel (candidats : `TiffImages.jl` en accès paresseux/mmap, `FileIO`+`ImageIO`,
ou un lecteur minimal maison sur le modèle de `io/SdtFile.jl` si les fichiers
Bliq VMS sont non compressés et de structure fixe).
