#Requires -Version 5.1
<#
  Recipe 1/1 -- put the four PowerShell files into the MiaAI-Lab recipe clone.

  This is the only step that touches the recipe, and it changes nothing of the recipe's own
  code: start.ps1 and stop.ps1 are added at the clone root, config.ps1 and banner.ps1 into
  scripts\. The .sh originals, patches\0001..0017, Dockerfile and README stay exactly as
  cloned. After this step `git -C <recipe> status --porcelain` shows new files only, no
  modifications -- which is the check at the end of this script.

  The engine (TensorFold) is not involved here at all; that is scripts\engine\.

  Usage:
    powershell -ExecutionPolicy Bypass -File scripts\recipe\1-install-ps1.ps1
    ... -Recipe D:\ai\Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold -ModelPath E:\model\Qwen3.8-Flash-Next-FP4-Local
#>
param(
    [string]$Recipe    = '',      # empty: the recipe clone from migration.config.ps1
    [string]$Source    = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'recipe'),
    [string]$ModelPath = '',      # empty: leave .env alone; 'none' to skip the MODEL_PATH write
    [switch]$NoEnv,
    [switch]$Force
)

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'migration.config.ps1')
$cfg = Get-MigConfig -Quiet
if (-not $Recipe)    { $Recipe    = $cfg.RecipeDir }
if (-not $ModelPath) { $ModelPath = $cfg.ModelPath }

$ErrorActionPreference = 'Continue'

Write-Host ''
Write-Host 'Qwen3.8-Flash-Next recipe - PowerShell files' -ForegroundColor Magenta
Write-Host "  recipe: $Recipe"
Write-Host "  from:   $Source"

function Fail { param([string]$Msg) Write-Host "  [FAIL] $Msg" -ForegroundColor Red; exit 1 }

if (-not (Test-Path (Join-Path $Recipe '.git'))) {
    Fail "$Recipe is not a git clone of the recipe. Run scripts\engine\2-clone.ps1 first, or pass -Recipe."
}
if (-not (Test-Path $Source)) { Fail "no PowerShell sources at $Source" }

# ---- copy ----------------------------------------------------------------
$map = @(
    @{ File = 'start.ps1';   To = $Recipe },
    @{ File = 'stop.ps1';    To = $Recipe },
    @{ File = 'config.ps1';  To = (Join-Path $Recipe 'scripts') },
    @{ File = 'banner.ps1';  To = (Join-Path $Recipe 'scripts') }
)

$added = 0; $same = 0; $replaced = 0
$envAdded = 0; $envReplaced = 0
foreach ($m in $map) {
    $from = Join-Path $Source $m.File
    if (-not (Test-Path $from)) { Fail "missing source file $from" }
    $to = Join-Path $m.To $m.File

    $equal = $false
    if (Test-Path $to) {
        $a = (Get-FileHash $from -Algorithm SHA256).Hash
        $b = (Get-FileHash $to   -Algorithm SHA256).Hash
        $equal = ($a -eq $b)
    }
    if ($equal) {
        Write-Host ("  same      " + $m.File) -ForegroundColor DarkGray
        $same++
        continue
    }
    if ((Test-Path $to) -and -not $Force) {
        # a locally edited copy is not something to overwrite silently
        Write-Host ("  [WARN]    " + $m.File + " exists and differs; kept it. Pass -Force to overwrite.") -ForegroundColor Yellow
        continue
    }
    $exists = Test-Path $to
    Copy-Item -Path $from -Destination $to -Force
    if ($exists) { Write-Host ("  replaced  " + $m.File) -ForegroundColor Yellow; $replaced++ }
    else { Write-Host ("  added     " + $m.File) -ForegroundColor Green; $added++ }
}

# ---- .env: tell the recipe where the checkpoint is ------------------------
$envFile = Join-Path $Recipe '.env'
if ($NoEnv) {
    Write-Host '  (.env left alone: -NoEnv)' -ForegroundColor DarkGray
} elseif (-not $ModelPath) {
    Write-Host '  (.env left alone: no checkpoint path known; set MODEL_PATH there when you have the weights)' -ForegroundColor DarkGray
} else {
    $line = "MODEL_PATH=$ModelPath"
    $existing = ''
    if (Test-Path $envFile) { $existing = Get-Content $envFile -Raw -ErrorAction SilentlyContinue }
    if ($existing -match '(?m)^\s*MODEL_PATH\s*=') {
        if ($Force) {
            $updated = [regex]::Replace($existing, '(?m)^\s*MODEL_PATH\s*=.*$', $line)
            $updated | Set-Content -Path $envFile -Encoding UTF8 -NoNewline
            Write-Host ("  .env      MODEL_PATH replaced with " + $ModelPath) -ForegroundColor Yellow
            $envReplaced++
        } else {
            Write-Host '  .env      already sets MODEL_PATH; left as is (pass -Force to replace)' -ForegroundColor DarkGray
        }
    } else {
        $prefix = ''
        if ($existing -and -not $existing.EndsWith("`n")) { $prefix = "`r`n" }
        Add-Content -Path $envFile -Value ($prefix + "# added by scripts\recipe\1-install-ps1.ps1" + "`r`n" + $line) -Encoding UTF8
        Write-Host ("  .env      MODEL_PATH=$ModelPath") -ForegroundColor Green
        $envAdded++
    }
}

# ---- the claim: the recipe's own files are untouched ----------------------
Write-Host ''
# plain --porcelain (not -uall): build\ and venv\ would otherwise report thousands of files
$status = @(& git -C $Recipe status --porcelain)
$modified = @($status | Where-Object { $_ -match '^ ?M ' -or $_ -match '^R ' -or $_ -match '^ ?D ' })
$untracked = @($status | Where-Object { $_ -match '^\?\?' })

Write-Host ("  git status: {0} untracked entr{1}, {2} modified" -f $untracked.Count, $(if ($untracked.Count -eq 1) { 'y' } else { 'ies' }), $modified.Count) -ForegroundColor Cyan
if ($untracked.Count -gt 0) {
    $untracked | ForEach-Object { Write-Host ('         ' + $_) -ForegroundColor DarkGray }
}
if ($modified.Count -gt 0) {
    Write-Host '  [WARN] tracked files in the recipe differ from the clone:' -ForegroundColor Yellow
    $modified | ForEach-Object { Write-Host ("         " + $_) -ForegroundColor Yellow }
    Write-Host '         Expected: nothing. The four .ps1 and .env are new files, not edits.' -ForegroundColor Yellow
} else {
    Write-Host '  the recipe itself is unmodified: only new files were added' -ForegroundColor Green
}

# the expected new files, each either untracked or ignored
foreach ($rel in @('start.ps1', 'stop.ps1', 'scripts\config.ps1', 'scripts\banner.ps1', '.env')) {
    $p = Join-Path $Recipe $rel
    if (-not (Test-Path $p)) { continue }
    $tracked = (& git -C $Recipe ls-files --error-unmatch $rel 2>$null)
    if ($LASTEXITCODE -eq 0) {
        Write-Host ("  [WARN] $rel is tracked by the recipe and now differs from the clone") -ForegroundColor Yellow
    }
}

# the copies must at least parse before anyone tries to run them
$parseFail = 0
foreach ($f in @('start.ps1', 'stop.ps1', 'scripts\config.ps1', 'scripts\banner.ps1')) {
    $p = Join-Path $Recipe $f
    if (-not (Test-Path $p)) { continue }
    $t = $null; $e = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$t, [ref]$e)
    if ($e.Count -gt 0) {
        $parseFail++
        Write-Host ("  [FAIL] {0} does not parse: {1}" -f $f, $e[0].Message) -ForegroundColor Red
    }
}
if ($parseFail -gt 0) { exit 1 }

Write-Host ''
Write-Host ("RECIPE PS1 OK: {0} added, {1} replaced, {2} unchanged (.env: {3} written, {4} rewritten)" -f `
    $added, $replaced, $same, $envAdded, $envReplaced) -ForegroundColor Green
Write-Host ("  next: cd `"$Recipe`"; .\start.ps1") -ForegroundColor DarkGray
exit 0
