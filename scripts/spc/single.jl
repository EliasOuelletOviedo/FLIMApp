# single.jl — déclins en mode « Single » (histogramme construit dans la
# carte), lanceur de FLIMCore : remplace histogrammes_single.jl de la
# branche NI-PCIe-6321.
#
#     julia -t auto scripts/spc/single.jl
#
# Réglages : config/spc.toml ([spc_module] et [single] : modules, temps de
# collecte, nombre d'histogrammes, résolution, arrêt sur débordement,
# inversion). Sorties, dans <[enregistrement] dossier>/single, pour chaque
# carte : *.csv (une ligne par canal : canal, temps_ns, h1 … hN, somme ;
# lignes « # » : réglages et fin de chaque mesure), *.svg, *_parametres.ini.
#
# Avant : SPCM fermé ; logiciel DCC ouvert, sorties activées ; laser allumé.

isdefined(Main, :FLIMCore) || include(joinpath(@__DIR__, "..", "..", "src", "spc", "FLIMCore.jl"))
FLIMCore.garde_version()
using .FLIMCore
using Printf

# SPC_REGLAGES : un autre fichier de réglages (par exemple une copie avec [source] type = "simulation").
reglages = lire_reglages(get(ENV, "SPC_REGLAGES", joinpath(@__DIR__, "..", "..", "config", "spc.toml")))

"""Une ligne par histogramme : coups, pic, temps moyen, fin de la mesure."""
function resume(h::HistoSingle)
    total = sum(Int, h.histogramme)
    pic, k = findmax(h.histogramme)
    tmoy = total > 0 ? sum((i - 0.5) * h.dt_ns * h.histogramme[i] for i in eachindex(h.histogramme)) / total : NaN
    @printf("  module %d, %d/%d : %d coups en %.2f s ; pic %d coups à %.3f ns ; temps moyen %.3f ns ; %s\n",
            h.carte, h.numero, h.total, total, h.duree_s, pic, (k - 0.5) * h.dt_ns, tmoy, h.fin)
end

m = demarrer_moteur(reglages)
try
    afficher_etat(verifier(m))
    println("\n$(reglages.n_histogrammes) histogramme(s) de $(reglages.temps_collecte_s) s sur les modules $(reglages.modules_single)")
    commander!(m, Single(reglages.temps_collecte_s, reglages.n_histogrammes))
    fin = attendre_fin(m, :single; f = r -> r isa HistoSingle && resume(r))
    println("\n", fin.erreur ? "ÉCHEC : " : "Terminée : ", fin.raison)
    foreach(f -> println("  ", f), fin.fichiers)
finally
    arreter_moteur(m)          # cartes libérées, même après une erreur
end
