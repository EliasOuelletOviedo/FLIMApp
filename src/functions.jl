# This file is included into the FLIMApp module, so AppState is visible here.
using Random

"Producer loop: runs on a worker thread, computes data and sends it into app.data_ch."
function producer_loop!(app::AppState)
    n = app.npoints
    buf = Vector{Float64}(undef, n)   # one reusable buffer to reduce allocations
    t = 0.0

    while app.running[]
        # --- example "heavy" computation (replace with your real processing) ---
        @inbounds @simd for i in 1:n
            # deterministic-ish synthetic signal; replace with your file-processing math
            buf[i] = sin(2π * (i / n) + 0.5 * t) + 0.1 * randn()
        end
        # send a copy so producer can immediately reuse its buffer
        put!(app.data_ch, copy(buf))

        t += 0.05
        # throttle loop so it doesn't spam the GUI — tune to your case
        sleep(0.01)
    end
end
