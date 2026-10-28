#Requires -Version 5.1
# Shared settings for start.ps1 / stop.ps1 -- Windows port of scripts/config.sh.
# A setting's value comes from the first of these that sets it:
#   1. .env in the recipe root (KEY=value lines, read, never run)
#   2. the environment:  $env:PORT='9000'; .\start.ps1
# (.env outranks a stale copy a reused shell carries from a previous run's defaults.)
# Windows differences from the Linux original: no Docker (the native engine runs on
# the host), checkpoints are local directories (MODEL_PATH), and state/logs live
# under this repo's build\ directory.

$script:RecipeDir = Split-Path -Parent $PSScriptRoot

function Get-Setting {
    param([string]$Name, $Default = $null)
    $v = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if ($null -ne $v -and $v -ne '') { return $v }
    return $Default
}

function Set-EnvVar { param([string]$Name, $Value)
    [Environment]::SetEnvironmentVariable($Name, [string]$Value, 'Process')
}

# ---- .env (KEY=value, # comments, optional quotes; read, never executed) ----
# A key set here wins outright: a reused shell can carry a stale copy of one (a dot-sourced config.ps1
# leaves its Set-EnvVar values behind), and that shadow would silently outrank the file.
$envFile = Join-Path $RecipeDir '.env'
if (Test-Path $envFile) {
    foreach ($line in [System.IO.File]::ReadAllLines($envFile)) {
        if ($line -match '^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
            $key = $Matches[1]; $val = $Matches[2].Trim()
            if ($val -match '^"([^"]*)"\s*(?:#.*)?$') { $val = $Matches[1] }
            elseif ($val -match "^'([^']*)'\s*(?:#.*)?$") { $val = $Matches[1] }
            else { $val = ($val -replace '\s+#.*$', '').TrimEnd() }
            Set-EnvVar $key $val
        }
    }
}

# ---- checkpoint (a local model directory; MODEL_PATH overrides) ----
# One checkpoint, the NVFP4 export. It is not shipped: nvidia/Qwen3.8-Flash-Next-FP4-Local on Hugging Face
# (revision b9ce18a6), mirrored at https://www.modelscope.cn/models/nv-community/Qwen3.8-Flash-Next-FP4-Local.
# From either host, check config.json says quant_method=modelopt and quant_algo=MIXED_PRECISION: the v1.1.4
# CUDA engine loads nothing else, and a GPTQ re-upload of the same model fails the same way. The AutoRound
# INT4 conversions are GPTQ -- a quantization path TensorFold dropped -- so they are not supported here;
# there is no preset for them, and this check refuses one before loading instead of after 48 layers.
# WEIGHTS_GIB is what loading takes of memory (measured on the Zig engine, config.sh).
$CHECKPOINT = Get-Setting 'CHECKPOINT' 'nvfp4'
# Fallback only: .env normally carries MODEL_PATH (scripts\recipe\1-install-ps1.ps1 writes it from
# the path menu). Derived as <parent of the recipe>\model so no drive letter is baked in here.
$ModelRoot  = Join-Path (Split-Path -Parent $RecipeDir) 'model'
if ($CHECKPOINT -eq 'nvfp4') {
    $ModelPath  = Get-Setting 'MODEL_PATH' (Join-Path $ModelRoot 'Qwen3.8-Flash-Next-FP4-Local')
    $WeightsGiB = [double](Get-Setting 'WEIGHTS_GIB' 81)
    $QuantLabel = 'NVIDIA FP4 QAD: NVFP4 experts, MXFP8'
} else {
    # Any other value names a checkpoint this engine cannot load. Leave the path empty and let start.ps1
    # -- the only caller that needs the weights -- refuse with the reason. Dying here would not work
    # anyway: 'exit' in a dot-sourced file only ends that file, returning control to the caller, so
    # start.ps1 would run on with an undefined path. It would also take out stop.ps1, which
    # dot-sources this file and has no interest in the checkpoint.
    $ModelPath  = $null
    $WeightsGiB = 0
    $QuantLabel = "CHECKPOINT=$CHECKPOINT (unsupported)"
}

# ---- engine binary and venv (all inside the clean latest tree) ----
$LatestRoot   = Split-Path -Parent $RecipeDir
$NativeBin    = Get-Setting 'NATIVE_BIN' (Join-Path $LatestRoot 'TensorFold\build\native\bin\tensorfold-native.exe')
$VenvDir      = Get-Setting 'VENV_DIR' (Join-Path $RecipeDir 'venv')
$VisionPython = Get-Setting 'TENSORFOLD_VISION_PYTHON' (Join-Path $VenvDir 'Scripts\python.exe')

# ---- serving defaults (a request's own values win over the server defaults) ----
$ServedName  = Get-Setting 'SERVED_NAME' 'Qwen3.8-Flash-Next'
$BindHost    = Get-Setting 'HOST' '0.0.0.0'    # never name this $Host: automatic variable
$Port        = [int](Get-Setting 'PORT' 8888)
$Context     = [int](Get-Setting 'CONTEXT' 262144)
$Parallel    = [int](Get-Setting 'PARALLEL' 5)
$KvDtype     = Get-Setting 'KV_DTYPE' 'fp8'
$MaxTokens   = [int](Get-Setting 'MAX_TOKENS' 32768)
$Thinking    = Get-Setting 'THINKING' '1'
$Drafts      = Get-Setting 'DRAFTS' '1'
$Temperature = Get-Setting 'TEMPERATURE' '1.0'
$TopP        = Get-Setting 'TOP_P' '0.95'
$TopK        = Get-Setting 'TOP_K' '20'
$Vision      = Get-Setting 'VISION' '1'
$VisionUrls  = Get-Setting 'VISION_URLS' '0'
$MaxVideos   = [int](Get-Setting 'MAX_VIDEOS' 4)
$WaitTimeout = [int](Get-Setting 'WAIT_TIMEOUT' 1800)
$DryRun      = ((Get-Setting 'DRY_RUN' '0') -eq '1')
$MemCheck    = ((Get-Setting 'MEM_CHECK' '1') -ne '0')
$Foreground  = ((Get-Setting 'FOREGROUND' '0') -eq '1')

# ---- engine environment (exported: the spawned server inherits these, like config.sh) ----
# Every variable below is one scripts/config.sh exports, and the engine reads an unset one as "off"
# or as its stock rule -- so a port that skips them does not run the same engine, it runs a
# different one. The VALUES, though, are this machine's, not config.sh's.
#
# Measured 2026-10-28, one stream, greedy code, best of three passes a run, one engine restart a
# run (sweep-decode.ps1 -> decode-c1.txt): config.sh's whole set gave 77.7 tok/s, all of it off gave
# 90.3. GATHER_READ=pread alone is the whole 14% (80.8 with it, 90.3 without) and drags the rest
# down with it. Two switches do survive: KEEP_LATE and GDN_LANES (91.8 together, the best of the
# nine combinations tried). So what ships here is the fastest set for WDDM, not the recipe's set.
# config.sh's own figures (+14% greedy code at one stream, 15-25% a prompt call) are its Linux
# image's and do not transfer. Still at config.sh's value and still unmeasured here: the prefill
# switches (a prefill sweep follows) and PRODUCT_STREAMS.
$Yarn = [int](Get-Setting 'TF_FLASHNEXT_YARN' $(if ($Context -gt 262144) { 4 } else { 0 }))
Set-EnvVar 'TF_FLASHNEXT_YARN' $Yarn
# MTP: up to 6 drafts a round (also the engine default; spelled out because config.sh does).
Set-EnvVar 'TF_FLASHNEXT_DRAFTS' (Get-Setting 'TF_FLASHNEXT_DRAFTS' 6)
# config.sh ships 5, the engine's stock is 2, and this port has not bisected it either way.
Set-EnvVar 'TF_FLASHNEXT_PRODUCT_STREAMS' (Get-Setting 'TF_FLASHNEXT_PRODUCT_STREAMS' 5)
# Off: the batched sampled draft, the GPU candidate pick, the pooled n-gram gather and the
# worker-thread draws (patches 0007/0008/0011) were 1.0-1.7 tok/s on WDDM, inside the noise floor
# a repeat run of one configuration sets (0.5%).
Set-EnvVar 'TF_FLASHNEXT_SAMPLED_HEADS' (Get-Setting 'TF_FLASHNEXT_SAMPLED_HEADS' 0)
Set-EnvVar 'TF_FLASHNEXT_SAMPLE_CAND' (Get-Setting 'TF_FLASHNEXT_SAMPLE_CAND' 0)
Set-EnvVar 'TF_FLASHNEXT_GATHER_EARLY' (Get-Setting 'TF_FLASHNEXT_GATHER_EARLY' 0)
Set-EnvVar 'TF_FLASHNEXT_HOST_DRAW_THREADS' (Get-Setting 'TF_FLASHNEXT_HOST_DRAW_THREADS' 0)
# A partly rejected draft window keeps its rows in a log instead of replaying DeltaNet (0012).
# On: 91.8 tok/s with it, 90.3 without -- the only pair that beat the baseline twice.
Set-EnvVar 'TF_FLASHNEXT_KEEP_LATE' (Get-Setting 'TF_FLASHNEXT_KEEP_LATE' 1)
# n-gram rows by positional reads from a pool that reads ahead (0013). OFF, and this is the one
# measurement that matters most here: pread costs 10.5 tok/s (80.8 vs 90.3) on Windows, where it is
# ReadFile+OVERLAPPED per row (zig/src/platform/win_c.zig) rather than a mapped page fault. The
# value stays a value, not a flag: only the literal 'pread' turns it on, so '0' is safely off.
Set-EnvVar 'TF_FLASHNEXT_GATHER_READ' (Get-Setting 'TF_FLASHNEXT_GATHER_READ' '0')
Set-EnvVar 'TF_FLASHNEXT_DRAFT_AHEAD' (Get-Setting 'TF_FLASHNEXT_DRAFT_AHEAD' 0)
# Prompt-side switches below: still config.sh's values, pending a prefill sweep against the
# recipe's 2,735 tok/s at 32k. WARM_AHEAD and PREFILL_TAIL only run in prompt passes.
Set-EnvVar 'TF_FLASHNEXT_WARM_AHEAD' (Get-Setting 'TF_FLASHNEXT_WARM_AHEAD' 1)
Set-EnvVar 'TF_FLASHNEXT_PREFILL_TAIL' (Get-Setting 'TF_FLASHNEXT_PREFILL_TAIL' 512)
# Prompt passes (0014): fused hyper-connection/GEMM, straight-to-y shared expert, routed
# experts on shared-memory row tiles from 256 rows, MTP head in 1536-row pieces.
Set-EnvVar 'TF_FLASHNEXT_PROMPT_HC2' (Get-Setting 'TF_FLASHNEXT_PROMPT_HC2' 1)
Set-EnvVar 'TF_FLASHNEXT_PROMPT_SHARED_DIRECT' (Get-Setting 'TF_FLASHNEXT_PROMPT_SHARED_DIRECT' 1)
Set-EnvVar 'TF_FLASHNEXT_PROMPT_EXPERT_TILE_ROWS' (Get-Setting 'TF_FLASHNEXT_PROMPT_EXPERT_TILE_ROWS' 256)
Set-EnvVar 'TF_FLASHNEXT_HEAD_PIECE' (Get-Setting 'TF_FLASHNEXT_HEAD_PIECE' 1536)
# The two-stage MX128 prompt tile (0015).
Set-EnvVar 'TF_FLASHNEXT_PROMPT_GEMM2' (Get-Setting 'TF_FLASHNEXT_PROMPT_GEMM2' 1)
Set-EnvVar 'TF_FLASHNEXT_PROMPT_EXPERT_TILE' (Get-Setting 'TF_FLASHNEXT_PROMPT_EXPERT_TILE' 2)
# Decode rounds (0016): DeltaNet rows in three launches a layer instead of five a lane. GDN_LANES
# needs KEEP_LATE=1. The side stream for the shared expert is off: 89.4 tok/s, 1.0% under baseline.
Set-EnvVar 'TF_FLASHNEXT_SHARED_SIDE' (Get-Setting 'TF_FLASHNEXT_SHARED_SIDE' 0)
Set-EnvVar 'TF_FLASHNEXT_GDN_LANES' (Get-Setting 'TF_FLASHNEXT_GDN_LANES' 1)
# Draft chain stop rule (0017): a running product >= 0.4 while up to 5 streams draft together,
# where v1.1.4's stock rule is a per-draft floor of 0.6. Only the draft row count changes, never a
# reply. 0.6 (stock) here: -0.4 measured 90.6, i.e. inside the noise floor, while the recipe's
# Linux image claims +14% with it.
Set-EnvVar 'TF_FLASHNEXT_CONFIDENCE' (Get-Setting 'TF_FLASHNEXT_CONFIDENCE' 0.6)
Set-EnvVar 'TENSORFOLD_MAX_IMAGES' (Get-Setting 'TENSORFOLD_MAX_IMAGES' 50)
Set-EnvVar 'TENSORFOLD_IMAGE_TOKENS' (Get-Setting 'TENSORFOLD_IMAGE_TOKENS' 16384)
Set-EnvVar 'TENSORFOLD_VIDEO_TOKENS' (Get-Setting 'TENSORFOLD_VIDEO_TOKENS' 16384)
Set-EnvVar 'TENSORFOLD_VISION_WORKSPACE_MIB' (Get-Setting 'TENSORFOLD_VISION_WORKSPACE_MIB' 2048)
Set-EnvVar 'TENSORFOLD_MEMORY_RESERVE_GIB' (Get-Setting 'TENSORFOLD_MEMORY_RESERVE_GIB' 10)
Set-EnvVar 'TENSORFOLD_NO_UPDATE_CHECK' (Get-Setting 'TENSORFOLD_NO_UPDATE_CHECK' 1)
$MemReserveGiB = [double]$env:TENSORFOLD_MEMORY_RESERVE_GIB
$MemFloorGiB   = [double](Get-Setting 'MEM_FLOOR_GIB' $MemReserveGiB)

# ---- state, logs, pid (everything inside this repo's build\ directory) ----
$StateDir = Get-Setting 'STATE_DIR' (Join-Path $RecipeDir 'build\state')
$LogDir   = Get-Setting 'LOG_DIR'   (Join-Path $RecipeDir 'build\logs')
$PidFile  = Join-Path $StateDir 'server.pid'
$LogKeep  = [int](Get-Setting 'LOG_KEEP' 10)

$apiHost = $BindHost
if ($apiHost -eq '0.0.0.0' -or $apiHost -eq '::') { $apiHost = '127.0.0.1' }
if ($apiHost.Contains(':') -and -not $apiHost.StartsWith('[')) { $apiHost = "[$apiHost]" }
$ApiUrl = 'http://{0}:{1}' -f $apiHost, $Port

# ---- shared helpers ----
function Log  { param([string]$Msg) Write-Host ('[{0}] {1}' -f $script:SelfName, $Msg) }
function Warn { param([string]$Msg) Write-Host ('[{0}] WARN: {1}' -f $script:SelfName, $Msg) -ForegroundColor Yellow }
function Die  { param([string]$Msg) Write-Host ('[{0}] ERROR: {1}' -f $script:SelfName, $Msg) -ForegroundColor Red; exit 1 }

# Direct-connection REST for the local server: PS 7 would otherwise pick up HTTP_PROXY
# from the environment and send 127.0.0.1 requests to the proxy.
function Invoke-LocalRest {
    param([string]$Uri, [int]$TimeoutSec = 5, [string]$Method = 'Get', [string]$Body = $null)
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        if (-not [string]::IsNullOrEmpty($Body)) { return Invoke-RestMethod -Uri $Uri -Method $Method -ContentType 'application/json' -Body $Body -TimeoutSec $TimeoutSec -NoProxy -ErrorAction Stop }
        return Invoke-RestMethod -Uri $Uri -Method $Method -TimeoutSec $TimeoutSec -NoProxy -ErrorAction Stop
    }
    $old = [System.Net.WebRequest]::DefaultWebProxy
    [System.Net.WebRequest]::DefaultWebProxy = $null
    try {
        # PS 5.1's Invoke-RestMethod defaults to POST (6.0 defaults to GET) and then rejects a
        # body-less POST with "cannot send a content-body with this verb type": pass -Method every time.
        if (-not [string]::IsNullOrEmpty($Body)) { return Invoke-RestMethod -Uri $Uri -Method $Method -ContentType 'application/json' -Body $Body -TimeoutSec $TimeoutSec -ErrorAction Stop }
        return Invoke-RestMethod -Uri $Uri -Method $Method -TimeoutSec $TimeoutSec -ErrorAction Stop
    } finally { [System.Net.WebRequest]::DefaultWebProxy = $old }
}

# One sequence's KV cache, GiB: bf16 30784 bytes a token, fp8 17888 (State.cacheBytes).
function Get-KvGib { param([int]$Ctx)
    $bytes = 30784; if ($KvDtype -eq 'fp8') { $bytes = 17888 }
    return [int][Math]::Ceiling(($bytes * [double]$Ctx) / 1GB)
}

# Memory a start needs: weights, one full window, 8 GiB scratch slack, the vision
# workspace when VISION=1, the floor, 2 GiB (mem_need_gib in config.sh).
function Get-MemNeedGib { param([int]$Ctx)
    $vision = 0; if ($Vision -eq '1') { $vision = 2 }
    return [int]($WeightsGiB + (Get-KvGib $Ctx) + 8 + $vision + $MemFloorGiB + 2)
}

# Available memory in whole GiB (FreePhysicalMemory is KB; closest Windows analogue
# of /proc/meminfo MemAvailable).
function Get-MemAvailableGiB {
    $os = Get-CimInstance Win32_OperatingSystem
    return [int][Math]::Floor($os.FreePhysicalMemory / 1MB)
}

# GPU memory in use / free, GiB, summed over the GPUs that report numbers
# (nvidia-smi --query-gpu). Per-process used_memory is [N/A] under WDDM on this box,
# so a process-level query cannot work: the engine's allocations show up in the
# totals while it loads. Returns 'used/free' as text, or '?' without nvidia-smi.
function Get-GpuMemSummary {
    $smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if (-not $smi) { return '?' }
    $used = 0.0; $free = 0.0
    foreach ($l in (& $smi.Source '--query-gpu=memory.used,memory.free' '--format=csv,noheader,nounits' 2>$null)) {
        $parts = $l -split ','
        if ($parts.Count -lt 2) { continue }
        $u = 0.0; $f = 0.0
        if ([double]::TryParse($parts[0].Trim(), [ref]$u)) { $used += $u }
        if ([double]::TryParse($parts[1].Trim(), [ref]$f)) { $free += $f }
    }
    return '{0:N1} / {1:N1}' -f ($used / 1024), ($free / 1024)
}

function Test-PortListen { param([int]$P)
    try {
        $found = Get-NetTCPConnection -LocalPort $P -State Listen -ErrorAction SilentlyContinue
        return (($found | Measure-Object).Count -gt 0)
    } catch {
        $c = New-Object Net.Sockets.TcpClient
        try { $c.Connect('127.0.0.1', $P); return $true } catch { return $false } finally { $c.Close() }
    }
}

# The pid start.ps1 recorded, when that process is still alive.
function Get-ServerPid {
    if (-not (Test-Path $PidFile)) { return $null }
    $first = (Get-Content $PidFile -First 1 -ErrorAction SilentlyContinue)
    $procId = 0
    if (-not $first -or -not [int]::TryParse($first.Trim(), [ref]$procId)) { return $null }
    if (Get-Process -Id $procId -ErrorAction SilentlyContinue) { return $procId }
    return $null
}

# Stop the tracked server (or an untracked native process from this binary): warn
# about running requests, kill, wait up to TimeoutSec, drop the pid file.
# Returns $true when a server was stopped.
function Stop-Server { param([int]$TimeoutSec = 30)
    $procId = Get-ServerPid
    if (-not $procId) {
        $orphan = $null
        if (Test-Path $NativeBin) {
            $orphan = Get-Process -Name 'tensorfold-native' -ErrorAction SilentlyContinue |
                      Where-Object { $_.Path -and ($_.Path -ieq $NativeBin) } | Select-Object -First 1
        }
        if (-not $orphan) {
            # Whoever holds the port is the server, no matter which checkout its binary
            # came from (a second clone, a moved build): find it by its LISTEN socket.
            foreach ($t in (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
                          Select-Object -ExpandProperty OwningProcess -Unique)) {
                $p = Get-Process -Id $t -ErrorAction SilentlyContinue
                if ($p -and $p.Name -eq 'tensorfold-native') { $orphan = $p; break }
            }
        }
        if (-not $orphan) { Remove-Item $PidFile -Force -ErrorAction SilentlyContinue; return $false }
        $procId = $orphan.Id
    }
    $busy = 0
    try { $h = Invoke-LocalRest -Uri "$ApiUrl/health" -TimeoutSec 3; $busy = [int]$h.running } catch { }
    if ($busy -gt 0) { Warn "$busy request(s) still running will be cut off" }
    Log "Stopping server (pid $procId, up to ${TimeoutSec}s)"
    # docker stop semantics: one kill, then the whole timeout for the process to die.
    # (The engine's graceful channels - Ctrl+C, console close - only fire inside its
    # own console; nothing outside it can raise them, so there is nothing gentler to
    # send here, and stop.sh itself promises requests are cut off, not drained.)
    Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Process -Id $procId -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 250 }
    if (Get-Process -Id $procId -ErrorAction SilentlyContinue) {
        # A force kill that dies silently is an access denial: the server runs with
        # more privilege than this shell (or is wedged in driver cleanup). Never
        # report 'Stopped' over a living process, and keep the pid file so the next
        # run still finds it. This is what looked like "stopped but still listening".
        Warn "pid $procId is still alive after ${TimeoutSec}s: it needs the same elevation that started it. Run stop.ps1 from that console, or taskkill /PID $procId /F from an admin one."
        return $true
    }
    if (Test-PortListen $Port) { Warn "pid $procId exited but port $Port is still held by another process" }
    Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
    Log 'Stopped; its GPU memory is free again'
    return $true
}
