# QA wrapper around tools/web_smoke.mjs (Windows).
# web_smoke.mjs's proc.kill() does not end the headless Edge process tree on
# Windows; the browser keeps port 9333 and the NEXT run silently attaches to
# that old browser (old profile, old page) instead of starting a fresh one.
# This wrapper kills only headless test browsers on port 9333 before and after
# the run, so a "restart with the same profile" really restarts the browser.
# Usage: powershell -File tools/qa_web_smoke.ps1 <steps.json> <out_dir> <profile_dir>
param([string]$Steps, [string]$Out, [string]$Profile)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

function Stop-TestBrowsers {
	Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" |
		Where-Object { $_.CommandLine -match '--headless=new --remote-debugging-port=9333' } |
		ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
	Start-Sleep -Seconds 2
}

Stop-TestBrowsers
& node (Join-Path $root "tools/web_smoke.mjs") $Steps $Out $Profile
$code = $LASTEXITCODE
Stop-TestBrowsers
exit $code
