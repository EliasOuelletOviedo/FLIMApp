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
    r = FLIMCore.Reglages(pixels_par_ligne = 256, series = ["A", "B"], rejeu = [raw"C:\données\a.spc"])
    r.spc["cfd_limit_low"] = -80.0
    r.dcc["note"] = "gain \"haut\""
    chemin = joinpath(mktempdir(), "spc.toml")
    FLIMCore.ecrire_reglages(chemin, r)
    relu = FLIMCore.lire_reglages(chemin)
    @test all(f -> f == :fichier || getfield(relu, f) == getfield(r, f), fieldnames(FLIMCore.Reglages))
    @test relu.fichier == abspath(chemin) && relu.spc["sync_freq_div"] isa Int
    @test FLIMCore.geometrie(relu).pixels_par_ligne == 256

    # Une faute de frappe ou une valeur hors plage ne passe pas.
    @test_throws ErrorException FLIMCore.reglages_depuis_dict(Dict("imagerie" => Dict("pixel_par_ligne" => 3)))
    @test_throws ErrorException FLIMCore.reglages_depuis_dict(Dict("single" => Dict("resolution_adc" => 11)))
    @test_throws ErrorException FLIMCore.reglages_depuis_dict(Dict("banc" => Dict("x" => 1)))

    # Le fichier livré est celui qu'écrit ecrire_reglages avec les défauts.
    livre = joinpath(@__DIR__, "..", "config", "spc.toml")
    @test isfile(livre)
    d = FLIMCore.lire_reglages(livre)
    @test all(f -> f == :fichier || getfield(d, f) == getfield(FLIMCore.Reglages(), f), fieldnames(FLIMCore.Reglages))

    # Paramètres imposés par chaque mesure, par-dessus [spc_module].
    p, imposes = FLIMCore.parametres_imagerie(d, FLIMCore.Geometrie(ligne_front_montant = false))
    @test p["mode"] == 1 && p["routing_mode"] == 0x4600 && p["tac_range"] == 50.0 && haskey(imposes, "macro_time_clk")
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
    g = FLIMCore.Geometrie(pixels_par_ligne = 100, lignes_par_image = 4)
    res = FLIMCore.ranger_photons(e.mots, TIC_TEST, DT_TEST, g)
    @test res.photons == 3 && res.dans_image == 2 && res.trames == 2
    @test res.intensite[3, 4] == 1 && res.intensite[2, 1] == 1
    @test res.somme_t[3, 4] ≈ 10.5 * DT_TEST
    @test res.declin[11] == 1 && res.declin[21] == 1          # temps croissant : canal = 4095 - ADC

    # Le macrotemps déborde (12 bits) : un seul tour par MTOV, plusieurs par un enregistrement dédié.
    d = FLIMCore.SPCLite.decoder!(FLIMCore.SPCLite.Decodeur(garder_photons = true), e.mots)
    @test d.marqueurs[3] == [1_000, 20_000, 40_000] && d.t_photons == [101, 1_407, 20_200]
end

@testset "rangement trame par trame == traitement en bloc (étape 2)" begin
    mots = flux_test()
    alea = FLIMCore.Alea(3)
    for g in (FLIMCore.Geometrie(),
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
                                    geometrie = FLIMCore.Geometrie(), dcc = FLIMCore.DCC_DEFAUT)
    @test FLIMCore.lire_spc(prefixe * ".spc") == (0x12345678, mots)
    res = FLIMCore.retraiter(basename(prefixe), FLIMCore.Geometrie(); dossier = dossier, io = devnull)
    @test res == FLIMCore.ranger_photons(mots, TIC_TEST, DT_TEST, FLIMCore.Geometrie())
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
    r = reglages_test(resolution_adc = 10)
    m = FLIMCore.demarrer_moteur(r; source = source)
    @test attendre_etat(m, :pret)
    histos = FLIMCore.HistoSingle[]
    FLIMCore.commander!(m, FLIMCore.Single(0.0005, 3))
    fin = FLIMCore.attendre_fin(m, :single; delai_s = 60, io = nothing, f = x -> x isa FLIMCore.HistoSingle && push!(histos, x))
    @test !fin.erreur && length(histos) == 6
    @test all(h -> length(h.histogramme) == 1024 && sum(Int, h.histogramme) > 0 && h.fin == "temps écoulé", histos)
    @test all(h -> h.dt_ns ≈ 12.5 / 1024, histos)
    csv = only(filter(f -> endswith(f, "module1.csv"), fin.fichiers))
    lignes = filter(l -> !startswith(l, "#"), readlines(csv))
    @test lignes[1] == "canal,temps_ns,h1,h2,h3,somme" && length(lignes) == 1025
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
        kill(p, Base.SIGINT)
        @test timedwait(() -> process_exited(p), 60.0) === :ok
        @test readlines(trace) == ["ouvrir", "fermer"]
    end
end

end # @testset FLIMCore
