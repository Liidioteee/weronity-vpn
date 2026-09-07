package main

import (
	"encoding/json"
	"os"
	"runtime"
	"strings"
	"sync"
	"testing"
)

func TestPing(t *testing.T) {
	if got := ping(41); got != 42 {
		t.Fatalf("ping(41) = %d, want 42", got)
	}
}

func TestIsElevatedReturnsAKnownValue(t *testing.T) {
	// On Windows it must be a definite yes/no; the stub build returns -1.
	got := isElevated()
	if runtime.GOOS == "windows" {
		if got != 0 && got != 1 {
			t.Fatalf("isElevated() = %d on windows, want 0 or 1", got)
		}
	} else if got != -1 {
		t.Fatalf("isElevated() = %d on %s, want -1", got, runtime.GOOS)
	}
}

func TestStartRejectsInvalidJSON(t *testing.T) {
	t.Cleanup(stopEngine)
	if err := startEngine("not json"); err == nil {
		t.Fatal("expected an error for invalid start config")
	}
	if engineRunning() {
		t.Fatal("engine must not be running after a rejected start")
	}
}

func TestStartRejectsHostileOutboundType(t *testing.T) {
	t.Cleanup(stopEngine)
	cfg := `{"outbound":{"type":"direct","server":"127.0.0.1","server_port":1},"self_test":false}`
	if err := startEngine(cfg); err == nil {
		t.Fatal("a 'direct' outbound must be rejected before the engine starts")
	}
	if engineRunning() {
		t.Fatal("engine must not be running")
	}
}

// vpn mode must still reject a hostile outbound *before* any tun device is
// created (sanitize happens first). Safe to run anywhere — never reaches b.Start.
func TestVpnModeStillSanitizesOutbound(t *testing.T) {
	t.Cleanup(stopEngine)
	cfg := `{"outbound":{"type":"socks","server":"1.1.1.1","server_port":1080},"mode":"vpn","self_test":false}`
	if err := startEngine(cfg); err == nil {
		t.Fatal("a 'socks' outbound must be rejected in vpn mode too")
	}
	if engineRunning() {
		t.Fatal("engine must not be running")
	}
}

// Full VPN lifecycle — GATED. Running it creates a real TUN device and rewrites
// the host route table (auto_route), which on a dev/CI machine cuts the box off
// the network. Only runs with WRN_ALLOW_TUN=1 on a machine where that is safe.
func TestStartVpnModeLifecycle(t *testing.T) {
	if os.Getenv("WRN_ALLOW_TUN") != "1" {
		t.Skip("set WRN_ALLOW_TUN=1 to run the real TUN lifecycle (reroutes all host traffic)")
	}
	t.Cleanup(stopEngine)
	cfg := `{
		"outbound": {"type":"trojan","server":"192.0.2.1","server_port":443,"password":"x",
			"tls":{"enabled":true,"server_name":"example.com"}},
		"mode": "vpn",
		"self_test": false,
		"log_level": "info"
	}`
	if err := startEngine(cfg); err != nil {
		t.Fatalf("startEngine vpn: %v", err)
	}
	var snap map[string]any
	if err := json.Unmarshal([]byte(statsJSON()), &snap); err != nil {
		t.Fatalf("statsJSON: %v", err)
	}
	if snap["mode"] != "vpn" {
		t.Errorf("stats.mode = %v, want vpn", snap["mode"])
	}
	if snap["listen"] != "tun" {
		t.Errorf("stats.listen = %v, want tun", snap["listen"])
	}
	stopEngine()
	if engineRunning() {
		t.Fatal("engine should be stopped")
	}
}

// Boots a real sing-box against an unroutable endpoint: creation + start must
// succeed (dialing is lazy), stats must reflect it, stop must clean up.
func TestEngineLifecycleWithRealSingBox(t *testing.T) {
	t.Cleanup(stopEngine)

	var lines []string
	var mu sync.Mutex
	setEmitter(func(p string) { mu.Lock(); lines = append(lines, p); mu.Unlock() })
	t.Cleanup(func() { setEmitter(nil) })

	// listen_port 0 -> the relay takes a free port (no clash with 55555 / CI)
	cfg := `{
		"outbound": {
			"type": "trojan",
			"server": "192.0.2.1",
			"server_port": 443,
			"password": "test",
			"tls": {"enabled": true, "server_name": "example.com"}
		},
		"mode": "proxy",
		"listen_port": 0,
		"self_test": false,
		"log_level": "info"
	}`
	if err := startEngine(cfg); err != nil {
		t.Fatalf("startEngine with a valid trojan config: %v", err)
	}
	if !engineRunning() {
		t.Fatal("engine should be running")
	}

	var snap map[string]any
	if err := json.Unmarshal([]byte(statsJSON()), &snap); err != nil {
		t.Fatalf("statsJSON invalid: %v", err)
	}
	if snap["running"] != true {
		t.Errorf("stats.running = %v", snap["running"])
	}
	if snap["mode"] != "proxy" {
		t.Errorf("stats.mode = %v", snap["mode"])
	}
	port, _ := snap["socks_port"].(float64)
	if port < 1 || port > 65535 {
		t.Errorf("stats.socks_port out of range: %v", snap["socks_port"])
	}
	if listen, _ := snap["listen"].(string); !strings.HasPrefix(listen, "127.0.0.1:") {
		t.Errorf("stats.listen = %v", snap["listen"])
	}
	for _, k := range []string{"up_bytes", "down_bytes", "up_bps", "down_bps", "ping_ms"} {
		if _, ok := snap[k]; !ok {
			t.Errorf("stats missing %q", k)
		}
	}

	stopEngine()
	if engineRunning() {
		t.Fatal("engine should be stopped")
	}

	// second stop is a no-op
	stopEngine()

	mu.Lock()
	joined := strings.Join(lines, "\n")
	mu.Unlock()
	if !strings.Contains(joined, "прокси поднят") || !strings.Contains(joined, "движок остановлен") {
		t.Errorf("expected up/stopped log lines, got:\n%s", joined)
	}
}

func TestDoubleStartIsNoop(t *testing.T) {
	t.Cleanup(stopEngine)
	cfg := `{"outbound":{"type":"trojan","server":"192.0.2.2","server_port":443,"password":"x"},"listen_port":0,"self_test":false}`
	if err := startEngine(cfg); err != nil {
		t.Fatalf("first start: %v", err)
	}
	if err := startEngine(cfg); err != nil {
		t.Fatalf("second start should be a silent no-op, got: %v", err)
	}
}

// The hot-swap path against a *real* sing-box: three unroutable candidates
// become a selector group, and selectCandidate moves between them without the
// engine restarting. Proxy mode, so no tun and no privileges are needed — the
// selector machinery is identical in vpn mode.
func TestSelectorHotSwapWithRealSingBox(t *testing.T) {
	t.Cleanup(stopEngine)
	stopEngine()

	cfg := `{
		"outbounds": [
			{"type":"trojan","server":"192.0.2.1","server_port":443,"password":"a"},
			{"type":"trojan","server":"192.0.2.2","server_port":443,"password":"b"},
			{"type":"trojan","server":"192.0.2.3","server_port":443,"password":"c"}
		],
		"mode": "proxy",
		"listen_port": 0,
		"self_test": false
	}`
	if err := startEngine(cfg); err != nil {
		t.Fatalf("startEngine with a candidate set: %v", err)
	}

	snap := statsMap(t)
	if snap["can_hotswap"] != true {
		t.Fatalf("stats.can_hotswap = %v, want true", snap["can_hotswap"])
	}
	if n, _ := snap["candidates"].(float64); int(n) != 3 {
		t.Errorf("stats.candidates = %v, want 3", snap["candidates"])
	}
	if snap["active_tag"] != nodeTag(0) {
		t.Errorf("stats.active_tag = %v, want %q", snap["active_tag"], nodeTag(0))
	}

	if err := selectCandidate(2); err != nil {
		t.Fatalf("hot-swap to candidate 2: %v", err)
	}
	if !engineRunning() {
		t.Fatal("hot-swap must not stop the engine")
	}
	if tag := statsMap(t)["active_tag"]; tag != nodeTag(2) {
		t.Errorf("after swap active_tag = %v, want %q", tag, nodeTag(2))
	}

	if err := selectCandidate(3); err == nil {
		t.Error("an out-of-range candidate should be refused")
	}
	if err := selectCandidate(-1); err == nil {
		t.Error("a negative candidate should be refused")
	}
	// The refusals must not have disturbed the live selection.
	if tag := statsMap(t)["active_tag"]; tag != nodeTag(2) {
		t.Errorf("a refused swap changed the selection to %v", tag)
	}
}

// A single-node session has no selector group, so hot-swap must refuse and let
// the caller fall back to stop/start.
func TestHotSwapRefusedForASingleNodeSession(t *testing.T) {
	t.Cleanup(stopEngine)
	stopEngine()

	cfg := `{"outbound":{"type":"trojan","server":"192.0.2.9","server_port":443,"password":"x"},"listen_port":0,"self_test":false}`
	if err := startEngine(cfg); err != nil {
		t.Fatalf("startEngine: %v", err)
	}
	snap := statsMap(t)
	if snap["can_hotswap"] != false {
		t.Errorf("stats.can_hotswap = %v, want false", snap["can_hotswap"])
	}
	if snap["active_tag"] != proxyTag {
		t.Errorf("stats.active_tag = %v, want %q", snap["active_tag"], proxyTag)
	}
	if err := selectCandidate(0); err == nil {
		t.Error("hot-swap without a selector group should be refused")
	}
	if !engineRunning() {
		t.Error("a refused hot-swap must leave the engine running")
	}
}

// A backup we cannot sanitise is dropped, but the node the user picked is not.
func TestHostileBackupIsDroppedNotFatal(t *testing.T) {
	t.Cleanup(stopEngine)
	stopEngine()

	cfg := `{
		"outbounds": [
			{"type":"trojan","server":"192.0.2.1","server_port":443,"password":"a"},
			{"type":"direct","server":"192.0.2.2","server_port":443},
			{"type":"trojan","server":"192.0.2.3","server_port":443,"password":"c"}
		],
		"listen_port": 0,
		"self_test": false
	}`
	if err := startEngine(cfg); err != nil {
		t.Fatalf("a bad backup should not sink the session: %v", err)
	}
	snap := statsMap(t)
	if n, _ := snap["candidates"].(float64); int(n) != 2 {
		t.Errorf("candidates = %v, want 2 (the hostile one dropped)", snap["candidates"])
	}
	// The dropped entry must not shift the caller's numbering: index 2 is still
	// the third node it sent, and index 1 (the one dropped) is simply gone.
	if err := selectCandidate(2); err != nil {
		t.Errorf("selecting the caller's index 2: %v", err)
	}
	if err := selectCandidate(1); err == nil {
		t.Error("a dropped candidate must not be selectable")
	}
	if tag := statsMap(t)["active_tag"]; tag != nodeTag(1) {
		t.Errorf("caller index 2 should map to %q, got %v", nodeTag(1), tag)
	}
}

// …but a hostile *first* candidate is the node the user chose, so it is fatal.
func TestHostileFirstCandidateIsFatal(t *testing.T) {
	t.Cleanup(stopEngine)
	stopEngine()

	cfg := `{
		"outbounds": [
			{"type":"direct","server":"192.0.2.1","server_port":443},
			{"type":"trojan","server":"192.0.2.3","server_port":443,"password":"c"}
		],
		"listen_port": 0,
		"self_test": false
	}`
	if err := startEngine(cfg); err == nil {
		t.Error("a hostile primary node must be rejected")
	}
	if engineRunning() {
		t.Error("engine should not be running")
	}
}

// When every backup is rejected the session degrades to the single-node shape:
// the remaining node keeps the "proxy" tag and no selector wraps a group of one.
func TestAllBackupsRejectedFallsBackToSingleNode(t *testing.T) {
	t.Cleanup(stopEngine)
	stopEngine()

	cfg := `{
		"outbounds": [
			{"type":"trojan","server":"192.0.2.1","server_port":443,"password":"a"},
			{"type":"block"}
		],
		"listen_port": 0,
		"self_test": false
	}`
	if err := startEngine(cfg); err != nil {
		t.Fatalf("startEngine: %v", err)
	}
	snap := statsMap(t)
	if snap["active_tag"] != proxyTag {
		t.Errorf("active_tag = %v, want %q", snap["active_tag"], proxyTag)
	}
	if snap["can_hotswap"] != false {
		t.Errorf("can_hotswap = %v, want false", snap["can_hotswap"])
	}
}

func statsMap(t *testing.T) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal([]byte(statsJSON()), &m); err != nil {
		t.Fatalf("statsJSON invalid: %v", err)
	}
	return m
}
