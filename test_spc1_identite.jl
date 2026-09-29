# test_spc1_identite.jl — la DLL se charge, la carte répond et s'identifie.
#
# Branchements : aucun. SPCM doit être FERMÉ (un seul programme à la fois
# peut tenir la carte).
# Lancer depuis le dossier banc-chlore :  include("test_spc1_identite.jl")
#
# Réussi si : état d'initialisation 0, type 151 (SPC-150N) et numéro de
# série lu dans l'EEPROM de la carte.
#
# `simulation = true` fait la même chose sans carte : la DLL simule une
# SPC-150N. Si la simulation passe et le mode matériel échoue, la DLL et
# Julia vont bien, le problème est du côté de la carte ou de son pilote.

isdefined(Main, :SPCLite) || include("SPCLite.jl")
using .SPCLite
using Printf

spc1 = (simulation = false, module_no = 0)

function test_spc1(r)
    dossier = joinpath(@__DIR__, "resultats", "spc")
    println("DLL : ", DLL_SPCM)
    ini = ecrire_ini(joinpath(dossier, "t1_identite.ini"); simulation = r.simulation ? 151 : 0)
    code = initialiser(ini)
    try
        @printf("SPC_init : %d%s\n", code, code < 0 ? " (" * message_erreur(code) * ")" : "")
        mode = mode_dll()
        println("Mode de la DLL : ", mode == 0 ? "matériel" : "simulation ($mode)")

        println("\nModules vus par la DLL :")
        for k in 0:7
            info = try
                info_module(k)
            catch
                nothing
            end
            info === nothing && continue
            (info.type > 0 || k == r.module_no) || continue
            @printf("  module %d : type %d (%s), bus PCI %d, slot %d, utilisé %d, init %d\n",
                    k, info.type, get(NOMS_MODULES, info.type, "?"), info.bus, info.slot,
                    info.utilise, info.init)
        end

        etat = etat_init(r.module_no)
        println("\nModule $(r.module_no) : ", explication_init(etat, code))
        id = type_module(r.module_no)
        println("SPC_test_id : ", id, id >= 0 ? " ($(get(NOMS_MODULES, id, "type inconnu")))" :
                                              " ($(message_erreur(id)))")
        try
            e = eeprom(r.module_no)
            println("EEPROM : type « $(e.type) », n° de série « $(e.serie) », date « $(e.date) »")
        catch err
            println("EEPROM illisible : ", sprint(showerror, err))
        end

        ok = etat == 0 && id in (150, 151)
        println()
        if ok && !r.simulation
            println("RÉUSSI : la carte répond, c'est une $(NOMS_MODULES[id]).")
        elseif ok
            println("RÉUSSI en simulation : la DLL et les fichiers .ini fonctionnent. ",
                    "Relance avec simulation = false.")
        else
            println("ÉCHEC : lis l'état d'initialisation ci-dessus, puis le tableau ",
                    "« Si un test échoue » du plan.")
        end
        return ok
    finally
        liberer(r.module_no)
    end
end

test_spc1(spc1)
