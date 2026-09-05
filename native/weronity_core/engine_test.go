package main

import (
	"encoding/json"
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
		t.Fatal("expected an error for invalid config json")
	}
	if engineRunning() {
		t.Fatal("engine must not be running after a rejected start")
	}
}

func TestStartStopLifecycle(t *testing.T) {
	t.Cleanup(stopEngine)

	if err := startEngine(`{"log":{"level":"info"}}`); err != nil {
		t.Fatalf("startEngine: %v", err)
	}
	if !engineRunning() {
		t.Fatal("engine should be running")
	}
	// Second start is a no-op, not an error.
	if err := startEngine(`{}`); err != nil {
		t.Fatalf("second startEngine: %v", err)
	}

	var snap map[string]any
	if err := json.Unmarshal([]byte(statsJSON()), &snap); err != nil {
		t.Fatalf("statsJSON not valid json: %v", err)
	}
	for _, k := range []string{"running", "rx_bytes", "tx_bytes", "uptime_ms"} {
		if _, ok := snap[k]; !ok {
			t.Errorf("stats snapshot missing %q", k)
		}
	}
	if snap["running"] != true {
		t.Errorf("stats.running = %v, want true", snap["running"])
	}

	stopEngine()
	if engineRunning() {
		t.Fatal("engine should be stopped")
	}
}

func TestEmitterReceivesLogEvents(t *testing.T) {
	t.Cleanup(func() {
		setEmitter(nil)
		stopEngine()
	})

	var mu chanGuard
	setEmitter(func(payload string) { mu.add(payload) })

	if err := startEngine(`{}`); err != nil {
		t.Fatalf("startEngine: %v", err)
	}
	got := mu.snapshot()
	if len(got) == 0 || !strings.Contains(strings.Join(got, "\n"), `"kind":"log"`) {
		t.Fatalf("expected a log event payload, got %v", got)
	}
	if !strings.Contains(strings.Join(got, "\n"), "engine started") {
		t.Errorf("expected a 'engine started' line, got %v", got)
	}
}

// chanGuard is a tiny mutex-guarded slice for collecting async emitter payloads.
type chanGuard struct {
	mu   sync.Mutex
	data []string
}

func (c *chanGuard) add(s string) {
	c.mu.Lock()
	c.data = append(c.data, s)
	c.mu.Unlock()
}

func (c *chanGuard) snapshot() []string {
	c.mu.Lock()
	defer c.mu.Unlock()
	out := make([]string, len(c.data))
	copy(out, c.data)
	return out
}
