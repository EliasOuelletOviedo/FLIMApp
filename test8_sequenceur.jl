include("DAQmxLite.jl")
using .DAQmxLite
using Printf
include("sequence.jl")
include("verif.jl")

const CARTE   = "X6321"
const HORLOGE = "/$CARTE/ai/SampleClock"

function jouer(s)
    N = length(s.x)
    withtasks("ao", "do", "ai") do tao, tdo, tai
        add_ao_voltage(tao, "$CARTE/ao0:1")
        cfg_sample_clock(tao, FS; source = HORLOGE, nsamp = N)
        write_analog(tao, vcat(s.x, s.y); nsamp_per_chan = N)   # voie par voie

        add_do(tdo, "$CARTE/port0/line0:7")
        cfg_sample_clock(tdo, FS; source = HORLOGE, nsamp = N)
        write_do_u8(tdo, s.d)

        add_ai_voltage(tai, "$CARTE/ai0:1"; termcfg = Val_RSE)
        cfg_sample_clock(tai, FS; nsamp = N)
        @printf("Cadence retenue par la carte : %.1f Hz\n", get_samp_clk_rate(tai))

        start_task(tao); start_task(tdo)
        start_task(tai)
        m = read_analog(tai, N, 2; timeout = 10.0 + N / FS)
        wait_until_done(tao); wait_until_done(tdo)
        return m
    end
end

s = construire()
@printf("Séquence : %d échantillons, %.0f ms, %d régions\n",
        length(s.x), 1000 * length(s.x) / FS, length(CENTRES))
m = jouer(s)

o_galvo, err_galvo = meilleur_decalage(s.x, m[:, 1])
dec_porte = decalages_fronts(m[:, 2], 1.5, s.debuts, s.nl)
@printf("\nGalvo X   (AO 0 -> AI 0) : décalage %d, erreur max %.1f mV\n", o_galvo, 1000 * err_galvo)
println("Porte 850 (P0.0 -> AI 1) : décalages des fronts ", dec_porte)

if stable(dec_porte) && err_galvo < 0.05
    println("Séquenceur validé : les ", length(dec_porte), " fronts de la porte ont le même décalage.")
    println("Écart galvo - porte : ", o_galvo - dec_porte[1],
            " échantillon (comparer au AO-DO du test 7).")
else
    println("Échec : fronts manquants, décalages variables, ou erreur galvo > 50 mV.")
end

# Optionnel, tracé dans le terminal (] add UnicodePlots) :
# using UnicodePlots
# t = (0:length(s.x)-1) ./ FS
# g = lineplot(t, s.x; name = "consigne galvo X", xlabel = "s", width = 100, height = 20)
# lineplot!(g, t, m[:, 1]; name = "relecture AI 0")
# lineplot!(g, t, m[:, 2] ./ 2; name = "porte 850 (÷2)")
# display(g)
