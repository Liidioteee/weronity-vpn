# Build the Windows debug target and (re)launch it.
#   powershell -File app/tool/run_windows.ps1 [-NoBuild]
param([switch]$NoBuild)

$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$app  = Join-Path $repo 'app'
$exe  = Join-Path $app  'build\windows\x64\runner\Debug\weronity.exe'

$env:JAVA_HOME = 'C:\Program Files\Java\jdk-21.0.10'
$env:PATH = "D:\sdk\flutter\bin;D:\sdk\go\bin;$env:PATH"

if (-not $NoBuild) {
  Push-Location $app
  try { flutter build windows --debug } finally { Pop-Location }
}
if (-not (Test-Path $exe)) { throw "not built: $exe" }

Get-Process -Name weronity -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 800
Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe)
Start-Sleep -Seconds 5

$p = Get-Process -Name weronity -ErrorAction SilentlyContinue | Select-Object -First 1
if ($p) { Write-Host "running: pid $($p.Id)  title '$($p.MainWindowTitle)'" }
else    { Write-Warning "weronity did not start" }
