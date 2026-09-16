include("DAQmxLite.jl")
using .DAQmxLite
using Printf, Statistics

const CARTE = "X6321"
const FS    = 20_000        # Hz
const N     = 2_000         # échantillons → 100 ms
const F0    = 50.0          # Hz, fréquence de la sinusoïde

t     = (0:N-1) ./ FS
sortie = 4.0 .* sin.(2π * F0 .* t)

# --- sortie cadencée matériellement, non démarrée -------------------
th_ao = create_task("ao_wave")
add_ao_voltage(th_ao, "$CARTE/ao0")
cfg_sample_clock(th_ao, FS; mode = Val_FiniteSamps, nsamp = N)
write_analog(th_ao, collect(sortie); nsamp_per_chan = N, autostart = false)

try
    start_task(th_ao)
    entree = ai_block("$CARTE/ai0", 1, FS, N; termcfg = Val_RSE)[:, 1]

    @printf("sortie : min %+.3f  max %+.3f  rms %.3f\n",
            minimum(sortie), maximum(sortie), sqrt(mean(sortie .^ 2)))
    @printf("entrée : min %+.3f  max %+.3f  rms %.3f\n",
            minimum(entree), maximum(entree), sqrt(mean(entree .^ 2)))

    # Corrélation entre les deux, tolérante à un décalage de phase :
    # les deux tâches ne partagent pas encore de déclencheur commun.
    r = cor(sortie[1:length(entree)], entree)
    @printf("\ncorrélation : %.3f\n", r)
    println(abs(r) > 0.9 ? "Horloge matérielle validée." :
            "Faible corrélation — normal sans déclencheur partagé ; " *
            "compare plutôt les rms ci-dessus.")
finally
    clear_task(th_ao)
end
