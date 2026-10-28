#Requires -Version 5.1
<#
  One-shot runner. Two separately runnable halves, because they touch two different repositories:

    engine  (TensorFold)      clone at the pinned release -> 3 patches -> vision venv -> build -> smoke
                              scripts\engine\1-preflight .. 6-smoke
    recipe  (MiaAI-Lab)       add the four .ps1 to the recipe clone, nothing else
                              scripts\recipe\1-install-ps1

  With no arguments it asks: where things live (scripts\migration.config.ps1, saved for next time),
  then which half to run. Every answer becomes a variable that the sub-scripts receive -- no path is
  written into any script.

  Usage:
    powershell -ExecutionPolicy Bypass -File scripts\Invoke-Migration.ps1
    ... -Only engine -NonInteractive            # uses the saved paths, runs the engine half
    ... -Only recipe                            # only the .ps1 copy
    ... -Reset                                  # ask the path questions again
    ... -Root E:\ai -NonInteractive             # a different tree, one run only

  Both repositories are pinned, not followed (VERSIONS.md):
    engine  eab85828 = TensorFold v1.1.4
    recipe  fd3f43e  = the commit the merged recipe patch was cut from
#>
param(
    [string]$Root   = '',
    [ValidateSet('all', 'engine', 'recipe')]
    [string]$Only   = 'all',
    [switch]$NonInteractive,
    [switch]$Reset,
    [switch]$SkipVenv,
    [switch]$Force,
    [int]$Sm        = 0
)

# Native tools write ordinary progress to stderr, and under 'Stop' PowerShell 5.1 turns such a line
# into a terminating NativeCommandError. Stay on 'Continue' and check $LASTEXITCODE.
$ErrorActionPreference = 'Continue'

$here        = $PSScriptRoot
$engineDir   = Join-Path $here 'engine'
$recipeSteps = Join-Path $here 'recipe'

function Stop-Here { param([string]$Step) Write-Host ''; Write-Host "$Step failed: fix it, then re-run that step on its own." -ForegroundColor Red; exit 1 }

# ---- paths: ask once, save, reuse ----------------------------------------
. (Join-Path $here 'migration.config.ps1')
$ask = -not $NonInteractive
$cfg = Get-MigConfig -Prompt:$ask -Reset:$Reset
if (-not $cfg) { Write-Host 'cancelled'; exit 1 }

$TensorFold = $cfg.EngineDir
$Recipe     = $cfg.RecipeDir
if ($Sm -le 0) { $Sm = $cfg.Sm }

# ---- which half ----------------------------------------------------------
$chosen = $Only
if ($ask -and -not $PSBoundParameters.ContainsKey('Only')) {
    Write-Host ''
    Write-Host 'What should run?' -ForegroundColor Cyan
    Write-Host '  [1] engine only   TensorFold: clone, 3 patches, vision venv, build, smoke'
    Write-Host '  [2] recipe only   the four .ps1 into the MiaAI-Lab recipe clone (nothing else changes)'
    Write-Host '  [3] both'
    Write-Host '  [q] quit'
    $pick = (Read-Host '  >').Trim().ToLower()
    if ($pick -eq 'q') { Write-Host 'cancelled'; exit 1 }
    if ($pick -eq '1') { $chosen = 'engine' }
    elseif ($pick -eq '2') { $chosen = 'recipe' }
    elseif ($pick -eq '' -or $pick -eq '3') { $chosen = 'all' }
    else { Write-Host "  unknown choice '$pick'"; exit 1 }
}

Write-Host ''
Write-Host ("TensorFold v1.1.4 + Qwen3.8-Flash-Next -- {0}" -f $chosen) -ForegroundColor Magenta
Write-Host ("  engine: {0}" -f $TensorFold)
Write-Host ("  recipe: {0}" -f $Recipe)

# ---- engine --------------------------------------------------------------
if ($chosen -eq 'all' -or $chosen -eq 'engine') {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    & (Join-Path $engineDir '1-preflight.ps1') -Root $cfg.Root -Python $cfg.Python -Zig $cfg.Zig -Cuda $cfg.Cuda -Vcvars $cfg.Vcvars
    if ($LASTEXITCODE -ne 0) { Stop-Here '1-preflight' }

    & (Join-Path $engineDir '2-clone.ps1') -Root $cfg.Root -TfRef $cfg.TfRef -RecipeRef $cfg.RecipeRef -Force:$Force
    if ($LASTEXITCODE -ne 0) { Stop-Here '2-clone' }

    & (Join-Path $engineDir '3-apply-patches.ps1') -TensorFold $TensorFold -TfRef $cfg.TfRef
    if ($LASTEXITCODE -ne 0) { Stop-Here '3-apply-patches' }

    if (-not $SkipVenv) {
        & (Join-Path $engineDir '4-venv.ps1') -Recipe $Recipe -Python $cfg.Python
        if ($LASTEXITCODE -ne 0) { Stop-Here '4-venv' }
    } else {
        Write-Host ''
        Write-Host '  (vision venv skipped: start the server with VISION=0)' -ForegroundColor DarkGray
    }

    & (Join-Path $engineDir '5-build.ps1') -TensorFold $TensorFold -Zig $cfg.Zig -Cuda $cfg.Cuda -Vcvars $cfg.Vcvars -Sm $Sm
    if ($LASTEXITCODE -ne 0) { Stop-Here '5-build' }

    & (Join-Path $engineDir '6-smoke.ps1') -TensorFold $TensorFold
    if ($LASTEXITCODE -ne 0) { Stop-Here '6-smoke' }

    $sw.Stop()
    Write-Host ''
    Write-Host ("ENGINE OK ({0:N1} min)" -f $sw.Elapsed.TotalMinutes) -ForegroundColor Green
}

# ---- recipe --------------------------------------------------------------
if ($chosen -eq 'all' -or $chosen -eq 'recipe') {
    & (Join-Path $recipeSteps '1-install-ps1.ps1') -Recipe $Recipe -ModelPath $cfg.ModelPath
    if ($LASTEXITCODE -ne 0) { Stop-Here 'recipe\1-install-ps1' }
}

Write-Host ''
Write-Host 'MIGRATION COMPLETE' -ForegroundColor Green
Write-Host ("  engine: " + (Join-Path $TensorFold 'build\native\bin\tensorfold-native.exe'))
Write-Host ("  recipe: " + $Recipe)
Write-Host ''
Write-Host '  Next: put the checkpoint where start.ps1 expects it (MODEL_PATH in the recipe .env), then:' -ForegroundColor DarkGray
Write-Host ("        cd `"$Recipe`"; .\start.ps1") -ForegroundColor DarkGray
exit 0
