@echo off
rem FLIMApp on the bench: high process priority, 4 worker threads + 1
rem interactive thread for the GUI (plan.md sections 2 and 6.6), GC marking
rem on every core (shorter pauses, see build/create_app.jl).
rem Optional first argument: another bench config (default config\bench.toml).
cd /d "%~dp0.."
set CONFIG=%~1
if "%CONFIG%"=="" set CONFIG=config\bench.toml
start "FLIMApp" /high julia --project -t 4,1 --gcthreads=%NUMBER_OF_PROCESSORS%,1 scripts\app.jl "%CONFIG%"
