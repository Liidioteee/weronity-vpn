//go:build !windows && !linux

package main

// interfaceOctets has no implementation on this platform yet (Android reports
// tun traffic through VpnService, macOS/iOS through the network extension), so
// vpn-mode byte counters read as zero rather than wrong.
func interfaceOctets(string) (tx, rx int64, ok bool) { return 0, 0, false }
