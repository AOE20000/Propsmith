# Headless smoke test for the FPGames project.
#
# Runs the real main scene (map loading, mods, player, HUD) either to completion in
# validate-only mode or for a fixed number of frames, then reports any error the
# engine produced. This is the check that catches runtime faults — bad API calls,
# null references, missing resources — which a syntax pass cannot see.
#
# Usage:  pwsh -File tools/smoke_test.ps1 [-Frames 240] [-Validate]
param(
    [string]$ProjectDir = "D:\untitled\FPGames",
    [string]$Godot = "D:\GJ\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe",
    [int]$Frames = 240,
    [switch]$Validate
)

$ErrorActionPreference = "Continue"

# Known-benign shutdown noise: the headless renderer always leaks its dummy
# resources at exit, and a display-only GDExtension reports a missing camera
# under headless.
$benignPatterns = @(
    "RendererDummy",
    "resources still in use at exit",
    "ObjectDB instances were leaked",
    "Cannot find the active camera",
    "instance_reset_physics_interpolation",
    "RID allocations of type"
)


## Run Godot headless; return its exit code and every line it printed.
##
## Output is captured through temporary files rather than `2>&1`. Godot prints
## UTF-8 — mod names and several boot lines are Chinese — but PowerShell 7 decodes
## a native command's redirected output with the system OEM codepage, which turns
## those lines into mojibake. Pointing `[Console]::OutputEncoding` at UTF-8 did not
## override that reliably: the same script decoded correctly on one run and not the
## next. Reading the bytes back as UTF-8 is deterministic instead.
##
## The trade-off is that stdout and stderr are no longer interleaved — stdout is
## listed first. Every consumer below filters by pattern, so order does not matter.
function Invoke-GodotCapture {
    param([string[]]$Arguments)

    $tempRoot = [System.IO.Path]::GetTempPath()
    $stdoutPath = Join-Path $tempRoot ("fpgames_stdout_{0}.log" -f [guid]::NewGuid().ToString("N"))
    $stderrPath = Join-Path $tempRoot ("fpgames_stderr_{0}.log" -f [guid]::NewGuid().ToString("N"))
    try {
        $process = Start-Process -FilePath $Godot -ArgumentList $Arguments `
            -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath

        $lines = @()
        if (Test-Path -LiteralPath $stdoutPath) {
            $lines += @(Get-Content -LiteralPath $stdoutPath -Encoding utf8)
        }
        if (Test-Path -LiteralPath $stderrPath) {
            $lines += @(Get-Content -LiteralPath $stderrPath -Encoding utf8)
        }
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Lines = $lines }
    } finally {
        Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
    }
}


# -ArgumentList is joined on spaces, so a project path containing spaces has to
# arrive already quoted.
#
# `--quit-after` is a hang guard, not a timeout. If the boot script itself fails to
# compile, nothing ever calls `quit()`, and a script that waits for the process
# would sit here forever. The engine then exits by itself with status 0, which is
# why the completion-marker check below exists: without it, a boot that never
# finished would be indistinguishable from a pass.
$godotArgs = @("--headless", "--path", ('"' + $ProjectDir + '"'), "--quit-after", "6000")

if ($Validate) {
    $env:DSH_VALIDATE_ONLY = "1"
    $run = Invoke-GodotCapture -Arguments $godotArgs
    $env:DSH_VALIDATE_ONLY = ""
    $expectedMarker = "[boot] SMOKE TEST PASSED"
} else {
    # Runtime mode: boot, settle the physics, and verify the player is standing on
    # the generated collision before quitting.
    $env:DSH_RUNTIME_REPORT = "1"
    $run = Invoke-GodotCapture -Arguments $godotArgs
    $env:DSH_RUNTIME_REPORT = ""
    $expectedMarker = "[runtime] COLLISION AND SPAWN VERIFIED"
}
$exitCode = $run.ExitCode

$lines = @($run.Lines | ForEach-Object { $_.TrimEnd() })
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
$reachedMarker = @($lines | Where-Object { $_.Contains($expectedMarker) }).Count -gt 0
if (-not $reachedMarker) {
    Write-Host "--- problems (1) ---" -ForegroundColor Red
    Write-Host "the run never reached '$expectedMarker' — boot did not complete" -ForegroundColor DarkRed
    Write-Host "SMOKE TEST FAILED (godot exit $exitCode)" -ForegroundColor Red
    exit 1
}

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
