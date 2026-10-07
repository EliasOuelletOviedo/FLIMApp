# reglages_qc.jl — réglages de la SPC-QC-104, en noms clairs. Utilisé par
# qc2 à qc6. SPCLite.parametres_qc les traduit en clés de la DLL (la DLL
# réutilise des noms de la SPC-150 avec un autre sens : par exemple
# cfd_limit_high est le seuil de IN2 ; tableau complet dans SPCLite.jl).
#
# À REMPLIR avec les valeurs de SPCM (panneau « System Parameters » de la
# QC-104) qui te donnent un beau déclin sur chaque entrée. Les CFD de la
# QC-104 sont ceux des SPC-150N : tes réglages de SPC-150N (seuil -51 mV,
# zéro 0 mV) sont un bon départ. B&H propose -60 mV et +12 mV pour une
# première mise en route.
# Ordre de tous les quadruplets : IN1, IN2, IN3, SYNC (= IN4).
REGLAGES_QC = Dict{String,Any}(
    # Entrées : IN1 = détecteur de l'ancienne carte 3N0317 (canal 1),
    # IN2 = détecteur de 3N0318 (canal 2), IN3 libre, SYNC = référence du laser.
    "entrees_actives"   => (true, true, false, true),
    "routage_entrees"   => (true, true, false),    # routage appliqué aux photons de IN1, IN2, IN3
    "photon_unique"     => false,     # false : détection multiphoton (tdc_control bit 20 = 0)
    # Discriminateurs (CFD)
    "seuil_mV"          => (-50.0, -50.0, -50.0, -50.0),   # -500 à 0 mV
    "zc_mV"             => (0.0, 0.0, 0.0, 0.0),           # niveau de zéro, -96 à 96 mV
    # Temps
    "plage_tdc_ns"      => 16.384,    # 1,024 ns à 67 µs ; en FIFO toujours 4096 canaux :
                                      # 16,384 ns = 4 ps par canal (le minimum), couvre la
                                      # période du laser à 80 MHz (12,46 ns)
    "diviseur_sync"     => 1,         # 1, 2 ou 4 : à 1, chaque impulsion du laser sert de référence
    "decalage_ns"       => (0.0, 0.0, 0.0, 0.0),   # 0 à 32,256 ns par pas de 0,512 : place la
                                      # montée du déclin au début de la fenêtre, par entrée
    "retard_routage_ns" => 0,         # lecture du routage après le photon, -57 à 65 ns (pas de 8,192)
)