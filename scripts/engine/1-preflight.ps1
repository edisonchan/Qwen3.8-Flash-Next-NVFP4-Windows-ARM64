#Requires -Version 5.1
<#
  Engine 1/6 -- environment preflight for the TensorFold v1.1.4 Windows ARM64 build.

  Verifies every prerequisite the build needs before anything is cloned, so a missing
  component fails in seconds instead of after a six-minute nvcc run.

  No path is baked in: they come from scripts\migration.config.ps1 (saved answers, else detection).
  A parameter you pass explicitly still wins.

  Usage:
    powershell -ExecutionPolicy Bypass -File scripts\engine\1-preflight.ps1
    powershell -ExecutionPolicy Bypass -File scripts\engine\1-preflight.ps1 -Zig "E:\tools\zig.exe" -Root "E:\ai"
#>
param(
    [string]$Zig    = '',
    [string]$Cuda   = '',
    [string]$Vcvars = '',
    [string]$Root   = '',
    [string]$Python = '',
    [double]$MinFreeGiB = 25
)

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'migration.config.ps1')
$cfg = Get-MigConfig -Quiet
if (-not $Zig)    { $Zig    = $cfg.Zig }
if (-not $Cuda)   { $Cuda   = $cfg.Cuda }
if (-not $Vcvars) { $Vcvars = $cfg.Vcvars }
if (-not $Root)   { $Root   = $cfg.Root }
if (-not $Python) { $Python = $cfg.Python }

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
Write-Host "  settings from: $($cfg.Source)  ($(Get-MigConfigPath))" -ForegroundColor DarkGray
Write-Host "  root:    $Root"
Write-Host "  python:  $Python"
Write-Host "  zig:     $Zig"
Write-Host "  cuda:    $Cuda"
Write-Host "  vcvars:  $Vcvars"
Write-Host ''

# ---- 1. OS / architecture -------------------------------------------------
# Under an emulated x64 shell RuntimeInformation reports the *process* view (X64), and
# Win32_OperatingSystem.OSArchitecture is a localized string ("ARM 64 位处理器"), so read the
# numeric processor architecture instead: 12 = ARM64, 9 = x64.
$cpuCode = $null
try { $cpuCode = [int](Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1).Architecture } catch { }
if ($null -ne $cpuCode) {
    $archName = 'code ' + $cpuCode
    if ($cpuCode -eq 12) { $archName = 'ARM64' }
    elseif ($cpuCode -eq 9) { $archName = 'x64' }
    elseif ($cpuCode -eq 0) { $archName = 'x86' }
    if ($cpuCode -eq 12) { Ok "OS architecture: $archName" }
    else { Bad "OS architecture is $archName, not ARM64" 'This recipe builds aarch64-windows binaries; an x64 host must cross-compile differently.' }
} else {
    $arch = [string][System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
    if ($arch -eq 'Arm64') { Ok "OS architecture: $arch (reported by .NET)" }
    else { Bad "OS architecture is $arch, not Arm64" 'This recipe builds aarch64-windows binaries; an x64 host must cross-compile differently.' }
}

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

# ---- 6. python (the vision helper's venv is built from this interpreter) --
$pyTest = Test-MigPython $Python
if ($pyTest.State -eq 'ok')      { Ok $pyTest.Text }
elseif ($pyTest.State -eq 'bad') { Warn2 ($pyTest.Text + ' -- text-only serving works with VISION=0') }
else                             { Warn2 ('python: ' + $pyTest.Text + ' -- needed only for --vision, skip engine\4-venv.ps1 with VISION=0') }

# ---- 7. GPU --------------------------------------------------------------
$smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
if ($smi) {
    # GB10 boxes answer with more than one row here (the NPU shows up as a device too, memory [N/A]),
    # so keep the first row that actually reports a memory size.
    $run = Invoke-MigNative -FilePath $smi.Source -Arguments @('--query-gpu=name,memory.total', '--format=csv,noheader')
    $rows = @(($run.Out -split "`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '\[N/A\]' })
    if ($rows.Count -gt 0) { Ok "GPU: $($rows[0])" }
    else { Warn2 "nvidia-smi gave no GPU row (exit $($run.Code)); the engine needs a CUDA device to serve" }
} else {
    Warn2 'nvidia-smi not on PATH: the build still works, but the engine needs a CUDA device to serve'
}

# ---- 8. disk -------------------------------------------------------------
$qual = Split-Path -Qualifier $Root                      # 'D:'
$driveName = $qual.TrimEnd(':')                          # 'D'
try {
    $free = (Get-PSDrive -Name $driveName).Free / 1GB
    if ($free -ge $MinFreeGiB) { Ok ('free space on {0} {1:N1} GiB' -f $qual, $free) }
    else {
        $hint = 'The sources plus zig caches want ~{0:N0} GiB; the checkpoint is separate (~96 GiB).' -f $MinFreeGiB
        Bad ('only {0:N1} GiB free on {1}' -f $free, $qual) $hint
    }
} catch { Warn2 'could not read free disk space' }

# ---- summary -------------------------------------------------------------
Write-Host ''
if ($script:failed -gt 0) {
    Write-Host ("PREFLIGHT FAILED: {0} blocking problem(s), {1} warning(s)" -f $script:failed, $script:warned) -ForegroundColor Red
    exit 1
}
Write-Host ("PREFLIGHT OK: 0 blocking problems, {0} warning(s)" -f $script:warned) -ForegroundColor Green
exit 0
