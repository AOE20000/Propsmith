# Headless smoke test for the LSPgodot project.
#
# Runs the real main scene (terrain, mods, player, HUD) either to completion in
# validate-only mode or for a fixed number of frames, then reports any error the
# engine produced. This is the check that catches runtime faults — bad API calls,
# null references, missing resources — which a syntax pass cannot see.
#
# Usage:  pwsh -File tools/smoke_test.ps1 [-Frames 240] [-Validate]
param(
    [string]$ProjectDir = "D:\untitled\ls-pgodot",
    [string]$Godot = "D:\GJ\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe",
    [int]$Frames = 240,
    [switch]$Validate
)

$ErrorActionPreference = "Continue"

# Known-benign shutdown noise: the headless renderer always leaks its dummy
# resources at exit, and Terrain3D reports a missing camera with no display.
$benignPatterns = @(
    "RendererDummy",
    "resources still in use at exit",
    "ObjectDB instances were leaked",
    "Cannot find the active camera",
    "instance_reset_physics_interpolation",
    "RID allocations of type"
)

if ($Validate) {
    $env:DSH_VALIDATE_ONLY = "1"
    $output = & $Godot --headless --path $ProjectDir 2>&1
    $env:DSH_VALIDATE_ONLY = ""
} else {
    # Runtime mode: boot, settle the physics, and verify the player is standing on
    # the generated collision before quitting.
    $env:DSH_RUNTIME_REPORT = "1"
    $output = & $Godot --headless --path $ProjectDir 2>&1
    $env:DSH_RUNTIME_REPORT = ""
}
$exitCode = $LASTEXITCODE

$lines = $output -split "`n" | ForEach-Object { $_.TrimEnd() }
$failures = @()
foreach ($line in $lines) {
    if ($line -notmatch "ERROR|SCRIPT ERROR|WARNING") { continue }
    $isBenign = $false
    foreach ($pattern in $benignPatterns) {
        if ($line -match [regex]::Escape($pattern)) { $isBenign = $true; break }
    }
    if (-not $isBenign) { $failures += $line }
}

Write-Host "--- boot report ---"
$lines | Where-Object { $_ -match "\[boot\]|\[runtime\]|\[mod:|\[ModLoader\]" } | ForEach-Object { Write-Host $_ }

Write-Host ""
if ($failures.Count -gt 0) {
    Write-Host "--- problems ($($failures.Count)) ---" -ForegroundColor Red
    $failures | Select-Object -First 30 | ForEach-Object { Write-Host $_ -ForegroundColor DarkRed }
    Write-Host "SMOKE TEST FAILED (godot exit $exitCode)" -ForegroundColor Red
    exit 1
}

if ($exitCode -ne 0) {
    Write-Host "SMOKE TEST FAILED: godot exited $exitCode with no classified error" -ForegroundColor Red
    exit 1
}

Write-Host "SMOKE TEST PASSED (exit 0, no unexpected errors)" -ForegroundColor Green
exit 0
