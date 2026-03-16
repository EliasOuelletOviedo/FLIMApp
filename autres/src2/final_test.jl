#!/usr/bin/env julia

"""
Final test: run_app() with timeout to verify it compiles and starts without segfault.
"""

cd("/Users/eliasouellet-oviedo/Documents/Stage2/Codes/FLIMApp/src2")
include("main.jl")

println("\n" * "="^70)
println("FINAL TEST: run_app() compilation and startup")
println("="^70)

timeout_task = @async begin
    sleep(3)  # Wait 3 seconds
    println("\n[Timeout] Shutting down test after 3 seconds...")
    exit(0)
end

try
    println("\n[Starting] run_app()...")
    run_app()
    println("\n✓ SUCCESS: run_app() executed without segmentation fault!")
catch e
    println("\n✗ FAILED: Exception during run_app():")
    println(e)
    exit(1)
end
