#Requires -Version 5.1
<#
Serve Qwen3.8 Flash Next (CHECKPOINT=nvfp4 for NVIDIA's QAD FP4 checkpoint, int4 for
azampatti's INT4-AutoRound) with TensorFold's Zig engine on one RTX Spark: launches
tensorfold-native serve on port 8888, waits until the OpenAI API answers, then runs a
smoke test. Stop it with .\stop.ps1. Windows port of start.sh: no Docker - the native
engine runs directly on this host.

Usage: .\start.ps1 [restart] [extra tensorfold-native serve args]
  .\start.ps1                          # up to 5 requests at once, a 262,144-token window, fp8 KV, image and video, MTP drafts
  .\start.ps1 restart                  # stop, then start again
  .\start.ps1 restart -Parallel 2 -Context 131072   (env style: $env:PARALLEL='2'; .\start.ps1 restart)
  $env:CONTEXT='1048576'; .\start.ps1 restart       # YaRN factor 4
  $env:DRAFTS='0'; .\start.ps1 restart              # no MTP drafts (--no-drafts)
  $env:DRY_RUN='1'; .\start.ps1                     # print the serve command and exit
Extra arguments go to tensorfold-native serve after the defaults, so they win.
Settings come from the environment or .\.env (see scripts\config.ps1): CHECKPOINT,
MODEL_PATH, CONTEXT, PARALLEL, MAX_TOKENS, THINKING, DRAFTS, KV_DTYPE, TEMPERATURE,
TOP_P, TOP_K, SERVED_NAME, HOST, PORT, VISION, VISION_URLS, MAX_VIDEOS, WAIT_TIMEOUT,
DRY_RUN, FOREGROUND, MEM_NEED_GIB, NATIVE_BIN, VENV_DIR, STATE_DIR, LOG_DIR
and every TENSORFOLD_* / TF_FLASHNEXT_* variable the engine reads.
#>
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ServeUserArgs = @()
)
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
$script:SelfName = 'start.ps1'
. (Join-Path $PSScriptRoot 'scripts\config.ps1')
. (Join-Path $PSScriptRoot 'scripts\banner.ps1')

# usage prints this file's leading <# ... #> comment block, like start.sh does with awk
function Usage {
    $path = Join-Path $PSScriptRoot 'start.ps1'
    $out = @(); $inBlock = $false
    foreach ($l in [System.IO.File]::ReadAllLines($path)) {
        if (-not $inBlock) { if ($l -match '^<#') { $inBlock = $true }; continue }
        if ($l -match '^#>') { break }
        $out += ($l -replace '^# ?', '')
    }
    $out -join [Environment]::NewLine | Write-Host
}

$mode = 'start'
if ($ServeUserArgs.Count -gt 0 -and $ServeUserArgs[0] -eq 'restart') {
    $mode = 'restart'
    $ServeUserArgs = if ($ServeUserArgs.Count -gt 1) { $ServeUserArgs[1..($ServeUserArgs.Count - 1)] } else { @() }
}
if (($ServeUserArgs | Where-Object { $_ -in '-h', '--help', 'help' }).Count -gt 0) { Usage; exit 0 }

# ---- validate (start.sh lines 34-48) ----
if ($Context -lt 1 -or $Context -gt 1048576) { Die "CONTEXT is a token count up to 1048576, not $Context" }
if ($Parallel -lt 1 -or $Parallel -gt 16) { Die "PARALLEL is 1 to 16, not $Parallel" }
if ($MaxTokens -lt 1) { Die "MAX_TOKENS is a token count, not $MaxTokens" }
foreach ($t in @(@('THINKING', $Thinking), @('DRAFTS', $Drafts), @('VISION', $Vision), @('VISION_URLS', $VisionUrls))) {
    if ($t[1] -notin @('0', '1')) { Die "$($t[0]) is 0 or 1, not $($t[1])" }
}
if ($Yarn -notin @(0, 4)) { Die "TF_FLASHNEXT_YARN is 0 or 4, not $Yarn" }
if ($Context -gt 262144 -and $Yarn -eq 0) { Die "CONTEXT=$Context is past 262,144: it needs YaRN (TF_FLASHNEXT_YARN=4)" }
if ($KvDtype -notin @('bf16', 'fp8')) { Die "KV_DTYPE is bf16 or fp8, not $KvDtype" }

$serveArgs = @('--context', "$Context", '--parallel', "$Parallel", '--max-tokens', "$MaxTokens",
               '--temperature', "$Temperature", '--top-p', "$TopP", '--top-k', "$TopK")
if ($Thinking -eq '1') { $serveArgs += '--thinking' } else { $serveArgs += '--no-thinking' }
if ($Drafts -ne '1') { $serveArgs += '--no-drafts' }
$serveArgs += @('--kv-cache', $KvDtype)
if ($Vision -eq '1') {
    $serveArgs += @('--vision', '--vision-max-images', $env:TENSORFOLD_MAX_IMAGES,
                    '--vision-max-videos', "$MaxVideos", '--vision-image-tokens', $env:TENSORFOLD_IMAGE_TOKENS)
    if ($VisionUrls -eq '1') { $serveArgs += '--vision-urls' }
}
$userArgs = @($ServeUserArgs | Where-Object { $_ })

# effective value of a flag after defaults + user args (user args win)
function Get-ArgValue { param([string]$Flag)
    $value = $null; $all = @($serveArgs) + @($userArgs)
    for ($i = 0; $i -lt $all.Count; $i++) {
        if ($all[$i] -eq $Flag) { if ($i + 1 -lt $all.Count) { $value = $all[$i + 1] } }
        elseif ($all[$i].StartsWith("$Flag=")) { $value = $all[$i].Substring($Flag.Length + 1) }
    }
    return $value
}
$effParallel = [int](Get-ArgValue '--parallel')
$effContext  = [int](Get-ArgValue '--context')

# ---- banner and step header (start.sh lines 76-87) ----
Write-Host ''
Show-Banner
Write-Host '  Mias'' TensorFold Start Script' -ForegroundColor Magenta
$visionTxt = if ($Vision -eq '1') { 'on' } else { 'off' }
$draftsTxt = if ($Drafts -eq '1') { 'MTP' } else { 'off' }
Write-Host ('  {0} - {1} at once - {2}-token window - {3} KV - vision {4} - drafts {5} - port {6}' -f `
    $ModelPath, $effParallel, $effContext, $KvDtype, $visionTxt, $draftsTxt, $Port) -ForegroundColor DarkGray
Write-Host ''
$steps = 5
function Step { param([int]$N, [string]$Msg) Write-Host ('[{0}/{1}] {2}' -f $N, $steps, $Msg) -ForegroundColor Magenta -NoNewline; Write-Host '' }

New-Item -ItemType Directory -Force -Path $StateDir, $LogDir | Out-Null
if ($DryRun) { Log 'DRY_RUN=1: printing the serve command; nothing is stopped or started' }

# already running? (start mode only)
$runningPid = Get-ServerPid
if (-not $DryRun -and $mode -eq 'start' -and $runningPid) {
    $served = 'not answering yet'
    try { $served = (Invoke-LocalRest -Uri "$ApiUrl/v1/models" -TimeoutSec 5).data[0].id } catch { }
    Log "server pid $runningPid is already running (model: $served, port $Port): nothing to do."
    Log 'Use .\start.ps1 restart to restart it, or .\stop.ps1 to stop it.'
    exit 0
}

# ---- step 1: setup (no Docker: binary, checkpoint, vision python) ----
Step 1 'Setup: engine binary, checkpoint and vision helper'
if (-not (Test-Path $NativeBin)) { Die "tensorfold-native.exe not found at $NativeBin (build TensorFold first, or set NATIVE_BIN)" }
if (-not (Test-Path (Join-Path $ModelPath 'config.json'))) { Die "$ModelPath has no config.json: set MODEL_PATH to the local checkpoint directory (CHECKPOINT=nvfp4|int4 picks a preset)" }
if ($Vision -eq '1') {
    if (-not (Test-Path $VisionPython)) { Die "vision is on but the venv python is missing: $VisionPython (set VENV_DIR or VISION=0)" }
    & $VisionPython -c "import importlib.util,sys; sys.exit(0 if importlib.util.find_spec('tensorfold.vision.native_helper') else 1)" 2>$null
    if ($LASTEXITCODE -ne 0) { Die "the venv at $VenvDir has no tensorfold.vision.native_helper (pip install TensorFold[vision] from the clean clone, or VISION=0)" }
    Set-EnvVar 'TENSORFOLD_VISION_PYTHON' $VisionPython
}
# kernel set: TENSORFOLD_CUDA_KERNELS, else share\tensorfold\cuda\sm<cap> beside the exe (native/cuda.zig),
# else the AOT set built here by tools/zig/flashnext_aot.py (build\kernels\sm121).
# A value this shell inherited from an earlier run outlives the folder it names (a renamed or deleted set),
# and the engine then refuses to load: drop a value whose aot.json is gone before it is used.
$kernEnv = [Environment]::GetEnvironmentVariable('TENSORFOLD_CUDA_KERNELS', 'Process')
if ($kernEnv -and $kernEnv -ne 'native' -and -not (Test-Path (Join-Path $kernEnv 'aot.json'))) {
    Warn "TENSORFOLD_CUDA_KERNELS=$kernEnv holds no aot.json (a stale value from an earlier run): using 'native' so the engine runs its embedded kernels"
    # Not "unset": the engine treats a present-but-empty value as a bad folder ("TENSORFOLD_CUDA_KERNELS= holds no aot.json").
    Set-EnvVar 'TENSORFOLD_CUDA_KERNELS' 'native'
    $kernEnv = 'native'
}
if (-not $kernEnv) {
    $kernelCandidates = @(
        (Join-Path (Split-Path -Parent $NativeBin) '..\share\tensorfold\cuda\sm121'),
        (Join-Path $PSScriptRoot 'build\kernels\sm121'),
        (Join-Path $PSScriptRoot 'build\kernels\sm121-int4ar')
    )
    $found = $null
    # A set left by an earlier engine build silently wins over the exe's own kernels and then fails at load
    # (Fp8KvUnsupported when the set predates the fp8-KV patch): take a set only if it is at least as new as the exe.
    $exeTime = (Get-Item $NativeBin).LastWriteTimeUtc
    foreach ($cand in $kernelCandidates) {
        $aot = Join-Path $cand 'aot.json'
        if (-not (Test-Path $aot)) { continue }
        if ((Get-Item $aot).LastWriteTimeUtc -lt $exeTime) {
            Warn "ignoring the Triton kernel set at ${cand}: its aot.json predates $NativeBin, so the engine uses its embedded kernels (a stale set fails with Fp8KvUnsupported)"
            continue
        }
        $found = $cand; break
    }
    if ($found) { Set-EnvVar 'TENSORFOLD_CUDA_KERNELS' $found }
    else {
        # 'native' is the engine's name for its embedded kernels; leaving the variable unset would also work,
        # but a shell that carried an empty copy of it fails the load, and this value survives reuse.
        Set-EnvVar 'TENSORFOLD_CUDA_KERNELS' 'native'
        Warn 'no Triton kernel set (aot.json) chosen: the engine runs its embedded kernels (tf-cuda-test info reports "kernels embedded true"). Set TENSORFOLD_CUDA_KERNELS to a set you built for this exact exe only if you need one.'
    }
}

# ---- step 2: checks - arguments, previous server, port, memory ----
Step 2 'Checks: arguments, previous server, port, memory'
$argErr = Join-Path $StateDir 'args.err'
& $env:ComSpec /c "`"$NativeBin`" serve /nonexistent/argument-check --name `"$ServedName`" --host `"$BindHost`" --port $Port $($serveArgs -join ' ') $($userArgs -join ' ') >nul 2>`"$argErr`""
$code = $LASTEXITCODE
if ($code -eq 2 -or -not ((Get-Content $argErr -Raw -ErrorAction SilentlyContinue) -match 'neither a directory')) {
    if ($DryRun) { Warn "DRY_RUN: tensorfold-native rejects these arguments: $((Get-Content $argErr -ErrorAction SilentlyContinue | Select-Object -Last 1))" }
    else { Get-Content $argErr | Write-Host -ForegroundColor Red; Die 'tensorfold-native serve rejects these arguments; nothing was changed' }
}
if ($DryRun) {
    if ($runningPid) { Log "DRY_RUN: a server (pid $runningPid) is running; a real start would stop it first" }
} elseif ($mode -eq 'restart') {
    if (-not (Stop-Server)) { Log 'no server was running' }
} elseif ($runningPid) {
    Log 'a server was left running: stopping it, then starting'
    Stop-Server | Out-Null
}
if (Test-PortListen $Port) {
    if ($DryRun) { Log "DRY_RUN: port $Port is in use" }
    else { Die "port $Port is already in use: $((Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | ForEach-Object { 'pid ' + $_.OwningProcess }) -join ', ')" }
}
$needGiB = if ($env:MEM_NEED_GIB) { [int]$env:MEM_NEED_GIB } else { Get-MemNeedGib $effContext }
$availGiB = Get-MemAvailableGiB
# RTX Spark is unified-memory but the 98 GiB GPU pool is carved out by the driver: CUDA
# allocations (weights AND the KV cache) come from that pool and do not show up in
# FreePhysicalMemory (~30 GiB visible to the OS). Gate on the host-side share only:
# scratch slack + vision workspace + the 2 GiB pad from config.sh's mem_need_gib.
# The MEM_FLOOR_GIB term is dropped: it is the runtime reserve the native engine
# enforces itself (TENSORFOLD_MEMORY_RESERVE_GIB) and the stop-line the loading
# heartbeat below watches — counting it here would double-gate on the 30 GiB view.
$hostNeedGiB = [Math]::Max(0, [int]($needGiB - $WeightsGiB - (Get-KvGib $effContext) - [Math]::Ceiling($MemFloorGiB)))
if ($availGiB -ge $hostNeedGiB) {
    Log "arguments OK, port $Port free, $availGiB GiB host memory available (host-side needs ~$hostNeedGiB; weights ~$WeightsGiB GiB + KV $(Get-KvGib $effContext) GiB come from the GPU pool)"
} else {
    # Warning only: the OS's FreePhysicalMemory view is unreliable on unified-memory
    # RTX Spark (the engine allocates weights/KV from the driver's 98 GiB pool), and
    # on this box other processes routinely hold RAM. Never block the start.
    Warn "only $availGiB GiB host memory available; this start wants ~$hostNeedGiB on the host side (weights/KV come from the GPU pool; FreePhysicalMemory)"
}
$full = Get-KvGib $effContext
if (($effParallel * $full + $WeightsGiB + $MemReserveGiB) -gt 121) {
    Warn "$effParallel full windows are ~$($effParallel * $full) GiB of $KvDtype cache beside ~$WeightsGiB GiB of weights: the engine keeps $MemReserveGiB GiB free and refuses a request that would not fit"
}

# ---- step 3: launch ----
Step 3 "Launch: $NativeBin"
$serveCmdLine = '"{0}" --name "{1}" --host {2} --port {3} {4} {5} --dashboard' -f `
    $ModelPath, $ServedName, $BindHost, $Port, ($serveArgs -join ' '), ($userArgs -join ' ')
Log "tensorfold-native serve $serveCmdLine"
if ($DryRun) {
    Write-Host '[dry-run]' -ForegroundColor DarkGray
    Write-Host "  `"$NativeBin`" serve $serveCmdLine" -ForegroundColor DarkGray
    exit 0
}
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$serveOut = Join-Path $LogDir "serve-$stamp.out.log"
$serveErr = Join-Path $LogDir "serve-$stamp.err.log"
$psi = Start-Process -FilePath $NativeBin -ArgumentList "serve $serveCmdLine" `
    -WorkingDirectory (Split-Path -Parent $NativeBin) -PassThru -WindowStyle Hidden `
    -RedirectStandardOutput $serveOut -RedirectStandardError $serveErr
Set-Content -Path $PidFile -Value $psi.Id
# keep only the newest LOG_KEEP serve logs
Get-ChildItem $LogDir -Filter 'serve-*.log' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -Skip $LogKeep | Remove-Item -Force -ErrorAction SilentlyContinue

if ($Foreground) {
    Log 'FOREGROUND=1: following the server log (Ctrl+C stops it)'
    $tails = @($serveOut, $serveErr) | ForEach-Object { [System.IO.StreamReader]::new($_, [System.Text.Encoding]::UTF8) }
    try {
        while (-not $tails[0].EndOfStream -or -not $tails[1].EndOfStream -or (Get-Process -Id $psi.Id -ErrorAction SilentlyContinue)) {
            for ($t = 0; $t -lt 2; $t++) {
                while (($line = $tails[$t].ReadLine()) -ne $null) { Write-Host "  | $line" -ForegroundColor DarkGray }
            }
            Start-Sleep -Milliseconds 300
        }
    } finally { $tails | ForEach-Object { $_.Dispose() } }
    exit 0
}

# ---- step 4: wait until the server answers /health ----
Step 4 "Loading: ~$WeightsGiB GiB of weights (the FP8 n-gram table included)"
function Show-ServerLogTail {
    foreach ($f in @($serveOut, $serveErr)) {
        if (Test-Path $f) { Get-Content $f -Tail 20 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  | $_" -ForegroundColor DarkGray } }
    }
}
function Fail-Start { param([string]$Msg)
    Start-Sleep -Milliseconds 500
    Write-Host '--- last server log lines ---' -ForegroundColor DarkGray
    Show-ServerLogTail
    Stop-Process -Id $psi.Id -Force -ErrorAction SilentlyContinue
    Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
    Die $Msg
}
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$nextBeat = 15
$ready = $false
$floorWarned = $false
while (-not $ready) {
    if (-not (Get-Process -Id $psi.Id -ErrorAction SilentlyContinue)) { Fail-Start 'the server exited before it was ready' }
    if ($sw.Elapsed.TotalSeconds -ge $WaitTimeout) { Fail-Start "not ready after ${WaitTimeout}s; it is still running: see $serveOut" }
    $a = Get-MemAvailableGiB
    # Warning only: the OS FreePhysicalMemory view does not cover the driver's unified
    # GPU pool this box loads from, and the native engine enforces its own reserve
    # (TENSORFOLD_MEMORY_RESERVE_GIB). Never kill the server for it.
    if ($a -lt $MemFloorGiB -and -not $floorWarned) {
        Warn "only $a GiB host memory left while loading (MEM_FLOOR_GIB $MemFloorGiB): continuing anyway"
        $floorWarned = $true
    }
    if ($a -ge $MemFloorGiB) { $floorWarned = $false }
    if ($sw.Elapsed.TotalSeconds -ge $nextBeat) {
        Write-Host ('  ... {0}s elapsed, GPU used/free {1} GiB, host {2} GiB free' -f [int]$sw.Elapsed.TotalSeconds, (Get-GpuMemSummary), $a) -ForegroundColor DarkGray
        $nextBeat += 15
    }
    Start-Sleep -Seconds 3
    try { Invoke-LocalRest -Uri "$ApiUrl/health" -TimeoutSec 5 | Out-Null; $ready = $true } catch { }
}
$loadedS = [int]$sw.Elapsed.TotalSeconds
Log "server answered after ${loadedS}s"

# ---- step 5: smoke test - one chat completion ----
Step 5 'Smoke test: one chat completion'
$served = $ServedName
try { $served = (Invoke-LocalRest -Uri "$ApiUrl/v1/models" -TimeoutSec 10).data[0].id } catch { }
$body = '{"model": "' + $served + '", "max_tokens": 32, "temperature": 0, "chat_template_kwargs": {"enable_thinking": false}, "messages": [{"role": "user", "content": "Reply with OK."}]}'
try {
    $resp = Invoke-LocalRest -Uri "$ApiUrl/v1/chat/completions" -Method Post -Body $body -TimeoutSec 180
    $content = "$($resp.choices[0].message.content)".Trim()
    if (-not $content) { throw 'empty completion' }
    $shown = $content.Substring(0, [Math]::Min(40, $content.Length))
    Log "OK: '$shown', $($resp.usage.completion_tokens) tokens"
} catch {
    Fail-Start "the smoke test request failed ($($_.Exception.Message)); the server is still running: see $serveOut"
}
$ip = if ($BindHost -in '0.0.0.0', '::') { try { (Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -and $_.IPv4Addresses.Count }).IPv4Addresses[0].IPAddress } catch { (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -like '192.168.*' -or $_.IPAddress -like '10.*' -or $_.IPAddress -like '172.*' } | Select-Object -First 1).IPAddress } } else { $BindHost }
if (-not $ip) { $ip = '<spark-address>' }
Write-Host ''
Write-Host ('  {0} is now LIVE! on port {1}' -f $served, $Port) -ForegroundColor Green
Write-Host @"
    API      http://${ip}:$Port/v1   (model: $served)
    Loaded   in ${loadedS}s - GPU used/free $(Get-GpuMemSummary) GiB, host $(Get-MemAvailableGiB) GiB free
    Model    $ModelPath ($QuantLabel)
    Window   $effContext tokens$(if ($Yarn -ne 0) { " (YaRN x$Yarn)" }) - $effParallel at once - $KvDtype KV - drafts $draftsTxt
    Logs     $serveOut
    Restart  .\start.ps1 restart
    Stop     .\stop.ps1
"@
Write-Host ''
