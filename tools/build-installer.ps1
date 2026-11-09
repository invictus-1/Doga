# Builds dist\Doga-Setup-<version>.exe (+ .sig when the release key is present):
# release doga.exe + libmpv + ui/, as one self-extracting installer.
# Also builds dist\Doga-<version>-portable.zip: the same files in a folder that runs as is.
param([string]$Root = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
Push-Location $Root
try {
  # Keep build-machine paths (and so the Windows user name) out of the binary.
  # Computed here at build time, so nothing personal is written into this script.
  $env:RUSTFLAGS = "--remap-path-prefix=$env:USERPROFILE=~ --remap-path-prefix=$Root=."
  cargo build --release
  if ($LASTEXITCODE -ne 0) { throw "cargo build failed" }
  $version = (Select-String -Path Cargo.toml -Pattern '^version\s*=\s*"([^"]+)"').Matches[0].Groups[1].Value
  New-Item -ItemType Directory -Force dist | Out-Null
  $out = "dist\Doga-Setup-$version.exe"
  # release doga.exe is a GUI-subsystem program, so wait for it explicitly
  $p = Start-Process -FilePath .\target\release\doga.exe -ArgumentList '--pack', $out -Wait -PassThru -NoNewWindow
  if ($p.ExitCode -ne 0) { throw "pack failed" }
  # Sign for the in-app updater (the private key lives outside the repo).
  if (Test-Path "$env:USERPROFILE\.doga-release\update.key") {
    $p = Start-Process -FilePath .\target\release\doga.exe -ArgumentList '--sign', $out -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -ne 0) { throw "signing failed" }
  } else {
    Write-Warning "No release key: the installer is unsigned and Dōga's updater won't offer it."
  }
  "$out  {0:N1} MB" -f ((Get-Item $out).Length / 1MB)
  "sha256 " + (Get-FileHash $out -Algorithm SHA256).Hash.ToLower()

  # Portable zip: unzip anywhere and run doga.exe. portable.txt beside the exe is what tells
  # it to keep its settings in a data folder there instead of %APPDATA%.
  Add-Type -AssemblyName System.IO.Compression
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip = Join-Path $Root "dist\Doga-$version-portable.zip"
  if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip }
  $z = [IO.Compression.ZipFile]::Open($zip, 'Create')
  try {
    $add = { param($src, $name) [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($z, $src, "Doga/$name", 'Optimal') }
    & $add (Join-Path $Root 'target\release\doga.exe') 'doga.exe'
    & $add (Join-Path $Root 'vendor\mpv\libmpv-2.dll') 'libmpv-2.dll'
    & $add (Join-Path $Root 'LICENSE') 'LICENSE.txt'
    & $add (Join-Path $Root 'THIRD_PARTY.md') 'THIRD_PARTY.md'
    $ui = Join-Path $Root 'ui'
    Get-ChildItem -LiteralPath $ui -Recurse -File | Sort-Object FullName | ForEach-Object {
      & $add $_.FullName ('ui/' + $_.FullName.Substring($ui.Length + 1).Replace('\', '/'))
    }
    $name = "D$([char]0x14D)ga"
    $w = New-Object IO.StreamWriter($z.CreateEntry('Doga/portable.txt').Open())
    $w.Write("$name portable`r`n`r`n" +
      "While this file sits beside doga.exe, settings, resume positions and recent files are`r`n" +
      "kept in the data folder here instead of %APPDATA%\Doga. Nothing is written elsewhere`r`n" +
      "(screenshots still go to Pictures). Delete this file and $name behaves like an installed copy.`r`n`r`n" +
      "To update: download the new zip and replace doga.exe, libmpv-2.dll and the ui folder.`r`n" +
      "Keep the data folder.`r`n")
    $w.Dispose()
  } finally { $z.Dispose() }
  "$(Split-Path $zip -Leaf)  {0:N1} MB" -f ((Get-Item -LiteralPath $zip).Length / 1MB)
  "sha256 " + (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLower()
} finally { Pop-Location }
