#Requires -Version 5.1
<#
  Engine 4/6 -- the vision helper's virtual environment, created inside the recipe folder.

  The native engine serves text on its own. It only spawns Python when --vision is on, and then
  it runs tensorfold.vision.native_helper from <recipe>\venv (TENSORFOLD_VISION_PYTHON, set by the
  recipe's start.ps1). Skip this whole step if you serve with VISION=0.

  Three installs, in this order -- the order matters:

    1. torch, torchvision, torchaudio, with --pre from NVIDIA's out-of-tree wheel index.
       On the recipe's own platform these arrive inside the nvcr.io/nvidia/pytorch base image;
       there is no such image on Windows, so they are installed here. --only-binary=:all: keeps
       pip from trying to compile them (there is no source build that would work here).

    2. tensorfold[vision] at v0.6.6. At v1.1.4 the tree's own setup.py refuses to install
       ("installs as a native binary"), so the Python package comes from the v0.6.6 tag, not
       from the checkout. It is installed second so that step 1 has already satisfied torch:
       otherwise pip pulls a plain PyPI torch wheel in as a dependency.

    3. The probe start.ps1 runs before it enables vision: the import must succeed.

  Paths come from scripts\migration.config.ps1 (the venv always lives in the recipe folder,
  because that is where start.ps1 looks for it). Override any of them with a parameter.
#>
param(
    [string]$Recipe     = '',
    [string]$VenvDir    = '',
    [string]$Python     = '',
    [string]$TorchIndex = 'https://pypi.nvidia.com/nvtorch_oot_nightly',
    [string]$Source     = 'tensorfold[vision] @ git+https://github.com/ashhart/TensorFold.git@v0.6.6',
    [switch]$SkipTorch,
    [switch]$Recreate
)

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'migration.config.ps1')
$cfg = Get-MigConfig -Quiet
if (-not $Recipe) { $Recipe = $cfg.RecipeDir }
if (-not $Python) { $Python = $cfg.Python }
if (-not $VenvDir) { $VenvDir = Join-Path $Recipe 'venv' }

# Native tools (python, pip) write ordinary progress to stderr, and under 'Stop' PowerShell 5.1 turns such
# a line into a terminating NativeCommandError. Stay on 'Continue' and check $LASTEXITCODE.
$ErrorActionPreference = 'Continue'

Write-Host ''
Write-Host 'TensorFold v1.1.4 - vision venv' -ForegroundColor Magenta
Write-Host "  recipe: $Recipe"
Write-Host "  venv:   $VenvDir"
Write-Host "  python: $Python"

function Fail { param([string]$Msg) Write-Host "  [FAIL] $Msg" -ForegroundColor Red; exit 1 }
function Step { param([string]$Msg) Write-Host "  $Msg" -ForegroundColor DarkGray }

if (-not (Test-Path (Join-Path $Recipe 'scripts\config.ps1'))) {
    Fail "$Recipe does not look like the recipe clone (no scripts\config.ps1). Run engine\2-clone.ps1 first, or pass -Recipe."
}

# ---- python ---------------------------------------------------------------
$pyTest = Test-MigPython $Python
if ($pyTest.State -eq 'missing') { Fail "no usable python: $($pyTest.Text). Install Python 3.11+ for ARM64, or serve with VISION=0." }
if ($pyTest.State -eq 'bad')     { Fail "$($pyTest.Text)" }
Write-Host "  $($pyTest.Text)" -ForegroundColor DarkGray

# ---- venv -----------------------------------------------------------------
if ($Recreate -and (Test-Path $VenvDir)) {
    Write-Host "  removing the existing venv at $VenvDir" -ForegroundColor Yellow
    Remove-Item -Path $VenvDir -Recurse -Force -ErrorAction SilentlyContinue
}
$py = Join-Path $VenvDir 'Scripts\python.exe'
if (-not (Test-Path $py)) {
    Step "creating the venv at $VenvDir"
    & $Python -m venv $VenvDir
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $py)) { Fail 'python -m venv failed' }
} else {
    Step 'reusing the existing venv'
}

Step 'upgrading pip'
& $py -m pip install --upgrade pip --quiet
if ($LASTEXITCODE -ne 0) { Write-Host '  [WARN] pip upgrade failed; continuing' -ForegroundColor Yellow }

# ---- 1. torch, from NVIDIA's out-of-tree index ----------------------------
if ($SkipTorch) {
    Write-Host '  (torch install skipped: -SkipTorch)' -ForegroundColor DarkGray
} else {
    Step "installing torch, torchvision, torchaudio --pre from $TorchIndex"
    Write-Host '        a few GB; expect several minutes' -ForegroundColor DarkGray
    & $py -m pip install --pre --upgrade --only-binary=:all: --extra-index-url $TorchIndex torch torchvision torchaudio
    if ($LASTEXITCODE -ne 0) {
        Fail ("torch install failed (pip exit $LASTEXITCODE). Check access to $TorchIndex and re-run; " +
              'if a nightly is broken, pin a known-good one with pip in the same venv.')
    }
}

# ---- 2. tensorfold[vision] ------------------------------------------------
Step "installing $Source (pulls transformers, Pillow and av)"
& $py -m pip install $Source
if ($LASTEXITCODE -ne 0) { Fail 'pip install of tensorfold[vision] failed. Check access to github.com and PyPI, then re-run.' }

# ---- 3. what start.ps1 checks --------------------------------------------
Step 'probing torch'
$torchProbe = ((& $py -c "import torch;print(torch.__version__);print(torch.version.cuda or 'no-cuda');print(torch.cuda.is_available())" 2>&1 | Out-String) -replace "`r", "").Trim()
if ($LASTEXITCODE -ne 0) { Fail "torch does not import in the venv: $torchProbe" }
$lines = $torchProbe -split "`r?`n"
Write-Host ("  torch:   " + $lines[0]) -ForegroundColor Cyan
if ($lines.Count -ge 2) { Write-Host ("  cuda:    " + $lines[1]) -ForegroundColor Cyan }
if ($lines.Count -ge 3 -and $lines[2].Trim() -eq 'False') {
    Write-Host '  [WARN] torch.cuda.is_available() is False: vision would fall back to the CPU, or fail if the wheel has no CUDA' -ForegroundColor Yellow
}

Step 'probing tensorfold.vision.native_helper'
& $py -c "import importlib.util,sys; sys.exit(0 if importlib.util.find_spec('tensorfold.vision.native_helper') else 1)"
if ($LASTEXITCODE -ne 0) { Fail 'tensorfold.vision.native_helper is missing after the install' }

$tv = (& $py -c "import tensorfold, sys; print(getattr(tensorfold,'__version__','?'))" 2>&1 | Out-String).Trim()

Write-Host ''
Write-Host "  tensorfold: $tv" -ForegroundColor Cyan
Write-Host "  python:     $py" -ForegroundColor Cyan
Write-Host "  venv:       $VenvDir  (start.ps1 picks it up as TENSORFOLD_VISION_PYTHON)" -ForegroundColor Cyan
Write-Host ''
Write-Host 'VENV OK' -ForegroundColor Green
exit 0
