package main

import (
	"strings"
	"testing"

	"github.com/sagernet/sing-box/log"
)

func TestEventBufferDrainAndCap(t *testing.T) {
	drainEvents() // clear anything from other tests

	for i := 0; i < eventBufferCap+250; i++ {
		pushEvent(`{"n":` + itoa(i) + `}`)
	}
	got := drainEvents()
	if len(got) != eventBufferCap {
		t.Fatalf("drain returned %d, want cap %d", len(got), eventBufferCap)
	}
	// oldest were dropped: first surviving entry is index 250
	if got[0] != `{"n":250}` {
		t.Errorf("oldest not dropped, got %s", got[0])
	}
	if drained := drainEvents(); len(drained) != 0 {
		t.Errorf("second drain not empty: %v", drained)
	}
}

func TestEmitFeedsBuffer(t *testing.T) {
	drainEvents()
	emit("info", "test", "hello")
	got := drainEvents()
	if len(got) != 1 || got[0] == "" {
		t.Fatalf("emit did not buffer: %v", got)
	}
	if want := `"message":"hello"`; !contains(got[0], want) {
		t.Errorf("payload missing %s: %s", want, got[0])
	}
}

func itoa(i int) string {
	if i == 0 {
		return "0"
	}
	var b [20]byte
	pos := len(b)
	for i > 0 {
		pos--
		b[pos] = byte('0' + i%10)
		i /= 10
	}
	return string(b[pos:])
}

func contains(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}

// The platform writer gets every sing-box message, coloured for a terminal: it
// must drop what is more verbose than the configured level and strip the codes.
func TestPlatformLogFiltersLevelAndStripsColour(t *testing.T) {
	drainEvents()
	w := newPlatformLog("info")
	w.WriteMessage(log.LevelTrace, "per-packet noise")
	w.WriteMessage(log.LevelDebug, "debug noise")
	w.WriteMessage(log.LevelInfo, "\x1b[36mINFO\x1b[0m[0045] [\x1b[38;5;231m3928509655\x1b[0m 0ms] inbound connection")
	w.WriteMessage(log.LevelError, "boom")

	events := drainEvents()
	if len(events) != 2 {
		t.Fatalf("want 2 forwarded events (info + error), got %d: %v", len(events), events)
	}
	if strings.Contains(events[0], "\\u001b") || strings.Contains(events[0], "[36m") {
		t.Errorf("colour codes survived: %s", events[0])
	}
	if !strings.Contains(events[0], "INFO[0045] [3928509655 0ms] inbound connection") {
		t.Errorf("message mangled: %s", events[0])
	}

	// an unknown level name falls back to info rather than letting everything through
	if got := newPlatformLog("nonsense").maxLevel; got != log.LevelInfo {
		t.Errorf("fallback level = %v, want info", got)
	}
	// debug lets debug through but still not trace
	d := newPlatformLog("debug")
	d.WriteMessage(log.LevelDebug, "d")
	d.WriteMessage(log.LevelTrace, "t")
	if got := len(drainEvents()); got != 1 {
		t.Errorf("debug level forwarded %d events, want 1", got)
	}
}
