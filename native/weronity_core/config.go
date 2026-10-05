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

// Caps applied to an untrusted v2ray-transport `headers` map.
const (
	maxHeaders      = 24
	maxHeaderKeyLen = 128
	maxHeaderValLen = 512
)

// hasCtrl reports whether s contains an ASCII control char (incl. CR/LF) — used
// to refuse header names/values that could smuggle a second header or request.
func hasCtrl(s string) bool {
	for _, r := range s {
		if r < 0x20 || r == 0x7f {
			return true
		}
	}
	return false
}

// sanitizeHeaders copies a transport `headers` map keeping only well-formed
// string / []string values. The map is attacker-controlled (it comes from a
// scraped node) but its whole purpose is the WebSocket/HTTP `Host` (and similar)
// header the node needs for routing — dropping it silently breaks every
// domain-fronted ws/httpupgrade node. We keep it, bounded and control-char-free.
func sanitizeHeaders(src map[string]any) map[string]any {
	out := make(map[string]any)
	for k, v := range src {
		if len(out) >= maxHeaders {
			break
		}
		if k == "" || len(k) > maxHeaderKeyLen || hasCtrl(k) || denied(strings.ToLower(k)) {
			continue
		}
		switch val := v.(type) {
		case string:
			if len(val) <= maxHeaderValLen && !hasCtrl(val) {
				out[k] = val
			}
		case []any:
			list := make([]any, 0, len(val))
			for _, item := range val {
				if s, ok := item.(string); ok && len(s) <= maxHeaderValLen && !hasCtrl(s) {
					list = append(list, s)
				}
			}
			if len(list) > 0 {
				out[k] = list
			}
		}
	}
	return out
}

// pick copies allowed scalar/array keys from src; object keys recurse only if
// listed in objAllow with their own field list. The `headers` object is a
// special case: its keys are not known ahead of time, so it goes through
// sanitizeHeaders instead of a field allowlist.
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
			if k == "headers" {
				if h := sanitizeHeaders(child); len(h) > 0 {
					out[k] = h
				}
				continue
			}
			if sub, ok := objAllow[k]; ok {
				out[k] = pick(child, sub, objAllow)
			}
		default:
			out[k] = v
		}
	}
	return out
}

// sanitizeOutbound rebuilds a single proxy outbound from an allowlist and gives
// it the caller-chosen `tag` (never one the node asked for). It never returns
// the input map.
func sanitizeOutbound(raw map[string]any, tag string) (*SanitizeResult, error) {
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
	clean["tag"] = tag
	// Resolve the proxy endpoint's own hostname via the local resolver, never
	// through the (not-yet-connected) proxy itself.
	clean["domain_resolver"] = "dns-local"

	var warns []string
	server, _ := clean["server"].(string)
	if server == "" {
		return nil, errors.New("outbound has no server")
	}
	if err := checkServerAddr(server); err != nil {
		return nil, err
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

// checkServerAddr refuses endpoints that can only be a mistake or an attempt to
// point the client at itself: loopback, unspecified, link-local and multicast
// addresses. Private LAN ranges stay allowed — a user's own key may well live
// on their network — and hostnames are resolved later by sing-box.
func checkServerAddr(server string) error {
	host := strings.TrimSuffix(strings.ToLower(strings.TrimSpace(server)), ".")
	if host == "localhost" || strings.HasSuffix(host, ".localhost") {
		return fmt.Errorf("outbound server %q is a loopback name", server)
	}
	ip := net.ParseIP(strings.Trim(host, "[]"))
	if ip == nil {
		return nil
	}
	if ip.IsLoopback() || ip.IsUnspecified() || ip.IsMulticast() ||
		ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() {
		return fmt.Errorf("outbound server %q is not a routable address", server)
	}
	return nil
}

// StartConfig is the JSON contract passed from Dart to wrnStart.
type StartConfig struct {
	// Outbound is the single node to connect through. Legacy/simple form; when
	// Outbounds is non-empty it is ignored.
	Outbound map[string]any `json:"outbound"`

	// Outbounds is the *candidate set*: the node to use first, followed by
	// backups. They all become `node-<i>` outbounds under a `selector` group
	// tagged "proxy", so wrnSelectOutbound can hot-swap between them without
	// tearing the tunnel (and, in vpn mode, the whole network) down.
	Outbounds []map[string]any `json:"outbounds"`

	// StrictRoute enables sing-box's anti-leak strict routing on the tun
	// inbound (vpn mode only). Off by default — it is the setting most likely
	// to leave a machine with "no internet" if something else on the box
	// already owns the routing table.
	StrictRoute bool `json:"strict_route"`

	// Mode: "proxy" (default) exposes a local SOCKS/HTTP proxy on
	// 127.0.0.1:<listen_port>; "vpn" captures all traffic via a TUN device.
	Mode string `json:"mode"`

	// ListenPort is the public proxy port in proxy mode, always bound to
	// 127.0.0.1. Absent (or out of range) = the default 55555; an explicit 0 =
	// let the OS pick a free one.
	ListenPort *int `json:"listen_port"`

	// SocksPort is the *internal* sing-box inbound port (loopback, ephemeral by
	// default). Rarely set from Dart — mostly for tests.
	SocksPort int `json:"socks_port"`

	LogLevel    string `json:"log_level"`
	SelfTest    *bool  `json:"self_test"`
	SelfTestURL string `json:"self_test_url"`
}

const defaultProxyPort = 55555

func (c StartConfig) mode() string {
	if strings.ToLower(strings.TrimSpace(c.Mode)) == "vpn" {
		return "vpn"
	}
	return "proxy"
}

// listenPort returns the public proxy port to bind; 0 means "any free port".
func (c StartConfig) listenPort() int {
	if c.ListenPort != nil && *c.ListenPort >= 0 && *c.ListenPort <= 65535 {
		return *c.ListenPort
	}
	return defaultProxyPort
}

// nodes returns the candidate outbounds in priority order.
func (c StartConfig) nodes() []map[string]any {
	if len(c.Outbounds) > 0 {
		return c.Outbounds
	}
	if c.Outbound != nil {
		return []map[string]any{c.Outbound}
	}
	return nil
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

// dnsBlock is shared by both modes: DoH through the tunnel, plus a local
// resolver used only for the proxy endpoints' own hostnames. Each node outbound
// pins `domain_resolver: dns-local` (see sanitizeOutbound) and the route sets
// `default_domain_resolver`, so a node's own DNS never loops back through the
// tunnel — no `outbound` DNS rule needed (sing-box deprecated that item).
func dnsBlock() map[string]any {
	return map[string]any{
		"servers": []any{
			map[string]any{
				"type": "https", "tag": "dns-proxy",
				"server": "1.1.1.1", "detour": "proxy",
			},
			map[string]any{"type": "local", "tag": "dns-local"},
		},
		"final":    "dns-proxy",
		"strategy": "prefer_ipv4",
	}
}

// nodeTag is the outbound tag of the i-th candidate node inside a selector group.
func nodeTag(i int) string { return fmt.Sprintf("node-%d", i) }

// proxyTag is the tag the route/final and the DNS detour always point at. It is
// either the single node itself or the selector group over all candidates.
const proxyTag = "proxy"

// buildOutbounds turns the sanitised candidate list into the config's
// `outbounds` array.
//
//	1 candidate  -> [node(tag=proxy), direct]                  (as before 3.3b)
//	N candidates -> [node-0 … node-N-1, selector(tag=proxy), direct]
//
// The caller must already have sanitised each candidate with the matching tag.
func buildOutbounds(cleans []map[string]any) (outbounds []any, err error) {
	if len(cleans) == 0 {
		return nil, errors.New("no node outbound")
	}
	if len(cleans) == 1 {
		return []any{
			cleans[0],
			map[string]any{"type": "direct", "tag": "direct"},
		}, nil
	}
	tags := make([]any, 0, len(cleans))
	outbounds = make([]any, 0, len(cleans)+2)
	for i, c := range cleans {
		outbounds = append(outbounds, c)
		tags = append(tags, nodeTag(i))
	}
	outbounds = append(outbounds, map[string]any{
		"type":                        "selector",
		"tag":                         proxyTag,
		"outbounds":                   tags,
		"default":                     nodeTag(0),
		"interrupt_exist_connections": true,
	})
	outbounds = append(outbounds, map[string]any{"type": "direct", "tag": "direct"})
	return outbounds, nil
}

// buildSingBoxConfig assembles the proxy-mode config: one loopback mixed inbound,
// no control API. Everything except the sanitised proxy outbounds is fixed.
func buildSingBoxConfig(cleans []map[string]any, socksPort int, logLevel string) ([]byte, error) {
	return buildBoundProxyConfig(cleans, socksPort, logLevel, routeBinding{})
}

// routeBinding says which network interface a proxy-mode engine's own sockets
// must leave through. The zero value = follow the OS routing table.
//
// It matters for the throwaway probe engine (preflight.go) while the main engine
// holds a tun with auto_route: without a binding the probe's connections follow
// the default route — straight into the tunnel, i.e. through the very node the
// probe is supposed to be an alternative to.
type routeBinding struct {
	// iface is an explicit interface name (`route.default_interface`).
	iface string
	// autoDetect asks sing-box to find the physical default interface itself;
	// used when the name is not known.
	autoDetect bool
}

func buildBoundProxyConfig(cleans []map[string]any, socksPort int, logLevel string, bind routeBinding) ([]byte, error) {
	if socksPort <= 0 || socksPort > 65535 {
		return nil, fmt.Errorf("bad socks port %d", socksPort)
	}
	outs, err := buildOutbounds(cleans)
	if err != nil {
		return nil, err
	}
	route := map[string]any{
		"rules":                   []any{},
		"final":                   proxyTag,
		"auto_detect_interface":   bind.iface == "" && bind.autoDetect,
		"default_domain_resolver": "dns-local",
	}
	if bind.iface != "" {
		route["default_interface"] = bind.iface
	}
	cfg := map[string]any{
		"log": map[string]any{"level": logLevel, "timestamp": true},
		"dns": dnsBlock(),
		"inbounds": []any{
			map[string]any{
				"type": "mixed", "tag": "socks-in",
				"listen": "127.0.0.1", "listen_port": socksPort,
			},
		},
		"outbounds": outs,
		"route":     route,
	}

	raw, err := json.Marshal(cfg)
	if err != nil {
		return nil, err
	}
	if err := assertConfigSafe(raw, "proxy"); err != nil {
		return nil, err
	}
	return raw, nil
}

// TUN device addressing — link-local /30 + /126, never routed anywhere real.
const (
	tunAddr4 = "172.19.0.1/30"
	tunAddr6 = "fdfe:dcba:9876::1/126"
	tunMTU   = 1500

	// tunInterfaceName is fixed so the OS-level byte counters (ifstat_*.go) can
	// find the adapter without guessing.
	tunInterfaceName = "weronity0"
)

// buildTunConfig assembles the VPN-mode config: a single `tun` inbound with
// `auto_route` so the whole system's traffic is captured, the gvisor userspace
// stack (build tag `with_gvisor`), DNS hijacked into the tunnel. Still exactly
// two outbounds {proxy, direct}, no control API, no experimental block.
//
// Loop protection (the proxy outbound's own connection to the node server must
// go out the physical interface, not back into the tun) is handled by sing-box:
// `auto_route` marks the engine's own sockets and `auto_detect_interface`
// binds them to the default interface.
func buildTunConfig(cleans []map[string]any, logLevel string, strictRoute bool) ([]byte, error) {
	outs, err := buildOutbounds(cleans)
	if err != nil {
		return nil, err
	}
	cfg := map[string]any{
		"log": map[string]any{"level": logLevel, "timestamp": true},
		"dns": dnsBlock(),
		"inbounds": []any{
			map[string]any{
				"type":           "tun",
				"tag":            "tun-in",
				"interface_name": tunInterfaceName,
				"address":        []any{tunAddr4, tunAddr6},
				"mtu":            tunMTU,
				"auto_route":     true,
				// strict_route closes the leak paths auto_route leaves open, but
				// it can also strand a machine whose routing is already owned by
				// something else — so it is opt-in from Settings.
				"strict_route": strictRoute,
				"stack":        "gvisor",
			},
		},
		"outbounds": outs,
		"route": map[string]any{
			"rules": []any{
				map[string]any{"action": "sniff"},
				map[string]any{"protocol": "dns", "action": "hijack-dns"},
			},
			"final":                   proxyTag,
			"auto_detect_interface":   true,
			"default_domain_resolver": "dns-local",
		},
	}

	raw, err := json.Marshal(cfg)
	if err != nil {
		return nil, err
	}
	if err := assertConfigSafe(raw, "vpn"); err != nil {
		return nil, err
	}
	return raw, nil
}

// assertConfigSafe re-parses the generated config and fails closed if any
// invariant we rely on is missing — belt-and-braces against future edits.
// `mode` is "proxy" or "vpn"; the inbound checks differ, everything else is shared.
func assertConfigSafe(raw []byte, mode string) error {
	var cfg struct {
		Experimental json.RawMessage `json:"experimental"`
		Inbounds     []struct {
			Type      string  `json:"type"`
			Listen    *string `json:"listen"`
			AutoRoute bool    `json:"auto_route"`
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
	switch mode {
	case "vpn":
		if in.Type != "tun" {
			return fmt.Errorf("vpn mode: inbound type is %q, want \"tun\"", in.Type)
		}
		if in.Listen != nil {
			return fmt.Errorf("vpn mode: tun inbound must not have a listen address (got %q)", *in.Listen)
		}
		if !in.AutoRoute {
			return errors.New("vpn mode: tun inbound must set auto_route")
		}
	default: // proxy
		if in.Type == "tun" {
			return errors.New("proxy mode: inbound must not be a tun device")
		}
		if in.Listen == nil {
			return errors.New("proxy mode: inbound has no listen address")
		}
		if ip := net.ParseIP(*in.Listen); ip == nil || !ip.IsLoopback() {
			return fmt.Errorf("inbound listen %q is not a loopback address", *in.Listen)
		}
	}
	return assertOutboundsSafe(cfg.Outbounds)
}

// assertOutboundsSafe enforces the only two shapes we ever generate:
//
//	[proxy(<protocol>), direct]                        — single candidate
//	[node-0 … node-N-1, proxy(selector), direct]       — candidate set
//
// Anything else — an extra tag, a second selector, a node whose type is not an
// allowed proxy protocol, a `direct`/`block` smuggled in as a node — is refused.
func assertOutboundsSafe(outs []struct {
	Type string `json:"type"`
	Tag  string `json:"tag"`
},
) error {
	if len(outs) < 2 {
		return fmt.Errorf("expected at least 2 outbounds, got %d", len(outs))
	}
	seen := make(map[string]struct{}, len(outs))
	nodes := 0
	var haveProxy, haveDirect bool
	for _, o := range outs {
		if _, dup := seen[o.Tag]; dup {
			return fmt.Errorf("duplicate outbound tag %q", o.Tag)
		}
		seen[o.Tag] = struct{}{}
		switch {
		case o.Tag == "direct":
			if o.Type != "direct" {
				return fmt.Errorf("the %q outbound has type %q", o.Tag, o.Type)
			}
			haveDirect = true
		case o.Tag == proxyTag:
			// Either the single node itself, or the selector over the candidates.
			if o.Type != "selector" {
				if _, ok := allowedOutboundTypes[o.Type]; !ok {
					return fmt.Errorf("the %q outbound has disallowed type %q", o.Tag, o.Type)
				}
				nodes++
			}
			haveProxy = true
		case o.Tag == nodeTag(nodes):
			if _, ok := allowedOutboundTypes[o.Type]; !ok {
				return fmt.Errorf("candidate %q has disallowed type %q", o.Tag, o.Type)
			}
			nodes++
		default:
			return fmt.Errorf("unexpected outbound tag %q", o.Tag)
		}
	}
	if !haveProxy {
		return errors.New(`generated config missing the "proxy" outbound`)
	}
	if !haveDirect {
		return errors.New(`generated config missing the "direct" outbound`)
	}
	if nodes == 0 {
		return errors.New("generated config has no node outbound")
	}
	if len(outs) != nodes+2 && len(outs) != 2 {
		return fmt.Errorf("expected %d outbounds, got %d", nodes+2, len(outs))
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
