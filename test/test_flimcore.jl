# Tests de FLIMCore (src/spc), sans les cartes : les étapes 1 à 3 du plan
# d'intégration des SPC-150N. Inclus par runtests.jl (FLIMCore =
# FLIMApp.FLIMCore) ; se lance aussi seul, sans charger FLIMApp :
#
#     julia -t 4 test/test_flimcore.jl

using Serialization

if !isdefined(@__MODULE__, :FLIMCore)
    using Test
    include(joinpath(@__DIR__, "..", "src", "spc", "FLIMCore.jl"))
end

const TIC_TEST = 25e-9
const DT_TEST = 12.5 / 4096

"""Flux d'un petit scanner (lignes de 5 µs, 48 lignes par trame) : image de 100 × 48 pixels."""
flux_test(; trames = 8, graine = 1) = FLIMCore.flux_synthetique(trames = trames, lignes_par_trame = 48, periode_ligne = 200,
                                                                 photons_par_ligne = 40, gap_toutes = 97, graine = graine)

source_test(mots; modules = (0,), kw...) =
    FLIMCore.SourceRejeu(Dict(m => FLIMCore.FluxRejeu(copy(mots), 0x00000001, TIC_TEST, 12.5) for m in modules); kw...)

reglages_test(; kw...) = FLIMCore.Reglages(; dossier = mktempdir(), seuil_cfd = 10.0, kw...)

"""
La géométrie automatique (toute la ligne, toutes les lignes, sans marge) :
l'image 100 × 48 de `flux_test`, quels que soient les défauts de `Geometrie`
(ceux du banc : 1024 × 512, marges de 21 pixels et 32 lignes).
"""
geometrie_auto(; kw...) = FLIMCore.Geometrie(; pixels_par_ligne = 0, decalage_pixels = 0, lignes_par_image = 0,
                                             decalage_lignes = 0, reglages_scanner = NTuple{3,Int}[], kw...)

"""Lit les résultats jusqu'au `Fin` de `mesure` ; rend les trames au moteur."""
function jusqu_a_fin(m, mesure; delai = 60.0, garder = x -> nothing)
    t0 = time()
    while time() - t0 < delai
        x = FLIMCore.recevoir(m)
        if x === nothing
            sleep(0.002)
            continue
        end
        garder(x)
        FLIMCore.rendre!(m, x)
        x isa FLIMCore.Fin && x.mesure == mesure && return x
    end
    error("pas de Fin($mesure) en $delai s")
end

attendre_etat(m, e; delai = 30.0) = timedwait(() -> FLIMCore.etat_moteur(m) == e, delai; pollint = 0.002) === :ok

@testset "FLIMCore" begin

@testset "SPCLite sans la DLL" begin
    # FLIMApp se charge sans le TCSPC Package ; seule la première fonction
    # qui touche une carte échoue, avec un message lisible.
    if !FLIMCore.SPCLite.dll_disponible()
        err = try
            FLIMCore.SPCLite.initialiser("inutile.ini")
            nothing
        catch e
            e
        end
        @test err isa ErrorException && occursin("spcm64.dll introuvable", err.msg)
    end
    @test FLIMCore.SPCLite.VERSION_LITE == 8
end

@testset "réglages SPC (config/spc.toml)" begin
    r = FLIMCore.Reglages(lignes_par_image = 256, series = ["A", "B"], rejeu = [raw"C:\données\a.spc"])
    r.spc["cfd_limit_low"] = -80.0
    r.dcc["note"] = "gain \"haut\""
    chemin = joinpath(mktempdir(), "spc.toml")
    FLIMCore.ecrire_reglages(chemin, r)
    relu = FLIMCore.lire_reglages(chemin)
    @test all(f -> f == :fichier || getfield(relu, f) == getfield(r, f), fieldnames(FLIMCore.Reglages))
    @test relu.fichier == abspath(chemin) && relu.spc["sync_freq_div"] isa Int
    @test FLIMCore.geometrie(relu).lignes_par_image == 256
    # 1024 pixels par ligne comme dans SPCM ; le nombre de lignes est libre (0 : celui de l'horloge de trame).
    @test_throws ErrorException FLIMCore.reglages_depuis_dict(Dict("imagerie" => Dict("pixels_par_ligne" => 0)))
    @test FLIMCore.reglages_depuis_dict(Dict("imagerie" => Dict("lignes_par_image" => 576))).lignes_par_image == 576   # modulable
    @test FLIMCore.reglages_depuis_dict(Dict("imagerie" => Dict("lignes_par_image" => 0))).lignes_par_image == 0       # horloge de trame
    @test_throws ErrorException FLIMCore.reglages_depuis_dict(Dict("imagerie" => Dict("lignes_par_image" => -1)))

    # Une faute de frappe ou une valeur hors plage ne passe pas.
    @test_throws ErrorException FLIMCore.reglages_depuis_dict(Dict("imagerie" => Dict("pixel_par_ligne" => 3)))
    @test_throws ErrorException FLIMCore.reglages_depuis_dict(Dict("single" => Dict("resolution_adc" => 11)))
    @test_throws ErrorException FLIMCore.reglages_depuis_dict(Dict("single" => Dict("resolution_adc" => 12)))   # 256 canaux seulement
    @test_throws ErrorException FLIMCore.reglages_depuis_dict(Dict("banc" => Dict("x" => 1)))

    # Le fichier livré est celui qu'écrit ecrire_reglages avec les défauts.
    livre = joinpath(@__DIR__, "..", "config", "spc.toml")
    @test isfile(livre)
    d = FLIMCore.lire_reglages(livre)
    @test all(f -> f == :fichier || getfield(d, f) == getfield(FLIMCore.Reglages(), f), fieldnames(FLIMCore.Reglages))

    # Paramètres imposés par chaque mesure, par-dessus [spc_module].
    p, imposes = FLIMCore.parametres_imagerie(d, FLIMCore.Geometrie(ligne_front_montant = false))
    @test p["mode"] == 1 && p["routing_mode"] == 0x4600 && p["tac_range"] == d.spc["tac_range"] && haskey(imposes, "macro_time_clk")
    p, _ = FLIMCore.parametres_single(d, 2.5)
    @test p["mode"] == 0 && p["collect_time"] == 2.5 && p["stop_on_ovfl"] == 1
end

@testset "rangement : photons placés à la main" begin
    # Tic de 25 ns, pixels de 50 ns : colonne = (t - t_ligne) ÷ 2 tics.
    e = FLIMCore.EncodeurFifo()
    FLIMCore.marqueur!(e, 100, 0b0010)                 # ligne hors trame
    FLIMCore.photon!(e, 101, 4000)                     # ignoré : pas encore de trame
    for (f, t0) in enumerate((1_000, 20_000))          # deux trames de 4 lignes de 200 tics
        for l in 0:3
            tl = t0 + 200l
            FLIMCore.marqueur!(e, tl, l == 0 ? 0b0110 : 0b0010)
            f == 1 && l == 2 && FLIMCore.photon!(e, tl + 7, 4095 - 10)    # ligne 2, pixel 3
            f == 2 && l == 1 && FLIMCore.photon!(e, tl, 4095 - 20)        # ligne 1, pixel 0 (même tic)
        end
    end
    FLIMCore.marqueur!(e, 40_000, 0b0110)              # clôt la seconde trame
    FLIMCore.marqueur!(e, 40_200, 0b0010)
    g = geometrie_auto(pixels_par_ligne = 100, lignes_par_image = 4)
    res = FLIMCore.ranger_photons(e.mots, TIC_TEST, DT_TEST, g)
    @test res.photons == 3 && res.dans_image == 2 && res.trames == 2
    @test res.intensite[3, 4] == 1 && res.intensite[2, 1] == 1
    @test res.somme_t[3, 4] ≈ 10.5 * DT_TEST
    @test res.declin[11] == 1 && res.declin[21] == 1          # temps croissant : canal = 4095 - ADC

    # Le macrotemps déborde (12 bits) : un seul tour par MTOV, plusieurs par un enregistrement dédié.
    d = FLIMCore.SPCLite.decoder!(FLIMCore.SPCLite.Decodeur(garder_photons = true), e.mots)
    @test d.marqueurs[3] == [1_000, 20_000, 40_000] && d.t_photons == [101, 1_407, 20_200]
end

@testset "horloges du scanner : lignes par trame, fréquences" begin
    # flux_test : lignes de 200 tics (5 µs), 48 lignes par trame, 8 trames.
    h = FLIMCore.mesurer_horloges(flux_test(), TIC_TEST; temps_pixel_ns = 50.0)
    @test h.ligne.periode_s ≈ 200 * TIC_TEST && h.ligne.frequence_hz ≈ 1 / (200 * TIC_TEST) && h.ligne.periode_min_s ≈ h.ligne.periode_max_s
    @test h.trame.fronts == 8 && h.trame.periode_s ≈ 48 * 200 * TIC_TEST && h.trame.frequence_hz ≈ 1 / (48 * 200 * TIC_TEST)
    @test h.lignes_par_trame == (min = 48, mediane = 48, max = 48) && h.repartition == [48 => 7]
    @test h.pixels_par_periode_ligne == 100 && h.fronts_m0 == 0 && h.fronts_m3 == 0 && h.photons > 0
    # Les lignes par trame suivent l'horloge de trame : la géométrie automatique (lignes_par_image = 0) en tient compte.
    autre = FLIMCore.flux_synthetique(trames = 5, lignes_par_trame = 20, periode_ligne = 160, photons_par_ligne = 5)
    @test FLIMCore.mesurer_horloges(autre, TIC_TEST).lignes_par_trame.mediane == 20
    @test FLIMCore.ranger_photons(autre, TIC_TEST, DT_TEST, geometrie_auto(decalage_lignes = 2)).intensite |> size == (18, 80)
    vide = FLIMCore.mesurer_horloges(UInt16[], TIC_TEST)
    @test vide.ligne.fronts == 0 && isnan(vide.ligne.frequence_hz) && vide.lignes_par_trame.mediane == 0

    # Le profil des photons dans la trame complète : 48 lignes, 100 pixels, le disque au centre.
    par_ligne, par_colonne = FLIMCore.profil_trame(flux_test(), TIC_TEST)
    @test length(par_ligne) == 48 && length(par_colonne) == 100 && sum(par_ligne) > 0
    @test sum(par_colonne[40:60]) > 1.4 * sum(par_colonne[1:21])                 # le disque, plus lumineux
    @test FLIMCore.profil_trame(UInt16[], TIC_TEST) == (Int[], Int[])
end

@testset "réglages du scanner : lignes de l'image selon l'horloge de trame" begin
    # Les réglages mesurés au banc (lignes par trame → lignes de l'image, lignes ignorées en haut).
    g = FLIMCore.Geometrie()
    @test g.lignes_par_image == 0 && FLIMCore.reglage_scanner(g, 540) == (540, 512, 16) && FLIMCore.reglage_scanner(g, 541) === nothing
    @test [FLIMCore.reglage_scanner(g, n)[2] for n in (1080, 540, 270, 144, 72, 36, 20)] == [1024, 512, 256, 128, 60, 24, 8]
    # Le flux de test (48 lignes par trame) comme un réglage connu : 40 lignes, 4 ignorées en haut.
    mots = flux_test()
    connu = geometrie_auto(reglages_scanner = [(48, 40, 4)])
    lignes, trames = FLIMCore.marqueurs_flux(mots)
    geo = FLIMCore.geometrie_resolue(lignes, trames, TIC_TEST, connu)
    @test (geo.ny, geo.decalage_lignes, geo.reglage) == (40, 4, (48, 40, 4))
    complet = FLIMCore.ranger_photons(mots, TIC_TEST, DT_TEST, geometrie_auto())
    @test FLIMCore.ranger_photons(mots, TIC_TEST, DT_TEST, connu).intensite == complet.intensite[5:44, :]
    # Absent de la table : les lignes mesurées moins decalage_lignes ; une image fixée ignore la table.
    @test FLIMCore.geometrie_resolue(lignes, trames, TIC_TEST, geometrie_auto(decalage_lignes = 3, reglages_scanner = [(50, 40, 4)])).ny == 45
    @test FLIMCore.geometrie_resolue(lignes, trames, TIC_TEST, geometrie_auto(lignes_par_image = 10, reglages_scanner = [(48, 40, 4)])).ny == 10
    # Le rangement trame par trame suit la même table.
    etalonnage = FLIMCore.Etalonnage()
    FLIMCore.ajouter_etalonnage!(etalonnage, mots, length(mots))
    ge = FLIMCore.geometrie_etalonnee(etalonnage, TIC_TEST, connu)
    r = FLIMCore.Rangeur(ge, TIC_TEST, DT_TEST, connu)
    FLIMCore.ranger!((x, c) -> nothing, r, mots, length(mots))
    FLIMCore.terminer!((x, c) -> nothing, r)
    @test r.intensite_tot == FLIMCore.ranger_photons(mots, TIC_TEST, DT_TEST, connu).intensite

    # Dans config/spc.toml, relus tels quels ; une entrée incohérente est refusée.
    chemin = joinpath(mktempdir(), "spc.toml")
    FLIMCore.ecrire_reglages(chemin, FLIMCore.Reglages(reglages_scanner = [(48, 40, 4), (1080, 1024, 32)]))
    @test FLIMCore.lire_reglages(chemin).reglages_scanner == [(48, 40, 4), (1080, 1024, 32)]
    @test occursin("reglages_scanner = [[48, 40, 4], [1080, 1024, 32]]", read(chemin, String))
    @test FLIMCore.geometrie(FLIMCore.lire_reglages(chemin)).reglages_scanner == [(48, 40, 4), (1080, 1024, 32)]
    @test_throws ErrorException FLIMCore.reglages_depuis_dict(Dict("imagerie" => Dict("reglages_scanner" => [[48, 45, 4]])))
    @test_throws ErrorException FLIMCore.reglages_depuis_dict(Dict("imagerie" => Dict("reglages_scanner" => [[48, 40]])))
    @test_throws ErrorException FLIMCore.reglages_depuis_dict(Dict("imagerie" => Dict("reglages_scanner" => [[48, 40, 4], [48, 30, 2]])))
end

@testset "rangement trame par trame == traitement en bloc (étape 2)" begin
    mots = flux_test()
    alea = FLIMCore.Alea(3)
    for g in (geometrie_auto(),
              FLIMCore.Geometrie(pixels_par_ligne = 60, decalage_pixels = 7, lignes_par_image = 20, decalage_lignes = 3))
        bloc = FLIMCore.ranger_photons(mots, TIC_TEST, DT_TEST, g)
        # Lectures de tailles quelconques, impaires comprises (un enregistrement
        # coupé en deux), et des égalités de tic dans tous les ordres (flux_synthetique).
        etalonnage = FLIMCore.Etalonnage()
        position, geo = 1, nothing
        while geo === nothing
            n = min(1 + Int(FLIMCore._suivant!(alea) % 300), length(mots) - position + 1)
            FLIMCore.ajouter_etalonnage!(etalonnage, view(mots, position:position + n - 1), n)
            position += n
            geo = FLIMCore.geometrie_etalonnee(etalonnage, TIC_TEST, g)
        end
        @test (geo.nx, geo.ny) == (bloc.nx, bloc.ny)
        r = FLIMCore.Rangeur(geo, TIC_TEST, DT_TEST, g)
        somme = zeros(UInt32, geo.ny, geo.nx)
        numeros, completes = Int[], Bool[]
        garder = (rg, complete) -> (somme .+= rg.intensite; push!(numeros, rg.numero); push!(completes, complete))
        FLIMCore.ranger!(garder, r, etalonnage.mots, length(etalonnage.mots))
        while position <= length(mots)
            n = min(1 + Int(FLIMCore._suivant!(alea) % 5000), length(mots) - position + 1)
            FLIMCore.ranger!(garder, r, mots[position:position + n - 1], n)
            position += n
        end
        FLIMCore.terminer!(garder, r)

        @test numeros == 1:8 && completes == [trues(7); false]
        @test r.intensite_tot == bloc.intensite && somme == bloc.intensite
        @test r.somme_t_tot == bloc.somme_t                       # même ordre de sommation : identique au bit près
        @test FLIMCore.declin_total(r) == bloc.declin
        @test (r.decodeur.photons, r.dans_image, r.decodeur.pertes, r.trames_completes) ==
              (bloc.photons, bloc.dans_image, bloc.pertes, bloc.trames)
        @test bloc.pertes > 0 && bloc.dans_image > 0
    end
end

@testset "fichiers d'une acquisition et retraitement (étape 1)" begin
    dossier = mktempdir()
    prefixe = joinpath(dossier, "20260930_120000_module1")
    mots = flux_test()
    FLIMCore.ecrire_spc(prefixe * ".spc", 0x12345678, mots)
    FLIMCore.ecrire_acquisition_ini(prefixe * "_acquisition.ini", 1, TIC_TEST, 12.5, 2.0, false;
                                    geometrie = geometrie_auto(), dcc = FLIMCore.DCC_DEFAUT)
    @test FLIMCore.lire_spc(prefixe * ".spc") == (0x12345678, mots)
    res = FLIMCore.retraiter(basename(prefixe), geometrie_auto(); dossier = dossier, io = devnull)
    @test res == FLIMCore.ranger_photons(mots, TIC_TEST, DT_TEST, geometrie_auto())
    for suffixe in ("_intensite.bmp", "_temps_moyen.bmp", "_declin.svg", ".jls")
        @test isfile(prefixe * suffixe)
    end
    @test read(prefixe * "_intensite.bmp", 2) == UInt8['B', 'M']

    Sn, tm = FLIMCore.temps_moyen(res.intensite, res.somme_t, 4, 20)
    @test size(tm) == (12, 25) && any(isfinite, tm) && all(t -> isnan(t) || 0 < t < 12.5, tm)
end

@testset "moteur : imagerie en rejeu (étapes 2 et 3)" begin
    mots = flux_test()
    source = source_test(mots; modules = (0, 1), vitesse = 0, boucle = false)
    r = reglages_test()
    m = FLIMCore.demarrer_moteur(r; source = source, tampons = 64)
    etat = FLIMCore.verifier(m)
    @test etat.ok && [c.carte for c in etat.cartes] == [0, 1] && all(c -> c.cfd > 0, etat.cartes)
    @test all(c -> all(l -> l.statut == :ok, c.tableau), etat.cartes)
    @test occursin("tac_range", sprint(io -> FLIMCore.afficher_etat(etat; io = io)))

    FLIMCore.commander!(m, FLIMCore.Imagerie(FLIMCore.geometrie(r); duree = 60))
    sommes = Dict{Int,Matrix{UInt32}}()
    trames = Dict(0 => 0, 1 => 0)
    fin = jusqu_a_fin(m, :imagerie; garder = x -> if x isa FLIMCore.ImageTrame
        trames[x.carte] += 1
        sommes[x.carte] = haskey(sommes, x.carte) ? sommes[x.carte] .+ x.intensite : copy(x.intensite)
    end)
    @test !fin.erreur && fin.raison == "fin du rejeu" && m.trames_sautees[] == 0 && m.perdus[] == 0

    bloc = FLIMCore.ranger_photons(mots, TIC_TEST, DT_TEST, FLIMCore.geometrie(r))
    @test trames == Dict(0 => 8, 1 => 8)
    @test sommes[0] == bloc.intensite && sommes[1] == bloc.intensite
    jls = Serialization.deserialize(only(filter(f -> endswith(f, "module0.jls"), fin.fichiers)))
    @test jls.intensite == bloc.intensite && jls.somme_t == bloc.somme_t && jls.declin == bloc.declin && jls.trames == 7
    @test FLIMCore.lire_spc(only(filter(f -> endswith(f, "module1.spc"), fin.fichiers)))[2] == mots
    ini = only(filter(f -> endswith(f, "module0_acquisition.ini"), fin.fichiers))
    @test FLIMCore.lire_ini(ini; section = "acquisition")["tic_s"] == TIC_TEST
    @test occursin("gain_c1_pourcent", read(ini, String))          # réglages DCC déclarés gardés

    @test FLIMCore.arreter_moteur(m)
    @test FLIMCore.etat_moteur(m) == :arrete && source.ouvertures == 1 && source.fermetures == 1
end

@testset "moteur : Single en rejeu" begin
    source = source_test(flux_test(); modules = (0, 1), vitesse = 0)
    r = reglages_test()                                  # 8 bits : 256 canaux, comme le Realtime et l'IRF
    m = FLIMCore.demarrer_moteur(r; source = source)
    @test attendre_etat(m, :pret)
    histos = FLIMCore.HistoSingle[]
    FLIMCore.commander!(m, FLIMCore.Single(0.0005, 3))
    fin = FLIMCore.attendre_fin(m, :single; delai_s = 60, io = nothing, f = x -> x isa FLIMCore.HistoSingle && push!(histos, x))
    @test !fin.erreur && length(histos) == 6
    @test all(h -> length(h.histogramme) == 256 && sum(Int, h.histogramme) > 0 && h.fin == "temps écoulé", histos)
    @test all(h -> h.dt_ns ≈ 12.5 / 256, histos)
    csv = only(filter(f -> endswith(f, "module1.csv"), fin.fichiers))
    lignes = filter(l -> !startswith(l, "#"), readlines(csv))
    @test lignes[1] == "canal,temps_ns,h1,h2,h3,somme" && length(lignes) == 257
    @test sum(parse(Int, last(split(l, ","))) for l in lignes[2:end]) ==
          sum(sum(Int, h.histogramme) for h in histos if h.carte == 1)
    @test FLIMCore.arreter_moteur(m)
end

@testset "moteur : 100 démarrages et arrêts, erreur simulée (étape 3)" begin
    source = source_test(flux_test(); modules = (0, 1), vitesse = 0)
    r = reglages_test()
    arrets = 0
    for _ in 1:100
        m = FLIMCore.demarrer_moteur(r; source = source)
        attendre_etat(m, :pret) && FLIMCore.arreter_moteur(m) && (arrets += 1)
    end
    @test arrets == 100
    @test source.ouvertures == 100 && source.fermetures == 100

    # Une lecture du FIFO qui échoue en pleine imagerie : mesure arrêtée,
    # alerte, moteur toujours prêt ; cartes libérées à l'arrêt.
    source.lectures, source.panne_apres, source.vitesse = 0, 3, 1.0
    m = FLIMCore.demarrer_moteur(r; source = source)
    FLIMCore.commander!(m, FLIMCore.Imagerie(FLIMCore.Geometrie(); duree = 60))
    alertes = String[]
    fin = jusqu_a_fin(m, :imagerie; garder = x -> x isa FLIMCore.Alerte && push!(alertes, x.texte))
    @test fin.erreur && occursin("panne simulée", fin.raison)
    @test any(a -> occursin("imagerie interrompue", a), alertes)
    @test attendre_etat(m, :pret) && all(f -> !f.en_cours, values(source.flux))
    @test FLIMCore.arreter_moteur(m) && source.fermetures == source.ouvertures == 101

    # Une source qui ne s'ouvre pas : le moteur s'arrête, avec l'alerte.
    m = FLIMCore.demarrer_moteur(reglages_test(source = "rejeu", rejeu = ["introuvable.spc"]))
    alertes = String[]
    fin = jusqu_a_fin(m, :moteur; garder = x -> x isa FLIMCore.Alerte && push!(alertes, x.texte))
    @test fin.erreur && any(a -> occursin("introuvable", a), alertes)
    @test FLIMCore.arreter_moteur(m) && FLIMCore.etat_moteur(m) == :arrete
end

@testset "moteur : taux, CFD et commandes refusées" begin
    source = source_test(flux_test(); vitesse = 1.0)
    source.cfd_impose = 0.0
    m = FLIMCore.demarrer_moteur(reglages_test(modules_imagerie = [0], modules_single = [0]); source = source)
    etat = FLIMCore.verifier(m)
    @test !etat.ok && any(p -> occursin("Enable outputs", p), etat.problemes)

    alertes = FLIMCore.Alerte[]
    taux = FLIMCore.Taux[]
    garder(x) = (x isa FLIMCore.Alerte && push!(alertes, x); x isa FLIMCore.Taux && push!(taux, x))
    attendre_alerte(motif) = timedwait(() -> begin
            while (x = FLIMCore.recevoir(m)) !== nothing
                garder(x)
            end
            any(a -> occursin(motif, a.texte), alertes)
        end, 10.0; pollint = 0.01) === :ok
    source.cfd_impose = NaN                                    # détecteurs rallumés
    @test attendre_alerte("CFD rétabli")
    source.cfd_impose = 0.0                                    # coupure par surcharge dans le logiciel DCC
    @test attendre_alerte("chute du CFD")
    @test only(filter(a -> occursin("chute du CFD", a.texte), alertes)).gravite == :erreur
    @test !isempty(taux) && all(t -> t.valide && t.sync == 8.0e7 && !t.en_mesure, taux)

    # Pendant une mesure, une autre commande est refusée, pas mise en attente.
    FLIMCore.commander!(m, FLIMCore.Imagerie(FLIMCore.Geometrie(); duree = 5))
    @test attendre_etat(m, :imagerie)
    FLIMCore.commander!(m, FLIMCore.Single(1.0, 1))
    @test attendre_alerte("commande Single ignorée")
    FLIMCore.commander!(m, FLIMCore.Arret())
    fin = jusqu_a_fin(m, :imagerie)
    @test !fin.erreur && fin.raison == "arrêtée"
    @test FLIMCore.arreter_moteur(m)
end

@testset "moteur : image de N trames et déclins par ROI (popup ROI)" begin
    mots = flux_test()
    source = source_test(mots; modules = (0, 1), vitesse = 0, boucle = false)
    m = FLIMCore.demarrer_moteur(reglages_test(); source = source, tampons = 64)
    @test attendre_etat(m, :pret)
    images = FLIMCore.ImageSomme[]
    FLIMCore.commander!(m, FLIMCore.Imagerie(geometrie_auto(); trames = 3, garder_mots = true))
    fin = jusqu_a_fin(m, :imagerie; garder = x -> x isa FLIMCore.ImageSomme && push!(images, x))
    @test !fin.erreur && [i.carte for i in images] == [0, 1]
    img = images[1]
    @test img.trames >= 3 && (img.geometrie.pixels_par_ligne, img.geometrie.lignes_par_image) == (100, 48)
    @test img.mots == mots[1:length(img.mots)] && !isempty(img.mots)
    # Le flux gardé redonne l'image, et un déclin par groupe de pixels.
    @test FLIMCore.ranger_photons(img.mots, TIC_TEST, DT_TEST, img.geometrie).intensite == img.intensite
    etiquettes = zeros(Int, 48, 100)
    etiquettes[10:20, 30:60] .= 1
    etiquettes[30:40, 70:90] .= 2
    H = FLIMCore.histogrammes_pixels(img.mots, TIC_TEST, img.geometrie, etiquettes, 2)
    @test size(H) == (256, 2)
    @test sum(H[:, 1]) == sum(img.intensite[10:20, 30:60]) && sum(H[:, 2]) == sum(img.intensite[30:40, 70:90])
    @test FLIMCore.arreter_moteur(m)
end

@testset "passes du Realtime : marqueurs M0/M3 et routage" begin
    # Le code que lit la carte et ce que la NI écrit (entrées actives à 0 V).
    @test FLIMCore.code_routage(1) == 1 && FLIMCore.code_routage(15) == 15
    @test_throws ErrorException FLIMCore.code_routage(16)
    @test FLIMCore.code_ecrit(3, true) == 0x0c && FLIMCore.code_ecrit(3, false) == 0x03
    @test FLIMCore.code_ecrit(FLIMCore.CODE_HORS_ROI, true) == 0x0f       # la carte lit 0 : code réservé
    @test FLIMCore.CODE_SANS_ROI == 1 != FLIMCore.CODE_HORS_ROI
    p, _ = FLIMCore.parametres_clamp(FLIMCore.Reglages())
    @test p["mode"] == 1 && p["routing_mode"] == 0x1100                  # M0 seul, front montant (fin_par_m3 = false)
    @test FLIMCore.parametres_clamp(FLIMCore.Reglages(fin_par_m3 = true))[1]["routing_mode"] == 0x1900   # M0 et M3, M3 descendant
    @test FLIMCore.parametres_clamp(FLIMCore.Reglages(); tous_marqueurs = true)[1]["routing_mode"] == 0x7F00   # test : M0–M3

    # Photons pile sur M0 : dans la passe ; pile sur M3 : dehors ; entre deux passes : hors passe.
    e = FLIMCore.EncodeurFifo()
    FLIMCore.photon!(e, 50, 4000; routage = 2)              # avant toute passe
    FLIMCore.photon!(e, 100, 4000; routage = 2)             # même tic que M0, écrit avant lui
    FLIMCore.marqueur!(e, 100, 0b0001)
    FLIMCore.photon!(e, 150, 4095 - 16; routage = 2)
    FLIMCore.photon!(e, 160, 4000; routage = FLIMCore.CODE_HORS_ROI)   # code réservé : jeté, même dans la passe
    FLIMCore.photon!(e, 200, 4000; routage = 2)             # même tic que M3
    FLIMCore.marqueur!(e, 200, 0b1000)
    vus = []
    q = FLIMCore.Passes(canaux = 256)
    FLIMCore.passes!((pp, t0, t1, pertes) -> push!(vus, (t0, t1, copy(pp.histo))), q, e.mots)
    FLIMCore.terminer_passes!((pp, t0, t1, pertes) -> push!(vus, (t0, t1, copy(pp.histo))), q)
    @test length(vus) == 1 && vus[1][1:2] == (100, 200)
    # ADC 4000 : microtemps 95, canal 6 sur 256 ; ADC 4079 : microtemps 16, canal 2 ; code 2 : colonne 3.
    @test sum(vus[1][3]) == 2 && vus[1][3][6, 3] == 1 && vus[1][3][2, 3] == 1
    @test q.hors_passe == 2                                  # t = 50 (avant M0) et t = 200 (pile sur M3)
    @test q.hors_roi == 1 && q.dernier == 200
end

@testset "passes du Realtime : flux synthétique, lectures quelconques" begin
    codes = [3, 1, 2]
    # Des photons pendant les pauses aussi, avec le code réservé que la NI y écrit.
    mots = FLIMCore.flux_passes_synthetique(codes = codes, passes = 7, scan_s = 0.004, pause_s = 0.001, photons_par_s = 2e6,
                                            photons_pause_par_s = 2e6)
    total = FLIMCore.SPCLite.decoder!(FLIMCore.SPCLite.Decodeur(), mots).photons
    alea = FLIMCore.Alea(5)
    q = FLIMCore.Passes()
    vus = []
    garder(pp, t0, t1, pertes) = push!(vus, (t0, t1, copy(pp.histo), pertes))
    position = 1
    while position <= length(mots)
        n = min(1 + Int(FLIMCore._suivant!(alea) % 3000), length(mots) - position + 1)
        FLIMCore.passes!(garder, q, mots[position:position + n - 1], n)
        position += n
    end
    FLIMCore.terminer_passes!(garder, q)
    @test length(vus) == 7 && q.passes_abandonnees == 0 && q.hors_passe == 0 && q.hors_roi > 1000
    @test sum(sum(v[3]) for v in vus) + q.hors_roi == total    # chaque photon dans sa passe, ou jeté
    for (n, v) in enumerate(vus)
        code = codes[mod1(n, 3)]
        @test sum(v[3][:, code + 1]) == sum(v[3]) > 0          # tout dans la colonne de son code
        @test v[2] - v[1] == round(Int, 0.004 / 25e-9)
    end
end

@testset "moteur : Realtime en FIFO, une passe par scan, session enregistrée" begin
    codes = [2, 1]
    mots0 = FLIMCore.flux_passes_synthetique(codes = codes, passes = 6, scan_s = 0.02, pause_s = 0.005, graine = 1)
    mots1 = FLIMCore.flux_passes_synthetique(codes = codes, passes = 6, scan_s = 0.02, pause_s = 0.005, graine = 2)
    # Module 0 porte la carte du canal 2 : les canaux suivent les n° de série.
    flux = Dict(0 => FLIMCore.FluxRejeu(mots0, 0x1, TIC_TEST, 12.5; serie = "3N0318"),
                1 => FLIMCore.FluxRejeu(mots1, 0x1, TIC_TEST, 12.5; serie = "3N0317"))
    source = FLIMCore.SourceRejeu(flux; vitesse = 0, boucle = false)
    m = FLIMCore.demarrer_moteur(reglages_test(); source = source)
    etat = FLIMCore.verifier(m)
    @test sort([(c.carte, c.canal) for c in etat.cartes]) == [(0, 2), (1, 1)]
    session = mktempdir()
    histos = FLIMCore.HistoClamp[]
    FLIMCore.commander!(m, FLIMCore.Clamp(rois = [1, 2], ordre = [2, 1], dossier = joinpath(session, "spc"), fin_par_m3 = true))
    fin = jusqu_a_fin(m, :clamp; garder = x -> nothing)
    while isready(m.histogrammes)
        push!(histos, take!(m.histogrammes))
    end
    @test !fin.erreur && fin.raison == "fin du rejeu après 6 passe(s)"
    @test [h.passe for h in histos] == 1:6 && all(h -> h.cartes == [1, 0] && h.series == ["3N0317", "3N0318"], histos)
    @test all(h -> size(h.histogrammes[1]) == (256, 16) && h.pertes == 0 && h.t_fin_s - h.t_debut_s ≈ 0.02, histos)
    @test all(h -> isempty(h.motifs), histos)
    for (n, h) in enumerate(histos)
        code = codes[mod1(n, 2)]
        @test sum(h.histogrammes[1][:, code + 1]) == sum(h.histogrammes[1]) > 0
    end
    # La session : le flux de chaque carte tel quel, et de quoi le rejouer.
    @test FLIMCore.lire_spc(joinpath(session, "spc", "3N0317.spc"))[2] == mots1
    @test isfile(joinpath(session, "spc", "3N0318_acquisition.ini")) && isfile(joinpath(session, "spc", "3N0317_parametres.ini"))
    @test FLIMCore.lire_ini_textes(joinpath(session, "spc", "3N0318_acquisition.ini"); section = "clamp")["serie"] == "3N0318"

    # Rejeu de la session (Playback) : mêmes passes, mêmes déclins.
    rejeu = FLIMCore.source_session(session; vitesse = 0)
    m2 = FLIMCore.demarrer_moteur(reglages_test(); source = rejeu)
    @test attendre_etat(m2, :pret)
    FLIMCore.commander!(m2, FLIMCore.Clamp(rois = [1, 2], fin_par_m3 = true))
    jusqu_a_fin(m2, :clamp)
    rejoues = FLIMCore.HistoClamp[]
    while isready(m2.histogrammes)
        push!(rejoues, take!(m2.histogrammes))
    end
    @test [h.histogrammes for h in rejoues] == [h.histogrammes for h in histos] && rejoues[1].series == ["3N0317", "3N0318"]

    # Plus de 15 ROI : refusé, rien ne démarre.
    FLIMCore.commander!(m, FLIMCore.Clamp(rois = collect(1:16)))
    fin = jusqu_a_fin(m, :clamp)
    @test fin.erreur && occursin("15", fin.raison)
    @test FLIMCore.arreter_moteur(m) && FLIMCore.arreter_moteur(m2)
end

"""Les passes d'un Realtime rejoué de `flux` (vitesse 0) avec la commande `c`, et la source."""
function passes_rejouees(flux, c; fovfl_a_lecture = 0)
    source = FLIMCore.SourceRejeu(flux; vitesse = 0, boucle = false)
    source.fovfl_a_lecture = fovfl_a_lecture
    m = FLIMCore.demarrer_moteur(reglages_test(); source = source)
    @test attendre_etat(m, :pret)
    FLIMCore.commander!(m, c)
    alertes = String[]
    fin = jusqu_a_fin(m, :clamp; garder = r -> r isa FLIMCore.Alerte && push!(alertes, r.texte))
    histos = FLIMCore.HistoClamp[]
    while isready(m.histogrammes)
        push!(histos, take!(m.histogrammes))
    end
    FLIMCore.arreter_moteur(m)
    return histos, fin, alertes
end

"""Le flux sans le `n`-ième marqueur M3 : remplacé par un photon du code réservé (même temps, même MTOV)."""
sans_m3(mots, n) = sans_marqueur(mots, 0b1000, n)

"""Le flux sans le `n`-ième marqueur `bits` (tous : `n = 0`), remplacés par des photons du code réservé (même temps, même MTOV)."""
function sans_marqueur(mots, bits, n)
    mots = copy(mots)
    vus = 0
    for i in 1:2:length(mots) - 1
        w = UInt32(mots[i]) | (UInt32(mots[i + 1]) << 16)
        if (w & FLIMCore.BIT_MARK) != 0 && ((w >> 12) & 0xf) == bits
            vus += 1
            if n == 0 || vus == n
                w = (w & (FLIMCore.BIT_MTOV | 0x00000fff)) | (UInt32(2000) << 16)
                mots[i], mots[i + 1] = UInt16(w & 0xffff), UInt16(w >> 16)
                n == 0 || return mots
            end
        end
    end
    n == 0 && return mots
    error("pas de $n-ième marqueur $bits")
end

"""Le flux avec un M0 en trop : le photon `decalage` enregistrements après le `n`-ième M0 devient un M0 (même temps, même MTOV)."""
function m0_en_trop(mots, n, decalage)
    mots = copy(mots)
    vus = 0
    for i in 1:2:length(mots) - 1
        w = UInt32(mots[i]) | (UInt32(mots[i + 1]) << 16)
        if (w & FLIMCore.BIT_MARK) != 0 && ((w >> 12) & 0xf) == 0b0001
            vus += 1
            if vus == n
                j = i + 2decalage
                v = UInt32(mots[j]) | (UInt32(mots[j + 1]) << 16)
                v = FLIMCore.BIT_MARK | FLIMCore.BIT_INVALID | (v & (FLIMCore.BIT_MTOV | 0x00000fff)) | (UInt32(0b0001) << 12)
                mots[j], mots[j + 1] = UInt16(v & 0xffff), UInt16(v >> 16)
                return mots
            end
        end
    end
    error("pas de $n-ième M0")
end

@testset "moteur : passes exclues du PI, passes appariées entre cartes" begin
    flux_test(; perdre = 0) = Dict(
        0 => FLIMCore.FluxRejeu(FLIMCore.flux_passes_synthetique(codes = [1, 2], passes = 6, scan_s = 0.02, pause_s = 0.005, graine = 1),
                                0x1, TIC_TEST, 12.5; serie = "3N0317"),
        1 => FLIMCore.FluxRejeu((perdre > 0 ? (m -> sans_m3(m, perdre)) : identity)(
                                    FLIMCore.flux_passes_synthetique(codes = [1, 2], passes = 6, scan_s = 0.02, pause_s = 0.005, graine = 2)),
                                0x1, TIC_TEST, 12.5; serie = "3N0318"))

    # Durée programmée respectée (un échantillon de 0,1 ms et 100 ppm) : rien d'exclu.
    histos, fin, _ = passes_rejouees(flux_test(), FLIMCore.Clamp(rois = [1, 2], scan_s = 0.02, echantillon_s = 1e-4, fin_par_m3 = true))
    @test length(histos) == 6 && all(h -> isempty(h.motifs), histos)
    @test FLIMCore.tolerance_passe(FLIMCore.Clamp(scan_s = 0.02, echantillon_s = 1e-4)) ≈ 1e-4 + 2e-6

    # M3 − M0 à 20 ms pour 20,2 ms programmées : hors tolérance, sur les deux cartes.
    histos, _, alertes = passes_rejouees(flux_test(), FLIMCore.Clamp(rois = [1, 2], scan_s = 0.0202, echantillon_s = 1e-4, fin_par_m3 = true))
    @test length(histos) == 6 && all(h -> count(t -> occursin("M3 − M0", t), h.motifs) == 2, histos)
    @test any(t -> occursin("durée M3 − M0 hors tolérance", t), alertes)

    # SPC_FOVFL dès la première lecture : les passes lues alors sont exclues.
    histos, _, alertes = passes_rejouees(flux_test(), FLIMCore.Clamp(rois = [1, 2], fin_par_m3 = true); fovfl_a_lecture = 1)
    @test length(histos) == 6 && all(h -> any(t -> occursin("SPC_FOVFL", t), h.motifs), histos)
    @test any(t -> occursin("FIFO débordé", t), alertes)

    # Un M3 perdu sur la carte du canal 2 : sa passe 3 est abandonnée, et la
    # passe 3 du canal 1, sans correspondante, écartée ; les autres restent
    # appariées par leur temps.
    histos, _, alertes = passes_rejouees(flux_test(perdre = 3), FLIMCore.Clamp(rois = [1, 2], fin_par_m3 = true))
    @test length(histos) == 5 && [h.passe for h in histos] == [1, 2, 4, 5, 6]
    @test all(h -> isempty(h.motifs), histos)
    codes(h) = [argmax(vec(sum(m; dims = 1))) - 1 for m in h.histogrammes]
    @test all(h -> codes(h) == fill([1, 2][mod1(h.passe, 2)], 2), histos)     # chaque passe avec la sienne
    @test any(t -> occursin("sans correspondante", t), alertes) && any(t -> occursin("sans marqueur de fin", t), alertes)
end

@testset "M0 seul : chaque passe dure le scan, intervalles M0 → M0" begin
    # Le découpage : mêmes passes qu'avec M3, quand M0 seul et la durée du scan les délimitent.
    codes = [3, 1, 2]
    mots = FLIMCore.flux_passes_synthetique(codes = codes, passes = 7, scan_s = 0.004, pause_s = 0.001, photons_par_s = 2e6)
    avec_m3, avec_m0 = [], []
    q3 = FLIMCore.Passes()
    FLIMCore.passes!((p, t0, t1, pertes) -> push!(avec_m3, (t0, t1, copy(p.histo))), q3, mots)
    FLIMCore.terminer_passes!((p, t0, t1, pertes) -> push!(avec_m3, (t0, t1, copy(p.histo))), q3)
    q0 = FLIMCore.Passes(duree = round(Int64, 0.004 / TIC_TEST))
    FLIMCore.passes!((p, t0, t1, pertes) -> push!(avec_m0, (t0, t1, copy(p.histo))), q0, sans_marqueur(mots, 0b1000, 0))
    FLIMCore.terminer_passes!((p, t0, t1, pertes) -> push!(avec_m0, (t0, t1, copy(p.histo))), q0)
    @test length(avec_m0) == 7 && avec_m0 == avec_m3
    @test q0.intervalle_min == q0.intervalle_max == round(Int64, 0.005 / TIC_TEST)

    # Le moteur, cartes sans M3 (fin_par_m3 = false, le défaut).
    flux(f1 = identity) = Dict(
        0 => FLIMCore.FluxRejeu(sans_marqueur(FLIMCore.flux_passes_synthetique(codes = [1, 2], passes = 6, scan_s = 0.02, pause_s = 0.005, graine = 1),
                                              0b1000, 0), 0x1, TIC_TEST, 12.5; serie = "3N0317"),
        1 => FLIMCore.FluxRejeu(f1(sans_marqueur(FLIMCore.flux_passes_synthetique(codes = [1, 2], passes = 6, scan_s = 0.02, pause_s = 0.005, graine = 2),
                                                 0b1000, 0)), 0x1, TIC_TEST, 12.5; serie = "3N0318"))
    c = FLIMCore.Clamp(rois = [1, 2], scan_s = 0.02, pause_s = 0.005, echantillon_s = 1e-4)
    histos, fin, _ = passes_rejouees(flux(), c)
    @test !fin.erreur && length(histos) == 6 && all(h -> isempty(h.motifs) && h.t_fin_s - h.t_debut_s ≈ 0.02, histos)
    @test [argmax(vec(sum(h.histogrammes[1]; dims = 1))) - 1 for h in histos] == [1, 2, 1, 2, 1, 2]
    histos_m3, _, _ = passes_rejouees(Dict(k => FLIMCore.FluxRejeu(FLIMCore.flux_passes_synthetique(codes = [1, 2], passes = 6, scan_s = 0.02,
                                                                                                   pause_s = 0.005, graine = k + 1),
                                                                    0x1, TIC_TEST, 12.5; serie = s) for (k, s) in ((0, "3N0317"), (1, "3N0318"))),
                                      FLIMCore.Clamp(rois = [1, 2], scan_s = 0.02, pause_s = 0.005, echantillon_s = 1e-4, fin_par_m3 = true))
    @test [h.histogrammes for h in histos] == [h.histogrammes for h in histos_m3]
    # Sans la durée du scan, M0 seul est refusé.
    _, refus, _ = passes_rejouees(flux(), FLIMCore.Clamp(rois = [1, 2], scan_s = NaN))
    @test refus.erreur && occursin("durée du scan", refus.raison)

    # Un M0 perdu sur la carte du canal 2 : une passe de moins, comptée ; rien d'exclu.
    histos, _, alertes = passes_rejouees(flux(m -> sans_marqueur(m, 0b0001, 3)), c)
    @test length(histos) == 5 && all(h -> isempty(h.motifs), histos)
    @test any(t -> occursin("1 M0 manquant", t), alertes)
    # Un M0 en trop au milieu de la passe 3 : hors cadence, ignoré ; la passe 3 continue.
    histos, _, alertes = passes_rejouees(flux(m -> m0_en_trop(m, 3, 50)), c)
    @test length(histos) == 6 && all(h -> isempty(h.motifs), histos)
    photons(hs) = sum(h -> sum(sum, h.histogrammes), hs)
    @test photons(histos) == photons(passes_rejouees(flux(), c)[1]) - 1       # le photon devenu parasite
    @test any(t -> occursin("1 M0 hors cadence", t), alertes) && !any(t -> occursin("interrompue", t), alertes)

    # Le décodeur : le M0 de la passe 1 perdu et un parasite dans son scan, qui
    # donne une fausse cadence ; le M0 de la passe 2 est alors ignoré, celui de
    # la passe 3, à un créneau du précédent, rétablit la cadence. Puis le M0 de
    # la passe 5 perdu.
    periode = round(Int64, 0.005 / TIC_TEST)
    q = FLIMCore.Passes(duree = round(Int64, 0.004 / TIC_TEST), periode = periode, tolerance = 10)
    m = sans_marqueur(m0_en_trop(sans_marqueur(mots, 0b1000, 0), 1, 50), 0b0001, 1)
    vus = Int64[]
    FLIMCore.passes!((p, t0, t1, pertes) -> push!(vus, t0), q, sans_marqueur(m, 0b0001, 5))
    FLIMCore.terminer_passes!((p, t0, t1, pertes) -> push!(vus, t0), q)
    debuts = first.(avec_m3)
    @test debuts[1] < vus[1] < debuts[1] + periode ÷ 10 && vus[2:end] == debuts[[3, 4, 6, 7]]
    @test q.m0_hors_cadence == 1 && q.m0_manquants == 1 && q.passes_abandonnees == 0
end

@testset "moteur : Realtime simulé (passes fabriquées)" begin
    m = FLIMCore.demarrer_moteur(reglages_test(source = "simulation"))
    @test attendre_etat(m, :pret)
    FLIMCore.commander!(m, FLIMCore.Clamp(rois = [1, 2, 3], ordre = [1, 3, 2], scan_s = 0.03, pause_s = 0.01))
    histos = FLIMCore.HistoClamp[]
    @test timedwait(() -> (while isready(m.histogrammes); push!(histos, take!(m.histogrammes)); end; length(histos) >= 6),
                    30.0; pollint = 0.01) === :ok
    FLIMCore.commander!(m, FLIMCore.Arret())
    @test !jusqu_a_fin(m, :clamp).erreur
    lu = [argmax(vec(sum(h.histogrammes[1]; dims = 1))) - 1 for h in histos[1:6]]
    @test lu == [1, 3, 2, 1, 3, 2]                          # les codes dans l'ordre de visite
    @test all(h -> sum(h.histogrammes[1][:, FLIMCore.CODE_HORS_ROI + 1]) == 0, histos)   # pauses : jetées

    # Sans ROI : le code des scans sans ROI.
    FLIMCore.commander!(m, FLIMCore.Clamp(scan_s = 0.03, pause_s = 0.01))
    empty!(histos)
    @test timedwait(() -> (while isready(m.histogrammes); push!(histos, take!(m.histogrammes)); end; length(histos) >= 2),
                    30.0; pollint = 0.01) === :ok
    FLIMCore.commander!(m, FLIMCore.Arret())
    @test !jusqu_a_fin(m, :clamp).erreur
    @test all(h -> sum(h.histogrammes[1]) == sum(h.histogrammes[1][:, FLIMCore.CODE_SANS_ROI + 1]) > 0, histos)
    @test FLIMCore.arreter_moteur(m)
end

@testset "moteur : Ctrl+C en pleine imagerie libère les cartes" begin
    # Le vrai Ctrl+C, dans un autre processus : Julia sort, atexit arrête le
    # moteur, qui libère les cartes (la source note ouvrir/fermer).
    if Sys.isunix()
        trace = tempname()
        code = """
            include($(repr(joinpath(@__DIR__, "..", "src", "spc", "FLIMCore.jl"))))
            mots = FLIMCore.flux_synthetique(trames = 8, lignes_par_trame = 48, periode_ligne = 200, photons_par_ligne = 40)
            source = FLIMCore.SourceRejeu(Dict(0 => FLIMCore.FluxRejeu(mots, 0x1, 25e-9, 12.5)); trace = ARGS[1])
            m = FLIMCore.demarrer_moteur(FLIMCore.Reglages(dossier = mktempdir(), seuil_cfd = 0.0); source = source)
            FLIMCore.commander!(m, FLIMCore.Imagerie(FLIMCore.Geometrie(); duree = Inf))
            while FLIMCore.etat_moteur(m) != :imagerie
                sleep(0.01)
            end
            println("imagerie"); flush(stdout)
            sleep(300)
            """
        p = open(`$(Base.julia_cmd()) -t 2 --startup-file=no -e $code $trace`; read = true)
        @test readline(p) == "imagerie"
        sleep(0.3)
        # Julia diffère parfois un SIGINT reçu à un mauvais moment : on refait
        # Ctrl+C, comme au clavier, jusqu'à trois fois.
        for _ in 1:3
            kill(p, Base.SIGINT)
            timedwait(() -> process_exited(p), 20.0) === :ok && break
        end
        @test process_exited(p)
        @test readlines(trace) == ["ouvrir", "fermer"]
    end
end

end # @testset FLIMCore
