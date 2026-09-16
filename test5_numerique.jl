include("DAQmxLite.jl")
using .DAQmxLite

const CARTE = "X6321"

withtask("do") do th
    add_do(th, "$CARTE/port0/line0")
    for i in 1:10
        etat = UInt8(i % 2)
        write_do(th, [etat])
        println("P0.0 = $etat   (attendu : ", etat == 1 ? "~5 V" : "~0 V", ")")
        sleep(0.5)
    end
    write_do(th, [UInt8(0)])
end
