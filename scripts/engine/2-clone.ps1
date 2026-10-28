#Requires -Version 5.1
<#
  Engine 2/6 -- clone both repositories and pin each to the commit the patch series describes.

  Two pins, both from VERSIONS.md (overridable here or in .migration.local.json):
    engine  -TfRef     eab8582819688325e371907e4706e1c602b8a273   (tag v1.1.4, the recipe's TF_REF)
    recipe  -RecipeRef fd3f43e11238553685ebb68b6d8ab2b112818e3c   (the commit 0001 was cut from)

  Layout is fixed by the recipe: scripts\config.ps1 looks for the engine at
  '<parent of the recipe>\TensorFold\build\native\bin\tensorfold-native.exe', so the two
  clones must be siblings and the engine clone must be named exactly 'TensorFold'.
  Root comes from scripts\migration.config.ps1 -- nothing here assumes D:\llm\latest.
#>
param(
    [string]$Root       = '',
    [string]$RecipeRepo = 'https://github.com/MiaAI-Lab/Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold',
    [string]$TfRepo     = 'https://github.com/ashhart/TensorFold',
    [string]$TfRef      = 'eab8582819688325e371907e4706e1c602b8a273',   # v1.1.4, see VERSIONS.md
    [string]$RecipeRef  = 'fd3f43e11238553685ebb68b6d8ab2b112818e3c',   # the commit patch 0001 describes
                                                                        # (pass '' to follow the recipe's main)
    [switch]$Force
)

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'migration.config.ps1')
$cfg = Get-MigConfig -Quiet
if (-not $Root) { $Root = $cfg.Root }

# Native tools (git) write ordinary progress to stderr, and under 'Stop' PowerShell 5.1 turns such a line
# into a terminating NativeCommandError. Stay on 'Continue' and check $LASTEXITCODE.
$ErrorActionPreference = 'Continue'
$RecipeDir = Join-Path $Root 'Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold'
$TfDir     = Join-Path $Root 'TensorFold'

Write-Host ''
Write-Host 'TensorFold v1.1.4 - clone' -ForegroundColor Magenta
Write-Host "  root: $Root"

function Fail { param([string]$Msg) Write-Host "  [FAIL] $Msg" -ForegroundColor Red; exit 1 }
function Step { param([string]$Msg) Write-Host "  $Msg" -ForegroundColor DarkGray }

foreach ($p in @($RecipeDir, $TfDir)) {
    if ((Test-Path $p) -and -not $Force) {
        Fail "$p already exists. Move it away, or pass -Force to reuse it (its own git state is kept)."
    }
}
if (-not (Test-Path $Root)) { New-Item -ItemType Directory -Force -Path $Root | Out-Null }

# ---- recipe --------------------------------------------------------------
if (-not (Test-Path (Join-Path $RecipeDir '.git'))) {
    Step "cloning the recipe into $RecipeDir"
    & git clone $RecipeRepo $RecipeDir
    if ($LASTEXITCODE -ne 0) { Fail 'git clone of the recipe failed' }
} else { Step "reusing the recipe clone at $RecipeDir" }
if ($RecipeRef) {
    & git -C $RecipeDir fetch --all --quiet
    & git -C $RecipeDir checkout $RecipeRef --quiet
    if ($LASTEXITCODE -ne 0) { Fail "the recipe has no commit $RecipeRef" }
    # The recipe keeps moving; patch 0001 describes its patches/ directory at the pin, nothing later.
    $ahead = (& git -C $RecipeDir rev-list --count "$RecipeRef..origin/main" 2>$null)
    if ($LASTEXITCODE -eq 0 -and $ahead -and [int]$ahead -gt 0) {
        Write-Host "  [WARN] the recipe's main is $ahead commit(s) past the pin ($($RecipeRef.Substring(0,7))); 0001 describes the pinned commit only (VERSIONS.md)." -ForegroundColor Yellow
    }
}
$recipeCommit = (& git -C $RecipeDir rev-parse HEAD).Trim()

# ---- engine --------------------------------------------------------------
if (-not (Test-Path (Join-Path $TfDir '.git'))) {
    Step "cloning TensorFold into $TfDir"
    & git clone $TfRepo $TfDir
    if ($LASTEXITCODE -ne 0) { Fail 'git clone of TensorFold failed' }
} else { Step "reusing the TensorFold clone at $TfDir" }

Step "checking out $TfRef"
& git -C $TfDir checkout --detach $TfRef --quiet
if ($LASTEXITCODE -ne 0) { Fail "TensorFold has no commit $TfRef (is this a shallow clone? clone it in full)" }
$tfCommit = (& git -C $TfDir rev-parse HEAD).Trim()
if ($tfCommit -ne $TfRef) { Fail "TensorFold HEAD is $tfCommit, expected $TfRef" }

# the tree must be pristine: the patches are applied on top of exactly this commit
$dirty = (& git -C $TfDir status --porcelain)
if ($dirty) {
    Write-Host '  [WARN] the TensorFold working tree already has changes; the patch step needs the release tree as cloned.' -ForegroundColor Yellow
}

# ---- manifest ------------------------------------------------------------
$logDir = Join-Path $TfDir 'build\logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$drive  = (Split-Path -Qualifier $TfDir).TrimEnd(':')
$freeGB = [math]::Round((Get-PSDrive -Name $drive).Free / 1GB, 1)
$manifest = [ordered]@{
    created_utc   = (Get-Date).ToUniversalTime().ToString('o')
    host          = $env:COMPUTERNAME
    os_arch       = [string][System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
    recipe_repo   = $RecipeRepo
    recipe_pin    = $RecipeRef
    recipe_commit = $recipeCommit
    tf_repo       = $TfRepo
    tf_pin        = $TfRef
    tf_commit     = $tfCommit
    free_gib      = $freeGB
    versions_doc  = 'VERSIONS.md'
}
$manifestPath = Join-Path $logDir '00-migration-manifest.json'
$manifest | ConvertTo-Json | Set-Content -Path $manifestPath -Encoding UTF8

Write-Host ''
Write-Host '  recipe:  ' -NoNewline; Write-Host $recipeCommit -ForegroundColor Cyan
Write-Host '  engine:  ' -NoNewline; Write-Host $tfCommit -ForegroundColor Cyan
Write-Host "  manifest: $manifestPath" -ForegroundColor DarkGray
Write-Host ''
Write-Host 'CLONE OK' -ForegroundColor Green
exit 0
