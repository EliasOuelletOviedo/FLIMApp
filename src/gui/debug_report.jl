"""
gui/debug_report.jl

The debug report: one text file with what is needed to find what went
wrong at the bench, to read or to send as it is. Written at the end of
every run (`debug_report.txt` in its folder), when the app closes and with
the Console panel's button (`<journal>/debug/`). Every section is written
on its own: one that fails says so and the others are still there.

Sections: versions and environment; the problems seen, with their codes and
what to check (diagnostics.jl, DEBUGGING.md); the run; the DAQ loop; the
SPC engine (cards, settings applied, alerts, rates); what the cards
received during the last Realtime measurement (`FLIMCore.EtatClamp`) and its
diagnosis; the analysis worker; the IRF and how it compares with the
current settings; the settings; config/bench.toml and config/spc.toml as
they are; the last records of the debug log, with their stack traces.
"""

using Printf

"""
    debug_report_text(app_run; app=nothing)::String

The debug report (see the file docstring); `app` (the `AppState`) adds the
layout, controller and protocol settings.
"""
function debug_report_text(app_run; app = nothing)::String
    io = IOBuffer()
    section(title) = println(io, "\n", "="^78, "\n", title, "\n", "="^78)
    function part(f, title)
        section(title)
        try
            f()
        catch e
            println(io, "  (this section failed: ", first(split(sprint(showerror, e), '\n')), ")")
        end
    end
    kv(k, v) = println(io, "  ", rpad(string(k), 26), string(v))

    println(io, "FLIMApp debug report — ", timestamp_string(time()))
    println(io, "Problem codes: DEBUGGING.md (what each one means, what to check).")

    part("Versions and environment") do
        for (k, v) in sort!(collect(code_versions()); by = first)
            kv(k, v)
        end
        kv("OS", "$(Sys.KERNEL) $(Sys.MACHINE)")
        kv("threads", "$(Threads.nthreads(:interactive)) interactive + $(Threads.nthreads(:default)) default")
        kv("offline", isempty(app_run.offline) ? "no" : app_run.offline)
        kv("debug log", isempty(debug_log_path()) ? "none (console only)" : debug_log_path())
        kv("journal", journal_root(app_run.config))
        kv("recording folder", FLIMCore.dossier_spc(app_run.spc.settings))
        kv("free space", recording_space(app_run.spc.settings)[3])
        kv("memory peak", "$(round(Sys.maxrss() / 2^20)) MB")
    end

    part("Problems seen (latest first)") do
        lines = problem_lines(; with_check = true)
        isempty(lines) ? println(io, "  none") : foreach(l -> println(io, "  ", l), lines)
    end

    part("Run") do
        kv("mode", app_run.run_mode)
        kv("running / open", "$(app_run.running[]) / $(app_run.run_open)")
        kv("run folder", isempty(app_run.run_dir) ? "—" : app_run.run_dir)
        kv("ROI visiting order", app_run.roi_order)
        kv("ROIs", join(["$k: $(r.name) ($(fit_channel_name(r)))" for (k, r) in enumerate(app_run.run_rois)], ", "))
        kv("image size", app_run.imported_image_size)
        kv("frames shown", "$(app_run.i) (lost by the display: $(app_run.display.frames_lost))")
        if app_run.run_mode == "Playback"
            kv("session replayed", app_run.playback.dir)
            fin = app_run.playback.fin
            kv("replay", fin === nothing ? "—" : fin.raison)
        end
    end

    part("DAQ loop") do
        status = loop_status(app_run.exchange)
        kv("state", "$(LOOP_STATE_NAMES[status.state])" * (isempty(status.message) ? "" : " — $(status.message)"))
        d = app_run.display
        kv("bench config", "$(app_run.config.source) ($(app_run.config.backend))")
        kv("slots played", d.loop_slots)
        kv("iteration max", "$(round(1000 * d.loop_iteration_max_s; digits = 2)) ms")
        kv("margin min", "$(round(1000 * d.loop_margin_min_s; digits = 2)) ms of $(round(1000 * d.loop_deadline_s; digits = 2)) ms")
        s = d.last_slot
        s === nothing || kv("last slot", "slot $(s.slot), ROI $(s.roi), visit $(s.visit), commands $(s.command1_v) / $(s.command2_v) V")
        kv("journal", "$(pending_journal(app_run.exchange.journal)) pending, $(app_run.exchange.journal.dropped[]) dropped")
    end

    part("SPC engine") do
        view = app_run.spc
        kv("state", spc_state(view) == :none ? "not running" : SPC_ENGINE_STATE_NAMES[spc_state(view)])
        kv("settings", view.settings_path)
        kv("source", view.settings.source)
        check = view.check
        if check === nothing
            println(io, "  no check of the cards yet")
        else
            kv("check", "source $(check.source), " * (check.ok ? "all passed" : "$(length(check.problemes)) problem(s)"))
            for c in check.cartes
                println(io, "    module $(c.carte): serial $(c.serie), channel $(c.canal), ",
                        c.pret ? "ready, SYNC $(c.sync), CFD $(fmt_rate(c.cfd)) /s" : "NOT READY ($(c.etat_init))")
                for l in c.tableau
                    l.statut == :ok || println(io, "      setting $(l.cle): requested $(l.demande), applied $(l.applique) ($(l.statut))")
                end
            end
            foreach(p -> println(io, "    problem: ", p), check.problemes)
        end
        for k in sort!(collect(keys(view.cards)))
            r = view.cards[k].last_rates
            r === nothing && continue
            println(io, @sprintf("    rates module %d: SYNC %.3g /s, CFD %.3g /s, TAC %.3g /s, ADC %.3g /s, FIFO %.0f %%, SYNC state %d",
                                 k, r.sync, r.cfd, r.tac, r.adc, 100 * r.remplissage_fifo, r.etat_sync))
        end
        println(io, "  alerts (oldest first):")
        for a in view.alerts
            println(io, "    ", Dates.format(Dates.unix2datetime(a.t) + local_utc_offset(), "HH:MM:SS"), " ",
                    a.gravite, " module $(a.carte): ", a.texte)
        end
        fin = view.last_fin
        fin === nothing || kv("last measurement", "$(fin.mesure): $(fin.raison)" * (fin.erreur ? " (error)" : ""))
    end

    part("Realtime: what the cards received") do
        status = app_run.spc.clamp_status
        if status === nothing
            println(io, "  no Realtime counters yet")
        else
            foreach(l -> println(io, "  ", l), pass_status_lines(status))
            diagnoses = diagnose_passes(status)
            println(io, "  diagnosis: ", isempty(diagnoses) ? "nothing wrong" : "")
            foreach(d -> println(io, "    ", problem_text(d.id, d.detail)), diagnoses)
        end
    end

    part("Analysis worker") do
        s = app_run.worker_stats
        kv("passes analyzed", s.passes[])
        kv("fits failed", "channel 1: $(s.fits_failed[1][]), channel 2: $(s.fits_failed[2][])")
        kv("kept out of the PI", s.excluded[])
        lock(s.lock) do
            for (k, v) in sort!(collect(s.reasons); by = last, rev = true)
                println(io, "    $k ×$v")
            end
        end
        kv("not analyzed (code)", "$(s.unmatched[]), codes mask $(string(s.unmatched_codes[]; base = 2))")
        kv("most passes waiting", s.backlog_max[])
        kv("longest pass analysis", "$(round(s.pass_max_ns[] / 1e6; digits = 1)) ms")
    end

    part("IRF") do
        kv("loaded", irf_loaded() ? "yes, $(length(loaded_irfs())) channel(s), bin $(RUNTIME[].irf_bin_size) ns" : "NO")
        info = loaded_irf_info()
        kv("source", get(info, "source", "—"))
        for (c, channel) in enumerate(get(info, "channels", Any[]))
            settings = join(["$k=$v" for (k, v) in sort!(collect(get(channel, "settings", Dict())); by = first)], ", ")
            println(io, "    channel $c: card $(get(channel, "serial", "?")); $settings")
        end
        kv("declared [dcc] then", get(info, "dcc", "—"))
        mismatches = irf_mismatches(info, app_run.spc.settings; applied = spc_applied_settings(app_run.spc))
        println(io, "  compared with the current settings: ", isempty(mismatches) ? "same" : "")
        foreach(m -> println(io, "    ", m), mismatches)
    end

    if app !== nothing
        part("Settings (layout, controller, protocol)") do
            for (name, x) in (("layout", app.layout), ("controller", app.controller), ("protocol", app.protocol), ("roi", app.roi))
                println(io, "  [$name] ", join(["$k=$v" for (k, v) in sort!(collect(settings_dict(x)); by = first)], ", "))
            end
        end
    end

    for (title, path) in (("config/bench.toml", app_run.config.source), ("config/spc.toml", app_run.spc.settings_path))
        part("$title ($path)") do
            isfile(path) ? print(io, read(path, String)) : println(io, "  (no file: built-in defaults)")
        end
    end

    part("Debug log: last records (with stack traces)") do
        records = recent_log(; limit = 300)
        isempty(records) ? println(io, "  (no debug log installed)") : foreach(r -> println(io, r), records)
    end
    return String(take!(io))
end

"""
    write_debug_report(app_run, path; app=nothing)::String

Write the debug report to `path`; returns `path`, or "" if it couldn't
(logged — never raised: it runs at the end of a run and at shutdown).
"""
function write_debug_report(app_run, path::AbstractString; app = nothing)::String
    try
        mkpath(dirname(path))
        write(path, debug_report_text(app_run; app))
        return String(path)
    catch e
        @error "Debug report not written" path=path exception=(e, catch_backtrace())
        return ""
    end
end

"""Where a debug report made outside a run goes: `<journal>/debug/<date>_report.txt`."""
debug_report_path(app_run) =
    joinpath(journal_root(app_run.config), "debug", Dates.format(Dates.now(), dateformat"yyyy-mm-dd_HHMMSS") * "_report.txt")
