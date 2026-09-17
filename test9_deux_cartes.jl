include("DAQmxLite.jl")
using .DAQmxLite
using Printf, Statistics
include("sequence.jl")
include("verif.jl")

const X = "X6321"
const S = "S6110"
# Un train d'impulsions carré produit par le compteur 0 de la 6321 sert
# d'horloge à toutes les tâches, sur les deux cartes. Ses impulsions de
# 50 µs sont détectées sans ambiguïté par la 6110, qui exige au moins 10 ns.
const HORLOGE = "/$X/Ctr0InternalOutput"

function jouer_deux_cartes(s)
    N = length(s.x)
    withtasks("ao_x", "do_x", "ao_s", "ai_x", "horloge") do tax, tdx, tas, tai, tco
        # 6321 : galvos et port 0
        add_ao_voltage(tax, "$X/ao0:1")
        cfg_sample_clock(tax, FS; source = HORLOGE, nsamp = N)
        write_analog(tax, vcat(s.x, s.y); nsamp_per_chan = N)

        add_do(tdx, "$X/port0/line0:7")
        cfg_sample_clock(tdx, FS; source = HORLOGE, nsamp = N)
        write_do_u8(tdx, s.d)

        # 6110 : puissances laser, même horloge, transmise par le câble RTSI
        add_ao_voltage(tas, "$S/ao0:1")
        cfg_sample_clock(tas, FS; source = HORLOGE, nsamp = N)
        write_analog(tas, vcat(s.p850, s.p1064); nsamp_per_chan = N)

        # 6321 : relecture des trois signaux, elle aussi esclave de l'horloge
        add_ai_voltage(tai, "$X/ai0:2"; termcfg = Val_RSE)
        cfg_sample_clock(tai, FS; source = HORLOGE, nsamp = N)

        # l'horloge elle-même : N impulsions, puis retour au repos
        add_co_pulse_freq(tco, "$X/ctr0", FS; duty = 0.5)
        cfg_implicit_timing(tco, Val_FiniteSamps, N)

        start_task(tax); start_task(tdx); start_task(tas); start_task(tai)  # esclaves
        start_task(tco)                                                    # l'horloge part
        m = read_analog(tai, N, 3; timeout = 10.0 + N / FS)
        wait_until_done(tax); wait_until_done(tdx); wait_until_done(tas)
        return m
    end
end

function verifier(s, essai)
    m = jouer_deux_cartes(s)

    o_galvo, err_galvo = meilleur_decalage(s.x, m[:, 1])
    dec_porte = decalages_fronts(m[:, 2], 1.5, s.debuts, s.nl)
    dec_p850  = decalages_fronts(m[:, 3], 0.4, s.debuts, s.nl)

    println("\n=== essai $essai ===")
    @printf("Galvo X       (6321 AO 0) : décalage %d, erreur max %.1f mV\n", o_galvo, 1000 * err_galvo)
    println("Porte 850     (6321 P0.0) : ", dec_porte)
    println("Puissance 850 (6110 AO 0) : ", dec_p850)

    if stable(dec_p850)
        o = dec_p850[1]
        for (k, deb) in enumerate(s.debuts)
            plateau = m[deb + o + 10 : deb + o + s.nl - 10, 3]
            @printf("  région %d : programmé %.3f V, mesuré %.3f V\n", k, P850[k], mean(plateau))
        end
    end

    if stable(dec_porte) && stable(dec_p850) && err_galvo < 0.05
        println("Synchronisé : chaque signal a un décalage fixe sur tous ses fronts.")
        println("Écart puissance 6110 - porte 6321 : ", dec_p850[1] - dec_porte[1], " échantillon(s)")
    else
        println("Échec : voir les décalages ci-dessus.")
    end
end

s = construire()
for essai in 1:3
    verifier(s, essai)
end
