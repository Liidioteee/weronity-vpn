# Move + resize the Weronity window (test responsive layout).
#   powershell -File app/tool/resize.ps1 -Width 1100 -Height 780
param(
  [Parameter(Mandatory = $true)] [int]$Width,
  [Parameter(Mandatory = $true)] [int]$Height,
  [int]$X = 80,
  [int]$Y = 60,
  [string]$Proc = 'weronity'
)
. "$PSScriptRoot\_common.ps1"

$h = Get-WeronityHandle -Proc $Proc
[Win]::ShowWindow($h, [Win]::SW_NORMAL) | Out-Null
[Win]::MoveWindow($h, $X, $Y, $Width, $Height, $true) | Out-Null
[Win]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 800
Write-Host "resized to ${Width}x${Height} at ($X,$Y)"
