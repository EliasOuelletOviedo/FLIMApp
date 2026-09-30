# reglages_dcc.jl — réglages des DCC-100 pour allumer les détecteurs sans le
# logiciel DCC. Utilisé par test_dcc1_reglages.jl et test_dcc2_allumage.jl.
#
# Recopiés du panneau « M1 DCC-100 » de SPCM (photo du 30 septembre 2026).
# Clé du Dict = numéro de module de la DLL : 0 pour M1, 1 pour M2. Seuls les
# modules listés ici sont initialisés ; les autres ne sont pas touchés.
# Vérifie que le module 0 est bien M1 : test_dcc1 affiche son numéro de
# série, à comparer avec celui du bouton « Show Info » du panneau M1.
#
# Clés du manuel de la DLL DCC (les majuscules comptent) :
#   c1_… connecteur 1, c2_… connecteur 2, c3_… connecteur 3 ;
#   p12V, p5V, m5V : alimentations +12 V, +5 V, -5 V (1 = allumée) ;
#   gain_HV : gain / haute tension en % ; digout : sorties b7…b0 du connecteur 2 ;
#   cooling, coolVolt (V), coolCurr (limite de courant, A) : refroidisseur du connecteur 3.
REGLAGES_DCC = Dict(
    0 => Dict{String,Any}(               # M1
        # Connecteur 1 : alimentations et gain
        "c1_p12V" => 1, "c1_p5V" => 1, "c1_m5V" => 1,
        "c1_gain_HV" => 82.0,            # %
        # Connecteur 2 : alimentations coupées, sortie numérique b0 à 1
        "c2_p12V" => 0, "c2_p5V" => 0, "c2_m5V" => 0,
        "c2_digout" => 0b00000001,       # b7…b0
        # Connecteur 3 : alimentations, gain et refroidissement
        "c3_p12V" => 1, "c3_p5V" => 1, "c3_m5V" => 1,
        "c3_gain_HV" => 82.0,            # %
        "c3_cooling" => 1,
        "c3_coolVolt" => 5.0,            # V, 0 à 5
        "c3_coolCurr" => 1.98,           # A, limite de courant, 0 à 2
    ),
    # 1 => Dict{String,Any}(…),          # M2 : à remplir s'il alimente aussi un détecteur
)
