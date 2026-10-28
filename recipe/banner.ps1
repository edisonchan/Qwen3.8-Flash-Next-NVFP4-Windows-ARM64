#Requires -Version 5.1
# The start.ps1 banner: the TensorFold ribbon as truecolour terminal art, with MIA AI LAB.
# Windows port of scripts/banner.sh -- the art is NOT duplicated here: it is extracted
# from banner.sh at runtime (byte-identical by construction), with the one intentional
# wording change for this machine: "one DGX Spark" -> "one RTX Spark".

$ErrorActionPreference = 'Stop'

function Get-BannerArt {
    param([string]$Block)   # wide | narrow
    $sh = Join-Path $PSScriptRoot 'banner.sh'
    if (-not (Test-Path $sh)) { return $null }
    $txt = [System.IO.File]::ReadAllText($sh, [System.Text.Encoding]::UTF8)
    $m = [regex]::Match($txt, "_banner_$Block\(\) \{\s*printf '%s\\n' '([\s\S]*?)'\s*\}")
    if (-not $m.Success) { return $null }
    return ($m.Groups[1].Value -replace 'one DGX Spark', 'one RTX Spark')
}

function Get-BannerText {
    param([int]$Columns = 120)
    if ($Columns -ge 108) { return Get-BannerArt 'wide' }
    if ($Columns -ge 86)  { return Get-BannerArt 'narrow' }
    return $null
}

function Show-Banner {
    param([switch]$Force)
    if (-not $Force) {
        if ([Console]::IsOutputRedirected) { return }
        $cols = 120
        try { $cols = [Console]::WindowWidth } catch { }
        $text = Get-BannerText -Columns $cols
    } else {
        $text = Get-BannerText -Columns 120
    }
    if ($text) { Write-Host $text }
}
