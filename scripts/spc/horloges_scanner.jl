# horloges_scanner.jl — ce que la carte voit des horloges du scanner, pour
# relier chaque réglage du scanner à un nombre de lignes : fréquence de
# ligne (M1), fréquence de trame (M2), lignes par trame.
#
# Pour chaque réglage du scanner (nombre de lignes, zoom, vitesse…), règle
# le scanner, fais-le tourner, puis :
#
#     julia -t 4 scripts/spc/horloges_scanner.jl "512 lignes"          # 5 s
#     julia -t 4 scripts/spc/horloges_scanner.jl "zoom 2, 256" 10      # 10 s
#
# Le premier argument nomme le réglage comme tu veux. Chaque mesure ajoute
# une ligne par carte à <[enregistrement] dossier>/horloges/horloges_scanner.csv
# et écrit le détail dans <date>_<réglage>.txt à côté : envoie ces fichiers.
# Pour relire un flux déjà enregistré (avec son _acquisition.ini) :
#
#     julia -t 4 scripts/spc/horloges_scanner.jl chemin/vers/module0.spc
#
# Mesure en imagerie, géométrie automatique (toute la ligne, toutes les
# lignes de chaque trame) : le flux brut de chaque carte est gardé, quelle
# que soit la géométrie. Réglages : config/spc.toml ([imagerie] modules,
# temps_pixel_ns, fronts des horloges) ; SPC_REGLAGES=<fichier> pour un autre
# (une copie avec [source] type = "simulation" pour l'essayer sans les cartes).
#
# Avant : SPCM fermé, le GUI fermé (il tient les cartes), scanner en marche
# sur le réglage à mesurer. Les photons ne sont pas nécessaires : les
# horloges arrivent sans laser.

isdefined(Main, :FLIMCore) || include(joinpath(@__DIR__, "..", "..", "src", "spc", "FLIMCore.jl"))
FLIMCore.garde_version()
using .FLIMCore
using Dates, Printf

reglages = lire_reglages(get(ENV, "SPC_REGLAGES", joinpath(@__DIR__, "..", "..", "config", "spc.toml")))

us(s) = isfinite(s) ? @sprintf("%.3f", 1e6s) : "?"
ms(s) = isfinite(s) ? @sprintf("%.4f", 1e3s) : "?"
hz(f) = isfinite(f) ? @sprintf("%.4f", f) : "?"

"""Le compte rendu d'une carte : lignes de texte, et la ligne du tableau CSV."""
function compte_rendu(h, etiquette, module_no, serie, fichier, r::Reglages)
    l, t, n = h.ligne, h.trame, h.lignes_par_trame
    lignes_image = n.mediane - r.decalage_lignes
    pixels_image = h.pixels_par_periode_ligne - r.decalage_pixels
    texte = String[
        "réglage du scanner : $etiquette",
        "carte : module $module_no, n° de série $(isempty(serie) ? "?" : serie)",
        "flux : $fichier",
        @sprintf("durée mesurée : %.2f s ; photons : %d ; enregistrements GAP : %d", h.duree_s, h.photons, h.pertes),
        "",
        "horloge de ligne (M1) : $(l.fronts) fronts",
        "  fréquence $(hz(l.frequence_hz)) Hz ; période $(us(l.periode_s)) µs (min $(us(l.periode_min_s)), max $(us(l.periode_max_s)))",
        "horloge de trame (M2) : $(t.fronts) fronts",
        "  fréquence $(hz(t.frequence_hz)) Hz ; période $(ms(t.periode_s)) ms (min $(ms(t.periode_min_s)), max $(ms(t.periode_max_s)))",
        "lignes par trame (fronts M1 entre deux M2) : min $(n.min), médiane $(n.mediane), max $(n.max)",
        "  répartition : " * (isempty(h.repartition) ? "aucune trame complète" :
                              join(["$k lignes × $v trame(s)" for (k, v) in h.repartition], ", ")),
        "",
        "avec les réglages actuels (config/spc.toml) :",
        "  pixels de $(reglages.temps_pixel_ns) ns par période de ligne : $(h.pixels_par_periode_ligne)" *
            " − decalage_pixels $(r.decalage_pixels) = $pixels_image (pixels_par_ligne = $(r.pixels_par_ligne))",
        "  lignes de l'image si lignes_par_image = 0 : $(n.mediane) − decalage_lignes $(r.decalage_lignes) = $lignes_image",
        "  fronts M0/M3 (signal de passe, normalement absent en imagerie) : $(h.fronts_m0) / $(h.fronts_m3)",
    ]
    l.fronts < 2 && push!(texte, "  ⚠ pas d'horloge de ligne sur M1 : scanner arrêté, câble, ou front (ligne_front_montant) ?")
    t.fronts < 2 && push!(texte, "  ⚠ pas d'horloge de trame sur M2 : scanner arrêté, câble, ou front (trame_front_montant) ?")
    n.min != n.max && push!(texte, "  ⚠ le nombre de lignes varie d'une trame à l'autre : voir la répartition")
    csv = join([Dates.format(now(), "yyyy-mm-dd HH:MM:SS"), "\"$(replace(etiquette, "\"" => "'"))\"", module_no, serie,
                @sprintf("%.3f", h.duree_s), h.photons, l.fronts, hz(l.frequence_hz), us(l.periode_s), us(l.periode_min_s),
                us(l.periode_max_s), t.fronts, hz(t.frequence_hz), ms(t.periode_s), ms(t.periode_min_s), ms(t.periode_max_s),
                n.min, n.mediane, n.max, h.pixels_par_periode_ligne, reglages.temps_pixel_ns, r.decalage_lignes, lignes_image,
                h.fronts_m0, h.fronts_m3, "\"$fichier\""], ",")
    return texte, csv
end

const ENTETE_CSV = "date,reglage_scanner,module,serie,duree_s,photons,fronts_M1,frequence_ligne_hz,periode_ligne_us," *
                   "periode_ligne_min_us,periode_ligne_max_us,fronts_M2,frequence_trame_hz,periode_trame_ms," *
                   "periode_trame_min_ms,periode_trame_max_ms,lignes_par_trame_min,lignes_par_trame_mediane," *
                   "lignes_par_trame_max,pixels_par_periode_ligne,temps_pixel_ns,decalage_lignes,lignes_image_auto," *
                   "fronts_M0,fronts_M3,flux"

"""Le tic et le n° de série d'un flux enregistré (son _acquisition.ini)."""
function infos_flux(fichier)
    ini = replace(fichier, r"\.spc$" => "_acquisition.ini")
    isfile(ini) || error("$ini introuvable : il donne le tic du flux")
    acquisition = FLIMCore.lire_ini_textes(ini; section = "acquisition")
    clamp_ = FLIMCore.lire_ini_textes(ini; section = "clamp")
    return parse(Float64, acquisition["tic_s"]), parse(Int, get(acquisition, "module", "-1")), get(clamp_, "serie", "")
end

function analyser(fichiers, etiquette, dossier)
    mkpath(dossier)
    csv = joinpath(dossier, "horloges_scanner.csv")
    nouveau = !isfile(csv)
    nom = replace(etiquette, r"[^\w\-]+" => "_")
    detail = joinpath(dossier, Dates.format(now(), "yyyymmdd_HHMMSS") * "_" * nom * ".txt")
    open(csv, "a") do io_csv
        nouveau && println(io_csv, ENTETE_CSV)
        open(detail, "w") do io
            for fichier in fichiers
                tic, module_no, serie = infos_flux(fichier)
                _, mots = lire_spc(fichier)
                h = mesurer_horloges(mots, tic; temps_pixel_ns = reglages.temps_pixel_ns)
                texte, ligne = compte_rendu(h, etiquette, module_no, serie, fichier, reglages)
                foreach(println, texte); println()
                foreach(l -> println(io, l), texte); println(io)
                println(io_csv, ligne)
            end
        end
    end
    println("→ ", csv)
    println("→ ", detail)
end

if !isempty(ARGS) && endswith(lowercase(ARGS[1]), ".spc")
    # Un flux déjà enregistré.
    analyser([abspath(ARGS[1])], length(ARGS) >= 2 ? ARGS[2] : basename(ARGS[1]), joinpath(dossier_spc(reglages), "horloges"))
else
    isempty(ARGS) && error("nomme le réglage du scanner : julia -t 4 scripts/spc/horloges_scanner.jl \"512 lignes\" [durée_s]")
    etiquette = ARGS[1]
    duree = length(ARGS) >= 2 ? parse(Float64, ARGS[2]) : 5.0
    # La copie en mémoire : le moteur ne relit pas le fichier, le flux brut est gardé.
    reglages.fichier = ""
    reglages.flux_brut = true
    g = Geometrie(temps_pixel_ns = reglages.temps_pixel_ns, pixels_par_ligne = 0, decalage_pixels = 0,
                  lignes_par_image = 0, decalage_lignes = 0,
                  ligne_front_montant = reglages.ligne_front_montant, trame_front_montant = reglages.trame_front_montant)
    m = demarrer_moteur(reglages)
    try
        afficher_etat(verifier(m))
        println("\n$(duree) s d'horloges du scanner, réglage « $etiquette », modules $(reglages.modules_imagerie)")
        commander!(m, Imagerie(g; duree = duree))
        fin = attendre_fin(m, :imagerie; delai_s = duree + 60)
        println(fin.erreur ? "ÉCHEC : " : "Terminée : ", fin.raison, "\n")
        fichiers = filter(f -> endswith(f, ".spc"), fin.fichiers)
        isempty(fichiers) && error("aucun flux enregistré : voir les alertes ci-dessus")
        analyser(fichiers, etiquette, joinpath(dossier_spc(reglages), "horloges"))
    finally
        arreter_moteur(m)
    end
end
