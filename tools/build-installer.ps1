# Builds dist\Doga-Setup.exe: release doga.exe + libmpv + ui/, as one self-extracting installer.
param([string]$Root = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
Push-Location $Root
try {
  # Keep build-machine paths (and so the Windows user name) out of the binary.
  # Computed here at build time, so nothing personal is written into this script.
  $env:RUSTFLAGS = "--remap-path-prefix=$env:USERPROFILE=~ --remap-path-prefix=$Root=."
  cargo build --release
  if ($LASTEXITCODE -ne 0) { throw "cargo build failed" }
  New-Item -ItemType Directory -Force dist | Out-Null
  # release doga.exe is a GUI-subsystem program, so wait for it explicitly
  $p = Start-Process -FilePath .\target\release\doga.exe -ArgumentList '--pack', 'dist\Doga-Setup.exe' -Wait -PassThru -NoNewWindow
  if ($p.ExitCode -ne 0) { throw "pack failed" }
  "dist\Doga-Setup.exe  {0:N1} MB" -f ((Get-Item dist\Doga-Setup.exe).Length / 1MB)
} finally { Pop-Location }
