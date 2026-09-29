# histogrammes_single.jl — déclins en mode « Single » : l'histogramme se
# construit dans la mémoire de la carte.
#
# C'est le mode Single de SPCM (mode 0 de la DLL, « normal ») : pendant le
# temps de collecte, chaque SPC-150N choisie range elle-même ses photons
# dans une courbe de 2^resolution_adc canaux. Pour chaque histogramme, le
# script efface la mémoire, lance toutes les cartes choisies en même temps,
# attend qu'elles s'arrêtent seules à la fin du temps de collecte, puis
# relit les courbes (séquence du manuel de la DLL). Ni marqueur ni routage :
# tous les photons d'une carte vont dans une seule courbe.
#
# Sorties, dans resultats/single, pour chaque carte :
#   *_module<m>.csv             une ligne par canal : canal, temps_ns (centre
#                               du canal), h1 … hN, somme. Les lignes « # » du
#                               début donnent les réglages et la fin de chaque
#                               mesure (en Julia : CSV.File(f; comment = "#")) ;
#   *_module<m>.svg             les N histogrammes (gris) et leur somme (bleu), en log ;
#   *_module<m>_parametres.ini  tous les paramètres relus dans la carte.
#
# Avant : SPCM fermé ; logiciel DCC ouvert, détecteur allumé ; laser allumé.
# Le scanner peut tourner ou non. Réglages du détecteur et du TAC :
# reglages_spc.jl, les mêmes que pour l'imagerie.
#
# Sens du temps : dans la mémoire de la carte, le temps croît avec le numéro
# de canal, comme dans SPCM. Si le déclin sort à l'envers (montée lente,
# chute brutale), mets inverser = true et signale-le-moi.

isdefined(Main, :SPCLite) || include("SPCLite.jl")
using .SPCLite
using Printf, Dates
include("reglages_spc.jl")

single_reglages = (
    modules = [0, 1],            # cartes mesurées en même temps
    temps_collecte_s = 1.0,      # durée de chaque histogramme
    n_histogrammes = 5,          # histogrammes successifs, chacun repart de zéro
    resolution_adc = 12,         # 12 bits = 4096 canaux ; ou 10, 8, 6
    arret_debordement = true,    # arrêt dès qu'un canal atteint 65535 coups
    inverser = false,            # voir « Sens du temps » plus haut
)

# ---------------------------------------------------------------------
# Mesure
# ---------------------------------------------------------------------

"""
Attend que chaque module se soit arrêté seul (bit SPC_ARMED à 0). Renvoie,
par module, l'état final (bits de SPC_test_state) et la durée écoulée.
Pendant les 50 premières ms, un module désarmé sans raison d'arrêt est
considéré comme pas encore armé.
"""
function attendre_fin_single(modules, delai_s)
    fin = Dict{Int16,Tuple{UInt16,Float64}}()
    raisons = SPC_OVERFL | SPC_TIME_OVER | SPC_COLTIM_OVER | SPC_CMD_STOP
    t0 = time()
    while true
        for m in modules
            haskey(fin, m) && continue
            s = etat_mesure(m)
            fini = (s & SPC_ARMED) == 0 && ((s & raisons) != 0 || time() - t0 > 0.05)
            fini && (fin[m] = (s, time() - t0))
        end
        length(fin) == length(modules) && return fin
        if time() - t0 > delai_s
            restants = [Int(m) for m in modules if !haskey(fin, m)]
            error("mesure encore en cours après $(round(delai_s; digits = 1)) s " *
                  "sur le(s) module(s) $restants")
        end
        sleep(0.005)
    end
end

"""Pourquoi la mesure s'est arrêtée, d'après les bits de SPC_test_state."""
function texte_fin_single(etat::UInt16)
    (etat & SPC_OVERFL) != 0 &&
        return "ARRÊT SUR DÉBORDEMENT : un canal a atteint 65535 coups, mesure écourtée"
    (etat & SPC_OVERFLOW) != 0 && return "DÉBORDEMENT : des canaux sont saturés à 65535"
    (etat & (SPC_TIME_OVER | SPC_COLTIM_OVER)) != 0 && return "temps écoulé"
    (etat & SPC_CMD_STOP) != 0 && return "arrêtée par le logiciel"
    return @sprintf("fin inattendue (état 0x%04X)", etat)
end

"""Une ligne par module et par mesure : coups, pic, temps moyen, fin."""
function resume_single(m, h, dt_ns, etat, duree)
    total = sum(Int, h)
    pic, k = findmax(h)
    tmoy = total > 0 ? sum((i - 0.5) * dt_ns * h[i] for i in eachindex(h)) / total : NaN
    @printf("  module %d : %d coups en %.2f s (%.3g /s) ; pic %d coups à %.3f ns ; temps moyen %.3f ns ; %s\n",
            m, total, duree, total / max(duree, 1e-3), pic, (k - 0.5) * dt_ns, tmoy,
            texte_fin_single(etat))
end

# ---------------------------------------------------------------------
# Fichiers
# ---------------------------------------------------------------------

function ecrire_csv_single(chemin, H::Matrix{UInt16}, dt_ns, entete)
    n, N = size(H)
    open(chemin, "w") do io
        for l in entete
            println(io, "# ", l)
        end
        println(io, "canal,temps_ns,", join(("h$i" for i in 1:N), ","), ",somme")
        for k in 1:n
            @printf(io, "%d,%.5f", k - 1, (k - 0.5) * dt_ns)
            s = 0
            for i in 1:N
                print(io, ",", H[k, i])
                s += Int(H[k, i])
            end
            println(io, ",", s)
        end
    end
    return chemin
end

function svg_histo_single(chemin, dt_ns, H::Matrix{UInt16}, titre)
    n, N = size(H)
    somme = vec(sum(Int.(H); dims = 2))
    L, Hs = 760, 440                              # largeur, hauteur
    mg, md, mh, mb = 80, 24, 56, 56               # marges gauche, droite, haut, bas
    lx, ly = L - mg - md, Hs - mh - mb
    xmax = n * dt_ns
    ymax = max(1.0, ceil(log10(maximum(somme) + 1)))
    X(t) = mg + lx * t / xmax
    Y(c) = mh + ly * (1 - log10(c + 1) / ymax)
    pas = xmax / 8
    for q in (0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 20, 50, 100, 200, 500, 1000)
        xmax / q <= 8 && (pas = q; break)
    end
    trace(c) = join((@sprintf("%.1f,%.1f", X((k - 0.5) * dt_ns), Y(c[k])) for k in 1:n), " ")
    open(chemin, "w") do io
        println(io, """<svg xmlns="http://www.w3.org/2000/svg" width="$L" height="$Hs" font-family="sans-serif" font-size="12">""")
        println(io, """<rect width="$L" height="$Hs" fill="white"/>""")
        # 20 courbes grises au plus, réparties sur la série, pour garder un SVG léger
        choisis = N > 1 ? unique(round.(Int, range(1, N; length = min(N, 20)))) : Int[]
        legende = length(choisis) == N ? "gris : chaque histogramme" :
                  "gris : $(length(choisis)) des $N histogrammes"
        println(io, """<text x="$mg" y="24" font-size="15">$titre</text>""")
        N > 1 && println(io, """<text x="$mg" y="42" fill="#4b5563">$legende ; bleu : somme</text>""")
        @printf(io, "<line x1=\"%d\" y1=\"%d\" x2=\"%d\" y2=\"%d\" stroke=\"black\"/>\n", mg, mh + ly, mg + lx, mh + ly)
        @printf(io, "<line x1=\"%d\" y1=\"%d\" x2=\"%d\" y2=\"%d\" stroke=\"black\"/>\n", mg, mh, mg, mh + ly)
        for t in 0:pas:xmax
            @printf(io, "<line x1=\"%.1f\" y1=\"%d\" x2=\"%.1f\" y2=\"%d\" stroke=\"black\"/>\n", X(t), mh + ly, X(t), mh + ly + 5)
            @printf(io, "<text x=\"%.1f\" y=\"%d\" text-anchor=\"middle\">%g</text>\n", X(t), mh + ly + 19, t)
        end
        for k in 0:Int(ymax)
            y = mh + ly * (1 - k / ymax)
            @printf(io, "<line x1=\"%d\" y1=\"%.1f\" x2=\"%d\" y2=\"%.1f\" stroke=\"#ddd\"/>\n", mg, y, mg + lx, y)
            @printf(io, "<text x=\"%d\" y=\"%.1f\" text-anchor=\"end\">1e%d</text>\n", mg - 8, y + 4, k)
        end
        @printf(io, "<text x=\"%.1f\" y=\"%d\" text-anchor=\"middle\">temps (ns)</text>\n", mg + lx / 2, Hs - 14)
        for i in choisis
            println(io, """<polyline fill="none" stroke="#9ca3af" stroke-width="0.8" points="$(trace(view(H, :, i)))"/>""")
        end
        println(io, """<polyline fill="none" stroke="#1d4ed8" stroke-width="1.2" points="$(trace(somme))"/>""")
        println(io, "</svg>")
    end
    return chemin
end

# ---------------------------------------------------------------------
# Programme
# ---------------------------------------------------------------------

function histogrammes_single(r, reglages)
    r.resolution_adc in (6, 8, 10, 12) || error("resolution_adc : 6, 8, 10 ou 12 bits")
    r.n_histogrammes >= 1 || error("n_histogrammes : au moins 1")
    N = r.n_histogrammes
    dossier = joinpath(@__DIR__, "resultats", "single")
    mkpath(dossier)
    p = merge(reglages, Dict{String,Any}(
        "mode" => 0,                                     # histogramme dans la carte
        "adc_resolution" => r.resolution_adc,
        "collect_time" => r.temps_collecte_s,
        "stop_on_time" => 1,                             # la carte s'arrête seule
        "stop_on_ovfl" => r.arret_debordement ? 1 : 0,
        "dead_time_comp" => get(reglages, "dead_time_comp", 1)))
    ini = ecrire_ini(joinpath(dossier, "single.ini"), p)
    debut = now()

    mes = avec_spc_tous(ini) do prets
        modules = Int16[m for m in r.modules if m in prets]
        isempty(modules) && error("aucune des cartes $(r.modules) n'est prête (prêtes : $(Int.(prets)))")
        n = Dict{Int16,Int}()
        fenetre = Dict{Int16,Float64}()
        serie = Dict{Int16,String}()
        lus = Dict{Int16,Dict{String,Float64}}()
        for m in modules
            s = sync_etat(m)
            s == 1 || @warn "module $m : $(get(MESSAGES_SYNC, s, string(s))) ; sans SYNC, aucun photon n'est compté"
            mem = configurer_memoire(m, r.resolution_adc, 0)
            mem.longueur_bloc > 0 || error("module $m : mémoire mal configurée ($mem)")
            n[m] = mem.longueur_bloc
            lus[m] = lire_parametres(m; fichier = joinpath(dossier, "relu_$(m).ini"))
            fenetre[m] = get(lus[m], "tac_range", Float64(get(reglages, "tac_range", 50.0))) /
                         get(lus[m], "tac_gain", Float64(get(reglages, "tac_gain", 1)))
            serie[m] = try
                eeprom(m).serie
            catch
                "?"
            end
        end
        H = Dict(m => zeros(UInt16, n[m], N) for m in modules)
        etats = Dict(m => zeros(UInt16, N) for m in modules)
        durees = Dict(m => zeros(N) for m in modules)
        delai = 4 * r.temps_collecte_s + 5               # le temps mort allonge la mesure
        println("$N histogramme(s) de $(r.temps_collecte_s) s sur les modules $(Int.(modules))")
        for i in 1:N
            for m in modules
                definir_page(m, 0)
                effacer_memoire(m; bloc = -1, page = 0)
            end
            foreach(demarrer, modules)
            fin = attendre_fin_single(modules, delai)
            afficher = N <= 20 || i % cld(N, 20) == 0 || i == N     # 20 résumés au plus
            afficher && println("Mesure $i/$N")
            for m in modules
                h = lire_bloc(m, n[m]; bloc = 0, page = 0)
                H[m][:, i] = r.inverser ? reverse(h) : h
                etats[m][i], durees[m][i] = fin[m]
                afficher && resume_single(m, view(H[m], :, i), fenetre[m] / n[m], etats[m][i], durees[m][i])
            end
        end
        return (modules = modules, H = H, etats = etats, durees = durees,
                fenetre = fenetre, n = n, serie = serie, lus = lus)
    end

    # Les cartes sont libérées : écriture des fichiers
    horodatage = Dates.format(debut, "yyyymmdd_HHMMSS")
    println()
    for m in mes.modules
        prefixe = joinpath(dossier, "$(horodatage)_module$(m)")
        dt_ns = mes.fenetre[m] / mes.n[m]
        releve = joinpath(dossier, "relu_$(m).ini")
        isfile(releve) && cp(releve, prefixe * "_parametres.ini"; force = true)
        valeur = k -> haskey(mes.lus[m], k) ? @sprintf("%g", mes.lus[m][k]) : string(p[k])
        entete = String[
            "histogrammes_single.jl, $(Dates.format(debut, "yyyy-mm-dd HH:MM:SS"))",
            "module $m, SPC-150N n° de série $(mes.serie[m])",
            @sprintf("fenêtre TAC %.4f ns, %d canaux de %.4f ps ; temps_ns = centre du canal",
                     mes.fenetre[m], mes.n[m], dt_ns * 1e3),
            "$N histogramme(s) de $(r.temps_collecte_s) s, chacun repart de zéro" *
                (r.inverser ? " ; courbes inversées (inverser = true)" : ""),
            "paramètres relus : " * join(("$k = $(valeur(k))" for k in sort!(collect(keys(p)))), ", "),
        ]
        for i in 1:N
            push!(entete, @sprintf("h%d : %.2f s, %s", i, mes.durees[m][i],
                                   texte_fin_single(mes.etats[m][i])))
        end
        ecrire_csv_single(prefixe * ".csv", mes.H[m], dt_ns, entete)
        svg_histo_single(prefixe * ".svg", dt_ns, mes.H[m],
                         "Module $m : $N × $(r.temps_collecte_s) s, $(sum(Int, mes.H[m])) coups au total")
        println("Module $m : ", prefixe, ".csv, .svg et _parametres.ini")
    end
    return mes
end

histogrammes_single(single_reglages, REGLAGES_SPC)
