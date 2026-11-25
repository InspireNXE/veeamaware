#Requires -Version 7.2
<#
.SYNOPSIS
Rebuilds the README screenshots in docs\images from made-up sample data. Runs tools\New-SampleCards.ps1, then
screenshots each card in Microsoft Edge (headless) and trims the empty space below it. Needs Windows, Edge and
internet access (the preview page loads the Adaptive Cards renderer and Twemoji from jsDelivr).

.EXAMPLE
pwsh -File .\tools\New-ReadmeImages.ps1
pwsh -File .\tools\New-ReadmeImages.ps1 -Card failure -View discord
#>
[CmdletBinding()]
param(
    [string[]]$Card = @('success', 'failure', 'warning', 'repository', 'malware', 'service', 'digest'),
    [ValidateSet('discord', 'teams')][string[]]$View = @('discord', 'teams'),
    [string]$OutDir = (Join-Path $PSScriptRoot '..\docs\images'),
    [double]$Scale = 2
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") |
    Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $edge) { throw 'Microsoft Edge not found.' }
Add-Type -AssemblyName System.Drawing

$work = Join-Path ([IO.Path]::GetTempPath()) "veeamaware-images-$PID"
& (Join-Path $PSScriptRoot 'New-SampleCards.ps1') -Card $Card -OutDir $work | Out-Null
New-Item -ItemType Directory $OutDir -Force | Out-Null
$OutDir = (Resolve-Path $OutDir).Path
$page = ([uri](Join-Path $work 'preview.html')).AbsoluteUri
$profileDir = Join-Path $work 'edge-profile'

function Get-TrimmedHeight([System.Drawing.Bitmap]$Bmp) {
    # Rows from the bottom that match the page background in a few sample columns are empty.
    $bg = $Bmp.GetPixel(2, $Bmp.Height - 2).ToArgb()
    $cols = @([int]($Bmp.Width * 0.1), [int]($Bmp.Width * 0.3), [int]($Bmp.Width * 0.5), [int]($Bmp.Width * 0.7), [int]($Bmp.Width * 0.9))
    for ($y = $Bmp.Height - 1; $y -gt 0; $y--) {
        foreach ($x in $cols) { if ($Bmp.GetPixel($x, $y).ToArgb() -ne $bg) { return [Math]::Min($Bmp.Height, $y + 1 + [int](16 * $Scale)) } }
    }
    return $Bmp.Height
}

try {
    foreach ($c in $Card) {
        foreach ($v in $View) {
            $raw = Join-Path $work "$c-$v.raw.png"
            $out = Join-Path $OutDir "$c-$v.png"
            $edgeArgs = @('--headless=new', '--disable-gpu', '--hide-scrollbars', "--user-data-dir=$profileDir", '--allow-file-access-from-files',
                "--force-device-scale-factor=$Scale", '--window-size=640,2600', '--virtual-time-budget=8000', "--screenshot=$raw", "$page`?card=$c&view=$v")
            & $edge @edgeArgs 2>&1 | Out-Null
            # msedge.exe hands the work to another process and returns early: wait for the file to settle.
            $deadline = (Get-Date).AddSeconds(90); $last = -1
            while ((Get-Date) -lt $deadline) {
                $len = if (Test-Path $raw) { (Get-Item $raw).Length } else { -1 }
                if ($len -gt 0 -and $len -eq $last) { break }
                $last = $len; Start-Sleep -Milliseconds 750
            }
            if (-not (Test-Path $raw)) { throw "Edge wrote no screenshot for $c/$v" }
            $bmp = [System.Drawing.Bitmap]::new($raw)
            try {
                $h = Get-TrimmedHeight $bmp
                $crop = $bmp.Clone([System.Drawing.Rectangle]::new(0, 0, $bmp.Width, $h), $bmp.PixelFormat)
                try { $crop.Save($out, [System.Drawing.Imaging.ImageFormat]::Png) } finally { $crop.Dispose() }
            }
            finally { $bmp.Dispose() }
            Write-Host "$c-$v.png  $([int]((Get-Item $out).Length / 1KB)) KB"
        }
    }
}
finally { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }
