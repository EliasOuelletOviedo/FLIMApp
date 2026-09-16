include("DAQmxLite.jl")
using .DAQmxLite
using Printf, Statistics

const CARTE = "X6321"

consignes = -5.0:1.0:5.0
mesures   = Float64[]

println(" consigne    mesure     écart")
for v in consignes
    th = ao_hold("$CARTE/ao0", [v])
    sleep(0.05)                                    # laisse la sortie s'établir
    m = mean(ai_block("$CARTE/ai0", 1, 10_000, 200;
                      termcfg = Val_RSE)[:, 1])    # moyenne sur 200 points
    clear_task(th)
    push!(mesures, m)
    @printf("%8.3f  %8.4f  %+8.4f\n", v, m, m - v)
end

ecart = maximum(abs.(mesures .- collect(consignes)))
@printf("\nÉcart maximal : %.4f V\n", ecart)
println(ecart < 0.05 ? "Bouclage validé." :
        "Écart trop grand — vérifie SE/RSE et le câble BNC.")
