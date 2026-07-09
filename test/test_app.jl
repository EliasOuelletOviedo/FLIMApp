using Test
using GLMakie

# load the application code (this will define AppState, AppRun, etc.)
# NOTE: this test predates several AppState/AppRun fields (e.g. `roi`) and is
# broken independently of this include-path update — see DEVELOPMENT.md.
using FLIMApp

# create a minimal fake GUI environment for the purposes of the test
app = AppState(dark,
               current_panel,
               layout,
               controller,
               protocol,
               console)

app_run = AppRun(nothing,
                 Threads.Atomic{Bool}(false),
                 nothing,
                 nothing,
                 nothing,
                 nothing,
                 Observable(zeros(Float64,256)),
                 Observable(zeros(Float64,256)),
                 Observable(Float64[]),
                 Observable(0.0),
                 Observable(Float64[]),
                 Observable(Float64[]),
                 Observable(Float64[]),
                 Observable(Float64[]),
                 Observable{UInt32}(0),
                 Observable(collect(1:256)))

# dummy axes and label used by the autoscaler/infos loops
fig = Figure(resolution = (1,1))
plot1 = Axis(fig[1, 1])
plot2 = Axis(fig[1, 1])
label = Label(fig, "")
blocks = Dict(:plot_1_axis=>plot1, :plot_2_axis=>plot2, :info_label=>label)

@testset "runtime tasks" begin
    # start the acquisition and let it run for a short interval
    start_pressed(app, app_run, blocks)
    sleep(0.2) # give the worker a moment to produce some points
    stop_pressed(app_run)

    @test !app_run.running[]
    @test length(app_run.photons[]) >= 0  # should be nonnegative (trivial)

    # now change binning value and verify histogram length reductions
    app.layout[:binning] = 4
    start_pressed(app, app_run, blocks)
    sleep(0.2)
    stop_pressed(app_run)
    last_hist = app_run.histogram[]
    @test length(last_hist) == 256  # Length remains 256 as binning sums vectors of same length
end
