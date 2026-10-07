# qc6_single.jl (v3) — mode « Single » de la QC-104 : où la carte range-t-elle IN2 ?
#
# Il faut : laser, détecteurs allumés, lumière sur IN1 et IN2 (comme pour
# qc5), reglages_qc.jl, SPCLite v12. SPCM fermé. Câble de routage branché
# (la 6321 met ses lignes à 5 V : la carte lit le routage 0000).
#
# Ce que v2 a montré : en mode histogramme, IN1 va dans la page 0, bloc 0,
# avec 0, 2 ou 4 bits de routage. IN2 seule ne donne AUCUN coup dans les
# pages 0 à 3, et IN1 + IN2 donne le même nombre de coups que IN1 seule. Les
# photons de IN2 sont donc ailleurs, ou pas enregistrés.
#
# Ce script : mémoire sans bit de routage, trois mesures (IN1 seule, IN2
# seule, les deux) ; pendant chacune, les taux de la carte (pour prouver que
# IN2 compte) ; après chacune, lecture de TOUTE la mémoire (1024 pages), dans
# la banque 0 et, si la DLL l'accepte, dans la banque 1 (mem_bank).
#
# Sortie : resultats/qc/q6_memoire.csv (courbes non vides). Colle la sortie
# dans la conversation.

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
       banques = (0, 1),            # banques de mémoire lues (mem_bank)
       ni_present = true, carte = "Dev1", lignes_routage = "port0/line4:7")

CONFIGS_QC6 = [("IN1 seule", (true, false, false, true)), ("IN2 seule", (false, true, false, true)),
                     ("IN1 et IN2", (true, true, false, true))]

"""Toutes les courbes non vides de la banque courante : (page, bloc) => courbe."""
function lire_tout_qc6(m, mem, npoints)
    blocs_page = mem.blocs_par_trame * mem.trames_par_page
    pleins = Dict{Tuple{Int,Int},Vector{UInt16}}()
    for p in 0:mem.pages - 1
        for b in 0:blocs_page - 1
            d = lire_bloc(m, npoints; bloc = b, page = p)
            any(>(0), d) && (pleins[(p, b)] = d)
        end
    end
    return pleins
end

"""Taux après la mesure (SYNC, IN1, IN2, valeur 4 : association de qc3), en coups/s."""
function taux_qc6(m)
    t0 = time()
    t = taux_bruts(m)
    while t.code < 0 && time() - t0 < 2.0
        sleep(0.1)
        t = taux_bruts(m)
    end
    return t
end

function test_qc6(r, reglages)
    dossier = joinpath(@__DIR__, "resultats", "qc")
    mkpath(dossier)
    npoints = 1 << r.bits_points
    function ini(nom, entrees, banque)
        p = merge(parametres_qc(merge(reglages, Dict{String,Any}("entrees_actives" => entrees))),
                  Dict{String,Any}("mode" => 0, "adc_resolution" => r.bits_points, "stop_on_time" => 1,
                                   "stop_on_ovfl" => 1, "collect_time" => r.temps_collecte_s,
                                   "mem_bank" => banque))
        return ecrire_ini(joinpath(dossier, "q6_$(replace(nom, ' ' => '_'))_b$(banque).ini"), p)
    end

    avec_spc_tous(ini("depart", CONFIGS_QC6[3][2], 0); types = (TYPE_QC104,)) do modules
        m = modules[1]
        if !isempty(r.numero_serie)
            i = findfirst(k -> (try eeprom(k).serie catch; "" end) == r.numero_serie, modules)
            i === nothing && error("aucune QC-104 de n° de série $(r.numero_serie)")
            m = modules[i]
        end

        # Banques que la DLL accepte vraiment pour cette carte
        banques = Int[]
        for b in r.banques
            try
                appliquer_ini(m, ini("essai", CONFIGS_QC6[3][2], b))
                lu = lire_parametres(m)
                vu = get(lu, "mem_bank", NaN)
                if !isnan(vu) && round(Int, vu) == b
                    push!(banques, b)
                else
                    println("Banque $b : la carte garde mem_bank = $vu ; non lue")
                end
            catch e
                println("Banque $b : refusée (", sprint(showerror, e), ")")
            end
        end
        isempty(banques) && (banques = [0])
        println("Banques lues : ", join(banques, ", "))

        resultats = Dict{String,Dict{Tuple{Int,Int,Int},Vector{UInt16}}}()
        for (nom, entrees) in CONFIGS_QC6
            # Effacer toutes les banques, puis mesurer dans la banque 0
            mem = nothing
            for b in banques
                appliquer_ini(m, ini(nom, entrees, b))
                mem = configurer_memoire(m, r.bits_points, 0)
                effacer_memoire(m; bloc = -1, page = -1)
            end
            appliquer_ini(m, ini(nom, entrees, banques[1]))
            mem = configurer_memoire(m, r.bits_points, 0)
            effacer_taux(m)
            definir_page(m, 0)
            demarrer(m)
            t0 = time()
            while (etat_mesure(m) & SPC_ARMED) != 0 || time() - t0 < 0.05
                time() - t0 > r.temps_collecte_s + 5 && (arreter(m); error("la mesure ne s'arrête pas seule"))
                sleep(0.005)
            end
            t = taux_qc6(m)
            v = t.valeurs
            @printf("\n%s : taux SYNC %.4g, IN1 %.4g, IN2 %.4g, valeur 4 %.4g /s%s\n", nom, v[1], v[2], v[3], v[4],
                    t.code < 0 ? " (taux pas prêts)" : "")

            # Lire toute la mémoire, banque par banque
            tout = Dict{Tuple{Int,Int,Int},Vector{UInt16}}()
            for b in banques
                if b != banques[1]
                    appliquer_ini(m, ini(nom, entrees, b))
                    mem = configurer_memoire(m, r.bits_points, 0)
                end
                for ((p, k), d) in lire_tout_qc6(m, mem, npoints)
                    tout[(b, p, k)] = d
                end
            end
            resultats[nom] = tout
            total = sum((sum(Int, d) for d in values(tout)); init = 0)
            cles = sort(collect(keys(tout)))
            @printf("  %d coups au total, dans %d courbe(s) non vide(s)%s\n", total, length(cles),
                    isempty(cles) ? "" : " :")
            for c in first(cles, 12)
                d = tout[c]
                n1, n2 = findfirst(>(0), d), findlast(>(0), d)
                @printf("    banque %d, page %d, bloc %d : %d coups, canaux %d à %d, pic au canal %d\n",
                        c[1], c[2], c[3], sum(Int, d), n1 - 1, n2 - 1, argmax(d) - 1)
            end
            length(cles) > 12 && println("    … et ", length(cles) - 12, " autres")
        end

        # Courbes non vides des trois mesures, pour les regarder
        chemin = joinpath(dossier, "q6_memoire.csv")
        colonnes = [(nom, c) for (nom, _) in CONFIGS_QC6 for c in sort(collect(keys(resultats[nom])))]
        colonnes = first(colonnes, 24)
        open(chemin, "w") do io
            println(io, "canal", isempty(colonnes) ? "" : "," * join(("$(replace(nom, ' ' => '_'))_b$(c[1])_p$(c[2])_k$(c[3])"
                                                                      for (nom, c) in colonnes), ","))
            for j in 1:npoints
                print(io, j - 1)
                for (nom, c) in colonnes
                    print(io, ",", resultats[nom][c][j])
                end
                println(io)
            end
        end
        println("\nCourbes : ", chemin)

        in1 = Set(keys(resultats["IN1 seule"]))
        in2 = Set(keys(resultats["IN2 seule"]))
        if isempty(in2)
            println("IN2 : aucun coup nulle part dans la mémoire lue. Si son taux ci-dessus n'est pas nul, ",
                    "la carte ne range pas IN2 en mode histogramme avec ces réglages.")
        elseif isempty(intersect(in1, in2))
            println("RÉUSSI : IN2 va ailleurs que IN1 : ", join(("banque $(c[1]) page $(c[2]) bloc $(c[3])" for c in sort(collect(in2))), " ; "))
        else
            println("IN1 et IN2 partagent des courbes : ", join(("banque $(c[1]) page $(c[2]) bloc $(c[3])"
                                                               for c in sort(collect(intersect(in1, in2)))), " ; "))
        end
        return !isempty(in2) && isempty(intersect(in1, in2))
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
