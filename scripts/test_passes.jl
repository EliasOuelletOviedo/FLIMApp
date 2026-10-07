# test_passes.jl — le signal de passe et le code de routage, de la NI aux
# cartes SPC, avec le code de l'app mais sans le GUI : pour départager un
# PASS-0x ou un ROUTE-0x (DEBUGGING.md).
#
#     julia --project -t 4 scripts/test_passes.jl                  # 5 s, code 5
#     julia --project -t 4 scripts/test_passes.jl 10 --code 3
#     julia --project -t 4 scripts/test_passes.jl --borne /X6321/PFI12
#     julia --project -t 4 scripts/test_passes.jl --sans-ni         # signal venu d'ailleurs
#
# Ce qu'il fait, comme un START du Realtime :
#   1. la carte SPC en Realtime (FIFO), mais avec les QUATRE marqueurs
#      enregistrés (M0–M3) : on voit sur quelle entrée le signal arrive ; la
#      fin des passes comme dans l'app ([clamp] fin_par_m3). Avec la QC-104,
#      une ligne par canal (une entrée de la carte : 3T0089/IN1, 3T0089/IN2) ;
#      les marqueurs et le routage sont communs aux deux ;
#   2. la NI écrit un code de routage fixe sur P0.4–P0.7 (`--code`, 1 à 15,
#      inversé selon inverser_routage) — sans allumer les lasers, sauf avec
#      `--laser` (P0.0 et P0.1 hauts) ;
#   3. l'horloge d'échantillonnage (ctr0) et le compteur de passes (ctr1 →
#      PFI13, ou `--borne`), créés par les mêmes fonctions que l'app, haut
#      `--scan-ms` (950) et bas `--pause-ms` (50).
# Chaque seconde, pour chaque carte : fronts M0–M3, passes, durées, photons
# par code ; à la fin, une conclusion par carte et le diagnostic de l'app.
#
# Avant : le GUI fermé (il tient la NI et les cartes), SPCM fermé. Les
# photons ne sont pas nécessaires pour les marqueurs ; pour le routage, il
# en faut quelques-uns pendant les passes (le bruit des détecteurs suffit).
# SPC_REGLAGES=<fichier> : d'autres réglages SPC (une copie en simulation
# avec --sans-ni pour l'essayer sans le banc).
#
# Câblage de la QC-104 (Micro Sub-D 15) : PFI13 → broche 12 (M0) et broche 10
# (M3) ; P0.4, P0.5, P0.6, P0.7 → broches 2, 3, 4, 7 (/R0 à /R3) ; D GND →
# broche 5 ou 15 ; rien sur 1, 6, 11.

using FLIMApp
using Printf
const F = FLIMApp
const C = FLIMApp.FLIMCore

# --- Options -----------------------------------------------------------------
function option(nom, defaut)
    k = findfirst(==(nom), ARGS)
    return k === nothing || k == length(ARGS) ? defaut : ARGS[k + 1]
end
drapeau(nom) = nom in ARGS
duree_s = something(tryparse(Float64, isempty(ARGS) || startswith(ARGS[1], "--") ? "" : ARGS[1]), 5.0)
code = parse(Int, option("--code", "5"))
1 <= code <= 15 || error("--code : de 1 à 15 (0 est le code réservé)")
scan_ms = parse(Float64, option("--scan-ms", "950"))
pause_ms = parse(Float64, option("--pause-ms", "50"))
sans_ni = drapeau("--sans-ni")
laser = drapeau("--laser")

cfg = F.load_bench_config(F.default_bench_config_path())
spc = F.load_spc_settings(get(ENV, "SPC_REGLAGES", F.spc_settings_path(cfg)))
borne = option("--borne", cfg.pass_terminal)
rate = cfg.sample_rate_hz
scan, pause = F.samples_of(scan_ms, rate), F.samples_of(pause_ms, rate)
periode_s = (scan + pause) / rate
octet = F.routing_byte(code, spc.inverser_routage) | (laser ? F.do_bit(F.DO_BIT_GATE) | F.do_bit(F.DO_BIT_ENABLE) : 0x00)

println("Test du signal de passe et du routage, $(duree_s) s")
println("  NI : ", sans_ni ? "rien (signal venu d'ailleurs)" :
        "horloge $(cfg.counter) à $(rate) Hz ; passes $(cfg.pass_counter) → $(F.pass_terminal_text(borne)), " *
        "haut $scan éch. ($(scan_ms) ms), bas $pause éch. ($(pause_ms) ms) ; " *
        "port 0 = 0x$(string(octet; base = 16, pad = 2)) (code $code écrit $(spc.inverser_routage ? "inversé" : "tel quel")" *
        (laser ? ", lasers allumés)" : ", lasers éteints)"))
println("  cartes : $(spc.source), séries $(spc.series) ; marqueurs M0–M3 tous enregistrés ; fin des passes : ",
        spc.fin_par_m3 ? "M3" : "M0 + durée du scan (M0 seul)", "\n")

# --- Lignes de compte rendu -----------------------------------------------------
ms(s) = isfinite(s) ? @sprintf("%.3f", 1000s) : "—"
function ligne_carte(c)
    codes = join(["$(k - 1):$n" for (k, n) in enumerate(c.photons_par_code) if n > 0], " ")
    temps = spc.fin_par_m3 ? @sprintf("M3−M0 %s…%s ms", ms(c.duree_min_s), ms(c.duree_max_s)) :
            @sprintf("M0→M0 %s…%s ms (M0 manquants %d, hors cadence %d)", ms(c.intervalle_min_s), ms(c.intervalle_max_s),
                     c.m0_manquants, c.hors_duree)
    return @sprintf("  module %d (canal %d %s) : M0 %d  M1 %d  M2 %d  M3 %d ; passes %d (abandonnées %d) ; %s ; photons %d ; codes en passe %s",
                    c.carte, c.canal, c.serie, c.marqueurs..., c.passes, c.abandonnees, temps,
                    c.photons, isempty(codes) ? "—" : codes)
end

function conclusion(c, attendues)
    m0, m1, m2, m3 = c.marqueurs
    lignes = String[]
    if m0 == 0 && m3 == 0
        if m1 + m2 > 0
            push!(lignes, "le signal arrive sur M1/M2 ($m1/$m2 fronts), pas sur M0/M3 : déplace-le sur M0 de cette carte" *
                          (spc.fin_par_m3 ? " et sur M3." : "."))
        elseif sans_ni
            push!(lignes, "aucun marqueur : rien n'arrive sur M0–M3 de cette carte.")
        else
            push!(lignes, "aucun marqueur sur M0–M3 alors que la NI génère le signal : il n'arrive pas à cette carte " *
                          "(fil de $(F.pass_terminal_text(borne)), BOB-104, masse D GND" *
                          (spc.source == "qc104" ? " → broche 5 ou 15 ; M0 = broche 12, M3 = broche 10 de la QC-104). " : " broche 15). ") *
                          "Essaie une autre sortie avec --borne /X6321/PFIx, ou mesure la borne à l'oscilloscope.")
        end
    elseif !spc.fin_par_m3
        # M0 seul ([clamp] fin_par_m3 = false) : M3 n'est pas attendu.
        if m0 == 0
            push!(lignes, "M3 reçoit ($m3) mais pas M0 : le signal de passe doit arriver sur M0 de cette carte.")
        elseif sans_ni
            push!(lignes, "M0 : $m0 fronts : le signal de passe arrive (M0 seul, chaque passe dure le scan).")
        else
            push!(lignes, abs(m0 - attendues) <= 2 ?
                "M0 : $m0 fronts pour ~$attendues passes attendues : le signal de passe arrive (M0 seul, chaque passe dure le scan)." :
                "M0 : $m0 fronts pour ~$attendues passes attendues : des fronts manquent ou sont en trop.")
            c.m0_manquants > 0 && push!(lignes, "M0 : $(c.m0_manquants) manquant(s) dans la cadence (créneau de $(ms(periode_s)) ms).")
            c.hors_duree > 0 && push!(lignes, "M0 : $(c.hors_duree) front(s) hors cadence (parasites, ignorés) : masse, câble, connecteur.")
        end
        m3 > 0 && push!(lignes, "M3 reçoit aussi ($m3 fronts), sans être utilisé (fin_par_m3 = false).")
        (m1 > 0 || m2 > 0) && push!(lignes, "M1/M2 reçoivent aussi ($m1/$m2) : les horloges du scanner, ou le signal de passe câblé aussi là.")
    else
        m0 == 0 && push!(lignes, "M3 reçoit ($m3) mais pas M0 : câble de M0 de cette carte.")
        m3 == 0 && push!(lignes, "M0 reçoit ($m0) mais pas M3 : câble de M3 de cette carte (ou fin_par_m3 = false pour M0 seul).")
        if m0 > 0 && m3 > 0
            if sans_ni
                push!(lignes, "M0 et M3 : $m0 et $m3 fronts : le signal de passe arrive" * (abs(m0 - m3) > 1 ? ", mais les deux comptes diffèrent." : "."))
            else
                ecart = max(abs(m0 - attendues), abs(m3 - attendues))
                push!(lignes, ecart <= 2 ? "M0 et M3 : $m0 et $m3 fronts pour ~$attendues passes attendues : le signal de passe arrive." :
                                           "M0 et M3 : $m0 et $m3 fronts pour ~$attendues passes attendues : des fronts manquent ou sont en trop.")
            end
        end
        (m1 > 0 || m2 > 0) && push!(lignes, "M1/M2 reçoivent aussi ($m1/$m2) : les horloges du scanner, ou le signal de passe câblé aussi là.")
    end
    en_passe = sum(c.photons_par_code)
    if en_passe < 50
        push!(lignes, "routage : trop peu de photons pendant les passes ($en_passe) pour le vérifier.")
    else
        lu = argmax(c.photons_par_code) - 1
        part = c.photons_par_code[lu + 1] / en_passe
        push!(lignes, lu == code ? @sprintf("routage : la carte lit le code %d écrit (%.0f %% des photons des passes).", code, 100part) :
                      lu == 15 - code ? "routage : la carte lit $lu, l'inverse du $code écrit : inverse inverser_routage dans config/spc.toml." :
                      lu == 0 ? "routage : la carte lit 0 (rien sur R0–R3) : P0.4–P0.7 n'arrivent pas aux entrées de routage" *
                                (spc.source == "qc104" ? " (broches 2, 3, 4, 7 de la QC-104)." : ".") :
                      "routage : la carte lit $lu au lieu de $code ($(string(lu; base = 2, pad = 4)) au lieu de $(string(code; base = 2, pad = 4))) : " *
                      "lignes échangées ou bloquées (R0 = P0.4 … R3 = P0.7).")
    end
    return lignes
end

# --- Mesure ----------------------------------------------------------------------
m = C.demarrer_moteur(spc)
taches = F.DAQmx.TaskHandle[]
final = nothing
try
    C.afficher_etat(C.verifier(m))
    C.commander!(m, C.Clamp(rois = [code], ordre = [code], scan_s = scan / rate, pause_s = pause / rate,
                            echantillon_s = sans_ni ? NaN : 1 / rate, tous_marqueurs = true))     # sans NI : cadence inconnue
    timedwait(() -> C.etat_moteur(m) == :clamp, 30.0; pollint = 0.01) === :ok || error("les cartes ne passent pas en Realtime")
    if !sans_ni
        F.with_context("écriture du code de routage sur le port 0 ($(cfg.line_channels))") do
            F.DAQmx.withtask("flimapp_test_lignes") do th
                F.DAQmx.add_do(th, cfg.line_channels)
                F.DAQmx.write_do_u8(th, UInt8[octet]; autostart = true)
            end
        end
        passes = F.create_pass_task(cfg, 2, scan, pause; terminal = borne)
        push!(taches, passes)
        horloge = F.create_clock_task(cfg)
        push!(taches, horloge)
        F.with_context(() -> F.DAQmx.start_task(passes), "démarrage du compteur de passes")
        F.with_context(() -> F.DAQmx.start_task(horloge), "démarrage de l'horloge")
    end
    debut = time()
    println()
    while time() - debut < duree_s
        r = C.recevoir(m)
        if r === nothing
            sleep(0.01)
            continue
        end
        if r isa C.EtatClamp
            println(@sprintf("t = %.0f s", r.duree_s))
            foreach(c -> println(ligne_carte(c)), r.cartes)
        elseif r isa C.Alerte && r.gravite != :info
            println("  ⚠ ", r.texte)
        end
        C.rendre!(m, r)
    end
finally
    for th in reverse(taches)                    # l'horloge d'abord : tout s'arrête sur le même échantillon
        try; F.DAQmx.stop_task(th); catch; end
        try; F.DAQmx.clear_task(th); catch; end
    end
    if !sans_ni
        try
            F.DAQmx.withtask("flimapp_test_lignes") do th
                F.DAQmx.add_do(th, cfg.line_channels)
                F.DAQmx.write_do_u8(th, UInt8[0]; autostart = true)
            end
        catch e
            println("⚠ port 0 pas remis à zéro : ", sprint(showerror, e))
        end
    end
    C.commander!(m, C.Arret())
    t0 = time()
    while time() - t0 < 30
        r = C.recevoir(m)
        r === nothing && (sleep(0.01); continue)
        r isa C.EtatClamp && r.fin && (global final = r)
        C.rendre!(m, r)
        r isa C.Fin && r.mesure == :clamp && break
    end
    C.arreter_moteur(m)
end

# --- Conclusion ------------------------------------------------------------------
final === nothing && error("pas de compteurs de fin : voir les alertes ci-dessus")
attendues = sans_ni ? 0 : floor(Int, final.duree_s / periode_s)
println("\n=== Fin : $(@sprintf("%.1f", final.duree_s)) s" * (sans_ni ? "" : ", ~$attendues passes attendues") * " ===")
for c in final.cartes
    println(ligne_carte(c))
    foreach(l -> println("    → ", l), conclusion(c, attendues))
end
diagnostics = F.diagnose_passes(final; daq_slots = sans_ni ? nothing : 1)
println("\nDiagnostic de l'app : ", isempty(diagnostics) ? "rien à signaler" : "")
foreach(d -> println("  ", F.problem_text(d.id, d.detail)), diagnostics)
