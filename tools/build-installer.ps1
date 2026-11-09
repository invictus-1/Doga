# Builds dist\Doga-Setup-<version>.exe (+ .sig when the release key is present):
# release doga.exe + libmpv + ui/, as one self-extracting installer.
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
} finally { Pop-Location }
