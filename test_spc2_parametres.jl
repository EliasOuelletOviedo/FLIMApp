# test_spc2_parametres.jl — écrire des paramètres dans la carte et les relire.
#
# Branchements : aucun. SPCM fermé.
#
# Aller  : fichier .ini (valeurs A)  → SPC_init          → relecture.
# Retour : fichier .ini (valeurs B)  → SPC_set_parameters → relecture.
# La relecture passe par la DLL elle-même (SPC_get_parameters, puis
# SPC_save_parameters_to_inifile) : on lit ce que la carte applique vraiment,
# après les arrondis du matériel.
#
# Réussi si : chaque valeur relue égale la valeur demandée (seuils à ±3 mV,
# durées à ±2 %, pourcentages à ±1), et le mode FIFO annonce un flux de type 7.

isdefined(Main, :SPCLite) || include("SPCLite.jl")
using .SPCLite
using Printf

spc2 = (
    module_no = 0,
    valeurs_A = Dict{String,Any}(
        "mode" => 1, "adc_resolution" => 12, "stop_on_time" => 0,
        "routing_mode" => 0xff00, "macro_time_clk" => 0, "collect_time" => 0.5,
        "rate_count_time" => 0.25, "sync_freq_div" => 2, "tac_range" => 100.0,
        "tac_gain" => 4, "sync_threshold" => -60.0, "cfd_limit_low" => -40.0,
        "tac_limit_low" => 5.0, "tac_limit_high" => 95.0),
    valeurs_B = Dict{String,Any}(
        "mode" => 0, "adc_resolution" => 10, "stop_on_time" => 1,
        "routing_mode" => 0, "macro_time_clk" => 0, "collect_time" => 1.0,
        "rate_count_time" => 1.0, "sync_freq_div" => 4, "tac_range" => 50.0,
        "tac_gain" => 1, "sync_threshold" => -30.0, "cfd_limit_low" => -80.0,
        "tac_limit_low" => 10.0, "tac_limit_high" => 80.0),
)

function test_spc2(r)
    dossier = joinpath(@__DIR__, "resultats", "spc")

    function tolerance(cle, v)
        cle in ("sync_threshold", "cfd_limit_low", "cfd_zc_level", "sync_zc_level") && return 3.0
        cle in ("collect_time", "tac_range", "rate_count_time") && return 0.02 * abs(v)
        cle in ("tac_limit_low", "tac_limit_high", "tac_offset") && return 1.0
        return 0.0
    end

    function comparer(titre, demande, relu)
        println("\n", titre)
        @printf("  %-16s %12s %12s\n", "paramètre", "demandé", "relu")
        ok = true
        for cle in sort!(collect(keys(demande)))
            v = Float64(demande[cle])
            if !haskey(relu, cle)
                @printf("  %-16s %12g %12s  ABSENT du fichier relu\n", cle, v, "-")
                ok = false
                continue
            end
            l = relu[cle]
            bon = abs(l - v) <= tolerance(cle, v)
            ok &= bon
            @printf("  %-16s %12g %12g  %s\n", cle, v, l, bon ? "ok" : "DIFFÉRENT")
        end
        return ok
    end

    ini_a = ecrire_ini(joinpath(dossier, "t2_valeurs_A.ini"), r.valeurs_A)
    ini_b = ecrire_ini(joinpath(dossier, "t2_valeurs_B.ini"), r.valeurs_B)

    avec_spc(ini_a; module_no = r.module_no) do m
        lu_a = lire_parametres(m; fichier = joinpath(dossier, "t2_relu_A.ini"))
        ok_a = comparer("Aller : fichier .ini → SPC_init → relecture", r.valeurs_A, lu_a)

        f = fifo_init(m)
        ok_f = f.type_fifo == 7 && f.horloge_macro_s > 0
        @printf("\nMode FIFO : flux de type %d (7 attendu), tic du macrotemps %.1f ns  %s\n",
                f.type_fifo, f.horloge_macro_s * 1e9, ok_f ? "ok" : "DIFFÉRENT")

        appliquer_ini(m, ini_b)
        lu_b = lire_parametres(m; fichier = joinpath(dossier, "t2_relu_B.ini"))
        ok_b = comparer("Retour : fichier .ini → SPC_set_parameters → relecture", r.valeurs_B, lu_b)

        ok = ok_a && ok_f && ok_b
        println()
        println(ok ? "RÉUSSI : les paramètres passent dans les deux sens." :
                     "ÉCHEC : regarde les lignes DIFFÉRENT ou ABSENT (fichiers relus dans resultats/spc).")
        return ok
    end
end

test_spc2(spc2)
