# Click at client-area coordinates of the Weronity window (relative to its
# top-left). Read a screenshot first to pick coordinates.
#   powershell -File app/tool/click.ps1 -X 220 -Y 117
param(
  [Parameter(Mandatory = $true)] [int]$X,
  [Parameter(Mandatory = $true)] [int]$Y,
  [string]$Proc = 'weronity'
)
. "$PSScriptRoot\_common.ps1"

$h = Get-WeronityHandle -Proc $Proc
[Win]::ShowWindow($h, [Win]::SW_RESTORE) | Out-Null
[Win]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 400

$r = New-Object Win+RECT
[Win]::GetWindowRect($h, [ref]$r) | Out-Null
$sx = $r.Left + $X
$sy = $r.Top + $Y
[Win]::SetCursorPos($sx, $sy) | Out-Null
Start-Sleep -Milliseconds 150
[Win]::mouse_event([Win]::LEFTDOWN, 0, 0, 0, [IntPtr]::Zero)
Start-Sleep -Milliseconds 60
[Win]::mouse_event([Win]::LEFTUP, 0, 0, 0, [IntPtr]::Zero)
Start-Sleep -Milliseconds 600
Write-Host "clicked screen ($sx,$sy)  [window at $($r.Left),$($r.Top)]"
