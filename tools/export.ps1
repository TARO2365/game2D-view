# Exports smoke builds. Usage: powershell -File tools/export.ps1 [-Preset Web|"Windows Desktop"]
param([string]$Preset = "Web")
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$godot = if ($env:GODOT) { $env:GODOT } else { "$env:LOCALAPPDATA\Programs\Godot\Godot_v4.7.2-stable_win64_console.exe" }
$out = @{ "Web" = "build/web/index.html"; "Windows Desktop" = "build/windows/LastBunker.exe" }[$Preset]
if (-not $out) { Write-Error "Unknown preset $Preset"; exit 2 }
New-Item -ItemType Directory -Force (Join-Path $root (Split-Path $out)) | Out-Null
& $godot --headless --path $root --export-debug $Preset (Join-Path $root $out)
exit $LASTEXITCODE
