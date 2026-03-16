#!/usr/bin/env julia
"""
Test compilation and loading of modules step by step.
Helps identify circular dependencies or segfault sources.
"""

println("=" ^ 60)
println("MODULE COMPILATION TEST")
println("=" ^ 60)

steps = [
    ("DataTypes.jl", () -> include("DataTypes.jl")),
    ("Persistence.jl", () -> include("Persistence.jl")),
    ("Attributes.jl", () -> include("Attributes.jl")),
    ("vec_to_lifetime.jl", () -> include("vec_to_lifetime.jl")),
    ("functions.jl", () -> include("functions.jl")),
    ("GUI.jl", () -> include("GUI.jl")),
    ("handlers.jl", () -> include("handlers.jl")),
]

for (name, loader) in steps
    print("  Loading $name... ")
    try
        loader()
        println("✓ OK")
    catch e
        println("✗ FAILED")
        println("    Error: $e")
        println("    Type: $(typeof(e))")
        rethrow(e)
    end
end

println("\n" ^ 2)
println("=" ^ 60)
println("TESTING FUNCTION CALLS")
println("=" ^ 60)

print("  create_app_run()... ")
try
    app_run = create_app_run()
    println("✓ OK")
catch e
    println("✗ FAILED")
    println("    Error: $e")
    rethrow(e)
end

print("  create_default_app_state()... ")
try
    app_state = create_default_app_state()
    println("✓ OK")
catch e
    println("✗ FAILED")
    println("    Error: $e")
    rethrow(e)
end

print("  get_theme_colors()... ")
try
    colors = get_theme_colors(true)
    println("✓ OK")
catch e
    println("✗ FAILED")
    println("    Error: $e")
    rethrow(e)
end

print("  get_rgb_colors()... ")
try
    colors = get_rgb_colors(true)
    println("✓ OK")
catch e
    println("✗ FAILED")
    println("    Error: $e")
    rethrow(e)
end

println("\n" ^ 2)
println("All tests passed! Safe to call run_app()")
