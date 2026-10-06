# qc2_parametres.jl — identité de la QC-104, puis écriture et relecture de ses paramètres.
#
# Branchements : aucun. SPCM fermé.
#
# Déroulé :
#   1. la QC-104 seule est prise (les SPC-150N éventuelles sont laissées libres) ;
#      type (SPC_test_id = 104) et EEPROM ;
#   2. Aller : reglages_qc.jl → fichier .ini → SPC_init → relecture ;
#   3. Retour : d'autres valeurs (B) → SPC_set_parameters → relecture ;
#   4. mode FIFO (1) et FIFO en temps absolu (13) : type de flux annoncé.
# La relecture passe par la DLL elle-même (SPC_get_parameters, puis
# SPC_save_parameters_to_inifile) : on lit ce que la carte applique, après
# ses arrondis. Les clés de la DLL ont un autre sens pour la QC-104 : le
# tableau les donne en clair, avec la clé entre parenthèses.
#
# Réussi si : type 104, chaque valeur appliquée dans les deux sens, flux de
# type 11 (FIFO_TDC) en mode 1. Fichiers relus : resultats/qc/q2_*.ini.

Base.exit_on_sigint(false)
isdefined(Main, :SPCLite) || include("SPCLite.jl")
using .SPCLite
(isdefined(SPCLite, :VERSION_LITE) && SPCLite.VERSION_LITE >= 9) ||
    error("Julia a gardé une ancienne version de SPCLite.jl : redémarre Julia, puis relance ce script.")
using Printf
include("reglages_qc.jl")

qc2 = (
    numero_serie = "",            # "" : la première QC-104 ; sinon son n° de série
    valeurs_B = Dict{String,Any}(
        "entrees_actives" => (true, false, true, true), "routage_entrees" => (false, true, true),
        "photon_unique" => true,
        "seuil_mV" => (-80.0, -40.0, -120.0, -30.0), "zc_mV" => (10.0, -10.0, 20.0, 5.0),
        "plage_tdc_ns" => 32.768, "diviseur_sync" => 2,
        "decalage_ns" => (1.024, 2.048, 0.512, 3.072), "retard_routage_ns" => 8),
)

const IMPOSES_QC2 = Dict{String,Any}("mode" => 1, "adc_resolution" => 12, "stop_on_time" => 0,
                                     "collect_time" => 1.0, "macro_time_clk" => 0)

function test_qc2(r, reglages)
    dossier = joinpath(@__DIR__, "resultats", "qc")
    ini_a = ecrire_ini(joinpath(dossier, "q2_valeurs_A.ini"), merge(parametres_qc(reglages), IMPOSES_QC2))
    ini_b = ecrire_ini(joinpath(dossier, "q2_valeurs_B.ini"),
                       merge(parametres_qc(merge(reglages, r.valeurs_B)), IMPOSES_QC2))

    avec_spc_tous(ini_a; types = (TYPE_QC104,)) do modules
        m = modules[1]
        if !isempty(r.numero_serie)
            i = findfirst(k -> (try eeprom(k).serie catch; "" end) == r.numero_serie, modules)
            i === nothing && error("aucune QC-104 de n° de série $(r.numero_serie)")
            m = modules[i]
        end
        info = info_module(m)
        id = type_module(m)
        e = eeprom(m)
        println("Module $m : bus PCI $(info.bus), slot $(info.slot)")
        println("SPC_test_id : $id ($(nom_module(id)))")
        println("EEPROM : type « $(e.type) », n° de série « $(e.serie) », date « $(e.date) »")
        ok_id = id == TYPE_QC104

        println("\nAller : reglages_qc.jl → SPC_init → relecture")
        lu_a = lire_parametres(m; fichier = joinpath(dossier, "q2_relu_A.ini"))
        ok_a = afficher_qc(reglages, lu_a)

        f = fifo_init(m)
        tic = tic_macro_s(m)
        ok_f = f.type_fifo == 11
        @printf("\nMode FIFO (1) : flux de type %d (11 = FIFO_TDC attendu) %s ; mt_clock brut %d ; ",
                f.type_fifo, ok_f ? "ok" : "DIFFÉRENT", f.mt_clock)
        @printf("tic retenu %.3f ns (manuel DLL : 2,048 ns, vérifié par qc4 et qc5)\n", tic * 1e9)
        @printf("Largeur d'un canal du microtemps : %.2f ps (plage relue / 4096)\n",
                largeur_canal_s(TYPE_QC104, lu_a) * 1e12)

        println("\nRetour : valeurs B → SPC_set_parameters → relecture")
        appliquer_ini(m, ini_b)
        lu_b = lire_parametres(m; fichier = joinpath(dossier, "q2_relu_B.ini"))
        ok_b = afficher_qc(merge(reglages, r.valeurs_B), lu_b)

        # Mode FIFO en temps absolu, pour information
        ini_abs = ecrire_ini(joinpath(dossier, "q2_absolu.ini"),
                             merge(parametres_qc(reglages), IMPOSES_QC2, Dict{String,Any}("mode" => 13)))
        appliquer_ini(m, ini_abs)
        fa = fifo_init(m)
        @printf("\nMode FIFO temps absolu (13) : flux de type %d (12 = FIFO_TDC_ABS attendu), mt_clock brut %d\n",
                fa.type_fifo, fa.mt_clock)

        appliquer_ini(m, ini_a)            # on laisse la carte dans l'état de reglages_qc.jl
        ok = ok_id && ok_a && ok_f && ok_b
        println()
        println(ok ? "RÉUSSI : la QC-104 s'identifie et ses paramètres passent dans les deux sens." :
                     "ÉCHEC : regarde les lignes DIFFÉRENT ou « clé absente » (fichiers relus dans resultats/qc). " *
                     "Une valeur arrondie par la carte (pas de 0,512 ns, de 8,192 ns) n'est pas grave : " *
                     "reporte la valeur appliquée dans reglages_qc.jl.")
        return ok
    end
end

test_qc2(qc2, REGLAGES_QC)
