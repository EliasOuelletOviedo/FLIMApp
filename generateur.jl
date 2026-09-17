# generateur.jl — génération continue, un créneau à la fois (phase 7)
# À inclure après DAQmxLite.jl et sequence.jl.

using Printf

const X = "X6321"
const S = "S6110"
const HORLOGE = "/$X/Ctr0InternalOutput"

# ---- Correspondance des voies ---------------------------------------
# Un seul endroit décrit tous les signaux écrits, dans l'ordre des panneaux
# des figures, et la voie AI où chacun est relu. `ai = nothing` : signal non
# relu, son panneau reste vide et marqué « non relu ». `champ` est la voie
# écrite (pour les analogiques), `bit` la ligne du port 0 (pour les numériques).
const SIGNAUX = (
    (cle = :galvo_x,    nom = "Galvo X",               sortie = "6321 AO 0", ai = 0,  champ = :x,     bit = nothing),
    (cle = :galvo_y,    nom = "Galvo Y",               sortie = "6321 AO 1", ai = 1,  champ = :y,     bit = nothing),
    (cle = :p850,       nom = "Puissance 850 nm",      sortie = "6110 AO 0", ai = 2,  champ = :p850,  bit = nothing),
    (cle = :p1064,      nom = "Pockels 1064 nm",       sortie = "6110 AO 1", ai = 3,  champ = :p1064, bit = nothing),
    (cle = :porte_850,  nom = "Porte 850 nm",          sortie = "P0.0",      ai = 4,  champ = :d,     bit = B_850),
    (cle = :porte_1064, nom = "Porte 1064 nm",         sortie = "P0.1",      ai = 5,  champ = :d,     bit = B_1064),
    (cle = :imp_seq,    nom = "Imp. séquence",         sortie = "P0.2",      ai = 6,  champ = :d,     bit = B_SEQ),
    (cle = :imp_region, nom = "Imp. région",           sortie = "P0.3",      ai = 7,  champ = :d,     bit = B_REG),
    (cle = :code_b0,    nom = "Code région · bit 0",   sortie = "P0.4",      ai = 8,  champ = :d,     bit = 4),
    (cle = :code_b1,    nom = "Code région · bit 1",   sortie = "P0.5",      ai = 9,  champ = :d,     bit = 5),
    (cle = :code_b2,    nom = "Code région · bit 2",   sortie = "P0.6",      ai = 10, champ = :d,     bit = 6),
    (cle = :code_b3,    nom = "Code région · bit 3",   sortie = "P0.7",      ai = 11, champ = :d,     bit = 7),
)

"""Voies AI à lire : chaîne DAQmx, colonne de chaque signal, nombre de voies."""
function voies_lues(signaux = SIGNAUX)
    lus = sort([s for s in signaux if s.ai !== nothing]; by = s -> s.ai)
    chaine = join(["$X/ai$(s.ai)" for s in lus], ",")
    colonne = Dict(s.cle => j for (j, s) in enumerate(lus))
    return chaine, colonne, length(lus)
end

"""Ce qui a été écrit pour un signal : volts, ou 0 et 1 pour une ligne du port 0."""
valeurs_demandees(res, s) = s.bit === nothing ? getfield(res, s.champ) :
                                                Float64.((res.d .>> s.bit) .& 0x01)

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

Renvoie la relecture `mesure` (une colonne par voie lue) avec `colonne`, qui
donne la colonne de chaque signal, la cadence de conversion `conv`, exactement
ce qui a été écrit (`x`, `y`, `p850`, `p1064`, `d`), le journal des créneaux
et la durée de chaque préparation.
"""
function jouer_en_continu(R::Integer, cycles::Integer, commande;
                          avance::Integer = 3, apres_creneau = nothing,
                          signaux = SIGNAUX)
    1 <= R <= length(CENTRES) || error("R doit être entre 1 et $(length(CENTRES))")
    Ls   = longueur_creneau()
    nS   = R * cycles
    2 <= avance <= nS || error("avance doit être entre 2 et $nS")
    voies, colonne, nv = voies_lues(signaux)
    ent  = entree()
    queue = ne(0.2)                          # 200 ms à zéro pour finir
    sor  = sortie(queue)
    Ntot = length(ent.x) + nS * Ls + length(sor.x)
    tampon = length(ent.x) + (avance + 2) * Ls + length(sor.x)

    m = zeros(Ntot, nv)
    ecrit = (x = Float64[], y = Float64[], p850 = Float64[], p1064 = Float64[], d = UInt8[])
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
            add_ai_voltage(tai, voies; termcfg = Val_RSE)      # toutes les voies, dans l'ordre des panneaux
            cfg_sample_clock(tai, FS; source = HORLOGE, mode = Val_ContSamps, nsamp = 4 * tampon)
            add_co_pulse_freq(tco, "$X/ctr0", FS; duty = 0.5)
            cfg_implicit_timing(tco, Val_ContSamps, 1000)

            function ecrire(b)
                nb = length(b.x)
                write_analog(tax, vcat(b.x, b.y); nsamp_per_chan = nb)
                write_do_u8(tdx, b.d)
                write_analog(tas, vcat(b.p850, b.p1064); nsamp_per_chan = nb)
                for champ in (:x, :y, :p850, :p1064, :d)          # garder exactement ce qui a été écrit
                    append!(getfield(ecrit, champ), getfield(b, champ))
                end
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
                m[pos+1:pos+n, :] = read_analog(tai, n, nv; timeout = 5.0 + n / FS)
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
            m[pos+1:pos+n, :] = read_analog(tai, n, nv; timeout = 5.0 + n / FS)
            pos += n
            conv = get_ai_conv_rate(tai)        # avant de fermer la tâche
            stop_task(tco)

            return (; mesure = m[1:pos, :], colonne, conv, signaux,
                      ecrit.x, ecrit.y, ecrit.p850, ecrit.p1064, ecrit.d,
                      journal, durees)
        end
    catch
        mise_a_zero()
        rethrow()
    end
end
