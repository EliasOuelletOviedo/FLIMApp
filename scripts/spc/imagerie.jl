# imagerie.jl — images à partir des photons (FIFO + horloges du scanner),
# lanceur de FLIMCore : remplace imagerie_photons.jl de la branche NI-PCIe-6321.
#
#     julia -t auto scripts/spc/imagerie.jl                  # une acquisition
#     julia -t auto scripts/spc/imagerie.jl 20260929_153012_module0
#                                                           # retraitement sans les cartes
#
# Réglages : config/spc.toml ([spc_module], [imagerie], [affichage]) ;
# durée : [imagerie] duree_s, 2 s si 0. Le retraitement relit le .spc avec
# la géométrie du fichier de réglages : règle decalage_pixels,
# pixels_par_ligne, decalage_lignes et lignes_par_image, puis relance-le.
#
# Sorties, dans <[enregistrement] dossier>/imagerie, pour chaque carte :
# *_intensite.bmp, *_temps_moyen.bmp, *_declin.svg, *.jls, *.spc (flux brut),
# *_acquisition.ini (de quoi retraiter, géométrie, réglages DCC déclarés) et
# *_parametres.ini (tous les paramètres relus dans la carte).
#
# Avant : SPCM fermé ; logiciel DCC ouvert, sorties activées ; scanner en
# marche ; laser allumé. Le GUI ne doit pas tenir les cartes en même temps.

isdefined(Main, :FLIMCore) || include(joinpath(@__DIR__, "..", "..", "src", "spc", "FLIMCore.jl"))
FLIMCore.garde_version()
using .FLIMCore

# SPC_REGLAGES : un autre fichier de réglages (par exemple une copie avec [source] type = "simulation").
reglages = lire_reglages(get(ENV, "SPC_REGLAGES", joinpath(@__DIR__, "..", "..", "config", "spc.toml")))

if !isempty(ARGS)
    retraiter(ARGS[1], geometrie(reglages); dossier = joinpath(dossier_spc(reglages), "imagerie"),
              binning_temps = reglages.binning_temps, photons_min = reglages.photons_min)
else
    m = demarrer_moteur(reglages)
    try
        afficher_etat(verifier(m))
        duree = reglages.duree_s > 0 ? reglages.duree_s : 2.0
        println("\nAcquisition de $duree s sur les modules $(reglages.modules_imagerie)…")
        commander!(m, Imagerie(geometrie(reglages); duree = duree))
        trames = Dict{Int,Int}()
        fin = attendre_fin(m, :imagerie; f = r -> r isa ImageTrame && (trames[r.carte] = get(trames, r.carte, 0) + 1))
        println("\n", fin.erreur ? "ÉCHEC : " : "Terminée : ", fin.raison, " ; trames par carte : ", trames)
        foreach(f -> println("  ", f), fin.fichiers)
        for f in fin.fichiers
            endswith(f, ".spc") && println("Pour retraiter sans les cartes : julia -t auto scripts/spc/imagerie.jl ",
                                            replace(basename(f), ".spc" => ""))
        end
    finally
        arreter_moteur(m)      # cartes libérées, même après une erreur
    end
end
