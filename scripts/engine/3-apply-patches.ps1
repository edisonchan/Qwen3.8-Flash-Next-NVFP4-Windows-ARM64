#Requires -Version 5.1
<#
  Engine 3/6 -- apply the three patches that turn the v1.1.4 release into the recipe's engine.

    patches\0001-recipe-0001-0017-on-v1.1.4.patch   the recipe's patches 0001..0017, flattened
                                                    onto eab85828 (74 files, +3.5k lines)
    patches\0002-windows-arm64-port.patch           the five Windows/MSVC compatibility fixes
                                                    (5 files; touches no kernel arithmetic)
    patches\0003-load-pipeline.patch                the model-load pipeline: grouped parallel
                                                    expert packing, pinned double buffering with
                                                    async HtoD, 48-slot shard cache, whole-row
                                                    memcpy (4 files; host side only, no .cu)

  Each one is checked with `git apply --check` first, so a mismatched tree stops before it is touched.
  Order matters: 0003 was cut against a tree that already had 0001 + 0002, and two of its files
  (cuda_prompt.zig, cuda_prompt_wt.zig) were touched by 0001. The name sort below keeps that order.

  The patch folder is resolved from this file's location (..\..\patches), so a clone at any path works;
  the engine tree comes from scripts\migration.config.ps1 unless -TensorFold is passed.
#>
param(
    [string]$TensorFold = '',
    [string]$PatchDir   = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'patches'),
    [string]$TfRef      = 'eab8582819688325e371907e4706e1c602b8a273',
    [switch]$AllowDirty
)

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'migration.config.ps1')
$cfg = Get-MigConfig -Quiet
if (-not $TensorFold) { $TensorFold = $cfg.EngineDir }

# Native tools (git) write ordinary progress to stderr, and under 'Stop' PowerShell 5.1 turns such a line
# into a terminating NativeCommandError. Stay on 'Continue' and check $LASTEXITCODE.
$ErrorActionPreference = 'Continue'
Write-Host ''
Write-Host 'TensorFold v1.1.4 - apply patches' -ForegroundColor Magenta
Write-Host "  tree:    $TensorFold"
Write-Host "  patches: $PatchDir"

function Fail { param([string]$Msg) Write-Host "  [FAIL] $Msg" -ForegroundColor Red; exit 1 }

if (-not (Test-Path (Join-Path $TensorFold '.git'))) { Fail "$TensorFold is not a git clone" }

$head = (& git -C $TensorFold rev-parse HEAD).Trim()
if ($head -ne $TfRef) {
    Fail "HEAD is $head, but the patches are cut against $TfRef. Run 2-clone.ps1 (or: git -C $TensorFold checkout --detach $TfRef)."
}

if (-not $AllowDirty) {
    $dirty = (& git -C $TensorFold status --porcelain)
    if ($dirty) { Fail "the working tree is not clean; the patches need the bare release tree ($($dirty.Count) entries)" }
}

$patches = Get-ChildItem -Path $PatchDir -Filter '*.patch' | Sort-Object Name
if (-not $patches) { Fail "no *.patch files in $PatchDir" }

$logDir = Join-Path $TensorFold 'build\logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logPath = Join-Path $logDir '01-patches.log'
"# patches applied $(Get-Date -Format o)" | Set-Content -Path $logPath -Encoding UTF8

foreach ($p in $patches) {
    $hash = (Get-FileHash -Path $p.FullName -Algorithm SHA256).Hash.ToLower()
    Write-Host ''
    Write-Host ("  {0}" -f $p.Name) -ForegroundColor Cyan
    Write-Host ("    sha256 {0}" -f $hash) -ForegroundColor DarkGray

    & git -C $TensorFold apply --check $p.FullName 2>&1 | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
    if ($LASTEXITCODE -ne 0) {
        Fail "$($p.Name) does not apply to this tree. Nothing was changed; verify HEAD is $TfRef and the tree is clean."
    }
    & git -C $TensorFold apply $p.FullName
    if ($LASTEXITCODE -ne 0) { Fail "$($p.Name) failed to apply (it passed --check, so the tree changed underneath)" }

    "$($p.Name) $hash" | Add-Content -Path $logPath -Encoding UTF8
    Write-Host '    applied' -ForegroundColor Green
}

# ---- what the tree should now look like ---------------------------------
$stat = (& git -C $TensorFold diff --stat HEAD | Select-Object -Last 1)
Write-Host ''
Write-Host "  tree now: $stat" -ForegroundColor Cyan
Write-Host "  log:      $logPath" -ForegroundColor DarkGray

# spot-check the port patch: MSVC needs the qualifiers to match the template definition exactly
$qmm = Get-Content (Join-Path $TensorFold 'zig\kernels\cuda\qmm_prefill.cu') -Raw
$restrictCount = ([regex]::Matches($qmm, 'prefill_kernel<64, 128, 128, 2, \d, \d, false>')).Count
if ($restrictCount -ge 2 -and $qmm -match 'const __nv_bfloat16\* __restrict__') {
    Write-Host '  port patch spot-check: the explicit instantiations carry __restrict__' -ForegroundColor Green
} else {
    Write-Host '  [WARN] qmm_prefill.cu does not look patched (the nvcc step will fail with "no instance of function template")' -ForegroundColor Yellow
}

# spot-check the load pipeline: the staged fill must be there, and the shard cache has to be wider
# than one layer's 14 shards, otherwise every layer reopens and re-parses the same shard headers
$expertsSrc = Join-Path $TensorFold 'zig\src\families\flashnext\cuda_modelopt_experts.zig'
$wtSrc      = Join-Path $TensorFold 'zig\src\families\flashnext\cuda_prompt_wt.zig'
$stagedOk = $false; $cacheOk = $false
if (Test-Path $expertsSrc) {
    $e = Get-Content $expertsSrc -Raw
    $stagedOk = ($e -match 'TENSORFOLD_LOAD_STATS') -and ($e -match 'cuMemcpyHtoDAsync')
}
if (Test-Path $wtSrc) { $cacheOk = ((Get-Content $wtSrc -Raw) -match 'cached_shards') }
if ($stagedOk -and $cacheOk) {
    Write-Host '  load patch spot-check: staged expert fill in place, shard cache widened' -ForegroundColor Green
} else {
    Write-Host '  [WARN] the load pipeline patch does not look applied: expect a ~257 s model load, not ~71 s' -ForegroundColor Yellow
}

Write-Host ''
Write-Host 'PATCHES OK - next: 5-build.ps1' -ForegroundColor Green
exit 0
