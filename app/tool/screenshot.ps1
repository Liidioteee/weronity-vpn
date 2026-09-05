# Capture the Weronity window to a PNG.
#   powershell -File app/tool/screenshot.ps1 -Out shot.png [-Proc weronity]
# Then Read the PNG. IMPORTANT: eyeball the result — if focus was stolen this can
# capture whatever window sits in that screen rectangle. See docs/gotchas.md #2.
param(
  [Parameter(Mandatory = $true)] [string]$Out,
  [string]$Proc = 'weronity'
)
. "$PSScriptRoot\_common.ps1"
Add-Type -AssemblyName System.Drawing

$h = Get-WeronityHandle -Proc $Proc
[Win]::ShowWindow($h, [Win]::SW_RESTORE) | Out-Null
[Win]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 500

$r = New-Object Win+RECT
[Win]::GetWindowRect($h, [ref]$r) | Out-Null
$w  = $r.Right - $r.Left
$ht = $r.Bottom - $r.Top
if ($w -le 0 -or $ht -le 0) { throw "Bad window rect ${w}x${ht}" }

if ([System.IO.Path]::IsPathRooted($Out)) { $path = $Out }
else { $path = Join-Path (Get-Location).Path $Out }

$bmp = New-Object System.Drawing.Bitmap $w, $ht
$g   = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r.Left, $r.Top, 0, 0, $bmp.Size)
$bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
Write-Host "saved $path  (${w}x${ht})"
