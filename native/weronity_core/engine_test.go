package main

import (
	"encoding/json"
	"strings"
	"sync"
	"testing"
	"time"
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

// Boots a real sing-box against an unroutable endpoint: creation + start must
// succeed (dialing is lazy), stats must reflect it, stop must clean up.
func TestEngineLifecycleWithRealSingBox(t *testing.T) {
	t.Cleanup(stopEngine)

	var lines []string
	var mu sync.Mutex
	setEmitter(func(p string) { mu.Lock(); lines = append(lines, p); mu.Unlock() })
	t.Cleanup(func() { setEmitter(nil) })

	cfg := `{
		"outbound": {
			"type": "trojan",
			"server": "192.0.2.1",
			"server_port": 443,
			"password": "test",
			"tls": {"enabled": true, "server_name": "example.com"}
		},
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
	port, _ := snap["socks_port"].(float64)
	if port < 1 || port > 65535 {
		t.Errorf("stats.socks_port out of range: %v", snap["socks_port"])
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
	if !strings.Contains(joined, "sing-box up") || !strings.Contains(joined, "sing-box stopped") {
		t.Errorf("expected up/stopped log lines, got:\n%s", joined)
	}
}

func TestDoubleStartIsNoop(t *testing.T) {
	t.Cleanup(stopEngine)
	cfg := `{"outbound":{"type":"trojan","server":"192.0.2.2","server_port":443,"password":"x"},"self_test":false}`
	if err := startEngine(cfg); err != nil {
		t.Fatalf("first start: %v", err)
	}
	deadline := time.After(2 * time.Second)
	_ = deadline
	if err := startEngine(cfg); err != nil {
		t.Fatalf("second start should be a silent no-op, got: %v", err)
	}
}
