# Ce que la NI a vraiment écrit sur les lignes de routage pendant une
# session, relu par les entrées analogiques (readback.bin) : départage un
# ROUTE-0x entre la NI (le code n'est pas écrit) et le câble vers les
# cartes (il est écrit, mais n'arrive pas).
#
#     julia --project scripts/lignes_routage.jl                 # la dernière session
#     julia --project scripts/lignes_routage.jl <dossier de session> [s]
#
# Il faut P0.0 et P0.4–P0.7 relus (readback_signals line_0, line_4 … line_7
# dans config/bench.toml) et [journal] readback = true. Par défaut, les 60
# premières secondes.
using FLIMApp

cfg = FLIMApp.load_bench_config(FLIMApp.default_bench_config_path())
spc = FLIMApp.load_spc_settings(FLIMApp.spc_settings_path(cfg))
function derniere_session()
    racine = FLIMApp.sessions_root(spc)
    dossiers = isdir(racine) ? filter(d -> isfile(joinpath(d, "readback.bin")), joinpath.(racine, readdir(racine))) : String[]
    isempty(dossiers) && error("aucune session avec readback.bin dans $racine : donne le dossier")
    return last(sort(dossiers; by = mtime))
end
dossier = length(ARGS) >= 1 ? ARGS[1] : derniere_session()
max_s = length(ARGS) >= 2 ? parse(Float64, ARGS[2]) : 60.0

println("Lignes de routage relues : ", dossier)
foreach(println, FLIMApp.routing_readback_lines(FLIMApp.routing_readback(dossier; max_s)))
