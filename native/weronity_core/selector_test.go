package main

import (
	"encoding/json"
	"testing"
)

func trojanNode(t *testing.T, host string) map[string]any {
	t.Helper()
	return mustJSON(t, `{"type":"trojan","server":"`+host+`","server_port":443,"password":"p"}`)
}

// cleanSet sanitises n fixture nodes the way startEngine does.
func cleanSet(t *testing.T, hosts ...string) []map[string]any {
	t.Helper()
	out := make([]map[string]any, 0, len(hosts))
	for i, h := range hosts {
		tag := proxyTag
		if len(hosts) > 1 {
			tag = nodeTag(i)
		}
		san, err := sanitizeOutbound(trojanNode(t, h), tag)
		if err != nil {
			t.Fatalf("sanitize %s: %v", h, err)
		}
		out = append(out, san.Outbound)
	}
	return out
}

type parsedConfig struct {
	Inbounds []struct {
		Type          string `json:"type"`
		InterfaceName string `json:"interface_name"`
		StrictRoute   bool   `json:"strict_route"`
	} `json:"inbounds"`
	Outbounds []struct {
		Type      string   `json:"type"`
		Tag       string   `json:"tag"`
		Outbounds []string `json:"outbounds"`
		Default   string   `json:"default"`
		Interrupt bool     `json:"interrupt_exist_connections"`
		Resolver  string   `json:"domain_resolver"`
	} `json:"outbounds"`
	Route struct {
		Final string `json:"final"`
	} `json:"route"`
}

func parseCfg(t *testing.T, raw []byte) parsedConfig {
	t.Helper()
	var c parsedConfig
	if err := json.Unmarshal(raw, &c); err != nil {
		t.Fatalf("generated config is not valid json: %v", err)
	}
	return c
}

// A single candidate keeps the pre-3.3b shape: the node *is* "proxy", no group.
func TestSingleCandidateHasNoSelector(t *testing.T) {
	raw, err := buildSingBoxConfig(cleanSet(t, "1.2.3.4"), 10808, "info")
	if err != nil {
		t.Fatalf("buildSingBoxConfig: %v", err)
	}
	c := parseCfg(t, raw)
	if len(c.Outbounds) != 2 {
		t.Fatalf("want 2 outbounds, got %d", len(c.Outbounds))
	}
	if c.Outbounds[0].Tag != proxyTag || c.Outbounds[0].Type != "trojan" {
		t.Errorf("first outbound = %q/%q", c.Outbounds[0].Tag, c.Outbounds[0].Type)
	}
	if c.Route.Final != proxyTag {
		t.Errorf("route.final = %q", c.Route.Final)
	}
}

func TestMultipleCandidatesBuildASelectorGroup(t *testing.T) {
	builders := map[string]func() ([]byte, error){
		"proxy": func() ([]byte, error) {
			return buildSingBoxConfig(cleanSet(t, "1.1.1.1", "2.2.2.2", "3.3.3.3"), 10808, "info")
		},
		"vpn": func() ([]byte, error) {
			return buildTunConfig(cleanSet(t, "1.1.1.1", "2.2.2.2", "3.3.3.3"), "info", false)
		},
	}
	for name, build := range builders {
		t.Run(name, func(t *testing.T) {
			raw, err := build()
			if err != nil {
				t.Fatalf("build: %v", err)
			}
			c := parseCfg(t, raw)
			if len(c.Outbounds) != 5 { // 3 nodes + selector + direct
				t.Fatalf("want 5 outbounds, got %d", len(c.Outbounds))
			}
			for i := 0; i < 3; i++ {
				if c.Outbounds[i].Tag != nodeTag(i) {
					t.Errorf("outbound %d tagged %q, want %q", i, c.Outbounds[i].Tag, nodeTag(i))
				}
			}
			sel := c.Outbounds[3]
			if sel.Type != "selector" || sel.Tag != proxyTag {
				t.Fatalf("selector = %q/%q", sel.Type, sel.Tag)
			}
			if len(sel.Outbounds) != 3 || sel.Outbounds[0] != nodeTag(0) {
				t.Errorf("selector members = %v", sel.Outbounds)
			}
			if sel.Default != nodeTag(0) {
				t.Errorf("selector default = %q, want %q", sel.Default, nodeTag(0))
			}
			// Without this, connections opened through the old node hang on a
			// server we just stopped using.
			if !sel.Interrupt {
				t.Error("selector must interrupt existing connections on switch")
			}
			if c.Route.Final != proxyTag {
				t.Errorf("route.final = %q", c.Route.Final)
			}
			// A node's own hostname must resolve locally, never through the
			// tunnel we have not built yet — so every candidate, not just
			// "proxy", pins the local resolver.
			for i := 0; i < 3; i++ {
				if c.Outbounds[i].Resolver != "dns-local" {
					t.Errorf("outbound %d domain_resolver = %q", i, c.Outbounds[i].Resolver)
				}
			}
		})
	}
}

func TestSelectorConfigStillPassesTheSafetyGate(t *testing.T) {
	// buildTunConfig already runs assertConfigSafe, so reaching here without an
	// error is half the assertion; re-run it explicitly for the other half.
	raw, err := buildTunConfig(cleanSet(t, "1.1.1.1", "2.2.2.2"), "info", true)
	if err != nil {
		t.Fatalf("buildTunConfig: %v", err)
	}
	if err := assertConfigSafe(raw, "vpn"); err != nil {
		t.Fatalf("selector vpn config rejected: %v", err)
	}
	if err := assertConfigSafe(raw, "proxy"); err == nil {
		t.Error("a tun config must not pass the proxy gate")
	}
}

func TestAssertOutboundsRejectsSmuggledGroups(t *testing.T) {
	head := `{"inbounds":[{"type":"tun","auto_route":true}],"outbounds":`
	bad := []string{
		// a "direct" smuggled in as a candidate — would bypass the tunnel
		head + `[{"type":"direct","tag":"node-0"},{"type":"trojan","tag":"node-1"},{"type":"selector","tag":"proxy"},{"type":"direct","tag":"direct"}]}`,
		// an extra outbound nobody asked for
		head + `[{"type":"trojan","tag":"node-0"},{"type":"selector","tag":"proxy"},{"type":"direct","tag":"direct"},{"type":"trojan","tag":"leak"}]}`,
		// duplicate tags
		head + `[{"type":"trojan","tag":"node-0"},{"type":"trojan","tag":"node-0"},{"type":"selector","tag":"proxy"},{"type":"direct","tag":"direct"}]}`,
		// the "direct" tag must really be a direct outbound
		head + `[{"type":"trojan","tag":"proxy"},{"type":"trojan","tag":"direct"}]}`,
		// a selector group with no candidates behind it
		head + `[{"type":"selector","tag":"proxy"},{"type":"direct","tag":"direct"}]}`,
		// candidates out of order (node-1 before node-0)
		head + `[{"type":"trojan","tag":"node-1"},{"type":"trojan","tag":"node-0"},{"type":"selector","tag":"proxy"},{"type":"direct","tag":"direct"}]}`,
	}
	for i, b := range bad {
		if err := assertConfigSafe([]byte(b), "vpn"); err == nil {
			t.Errorf("hostile outbound set #%d passed the gate", i)
		}
	}
}

func TestTunConfigStrictRouteAndInterfaceName(t *testing.T) {
	for _, strict := range []bool{false, true} {
		raw, err := buildTunConfig(cleanSet(t, "1.2.3.4"), "info", strict)
		if err != nil {
			t.Fatalf("buildTunConfig(strict=%v): %v", strict, err)
		}
		c := parseCfg(t, raw)
		if got := c.Inbounds[0].StrictRoute; got != strict {
			t.Errorf("strict_route = %v, want %v", got, strict)
		}
		// The byte counters find the adapter by this name — if it ever drifts,
		// vpn-mode traffic silently reads as zero.
		if c.Inbounds[0].InterfaceName != tunInterfaceName {
			t.Errorf("interface_name = %q, want %q", c.Inbounds[0].InterfaceName, tunInterfaceName)
		}
	}
}

func TestStartConfigNodesPrefersTheCandidateList(t *testing.T) {
	single := StartConfig{Outbound: map[string]any{"type": "trojan"}}
	if got := single.nodes(); len(got) != 1 {
		t.Errorf("single: got %d nodes", len(got))
	}
	both := StartConfig{
		Outbound:  map[string]any{"type": "trojan", "server": "legacy"},
		Outbounds: []map[string]any{{"server": "a"}, {"server": "b"}},
	}
	got := both.nodes()
	if len(got) != 2 || got[0]["server"] != "a" {
		t.Errorf("candidate list should win, got %v", got)
	}
	if n := (StartConfig{}).nodes(); n != nil {
		t.Errorf("empty config should yield no nodes, got %v", n)
	}
}

// selectCandidate is the hot-swap entry point; without a running engine it must
// refuse rather than panic, so the Dart side can fall back to stop/start.
func TestSelectCandidateRefusesWhenStopped(t *testing.T) {
	stopEngine()
	if err := selectCandidate(0); err == nil {
		t.Error("hot-swap on a stopped engine should fail")
	}
}
