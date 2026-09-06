package main

import (
	"encoding/json"
	"testing"
)

func parseSummary(t *testing.T, s string) probeSummary {
	t.Helper()
	var sum probeSummary
	if err := json.Unmarshal([]byte(s), &sum); err != nil {
		t.Fatalf("summary not json: %v (%s)", err, s)
	}
	return sum
}

func TestTestNodeRejectsBadRequest(t *testing.T) {
	if sum := parseSummary(t, testNodeJSON("not json")); sum.Err == "" {
		t.Error("bad json should yield an error summary")
	}
	// hostile outbound type — rejected before any engine spins up
	req := `{"outbound":{"type":"socks","server":"1.1.1.1","server_port":1080}}`
	sum := parseSummary(t, testNodeJSON(req))
	if sum.Err == "" {
		t.Error("a non-proxy outbound type must be rejected")
	}
}

// A syntactically valid trojan node pointing at TEST-NET-1: the throwaway
// engine starts, every probe fails to connect, verdict = not reachable. Proves
// the isolated engine lifecycle + probe plumbing without a live key.
func TestTestNodeUnroutableIsNotReachable(t *testing.T) {
	t.Cleanup(stopEngine) // in case anything leaked; the probe uses its own box
	req := `{
		"outbound": {"type":"trojan","server":"192.0.2.1","server_port":443,"password":"x",
			"tls":{"enabled":true,"server_name":"example.com"}},
		"targets": ["https://www.google.com/generate_204"],
		"timeout_ms": 2500
	}`
	sum := parseSummary(t, testNodeJSON(req))
	if sum.Err != "" {
		t.Fatalf("engine should have started fine, got err: %s", sum.Err)
	}
	if sum.OK || sum.Reachable {
		t.Errorf("unroutable node must not be OK/reachable: %+v", sum)
	}
	if sum.BestMs != -1 {
		t.Errorf("best_ms should be -1 when nothing succeeded, got %d", sum.BestMs)
	}
	if len(sum.Hits) != 1 || sum.Hits[0].Err == "" {
		t.Errorf("expected one failed hit with an error, got %+v", sum.Hits)
	}
	// the main engine must be untouched
	if engineRunning() {
		t.Error("testNodeJSON must not start the main engine")
	}
}
