# reglages_spc.jl — réglages du détecteur et du laser pour la SPC-150N.
# Utilisé par test_spc3_taux.jl et test_spc5_photons.jl.
#
# Recopie ici les valeurs de SPCM (panneau « System Parameters ») qui te
# donnent déjà un beau déclin. Les valeurs ci-dessous ne sont qu'un point
# de départ. Plages : manuel de la DLL SPCM, section [spc_module].
REGLAGES_SPC = Dict{String,Any}(
    "sync_threshold" => -70.9,   # mV, seuil du SYNC (-500 à -20)
    "sync_zc_level"  => -6.80,     # mV, passage par zéro du SYNC (-96 à 96)
    "sync_freq_div"  => 1,       # diviseur du SYNC : 1, 2 ou 4
    "cfd_limit_low"  => -139.22,   # mV, seuil du CFD (-500 à 0)
    "cfd_zc_level"   => 12.85,     # mV, passage par zéro du CFD (-96 à 96)
    "tac_range"      => 50.034,    # ns (50 à 5000)
    "tac_gain"       => 4,       # 1 à 15 ; fenêtre = tac_range / tac_gain (12,5 ns ici)
    "tac_offset"     => 3.33,     # % (0 à 50 pour la SPC-150N)
    "tac_limit_low"  => 5.10,     # % de la fenêtre
    "tac_limit_high" => 94.90,    # % de la fenêtre
)
