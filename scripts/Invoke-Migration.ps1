#Requires -Version 5.1
<#
  Runs steps 1..6 in order, stopping at the first failure.

    powershell -ExecutionPolicy Bypass -File scripts\Invoke-Migration.ps1
    powershell -ExecutionPolicy Bypass -File scripts\Invoke-Migration.ps1 -Root E:\ai -Zig E:\tools\zig.exe
    powershell -ExecutionPolicy Bypass -File scripts\Invoke-Migration.ps1 -SkipVenv     # text only, no vision helper
    powershell -ExecutionPolicy Bypass -File scripts\Invoke-Migration.ps1 -SkipClone    # patches applied already? no: patch step still checks

  Every step is a separate script; run one on its own when you need to inspect its output.

  Both repositories are pinned, not followed (VERSIONS.md):
    engine -TfRef     eab85828 = TensorFold v1.1.4
    recipe -RecipeRef fd3f43e  = the commit the merged recipe patch was cut from
  Pass -RecipeRef '' to follow the recipe's main instead.
#>
param(
    [string]$Root      = 'D:\llm\latest',
    [string]$Zig       = 'D:\llm\zig-aarch64-windows-0.17.0\zig.exe',
    [string]$Cuda      = 'C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.4',
    [string]$Vcvars    = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsall.bat',
    [string]$TfRef     = 'eab8582819688325e371907e4706e1c602b8a273',
    [string]$RecipeRef = 'fd3f43e11238553685ebb68b6d8ab2b112818e3c',
    [int]$Sm           = 121,
    [switch]$SkipPreflight,
    [switch]$SkipVenv,
    [switch]$Force
)

$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
$TensorFold = Join-Path $Root 'TensorFold'
$Recipe     = Join-Path $Root 'Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold'

function Stop-Here { param([string]$Step) Write-Host ''; Write-Host "$Step failed: fix it, then re-run from that step." -ForegroundColor Red; exit 1 }

if (-not $SkipPreflight) {
    & (Join-Path $here '1-preflight.ps1') -Zig $Zig -Cuda $Cuda -Vcvars $Vcvars -Root $Root
    if ($LASTEXITCODE -ne 0) { Stop-Here '1-preflight' }
}

& (Join-Path $here '2-clone.ps1') -Root $Root -TfRef $TfRef -RecipeRef $RecipeRef -Force:$Force
if ($LASTEXITCODE -ne 0) { Stop-Here '2-clone' }

& (Join-Path $here '3-apply-patches.ps1') -TensorFold $TensorFold -TfRef $TfRef
if ($LASTEXITCODE -ne 0) { Stop-Here '3-apply-patches' }

if (-not $SkipVenv) {
    & (Join-Path $here '4-venv.ps1') -Recipe $Recipe
    if ($LASTEXITCODE -ne 0) { Stop-Here '4-venv' }
} else {
    Write-Host ''
    Write-Host '  (vision venv skipped: start the server with VISION=0)' -ForegroundColor DarkGray
}

& (Join-Path $here '5-build.ps1') -TensorFold $TensorFold -Zig $Zig -Cuda $Cuda -Vcvars $Vcvars -Sm $Sm
if ($LASTEXITCODE -ne 0) { Stop-Here '5-build' }

& (Join-Path $here '6-smoke.ps1') -TensorFold $TensorFold
if ($LASTEXITCODE -ne 0) { Stop-Here '6-smoke' }

Write-Host ''
Write-Host 'MIGRATION COMPLETE' -ForegroundColor Green
Write-Host "  engine:  $TensorFold\build\native\bin\tensorfold-native.exe"
Write-Host "  recipe:  $Recipe"
Write-Host ''
Write-Host '  Next: put the checkpoint at the path start.ps1 expects (see SKILL.md, model location), then:' -ForegroundColor DarkGray
Write-Host "        cd `"$Recipe`"; .\start.ps1" -ForegroundColor DarkGray
exit 0
