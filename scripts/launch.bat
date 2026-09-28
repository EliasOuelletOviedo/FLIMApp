@echo off
rem FLIMApp on the bench: high process priority, 3 worker threads + 1
rem interactive thread for the GUI (plan.md sections 2 and 6.6).
rem Optional first argument: another bench config (default config\bench.toml).
cd /d "%~dp0.."
set CONFIG=%~1
if "%CONFIG%"=="" set CONFIG=config\bench.toml
start "FLIMApp" /high julia --project -t 3,1 scripts\app.jl "%CONFIG%"
