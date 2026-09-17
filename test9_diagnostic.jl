include("DAQmxLite.jl")
using .DAQmxLite
using Printf
include("sequence.jl")

const X = "X6321"
const S = "S6110"

s = construire()
N = length(s.x)
donnees_6110 = vcat(s.p850, s.p1064)

# 1. La 6110 sait-elle générer une forme d'onde cadencée, toute seule ?
withtasks("ao_s_seule") do tas
    add_ao_voltage(tas, "$S/ao0:1")
    cfg_sample_clock(tas, FS; nsamp = N)             # horloge interne de la 6110
    write_analog(tas, donnees_6110; nsamp_per_chan = N)
    start_task(tas)
    wait_until_done(tas, 10.0)
    @printf("1. 6110 seule, horloge interne        : %5d / %d échantillons\n",
            samples_generated(tas), N)
end

# 2. Combien d'impulsions de l'horloge AI de la 6321 arrivent à la 6110 ?
withtasks("ao_s", "ai_x") do tas, tai
    add_ao_voltage(tas, "$S/ao0:1")
    cfg_sample_clock(tas, FS; source = "/$X/ai/SampleClock", nsamp = N)
    write_analog(tas, donnees_6110; nsamp_per_chan = N)
    add_ai_voltage(tai, "$X/ai2"; termcfg = Val_RSE)
    cfg_sample_clock(tai, FS; nsamp = N)
    start_task(tas)
    start_task(tai)
    read_analog(tai, N, 1; timeout = 10.0)
    sleep(0.5)
    @printf("2. horloge AI de la 6321, via RTSI    : %5d / %d échantillons\n",
            samples_generated(tas), N)
end

# 3. Et avec un train d'impulsions à 50 % produit par un compteur ?
withtasks("ao_s", "horloge") do tas, tco
    add_ao_voltage(tas, "$S/ao0:1")
    cfg_sample_clock(tas, FS; source = "/$X/Ctr0InternalOutput", nsamp = N)
    write_analog(tas, donnees_6110; nsamp_per_chan = N)
    add_co_pulse_freq(tco, "$X/ctr0", FS; duty = 0.5)
    cfg_implicit_timing(tco, Val_FiniteSamps, N)
    start_task(tas)
    start_task(tco)
    wait_until_done(tco, 10.0)
    sleep(0.5)
    @printf("3. compteur 50 %% de la 6321, via RTSI : %5d / %d échantillons\n",
            samples_generated(tas), N)
end
