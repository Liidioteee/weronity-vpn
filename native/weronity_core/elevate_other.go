//go:build !windows

package main

// On non-Windows platforms there is no UAC. VPN mode's privilege handling
// (root / CAP_NET_ADMIN) is done by the launcher / platform layer instead.

func isElevated() int { return -1 }

func relaunchElevated() int { return -1 }
