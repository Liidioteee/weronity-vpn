package main

import (
	"encoding/json"
	"strings"
	"testing"
)

func mustJSON(t *testing.T, s string) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal([]byte(s), &m); err != nil {
		t.Fatalf("bad fixture json: %v", err)
	}
	return m
}

func TestSanitizeRejectsNonProxyTypes(t *testing.T) {
	for _, ty := range []string{"direct", "block", "dns", "selector", "urltest", "socks", "http", "tor", "ssh", "wireguard", ""} {
		_, err := sanitizeOutbound(map[string]any{"type": ty, "server": "x", "server_port": 1})
		if err == nil {
			t.Errorf("type %q should be rejected", ty)
		}
	}
}

func TestSanitizeForcesTagAndDropsDangerousKeys(t *testing.T) {
	raw := mustJSON(t, `{
		"type": "vless",
		"tag": "attacker-tag",
		"server": "example.com",
		"server_port": 443,
		"uuid": "11111111-2222-3333-4444-555555555555",
		"flow": "xtls-rprx-vision",
		"detour": "some-inbound",
		"bind_interface": "eth0",
		"routing_mark": 1234,
		"tls_fragment": {"enabled": true},
		"certificate_path": "/etc/passwd",
		"plugin": "obfs-local",
		"plugin_opts": "obfs=http",
		"inbounds": [{"type":"socks","listen":"0.0.0.0"}],
		"experimental": {"clash_api": {"external_controller": "0.0.0.0:9090"}},
		"tls": {
			"enabled": true,
			"server_name": "example.com",
			"insecure": true,
			"certificate_path": "/root/.ssh/id_rsa",
			"utls": {"enabled": true, "fingerprint": "chrome"},
			"reality": {"enabled": true, "public_key": "abc", "short_id": "00"}
		},
		"transport": {"type":"ws","path":"/x","headers":{"Host":"a.com"},"early_data_command":"rm -rf /"}
	}`)

	res, err := sanitizeOutbound(raw)
	if err != nil {
		t.Fatalf("sanitize: %v", err)
	}
	ob := res.Outbound

	if ob["tag"] != "proxy" {
		t.Errorf("tag not forced to proxy: %v", ob["tag"])
	}
	if ob["domain_resolver"] != "dns-local" {
		t.Errorf("domain_resolver not pinned: %v", ob["domain_resolver"])
	}
	for _, bad := range []string{"detour", "bind_interface", "routing_mark", "tls_fragment", "certificate_path", "plugin", "plugin_opts", "inbounds", "experimental"} {
		if _, present := ob[bad]; present {
			t.Errorf("dangerous key %q survived sanitisation", bad)
		}
	}
	if ob["connect_timeout"] != "10s" {
		t.Errorf("connect_timeout not clamped: %v", ob["connect_timeout"])
	}
	// kept fields
	if ob["uuid"] == nil || ob["flow"] == nil || ob["server"] == nil {
		t.Errorf("expected connection fields to be kept: %v", ob)
	}
	tls, _ := ob["tls"].(map[string]any)
	if tls == nil {
		t.Fatal("tls object dropped entirely")
	}
	if _, present := tls["certificate_path"]; present {
		t.Error("tls.certificate_path survived")
	}
	if tls["insecure"] != true {
		t.Error("tls.insecure should be preserved (and warned)")
	}
	if len(res.Warnings) == 0 {
		t.Error("expected a warning about tls.insecure")
	}
	utls, _ := tls["utls"].(map[string]any)
	if utls == nil || utls["fingerprint"] != "chrome" {
		t.Errorf("utls sub-object mangled: %v", tls["utls"])
	}
	tr, _ := ob["transport"].(map[string]any)
	if tr == nil || tr["path"] != "/x" {
		t.Errorf("transport mangled: %v", ob["transport"])
	}
	if _, present := tr["early_data_command"]; present {
		t.Error("transport.early_data_command (contains 'command') survived")
	}
	hdr, _ := tr["headers"].(map[string]any)
	if hdr == nil || hdr["Host"] != "a.com" {
		t.Errorf("transport.headers.Host must be preserved for ws routing, got: %v", tr["headers"])
	}
}

// Regression: a domain-fronted trojan-over-ws node with NO TLS whose only
// routing signal is the ws `Host` header (the shape that shipped broken —
// sanitizeOutbound used to drop transport.headers entirely).
func TestSanitizePreservesTransportHeaders(t *testing.T) {
	raw := mustJSON(t, `{
		"type": "trojan",
		"server": "66.23.207.69",
		"server_port": 443,
		"password": "p4ss",
		"transport": {
			"type": "ws",
			"path": "/",
			"headers": {
				"Host": "telegram.org",
				"X-Evil\r\nInjected": "1",
				"drop_command": "x",
				"Too-Long": "` + strings.Repeat("A", 600) + `"
			}
		}
	}`)

	res, err := sanitizeOutbound(raw)
	if err != nil {
		t.Fatalf("sanitize: %v", err)
	}
	tr, _ := res.Outbound["transport"].(map[string]any)
	if tr == nil {
		t.Fatal("transport dropped")
	}
	hdr, _ := tr["headers"].(map[string]any)
	if hdr == nil {
		t.Fatal("transport.headers dropped — the fronting Host header is gone")
	}
	if hdr["Host"] != "telegram.org" {
		t.Errorf("Host header not preserved: %v", hdr)
	}
	if _, bad := hdr["X-Evil\r\nInjected"]; bad {
		t.Error("header name with CR/LF survived")
	}
	if _, bad := hdr["drop_command"]; bad {
		t.Error("header name matching the denied-key rule survived")
	}
	if _, bad := hdr["Too-Long"]; bad {
		t.Error("over-long header value survived")
	}
}

func TestSanitizeHeadersCap(t *testing.T) {
	in := map[string]any{}
	for i := 0; i < maxHeaders+20; i++ {
		in[strings.Repeat("h", 1)+string(rune('A'+i%26))+string(rune('0'+i/26))] = "v"
	}
	out := sanitizeHeaders(in)
	if len(out) > maxHeaders {
		t.Errorf("sanitizeHeaders kept %d, cap is %d", len(out), maxHeaders)
	}
}

func TestSanitizeRequiresServerAndPort(t *testing.T) {
	if _, err := sanitizeOutbound(map[string]any{"type": "trojan", "password": "x"}); err == nil {
		t.Error("missing server must be rejected")
	}
	if _, err := sanitizeOutbound(map[string]any{"type": "trojan", "server": "h", "password": "x"}); err == nil {
		t.Error("missing server_port must be rejected")
	}
	if _, err := sanitizeOutbound(map[string]any{"type": "trojan", "server": "h", "server_port": 443.0, "password": "x"}); err != nil {
		t.Errorf("valid trojan rejected: %v", err)
	}
}

func TestBuildConfigIsLoopbackOnlyAndApiFree(t *testing.T) {
	san, err := sanitizeOutbound(mustJSON(t, `{"type":"trojan","server":"1.2.3.4","server_port":443,"password":"p"}`))
	if err != nil {
		t.Fatal(err)
	}
	raw, err := buildSingBoxConfig(san.Outbound, 10808, "info")
	if err != nil {
		t.Fatalf("buildSingBoxConfig: %v", err)
	}

	var cfg map[string]any
	if err := json.Unmarshal(raw, &cfg); err != nil {
		t.Fatal(err)
	}
	if _, present := cfg["experimental"]; present {
		t.Error("config must not contain an experimental block")
	}
	ins := cfg["inbounds"].([]any)
	if len(ins) != 1 {
		t.Fatalf("want 1 inbound, got %d", len(ins))
	}
	in := ins[0].(map[string]any)
	if in["listen"] != "127.0.0.1" {
		t.Errorf("inbound not loopback: %v", in["listen"])
	}
	obs := cfg["outbounds"].([]any)
	if len(obs) != 2 {
		t.Fatalf("want 2 outbounds, got %d", len(obs))
	}
	if !strings.Contains(string(raw), `"final":"proxy"`) {
		t.Error("route.final should be proxy")
	}
}

func TestAssertConfigSafeCatchesTampering(t *testing.T) {
	good := `{"inbounds":[{"type":"mixed","listen":"127.0.0.1","listen_port":1}],"outbounds":[{"type":"trojan","tag":"proxy"},{"type":"direct","tag":"direct"}]}`
	if err := assertConfigSafe([]byte(good)); err != nil {
		t.Fatalf("good config flagged: %v", err)
	}
	bad := []string{
		`{"inbounds":[{"type":"mixed","listen":"0.0.0.0","listen_port":1}],"outbounds":[{"tag":"proxy"},{"tag":"direct"}]}`,
		`{"experimental":{"clash_api":{}},"inbounds":[{"listen":"127.0.0.1"}],"outbounds":[{"tag":"proxy"},{"tag":"direct"}]}`,
		`{"inbounds":[{"listen":"127.0.0.1"},{"listen":"127.0.0.1"}],"outbounds":[{"tag":"proxy"},{"tag":"direct"}]}`,
		`{"inbounds":[{"listen":"127.0.0.1"}],"outbounds":[{"tag":"proxy"}]}`,
	}
	for i, b := range bad {
		if err := assertConfigSafe([]byte(b)); err == nil {
			t.Errorf("tampered config #%d passed assertConfigSafe", i)
		}
	}
}

func TestStartConfigDefaults(t *testing.T) {
	var sc StartConfig
	if !sc.selfTestEnabled() {
		t.Error("self-test should default on")
	}
	if sc.logLevel() != "info" {
		t.Errorf("default log level: %s", sc.logLevel())
	}
	if !strings.HasPrefix(sc.selfTestURL(), "http") {
		t.Errorf("default self-test url: %s", sc.selfTestURL())
	}
	if sc.mode() != "proxy" {
		t.Errorf("default mode: %s", sc.mode())
	}
	if sc.listenPort() != 55555 {
		t.Errorf("default proxy port: %d", sc.listenPort())
	}
	no := false
	sc.SelfTest = &no
	if sc.selfTestEnabled() {
		t.Error("self-test explicitly disabled")
	}
}

func TestStartConfigModeParsing(t *testing.T) {
	cases := map[string]string{"": "proxy", "proxy": "proxy", "PROXY": "proxy",
		"vpn": "vpn", " VPN ": "vpn", "tun": "proxy" /* unknown -> proxy */}
	for in, want := range cases {
		if got := (StartConfig{Mode: in}).mode(); got != want {
			t.Errorf("mode(%q) = %q, want %q", in, got, want)
		}
	}
	if (StartConfig{ListenPort: 8080}).listenPort() != 8080 {
		t.Error("explicit listen_port ignored")
	}
	if (StartConfig{ListenPort: 70000}).listenPort() != 55555 {
		t.Error("out-of-range listen_port should fall back to default")
	}
}
