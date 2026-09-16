include("DAQmxLite.jl")
using .DAQmxLite

const CARTE = "X6321"

reset_device(CARTE)

for v in (0.0, 1.0, 2.5, 5.0, -2.5, 0.0)
    th = ao_hold("$CARTE/ao0", [v])
    println("ao0 = $v V  —  mesure au multimètre, puis Entrée")
    readline()
    clear_task(th)
    println("   tâche libérée — relis le multimètre : la tension tient-elle ?")
    readline()
end
