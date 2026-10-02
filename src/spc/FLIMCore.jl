"""
    FLIMCore

Pilote des SPC-150N (plan « Intégration des SPC-150N dans le GUI »). Trois
couches, toutes sans affichage ni exécution au chargement :

- fonctions pures tirées des scripts imagerie_photons.jl et
  histogrammes_single.jl (branche NI-PCIe-6321) : réglages (config/spc.toml),
  flux .spc, rangement des photons en pixels, en bloc ou trame par trame,
  fichiers de sortie ;
- sources de photons derrière une même interface : les cartes (SPCLite),
  le rejeu de fichiers .spc, une simulation ;
- le moteur : une tâche (`Threads.@spawn`), seule à appeler la DLL SPC, qui
  reçoit des commandes et publie ses résultats par deux `Channel`.

Le GUI ne fait aucun ccall :

    m = demarrer_moteur(lire_reglages("config/spc.toml"))   # SPC_init, puis vérification
    etat = verifier(m)                                       # EtatCartes
    commander!(m, Imagerie(geometrie(reglages); duree = Inf))
    r = take!(m.resultats)   # ImageTrame, HistoSingle, Taux, Alerte, Fin, EtatCartes
    rendre!(m, r)            # une ImageTrame lue rend son tampon
    commander!(m, Single(1.0, 5))
    commander!(m, Arret())
    arreter_moteur(m)        # arrête, libère les cartes, termine la tâche

Le logiciel DCC autonome garde les détecteurs : FLIMCore n'appelle jamais
la DLL des DCC-100 (DCC_init échoue tant que le logiciel DCC tient les
modules, et couperait les sorties dès qu'il ne les tient plus). Il ne voit
les détecteurs qu'à travers le taux CFD.

FLIMCore n'utilise que la bibliothèque standard : il se charge avec FLIMApp
(`using FLIMApp.FLIMCore`) ou seul (`include("src/spc/FLIMCore.jl")`).
"""
module FLIMCore

using Dates, Printf, Serialization, TOML

include("SPCLite.jl")
using .SPCLite: Decodeur, decoder!, ecrire_ini, lire_ini, comparer_parametres, ecart_peigne,
                explication_init, MESSAGES_SYNC, SPC_ARMED, SPC_FOVFL, SPC_OVERFL, SPC_OVERFLOW,
                SPC_TIME_OVER, SPC_COLTIM_OVER, SPC_CMD_STOP

"""Version de FLIMCore : à augmenter à chaque changement, pour `garde_version`."""
const VERSION_CORE = 4

include("reglages.jl")
include("flux.jl")
include("rangement.jl")
include("passes.jl")
include("sorties.jl")
include("sources.jl")
include("moteur.jl")

export SPCLite
export Geometrie, Reglages, lire_reglages, ecrire_reglages, reglages_depuis_dict, geometrie, geometrie!,
       dossier_spc, parametres_imagerie, parametres_single, parametres_clamp, code_routage, code_ecrit, CODE_HORS_ROI, CODE_SANS_ROI, ROI_MAX, canal_serie
export ecrire_spc, lire_spc, flux_synthetique, EncodeurFifo, photon!, marqueur!
export Passes, passes!, terminer_passes!, flux_passes_synthetique
export ranger_photons, histogrammes_pixels, Rangeur, ranger!, terminer!, declin_total, temps_moyen, traiter, retraiter
export Source, SourceCartes, SourceRejeu, source_rejeu, source_simulation, source_session, source_depuis
export Moteur, demarrer_moteur, arreter_moteur, verifier, commander!, rendre!, recevoir, etat_moteur,
       attendre_fin, afficher_etat
export Resultat, ImageTrame, ImageSomme, HistoSingle, HistoClamp, Taux, Alerte, Fin, EtatCartes, EtatCarte
export Commande, Imagerie, Single, Clamp, Arret, Verifier, Deverrouiller
export garde_version

"""
    garde_version()

Refuse un FLIMCore chargé plus ancien que son fichier source (modifié
depuis le chargement, sans Revise) : il faut redémarrer Julia. Sans effet
si le fichier source n'est pas là (application compilée).
"""
function garde_version()
    fichier = joinpath(@__DIR__, "FLIMCore.jl")
    isfile(fichier) || return nothing
    v = match(r"const VERSION_CORE = (\d+)", read(fichier, String))
    v === nothing && return nothing
    parse(Int, v[1]) == VERSION_CORE ||
        error("FLIMCore chargé (version $VERSION_CORE) plus ancien que $fichier (version $(v[1])) : " *
              "redémarre Julia, ou charge Revise avant FLIMApp")
    return nothing
end

function __init__()
    atexit(arreter_tous)      # cartes libérées même si Julia se ferme en pleine mesure
end

end # module FLIMCore
