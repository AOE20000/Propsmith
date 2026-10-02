# One-time per-Blender setup: addons, Python deps, hamr path injection.
#
# Hamr drives a *specific* Blender install chosen in settings.json. Every new
# Blender needs three things this script provides:
#   1. io_scene_vrm (renamed from the upstream zip's folder so Hamr's
#      `addon_utils.enable("io_scene_vrm")` resolves) — user scripts dir,
#      because Blender 5.x no longer scans the install dir for legacy addons.
#   2. MB-Lab 1.8.1 under BOTH names Hamr uses ("mb-lab" at build time,
#      "mblab" in check-env) — one real folder, one junction.
#   3. hamr itself + its pip deps inside Blender's bundled Python, via a .pth
#      file (Blender 5.x ignores PYTHONPATH, the .pth does not).
#
# Usage:  pwsh -File tools/hamr/setup_blender.ps1 -BlenderExe <path\to\blender.exe>
param([Parameter(Mandatory = $true)][string]$BlenderExe)

$ErrorActionPreference = "Stop"
$blenderDir = Split-Path -Parent $BlenderExe
$versionDir = Get-ChildItem $blenderDir -Directory | Where-Object { $_.Name -match '^\d+\.\d+$' } | Select-Object -First 1
if ($null -eq $versionDir) { Write-Error "no <major.minor> dir under $blenderDir"; exit 2 }
$version = $versionDir.Name

# ── 1. Addons into the user scripts dir ─────────────────────────────────────
$addonDst = Join-Path $env:APPDATA "Blender Foundation\Blender\$version\scripts\addons"
New-Item -ItemType Directory -Force -Path $addonDst | Out-Null

$vrmSrc = "C:\Users\御坂零伊\.workbuddy\tools\hamr-addons\io_scene_vrm"
Copy-Item -Recurse -Force $vrmSrc (Join-Path $addonDst "io_scene_vrm")

$mbSrc = "C:\Users\御坂零伊\.workbuddy\tools\hamr-addons\mb-lab"
Copy-Item -Recurse -Force $mbSrc (Join-Path $addonDst "mb-lab")
cmd /c mklink /J "`"$addonDst\mblab`"" "`"$addonDst\mb-lab`"" | Out-Null

# ── 2. hamr source visible to Blender's Python ──────────────────────────────
$sitePackages = Join-Path $versionDir.FullName "python\Lib\site-packages"
" src" | Out-Null
Set-Content -Path (Join-Path $sitePackages "hamr_src.pth") -Value "C:\Users\御坂零伊\.workbuddy\tools\hamr\src" -Encoding ascii

# ── 3. pip deps into Blender's bundled Python ───────────────────────────────
$bpy = Join-Path $versionDir.FullName "python\bin\python.exe"
& $bpy -m pip install --quiet --proxy http://127.0.0.1:7890 pyyaml pillow pydantic rich click
& $bpy -c "import yaml, PIL, numpy, pydantic, rich, click; print('DEPS OK')"

Write-Host "Blender $version configured at $blenderDir"
Write-Host "Point settings.json blender_path at $BlenderExe"
