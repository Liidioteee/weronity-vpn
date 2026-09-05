# Shared Win32 helpers for the dev scripts. Dot-source this.
$ErrorActionPreference = 'Stop'

if (-not ('Win' -as [type])) {
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Win {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int h2, bool repaint);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, IntPtr extra);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  public const int SW_RESTORE = 9;
  public const int SW_NORMAL  = 1;
  public const uint LEFTDOWN = 0x0002, LEFTUP = 0x0004;
}
"@
}

function Get-WeronityHandle {
  param([string]$Proc = 'weronity')
  $p = Get-Process -Name $Proc -ErrorAction SilentlyContinue |
       Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
  if (-not $p) { throw "No running '$Proc' window (MainWindowHandle==0 quirk? kill & relaunch)." }
  return $p.MainWindowHandle
}
