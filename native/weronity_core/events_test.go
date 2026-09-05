package main

import "testing"

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
