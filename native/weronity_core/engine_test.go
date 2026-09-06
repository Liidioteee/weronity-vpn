package main

import (
	"encoding/json"
	"os"
	"strings"
	"sync"
	"testing"
)

func TestPing(t *testing.T) {
	if got := ping(41); got != 42 {
		t.Fatalf("ping(41) = %d, want 42", got)
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
