#Requires -Version 5.1
<#
  Step 5/6 -- build tensorfold-native.exe for aarch64-windows.

  The build must run inside a cmd session that has loaded vcvarsall.bat arm64: nvcc locates
  the MSVC compiler for the target through that environment, and a PowerShell `call` cannot
  change its own parent's environment. Without it every .cu fails with "process exited with
  code 1" and nothing else - the classic six-minute dead end.

  All caches and temporaries are redirected under <TensorFold>\build, so nothing lands in the
  user profile and a re-run is reproducible.
#>
param(
    [string]$TensorFold = 'D://llm//latest//TensorFold',
    [string]$Zig        = 'D:\llm\zig-aarch64-windows-0.17.0\zig.exe',
    [string]$Cuda       = 'C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.4',
    [string]$Vcvars     = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsall.bat',
    [int]$Sm            = 121,
    [string]$LogName    = '05-build.log'
)

# cmd/nvcc write ordinary progress to stderr, and under 'Stop' PowerShell 5.1 turns such a line into a
# terminating NativeCommandError. Stay on 'Continue' and check $LASTEXITCODE.
$ErrorActionPreference = 'Continue'
Write-Host ''
Write-Host 'TensorFold v1.1.4 - build' -ForegroundColor Magenta
Write-Host "  tree: $TensorFold"
Write-Host "  sm:   $Sm"

function Fail { param([string]$Msg) Write-Host "  [FAIL] $Msg" -ForegroundColor Red; exit 1 }

foreach ($p in @($TensorFold, $Zig, $Vcvars)) { if (-not (Test-Path $p)) { Fail "missing: $p" } }
$nvcc = Join-Path $Cuda 'bin\nvcc.exe'
if (-not (Test-Path $nvcc)) { Fail "missing nvcc: $nvcc" }

$buildDir = Join-Path $TensorFold 'build'
$logDir   = Join-Path $buildDir 'logs'
foreach ($d in @($logDir, (Join-Path $buildDir '.zig-cache'), (Join-Path $buildDir 'zig-cache-global'), (Join-Path $buildDir 'tmp'))) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}
$log = Join-Path $logDir $LogName
$bat = Join-Path $buildDir 'build_now.bat'

# cmd reads the .bat with the console code page; chcp 65001 keeps UTF-8 paths intact.
$batText = @"
@echo off
chcp 65001 >nul
call "$Vcvars" arm64
if errorlevel 1 exit /b 3
set ZIG_LOCAL_CACHE_DIR=$buildDir\.zig-cache
set ZIG_GLOBAL_CACHE_DIR=$buildDir\zig-cache-global
set TMP=$buildDir\tmp
set TEMP=$buildDir\tmp
cd /d "$TensorFold"
"$Zig" build native install -Dsm=$Sm -Dnvcc="$nvcc" --prefix build > "$log" 2>&1
echo BUILD_EXIT=%ERRORLEVEL%
exit /b %ERRORLEVEL%
"@
[System.IO.File]::WriteAllText($bat, $batText, (New-Object System.Text.UTF8Encoding($false)))

Write-Host '  compiling (5 to 8 minutes on a Spark; the log is written as it goes)' -ForegroundColor DarkGray
$sw = [System.Diagnostics.Stopwatch]::StartNew()
& cmd.exe /c $bat
$code = $LASTEXITCODE
$sw.Stop()
Write-Host ("  elapsed: {0:N1} min" -f $sw.Elapsed.TotalMinutes) -ForegroundColor DarkGray

if ($code -ne 0) {
    Write-Host ''
    Write-Host "  [FAIL] build exited with $code. The log is ANSI/GBK encoded; read the tail with:" -ForegroundColor Red
    Write-Host "         Get-Content '$log' -Encoding Default -Tail 60" -ForegroundColor DarkGray
    if (Test-Path $log) {
        $tail = Get-Content $log -Encoding Default -Tail 25
        Write-Host '  --- last lines ---' -ForegroundColor DarkGray
        $tail | ForEach-Object { Write-Host "  | $_" -ForegroundColor DarkGray }
    }
    exit 1
}

$exe  = Join-Path $buildDir 'native\bin\tensorfold-native.exe'
$test = Join-Path $buildDir 'bin\tf-cuda-test.exe'
foreach ($a in @($exe, $test)) {
    if (-not (Test-Path $a)) { Fail "the build reported success but $a is missing" }
    $mb = [math]::Round((Get-Item $a).Length / 1MB, 1)
    Write-Host ("  {0}  ({1} MB)" -f $a, $mb) -ForegroundColor Cyan
}

# Anything older than the exe is a stale Triton AOT set: start.ps1 refuses those, but say so here too.
$kern = Join-Path (Split-Path -Parent $PSScriptRoot) '..\..\Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold\build\kernels\sm121\aot.json'
if (Test-Path $kern) {
    if ((Get-Item $kern).LastWriteTimeUtc -lt (Get-Item $exe).LastWriteTimeUtc) {
        Write-Host '  [WARN] build\kernels\sm121\aot.json predates this exe: rename that folder, or start.ps1 will ignore it (it fails with Fp8KvUnsupported)' -ForegroundColor Yellow
    }
}

Write-Host ''
Write-Host 'BUILD OK - next: 6-smoke.ps1' -ForegroundColor Green
exit 0
