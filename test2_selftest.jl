include("DAQmxLite.jl")
using .DAQmxLite

for d in device_names()
    print("Auto-test $d ... ")
    try
        self_test(d)
        println("ok")
    catch e
        println("ÉCHEC"); showerror(stdout, e); println()
    end
    print("Remise à zéro $d ... ")
    reset_device(d); println("ok")
end
