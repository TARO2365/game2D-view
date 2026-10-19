# Runs the full GUT suite headless. Exit code != 0 means failure.
# Usage: powershell -File tools/run_tests.ps1
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$godot = if ($env:GODOT) { $env:GODOT } else { "$env:LOCALAPPDATA\Programs\Godot\Godot_v4.7.2-stable_win64_console.exe" }

New-Item -ItemType Directory -Force (Join-Path $root "build") | Out-Null

# Import pass builds .godot/ and the global class cache (needed on fresh clones).
& $godot --headless --path $root --import
if ($LASTEXITCODE -ne 0) { Write-Error "Import failed ($LASTEXITCODE)"; exit $LASTEXITCODE }

& $godot --headless --path $root -s res://addons/gut/gut_cmdln.gd -gconfig=res://.gutconfig.json
exit $LASTEXITCODE
