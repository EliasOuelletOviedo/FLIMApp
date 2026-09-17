include("DAQmxLite.jl")
using .DAQmxLite
using Printf

const CARTE   = "X6321"
const HORLOGE = "/$CARTE/ai/SampleClock"   # l'horloge maîtresse
const FS = 10_000        # Hz
const N  = 2_000         # 200 ms
const K  = 1_000         # AO 0 et P0.0 changent ensemble à l'échantillon K+1
const Z  = 100           # on termine toujours à zéro
const RETARD = 0.0       # s ; mettre 40e-6 pour le diagnostic (voir texte)

sortie_ao = vcat(zeros(K), fill(3.0, N - K - Z), zeros(Z))
sortie_do = vcat(zeros(UInt8, K), ones(UInt8, N - K - Z), zeros(UInt8, Z))

function une_passe()
    withtasks("ao", "do", "ai") do tao, tdo, tai
        add_ao_voltage(tao, "$CARTE/ao0")
        cfg_sample_clock(tao, FS; source = HORLOGE, nsamp = N)
        write_analog(tao, sortie_ao; nsamp_per_chan = N)

        add_do(tdo, "$CARTE/port0/line0:7")
        cfg_sample_clock(tdo, FS; source = HORLOGE, nsamp = N)
        write_do_u8(tdo, sortie_do)

        add_ai_voltage(tai, "$CARTE/ai0:1"; termcfg = Val_RSE)
        cfg_sample_clock(tai, FS; nsamp = N)
        if RETARD > 0
            set_ai_conv_rate(tai, 100_000)   # 10 µs entre ai0 et ai1
            set_ai_delay(tai, RETARD)        # première conversion RETARD après le front
        end
        ecart = 1 / get_ai_conv_rate(tai)

        start_task(tao)    # esclaves d'abord : ils attendent la première impulsion
        start_task(tdo)
        start_task(tai)    # maître en dernier : c'est lui qui fait partir l'horloge
        d = read_analog(tai, N, 2; timeout = 10.0)
        wait_until_done(tao)
        wait_until_done(tdo)
        return findfirst(>(1.5), d[:, 1]), findfirst(>(1.5), d[:, 2]), ecart
    end
end

println("passe   front AO   front DO   AO-DO   décalage")
for p in 1:5
    iao, ido, ecart = une_passe()
    p == 1 && @printf("(retard %.0f µs, écart entre ai0 et ai1 : %.1f µs)\n", 1e6 * RETARD, 1e6 * ecart)
    if iao === nothing || ido === nothing
        println("passe $p : front introuvable (AO 0 -> AI 0 ? P0.0 -> USER1 -> AI 1 ?)")
        continue
    end
    @printf("%4d   %8d   %8d   %5d   %+8d\n", p, iao, ido, iao - ido, iao - (K + 1))
end
