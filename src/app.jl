"""
app.jl

Application start-up and shutdown (plan §2, §5, §6, §7):

- `run_app` loads config/bench.toml, spawns the DAQ loop and journal
  threads, tries to connect the NI cards, starts the SPC engine (FLIMCore,
  if config/spc.toml asks for it),
  builds and shows the window, warms up the GUI code paths, and starts the
  30 Hz refresh tick;
- closing the window stops everything the way STOP does (the loop sees the
  stop flag within one readback block and zeroes every output), then
  disconnects the cards, stops the SPC engine (which frees the SPC-150N)
  and lets the journal write what's left.

Launch with 4 worker threads and 1 interactive thread (scripts/launch.bat
on the bench, at high priority):

    julia --project -t 4,1 scripts/app.jl config/bench.toml
"""

using GLMakie

"""The `AppRun` of the most recent `run_app`, for `wait_for_window`."""
const LAST_APP_RUN = Ref{Union{Nothing, AppRun}}(nothing)

"""
    check_threads()

Warn unless Julia runs with an interactive thread for the GUI and at least
four worker threads (DAQ loop, journal, analysis, SPC engine): with fewer, a
blocking card read or a fit shares a thread with the window, which then
freezes.
"""
function check_threads()
    n_interactive = Threads.nthreads(:interactive)
    n_default = Threads.nthreads(:default)
    if n_interactive == 0 || n_default < 4
        @warn """
        Julia is running with $n_default worker thread(s) and $n_interactive interactive thread(s).
        The GUI needs the interactive thread to itself, and the DAQ loop, the
        journal, the analysis and the SPC engine each need a worker thread;
        otherwise a card read or a lifetime fit can freeze the window (plan.md §2).
        Start with:
            julia --project -t 4,1 scripts/app.jl config/bench.toml
        (scripts/launch.bat does this at high priority on Windows).
        """
    end
    return nothing
end

"""
    offline_reason(cfg, spc)::String

Why this computer can't run the Realtime acquisition, "" if it can: the NI
backend without the NI-DAQmx driver (nicaiu), or the SPC-150N cards as SPC
source without their DLL — a laptop, typically. The app then starts
offline: no connection attempt and no fault, a banner says so, START
refuses the Realtime mode, and Playback stays available. (On the bench PC,
a failed connection is not this: the DAQ label says so and RECONNECT
retries, see `connect_button_label`.)
"""
function offline_reason(cfg::BenchConfig, spc::FLIMCore.Reglages)::String
    missing_parts = String[]
    cfg.backend == :ni && isempty(Libdl.find_library(DAQmx.LIB)) && push!(missing_parts, "NI-DAQmx driver")
    spc.source == "cartes" && !FLIMCore.SPCLite.dll_disponible() && push!(missing_parts, "SPC-150N DLL")
    isempty(missing_parts) && return ""
    return "OFFLINE (no $(join(missing_parts, ", no ")) on this computer): acquisition disabled, Playback available"
end

"""
    start_background_threads!(app_run)

Spawn the DAQ loop and journal threads for the session.
"""
function start_background_threads!(app_run::AppRun)
    cfg, ex = app_run.config, app_run.exchange
    app_run.loop_task = errormonitor(Threads.@spawn daq_loop(cfg, ex))
    app_run.journal_task = errormonitor(Threads.@spawn journal_loop(cfg, ex))
    return nothing
end

"""
    dummy_frame_record()::FrameRecord

A plausible analyzed histogram for the GUI warm-up.
"""
function dummy_frame_record()::FrameRecord
    n = DEFAULT_HISTOGRAM_RESOLUTION
    histogram = [exp(-(i - 20) / 40) * (i > 20) for i in 1:n]
    frame = ChannelFrame(histogram, copy(histogram), sum(histogram), 3.0, 1.0)
    sample = AcquisitionSample(frame, ChannelFrame(), 10.0, NaN, 1.0, NaN, UInt32(1), 1, 0.0, 1.0, true, time())
    return FrameRecord(sample, 1)
end

"""
    warm_up_gui!(app, app_run, blocks)

Plan §5 (last row): with the window shown, run every plot type and one
refresh tick once on dummy data, so JIT compilation doesn't land on the
user's first click or the first real frame. Leaves the histories empty and
the plots as the user left them.
"""
function warm_up_gui!(app, app_run, blocks)
    accumulate_frame!(app, app_run, dummy_frame_record())
    publish_frame!(app_run.ch1, dummy_frame_record().sample.ch1)
    for option in PLOT_OPTIONS
        render_plot!(app, app_run, blocks, :plot1; selection=option, show_channels=(true, true))
    end
    app_run.display.dirty = true
    refresh_tick!(app, app_run, blocks)

    reset_acquisition_state!(app, app_run)
    foreach(reset_channel_series!, channel_series(app_run))
    render_plot!(app, app_run, blocks, :plot1)
    render_plot!(app, app_run, blocks, :plot2)
    reset_diagnostics!(app_run.display)
    app_run.display.diagnostics[] = diagnostics_text(app_run)
    warm_up_spc_display!(app_run.spc)
    return nothing
end

"""
    shutdown_app!(app_run)

Window closed: stop the analysis and the scan (outputs to zero within one
readback block), disconnect the cards, stop the DAQ loop and the SPC engine
(which stops its measurement and frees the SPC-150N), then let the journal
write everything queued and close. Returns immediately; the journal is
released once the loop and the SPC engine have finished (5 s at most).
"""
function shutdown_app!(app_run::AppRun)
    ex = app_run.exchange
    ex.shutdown[] && return nothing

    app_run.running[] = false
    request_stop!(ex)
    app_run.run_open && send_journal!(ex.journal, JournalRunEnd(time()))
    send_command!(ex, DisconnectCommand())
    send_command!(ex, QuitCommand())
    journal_event!(ex.journal, :info, "window closed")
    spc_stopping = stop_spc!(app_run.spc)
    replay = app_run.playback.engine
    replay === nothing || errormonitor(Threads.@spawn FLIMCore.arreter_moteur(replay))

    loop = app_run.loop_task
    Threads.@spawn begin
        loop === nothing || timedwait(() -> istaskdone(loop), 5.0; pollint=0.05)
        spc_stopping === nothing || timedwait(() -> istaskdone(spc_stopping), 5.0; pollint=0.05)
        ex.shutdown[] = true
    end
    return nothing
end

"""
    run_app(config_path=default_bench_config_path())

Main application entry point: load the bench config and the saved
`AppState`, load the IRF and warm up the fit, spawn the DAQ loop and journal
threads, try to connect the NI cards, start the SPC engine, build the
window, attach the handlers, show it, warm up the GUI, and start the
refresh tick. Returns the `Figure`.
"""
function run_app(config_path::AbstractString = default_bench_config_path())
    @info "="^60
    @info "FLIM Application Starting"
    @info "="^60

    check_threads()
    initialize_directories()

    cfg = load_bench_config(config_path)
    @info "Bench config loaded" source=cfg.source backend=cfg.backend
    app_state = load_or_create_state()
    app_run = AppRun(cfg)
    LAST_APP_RUN[] = app_run

    init_irf_runtime!(app_run.spc.settings)

    # One-time JIT warmup of the fitting code path, done before the GUI
    # appears rather than left to the user's first START — see
    # warmup_lifetime_fitting!'s docstring.
    @info "Warming up lifetime-fitting code paths (one-time JIT compilation)..."
    t_warmup = time()
    warmup_lifetime_fitting!()
    @info "Warmup complete" seconds = round(time() - t_warmup, digits=1)

    start_background_threads!(app_run)
    journal_event!(app_run.exchange.journal, :info, "app started (config $(cfg.source), backend $(cfg.backend))")
    code_versions()                  # git, once: every session's run.toml records them

    # Offline (no NI-DAQmx driver or no SPC DLL, e.g. a laptop): nothing to
    # connect, no fault; the banner says so and Playback stays available.
    app_run.offline = offline_reason(cfg, app_run.spc.settings)
    app_run.spc.banner = app_run.offline
    isempty(app_run.offline) || @info "Starting offline" reason=app_run.offline
    app_run.playback.dir = cached_path(session_folder_cache())

    # Try to connect the NI cards right away (the DAQ loop does it on its
    # own thread; the DAQ label shows the outcome, RECONNECT retries a
    # failed connection, RESET acknowledges a fault).
    (cfg.backend != :ni || !isempty(Libdl.find_library(DAQmx.LIB))) && send_command!(app_run.exchange, ConnectCommand())

    # Plan.pdf, start-up step 3: the GUI starts the SPC engine, which
    # initializes and checks the SPC-150N on its own thread.
    spc_cards_missing = app_run.spc.settings.source == "cartes" && !FLIMCore.SPCLite.dll_disponible()
    app_run.spc.settings.connexion_au_demarrage && !spc_cards_missing && spc_connect!(app_run.spc)

    @info "Creating GUI..."
    fig, blocks = make_gui(app_state, app_run)
    make_handlers(app_state, app_run, blocks)
    display(fig)

    warm_up_gui!(app_state, app_run, blocks)
    show_recording_space!(app_run, blocks)       # the raw streams: about 4 bytes per photon per card
    start_refresh_task!(app_state, app_run, blocks, fig)
    on(events(fig).window_open) do is_open
        is_open || shutdown_app!(app_run)
    end

    @info "="^60
    @info "Application ready"
    @info "="^60
    return fig
end

"""
    wait_for_window(fig; timeout_s=10.0)

Block until the window is closed, then until the DAQ loop, the SPC engine
and the journal of the last `run_app` have finished (at most `timeout_s`) —
for scripts and the compiled app, which would otherwise exit before the
outputs are zeroed, the SPC-150N freed and the journal closed.
"""
function wait_for_window(fig; timeout_s::Real = 10.0)
    screen = GLMakie.Makie.getscreen(fig.scene)
    screen === nothing || wait(screen)

    app_run = LAST_APP_RUN[]
    if app_run !== nothing
        shutdown_app!(app_run)
        for task in (app_run.loop_task, app_run.spc.stopping, app_run.journal_task)
            task === nothing || timedwait(() -> istaskdone(task), Float64(timeout_s); pollint=0.05)
        end
    end
    return nothing
end

"""
    config_path_from_args(args)::String

The first `.toml` among the command-line arguments (the launchers pass the
bench config after Julia options), config/bench.toml otherwise.
"""
function config_path_from_args(args::AbstractVector{<:AbstractString})::String
    index = findfirst(a -> endswith(lowercase(a), ".toml"), args)
    return index === nothing ? default_bench_config_path() : String(args[index])
end

"""
    julia_main()::Cint

Entry point for the compiled standalone application (see
build/create_app.jl): the bench config is the first `.toml` command-line
argument (config/bench.toml otherwise). Blocks until the window is closed and the
background threads have finished.
"""
function julia_main()::Cint
    try
        fig = run_app(config_path_from_args(ARGS))
        wait_for_window(fig)
    catch e
        @error "FLIMApp terminated with an unhandled error" exception=(e, catch_backtrace())
        return 1
    end

    return 0
end
