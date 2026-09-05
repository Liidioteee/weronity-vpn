package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"strings"
)

// ============================================================================
//  Hardened sing-box config generation.
//
//  A node's `outbound` object comes from the *public, scraped* pool — it must be
//  treated as hostile input. We never splat it into a config. Instead we:
//    1. require `type` to be a known proxy protocol (allowlist),
//    2. rebuild the outbound field-by-field from a per-type allowlist,
//    3. drop every key that could read a file, bind a socket, chain a detour,
//       or otherwise reach outside "be a proxy client",
//    4. wrap it in a config whose inbound is *always* loopback-only and which
//       enables no network-facing control API,
//    5. let sing-box's own loader (`box.New`) do the final validation.
// ============================================================================

// Proxy protocols we will build an outbound for. Everything else — direct,
// block, dns, selector, urltest, tor, ssh, socks, http, wireguard — is rejected.
var allowedOutboundTypes = map[string]struct{}{
	"vless":       {},
	"vmess":       {},
	"trojan":      {},
	"shadowsocks": {},
	"hysteria2":   {},
	"tuic":        {},
	"shadowtls":   {},
	"anytls":      {},
}

// Keys that must never survive sanitisation, wherever they appear. `*_path` and
// `*_command` are additionally stripped by suffix/needle checks below.
var globalKeyDenylist = map[string]struct{}{
	"detour":               {},
	"bind_interface":       {},
	"bind_address":         {},
	"inet4_bind_address":   {},
	"inet6_bind_address":   {},
	"routing_mark":         {},
	"netns":                {},
	"network_strategy":     {},
	"network_namespace":    {},
	"plugin":               {}, // shadowsocks SIP003 plugins — skip for scraped nodes
	"plugin_opts":          {},
	"tls_fragment":         {},
	"process_name":         {},
	"outbound":             {},
	"inbounds":             {},
	"outbounds":            {},
	"route":                {},
	"experimental":         {},
	"log":                  {},
	"dns":                  {},
	"services":             {},
	"endpoints":            {},
	"certificate_provider": {},
}

// Per-type field allowlists (scalars + arrays copied verbatim; objects recurse
// with their own sub-allowlist). `type` and `tag` are handled separately.
var commonOutboundFields = []string{
	"server", "server_port", "server_ports", "hop_interval", "network",
	"tcp_fast_open", "udp_fragment", "connect_timeout",
}

var outboundFieldWhitelist = map[string][]string{
	"vless":  {"uuid", "flow", "packet_encoding"},
	"vmess":  {"uuid", "security", "alter_id", "global_padding", "authenticated_length", "packet_encoding"},
	"trojan": {"password"},
	"shadowsocks": {
		"method", "password", "udp_over_tcp",
	},
	"hysteria2": {"password", "up_mbps", "down_mbps", "obfs", "brutal_debug"},
	"tuic": {
		"uuid", "password", "congestion_control", "udp_relay_mode",
		"udp_over_stream", "zero_rtt_handshake", "heartbeat",
	},
	"shadowtls": {"version", "password"},
	"anytls": {
		"password", "idle_session_check_interval", "idle_session_timeout",
		"min_idle_session",
	},
}

// Object-valued fields and the allowlist for their contents.
var tlsFields = []string{
	"enabled", "disable_sni", "server_name", "insecure", "alpn",
	"min_version", "max_version", "cipher_suites",
}
var utlsFields = []string{"enabled", "fingerprint"}
var realityFields = []string{"enabled", "public_key", "short_id"}
var echFields = []string{"enabled", "config"}
var transportFields = []string{
	"type", "path", "host", "headers", "method", "service_name",
	"idle_timeout", "ping_timeout", "permit_without_stream",
	"max_early_data", "early_data_header_name",
}
var multiplexFields = []string{
	"enabled", "protocol", "max_connections", "min_streams", "max_streams",
	"padding",
}
var obfsFields = []string{"type", "password"}
var brutalFields = []string{"enabled", "up_mbps", "down_mbps"}

// SanitizeResult is the outcome of cleaning one node outbound.
type SanitizeResult struct {
	Outbound map[string]any
	Warnings []string
}

func denied(key string) bool {
	if _, bad := globalKeyDenylist[key]; bad {
		return true
	}
	lk := strings.ToLower(key)
	return strings.HasSuffix(lk, "_path") ||
		strings.HasSuffix(lk, "_command") ||
		strings.Contains(lk, "exec")
}

// pick copies allowed scalar/array keys from src; object keys recurse only if
// listed in objAllow with their own field list.
func pick(src map[string]any, fields []string, objAllow map[string][]string) map[string]any {
	allow := make(map[string]struct{}, len(fields))
	for _, f := range fields {
		allow[f] = struct{}{}
	}
	out := make(map[string]any)
	for k, v := range src {
		if denied(k) {
			continue
		}
		if _, ok := allow[k]; !ok {
			continue
		}
		switch child := v.(type) {
		case map[string]any:
			if sub, ok := objAllow[k]; ok {
				out[k] = pick(child, sub, objAllow)
			}
		default:
			out[k] = v
		}
	}
	return out
}

// sanitizeOutbound rebuilds a single proxy outbound from an allowlist and forces
// tag="proxy". It never returns the input map.
func sanitizeOutbound(raw map[string]any) (*SanitizeResult, error) {
	if raw == nil {
		return nil, errors.New("empty outbound")
	}
	typeVal, _ := raw["type"].(string)
	typeVal = strings.ToLower(strings.TrimSpace(typeVal))
	if typeVal == "" {
		return nil, errors.New("outbound has no type")
	}
	if _, ok := allowedOutboundTypes[typeVal]; !ok {
		return nil, fmt.Errorf("outbound type %q is not an allowed proxy protocol", typeVal)
	}

	fields := append([]string{}, commonOutboundFields...)
	fields = append(fields, outboundFieldWhitelist[typeVal]...)
	fields = append(fields, "tls", "transport", "multiplex")

	objAllow := map[string][]string{
		"tls":       append(append([]string{}, tlsFields...), "utls", "reality", "ech"),
		"utls":      utlsFields,
		"reality":   realityFields,
		"ech":       echFields,
		"transport": transportFields,
		"multiplex": append(append([]string{}, multiplexFields...), "brutal"),
		"brutal":    brutalFields,
		"obfs":      obfsFields,
	}
	if typeVal == "hysteria2" {
		fields = append(fields, "obfs")
	}

	clean := pick(raw, fields, objAllow)
	clean["type"] = typeVal
	clean["tag"] = "proxy"
	// Resolve the proxy endpoint's own hostname via the local resolver, never
	// through the (not-yet-connected) proxy itself.
	clean["domain_resolver"] = "dns-local"

	var warns []string
	if server, _ := clean["server"].(string); server == "" {
		return nil, errors.New("outbound has no server")
	}
	if _, port := clean["server_port"]; !port {
		if _, ports := clean["server_ports"]; !ports {
			return nil, errors.New("outbound has no server_port")
		}
	}
	if tlsObj, ok := clean["tls"].(map[string]any); ok {
		if ins, _ := tlsObj["insecure"].(bool); ins {
			warns = append(warns, "node requests tls.insecure=true (certificate check disabled for this hop)")
		}
	}
	// Clamp connect_timeout to something sane.
	clean["connect_timeout"] = "10s"

	return &SanitizeResult{Outbound: clean, Warnings: warns}, nil
}

// StartConfig is the JSON contract passed from Dart to wrnStart in Phase 3.1.
type StartConfig struct {
	Outbound    map[string]any `json:"outbound"`
	SocksPort   int            `json:"socks_port"`
	LogLevel    string         `json:"log_level"`
	SelfTest    *bool          `json:"self_test"`
	SelfTestURL string         `json:"self_test_url"`
}

func (c StartConfig) selfTestEnabled() bool { return c.SelfTest == nil || *c.SelfTest }

func (c StartConfig) selfTestURL() string {
	if c.SelfTestURL != "" {
		return c.SelfTestURL
	}
	return "https://www.gstatic.com/generate_204"
}

func (c StartConfig) logLevel() string {
	switch strings.ToLower(c.LogLevel) {
	case "trace", "debug", "info", "warn", "warning", "error", "fatal":
		return strings.ToLower(c.LogLevel)
	default:
		return "info"
	}
}

// buildSingBoxConfig assembles the full config. Everything except the single
// sanitised proxy outbound is fixed here.
func buildSingBoxConfig(clean map[string]any, socksPort int, logLevel string) ([]byte, error) {
	if socksPort <= 0 || socksPort > 65535 {
		return nil, fmt.Errorf("bad socks port %d", socksPort)
	}
	cfg := map[string]any{
		"log": map[string]any{"level": logLevel, "timestamp": true},
		"dns": map[string]any{
			"servers": []any{
				map[string]any{
					"type": "https", "tag": "dns-proxy",
					"server": "1.1.1.1", "detour": "proxy",
				},
				map[string]any{"type": "local", "tag": "dns-local"},
			},
			"rules": []any{
				// The proxy endpoint's own hostname resolves locally.
				map[string]any{
					"outbound": []any{"proxy"},
					"server":   "dns-local",
				},
			},
			"final":            "dns-proxy",
			"strategy":         "prefer_ipv4",
			"independent_cache": true,
		},
		"inbounds": []any{
			map[string]any{
				"type": "mixed", "tag": "socks-in",
				"listen": "127.0.0.1", "listen_port": socksPort,
			},
		},
		"outbounds": []any{
			clean,
			map[string]any{"type": "direct", "tag": "direct"},
		},
		"route": map[string]any{
			"rules":                   []any{},
			"final":                   "proxy",
			"auto_detect_interface":   false,
			"default_domain_resolver": "dns-local",
		},
	}

	raw, err := json.Marshal(cfg)
	if err != nil {
		return nil, err
	}
	if err := assertConfigSafe(raw); err != nil {
		return nil, err
	}
	return raw, nil
}

// assertConfigSafe re-parses the generated config and fails closed if any
// invariant we rely on is missing — belt-and-braces against future edits.
func assertConfigSafe(raw []byte) error {
	var cfg struct {
		Experimental json.RawMessage `json:"experimental"`
		Inbounds     []struct {
			Type       string `json:"type"`
			Listen     string `json:"listen"`
			ListenPort int    `json:"listen_port"`
		} `json:"inbounds"`
		Outbounds []struct {
			Type string `json:"type"`
			Tag  string `json:"tag"`
		} `json:"outbounds"`
	}
	if err := json.Unmarshal(raw, &cfg); err != nil {
		return err
	}
	if len(cfg.Experimental) > 0 && string(cfg.Experimental) != "null" {
		return errors.New("generated config unexpectedly contains an experimental block")
	}
	if len(cfg.Inbounds) != 1 {
		return fmt.Errorf("expected exactly 1 inbound, got %d", len(cfg.Inbounds))
	}
	in := cfg.Inbounds[0]
	if ip := net.ParseIP(in.Listen); ip == nil || !ip.IsLoopback() {
		return fmt.Errorf("inbound listen %q is not a loopback address", in.Listen)
	}
	tags := make(map[string]struct{})
	for _, o := range cfg.Outbounds {
		tags[o.Tag] = struct{}{}
	}
	for _, want := range []string{"proxy", "direct"} {
		if _, ok := tags[want]; !ok {
			return fmt.Errorf("generated config missing the %q outbound", want)
		}
	}
	if len(cfg.Outbounds) != 2 {
		return fmt.Errorf("expected exactly 2 outbounds, got %d", len(cfg.Outbounds))
	}
	return nil
}

// freeLoopbackPort asks the OS for an unused TCP port on 127.0.0.1.
func freeLoopbackPort() (int, error) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port, nil
}
