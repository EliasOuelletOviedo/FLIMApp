# carto1_inventaire.jl — inventaire de tout le matériel, sans rien allumer.
#
# Avant : châssis Magma et Simple-Tau allumés AVANT le PC ; SPCM et le
# logiciel DCC fermés. Aucun fil à toucher.
# Rien n'est mis sous tension. L'initialisation des DCC-100 coupe même
# leurs sorties, par sécurité : un détecteur resté allumé s'éteint.
#
# Donne : les cartes NI, puis chaque SPC-150N et chaque DCC-100 avec son
# numéro de module, son numéro de série et sa place sur le bus PCI. Les
# cartes d'un même châssis ont en général des numéros de bus voisins.
# Colle toute la sortie dans la conversation.

isdefined(Main, :DAQmxLite) || include("DAQmxLite.jl")
using .DAQmxLite
isdefined(Main, :SPCLite) || include("SPCLite.jl")
using .SPCLite
if !isdefined(Main, :DCCLite)
    try
        include("DCCLite.jl")
    catch err
        println("DCCLite non chargé, les DCC-100 seront sautés : ", sprint(showerror, err))
    end
end
if isdefined(Main, :DCCLite)
    using .DCCLite
end
using Printf

function carto1()
    dossier = joinpath(@__DIR__, "resultats", "spc")

    println("== Cartes NI ==")
    try
        for dev in device_names()
            @printf("  %-8s %-12s n° de série %X\n", dev, product_type(dev), serial_number(dev))
        end
    catch err
        println("  NI-DAQmx indisponible : ", sprint(showerror, err))
    end

    println("\n== Cartes SPC (DLL : ", DLL_SPCM, ") ==")
    ini = ecrire_ini(joinpath(dossier, "c1_spc.ini"))
    code = initialiser(ini)
    try
        code < 0 && println("  SPC_init : $code ($(message_erreur(code)))")
        vues = 0
        for k in 0:7
            info = try
                info_module(k)
            catch
                nothing
            end
            (info === nothing || info.type <= 0) && continue
            vues += 1
            etat = etat_init(k)
            serie = try
                eeprom(k).serie
            catch
                "?"
            end
            @printf("  module %d : %-10s n° de série %-10s bus PCI %3d, slot %2d : %s\n",
                    k, get(NOMS_MODULES, info.type, string(info.type)), serie,
                    info.bus, info.slot, etat == 0 ? "prête" : explication_init(etat))
        end
        vues == 0 && println("  aucune carte SPC trouvée : ", explication_init(etat_init(0), code))
    finally
        liberer_tous(0:3)
    end

    if !isdefined(Main, :DCCLite)
        println("\n== Contrôleurs DCC-100 : sautés (dcc64.dll introuvable) ==")
        return nothing
    end
    println("\n== Contrôleurs DCC-100 (DLL : ", DLL_DCC, ") ==")
    ini_dcc = ecrire_ini_dcc(joinpath(dossier, "c1_dcc.ini"))
    avec_dcc(ini_dcc) do code_dcc
        code_dcc < 0 && println("  DCC_init : $code_dcc ($(message_erreur_dcc(code_dcc)))")
        vues = 0
        for k in 0:7
            etat = etat_init_dcc(k)
            info = try
                info_dcc(k)
            catch
                nothing
            end
            present = (info !== nothing && info.type == 100) || etat in (0, -2, -4)
            present || continue
            vues += 1
            s = try
                surcharge_dcc(k)
            catch
                nothing
            end
            protection = s === nothing ? "?" :
                         "surcharge C1 $(s.c1 ? "OUI" : "non"), C3 $(s.c3 ? "OUI" : "non")"
            if info === nothing
                @printf("  module %d : %s\n", k, get(MESSAGES_INIT_DCC, etat, "état $etat"))
            else
                @printf("  module %d : DCC-100 n° de série %-12s bus PCI %3d, slot %2d : %s ; %s\n",
                        k, info.serie, info.bus, info.slot,
                        etat == 0 ? "prête" : get(MESSAGES_INIT_DCC, etat, "état $etat"), protection)
            end
        end
        vues == 0 && println("  aucun DCC-100 trouvé : ",
                             get(MESSAGES_INIT_DCC, etat_init_dcc(0), "état $(etat_init_dcc(0))"))
    end
    println("\nToutes les sorties des DCC-100 sont coupées. Colle cette sortie dans la conversation.")
    return nothing
end

carto1()
