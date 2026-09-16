include("DAQmxLite.jl")
using .DAQmxLite
using Printf

maj, mnr, upd = driver_version()
@printf("Pilote NI-DAQmx : %d.%d.%d\n\n", maj, mnr, upd)

devs = device_names()
isempty(devs) && error("Aucune carte vue par le pilote. Retourne dans NI MAX.")

for d in devs
    @printf("%-10s  %s  (s/n %d)\n", d, product_type(d), serial_number(d))
    println("   AI : ", join(ai_channels(d), " "))
    println("   AO : ", join(ao_channels(d), " "))
    println("   DO : ", join(do_lines(d), " "))
    println()
end
