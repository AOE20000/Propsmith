# Per-file GDScript syntax check for the FPGames project.
#
# Why this exists: `godot --headless --script` does not register autoload
# singletons, so any script referencing `Events`/`Services`/`GameState` reports a
# bogus "Identifier not found". This script classifies those as autoload noise and
# only fails on real parse errors.
#
# Usage:  pwsh -File tools/check_scripts.ps1 [-ProjectDir <path>]
param(
    [string]$ProjectDir = "D:\untitled\FPGames",
    [string]$Godot = "D:\GJ\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe"
)

$ErrorActionPreference = "Continue"
$autoloads = @("Services", "Events", "GameState", "ModLoader", "SaveSystem")
$pattern = ($autoloads -join "|")

$scripts = Get-ChildItem -Path (Join-Path $ProjectDir "src"), (Join-Path $ProjectDir "mods") -Recurse -Filter *.gd -ErrorAction SilentlyContinue |
    Sort-Object FullName

$failed = @()
$noiseOnly = @()


## Run Godot headless; return what it printed.
##
## Captured through temporary files instead of `2>&1` because PowerShell 7 decodes
## a native command's redirected output with the system OEM codepage, which mojibakes
## any Chinese the engine echoes back from the sources under test. Reading the bytes
## back as UTF-8 is deterministic; `[Console]::OutputEncoding` was not.
function Invoke-GodotCapture {
    param([string[]]$Arguments)

    $tempRoot = [System.IO.Path]::GetTempPath()
    $stdoutPath = Join-Path $tempRoot ("fpgames_check_{0}.log" -f [guid]::NewGuid().ToString("N"))
    $stderrPath = Join-Path $tempRoot ("fpgames_checkerr_{0}.log" -f [guid]::NewGuid().ToString("N"))
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
        return $lines
    } finally {
        Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
    }
}


# -ArgumentList is joined on spaces, so paths containing spaces arrive pre-quoted.
$quotedProjectDir = '"' + $ProjectDir + '"'

foreach ($script in $scripts) {
    $relative = $script.FullName.Substring($ProjectDir.Length + 1).Replace("\", "/")
    $output = Invoke-GodotCapture -Arguments @(
        "--headless", "--path", $quotedProjectDir,
        "--check-only", "--script", ('"res://' + $relative + '"')
    )
    $errors = $output | Select-String -Pattern "Parse Error|SCRIPT ERROR"

    if (-not $errors) {
        Write-Host ("ok    " + $relative)
        continue
    }

    # Separate genuine parse errors from two kinds of autoload false positive:
    #   1. direct "Identifier not found: Events" on this script;
    #   2. pass-through "Failed to load script <dependency>" lines, which appear
    #      when a dependency itself only failed for reason (1).
    $real = $errors | Where-Object {
        $line = $_.Line
        if ($line -match "Identifier not found: ($pattern)") { return $false }
        if ($line -match "Failed to load script .*(src|mods)/([^`"]+\.gd)" -and $line -notmatch [regex]::Escape($relative)) { return $false }
        if ($line -match "Failed to compile depended scripts") { return $false }
        return $true
    }
    if ($real) {
        $failed += $relative
        Write-Host ("FAIL  " + $relative) -ForegroundColor Red
        $real | Select-Object -First 4 | ForEach-Object { Write-Host ("        " + $_.Line.Trim()) -ForegroundColor DarkRed }
    } else {
        $noiseOnly += $relative
        Write-Host ("ok*   " + $relative + "  (autoload identifier only)") -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host ("checked {0} scripts: {1} failed, {2} autoload-noise-only" -f $scripts.Count, $failed.Count, $noiseOnly.Count)
if ($failed.Count -gt 0) { exit 1 }
exit 0
