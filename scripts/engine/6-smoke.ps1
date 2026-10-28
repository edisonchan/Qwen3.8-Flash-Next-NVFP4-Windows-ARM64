#Requires -Version 5.1
<#
  Engine 6/6 -- smoke tests. None of them loads a checkpoint: no model, no GPU memory, no port.

    1. tensorfold-native --help                 the binary starts and prints its usage
    2. tensorfold-native capabilities --json    the build carries the expected version and backend
    3. tf-cuda-test info                        the CUDA driver, the device and the embedded kernels

  A failing check here means the build is wrong; a passing one does not mean a checkpoint will
  load (that is start.ps1's job, and it needs the model on disk).

  The engine tree comes from scripts\migration.config.ps1; an explicit -TensorFold wins.
#>
param(
    [string]$TensorFold = '',
    [string]$Expect     = '1.1.4',
    [string]$ExpectChip = 'nvidia-sm121'
)

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'migration.config.ps1')
$cfg = Get-MigConfig -Quiet
if (-not $TensorFold) { $TensorFold = $cfg.EngineDir }

# tf-cuda-test prints its result on stderr: under 'Stop' PowerShell 5.1 would abort the script with a
# NativeCommandError. Stay on 'Continue' and judge by the text and $LASTEXITCODE.
$ErrorActionPreference = 'Continue'
Write-Host ''
Write-Host 'TensorFold v1.1.4 - smoke' -ForegroundColor Magenta

$exe  = Join-Path $TensorFold 'build\native\bin\tensorfold-native.exe'
$test = Join-Path $TensorFold 'build\bin\tf-cuda-test.exe'
$failed = 0
function Bad { param([string]$Msg) Write-Host "  [FAIL] $Msg" -ForegroundColor Red; $script:failed++ }
function Ok  { param([string]$Msg) Write-Host "  [ OK ] $Msg" -ForegroundColor Green }

if (-not (Test-Path $exe))  { Bad "missing $exe"; exit 1 }
if (-not (Test-Path $test)) { Bad "missing $test"; exit 1 }

# 1. usage -----------------------------------------------------------------
# --help exits 0 or 2 depending on the subcommand table; what matters is that it printed usage.
$run = Invoke-MigNative -FilePath $exe -Arguments @('--help')
$help = $run.Out + $run.Err
if ($help -match 'usage: tensorfold-native') { Ok '--help prints the usage line' }
else { Bad "--help did not print a usage line: $($help.Substring(0, [Math]::Min(120, $help.Length)))" }

# 2. capabilities ----------------------------------------------------------
$run = Invoke-MigNative -FilePath $exe -Arguments @('capabilities', '--json')
$caps = $run.Out + $run.Err
if ($caps -match '"version":\s*"([^"]+)"') {
    $v = $Matches[1]
    if ($v -eq $Expect) { Ok "capabilities: version $v" } else { Bad "capabilities: version $v, expected $Expect" }
} else { Bad 'capabilities: no version field' }
if ($caps -match '"chip":\s*"([^"]+)"') {
    $chip = $Matches[1]
    if ($chip -eq $ExpectChip) { Ok "capabilities: chip $chip" } else { Bad "capabilities: chip $chip, expected $ExpectChip" }
} else { Bad 'capabilities: no chip field' }
if ($caps -match '"backends":\s*\[([^\]]*)\]') {
    $bk = $Matches[1]
    if ($bk -match 'cuda') { Ok "capabilities: backends $bk" } else { Bad "capabilities: no cuda backend ($bk)" }
}

# 3. device and kernels ----------------------------------------------------
# tf-cuda-test prints its result line on stderr; Invoke-MigNative reads both streams as raw text
# (PowerShell's own 2>&1 would wrap the line at the host width and add NativeCommandError noise).
$run = Invoke-MigNative -FilePath $test -Arguments @('info')
$info = $run.Out + "`n" + $run.Err
if ($info -match 'RESULT\s+(.*)') {
    $line = $Matches[1].Trim()
    Write-Host "  device: $line" -ForegroundColor DarkGray
    if ($info -match 'sm_121') { Ok 'tf-cuda-test: sm_121 device' } else { Bad 'tf-cuda-test: no sm_121 in the device line' }
    if ($info -match 'kernels embedded true') { Ok 'tf-cuda-test: kernels embedded' }
    elseif ($info -match 'kernels embedded false') {
        Write-Host '  [WARN] kernels are not embedded: this exe needs a Triton AOT kernel set (build\kernels\sm121) at load time' -ForegroundColor Yellow
    }
} else { Bad "tf-cuda-test print no RESULT line: $($info.Substring(0, [Math]::Min(160, $info.Length)))" }

Write-Host ''
if ($failed -gt 0) { Write-Host "SMOKE FAILED: $failed check(s)" -ForegroundColor Red; exit 1 }
Write-Host 'SMOKE OK' -ForegroundColor Green
exit 0
