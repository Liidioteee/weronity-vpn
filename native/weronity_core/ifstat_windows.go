//go:build windows

package main

import (
	"net"

	"golang.org/x/sys/windows"
)

// interfaceOctets reads the adapter's cumulative octet counters via
// GetIfEntry2Ex (iphlpapi). `name` is the friendly interface name — the same
// string we hand sing-box as the tun `interface_name`.
func interfaceOctets(name string) (tx, rx int64, ok bool) {
	idx, found := interfaceIndex(name)
	if !found {
		return 0, 0, false
	}
	row := windows.MibIfRow2{InterfaceIndex: uint32(idx)}
	if err := windows.GetIfEntry2Ex(windows.MibIfEntryNormal, &row); err != nil {
		return 0, 0, false
	}
	return int64(row.OutOctets), int64(row.InOctets), true
}

func interfaceIndex(name string) (int, bool) {
	ifaces, err := net.Interfaces()
	if err != nil {
		return 0, false
	}
	for _, i := range ifaces {
		if i.Name == name {
			return i.Index, true
		}
	}
	return 0, false
}
