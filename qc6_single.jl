# qc6_single.jl (v2) — mode « Single » de la QC-104 : histogrammes construits par la carte.
#
# Il faut : laser, détecteurs allumés, de la lumière sur IN1 et IN2 (un
# échantillon fluorescent de préférence), reglages_qc.jl, SPCLite v12.
# SPCM fermé. Câble de routage branché comme pour qc4 et qc5 (la 6321 met ses
# lignes à 5 V : la carte lit le routage 0000).
#
# Pourquoi : en mode histogramme (mode 0), la carte range les photons dans sa
# mémoire, une courbe par bloc. Le manuel de la DLL ne dit pas où vont IN1 et
# IN2 ; sur ta carte, configurée sans bits de routage, la mémoire n'a qu'un
# bloc par page (v1 lisait les blocs 1 à 15 : erreur -14). Ce script essaie
# trois configurations de la mémoire (0, 2 et 4 bits de routage), mesure à
# chaque fois IN1 seule, IN2 seule puis les deux, et lit tous les blocs des
# premières pages pour trouver où va chaque entrée.
#
# Sortie : resultats/qc/q6_single_rN.csv (N = bits de routage ; une colonne
# par bloc non vide, IN1 et IN2 actives). Colle la sortie dans la conversation.

Base.exit_on_sigint(false)
isdefined(Main, :DAQmxLite) || include("DAQmxLite.jl")
using .DAQmxLite
isdefined(Main, :SPCLite) || include("SPCLite.jl")
using .SPCLite
(isdefined(SPCLite, :VERSION_LITE) && SPCLite.VERSION_LITE >= 12) ||
    error("Julia a gardé une ancienne version de SPCLite.jl (il faut la v12) : redémarre Julia, puis relance ce script.")
using Printf
include("reglages_qc.jl")

qc6 = (numero_serie = "", temps_collecte_s = 1.0, bits_points = 12,
       bits_routage = (0, 2, 4),    # configurations de la mémoire essayées
       pages_lues = 4,              # pages lues au plus, par configuration
       ni_present = true, carte = "Dev1", lignes_routage = "port0/line4:7")

"""Une mesure : efface toute la mémoire, mesure sur la page 0, lit les blocs des premières pages."""
function mesure_single_qc6(m, r, mem, npoints)
    effacer_memoire(m; bloc = -1, page = -1)
    definir_page(m, 0)
    demarrer(m)
    t0 = time()
    while (etat_mesure(m) & SPC_ARMED) != 0 || time() - t0 < 0.05
        time() - t0 > r.temps_collecte_s + 5 && (arreter(m); error("la mesure ne s'arrête pas seule"))
        sleep(0.005)
    end
    blocs_page = mem.blocs_par_trame * mem.trames_par_page
    courbes = Dict{Tuple{Int,Int},Vector{UInt16}}()
    for p in 0:min(mem.pages, r.pages_lues) - 1
        for b in 0:blocs_page - 1
            courbes[(p, b)] = lire_bloc(m, npoints; bloc = b, page = p)
        end
    end
    return courbes
end

"""Clé (page, bloc) qui a le plus de coups, et sa part du total."""
function bloc_principal_qc6(sommes::Dict{Tuple{Int,Int},Int})
    total = sum(values(sommes); init = 0)
    total == 0 && return (nothing, 0.0, 0)
    meilleur, n = first(sommes)
    for (k, v) in sommes
        v > n && ((meilleur, n) = (k, v))
    end
    return (meilleur, n / total, total)
end

function test_qc6(r, reglages)
    dossier = joinpath(@__DIR__, "resultats", "qc")
    mkpath(dossier)
    imposes = Dict{String,Any}("mode" => 0, "adc_resolution" => r.bits_points, "stop_on_time" => 1,
                               "stop_on_ovfl" => 1, "collect_time" => r.temps_collecte_s)
    ini(nom, entrees) = ecrire_ini(joinpath(dossier, "q6_$(replace(nom, ' ' => '_')).ini"),
        merge(parametres_qc(merge(reglages, Dict{String,Any}("entrees_actives" => entrees))), imposes))
    configs = [("IN1 seule", (true, false, false, true)), ("IN2 seule", (false, true, false, true)),
               ("IN1 et IN2", (true, true, false, true))]
    npoints = 1 << r.bits_points

    avec_spc_tous(ini("depart", configs[3][2]); types = (TYPE_QC104,)) do modules
        m = modules[1]
        if !isempty(r.numero_serie)
            i = findfirst(k -> (try eeprom(k).serie catch; "" end) == r.numero_serie, modules)
            i === nothing && error("aucune QC-104 de n° de série $(r.numero_serie)")
            m = modules[i]
        end
        lu = lire_parametres(m; fichier = joinpath(dossier, "q6_relu.ini"))
        dt_ps = largeur_canal_s(TYPE_QC104, lu) * 4096 / npoints * 1e12
        @printf("Canal de %.2f ps ; limite basse de la fenêtre (tac_limit_low) : %s %%\n", dt_ps,
                string(get(lu, "tac_limit_low", "?")))

        bilan = String[]
        for bits in r.bits_routage
            mem = try
                configurer_memoire(m, r.bits_points, bits)
            catch e
                println("\nRoutage sur $bits bits : refusé par la DLL (", sprint(showerror, e), ")")
                push!(bilan, "$bits bits : refusé par la DLL")
                continue
            end
            blocs_page = mem.blocs_par_trame * mem.trames_par_page
            @printf("\nMémoire avec %d bits de routage : %d blocs par page, %d pages, %d mots par bloc\n",
                    bits, blocs_page, mem.pages, mem.longueur_bloc)
            mem.longueur_bloc == npoints || println("  NOTE : longueur de bloc ≠ 2^bits_points")

            sommes = Dict{String,Dict{Tuple{Int,Int},Int}}()
            courbes = Dict{String,Dict{Tuple{Int,Int},Vector{UInt16}}}()
            echec = nothing
            for (nom, entrees) in configs
                try
                    appliquer_ini(m, ini(nom, entrees))
                    mem = configurer_memoire(m, r.bits_points, bits)   # après appliquer_ini, toujours
                    c = mesure_single_qc6(m, r, mem, npoints)
                    courbes[nom] = c
                    sommes[nom] = Dict(k => sum(Int, v) for (k, v) in c)
                catch e
                    echec = "$nom : " * sprint(showerror, e)
                    break
                end
                pleins = sort([k for (k, s) in sommes[nom] if s > 0])
                @printf("  %-11s : %s\n", nom, isempty(pleins) ? "aucun coup" :
                        join(("page $(k[1]) bloc $(k[2]) : $(sommes[nom][k])" for k in pleins), " ; "))
            end
            if echec !== nothing
                println("  ERREUR ", echec)
                push!(bilan, "$bits bits : erreur ($echec)")
                continue
            end

            # Place de chaque entrée : le bloc qui reçoit presque tout quand elle est seule.
            place = Dict{String,Tuple{Int,Int}}()
            for (nom, entree) in (("IN1 seule", "IN1"), ("IN2 seule", "IN2"))
                k, part, total = bloc_principal_qc6(sommes[nom])
                if k === nothing
                    println("  $entree : aucun coup (détecteur, seuil, lumière ?)")
                elseif part >= 0.95
                    place[entree] = k
                    @printf("  %s → page %d, bloc %d (%.1f %% de ses %d coups)\n", entree, k[1], k[2], 100 * part, total)
                else
                    @printf("  %s : réparti sur plusieurs blocs (le premier n'a que %.1f %%)\n", entree, 100 * part)
                end
            end
            separe = length(place) == 2 && place["IN1"] != place["IN2"]
            if length(place) == 2
                both = sommes["IN1 et IN2"]
                @printf("  IN1 et IN2 ensemble : %d coups dans le bloc de IN1, %d dans celui de IN2\n",
                        get(both, place["IN1"], 0), get(both, place["IN2"], 0))
                separe || println("  IN1 et IN2 tombent dans le MÊME bloc : courbes additionnées")
            end
            push!(bilan, "$bits bits : " * (separe ?
                  "IN1 → page $(place["IN1"][1]) bloc $(place["IN1"][2]), IN2 → page $(place["IN2"][1]) bloc $(place["IN2"][2])" :
                  "IN1 et IN2 non séparés"))

            # Courbes de la mesure à deux entrées
            c = courbes["IN1 et IN2"]
            non_vides = sort([k for (k, v) in c if any(>(0), v)])
            chemin = joinpath(dossier, "q6_single_r$(bits).csv")
            open(chemin, "w") do io
                println(io, "canal,temps_ps", isempty(non_vides) ? "" :
                        "," * join(("p$(k[1])_b$(k[2])" for k in non_vides), ","))
                for j in 1:npoints
                    @printf(io, "%d,%.2f", j - 1, (j - 0.5) * dt_ps)
                    for k in non_vides
                        print(io, ",", c[k][j])
                    end
                    println(io)
                end
            end
            println("  Courbes (IN1 et IN2 actives) : ", chemin)
        end

        println("\nBilan :")
        foreach(l -> println("  ", l), bilan)
        ok = any(l -> occursin("IN1 → page", l), bilan)
        println(ok ? "RÉUSSI : au moins une configuration sépare IN1 et IN2 (note laquelle)." :
                     "INCOMPLET : colle la sortie dans la conversation.")
        return ok
    end
end

if qc6.ni_present
    withtask("routage_qc6") do th
        add_do(th, "$(qc6.carte)/$(qc6.lignes_routage)")
        write_do(th, UInt8[1, 1, 1, 1])     # lignes à 5 V : la carte lit le routage 0000
        test_qc6(qc6, REGLAGES_QC)
    end
else
    test_qc6(qc6, REGLAGES_QC)
end
