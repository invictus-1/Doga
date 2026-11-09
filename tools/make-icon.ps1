# Renders assets/icon.svg to assets/doga.ico (16–256 px, PNG-compressed entries).
# Uses Edge headless for the SVG render and System.Drawing for the smaller sizes.
param([string]$Root = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$svg = Join-Path $Root 'assets\icon.svg'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("doga-icon-" + [guid]::NewGuid())
New-Item -ItemType Directory $tmp | Out-Null
$html = Join-Path $tmp 'icon.html'
$svgText = Get-Content $svg -Raw
"<!doctype html><html><body style='margin:0;background:transparent'>$svgText</body></html>" | Set-Content $html -Encoding utf8

$edge = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
if (!(Test-Path $edge)) { $edge = "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe" }
$big = Join-Path $tmp 'icon-256.png'
& $edge --headless=new --disable-gpu --hide-scrollbars --default-background-color=00000000 --window-size=256,256 --screenshot="$big" ("file:///" + ($html -replace '\\', '/')) 2>$null | Out-Null
Start-Sleep -Milliseconds 300

$src = [System.Drawing.Image]::FromFile($big)
$sizes = 256, 128, 64, 48, 32, 24, 16
$pngs = @()
foreach ($n in $sizes) {
  $bmp = New-Object System.Drawing.Bitmap $n, $n, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.InterpolationMode = 'HighQualityBicubic'; $g.PixelOffsetMode = 'HighQuality'; $g.SmoothingMode = 'HighQuality'
  $g.Clear([System.Drawing.Color]::Transparent)
  $g.DrawImage($src, 0, 0, $n, $n)
  $ms = New-Object IO.MemoryStream
  $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
  $pngs += , @($n, $ms.ToArray())
  $g.Dispose(); $bmp.Dispose()
}
$src.Dispose()

# ICO: ICONDIR + ICONDIRENTRY[n] + PNG blobs
$out = New-Object IO.MemoryStream
$w = New-Object IO.BinaryWriter $out
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$pngs.Count)
$offset = 6 + 16 * $pngs.Count
foreach ($p in $pngs) {
  $n = $p[0]; $data = $p[1]
  $w.Write([byte]($(if ($n -ge 256) { 0 } else { $n }))); $w.Write([byte]($(if ($n -ge 256) { 0 } else { $n })))
  $w.Write([byte]0); $w.Write([byte]0); $w.Write([uint16]1); $w.Write([uint16]32)
  $w.Write([uint32]$data.Length); $w.Write([uint32]$offset)
  $offset += $data.Length
}
foreach ($p in $pngs) { $w.Write($p[1]) }
$w.Flush()
[IO.File]::WriteAllBytes((Join-Path $Root 'assets\doga.ico'), $out.ToArray())
Copy-Item $big (Join-Path $Root 'assets\icon-256.png') -Force
Remove-Item $tmp -Recurse -Force
"wrote assets\doga.ico ($($out.Length) bytes)"
