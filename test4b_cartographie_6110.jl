include("DAQmxLite.jl")
using .DAQmxLite
using Printf, Statistics

const CARTE = "S6110"
const CIBLE = 4.0          # tension injectée, bien au-dessus du bruit

println("Branche AO 0 sur UN connecteur d'entrée du boîtier, puis Entrée.")
println("Note lequel physiquement — c'est ça qu'on cherche à identifier.\n")
readline()

th = ao_hold("$CARTE/ao0", [CIBLE])
sleep(0.1)

# Couplage DC forcé : la 6110 accepte AC ou DC par voie, et en AC
# une tension continue est purement et simplement supprimée.
d = ai_block("$CARTE/ai0:3", 4, 100_000, 1000;
             coupling = Val_DC, termcfg = Val_Diff)
clear_task(th)

println("voie    moyenne     écart-type")
for k in 1:4
    @printf("ai%d  %9.4f  %10.5f\n", k - 1, mean(d[:, k]), std(d[:, k]))
end

actives = findall(k -> abs(mean(d[:, k]) - CIBLE) < 0.3, 1:4)
if length(actives) == 1
    @printf("\nCe connecteur correspond à %s/ai%d\n", CARTE, actives[1] - 1)
elseif isempty(actives)
    println("\nAucune voie ne voit les $CIBLE V.")
    println("Causes probables, dans l'ordre : câble BNC, couplage AC resté actif,")
    println("ou ce connecteur n'est simplement pas relié sur le brochage S Series.")
else
    println("\nPlusieurs voies réagissent — vérifie les interrupteurs SE/DIFF.")
end
