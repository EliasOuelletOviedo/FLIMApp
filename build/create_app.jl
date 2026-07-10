"""
build/create_app.jl

Build a standalone, double-clickable FLIMApp executable with PackageCompiler.

Usage (from the repository root; -t auto speeds up compilation):

    julia -t auto --project=build build/create_app.jl

The build is native-only — PackageCompiler cannot cross-compile — so run
this script on each platform you want a binary for:

- **macOS**: produces `dist/FLIMApp.app`, a real Finder app bundle
  (Contents/Info.plist + launcher). Double-click it like any app. The first
  launch on a machine may need right-click -> Open because the bundle is
  unsigned (Gatekeeper).
- **Windows**: produces `dist/FLIMApp/`, with `FLIMApp.bat` at its root.
  Double-click the .bat (or make a shortcut to it). It sets the thread
  count and starts `bin\\FLIMApp.exe`.

Either way the raw PackageCompiler output also remains directly runnable
from a terminal (`.../bin/FLIMApp`).

The launcher on both platforms sets `JULIA_NUM_THREADS=auto`: the
acquisition worker runs on its own thread (see runtime.jl) and needs a
second thread to keep the GUI responsive during fits.

Expect the build to take a long time (tens of minutes) and the output to
be large (GLMakie bundles OpenGL, fonts, FFTW, etc.).
"""

using PackageCompiler

const ROOT = dirname(@__DIR__)
const DIST = joinpath(ROOT, "dist")
const APP_COMPILE_DIR = joinpath(DIST, "FLIMApp")

println("=== FLIMApp standalone build ===")
println("Package dir : $ROOT")
println("Output dir  : $APP_COMPILE_DIR")

create_app(
    ROOT,
    APP_COMPILE_DIR;
    executables=["FLIMApp" => "julia_main"],
    force=true,
    include_lazy_artifacts=true,
    # incremental=true bases the app sysimage on the stock Julia sysimage
    # instead of compiling a minimal one from scratch. Required here: the
    # from-scratch base image on Julia 1.11 makes FixedPointNumbers'
    # `@assert precompile(...)` fail during GLMakie's precompilation
    # (known PackageCompiler issue), which aborts the whole build.
    incremental=true,
    precompile_execution_file=joinpath(ROOT, "build", "precompile_app.jl")
)

if Sys.isapple()
    # Wrap the PackageCompiler output into a real macOS .app bundle so it is
    # double-clickable in Finder. Structure:
    #   FLIMApp.app/Contents/Info.plist
    #   FLIMApp.app/Contents/MacOS/FLIMApp          (launcher script)
    #   FLIMApp.app/Contents/Resources/app/...      (PackageCompiler output)
    bundle = joinpath(DIST, "FLIMApp.app")
    rm(bundle; force=true, recursive=true)

    contents = joinpath(bundle, "Contents")
    macos_dir = joinpath(contents, "MacOS")
    resources = joinpath(contents, "Resources")
    mkpath(macos_dir)
    mkpath(resources)

    mv(APP_COMPILE_DIR, joinpath(resources, "app"))

    write(joinpath(contents, "Info.plist"),
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleName</key>
            <string>FLIMApp</string>
            <key>CFBundleDisplayName</key>
            <string>FLIMApp</string>
            <key>CFBundleIdentifier</key>
            <string>org.flimapp.FLIMApp</string>
            <key>CFBundleVersion</key>
            <string>0.1.0</string>
            <key>CFBundleShortVersionString</key>
            <string>0.1.0</string>
            <key>CFBundlePackageType</key>
            <string>APPL</string>
            <key>CFBundleExecutable</key>
            <string>FLIMApp</string>
            <key>NSHighResolutionCapable</key>
            <true/>
        </dict>
        </plist>
        """)

    launcher = joinpath(macos_dir, "FLIMApp")
    write(launcher,
        """
        #!/bin/bash
        # FLIMApp launcher: locate the bundled app and run it with threads
        # enabled (the acquisition worker needs its own thread, runtime.jl).
        DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
        export JULIA_NUM_THREADS=auto
        exec "\$DIR/../Resources/app/bin/FLIMApp"
        """)
    chmod(launcher, 0o755)

    println()
    println("=== Build complete ===")
    println("macOS app bundle: $bundle")
    println("Double-click it in Finder (first time: right-click -> Open, since it is unsigned).")
elseif Sys.iswindows()
    # The .exe is already double-clickable; add a .bat launcher at the
    # bundle root that also enables threading.
    bat = joinpath(APP_COMPILE_DIR, "FLIMApp.bat")
    write(bat,
        """
        @echo off
        set JULIA_NUM_THREADS=auto
        start "" "%~dp0bin\\FLIMApp.exe"
        """)

    println()
    println("=== Build complete ===")
    println("Windows build: $APP_COMPILE_DIR")
    println("Double-click FLIMApp.bat inside it (or make a desktop shortcut to it).")
else
    println()
    println("=== Build complete ===")
    println("Executable: $(joinpath(APP_COMPILE_DIR, "bin", "FLIMApp"))")
end
