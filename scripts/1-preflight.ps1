#Requires -Version 5.1
<#
  Step 1/6 -- environment preflight for the TensorFold v1.1.4 Windows ARM64 build.

  Verifies every prerequisite the build needs before anything is cloned, so a missing
  component fails in seconds instead of after a six-minute nvcc run.

  Usage:
    powershell -ExecutionPolicy Bypass -File scripts\1-preflight.ps1
    powershell -ExecutionPolicy Bypass -File scripts\1-preflight.ps1 -Zig "E:\tools\zig.exe" -Root "E:\ai"
#>
param(
    [string]$Zig    = 'D:\llm\zig-aarch64-windows-0.17.0\zig.exe',
    [string]$Cuda   = 'C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.4',
    [string]$Vcvars = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsall.bat',
    [string]$Root   = 'D:\llm\latest',
    [double]$MinFreeGiB = 25
)

# Native tools (git, nvcc, nvidia-smi) write ordinary progress to stderr, and under 'Stop' PowerShell 5.1
# turns such a line into a terminating NativeCommandError. Stay on 'Continue' and check $LASTEXITCODE.
$ErrorActionPreference = 'Continue'
$script:failed = 0
$script:warned = 0

function Ok   { param([string]$Msg) Write-Host ('  [ OK ] ' + $Msg) -ForegroundColor Green }
function Warn2{ param([string]$Msg) Write-Host ('  [WARN] ' + $Msg) -ForegroundColor Yellow; $script:warned++ }
function Bad  { param([string]$Msg, [string]$Hint)
    Write-Host ('  [FAIL] ' + $Msg) -ForegroundColor Red
    if ($Hint) { Write-Host ('         -> ' + $Hint) -ForegroundColor DarkGray }
    $script:failed++
}

Write-Host ''
Write-Host 'TensorFold v1.1.4 - Windows ARM64 preflight' -ForegroundColor Magenta
Write-Host ''

# ---- 1. OS / architecture -------------------------------------------------
# PROCESSOR_ARCHITECTURE is unreliable under a WOW64 shell; ask the runtime.
$arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
if ($arch -eq 'Arm64') { Ok "OS architecture: $arch" }
else { Bad "OS architecture is $arch, not Arm64" 'This recipe builds aarch64-windows binaries; an x64 host must cross-compile differently.' }

# ---- 2. zig ---------------------------------------------------------------
if (-not (Test-Path $Zig)) {
    Bad "zig not found at $Zig" 'Download zig 0.17.0 aarch64-windows from https://ziglang.org/download/0.17.0/ (sha256 9e8d11661d4ae3bd57702a3832781e23ad151dde5798e16a5ccd503f65234ff8) and pass -Zig <path>.'
} else {
    $zigVer = (& $Zig version 2>&1 | Out-String).Trim()
    if ($zigVer -eq '0.17.0') { Ok "zig version: $zigVer" }
    else { Bad "zig version is '$zigVer', not 0.17.0" 'The tree pins 0.17.0; another version fails on std API changes (mmap, Io.Clock).' }
}

# ---- 3. CUDA toolkit (nvcc, not just the driver) --------------------------
$nvcc = Join-Path $Cuda 'bin\nvcc.exe'
if (-not (Test-Path $nvcc)) {
    Bad "nvcc not found at $nvcc" 'Install the CUDA 13.4 toolkit (not only the display driver) and pass -Cuda <toolkit root>.'
} else {
    $nv = (& $nvcc --version 2>&1 | Out-String)
    if ($nv -match 'release\s+(\d+\.\d+)') {
        $rel = $Matches[1]
        if ($rel -like '13.4*') { Ok "nvcc: $rel" }
        else { Warn2 "nvcc is $rel (the validated toolkit is 13.4)" }
    } else { Warn2 'nvcc --version did not report a release number' }
}

# cuBLAS 13 is what the engine's vision towers and cuBLASLt projections load at run time.
$cublas = Get-ChildItem -Path (Join-Path $Cuda 'bin') -Filter 'cublasLt64_13.dll' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
if ($cublas) { Ok "cuBLASLt: $($cublas.FullName)" }
else { Warn2 'cublasLt64_13.dll not found under the toolkit; --vision would report it missing at load time' }

# ---- 4. MSVC with the ARM64 host/target set ------------------------------
if (-not (Test-Path $Vcvars)) {
    Bad "vcvarsall.bat not found at $Vcvars" 'Install Visual Studio 2022 Build Tools with "Desktop development with C++" and the ARM64 build tools component, then pass -Vcvars <path>.'
} else {
    # Hostarm64\arm64\cl.exe is the compiler nvcc drives for an aarch64 target.
    $cl = Get-ChildItem -Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $Vcvars))) -Filter 'cl.exe' -Recurse -ErrorAction SilentlyContinue |
          Where-Object { $_.FullName -match 'Hostarm64\\arm64\\cl\.exe$' } | Select-Object -First 1
    if ($cl) { Ok "MSVC arm64 cl.exe: $($cl.FullName)" }
    else { Bad 'MSVC ARM64 build tools missing (no Hostarm64\arm64\cl.exe)' 'In the VS Installer add the "MSVC v143 - VS 2022 C++ ARM64 build tools" component.' }
}

# ---- 5. git ---------------------------------------------------------------
$git = Get-Command git -ErrorAction SilentlyContinue
if ($git) { Ok "git: $((& git --version 2>&1 | Out-String).Trim())" }
else { Bad 'git not on PATH' 'Install Git for Windows; both repositories are cloned with it.' }

# ---- 6. python (only the vision helper needs it) -------------------------
$py = Get-Command python -ErrorAction SilentlyContinue
if ($py) {
    $pv = (& python -c "import sys;print('%d.%d.%d' % sys.version_info[:3])" 2>&1 | Out-String).Trim()
    if ($pv -match '^3\.(\d+)\.') {
        $minor = [int]$Matches[1]
        if ($minor -ge 11) { Ok "python: $pv" }
        else { Warn2 "python is $pv (vision needs 3.11 or newer)" }
    } else { Warn2 "could not read the python version ('$pv')" }
} else {
    Warn2 'python not on PATH: fine for text-only serving (VISION=0), required for --vision'
}

# ---- 7. GPU --------------------------------------------------------------
$smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
if ($smi) {
    $name = (& nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>&1 | Out-String).Trim()
    Ok "GPU: $name"
} else {
    Warn2 'nvidia-smi not on PATH: the build still works, but the engine needs a CUDA device to serve'
}

# ---- 8. disk -------------------------------------------------------------
$drive = (Resolve-Path (Split-Path -Qualifier $Root) -ErrorAction SilentlyContinue)
if (-not $drive) { $drive = "$((Split-Path -Qualifier $Root))\" }
try {
    $free = (Get-PSDrive -Name ((Split-Path -Qualifier $Root).TrimEnd(':'))).Free / 1GB
    if ($free -ge $MinFreeGiB) { Ok ('free space on {0}: {1:N1} GiB' -f (Split-Path -Qualifier $Root), $free) }
    else { Bad ('only {0:N1} GiB free on {1}' -f $free, (Split-Path -Qualifier $Root)) "The sources plus zig caches want ~{0:N0} GiB; the checkpoint is separate (~96 GiB)." -f $MinFreeGiB }
} catch { Warn2 'could not read free disk space' }

# ---- summary -------------------------------------------------------------
Write-Host ''
if ($script:failed -gt 0) {
    Write-Host ("PREFLIGHT FAILED: {0} blocking problem(s), {1} warning(s)" -f $script:failed, $script:warned) -ForegroundColor Red
    exit 1
}
Write-Host ("PREFLIGHT OK: 0 blocking problems, {0} warning(s)" -f $script:warned) -ForegroundColor Green
exit 0
