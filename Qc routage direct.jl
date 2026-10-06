# qc_routage_direct.jl — affiche en continu le routage lu par la QC-104, pour câbler et tester.
#
# Il faut : laser et détecteurs allumés, un peu de lumière (le routage n'est lu
# que sur les photons). SPCM fermé. Arrêt : Ctrl+C (les cartes sont libérées).
#
# Chaque ligne résume une période (0,5 s par défaut) :
#   - routage lu par la DLL de B&H (l'arbitre) : valeur la plus fréquente, écrite
#     R3 R2 R1 R0, sa part des photons, et la part des photons où chaque bit vaut 1 ;
#   - « brut » : les mêmes photons lus directement dans les bits 12-15 des
#     enregistrements, et l'entrée d'après le bit 28. Ce n'est qu'une hypothèse
#     tirée de l'empreinte de qc4 : « ≠ DLL » signale qu'elle est fausse.
# Sur les SPC-150N, un bit vaut 1 quand son entrée est à 0 V (actif à l'état
# bas) ; une entrée en l'air se lit 0.
#
# Trois façons de tester (champ ni) :
#   :aucun  rien n'est piloté ; tu relies toi-même une broche de routage à la
#           masse (broche 5 ou 15) : son bit doit passer à 100 %.
#           Jamais de fil vers les broches 1, 6 ou 11 (alimentations).
#   :fixe   la 6321 écrit `code` sur P0.4-P0.7 (P0.4 → broche 2 = /R0 … P0.7 → broche 7 = /R3).
#   :cycle  la 6321 parcourt codes_cycle, un code toutes les pas_cycle_s secondes :
#           1, 2, 4, 8 testent chaque fil seul. La ligne dit si le routage lu est
#           le code (« direct ») ou son complément (« complément »).

Base.exit_on_sigint(false)          # Ctrl+C passe par la libération des cartes
isdefined(Main, :DAQmxLite) || include("DAQmxLite.jl")
using .DAQmxLite
isdefined(Main, :SPCLite) || include("SPCLite.jl")
using .SPCLite
(isdefined(SPCLite, :VERSION_LITE) && SPCLite.VERSION_LITE >= 9) ||
    error("Julia a gardé une ancienne version de SPCLite.jl : redémarre Julia, puis relance ce script.")
using Printf
include("reglages_qc.jl")

routage_direct = (
    ni = :aucun,                  # :aucun, :fixe ou :cycle (voir plus haut)
    carte = "Dev1",               # nom de la PCIe-6321 dans NI MAX (qc1 : Dev1)
    lignes = "port0/line4:7",
    code = 5,                     # pour ni = :fixe
    codes_cycle = [0, 1, 2, 4, 8, 15],
    pas_cycle_s = 3.0,
    periode_s = 0.5,              # une ligne affichée par période
    duree_max_s = Inf,            # Inf : jusqu'à Ctrl+C
    numero_serie = "",            # "" : la première QC-104 trouvée
)

bits4(v) = string(v; base = 2, pad = 4)

"""Résume une période : décodage par la DLL et lecture brute provisoire des bits 12-15."""
function resumer_routage(mots, n, f, fichier)
    # Arbitre : la DLL de B&H, sur un fichier .spc de cette période seule
    ecrire_spc(fichier, f.entete, mots, n)
    ent, _ = photons_dll(fichier; type_fifo = f.type_fifo, type_flux = type_flux_fichier(f.type_flux),
                         quoi = 0x01, max = 200_000)
    compte = zeros(Int, 16)
    for e in ent
        compte[Int(e.rout & 0x000f) + 1] += 1
    end
    # Hypothèse tirée de l'empreinte de qc4 : photon = bits 31 et 30 à 0,
    # routage = bits 12-15, entrée = bit 28 (0 = IN1, 1 = IN2).
    brut = zeros(Int, 16)
    par_entree = zeros(Int, 4)
    for i in 1:2:n - 1
        w = UInt32(mots[i]) | (UInt32(mots[i + 1]) << 16)
        (w >> 30) == 0 || continue
        brut[Int((w >> 12) & 0x0f) + 1] += 1
        par_entree[Int((w >> 28) & 0x03) + 1] += 1
    end
    return compte, brut, par_entree
end

function ligne_routage(t, code, compte, brut, par_entree)
    total = sum(compte)
    ecrit = code === nothing ? "  —   " : "  " * bits4(code) * "  "
    if total == 0
        @printf("%7.1f %s aucun photon décodé par la DLL (détecteurs, lumière ?) ; brut : %d photons\n",
                t, ecrit, sum(brut))
        return
    end
    lu = argmax(compte) - 1
    part = 100 * compte[lu + 1] / total
    bits = [100 * sum(compte[v + 1] for v in 0:15 if (v >> k) & 1 == 1) / total for k in 0:3]
    verdict = ""
    if code !== nothing
        verdict = part < 90 ? "  instable" :
                  lu == code ? "  direct" :
                  lu == (~code & 0x0f) ? "  complément" : "  ✗ ni l'un ni l'autre"
    end
    lu_brut = sum(brut) > 0 ? argmax(brut) - 1 : -1
    accord = lu_brut < 0 ? "" : lu_brut == lu ? "" : "  ≠ DLL"
    @printf("%7.1f %s %7d   %s  %5.1f %%   %3.0f %3.0f %3.0f %3.0f %%   | brut : IN1 %d, IN2 %d, %s%s%s\n",
            t, ecrit, total, bits4(lu), part, bits[4], bits[3], bits[2], bits[1],
            par_entree[1], par_entree[2], lu_brut < 0 ? "—" : bits4(lu_brut), accord, verdict)
end

function boucle_routage(r, m, f, fichier, th)
    tampon = zeros(UInt16, 1 << 21)
    morceau = UInt16[]
    code_ecrit = nothing
    println("      t   écrit  photons   lu (R3..R0)  part     R3  R2  R1  R0 à 1   | lecture brute provisoire")
    demarrer(m)
    t0 = time()
    try
        while time() - t0 < r.duree_max_s
            if th !== nothing
                c = r.ni == :fixe ? r.code :
                    r.codes_cycle[mod1(floor(Int, (time() - t0) / r.pas_cycle_s) + 1, length(r.codes_cycle))]
                if c != code_ecrit
                    write_do(th, UInt8[(c >> k) & 0x01 for k in 0:3])
                    code_ecrit = c
                    sleep(0.02)
                    lire_fifo!(m, tampon)                # jette ce qui précède le changement de code
                    empty!(morceau)
                end
            end
            fin = time() + r.periode_s
            while time() < fin
                n = lire_fifo!(m, tampon)
                append!(morceau, view(tampon, 1:n))
                sleep(0.01)
            end
            (etat_mesure(m) & SPC_FOVFL) != 0 && println("        FIFO débordé : baisse la lumière")
            n = length(morceau) - isodd(length(morceau))   # un mot isolé attend son partenaire
            compte, brut, par_entree = resumer_routage(morceau, n, f, fichier)
            ligne_routage(time() - t0, code_ecrit, compte, brut, par_entree)
            reste = isodd(length(morceau)) ? morceau[end] : nothing
            empty!(morceau)
            reste === nothing || push!(morceau, reste)
        end
    finally
        try; arreter(m); catch; end
    end
end

function surveiller_routage(r, reglages)
    dossier = joinpath(@__DIR__, "resultats", "qc", "routage")
    p = merge(parametres_qc(reglages), Dict{String,Any}(
        "mode" => 1, "adc_resolution" => 12, "stop_on_time" => 0, "collect_time" => 1.0,
        "macro_time_clk" => 0, "trigger" => 0, "routing_mode" => 0))   # marqueurs coupés
    ini = ecrire_ini(joinpath(dossier, "routage.ini"), p)
    fichier = joinpath(dossier, "periode.spc")
    r.ni in (:aucun, :fixe, :cycle) || error("ni : :aucun, :fixe ou :cycle")

    avec_spc_tous(ini; types = (TYPE_QC104,)) do modules
        m = modules[1]
        if !isempty(r.numero_serie)
            i = findfirst(k -> (try eeprom(k).serie catch; "" end) == r.numero_serie, modules)
            i === nothing && error("aucune QC-104 de n° de série $(r.numero_serie)")
            m = modules[i]
        end
        f = fifo_init(m)
        println("QC-104 module $m ; routage appliqué aux photons de : ",
                decrire_controle_tdc(p["tdc_control"]))
        println("Ctrl+C pour arrêter.\n")
        if r.ni == :aucun
            boucle_routage(r, m, f, fichier, nothing)
        else
            withtask("routage_direct") do th
                add_do(th, "$(r.carte)/$(r.lignes)")
                try
                    boucle_routage(r, m, f, fichier, th)
                finally
                    try; write_do(th, UInt8[0, 0, 0, 0]); catch; end
                end
            end
        end
    end
end

try
    surveiller_routage(routage_direct, REGLAGES_QC)
catch err
    err isa InterruptException || rethrow()
    println("\nArrêté ; cartes libérées.")
end
