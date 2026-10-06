# qc1_inventaire.jl — trouve la SPC-QC-104 et toutes les cartes B&H, sans rien mesurer.
#
# Avant : la QC-104 est installée, le PC redémarré, SPCM a été ouvert une
# fois (et le firmware mis à jour s'il l'a demandé), puis REFERMÉ. Châssis
# Magma et Simple-Tau allumés avant le PC, comme d'habitude. Aucun fil à
# toucher.
#
# Donne : les cartes NI, puis chaque carte SPC avec son numéro de module,
# son type, son numéro de série, sa place sur le bus PCI et son état.
# Attention : la DLL numérote les modules dans l'ordre des numéros de série,
# pas des slots ; l'arrivée de la QC-104 peut décaler les numéros des
# SPC-150N. Les scripts choisissent donc les cartes par type, plus par numéro.
#
# Réussi si : une carte de type 104 (SPC-QC-104), prête, avec son numéro de
# série lu dans son EEPROM. Colle toute la sortie dans la conversation.

Base.exit_on_sigint(false)
isdefined(Main, :DAQmxLite) || include("DAQmxLite.jl")
using .DAQmxLite
isdefined(Main, :SPCLite) || include("SPCLite.jl")
using .SPCLite
(isdefined(SPCLite, :VERSION_LITE) && SPCLite.VERSION_LITE >= 9) ||
    error("Julia a gardé une ancienne version de SPCLite.jl : redémarre Julia, puis relance ce script.")
using Printf

function qc1()
    dossier = joinpath(@__DIR__, "resultats", "qc")

    println("== Cartes NI ==")
    try
        for dev in device_names()
            @printf("  %-8s %-12s n° de série %X\n", dev, product_type(dev), serial_number(dev))
        end
    catch err
        println("  NI-DAQmx indisponible : ", sprint(showerror, err))
    end

    println("\n== Cartes SPC (DLL : ", DLL_SPCM, ") ==")
    ini = ecrire_ini(joinpath(dossier, "q1_inventaire.ini"))
    code = initialiser(ini)
    trouvee = false
    a_prendre = Int16[]          # QC-104 prises seules : les autres cartes ont alors été rendues
    try
        code < 0 && println("  SPC_init : $code ($(message_erreur(code)))")
        detectes = modules_detectes()          # structures internes de la DLL seulement
        isempty(detectes) && println("  aucune carte SPC détectée",
                                     code < 0 ? " (SPC_init : $(message_erreur(code)))" : "")
        types = types_presents()
        qcs = Int16[k for k in detectes if est_qc(types[k])]

        # Une QC-104 pas prête (et pas verrouillée ailleurs) : SPC_set_mode l'initialise seule.
        # C'est le cas si SPC_init n'initialise que le type de la première carte trouvée.
        append!(a_prendre, Int16[k for k in qcs if etat_init(k) != 0 && etat_init(k) != -6])
        if !isempty(a_prendre)
            println("  QC-104 détectée mais pas prête après SPC_init : essai de SPC_set_mode sur elle seule…")
            r = try
                prendre_modules(a_prendre)
            catch err
                sprint(showerror, err)
            end
            println("  SPC_set_mode : ", r)
        end

        verrou = false
        for k in detectes
            info = info_module(k)
            etat = etat_init(k)
            # EEPROM et SPC_test_id se lisent sur la carte : seulement si le module est prêt
            # et tenu par cette session (pas une carte rendue par SPC_set_mode).
            tenu = isempty(a_prendre) || k in a_prendre
            e = etat == 0 && tenu ? (try eeprom(k) catch; nothing end) : nothing
            id = e === nothing ? nothing : type_module(k)
            @printf("  module %d : %-11s n° de série %-10s bus PCI %3d, slot %2d, utilisé %2d : %s\n",
                    k, nom_module(info.type), e === nothing ? "?" : e.serie, info.bus, info.slot,
                    info.utilise, !tenu ? "rendue (pour laisser la QC-104 seule)" :
                                  etat == 0 ? "prête" : explication_init(etat))
            if e !== nothing
                @printf("             EEPROM : type « %s », date « %s » ; SPC_test_id : %s\n", e.type, e.date,
                        id >= 0 ? "$id ($(nom_module(id)))" : "$id ($(message_erreur(id)))")
            end
            etat == -6 && (verrou = true)
            if est_qc(info.type) && e !== nothing && id == TYPE_QC104
                trouvee = true
            end
        end

        if length(unique(values(types))) > 1
            println("\n  Cartes de types différents : la DLL n'en pilote qu'un type à la fois. ",
                    "Les scripts qc* prennent la QC-104 seule (types = (TYPE_QC104,)) ; ",
                    "pour les anciens scripts SPC-150N, ajoute types = (151,) à avec_spc / avec_spc_tous.")
        end
        verrou && println("  → verrou : ferme SPCM, puis lance spc_deverrouiller.jl.")
        if isempty(qcs)
            println("\nÉCHEC : aucune QC-104 vue par la DLL. Vérifie dans SPCM (fenêtre d'initialisation) ",
                    "qu'elle apparaît ; sinon : carte bien enfichée et vissée, version du TCSPC Package ",
                    "(DLL 5.0 au moins pour la QC-104, la plus récente de préférence).")
        elseif !trouvee
            println("\nÉCHEC : QC-104 vue mais pas prête. Lis son état ci-dessus : -9 = firmware ",
                    "(mise à jour dans SPCM : bouton In Use, puis OK) ; -6 = verrou ; -5 = pilote.")
        else
            println("\nRÉUSSI : la QC-104 répond. Suite : qc2_parametres.jl.")
        end
    finally
        # Arrête seulement les modules prêts et tenus par cette session ; SPC_close dans tous les cas.
        liberer_tous(isempty(a_prendre) ? modules_prets() : Int16[k for k in a_prendre if etat_init(k) == 0])
    end
    println("Colle cette sortie dans la conversation.")
    return trouvee
end

qc1()
