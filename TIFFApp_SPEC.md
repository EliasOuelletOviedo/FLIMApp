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

> **Révisé après enquête sur 151 sessions réelles.** La spec initiale
> supposait un compteur global unique. C'est faux dans les deux sens décrits
> ci-dessous, et chaque erreur produit des ratios **plausibles mais faux**,
> sans aucun message d'erreur.

**Deux conventions coexistent sur le disque, détectées et non supposées :**

| Convention | Sessions | Règle |
|---|---|---|
| **Globale** | 148 | Un compteur partagé, incrémenté à chaque fichier écrit. Les canaux ont des valeurs disjointes et entrelacées (C1 = {1,3,5…}, C2 = {2,4,6…}). Instance = `cld(T, N)`. |
| **Par canal** | 3 | Chaque canal compte depuis 1 indépendamment ; tous les canaux ont le **même** ensemble de valeurs. Instance = `T`. |

**Discriminant** (`detect_numbering`) : proportion de valeurs `T` **distinctes**
rapportée au nombre de fichiers. En numérotation globale chaque fichier
consomme un numéro, donc les deux comptes sont égaux (ratio ≈ 1). En
numérotation par canal, `N` canaux se partagent chaque valeur (ratio ≈ 1/N). Le
seuil est placé à mi-chemin entre les deux attentes.

> **Pourquoi une proportion et non « une collision suffit ».** Le test binaire
> initial — une valeur présente dans deux canaux ⇒ numérotation par canal — est
> beaucoup trop fragile. Une acquisition réelle de 1764 fichiers a produit deux
> ratés du compteur : le logiciel a sauté une valeur puis écrit la suivante en
> double, une fois pour chaque canal. Deux fichiers anormaux sur 1764
> reclassaient tout le jeu, mappaient chaque fichier sur sa propre instance et
> déclaraient les 588 instances incomplètes — jeu illisible à cause de deux
> fichiers. Le groupement `cld` absorbe ce raté sans problème ; seule la
> détection devait cesser d'y voir une preuve.

Les deux conventions coïncident pour une acquisition mono-canal.

Le groupement dérive de la valeur du compteur, jamais de la position du
fichier dans le listing : si un canal perd un fichier, le groupement par
position décale ce canal d'un cran et **toutes les instances suivantes sont
mal appariées** en silence.

Exemple à 2 canaux, numérotation globale : C1 = {T001, T004, T006},
C2 = {T002, T003, T005} → instances (T001,T002), (T004,T003), (T006,T005).

### 1.4 Nombre et *noms* des canaux

Le nombre de canaux vient du décompte des dossiers `C<n>`, donc connu avant
toute lecture de pixel.

> **Les noms de canaux ne sont pas des positions.** 33 des sessions étudiées
> contiennent `C1` et `C3`, **sans `C2`**. La combinaison choisie dans le GUI
> nomme des canaux (« C1/C3 »), pas des indices : elle doit être résolue via
> `channel_numbers` (`channel_position`). Indexer directement
> `channel_means[3]` sur une acquisition à deux dossiers dépasse la borne et
> renvoie un ratio `NaN` pour une session dont les données sont pourtant
> parfaitement exploitables.

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
| oui | oui | **Round-robin temporel** : chaque **instance** (le groupe complet de N fichiers, un par canal) appartient à un seul ROI — le galvo scanne un ROI et la caméra écrit ses 2-3 canaux pour ce ROI. `RoiSlotTracker`, la boîte de trigger et la réparation des trous sont conservés, mais cadencés à l'instance et non au fichier. |
| sinon | | **Masques spatiaux** : chaque image contient tous les ROIs ; on applique chaque masque à chaque instance et tous les ROIs sont mis à jour à chaque frame. |

Le popup ROI accepte **les deux** sources d'image de fond : import manuel d'un
fichier TIFF, et capture de la dernière frame reçue de l'acquisition.

### 3.1 Espace de coordonnées des ROIs

Les coordonnées des ROIs sont dans l'espace de pixels de l'**image de
référence** sur laquelle ils ont été dessinés (`AppRun.imported_image_size`),
pas dans celui de l'image d'acquisition. C'est la convention que `roi.jl`
utilise déjà pour la cartographie en tension du galvo.

Les deux tailles diffèrent dès que la référence vient de la capture de frame
live : c'est le *preview*, sous-échantillonné (`FramePreview.stride`, typiquement
1/4). `roi_coordinate_scale` convertit donc les coordonnées avant la
rastérisation. Sans cette conversion, chaque ROI se retrouve dans un coin de
l'image et mesure les mauvais pixels — sans aucun signal d'erreur.

### 3.2 Nombre de séries

Le nombre de séries (`AppRun.rois_series`) et le nombre de régions produites
par le worker **doivent concorder** : `consumer_loop` ignore les régions
au-delà de la fin de `rois_series`. Les deux dérivent du nombre de ROIs
dessinés.

La bascule `app.roi.active` ne conditionne **pas** ce nombre — elle ne
sélectionne, avec `app.protocol.active`, que le *modèle* de ROI (round-robin ou
masques spatiaux). La conditionner ici faisait disparaître silencieusement tous
les ROIs sauf le premier.

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
- stockage dans le **type natif** de l'échantillon (`UInt8` aujourd'hui,
  `UInt16` si la caméra change) plutôt qu'en `Float64` — un facteur 4 à 8 ;
- tampon circulaire préalloué, réutilisé : `push_frame!` mesure ~48 octets par
  frame en régime permanent, et `read_frame!` n'alloue aucun pixel ;
- somme glissante entretenue de façon incrémentale (ajout du nouveau, retrait
  du plus ancien), en `UInt32` ;
- **une case de rab** : le tampon alloue `profondeur + 1` frames. Sans elle, à
  la fenêtre maximale, la frame entrante écrase la frame sortante avant qu'on
  puisse la soustraire — la somme reste plausible et fausse pour le reste de
  l'acquisition. Trouvé en comparant à une re-sommation naïve, pas en relisant
  le code.

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

## 11. Format réel des fichiers (vérifié)

Mesuré sur `~/Documents/Maîtrise/Test galvo`, 6 sessions, 54 en-têtes
échantillonnés — **strictement uniformes** :

| Propriété | Valeur |
|---|---|
| Format | **BigTIFF** (version 43), little-endian |
| Dimensions | 1024 × 1024 **ou** 1024 × 512 selon la session — d'où l'allocation dynamique du tampon |
| Profondeur | **8 bits** (`BitsPerSample = 8`), 1 échantillon par pixel |
| Compression | **aucune** (`Compression = 1`) |
| Disposition | **une seule bande**, données contiguës à l'offset fixe **3840** |
| Charge utile | 1 048 576 octets ; fichier total 1 052 416 octets |
| Producteur | `Nirvana 2.31.4` |
| `ImageDescription` | `{"shape": [1024, 1024, 1]}` |
| IFD suivant | aucun (image unique par fichier) |

La règle de groupement globale de la section 1.3 a été validée sur **2690
fichiers réels : zéro violation** pour les sessions concernées. L'enquête
élargie à 151 sessions a ensuite révélé la convention par canal et les noms de
canaux non contigus, tous deux traités en 1.3 et 1.4.

Le pipeline complet (résolution du dossier → groupement → lecture → binning →
ratio) a été vérifié sur un représentant de **chacune des quatre formes**
présentes sur le disque :

| Forme | Géométrie | Instances | Résultat |
|---|---|---|---|
| `C1 C2 C3`, par canal | 1024×512 | 1443 | ratios finis |
| `C1 C2`, globale | 1024×1024 | 600 | ratios finis |
| `C1 C3`, globale | 1024×512 | 3 | ratios finis (« C1/C3 » résolu correctement) |
| `C2` seul | 1024×1024 | 1024 | « C1/C2 » → `NaN`, comme prévu |

Note : 1024 × 1024 correspond exactement à la référence de calibration galvo
déjà présente dans `roi.jl` et au défaut de `imported_image_size`.

## 12. Lecteur TIFF — décision

Un **lecteur BigTIFF minimal maison** (`src/io/BigTiffFile.jl`, dans l'esprit
de l'ancien `io/SdtFile.jl`), sans dépendance externe. Justifié par le
benchmark ci-dessous : les données étant un bloc contigu non compressé à offset
fixe, la lecture se réduit à un `seek` + `read!` dans un tampon préalloué.

Mesures sur 200 fichiers réels (Julia 1.11, disque local) :

| Approche | Temps par fichier |
|---|---|
| `read()` du fichier entier | 0.173 ms |
| **`seek` + `read!` dans un tampon préalloué** | **0.081 ms** |
| `mmap` + parcours complet | 0.160 ms |
| *(comparaison)* `mean()` sur 1024×1024 `UInt8` | 0.326 ms |

Budget temps réel à 60 Hz × 2 canaux : **8.33 ms par fichier**. L'approche
retenue consomme **~1 %** de ce budget, et la lecture n'est même pas le facteur
limitant — la réduction `mean()` coûte 4× plus cher que l'I/O. Marge d'environ
20× sur la chaîne complète.

Le lecteur parse l'IFD pour lire la géométrie (largeur, hauteur,
`BitsPerSample`, `StripOffsets`, `StripByteCounts`) plutôt que de coder en dur
l'offset 3840, et prend en charge `BitsPerSample` de 8 **et** 16 pour rester
valide si la profondeur d'acquisition change. Il refuse explicitement les
fichiers compressés ou multi-bandes plutôt que de les lire de travers.

Conséquence mémoire : à 8 bits, le tampon de 50 frames × 3 canaux × 1024×1024
occupe **~157 Mo** (~314 Mo si l'acquisition passe en 16 bits).
