#Requires -Version 7.2
<#
.SYNOPSIS
Regenerates the status badge images in assets\ (used as the Discord embed thumbnail). Development helper;
the generated PNGs ship with VeeamAware, so this does not need to run on the backup server.
#>
[CmdletBinding()]
param([int]$Size = 128)

Add-Type -AssemblyName System.Drawing
$dir = Join-Path $PSScriptRoot '..\assets'
New-Item -ItemType Directory -Force $dir | Out-Null

$badges = @{
    success  = @{ Color = '#23A55A'; Glyph = 'check' }
    warning  = @{ Color = '#F0B232'; Glyph = 'bang' }
    failed   = @{ Color = '#F23F43'; Glyph = 'cross' }
    info     = @{ Color = '#5865F2'; Glyph = 'bars' }
    security = @{ Color = '#9B59B6'; Glyph = 'shield' }
}

foreach ($name in $badges.Keys) {
    $b = $badges[$name]
    $c = [System.Drawing.ColorTranslator]::FromHtml($b.Color)
    $bmp = [System.Drawing.Bitmap]::new($Size, $Size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)
    $s = $Size / 128.0

    # Soft tinted disc with a solid ring, then a white-on-colour inner disc carrying the glyph.
    $g.FillEllipse([System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(56, $c)), 2 * $s, 2 * $s, 124 * $s, 124 * $s)
    $g.FillEllipse([System.Drawing.SolidBrush]::new($c), 18 * $s, 18 * $s, 92 * $s, 92 * $s)

    $pen = [System.Drawing.Pen]::new([System.Drawing.Color]::White, 11 * $s)
    $pen.StartCap = 'Round'; $pen.EndCap = 'Round'; $pen.LineJoin = 'Round'
    $white = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::White)
    $pt = { param($x, $y) [System.Drawing.PointF]::new($x * $s, $y * $s) }
    switch ($b.Glyph) {
        'check' { $g.DrawLines($pen, [System.Drawing.PointF[]]@((& $pt 44 66), (& $pt 58 80), (& $pt 85 50))) }
        'cross' { $g.DrawLine($pen, (& $pt 48 48), (& $pt 80 80)); $g.DrawLine($pen, (& $pt 80 48), (& $pt 48 80)) }
        'bang' { $g.DrawLine($pen, (& $pt 64 42), (& $pt 64 70)); $g.FillEllipse($white, 57 * $s, 80 * $s, 14 * $s, 14 * $s) }
        'bars' {
            $pen.Width = 10 * $s
            $g.DrawLine($pen, (& $pt 48 82), (& $pt 48 66)); $g.DrawLine($pen, (& $pt 64 82), (& $pt 64 48)); $g.DrawLine($pen, (& $pt 80 82), (& $pt 80 58))
        }
        'shield' {
            $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
            $path.AddPolygon([System.Drawing.PointF[]]@((& $pt 64 40), (& $pt 86 48), (& $pt 84 70), (& $pt 64 88), (& $pt 44 70), (& $pt 42 48)))
            $g.FillPath($white, $path)
        }
    }
    $out = Join-Path $dir "status-$name.png"
    $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    Write-Host "Wrote $out"
}
