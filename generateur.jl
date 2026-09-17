# generateur.jl — génération continue, un créneau à la fois (phase 7)
# À inclure après DAQmxLite.jl et sequence.jl.

using Printf

const X = "X6321"
const S = "S6110"
const HORLOGE = "/$X/Ctr0InternalOutput"

# ---- Sécurité --------------------------------------------------------
# Rien n'est écrit sans passer par ces limites. Valeurs de bouclage :
# à remplacer par celles des pilotes réels avant de brancher quoi que ce soit.
const LIMITE_GALVO = 3.0      # V, |x| et |y|
const LIMITE_P850  = 2.0      # V, commande de puissance de lecture
const LIMITE_P1064 = 2.0      # V, commande de la Pockels

"""Refuse un bloc dont les galvos sortent des limites ou contiennent NaN/Inf."""
function verifier_bloc(b)
    for (nom, v) in (("galvo X", b.x), ("galvo Y", b.y), ("P850", b.p850), ("P1064", b.p1064))
        all(isfinite, v) || error("$nom : valeur non finie, bloc refusé")
    end
    for (nom, v) in (("galvo X", b.x), ("galvo Y", b.y))
        maximum(abs, v) <= LIMITE_GALVO ||
            error(@sprintf("%s : %.3f V dépasse la limite de %.1f V, bloc refusé",
                           nom, maximum(abs, v), LIMITE_GALVO))
    end
    return b
end

"""
Remet toutes les sorties à zéro par des écritures immédiates.
Appelée si la génération s'interrompt : une tâche arrêtée garde sinon
sa dernière valeur, porte laser comprise.
"""
function mise_a_zero()
    for voies in ("$X/ao0:1", "$S/ao0:1")
        try
            withtask("zero_ao") do th
                add_ao_voltage(th, voies)
                write_analog(th, zeros(2); nsamp_per_chan = 1, autostart = true)
            end
        catch e
            @warn "Mise à zéro impossible sur $voies" exception = e
        end
    end
    try
        withtask("zero_do") do th
            add_do(th, "$X/port0/line0:7")
            write_do(th, zeros(UInt8, 8))
        end
    catch e
        @warn "Mise à zéro impossible sur le port 0" exception = e
    end
end

# ---- Moteur -----------------------------------------------------------
"""
    jouer_en_continu(R, cycles, commande; avance=3, apres_creneau=nothing)

Joue `cycles` passages sur les régions 1 à `R`, un créneau à la fois, sur
les deux cartes et l'horloge du compteur.

- `commande(k, v)` renvoie `(p850, p1064)` pour la visite `v` (0, 1, 2…)
  de la région `k`. Elle est appelée juste avant d'écrire ce créneau.
- `apres_creneau(s, bloc)` (facultatif) reçoit la relecture de chaque
  créneau dès qu'il est terminé ; c'est là que viendra la mesure.
- `avance` : nombre de créneaux écrits d'avance. Une mesure faite pendant
  une visite agit au plus tôt `cld(avance, R)` visites plus tard.

Renvoie la relecture (N × 4 : galvo X, porte 850, P850, P1064), ce qui a
été écrit, le journal des créneaux et la durée de chaque préparation.
"""
function jouer_en_continu(R::Integer, cycles::Integer, commande;
                          avance::Integer = 3, apres_creneau = nothing)
    1 <= R <= length(CENTRES) || error("R doit être entre 1 et $(length(CENTRES))")
    Ls   = longueur_creneau()
    nS   = R * cycles
    2 <= avance <= nS || error("avance doit être entre 2 et $nS")
    ent  = entree()
    queue = ne(0.2)                          # 200 ms à zéro pour finir
    sor  = sortie(queue)
    Ntot = length(ent.x) + nS * Ls + length(sor.x)
    tampon = length(ent.x) + (avance + 2) * Ls + length(sor.x)

    m = zeros(Ntot, 4)
    ecrit_x, ecrit_p1064, ecrit_d = Float64[], Float64[], UInt8[]
    journal = NamedTuple[]
    durees = Float64[]

    function preparer(s)
        k = s % R + 1
        v = s ÷ R
        p850, p1064 = commande(k, v)
        p850  = clamp(Float64(p850), 0.0, LIMITE_P850)     # saturation de la commande
        p1064 = clamp(Float64(p1064), 0.0, LIMITE_P1064)
        suivant = CENTRES[(s + 1) % R + 1]
        debut = length(ent.x) + s * Ls + 1
        push!(journal, (; creneau = s, region = k, visite = v, debut, p850, p1064))
        return verifier_bloc(creneau(k, suivant, p850, p1064; debut_sequence = (k == 1)))
    end

    try
        return withtasks("ao_x", "do_x", "ao_s", "ai_x", "horloge") do tax, tdx, tas, tai, tco
            for (th, voies) in ((tax, "$X/ao0:1"), (tas, "$S/ao0:1"))
                add_ao_voltage(th, voies)
            end
            add_do(tdx, "$X/port0/line0:7")
            for th in (tax, tdx, tas)
                cfg_sample_clock(th, FS; source = HORLOGE, mode = Val_ContSamps, nsamp = tampon)
                set_regen_mode(th, Val_DoNotAllowRegen)   # jamais rejouer d'anciennes données
                cfg_output_buffer(th, tampon)
            end
            add_ai_voltage(tai, "$X/ai0:3"; termcfg = Val_RSE)
            cfg_sample_clock(tai, FS; source = HORLOGE, mode = Val_ContSamps, nsamp = 4 * tampon)
            add_co_pulse_freq(tco, "$X/ctr0", FS; duty = 0.5)
            cfg_implicit_timing(tco, Val_ContSamps, 1000)

            function ecrire(b)
                n = length(b.x)
                write_analog(tax, vcat(b.x, b.y); nsamp_per_chan = n)
                write_do_u8(tdx, b.d)
                write_analog(tas, vcat(b.p850, b.p1064); nsamp_per_chan = n)
                append!(ecrit_x, b.x); append!(ecrit_p1064, b.p1064); append!(ecrit_d, b.d)
            end

            # pré-remplissage : entrée + `avance` créneaux, avant que l'horloge parte
            ecrire(verifier_bloc(ent))
            for s in 0:avance-1
                ecrire(preparer(s))
            end

            start_task(tax); start_task(tdx); start_task(tas); start_task(tai)   # esclaves
            start_task(tco)                                                    # l'horloge part

            pos = 0
            for s in 0:nS-1
                n = s == 0 ? length(ent.x) + Ls : Ls
                m[pos+1:pos+n, :] = read_analog(tai, n, 4; timeout = 5.0 + n / FS)
                pos += n
                apres_creneau === nothing || apres_creneau(s, view(m, pos-Ls+1:pos, :))

                t0 = time_ns()
                prochain = s + avance
                if prochain < nS
                    ecrire(preparer(prochain))
                elseif prochain == nS
                    ecrire(verifier_bloc(sor))            # retour à zéro + queue
                end
                push!(durees, (time_ns() - t0) / 1e9)
            end

            # lire le retour à zéro et la moitié de la queue, puis couper l'horloge :
            # toutes les sorties restent figées à zéro, sans vider les tampons
            n = length(sor.x) - queue ÷ 2
            m[pos+1:pos+n, :] = read_analog(tai, n, 4; timeout = 5.0 + n / FS)
            pos += n
            stop_task(tco)

            return (; mesure = m[1:pos, :], x = ecrit_x, p1064 = ecrit_p1064,
                      d = ecrit_d, journal, durees)
        end
    catch
        mise_a_zero()
        rethrow()
    end
end
