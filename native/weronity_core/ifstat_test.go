package main

import "testing"

// tunCounters reports *per-session* totals: the first read establishes the
// baseline, because an adapter carries counters from before we connected.
func TestTunCountersAreZeroWithoutAnAdapter(t *testing.T) {
	resetTunCounters()
	up, down := tunCounters()
	if up != 0 || down != 0 {
		t.Errorf("no adapter should read as 0/0, got %d/%d", up, down)
	}
}

func TestInterfaceOctetsMissesUnknownAdapters(t *testing.T) {
	if _, _, ok := interfaceOctets("weronity-does-not-exist-0"); ok {
		t.Error("an adapter that does not exist must not report ok")
	}
}

// A loopback adapter exists on every platform we build for, so this exercises
// the real syscall / sysfs path wherever one is implemented.
func TestInterfaceOctetsReadsARealAdapter(t *testing.T) {
	for _, name := range []string{"Loopback Pseudo-Interface 1", "lo"} {
		if tx, rx, ok := interfaceOctets(name); ok {
			if tx < 0 || rx < 0 {
				t.Errorf("%s: negative counters %d/%d", name, tx, rx)
			}
			return
		}
	}
	t.Skip("no known loopback adapter name on this host")
}
