//go:build windows

package main

import (
	"errors"
	"os"

	"golang.org/x/sys/windows"
)

// isElevated reports 1 if this process runs with an elevated token (admin),
// 0 if not, -1 if the check failed.
func isElevated() int {
	tok := windows.GetCurrentProcessToken()
	if tok.IsElevated() {
		return 1
	}
	return 0
}

// relaunchElevated spawns a fresh, elevated copy of this executable via the
// shell "runas" verb (which raises the UAC prompt) and returns:
//
//	0  — the elevated instance is starting; the caller should exit now
//	1  — the user declined the UAC prompt
//	-1 — some other failure
//
// No arguments are passed: the app restores its own state (Settings live in
// Hive), so the new instance lands where the old one was.
func relaunchElevated() int {
	exe, err := os.Executable()
	if err != nil {
		return -1
	}
	verb, err := windows.UTF16PtrFromString("runas")
	if err != nil {
		return -1
	}
	file, err := windows.UTF16PtrFromString(exe)
	if err != nil {
		return -1
	}
	if err := windows.ShellExecute(0, verb, file, nil, nil, windows.SW_SHOWNORMAL); err != nil {
		if errors.Is(err, windows.ERROR_CANCELLED) {
			return 1
		}
		return -1
	}
	return 0
}
