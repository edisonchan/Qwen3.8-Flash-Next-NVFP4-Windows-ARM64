#Requires -Version 5.1
<#
  Step 4/6 -- the vision helper's virtual environment (optional).

  The native engine serves text on its own. It only spawns Python when --vision is on, and
  then it runs tensorfold.vision.native_helper from this venv (TENSORFOLD_VISION_PYTHON).
  Skip this step entirely if you serve with VISION=0.

  The Python engine is pinned at v0.6.6: at v1.1.4 the tree's own setup.py refuses to install
  ("installs as a native binary"), so the venv is built from the v0.6.6 tag, not the checkout.
#>
param(
    [string]$Recipe  = 'D://llm//latest//Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold',
    [string]$VenvDir = '',
    [string]$Python  = '',                # empty: 'python' on PATH
    [string]$Source  = 'tensorfold[vision] @ git+https://github.com/ashhart/TensorFold.git@v0.6.6'
)

# Native tools (python, pip) write ordinary progress to stderr, and under 'Stop' PowerShell 5.1 turns such
# a line into a terminating NativeCommandError. Stay on 'Continue' and check $LASTEXITCODE.
$ErrorActionPreference = 'Continue'
if (-not $VenvDir) { $VenvDir = Join-Path $Recipe 'venv' }
Write-Host ''
Write-Host 'TensorFold v1.1.4 - vision venv' -ForegroundColor Magenta
Write-Host "  venv:   $VenvDir"
Write-Host "  source: $Source"

function Fail { param([string]$Msg) Write-Host "  [FAIL] $Msg" -ForegroundColor Red; exit 1 }

if (-not $Python) { $Python = 'python' }
$ver = (& $Python -c "import sys;print('%d.%d.%d' % sys.version_info[:3])" 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0) { Fail "no usable python ('$Python'); install Python 3.11+ for arm64, or use VISION=0" }
Write-Host "  python: $ver ($Python)" -ForegroundColor DarkGray
if ($ver -notmatch '^3\.(1[1-9]|[2-9]\d)\.') { Fail "python $ver is too old; tensorfold needs 3.11 or newer" }

$py = Join-Path $VenvDir 'Scripts\python.exe'
if (-not (Test-Path $py)) {
    Write-Host '  creating the venv' -ForegroundColor DarkGray
    & $Python -m venv $VenvDir
    if ($LASTEXITCODE -ne 0) { Fail 'python -m venv failed' }
} else {
    Write-Host '  reusing the existing venv' -ForegroundColor DarkGray
}

Write-Host '  upgrading pip' -ForegroundColor DarkGray
& $py -m pip install --upgrade pip --quiet
if ($LASTEXITCODE -ne 0) { Write-Host '  [WARN] pip upgrade failed; continuing' -ForegroundColor Yellow }

Write-Host "  installing $Source (this pulls Pillow, transformers and av; a few minutes)" -ForegroundColor DarkGray
& $py -m pip install $Source
if ($LASTEXITCODE -ne 0) { Fail 'pip install failed. Check network access to github.com and PyPI, then re-run.' }

# The engine's step 1 runs exactly this probe; a venv that fails it makes --vision abort the start.
& $py -c "import importlib.util,sys; sys.exit(0 if importlib.util.find_spec('tensorfold.vision.native_helper') else 1)"
if ($LASTEXITCODE -ne 0) { Fail 'tensorfold.vision.native_helper is missing after the install' }

$tv = (& $py -c "import tensorfold, sys; print(getattr(tensorfold,'__version__','?'))" 2>&1 | Out-String).Trim()
Write-Host ''
Write-Host "  tensorfold: $tv" -ForegroundColor Cyan
Write-Host "  python:     $py" -ForegroundColor Cyan
Write-Host ''
Write-Host 'VENV OK' -ForegroundColor Green
exit 0
