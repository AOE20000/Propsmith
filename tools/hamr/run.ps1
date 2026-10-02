# Hamr wrapper for Propsmith — the "pick your Blender" seam.
#
# Hamr resolves the Blender executable through PATH only (no env var, no
# config of its own, `compat.py` hardcodes `shutil.which("blender")`). This
# wrapper reads `settings.json` next to it, puts that Blender's folder at the
# front of PATH for the child process, and hands all arguments to the hamr CLI
# — so switching Blender installs is a one-line edit in settings.json, and
# nothing outside this file needs to know where Blender lives.
#
# Usage:  pwsh -File tools/hamr/run.ps1 check-env
#         pwsh -File tools/hamr/run.ps1 build specs/protagonist.yaml '--out' build/
# (Quote PowerShell's own parameter-looking tokens like '--out' when calling.)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$settings = Get-Content (Join-Path $here "settings.json") -Raw -Encoding UTF8 | ConvertFrom-Json

$blenderPath = $settings.blender_path
if (-not (Test-Path $blenderPath)) {
    Write-Error "settings.json points to a missing Blender: $blenderPath"
    exit 2
}

$env:PATH = (Split-Path -Parent $blenderPath) + ";" + $env:PATH
# The CLI prints ✓/✗ glyphs; a GBK console would kill it mid-report.
$env:PYTHONUTF8 = "1"

$hamr = "C:\Users\御坂零伊\.workbuddy\binaries\python\envs\hamr\Scripts\hamr.exe"
if (-not (Test-Path $hamr)) {
    Write-Error "hamr CLI not found at $hamr — create the venv first (see docs/local/hamr.md)"
    exit 2
}
& $hamr @args
exit $LASTEXITCODE
