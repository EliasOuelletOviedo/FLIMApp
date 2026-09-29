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
        detectes = modules_detectes()          # structures internes de la DLL seulement
        verrou = false
        for k in detectes
            info = info_module(k)
            etat = etat_init(k)
            # L'EEPROM se lit sur la carte : seulement si le module est prêt.
            serie = etat == 0 ? (try eeprom(k).serie catch; "?" end) : "?"
            @printf("  module %d : %-10s n° de série %-10s bus PCI %3d, slot %2d, utilisé %2d : %s\n",
                    k, get(NOMS_MODULES, info.type, string(info.type)), serie,
                    info.bus, info.slot, info.utilise, etat == 0 ? "prête" : explication_init(etat))
            etat == -6 && (verrou = true)
        end
        isempty(detectes) && println("  aucune carte SPC détectée",
                                     code < 0 ? " (SPC_init : $(message_erreur(code)))" : "")
        verrou && println("  → verrou : ferme VS Code, vérifie les processus (voir le plan), ",
                          "puis lance spc_deverrouiller.jl.")
    finally
        liberer()      # arrête seulement les modules prêts ; SPC_close dans tous les cas
    end

    if !isdefined(Main, :DCCLite)
        println("\n== Contrôleurs DCC-100 : sautés (dcc64.dll introuvable) ==")
        return nothing
    end
    println("\n== Contrôleurs DCC-100 (DLL : ", DLL_DCC, ") ==")
    ini_dcc = ecrire_ini_dcc(joinpath(dossier, "c1_dcc.ini"))
    avec_dcc(ini_dcc) do code_dcc
        code_dcc < 0 && println("  DCC_init : $code_dcc ($(message_erreur_dcc(code_dcc)))")
        detectes = modules_detectes_dcc()      # structures internes de la DLL seulement
        verrou = false
        for k in detectes
            info = info_dcc(k)
            etat = etat_init_dcc(k)
            # L'état de surcharge se lit sur la carte : seulement si le module est prêt.
            s = etat == 0 ? (try surcharge_dcc(k) catch; nothing end) : nothing
            protection = s === nothing ? "surcharge ?" :
                         "surcharge C1 $(s.c1 ? "OUI" : "non"), C3 $(s.c3 ? "OUI" : "non")"
            @printf("  module %d : DCC-100 n° de série %-8s bus PCI %3d, slot %2d, utilisé %2d : %s ; %s\n",
                    k, info.serie, info.bus, info.slot, info.utilise,
                    etat == 0 ? "prête" : get(MESSAGES_INIT_DCC, etat, "état $etat"), protection)
            etat == -4 && (verrou = true)
        end
        isempty(detectes) && println("  aucun DCC-100 détecté",
                                     code_dcc < 0 ? " (DCC_init : $(message_erreur_dcc(code_dcc)))" : "")
        verrou && println("  → verrou : ferme le logiciel DCC et SPCM, puis lance dcc_deverrouiller.jl.")
    end
    println("\nLes sorties des DCC-100 pris par ce script sont coupées et les modules libérés.")
    println("Colle cette sortie dans la conversation.")
    return nothing
end

carto1()
