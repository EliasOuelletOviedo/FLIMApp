"""
runtime.jl

Background task lifecycle: the consumer/info tasks
started on acquisition, and the START/PAUSE/RESUME/STOP button handlers that
launch and tear them down together with the acquisition worker task
(acquisition.jl), autoscaling (plotting.jl), and serial signaling (serial.jl).

Tasks are launched by start_pressed() and terminated by stop_pressed().
"""

using GLMakie
using Observables
using DataFrames
using Base.Threads

"""
    accumulate_roi_sample!(app, series::RoiSeries, frame::RegionFrame, timestamp::Float64, command::Float64)

Append one instance's results for one region — the ratio, the concentration,
each channel's mean intensity, and their smoothed companions — plus that
region's own timestamp and the PI `command` in force for it onto its
time-series observables.

`command` is passed in rather than read off the frame because who computed it
depends on the ROI model: in round-robin mode it is this region's own
controller (`RoiPowerControl`, roi.jl), in spatial-mask mode the worker's
single PI pair, shared by every region.

Which `RoiSeries` a `RegionFrame` is routed to is decided by the caller
(`consumer_loop`), not here: in spatial-mask mode region `i` goes to series
`i`, while in round-robin mode the single region goes to whichever series the
scan slot points at.
"""
function accumulate_roi_sample!(app, series::RoiSeries, frame::RegionFrame, timestamp::Float64, command::Float64)
    push!(series.timestamps[], timestamp)
    push!(series.command[], command)

    push!(series.ratio[], frame.ratio)
    append_smooth_value!(app, series.ratio, series.ratio_smooth, series.timestamps, series.ratio_kalman)

    push!(series.concentration[], frame.concentration)
    append_smooth_value!(app, series.concentration, series.concentration_smooth, series.timestamps, series.concentration_kalman)

    for (c, channel) in enumerate(series.channels)
        value = c <= length(frame.channel_means) ? frame.channel_means[c] : NaN
        push!(channel.values[], value)
        append_smooth_value!(app, channel.values, channel.smooth, series.timestamps, channel.kalman)
    end

    return nothing
end

"""
    publish_preview!(app_run, sample)

Publish one instance's downsampled snapshot onto the GUI-facing observable the
image plot renders. A no-op when the sample carries no preview, which is the
normal case between throttled builds — leaving the previous frame on screen
rather than blanking the plot.
"""
function publish_preview!(app_run, sample::AcquisitionSample)
    sample.preview === nothing && return nothing
    app_run.preview[] = sample.preview
    return nothing
end

"""
    realtime_capture_dataframe(channel_count) -> DataFrame

Empty per-instance capture table for Realtime mode, with one mean-intensity
column per channel.

Built for a specific channel count rather than declared once as a constant:
the column set depends on what the acquisition writes, and the FLIM version's
fixed `_ch1`/`_ch2` columns have no equivalent when a run may have one, two or
three channels — nor when the useful per-channel quantity is a mean intensity
rather than a histogram and a fit.
"""
function realtime_capture_dataframe(channel_count::Integer)
    df = DataFrame(
        frame_idx=UInt32[],
        instance_index=Int[],
        source_files=String[],
        roi_index=Int[],
        timestamp=Float64[],
        ratio=Float64[],
        concentration=Float64[],
        command1=Float64[],
        command2=Float64[],
        protocol_setpoint=Float64[]
    )

    for c in 1:max(Int(channel_count), 1)
        df[!, Symbol("mean_c", c)] = Float64[]
    end

    return df
end

"""
    release_hardware_outputs!(app, app_run)

Drive every output on both trigger boxes back to its resting state: analog and
digital outputs on the galvo box (`zero_all_outputs!`, serial.jl) and the power
buffer on the second one (`zero_roi_power_buffer!`, roi.jl).

The single place that answers "the run is over, stop driving things". Called
from `stop_pressed` (the STOP button) *and* from `consumer_loop`'s `finally`,
because those are two genuinely different ways for a run to end and only the
first used to zero anything — a Save run that reached its last file, or a
worker that threw, left the outputs energized at whatever the controller last
commanded.

Safe to call twice, with no device connected, or on a dead port: both helpers
no-op on `nothing` and swallow their own failures.
"""
function release_hardware_outputs!(app, app_run)
    if app_run.serial1 !== nothing
        zero_all_outputs!(app_run.serial1)
    end

    zero_roi_power_buffer!(app, app_run)

    return nothing
end

"""
    scan_position_to_roi(scan_order, slot_key, n_rois)::Int

Which ROI series a round-robin scan slot belongs to.

`slot_key` counts scan *positions* around the cycle, while `rois_series` (and
`app_run.rois[]`, which it mirrors) is in the order the ROIs were drawn. Those
two orders are not the same: `roi_trigger_buffer` (roi.jl) lays the ROIs out
along `optimize_centers`' shortest tour, so the ROI physically scanned first
is whichever one that tour starts at, not the first one drawn.

`scan_order` is the permutation the trigger box was actually programmed with
(`app_run.roi_scan_order`). An empty or wrong-length one — no upload happened,
or the ROI set changed after it did — falls back to treating the two orders as
identical, which is exactly the behavior from before the mapping existed.
"""
function scan_position_to_roi(scan_order::Vector{Int}, slot_key::Integer, n_rois::Integer)::Int
    position = mod1(Int(slot_key), Int(n_rois))

    if length(scan_order) != Int(n_rois)
        return position
    end

    return clamp(scan_order[position], 1, Int(n_rois))
end

"""
    consumer_loop(app, app_run, blocks; rate=30, acquisition_mode="Playback", use_spatial_masks=true)

Consumes acquisition samples from the channel and updates the `app_run`
observables. Notifications are throttled to approximately `rate` Hz to avoid
overwhelming the GUI.

# Region routing

`use_spatial_masks` decides how a sample's regions map onto the series, and
must match what the worker was started with (both come from the same test in
`start_pressed`):

- **spatial** — the sample carries one `RegionFrame` per drawn ROI, all
  measured from this instance, so region `i` appends to series `i`;
- **round-robin** — the sample carries a single `RegionFrame` covering the
  whole frame, and the scan slot decides which series it belongs to.
"""
function consumer_loop(app, app_run, blocks; rate=30, acquisition_mode="Playback", use_spatial_masks::Bool=true)
    last_publish_time = time()
    publish_interval_s = 1.0 / rate
    plot_1_axis = blocks.plot_1_axis
    plot_2_axis = blocks.plot_2_axis
    publish_live_updates = acquisition_mode != "Save"
    last_sample = nothing
    is_realtime_mode = acquisition_mode == "Realtime"

    # Real-time missed-scan repair. The source acquisition sometimes writes no
    # files at all for a ROI's scan, and because it numbers files as they are
    # written that hole leaves no trace in the numbering — so every later
    # instance lands one ROI off, permanently. `RoiSlotTracker`
    # (acquisition.jl) recovers the real scan slot from the delay between
    # instances instead, seeded with the period the trigger box itself was
    # programmed with (`app.protocol.scan_time + .shift_time`, read once here:
    # that's the value uploaded at START, which a later edit to the textbox
    # does not re-upload).
    #
    # Real-time only, and only in round-robin mode. Playback paces instances
    # on its own synthetic schedule and Save runs them as fast as it can, so in
    # neither mode does the delay between reads carry any information about the
    # acquisition's cadence. In spatial-mask mode there is no round-robin to
    # keep aligned in the first place.
    roi_slot_tracker = RoiSlotTracker(roi_scan_period_s(app.protocol))
    warned_ambiguous_roi_gap = Ref(false)
    realtime_frame_df = realtime_capture_dataframe(app_run.channel_count)

    # The order the galvo box was actually programmed to visit the ROIs in,
    # snapshotted for the run: `roi_scan_order[k]` is the index into
    # `rois_series` of the ROI scanned in cycle position `k`. Empty when no
    # upload happened (no device, ROI mode off), where scan position and drawn
    # order coincide by default.
    roi_scan_order = copy(app_run.roi_scan_order)

    # Per-ROI PI control: every instance measures every ROI, so every instance
    # advances all n controllers and produces all n commands at once.
    #
    # Deliberately NOT gated on `serial2` being connected: this also produces
    # the per-ROI traces the Command plot draws, so the plot has to work with
    # no power hardware attached. Only the *upload* checks for the device.
    roi_power = RoiPowerControl(app.protocol, roi_scan_order, length(app_run.rois_series))

    # How this run gets its power onto the hardware. Three ways, and exactly one
    # applies — `serial_signal_loop` consults the same helper, so only ever one
    # writer owns the analog output.
    #
    # - ROI + protocol on with two or more ROIs: alternating set-and-wait
    #   sequences on the galvo box itself (`RoiPowerSequencer`, roi.jl). No
    #   second device involved.
    # - ROI on with two or more ROIs but no protocol: the power box's replayed
    #   sample buffer, as before.
    # - a single region (ROI off, or one ROI): one held level on analog output 3.
    direct_output = drives_analog_output_directly(app, app_run)
    use_power_sequencer = !direct_output && app.protocol.active
    push_power = !direct_output && !use_power_sequencer

    power_sequencer = use_power_sequencer ? RoiPowerSequencer() : nothing

    try
        for sample in app_run.channel
            while app_run.running[] && app_run.paused[]
                sleep(0.02)
            end

            if !app_run.running[]
                break
            end

            last_sample = sample

            n_rois = length(app_run.rois_series)
            roi_idx = 1

            if use_spatial_masks
                # Every region measured from this same instance. Extra regions
                # (the ROI set changed mid-run, which rebuild_roi_series! does
                # not track) are dropped rather than written past the end.
                for (i, region) in enumerate(sample.regions)
                    i > n_rois && break

                    # Each ROI is regulated by its own controller, all advanced
                    # from this one instance. Computed before accumulating so
                    # the command lands on the same index as its timestamp.
                    command = update_roi_power_command!(roi_power, i, region.ratio,
                                                        sample.protocol_setpoint, sample.timestamps,
                                                        app.controller, series_smooth_level(app.layout))

                    accumulate_roi_sample!(app, app_run.rois_series[i], region, sample.timestamps, command)
                end

                if power_sequencer !== nothing
                    # Rebuild the idle sequence with the new levels and swap onto
                    # it, leaving the running one to be parked — the output is
                    # never interrupted to be updated.
                    log_roi_power_commands(roi_power, sample.frame_index)
                    push_roi_power_sequence!(app, app_run, power_sequencer, roi_power)
                elseif push_power
                    # Every ROI's command just changed, so the whole buffer is
                    # rebuilt and re-sent — one upload per acquired image.
                    log_roi_power_commands(roi_power, sample.frame_index)
                    push_roi_power_buffer!(app, app_run, roi_power)
                elseif !isempty(sample.regions)
                    # One region — the whole frame, or the single ROI the galvo
                    # traces for the entire period. One command, written straight
                    # to the galvo box's analog output 3 as a held level. No
                    # buffer and no second box involved.
                    push_whole_image_command!(app_run, roi_power.commands[1])
                end
            else
                # Round-robin: instance 1 -> ROI 1, instance 2 -> ROI 2, ...,
                # instance N+1 -> ROI 1 again. Keyed on the instance's OWN
                # index (recovered from the acquisition's T counter), not this
                # app's read-count — see AcquisitionSample's docstring
                # (data_types.jl): an instance that never reaches this app is
                # invisible to frame_index, which would then silently misassign
                # every later instance for the rest of the run.
                #
                # In Real-time that index is then corrected against the measured
                # delay between instances (next_roi_slot!), the only thing that
                # can see a scan the source wrote no file for — such a hole
                # consumes no counter values, so the numbering alone reports
                # business as usual right through it.
                slot_key = sample.instance_index

                if is_realtime_mode && n_rois > 1
                    slot, skipped, ambiguous = next_roi_slot!(roi_slot_tracker, sample.file_time, slot_key)

                    if skipped > 0
                        @warn "Gap between acquisition instances spans more than one ROI scan; assuming the source wrote nothing for it and advancing ROI assignment to stay aligned" instance=sample.instance_index skipped_scans=skipped period_s=round(roi_slot_tracker.period_est_s, digits=3) roi_index=scan_position_to_roi(roi_scan_order, slot, n_rois)
                    elseif ambiguous && !warned_ambiguous_roi_gap[]
                        @warn "Delay between acquisition instances doesn't line up with the expected scan period; ROI assignment may drift — check Scan time / Shift time against the actual acquisition" instance=sample.instance_index expected_period_s=round(roi_slot_tracker.period_est_s, digits=3)
                        warned_ambiguous_roi_gap[] = true
                    end

                    slot_key = slot
                end

                # `slot_key` counts *scan positions*, but the series (and the
                # drawn ROI set they mirror) are in the order the ROIs were
                # drawn — and the trigger box visits them in the optimized tour
                # order instead (`ordered_roi_indices`, roi.jl). Mapping through
                # the order the box was actually programmed with is what puts
                # each scan's measurement on the ROI it really came from.
                roi_idx = scan_position_to_roi(roi_scan_order, slot_key, n_rois)

                if !isempty(sample.regions)
                    # Only the ROI this instance covered advances; the others
                    # keep the command they last held. Computed before
                    # accumulating so the command lands on the same index as the
                    # timestamp it belongs to.
                    command = update_roi_power_command!(roi_power, roi_idx, sample.regions[1].ratio,
                                                        sample.protocol_setpoint, sample.timestamps,
                                                        app.controller, series_smooth_level(app.layout))

                    accumulate_roi_sample!(app, app_run.rois_series[roi_idx], sample.regions[1], sample.timestamps, command)

                    if push_power
                        log_roi_power_commands(roi_power, sample.frame_index)
                        push_roi_power_buffer!(app, app_run, roi_power)
                    end
                end
            end

            if is_realtime_mode && !isempty(sample.regions)
                region = sample.regions[1]
                row = Dict{Symbol, Any}(
                    :frame_idx => sample.frame_index,
                    :instance_index => sample.instance_index,
                    :source_files => join(basename.(sample.source_files), "; "),
                    :roi_index => roi_idx,
                    :timestamp => Float64(sample.timestamps),
                    :ratio => Float64(region.ratio),
                    :concentration => Float64(region.concentration),
                    :command1 => Float64(sample.command1),
                    :command2 => Float64(sample.command2),
                    :protocol_setpoint => Float64(sample.protocol_setpoint)
                )
                for c in 1:max(app_run.channel_count, 1)
                    row[Symbol("mean_c", c)] = c <= length(region.channel_means) ? Float64(region.channel_means[c]) : NaN
                end
                push!(realtime_frame_df, row)
            end

            push!(app_run.protocol_setpoint[], sample.protocol_setpoint)
            push!(app_run.command1[], sample.command1)
            push!(app_run.command2[], sample.command2)
            push!(app_run.timestamps[], sample.timestamps)
            app_run.i[] = sample.frame_index

            now_s = time()

            if publish_live_updates && now_s - last_publish_time >= publish_interval_s
                publish_preview!(app_run, sample)
                notify_runtime_observables!(app_run)

                last_publish_time = now_s

                autoscale_plot!(app, app_run, plot_1_axis, app.layout.plot1, plot_channel_toggles(app.layout, 1))
                autoscale_plot!(app, app_run, plot_2_axis, app.layout.plot2, plot_channel_toggles(app.layout, 2))
            end
        end

        # Publish the final instance once the loop ends, so the plots show the
        # last processed data even if it arrived between throttled updates.
        if last_sample !== nothing
            publish_preview!(app_run, last_sample)
            notify_runtime_observables!(app_run)

            save_completed = isfinite(app_run.save_progress[]) && app_run.save_progress[] >= 100.0
            if save_completed
                autolimits!(plot_1_axis)
                autolimits!(plot_2_axis)
                lim1 = plot_1_axis.finallimits[]
                lim2 = plot_2_axis.finallimits[]
                xmax1 = lim1.origin[1] + lim1.widths[1]
                xmax2 = lim2.origin[1] + lim2.widths[1]
                xlims!(plot_1_axis, 0.0, max(Float64(xmax1), 0.0))
                xlims!(plot_2_axis, 0.0, max(Float64(xmax2), 0.0))
            else
                autoscale_plot!(app, app_run, plot_1_axis, app.layout.plot1, plot_channel_toggles(app.layout, 1))
                autoscale_plot!(app, app_run, plot_2_axis, app.layout.plot2, plot_channel_toggles(app.layout, 2))
            end
        end

        if !app_run.running[]
            app_run.save_progress[] = NaN
        end

        if is_realtime_mode && nrow(realtime_frame_df) > 0
            save_realtime_capture!(app, app_run, realtime_frame_df)
        end

        blocks.start_button.label[] = "START"
        blocks.stop_button.label[] = "CLEAR"
    catch e
        @error "Consumer error" exception=(e, catch_backtrace())
    finally
        # Whatever ends this loop — STOP, a Save run reaching its last file, a
        # worker that died, an exception above — the hardware must not be left
        # holding the last commanded level. `stop_pressed` covers only the STOP
        # button, so without this a run that finished on its own kept driving
        # the outputs indefinitely.
        release_hardware_outputs!(app, app_run)
    end
end

function infos_loop(app_run, info_label; rate=1.0)
    last_i = app_run.i[]
    last_t = time()
    dt = 1/float(rate)
    freq_ema = NaN   # smoothed frame rate (Hz), EMA of the instantaneous rate
    while app_run.running[]
        if app_run.paused[]
            sleep(min(dt, 0.05))
            continue
        end

        sleep(dt)
        try
            i = app_run.i[]
            now = time()
            elapsed = now - last_t
            if i != last_i && elapsed > 0
                # Rate over the true elapsed time (not the nominal dt), smoothed
                # so the readout doesn't jump with each integer frame-count tick.
                inst = (i - last_i) / elapsed
                freq_ema = isfinite(freq_ema) ? 0.6 * freq_ema + 0.4 * inst : inst
                info_label.text[] = "Frequency: $(round(freq_ema, digits=1)) Hz\nFile: $i"
                last_i = i
                last_t = now
            end
        catch e
            @warn "Infos loop error" e
        end
    end
    return nothing
end

# -----------------------------------------------------------------------------
# button handlers
# -----------------------------------------------------------------------------

"""
    reset_roi_series!(series::RoiSeries)

Clear one region's time-series observables ahead of a fresh acquisition run.
Does not notify — callers batch their own notifications.
"""
function reset_roi_series!(series::RoiSeries)
    empty!(series.timestamps[])
    empty!(series.command[])
    empty!(series.ratio[])
    empty!(series.ratio_smooth[])
    empty!(series.concentration[])
    empty!(series.concentration_smooth[])

    for channel in series.channels
        empty!(channel.values[])
        empty!(channel.smooth[])
    end

    return nothing
end

"""
    use_spatial_roi_masks(app)::Bool

Which of the two ROI models a run should use — always spatial masks now.

Every acquired image carries all of the drawn ROIs, so each is measured from
every instance through its own pixel mask, and one instance yields one
`RegionFrame` per ROI. That holds in ROI mode too: the camera integrates over a
full scan cycle, so the frame it writes contains every ROI the galvo visited
during that exposure, not just one of them.

This used to return `false` when the ROI toggle and the protocol were both on,
selecting a round-robin model where each instance was assumed to cover a single
ROI and successive frames were dealt out in turn. That assumption did not match
the acquisition, which is why per-ROI control saw one ROI's measurement per
frame instead of all of them.

Kept as a function rather than inlined: it is still read once at START and
passed to both the worker (which builds the masks) and `consumer_loop` (which
routes the resulting regions), so the two cannot disagree about what a sample's
`regions` vector means.
"""
use_spatial_roi_masks(app)::Bool = true

"""
    sync_preview_enabled!(app, app_run)

Set `app_run.preview_enabled` from whether either plot slot currently shows the
Image plot.

Called at START and from the Layout panel whenever a plot selection changes
(handlers_layout.jl), so the worker stops paying for previews the moment
nothing is displaying them and resumes the moment something is.
"""
function sync_preview_enabled!(app, app_run)
    app_run.preview_enabled[] = app.layout.plot1 == PLOT_IMAGE || app.layout.plot2 == PLOT_IMAGE
    return nothing
end

"""
    rebuild_roi_series!(app, app_run; channel_count=app_run.channel_count)

Resize `app_run.rois_series` to one series per drawn ROI (`app_run.rois[]`),
or a single series when none are drawn — or when ROI mode is off.

Gated on the ROI toggle (`app.roi.active`): with it off the run reduces over
the whole frame instead of per-ROI, so there is exactly one region and one
series no matter how many ROIs happen to be drawn. `start_pressed` enforces
the other half of that by handing the worker an empty ROI set, which is what
makes `build_region_masks` (ratio_analysis.jl) return a single whole-image
mask.

The series count and the worker's region count must agree — `consumer_loop`
drops regions past the end of `rois_series` — so both are derived from the
same two things: the toggle, and the number of drawn ROIs.

Each series is sized for `channel_count` channels, which is what makes
`accumulate_roi_sample!`'s per-channel loop line up with the worker's
`channel_means`.

Discards all previously accumulated per-region data. Called ahead of a fresh
acquisition run (`start_pressed`) and by the CLEAR button
(`clear_runtime_plots!`, handlers.jl) — either could follow a change to the
drawn ROI set or the toggle, and the routing in `consumer_loop` needs the
vector to always be a non-zero length. Callers must re-render both plot slots
(`render_plot!`, plotting.jl) afterward: this replaces the `Observable`s
themselves (not just their contents), so any existing `lines!` plot objects on
the axes are left pointing at now-orphaned data.
"""
function rebuild_roi_series!(app, app_run; channel_count::Integer=app_run.channel_count)
    n = app.roi.active ? max(1, length(app_run.rois[])) : 1
    app_run.channel_count = max(Int(channel_count), 1)
    app_run.rois_series = [RoiSeries(app_run.channel_count) for _ in 1:n]
    return nothing
end

"""
    reset_acquisition_state!(app, app_run)

Clear all time-series observables and counters ahead of a fresh acquisition run.
"""
function reset_acquisition_state!(app, app_run)
    rebuild_roi_series!(app, app_run)
    app_run.preview[] = nothing
    empty!(app_run.protocol_setpoint[])
    empty!(app_run.command1[])
    empty!(app_run.command2[])
    empty!(app_run.timestamps[])
    app_run.i[] = 0
    app_run.save_progress[] = NaN
    return nothing
end

"""
    spawn_acquisition_worker!(app_run, selected_mode, layout, controller, protocol_config; rois, use_spatial_masks, preview_enabled, nominal_period_s)

Launch the background worker task for the selected acquisition mode
(Playback/Realtime/Save, defaulting to Playback for an unrecognized mode)
and store it on `app_run.worker_task`.

`rois`, `use_spatial_masks` and `roi_reference_size` are snapshotted by the
caller and passed by value: the worker builds its pixel masks from them on its
own thread, and reaching into `app_run.rois[]` from there would race the ROI
popup.

Launched with `Threads.@spawn`, not `@async`: the worker loop reads and
reduces whole images, and `@async` tasks are sticky to the thread they were
spawned from — with GLMakie's event loop and
`consumer_task`/`serial_task`/`infos_task` all pinned to the main thread via
`@async` (see `start_pressed` below), a `@async` worker would compete with
GUI redraw and input for every frame. `Threads.@spawn` lets the scheduler run
the worker on a different OS thread when one is available. This is pure Julia
(`Base.Threads`) with no OS-specific code, so it behaves identically on macOS
and Windows; it only *helps* when Julia is started with more than one thread
(`julia -t auto`), which `start_pressed` checks for and warns about below.
With a single thread it degrades gracefully to the same cooperative
scheduling as `@async` — never worse, just not better.

`consumer_task` (and `serial_task`/`infos_task`) must stay on `@async`: they
touch `Observable`s and the GLMakie figure directly, which are not safe to
mutate concurrently from multiple threads.
"""
function spawn_acquisition_worker!(app_run, selected_mode, layout, controller, protocol_config;
                                   rois::Vector{RoiCoordinates}=RoiCoordinates[],
                                   use_spatial_masks::Bool=true,
                                   roi_reference_size::Union{Nothing, Tuple{Int, Int}}=nothing,
                                   preview_enabled::Threads.Atomic{Bool}=Threads.Atomic{Bool}(true),
                                   nominal_period_s::Float64=NaN)
    shared = (
        protocol = protocol_config,
        paused = app_run.paused,
        rois = rois,
        use_spatial_masks = use_spatial_masks,
        roi_reference_size = roi_reference_size,
        preview_enabled = preview_enabled
    )

    if selected_mode == "Realtime"
        app_run.worker_task = Threads.@spawn start_realtime(
            app_run.channel, app_run.running, layout, controller;
            shared..., nominal_period_s=nominal_period_s
        )
    elseif selected_mode == "Save"
        app_run.save_progress[] = 0.0

        save_progress_cb = function (pct)
            app_run.save_progress[] = Float64(pct)
            return nothing
        end

        # Save runs the whole instance list as fast as the disk allows and
        # publishes no live updates, so previews would be built and discarded.
        # Its own Atomic, not the shared one, so disabling them here cannot
        # switch them off for a plot that is displaying them.
        app_run.worker_task = Threads.@spawn start_save(
            app_run.channel, app_run.running, layout, controller;
            shared..., preview_enabled=Threads.Atomic{Bool}(false), progress_cb=save_progress_cb
        )
    else
        if selected_mode != "Playback"
            @warn "Unknown acquisition mode selected; falling back to Playback" selected_mode=selected_mode
        end

        app_run.worker_task = Threads.@spawn start_playback(
            app_run.channel, app_run.running, layout, controller;
            shared..., target_frequency=app_run.target_frequency
        )
    end

    return nothing
end

"""
    abort_start!(app_run, blocks)

Undo the `running`/`paused` flags claimed by `start_pressed` and restore the
button labels when a start is abandoned after those flags were set (e.g. a
missing data folder found during the async validation).
"""
function abort_start!(app_run, blocks)
    app_run.running[] = false
    app_run.paused[] = false
    update_start_button_label!(app_run, blocks)
    update_stop_button_label!(app_run, blocks)
    return nothing
end

"""
    start_pressed(app, app_run, blocks)

Handler called when the START button is clicked. After its guard checks and
claiming `running[]`/`paused[]` synchronously, the rest of the work — the
ROI trigger-box upload, setting up the communication channel, resetting all
time-series observables, and launching four background tasks — happens on
its own `@async` task that this function does not wait on (see the comment
above that task in the body for why: this function's own call stack is
GLMakie's render-loop task, and blocking it blocks rendering).

The four background tasks:

* **worker_task** - the Playback/Realtime/Save acquisition loop (acquisition.jl)
  that reads data files and pushes samples onto the channel. Launched with
  `Threads.@spawn` (see `spawn_acquisition_worker!`), since it is
  CPU-bound (dominated by the MLE fit) and must not block the GUI thread;
* **consumer_task** - pulls samples from the channel and updates the
  `app_run` observables so that the plots react. Stays on `@async` (pinned
  to the thread it's spawned from, i.e. the GUI thread) since it touches
  `Observable`s/GLMakie, which aren't safe to mutate from multiple threads;
* **serial_task** - periodically sends PID/PWM commands to the connected device;
* **infos_task** - refreshes the status label at 1 Hz.

`blocks` is used to read the selected mode/lifetimes menus and to obtain
the info label object for `infos_task`.
"""
function start_pressed(app, app_run, blocks)
    if app_run.running[]
        @info "Already running"
        return
    end

    # A previous run's async teardown (stop_pressed) may still be draining its
    # tasks; starting now would let that teardown clobber the fresh channel/tasks.
    if tasks_still_running(app_run)
        @info "Previous run is still shutting down; ignoring START"
        show_status!(blocks, "Finishing previous run…")
        return
    end

    @info "Starting acquisition"

    # Claimed synchronously, before any of the async work below, so a second
    # click arriving while that work is still in flight is still correctly
    # caught by the "already running" guard above instead of racing in as a
    # second concurrent start. Neither field has any on(...) listener
    # (they're plain Threads.Atomic{Bool}, not Observable — data_types.jl),
    # so setting them early has no other side effect.
    app_run.running[] = true
    app_run.paused[] = false

    # Everything below is real work — the ROI trigger-box upload alone can
    # be 1000+ blocking serial round trips — so none of it runs directly in
    # this function's own call stack. start_pressed is invoked synchronously
    # from GLMakie's own render-loop task: button clicks are dispatched via
    # GLFW.PollEvents() from inside that loop's while-loop (GLMakie
    # screen.jl), so this function's call stack *is* that task. Blocking it
    # — even indirectly, e.g. a wait() on some other task — blocks the
    # render loop itself; nothing else can step in to draw a frame while
    # it's suspended waiting. The previous attempt at this
    # (`wait(@async build_and_send_roi_trigger_buffer!(...))`) still did
    # exactly that, which is why the save_progress bar it drives (roi.jl)
    # stayed invisible. Returning immediately here and doing the real work
    # on its own task instead — never waited on from this call stack, same
    # as consumer_task/serial_task/infos_task always have been — is what
    # actually lets rendering keep happening while this runs.
    @async begin
        # Position the trigger box (if active/connected) before any
        # file-reading begins, so the first acquired frame already matches
        # the first ROI in the scan cycle. No-op (see its own docstring)
        # unless ROI mode is on, a serial device is connected, and at least
        # one ROI is drawn.
        build_and_send_roi_trigger_buffer!(app, app_run)

        # The GUI stays responsive during that upload now (that's the point
        # of this task), which makes it newly possible for the user to
        # click STOP while it's still running — stop_pressed (below) would
        # see running[] already true and run its shutdown against state
        # (channel/worker_task/...) this function hasn't created yet. Bail
        # out here instead of dispatching a worker the user just asked to
        # stop before it ever started.
        if !app_run.running[]
            @info "Acquisition stopped before it finished starting (during ROI trigger-box upload)"
            return nothing
        end

        selected_mode = blocks.mode_menu.selection[]
        if !(selected_mode isa AbstractString)
            selected_mode = "Playback"
        end

        # Validate the data source here, on the GUI thread, so the common
        # "clicked START but nothing happened" cases surface in the window
        # instead of only in the worker's console log. Realtime waits for
        # files to appear, so it just needs the folder to exist.
        data_path = get_data_root_path()
        if !isdir(data_path)
            show_status!(blocks, "Data folder not found")
            abort_start!(app_run, blocks)
            return nothing
        end
        # Realtime waits for a session folder to appear, so it only needs the
        # parent to exist. The other two modes need one already on disk, and
        # resolving it here means "you picked a folder with no acquisition in
        # it" shows up in the window rather than only in the worker's log.
        channel_layout = nothing
        if selected_mode != "Realtime"
            channel_layout = resolve_channel_layout(data_path)
            if channel_layout === nothing
                show_status!(blocks, "No Bliq VMS channel folders found")
                abort_start!(app_run, blocks)
                return nothing
            end
        end

        # The ratio combination is persisted through app.layout (committed by
        # the menu handler), so the worker reads it from there rather than from
        # the widget — one source of truth, and it survives a restart.
        selected_combination = blocks.ratio_menu.selection[]
        if selected_combination isa AbstractString
            app.layout.ratio_combination = selected_combination
        end

        # Channel count comes from the folder layout when one is already
        # resolvable; Realtime cannot know it until its session appears, so it
        # keeps whatever the last run used and the series are rebuilt to match
        # once the worker reports the real geometry.
        channel_count = channel_layout === nothing ? app_run.channel_count : length(channel_layout.channel_dirs)

        # Read once, and shared by the worker (which builds the masks) and the
        # consumer (which routes the regions) so the two cannot disagree.
        use_spatial_masks = use_spatial_roi_masks(app)
        # With ROI mode off the ratio is taken over the whole frame, so the
        # worker gets no ROIs at all — `build_region_masks` (ratio_analysis.jl)
        # then returns a single whole-image mask. `rebuild_roi_series!` gates on
        # the same toggle, so the region count and the series count agree.
        rois_snapshot = app.roi.active ? copy(app_run.rois[]) : RoiCoordinates[]
        # ROI coordinates live in the reference image's pixel space, not the
        # acquisition frame's — capturing a live frame in the ROI popup records
        # the *downsampled* preview's size. Passed along so the worker can
        # convert; see roi_coordinate_scale (ratio_analysis.jl).
        roi_reference_size = app_run.imported_image_size

        # Capacity: the worker (its own thread since Threads.@spawn, see
        # spawn_acquisition_worker!) blocks on put! once this fills, so a
        # transient GUI-thread slowdown (a GC pause, a Makie redraw, a
        # smoothing-slider recompute) directly stalls the reduction loop too,
        # not just the display. 512 absorbs multi-second GC pauses without
        # back-pressuring the worker, while still bounding worst-case backlog
        # if the consumer falls behind persistently rather than transiently.
        #
        # Samples are much smaller than the FLIM version's (a handful of
        # scalars per region, and a preview only on throttled frames rather
        # than two histogram vectors every frame), so the same depth costs
        # less memory here than it did there.
        app_run.channel = Channel{AcquisitionSample}(512)

        rebuild_roi_series!(app, app_run; channel_count=channel_count)
        reset_acquisition_state!(app, app_run)
        # rebuild_roi_series! replaced app_run.rois_series wholesale, so the
        # plot axes must be rebuilt to draw one line set per new RoiSeries
        # instance — see its docstring.
        render_plot!(app, app_run, blocks, :plot1)
        render_plot!(app, app_run, blocks, :plot2)

        sync_runtime_protocol!(app, app_run)
        protocol_config = app_run.protocol

        # Only build previews when a plot is actually showing one. The worker
        # re-reads this every frame, and the Layout panel writes to it, so
        # switching a slot to the Image plot mid-run takes effect at once.
        sync_preview_enabled!(app, app_run)

        spawn_acquisition_worker!(app_run, selected_mode, app.layout, app.controller, protocol_config;
                                  rois=rois_snapshot,
                                  use_spatial_masks=use_spatial_masks,
                                  roi_reference_size=roi_reference_size,
                                  preview_enabled=app_run.preview_enabled,
                                  nominal_period_s=roi_scan_period_s(app.protocol))

        app_run.consumer_task = @async consumer_loop(app, app_run, blocks; rate=10,
                                                     acquisition_mode=selected_mode,
                                                     use_spatial_masks=use_spatial_masks)
        app_run.serial_task = @async serial_signal_loop(app, app_run; rate=20.0)
        app_run.infos_task = @async infos_loop(app_run, blocks.info_label; rate=1)
    end

    return nothing
end

function pause_pressed(app_run)
    if app_run.running[]
        app_run.paused[] = true
    end
    return nothing
end

function resume_pressed(app_run)
    if app_run.running[]
        app_run.paused[] = false
    end
    return nothing
end

"""
    background_tasks(app_run)

The five background-task slots, in the order `stop_pressed` tears them down.
"""
background_tasks(app_run) = (app_run.worker_task, app_run.consumer_task,
                             app_run.autoscaler_task, app_run.infos_task, app_run.serial_task)

"""
    tasks_still_running(app_run)::Bool

True while a previous run's tasks are still shutting down (`stop_pressed`
waits for them off the render loop, see below). `start_pressed` checks this
so a restart can't race the async teardown and have its fresh channel/tasks
clobbered by the tail of the old one.
"""
function tasks_still_running(app_run)::Bool
    return any(t -> t !== nothing && !istaskdone(t), background_tasks(app_run))
end

"""
    stop_pressed(app, app_run)

Stop any running acquisition: zero the hardware outputs (both boxes — see
`zero_roi_power_buffer!`, roi.jl), clear `running`,
and close the channel — all synchronously — then `wait` on the background
tasks from a detached `@async` task rather than inline.

The `wait` is what makes the difference: `stop_pressed` runs on GLMakie's
render-loop task (it's a button handler), and waiting there for a worker
mid-fit froze the window until the fit finished. Doing it on a separate
task keeps rendering live. The task refs are deliberately left in place (not
nil'd) so `tasks_still_running` can see the teardown is ongoing and block a
restart until it completes — `start_pressed` overwrites them with the fresh
run's tasks once they're done.
"""
function stop_pressed(app, app_run)
    # Both boxes, every output — see release_hardware_outputs!. Done here as
    # well as in consumer_loop's finally so STOP takes effect immediately
    # rather than whenever the consumer notices and unwinds.
    release_hardware_outputs!(app, app_run)

    if !app_run.running[]
        app_run.save_progress[] = NaN
        @info "Not running"
        return
    end

    @info "Stopping acquisition"

    app_run.paused[] = false
    app_run.running[] = false
    if app_run.channel !== nothing && isopen(app_run.channel)
        close(app_run.channel)
    end
    app_run.channel = nothing
    app_run.save_progress[] = NaN

    tasks = background_tasks(app_run)
    @async for t in tasks
        if t !== nothing && !istaskdone(t)
            try
                wait(t)
            catch e
                @warn "Task error during shutdown" e
            end
        end
    end

    return nothing
end
