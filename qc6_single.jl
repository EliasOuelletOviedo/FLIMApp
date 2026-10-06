# qc6_single.jl — mode « Single » de la QC-104 : histogrammes construits par la carte.
#
# Il faut : laser, détecteurs allumés, lumière sur IN1 et IN2, reglages_qc.jl.
# SPCM fermé.
#
# Pourquoi : en mode histogramme (mode 0), la carte range les photons de ses
# entrées dans sa mémoire ; le manuel de la DLL ne dit pas dans quels blocs
# vont IN1, IN2 et IN3. Le script mesure trois fois (IN1 seule, IN2 seule,
# les deux), lit tous les blocs de la page 0 et en déduit la place de chaque
# entrée. Le temps croît avec le numéro de canal (la QC-104 mesure du laser
# au photon).
#
# Sortie : resultats/qc/q6_single.csv (une colonne par bloc non vide, IN1 et
# IN2 actives). Colle la sortie dans la conversation.

Base.exit_on_sigint(false)
isdefined(Main, :SPCLite) || include("SPCLite.jl")
using .SPCLite
(isdefined(SPCLite, :VERSION_LITE) && SPCLite.VERSION_LITE >= 9) ||
    error("Julia a gardé une ancienne version de SPCLite.jl : redémarre Julia, puis relance ce script.")
using Printf
include("reglages_qc.jl")

qc6 = (numero_serie = "", temps_collecte_s = 1.0, bits_points = 12, blocs_max = 16)

function mesure_single_qc6(m, r, nblocs, npoints)
    effacer_memoire(m; bloc = -1, page = 0)
    definir_page(m, 0)
    demarrer(m)
    t0 = time()
    while (etat_mesure(m) & SPC_ARMED) != 0 || time() - t0 < 0.05
        time() - t0 > r.temps_collecte_s + 5 && (arreter(m); error("la mesure ne s'arrête pas seule"))
        sleep(0.005)
    end
    return [lire_bloc(m, npoints; bloc = b, page = 0) for b in 0:nblocs - 1]
end

function test_qc6(r, reglages)
    dossier = joinpath(@__DIR__, "resultats", "qc")
    imposes = Dict{String,Any}("mode" => 0, "adc_resolution" => r.bits_points, "stop_on_time" => 1,
                               "stop_on_ovfl" => 1, "collect_time" => r.temps_collecte_s)
    ini(nom, entrees) = ecrire_ini(joinpath(dossier, "q6_$(nom).ini"),
        merge(parametres_qc(merge(reglages, Dict{String,Any}("entrees_actives" => entrees))), imposes))
    configs = [("IN1 seule", (true, false, false, true)), ("IN2 seule", (false, true, false, true)),
               ("IN1 et IN2", (true, true, false, true))]

    avec_spc_tous(ini("depart", configs[3][2]); types = (TYPE_QC104,)) do modules
        m = modules[1]
        if !isempty(r.numero_serie)
            i = findfirst(k -> (try eeprom(k).serie catch; "" end) == r.numero_serie, modules)
            i === nothing && error("aucune QC-104 de n° de série $(r.numero_serie)")
            m = modules[i]
        end
        mem = configurer_memoire(m, r.bits_points, 0)
        npoints = 1 << r.bits_points
        nblocs = min(mem.blocs, r.blocs_max)
        @printf("Mémoire : %d blocs, %d blocs par trame, %d trames par page, %d pages, %d mots par bloc\n",
                mem.blocs, mem.blocs_par_trame, mem.trames_par_page, mem.pages, mem.longueur_bloc)
        mem.longueur_bloc == npoints || println("  NOTE : longueur de bloc ≠ 2^bits_points")
        lu = lire_parametres(m; fichier = joinpath(dossier, "q6_relu.ini"))
        dt_ps = largeur_canal_s(TYPE_QC104, lu) * 4096 / npoints * 1e12

        sommes = Dict{String,Vector{Int}}()
        courbes = Dict{String,Vector{Vector{UInt16}}}()
        for (nom, entrees) in configs
            appliquer_ini(m, ini(nom, entrees))
            mem = configurer_memoire(m, r.bits_points, 0)
            c = mesure_single_qc6(m, r, nblocs, npoints)
            courbes[nom] = c
            sommes[nom] = [sum(Int, x) for x in c]
            @printf("%-11s : coups par bloc %s\n", nom, string(sommes[nom]))
        end

        println()
        place = Dict{String,Int}()
        for (nom, entree) in (("IN1 seule", "IN1"), ("IN2 seule", "IN2"))
            s = sommes[nom]
            b = argmax(s)
            if s[b] > 0 && s[b] > 20 * (sum(s) - s[b] + 1)
                place[entree] = b - 1
                println("  $entree → bloc $(b - 1)")
            else
                println("  $entree : pas de bloc net (comptes $(s)) — entrées non coupées par tdc_control ?")
            end
        end
        ok = length(place) == 2 && place["IN1"] != place["IN2"]

        both = courbes["IN1 et IN2"]
        non_vides = [b for b in 1:nblocs if sum(Int, both[b]) > 0]
        open(joinpath(dossier, "q6_single.csv"), "w") do io
            println(io, "canal,temps_ps,", join(("bloc$(b - 1)" for b in non_vides), ","))
            for j in 1:npoints
                @printf(io, "%d,%.2f", j - 1, (j - 0.5) * dt_ps)
                for b in non_vides
                    print(io, ",", both[b][j])
                end
                println(io)
            end
        end
        println("Courbes (IN1 et IN2 actives) : ", joinpath(dossier, "q6_single.csv"))
        println()
        println(ok ? "RÉUSSI : place de IN1 et IN2 dans la mémoire trouvée (note-la)." :
                     "INCOMPLET : colle la sortie dans la conversation.")
        return ok
    end
end

test_qc6(qc6, REGLAGES_QC)
