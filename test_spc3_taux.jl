# test_spc3_taux.jl — compteurs de taux et état du SYNC, pendant 6 s.
#
# Branchements : aucun n'est obligatoire. Pour un vrai contrôle, branche
# comme avec SPCM : SYNC ← sortie de référence du laser, CFD ← détecteur.
# SPCM fermé. Les seuils viennent de reglages_spc.jl.
#
# Réussi si : les compteurs se lisent. Sans rien de branché, tout vaut 0 et
# le SYNC est absent : c'est normal, la communication est quand même prouvée.
# Avec le laser : SYNC proche de sa fréquence (ou divisée par sync_freq_div).
# Avec le détecteur sous tension : CFD > 0 (bruit d'obscurité au minimum).

isdefined(Main, :SPCLite) || include("SPCLite.jl")
using .SPCLite
using Printf
include("reglages_spc.jl")

spc3 = (module_no = 0, duree_s = 6.0, periode_s = 0.3)

function test_spc3(r, reglages)
    dossier = joinpath(@__DIR__, "resultats", "spc")
    p = merge(reglages, Dict{String,Any}("rate_count_time" => 0.25))
    ini = ecrire_ini(joinpath(dossier, "t3_taux.ini"), p)
    avec_spc(ini; module_no = r.module_no) do m
        effacer_taux(m)
        @printf("%7s %12s %12s %12s %12s   %s\n", "t (s)", "SYNC (/s)", "CFD (/s)",
                "TAC (/s)", "ADC (/s)", "état du SYNC")
        lectures = 0
        dernier_code = 0
        t0 = time()
        while time() - t0 < r.duree_s
            sleep(r.periode_s)
            v = taux(m)
            s = sync_etat(m)
            if v.code == 0
                lectures += 1
                @printf("%7.1f %12.4g %12.4g %12.4g %12.4g   %s\n", time() - t0, v.sync, v.cfd,
                        v.tac, v.adc, get(MESSAGES_SYNC, s, string(s)))
            else
                dernier_code = v.code
            end
        end
        ok = lectures > 0
        println()
        println(ok ? "RÉUSSI : $lectures lectures des compteurs." :
                     "ÉCHEC : aucune lecture ($dernier_code : $(message_erreur(dernier_code))).")
        return ok
    end
end

test_spc3(spc3, REGLAGES_SPC)
