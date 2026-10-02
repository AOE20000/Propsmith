# Asserts the optional scripting integrations behave correctly when they are absent.
#
# `smoke_test.ps1` boots the game and `check_scripts.ps1` parses every file, but
# neither can check the answers of the compatibility layer — and the configuration
# this repository ships in has both GDExtensions missing, where a wrong answer is
# silent. This runs the assertions in `tools/runtime_self_test.gd` and classifies the
# engine's shutdown noise the same way the smoke test does.
#
# Usage:  pwsh -File tools/check_runtimes.ps1
param(
    [string]$ProjectDir = "D:\untitled\FPGames",
    [string]$Godot = "D:\GJ\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe"
)

$ErrorActionPreference = "Continue"

# Benign lines, in two groups.
#
# 1. Engine shutdown noise: the dummy renderer always leaks its resources at exit
#    under `--headless`.
# 2. Warnings the self test *provokes on purpose*. Several checks assert that a bad
#    input is refused, and refusal is implemented as `push_warning` — so this output
#    is the evidence the check fired, not a fault. Each pattern is the exact message
#    from one assertion, deliberately narrow enough that it cannot hide an unexpected
#    warning from anywhere else.
#
# `at: push_warning` / `at: push_error` are the engine's stack-frame continuation
# lines. They only exist to accompany a line above them, which is still judged on its
# own, so dropping them hides nothing.
#
# Note that `-match` is case-insensitive, so a continuation line mentioning
# `push_warning` would otherwise be counted as a second problem.
$benignPatterns = @(
    "RendererDummy",
    "resources still in use at exit",
    "ObjectDB instances were leaked",
    "Unreferenced static string",
    "Cannot find the active camera",
    "RID allocations of type",
    "at: push_warning",
    "at: push_error",
    "[mod:selftest] prop id 'selftest_prop' already taken",
    "[selftest] watch: 'player_died_secretly' is not a published event",
    "[selftest] on: 'before_frame' is not a hook",
    "[ModHost] mod 'selftest_second': prop id 'shared_id' is already claimed",
    "[ModOrder] mod 'lonely' depends on 'ghost_mod', which is not installed",
    # The map-identity section *provokes* SaveSystem refusals on purpose; the
    # refusal is implemented as push_error, so this line is evidence, not a fault.
    # (The match is on the ASCII prefix only — the Chinese reason would mojibake
    # in captured output, and the prefix is enough: this self test performs no
    # other save-file operation.)
    "ERROR: SaveSystem: "
)


## Run Godot headless; return its exit code and every line it printed.
##
## Redirected through temporary files rather than `2>&1` because PowerShell 7 decodes
## a native command's redirected output with the system OEM codepage, which mojibakes
## any Chinese the engine echoes back — and the self-test prints install hints in
## Chinese. Reading the bytes back as UTF-8 is deterministic.
function Invoke-GodotCapture {
    param([string[]]$Arguments)

    $tempRoot = [System.IO.Path]::GetTempPath()
    $stdoutPath = Join-Path $tempRoot ("fpgames_selftest_{0}.log" -f [guid]::NewGuid().ToString("N"))
    $stderrPath = Join-Path $tempRoot ("fpgames_selftesterr_{0}.log" -f [guid]::NewGuid().ToString("N"))
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


# `--quit-after` is a hang guard: if the test script fails to compile, nothing calls
# quit() and this would wait forever. It is not a timeout — the completion marker is
# what decides pass or fail.
$godotArgs = @(
    "--headless", "--path", ('"' + $ProjectDir + '"'),
    "res://tools/runtime_self_test.tscn",
    "--quit-after", "600"
)

$run = Invoke-GodotCapture -Arguments $godotArgs
$exitCode = $run.ExitCode
$lines = @($run.Lines | ForEach-Object { $_.TrimEnd() })

Write-Host "--- self test ---"
$lines | Where-Object { $_ -match "\[selftest\]" } | ForEach-Object { Write-Host $_ }

$failures = @()
foreach ($line in $lines) {
    if ($line -notmatch "ERROR|SCRIPT ERROR|WARNING") { continue }
    $isBenign = $false
    foreach ($pattern in $benignPatterns) {
        if ($line -match [regex]::Escape($pattern)) { $isBenign = $true; break }
    }
    if (-not $isBenign) { $failures += $line }
}

Write-Host ""
$completed = @($lines | Where-Object { $_ -match "\[selftest\] \d+ checks passed" }).Count -gt 0
if (-not $completed) {
    Write-Host "--- problems (1) ---" -ForegroundColor Red
    Write-Host "the run never reported a passing summary — the self test did not complete" -ForegroundColor DarkRed
    Write-Host "RUNTIME SELF TEST FAILED (godot exit $exitCode)" -ForegroundColor Red
    exit 1
}

if ($failures.Count -gt 0) {
    Write-Host "--- problems ($($failures.Count)) ---" -ForegroundColor Red
    $failures | Select-Object -First 30 | ForEach-Object { Write-Host $_ -ForegroundColor DarkRed }
    Write-Host "RUNTIME SELF TEST FAILED (godot exit $exitCode)" -ForegroundColor Red
    exit 1
}

if ($exitCode -ne 0) {
    Write-Host "RUNTIME SELF TEST FAILED: godot exited $exitCode" -ForegroundColor Red
    exit 1
}

Write-Host "RUNTIME SELF TEST PASSED (exit 0, no unexpected errors)" -ForegroundColor Green
exit 0
