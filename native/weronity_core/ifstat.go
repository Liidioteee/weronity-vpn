package main

import "sync/atomic"

// ---------------------------------------------------------------------------
//  TUN byte counters.
//
//  In proxy mode the counting relay sees every byte (relay.go). In vpn mode
//  there is no relay: traffic goes straight through the tun device. Rather than
//  re-enable sing-box's clash-api (a mutable control server we deliberately keep
//  out of the config — see config.go), we read the OS's own octet counters for
//  the adapter we created, by its fixed name (`tunInterfaceName`).
//
//  Direction, from the OS's point of view on a tun adapter:
//    OutOctets / tx_bytes — the host wrote packets into the tunnel  -> upload
//    InOctets  / rx_bytes — the tunnel delivered packets to the host -> download
//
//  Counters are absolute since the adapter appeared, so we subtract a baseline
//  taken at connect time to make them per-session.
// ---------------------------------------------------------------------------

var (
	tunBaseUp   atomic.Int64
	tunBaseDown atomic.Int64
	tunHaveBase atomic.Bool
)

// resetTunCounters re-baselines the per-session counters. Called on every start.
func resetTunCounters() {
	tunHaveBase.Store(false)
	tunBaseUp.Store(0)
	tunBaseDown.Store(0)
}

// tunCounters returns per-session (up, down) byte totals for the tun adapter,
// or (0, 0) when the platform has no implementation or the adapter is not up yet.
func tunCounters() (up, down int64) {
	tx, rx, ok := interfaceOctets(tunInterfaceName)
	if !ok {
		return 0, 0
	}
	if !tunHaveBase.Load() {
		tunBaseUp.Store(tx)
		tunBaseDown.Store(rx)
		tunHaveBase.Store(true)
		return 0, 0
	}
	up = tx - tunBaseUp.Load()
	down = rx - tunBaseDown.Load()
	// A counter that went backwards means the adapter was recreated; re-baseline
	// instead of reporting nonsense.
	if up < 0 || down < 0 {
		tunBaseUp.Store(tx)
		tunBaseDown.Store(rx)
		return 0, 0
	}
	return up, down
}
