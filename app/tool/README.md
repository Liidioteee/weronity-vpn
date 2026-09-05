# app/tool — dev helper scripts (Windows)

Used to run and drive the Windows debug build for visual checks, because
`computer-use` can't attach to a loose built `.exe`. See `docs/gotchas.md` #2 for
the failure modes.

```powershell
powershell -File app/tool/run_windows.ps1              # build --debug + relaunch
powershell -File app/tool/run_windows.ps1 -NoBuild     # just relaunch
powershell -File app/tool/screenshot.ps1 -Out shot.png # capture the window
powershell -File app/tool/click.ps1 -X 220 -Y 117      # click at client (x,y)
powershell -File app/tool/resize.ps1 -Width 1100 -Height 780
```

Workflow: `run_windows.ps1` → `screenshot.ps1` → `Read shot.png` → pick coords →
`click.ps1` → `screenshot.ps1` again. Always confirm the screenshot is actually
the Weronity window (focus theft can capture the wrong one). If `screenshot.ps1`
throws "No running 'weronity' window", the Flutter `MainWindowHandle == 0` quirk
hit — rerun `run_windows.ps1 -NoBuild`.
