#Requires -Version 5.1
<#
  Shared settings for every script in this repository -- no path is hard-coded.

  Nothing here assumes D:\llm\latest. The defaults are *detected* from where this repository
  was cloned and from the machine's own environment; the interactive menu lets you confirm or
  change each one, and the accepted set is written to .migration.local.json (git-ignored) so
  every later script, and a re-run next week, uses the same paths.

  Consumers dot-source this file and call Get-MigConfig:

      . (Join-Path (Split-Path -Parent $PSScriptRoot) 'migration.config.ps1')
      $cfg = Get-MigConfig -Quiet          # no prompt: saved file, else detected defaults

  Only the two entry points ask questions -- scripts\Invoke-Migration.ps1 and a first run of any
  single step. Once .migration.local.json exists, every step is non-interactive.

  The one layout constraint comes from the recipe itself, not from this file: the recipe's
  scripts\config.ps1 looks for the engine at '<parent of the recipe>\TensorFold\build\...', so the
  engine directory must be a sibling named exactly 'TensorFold'. Root is therefore the only
  directory to choose; engine and recipe are derived from it.
#>
param()

$ErrorActionPreference = 'Continue'

$script:MigEngineName = 'TensorFold'
$script:MigRecipeName = 'Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold'
$script:MigTfRef      = 'eab8582819688325e371907e4706e1c602b8a273'   # v1.1.4, see VERSIONS.md
$script:MigRecipeRef  = 'fd3f43e11238553685ebb68b6d8ab2b112818e3c'

function Get-MigRepoRoot {
    # this file lives in <repo>\scripts
    return (Split-Path -Parent $PSScriptRoot)
}

function Get-MigConfigPath {
    if ($env:TENSORFOLD_MIG_CONFIG) { return $env:TENSORFOLD_MIG_CONFIG }
    return (Join-Path (Get-MigRepoRoot) '.migration.local.json')
}

# ---- detection ------------------------------------------------------------

function Get-MigFirstExisting {
    param([string[]]$Candidates, [string]$Filter = '')
    foreach ($c in $Candidates) {
        if (-not $c) { continue }
        if ($Filter) {
            $hit = Get-ChildItem -Path $c -Filter $Filter -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hit) { return $hit.FullName }
        } elseif (Test-Path $c) {
            return (Resolve-Path $c).Path
        }
    }
    return ''
}

function Find-MigDefaults {
    $repo   = Get-MigRepoRoot
    $parent = Split-Path -Parent $repo

    # root: the directory this repository sits in, i.e. where its siblings would be cloned.
    $rootCandidates = @($env:TENSORFOLD_MIG_ROOT, $parent, (Join-Path $HOME 'llm\latest'))
    if ($env:TENSORFOLD_MIG_ROOT -and (Test-Path $env:TENSORFOLD_MIG_ROOT)) {
        $root = (Resolve-Path $env:TENSORFOLD_MIG_ROOT).Path
    } elseif (Test-Path (Join-Path $parent $script:MigEngineName)) {
        $root = $parent                     # the engine clone is already beside this repo
    } elseif (Test-Path (Join-Path $parent $script:MigRecipeName)) {
        $root = $parent
    } else {
        $root = $parent
    }

    # zig: PATH first, then the conventional folder names next to root, beside the repo, in the profile.
    $zigCandidates = @()
    $onPath = Get-Command zig -ErrorAction SilentlyContinue
    if ($onPath) { $zigCandidates += $onPath.Source }
    $rootParent = Split-Path -Parent $root
    $zigCandidates += @(
        (Join-Path $root 'zig\zig.exe'),
        (Join-Path $parent 'zig\zig.exe'),
        (Join-Path $HOME 'zig\zig.exe')
    )
    foreach ($dir in @($rootParent, $root, $parent, $HOME)) {
        $zigCandidates += @(Get-ChildItem -Path $dir -Filter 'zig*' -Directory -ErrorAction SilentlyContinue |
                            ForEach-Object { Join-Path $_.FullName 'zig.exe' })
    }
    $zig = Get-MigFirstExisting -Candidates $zigCandidates

    # python: PATH first, then the per-user and machine-wide installs py launcher would find.
    $pyCandidates = @()
    $pyOnPath = Get-Command python -ErrorAction SilentlyContinue
    if ($pyOnPath) { $pyCandidates += $pyOnPath.Source }
    foreach ($base in @((Join-Path $env:LOCALAPPDATA 'Programs\Python'), $env:ProgramFiles, 'C:\')) {
        if (-not $base) { continue }
        $pyCandidates += @(Get-ChildItem -Path $base -Filter 'Python3*' -Directory -ErrorAction SilentlyContinue |
                           Sort-Object Name -Descending | ForEach-Object { Join-Path $_.FullName 'python.exe' })
    }
    $python = Get-MigFirstExisting -Candidates $pyCandidates

    # CUDA toolkit: CUDA_PATH, else the toolkit's own install root (any 13.x).
    $cudaCandidates = @($env:CUDA_PATH)
    $tkRoot = Join-Path $env:ProgramFiles 'NVIDIA GPU Computing Toolkit\CUDA'
    if (Test-Path $tkRoot) {
        $cudaCandidates += @(Get-ChildItem -Path $tkRoot -Directory -ErrorAction SilentlyContinue |
                             Sort-Object Name -Descending | ForEach-Object { $_.FullName })
    }
    $cuda = ''
    foreach ($c in $cudaCandidates) {
        if ($c -and (Test-Path (Join-Path $c 'bin\nvcc.exe'))) { $cuda = $c; break }
    }
    if (-not $cuda) { $cuda = (Get-MigFirstExisting -Candidates $cudaCandidates) }

    # vcvarsall: any VS 2022 install (Build Tools, Community, Professional, Enterprise).
    $vsGlobs = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\2022\*\VC\Auxiliary\Build\vcvarsall.bat'),
        (Join-Path $env:ProgramFiles        'Microsoft Visual Studio\2022\*\VC\Auxiliary\Build\vcvarsall.bat')
    )
    $vcvars = ''
    foreach ($g in $vsGlobs) {
        $hit = Get-Item $g -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { $vcvars = $hit.FullName; break }
    }

    # checkpoint: '<parent of root>\model\<name>' is the convention, but never assume it exists.
    $modelCandidates = @($env:MODEL_PATH)
    foreach ($base in @((Split-Path -Parent $root), $root, (Join-Path $HOME 'model'))) {
        if (-not $base) { continue }
        $modelCandidates += Join-Path (Join-Path $base 'model') 'Qwen3.8-Flash-Next-FP4-Local'
        $modelCandidates += Join-Path $base 'Qwen3.8-Flash-Next-FP4-Local'
    }
    $model = Get-MigFirstExisting -Candidates $modelCandidates

    return [pscustomobject]@{
        Repo      = $repo
        Root      = $root
        Python    = $python
        Zig       = $zig
        Cuda      = $cuda
        Vcvars    = $vcvars
        ModelPath = $model
        Sm        = 121
        RootCandidates   = $rootCandidates
        ZigCandidates    = $zigCandidates
        PythonCandidates = $pyCandidates
        CudaCandidates   = $cudaCandidates
        ModelCandidates  = $modelCandidates
    }
}

# ---- validation -----------------------------------------------------------

function Test-MigZig {
    param([string]$Path)
    if (-not $Path) { return @{ State = 'missing'; Text = 'not found' } }
    if (-not (Test-Path $Path)) { return @{ State = 'missing'; Text = "no file at $Path" } }
    $v = (& $Path version 2>&1 | Out-String).Trim()
    if ($v -eq '0.17.0') { return @{ State = 'ok'; Text = "0.17.0" } }
    if (-not $v) { return @{ State = 'bad'; Text = 'did not report a version' } }
    return @{ State = 'bad'; Text = "version $v, the tree needs 0.17.0" }
}

function Test-MigPython {
    param([string]$Path)
    if (-not $Path) { return @{ State = 'missing'; Text = 'not found (needed for the vision venv)' } }
    if (-not (Test-Path $Path)) { return @{ State = 'missing'; Text = "no file at $Path" } }
    $out = (& $Path -c "import sys,platform;print('%d.%d.%d %s' % (sys.version_info[0],sys.version_info[1],sys.version_info[2],platform.machine()))" 2>&1 | Out-String).Trim()
    if ($out -notmatch '^(\d+)\.(\d+)\.(\d+)\s+(\S+)') {
        return @{ State = 'bad'; Text = "could not run it ('$out')" }
    }
    $major = [int]$Matches[1]; $minor = [int]$Matches[2]; $patch = $Matches[3]; $arch = $Matches[4]
    if ($major -ne 3 -or $minor -lt 11) {
        return @{ State = 'bad'; Text = "python $major.$minor, the vision helper needs 3.11 or newer" }
    }
    if ($arch -notmatch 'ARM64|aarch64') {
        return @{ State = 'bad'; Text = "python is $arch; wheels for this machine are aarch64" }
    }
    return @{ State = 'ok'; Text = ("python {0}.{1}.{2} {3}" -f $major, $minor, $patch, $arch) }
}

function Test-MigCuda {
    param([string]$Path)
    if (-not $Path) { return @{ State = 'missing'; Text = 'not found' } }
    $nvcc = Join-Path $Path 'bin\nvcc.exe'
    if (-not (Test-Path $nvcc)) { return @{ State = 'missing'; Text = "no bin\nvcc.exe under $Path" } }
    $out = (& $nvcc --version 2>&1 | Out-String)
    $rel = ''
    if ($out -match 'release\s+(\d+\.\d+)') { $rel = $Matches[1] }
    if ($rel -like '13.4*') { return @{ State = 'ok'; Text = "nvcc $rel" } }
    if ($rel) { return @{ State = 'bad'; Text = "nvcc $rel (validated: 13.4)" } }
    return @{ State = 'bad'; Text = 'nvcc present but printed no release' }
}

function Test-MigVcvars {
    param([string]$Path)
    if (-not $Path) { return @{ State = 'missing'; Text = 'not found' } }
    if (-not (Test-Path $Path)) { return @{ State = 'missing'; Text = "no file at $Path" } }
    $cl = Get-ChildItem -Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $Path))) -Filter 'cl.exe' -Recurse -ErrorAction SilentlyContinue |
          Where-Object { $_.FullName -match 'Hostarm64\\arm64\\cl\.exe$' } | Select-Object -First 1
    if ($cl) { return @{ State = 'ok'; Text = "arm64 cl $((Get-Item $cl.FullName).VersionInfo.FileVersion)" } }
    return @{ State = 'bad'; Text = 'no Hostarm64\arm64\cl.exe: add the ARM64 build tools component' }
}

function Test-MigModel {
    param([string]$Path)
    if (-not $Path) { return @{ State = 'missing'; Text = 'not set (fine before you download the weights)' } }
    $cfg = Join-Path $Path 'config.json'
    if (-not (Test-Path $cfg)) { return @{ State = 'missing'; Text = 'no config.json' } }
    $json = Get-Content $cfg -Raw -ErrorAction SilentlyContinue
    $quant = ''
    if ($json -match '"quant_method"\s*:\s*"([^"]+)"') { $quant = $Matches[1] }
    $algo = ''
    if ($json -match '"quant_algo"\s*:\s*"([^"]+)"') { $algo = $Matches[1] }
    if ($quant -eq 'modelopt' -and $algo -eq 'MIXED_PRECISION') {
        # the NVIDIA export keeps its shards in tensors\, a flattened mirror has them at the root
        $size = (Get-ChildItem $Path -Filter '*.safetensors' -Recurse -File -ErrorAction SilentlyContinue |
                 Measure-Object Length -Sum).Sum
        return @{ State = 'ok'; Text = ("modelopt / {0}, {1:N0} GiB" -f $algo, ($size / 1GB)) }
    }
    return @{ State = 'bad'; Text = "config.json says '$quant' / '$algo', the engine takes modelopt / MIXED_PRECISION" }
}

function Test-MigRoot {
    param([string]$Root)
    if (-not $Root) { return @{ State = 'missing'; Text = 'not set' } }
    $parent = Split-Path -Parent $Root
    if (-not $parent -or -not (Test-Path $parent)) {
        return @{ State = 'bad'; Text = "the parent of $Root does not exist" }
    }
    $engine = Join-Path $Root $script:MigEngineName
    $recipe = Join-Path $Root $script:MigRecipeName
    $bits = @()
    if (Test-Path $engine) { $bits += 'engine present' } else { $bits += 'engine to be cloned' }
    if (Test-Path $recipe) { $bits += 'recipe present' } else { $bits += 'recipe to be cloned' }
    return @{ State = 'ok'; Text = ($bits -join ', ') }
}

# ---- running native tools -------------------------------------------------

# PowerShell's `2>&1` turns every stderr line of a native program into an ErrorRecord; the formatter
# then wraps it at the host width and appends the "NativeCommandError" decoration. Tools like
# tf-cuda-test print their result on stderr, so read the two streams as raw text instead.
function Invoke-MigNative {
    param(
        [string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$TimeoutSec = 0
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = ($Arguments | ForEach-Object {
        if ($_ -match '\s') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    try {
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    } catch { }
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    if ($TimeoutSec -gt 0) {
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            try { $p.Kill() } catch { }
            return @{ Out = ''; Err = "timed out after $TimeoutSec s"; Code = -1 }
        }
    } else {
        $p.WaitForExit()
    }
    $outText = ''
    $errText = ''
    try { $outText = $outTask.Result } catch { }
    try { $errText = $errTask.Result } catch { }
    return @{
        Out  = ($outText -replace "`r", '')
        Err  = ($errText -replace "`r", '')
        Code = $p.ExitCode
    }
}

# ---- persistence ----------------------------------------------------------

function Read-MigSaved {
    $path = Get-MigConfigPath
    if (-not (Test-Path $path)) { return $null }
    try {
        $o = Get-Content $path -Raw | ConvertFrom-Json
        return [pscustomobject]@{
            Root      = [string]$o.root
            Python    = [string]$o.python
            Zig       = [string]$o.zig
            Cuda      = [string]$o.cuda
            Vcvars    = [string]$o.vcvars
            ModelPath = [string]$o.model_path
            Sm        = $(if ($o.sm) { [int]$o.sm } else { 121 })
            TfRef     = $(if ($o.tf_ref) { [string]$o.tf_ref } else { $script:MigTfRef })
            RecipeRef = $(if ($o.recipe_ref) { [string]$o.recipe_ref } else { $script:MigRecipeRef })
        }
    } catch {
        Write-Host "  [WARN] $path is not valid JSON; ignoring it" -ForegroundColor Yellow
        return $null
    }
}

function Save-MigConfig {
    param($Config)
    $path = Get-MigConfigPath
    $o = [ordered]@{
        _comment   = 'Written by scripts\migration.config.ps1. Git-ignored; delete it to be asked again.'
        saved_utc  = (Get-Date).ToUniversalTime().ToString('o')
        root       = $Config.Root
        python     = $Config.Python
        zig        = $Config.Zig
        cuda       = $Config.Cuda
        vcvars     = $Config.Vcvars
        model_path = $Config.ModelPath
        sm         = $Config.Sm
        tf_ref     = $Config.TfRef
        recipe_ref = $Config.RecipeRef
    }
    try {
        ($o | ConvertTo-Json) | Set-Content -Path $path -Encoding UTF8
        Write-Host "  saved: $path" -ForegroundColor DarkGray
        return $true
    } catch {
        Write-Host "  [WARN] could not write ${path}: $($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    }
}

# ---- the menu -------------------------------------------------------------

function Read-MigLine {
    param([string]$Prompt, [string]$Default = '')
    if ($Default) {
        Write-Host ("  {0} [{1}]: " -f $Prompt, $Default) -NoNewline
    } else {
        Write-Host ("  {0}: " -f $Prompt) -NoNewline
    }
    $line = Read-Host
    if ($null -eq $line) { return $Default }
    $line = $line.Trim().Trim('"').Trim("'")
    if (-not $line) { return $Default }
    return $line
}

function Select-MigFolder {
    param([string]$Start)
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $d = New-Object System.Windows.Forms.FolderBrowserDialog
        $d.Description = 'Pick a folder'
        if ($Start -and (Test-Path $Start)) { $d.SelectedPath = $Start }
        if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $d.SelectedPath }
        return ''
    } catch {
        Write-Host '    (no folder picker available here; type the path instead)' -ForegroundColor DarkGray
        return ''
    }
}

function Format-MigConfig {
    param($Config)
    $rows = @(
        @{ N = 1; Key = 'root    '; Value = $Config.Root;      Test = (Test-MigRoot   $Config.Root) },
        @{ N = 2; Key = 'python  '; Value = $Config.Python;    Test = (Test-MigPython $Config.Python) },
        @{ N = 3; Key = 'zig     '; Value = $Config.Zig;       Test = (Test-MigZig    $Config.Zig) },
        @{ N = 4; Key = 'cuda    '; Value = $Config.Cuda;      Test = (Test-MigCuda   $Config.Cuda) },
        @{ N = 5; Key = 'vcvars  '; Value = $Config.Vcvars;    Test = (Test-MigVcvars $Config.Vcvars) },
        @{ N = 6; Key = 'model   '; Value = $Config.ModelPath; Test = (Test-MigModel  $Config.ModelPath) }
    )
    Write-Host ''
    Write-Host '  Settings' -ForegroundColor Cyan
    foreach ($r in $rows) {
        $colour = 'White'
        $tag = ''
        if ($r.Test.State -eq 'ok')      { $colour = 'White';  $tag = '' }
        elseif ($r.Test.State -eq 'bad') { $colour = 'Yellow'; $tag = '  <- ' + $r.Test.Text }
        else                             { $colour = 'DarkGray'; $tag = '  <- ' + $r.Test.Text }
        Write-Host ("   [{0}] {1} {2}" -f $r.N, $r.Key, $r.Value) -ForegroundColor $colour
        if ($tag) { Write-Host ("       " + $tag) -ForegroundColor $colour }
    }
    Write-Host ("       engine   " + (Join-Path $Config.Root $script:MigEngineName)) -ForegroundColor DarkGray
    Write-Host ("       recipe   " + (Join-Path $Config.Root $script:MigRecipeName)) -ForegroundColor DarkGray
}

# Values that would stop a later step. Model may legitimately be unset (weights not downloaded yet).
function Get-MigProblems {
    param($Config)
    $bad = New-Object System.Collections.ArrayList
    $r = Test-MigRoot $Config.Root
    if ($r.State -ne 'ok') { [void]$bad.Add("root: $($r.Text)") }
    $p = Test-MigPython $Config.Python
    if ($p.State -ne 'ok') { [void]$bad.Add("python: $($p.Text)") }
    $z = Test-MigZig $Config.Zig
    if ($z.State -ne 'ok') { [void]$bad.Add("zig: $($z.Text)") }
    $c = Test-MigCuda $Config.Cuda
    if ($c.State -ne 'ok') { [void]$bad.Add("cuda: $($c.Text)") }
    $v = Test-MigVcvars $Config.Vcvars
    if ($v.State -ne 'ok') { [void]$bad.Add("vcvars: $($v.Text)") }
    $m = Test-MigModel $Config.ModelPath
    if ($m.State -eq 'bad') { [void]$bad.Add("model: $($m.Text)") }
    return $bad
}

function Read-MigMenu {
    param($Config, $Defaults)

    Write-Host ''
    Write-Host 'TensorFold + Qwen3.8-Flash-Next recipe -- where everything lives' -ForegroundColor Magenta
    Write-Host '  Enter accepts. A number edits that row. "?" inside a row opens a folder picker.' -ForegroundColor DarkGray

    while ($true) {
        Format-MigConfig $Config
        Write-Host ''
        Write-Host '  [Enter] accept   [1-6] edit   [d] detect again   [q] quit' -ForegroundColor DarkGray
        $choice = (Read-Host '  >').Trim().ToLower()

        if ($choice -eq 'q') { return $null }
        if ($choice -eq '') {
            # accepting a set that cannot work only moves the failure three steps later
            $problems = Get-MigProblems $Config
            if ($problems.Count -gt 0) {
                Write-Host ''
                Write-Host '  this set will not get through the migration:' -ForegroundColor Yellow
                foreach ($p in $problems) { Write-Host ("    - " + $p) -ForegroundColor Yellow }
                Write-Host '  accept anyway? [y/N]: ' -NoNewline
                $yn = (Read-Host).Trim().ToLower()
                if ($yn -ne 'y' -and $yn -ne 'yes') { continue }
            }
            return $Config
        }
        if ($choice -eq 'd') {
            $d = Find-MigDefaults
            $Config.Root      = $d.Root
            $Config.Python    = $d.Python
            $Config.Zig       = $d.Zig
            $Config.Cuda      = $d.Cuda
            $Config.Vcvars    = $d.Vcvars
            $Config.ModelPath = $d.ModelPath
            continue
        }

        $n = 0
        if (-not [int]::TryParse($choice, [ref]$n) -or $n -lt 1 -or $n -gt 6) {
            Write-Host '  pick 1-6, d, or Enter' -ForegroundColor Yellow
            continue
        }

        switch ($n) {
            1 {
                $cur = $Config.Root
                $v = Read-MigLine 'root (the folder holding the two clones)' $cur
                if ($v -eq '?') { $v = Select-MigFolder $cur }
                if (-not $v) { $v = $cur }
                $Config.Root = $v.TrimEnd('\')
            }
            2 {
                $cur = $Config.Python
                $v = Read-MigLine 'python.exe (for the vision venv)' $cur
                if ($v -eq '?') { $v = Select-MigFolder (Split-Path -Parent $cur) }
                if (-not $v) { $v = $cur }
                else {
                    $p = $v.TrimEnd('\')
                    if ((Test-Path $p -PathType Container)) { $p = Join-Path $p 'python.exe' }
                    $v = $p
                }
                $Config.Python = $v
            }
            3 {
                $cur = $Config.Zig
                $v = Read-MigLine 'zig.exe' $cur
                if ($v -eq '?') { $v = Select-MigFolder (Split-Path -Parent $cur) }
                if (-not $v) { $v = $cur }
                else {
                    $p = $v.TrimEnd('\')
                    if ((Test-Path $p -PathType Container)) { $p = Join-Path $p 'zig.exe' }
                    $v = $p
                }
                $Config.Zig = $v
            }
            4 {
                $cur = $Config.Cuda
                $v = Read-MigLine 'CUDA toolkit root' $cur
                if ($v -eq '?') { $v = Select-MigFolder $cur }
                if ($v) { $Config.Cuda = $v.TrimEnd('\') }
            }
            5 {
                $cur = $Config.Vcvars
                $v = Read-MigLine 'vcvarsall.bat' $cur
                if ($v -eq '?') { $v = Select-MigFolder (Split-Path -Parent $cur) }
                if ($v) {
                    $p = $v.TrimEnd('\')
                    if ((Test-Path $p -PathType Container)) { $p = Join-Path $p 'vcvarsall.bat' }
                    $Config.Vcvars = $p
                }
            }
            6 {
                $cur = $Config.ModelPath
                $v = Read-MigLine 'checkpoint folder (blank to leave unset)' $cur
                if ($v -eq '?') { $v = Select-MigFolder $cur }
                $Config.ModelPath = $v.TrimEnd('\')
            }
        }
    }
}

# ---- entry point ----------------------------------------------------------

function Get-MigConfig {
    param(
        [switch]$Quiet,          # no banner, no prompt: saved file, else detected defaults
        [switch]$Prompt,         # force the menu even when a saved file exists
        [switch]$Reset,          # ignore and overwrite the saved file
        [string]$Root,           # explicit overrides win over everything
        [string]$Python,
        [string]$Zig,
        [string]$Cuda,
        [string]$Vcvars,
        [string]$ModelPath,
        [string]$TfRef,
        [string]$RecipeRef
    )

    $saved = $null
    if (-not $Reset) { $saved = Read-MigSaved }
    $detected = Find-MigDefaults

    $cfg = [pscustomobject]@{
        Root      = $detected.Root
        Python    = $detected.Python
        Zig       = $detected.Zig
        Cuda      = $detected.Cuda
        Vcvars    = $detected.Vcvars
        ModelPath = $detected.ModelPath
        Sm        = 121
        TfRef     = $script:MigTfRef
        RecipeRef = $script:MigRecipeRef
        Repo      = $detected.Repo
        Source    = 'detected'
    }
    if ($saved) {
        if ($saved.Root)      { $cfg.Root      = $saved.Root }
        if ($saved.Python)    { $cfg.Python    = $saved.Python }
        if ($saved.Zig)       { $cfg.Zig       = $saved.Zig }
        if ($saved.Cuda)      { $cfg.Cuda      = $saved.Cuda }
        if ($saved.Vcvars)    { $cfg.Vcvars    = $saved.Vcvars }
        if ($saved.ModelPath) { $cfg.ModelPath = $saved.ModelPath }
        if ($saved.Sm)        { $cfg.Sm        = $saved.Sm }
        if ($saved.TfRef)     { $cfg.TfRef     = $saved.TfRef }
        if ($saved.RecipeRef) { $cfg.RecipeRef = $saved.RecipeRef }
        $cfg.Source = 'saved'
    }
    if ($Root)      { $cfg.Root      = $Root.TrimEnd('\') }
    if ($Python)    { $cfg.Python    = $Python }
    if ($Zig)       { $cfg.Zig       = $Zig }
    if ($Cuda)      { $cfg.Cuda      = $Cuda.TrimEnd('\') }
    if ($Vcvars)    { $cfg.Vcvars    = $Vcvars }
    if ($ModelPath) { $cfg.ModelPath = $ModelPath.TrimEnd('\') }
    if ($TfRef)     { $cfg.TfRef     = $TfRef }
    if ($RecipeRef -ne '') { $cfg.RecipeRef = $RecipeRef }

    if ($Prompt -and -not $Quiet) {
        $answered = Read-MigMenu $cfg $detected
        if (-not $answered) {
            Write-Host '  cancelled' -ForegroundColor Yellow
            return $null
        }
        $cfg = $answered
        $cfg.Source = 'menu'
        Save-MigConfig $cfg | Out-Null
    }

    $cfg | Add-Member -NotePropertyName EngineDir -NotePropertyValue (Join-Path $cfg.Root $script:MigEngineName) -Force
    $cfg | Add-Member -NotePropertyName RecipeDir -NotePropertyValue (Join-Path $cfg.Root $script:MigRecipeName) -Force
    return $cfg
}

# When run directly (not dot-sourced), show the menu and write the file: that is the "set up paths" entry.
if ($MyInvocation.InvocationName -ne '.' -and $MyInvocation.MyCommand.Path) {
    $cfg = Get-MigConfig -Prompt
    if ($cfg) {
        Write-Host ''
        Write-Host 'PATHS SET' -ForegroundColor Green
        Write-Host ("  engine  " + $cfg.EngineDir)
        Write-Host ("  recipe  " + $cfg.RecipeDir)
        Write-Host '  next:   .\scripts\Invoke-Migration.ps1'
    }
    exit 0
}
