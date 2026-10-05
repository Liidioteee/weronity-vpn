//go:build linux

package main

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// interfaceOctets reads the adapter's cumulative octet counters from sysfs.
func interfaceOctets(name string) (tx, rx int64, ok bool) {
	if name == "" || strings.ContainsAny(name, `/\`) {
		return 0, 0, false
	}
	base := filepath.Join("/sys/class/net", name, "statistics")
	tx, okTx := readCounter(filepath.Join(base, "tx_bytes"))
	rx, okRx := readCounter(filepath.Join(base, "rx_bytes"))
	return tx, rx, okTx && okRx
}

func readCounter(path string) (int64, bool) {
	b, err := os.ReadFile(path) //nolint:gosec // fixed, non-user path under /sys
	if err != nil {
		return 0, false
	}
	v, err := strconv.ParseInt(strings.TrimSpace(string(b)), 10, 64)
	if err != nil {
		return 0, false
	}
	return v, true
}
