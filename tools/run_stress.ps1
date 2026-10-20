# Runs the slow stress tests (tests/stress, ~2 min). Not part of the default run.
# Same load/parse-error checks as run_tests.ps1.
# Usage: powershell -File tools/run_stress.ps1
& (Join-Path $PSScriptRoot "run_tests.ps1") -Config "res://.gutconfig_stress.json"
exit $LASTEXITCODE
