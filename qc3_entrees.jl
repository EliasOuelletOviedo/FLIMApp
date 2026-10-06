# qc3_entrees.jl — SYNC et compteurs de taux de la QC-104, entrée par entrée.
#
# Il faut : laser allumé (SYNC branché), les deux détecteurs allumés (logiciel
# DCC) avec un peu de lumière, IN1 et IN2 branchés. SPCM fermé.
#
# Pourquoi : SPC_read_rates rend 4 valeurs nommées, pour une SPC-150N,
# SYNC, CFD, TAC et ADC. Pour la QC-104, le manuel ne dit pas laquelle
# correspond à quelle entrée. Le script coupe et rallume les entrées par
# tdc_control et regarde quelles valeurs suivent.
#
# Réussi si : SYNC correct et une association valeur → entrée sans
# ambiguïté. Si les taux ne bougent pas quand une entrée est coupée (les
# compteurs ignorent peut-être tdc_control), coupe un détecteur dans le
# logiciel DCC et relance : le script le signale. Colle la sortie.

Base.exit_on_sigint(false)
isdefined(Main, :SPCLite) || include("SPCLite.jl")
using .SPCLite
(isdefined(SPCLite, :VERSION_LITE) && SPCLite.VERSION_LITE >= 9) ||
    error("Julia a gardé une ancienne version de SPCLite.jl : redémarre Julia, puis relance ce script.")
using Printf
include("reglages_qc.jl")

qc3 = (numero_serie = "", lectures = 3, attente_s = 1.3)   # rate_count_time vaut 1 s par défaut

const CONFIGS_QC3 = [
    ("toutes (reglages_qc.jl)", nothing),
    ("SYNC seul",               (false, false, false, true)),
    ("IN1 + SYNC",              (true, false, false, true)),
    ("IN2 + SYNC",              (false, true, false, true)),
    ("IN3 + SYNC",              (false, false, true, true)),
    ("IN1 seule, SYNC coupé",   (true, false, false, false)),
]

function test_qc3(r, reglages)
    dossier = joinpath(@__DIR__, "resultats", "qc")
    imposes = Dict{String,Any}("mode" => 1, "adc_resolution" => 12, "stop_on_time" => 0,
                               "macro_time_clk" => 0)
    ini(nom, entrees) = ecrire_ini(joinpath(dossier, "q3_$(nom).ini"),
        merge(parametres_qc(entrees === nothing ? reglages :
                            merge(reglages, Dict{String,Any}("entrees_actives" => entrees))), imposes))

    avec_spc_tous(ini("depart", nothing); types = (TYPE_QC104,)) do modules
        m = modules[1]
        if !isempty(r.numero_serie)
            i = findfirst(k -> (try eeprom(k).serie catch; "" end) == r.numero_serie, modules)
            i === nothing && error("aucune QC-104 de n° de série $(r.numero_serie)")
            m = modules[i]
        end
        @printf("%-24s %11s %11s %11s %11s   %s\n", "entrées actives", "valeur 1", "valeur 2",
                "valeur 3", "valeur 4", "SYNC")
        resultats = Dict{String,Vector{Float64}}()
        for (k, (nom, entrees)) in enumerate(CONFIGS_QC3)
            appliquer_ini(m, ini("c$k", entrees))
            effacer_taux(m)
            somme = zeros(8)
            n = 0
            for _ in 1:r.lectures
                sleep(r.attente_s)
                v = taux_bruts(m)
                v.code == 0 || continue
                somme .+= v.valeurs
                n += 1
            end
            s = sync_etat(m)
            moy = n > 0 ? somme ./ n : fill(NaN, 8)
            resultats[nom] = moy
            @printf("%-24s %11.4g %11.4g %11.4g %11.4g   %s\n", nom, moy[1], moy[2], moy[3], moy[4],
                    get(MESSAGES_SYNC, s, string(s)))
            any(x -> !isnan(x) && x != 0, moy[5:8]) &&
                @printf("%-24s valeurs 5 à 8 non nulles : %s\n", "", string(round.(moy[5:8]; sigdigits = 4)))
        end
        appliquer_ini(m, ini("fin", nothing))

        # Association : une valeur appartient à une entrée si elle est nettement plus
        # grande quand cette entrée est active que quand elle est coupée.
        println()
        ref = resultats["SYNC seul"]
        assoc = Dict{Int,String}()
        for (nom, entree) in (("IN1 + SYNC", "IN1"), ("IN2 + SYNC", "IN2"), ("IN3 + SYNC", "IN3"))
            v = resultats[nom]
            for i in 1:4
                if v[i] > 10 * max(ref[i], 1.0) && v[i] > 100
                    assoc[i] = haskey(assoc, i) ? assoc[i] * " ou " * entree : entree
                end
            end
        end
        sans_sync = resultats["IN1 seule, SYNC coupé"]
        for i in 1:4
            if ref[i] > 1e5 && sans_sync[i] < 0.01 * ref[i]
                assoc[i] = get(assoc, i, "") == "" ? "SYNC" : assoc[i] * " ou SYNC"
            end
        end
        for i in 1:4
            println("  valeur $i : ", get(assoc, i, "non associée (entrée sans signal, ou compteur insensible)"))
        end
        bouge = any(!isempty, values(assoc))
        egaux = all(nom -> resultats[nom][1:4] ≈ resultats["toutes (reglages_qc.jl)"][1:4],
                    ("SYNC seul", "IN1 + SYNC", "IN2 + SYNC"))
        if !bouge || egaux
            println("\nLes taux ne suivent pas tdc_control : coupe le détecteur 2 dans le logiciel DCC, ",
                    "relance, et compare avec ce tableau-ci (la valeur qui s'effondre est IN2).")
        end
        ok = sync_etat(m) == 1 && bouge
        println()
        println(ok ? "RÉUSSI : SYNC correct ; association ci-dessus (note-la, ton GUI en aura besoin)." :
                     "ÉCHEC ou incomplet : voir ci-dessus ; colle la sortie dans la conversation.")
        return ok
    end
end

test_qc3(qc3, REGLAGES_QC)
