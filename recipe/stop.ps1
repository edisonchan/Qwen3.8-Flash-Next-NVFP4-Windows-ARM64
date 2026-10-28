#Requires -Version 5.1
<#
Stop the server that .\start.ps1 started, freeing its GPU memory. The server gets
STOP_TIMEOUT seconds (default 30) to shut down; requests still running are cut off
(it does not drain them), so stop.ps1 says when there are any.
Windows port of stop.sh: no Docker - the tracked process from start.ps1's pid file is
stopped directly (falling back to any tensorfold-native process from this build).
Usage: .\stop.ps1      Env: PORT, STOP_TIMEOUT (see scripts\config.ps1)
#>
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
$script:SelfName = 'stop.ps1'
. (Join-Path $PSScriptRoot 'scripts\config.ps1')

$timeout = [int](Get-Setting 'STOP_TIMEOUT' 30)
if (-not (Stop-Server -TimeoutSec $timeout)) {
    Log 'no server running: nothing to stop'
    exit 0
}
