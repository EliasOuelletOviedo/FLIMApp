# format_fifo_qc104.jl — écrit par qc4_format_fifo.jl, ne pas modifier à la main.
# SPC-QC-104 n° 3T0089, DLL C:\Program Files (x86)\BH\SPCM\DLL\spcm64.dll
# valeur de IN3 déduite (2), non observée
# M1, M2 déduits de M0 et M3 (non observés)
# sens du temps indéterminé (peu de photons ?) : supposé croissant, comme le dit le manuel
# aucun photon invalide observé : bit_invalide inconnu
# bit de perte (FIFO plein) non observé : les pertes se lisent par SPC_FOVFL
isdefined(Main, :SPCLite) || include("SPCLite.jl")
using .SPCLite
FORMAT_QC104 = FormatFIFO(
    nom = "SPC-QC-104 (FIFO, format établi par qc4)",
    mots_inverses = false,
    macrotemps = (0, 12), microtemps = (16, 12), micro_inverse = false,
    routage = (12, 4), voie = (28, 2), valeurs_voie = (0, 1, 2, -1),
    bit_invalide = -1, bit_mtov = -1, bit_perte = -1,
    masque_debord = 0xc0000000, valeur_debord = 0x80000000, compte = (0, 0),
    masque_marqueur = 0x40000000, valeur_marqueur = 0x40000000, bits_marqueurs = (12, 13, 14, 15),
    masque_photon = 0x40000000, valeur_photon = 0x00000000,
    verification = "vérifié le 2026-10-07 11:28 sur la QC-104 n° 3T0089 : 189933 photons et 9057 marqueurs identiques à la DLL (spcm64.dll)")