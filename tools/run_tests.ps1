# Runs the full GUT suite headless. Exit code != 0 means failure.
# Usage: powershell -File tools/run_tests.ps1 [-Config res://.gutconfig.json]
# GUT skips test scripts that fail to parse and can still report "All tests
# passed" with exit 0, so this script also fails on any script load/parse error.
param([string]$Config = "res://.gutconfig.json")
$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $PSScriptRoot
$godot = if ($env:GODOT) { $env:GODOT } else { "$env:LOCALAPPDATA\Programs\Godot\Godot_v4.7.2-stable_win64_console.exe" }

New-Item -ItemType Directory -Force (Join-Path $root "build") | Out-Null

# Import pass builds .godot/ and the global class cache (needed on fresh clones).
& $godot --headless --path $root --import
if ($LASTEXITCODE -ne 0) { Write-Error "Import failed ($LASTEXITCODE)"; exit $LASTEXITCODE }

$log = Join-Path $root "build/test_output.log"
& $godot --headless --path $root -s res://addons/gut/gut_cmdln.gd "-gconfig=$Config" 2>&1 |
	ForEach-Object { "$_" } | Tee-Object -FilePath $log
$code = $LASTEXITCODE

$broken = Select-String -Path $log -Pattern "Parse Error|Failed to load script" | ForEach-Object { $_.Line.Trim() }
if ($broken) {
	Write-Host ""
	Write-Host "FAILED: test scripts could not be loaded (GUT skipped them):" -ForegroundColor Red
	$broken | Select-Object -Unique | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
	if ($code -eq 0) { $code = 2 }
}
exit $code
