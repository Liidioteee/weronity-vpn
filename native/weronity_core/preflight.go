package main

// On-device node reachability test. Given one node outbound, spins a throwaway
// sing-box on an ephemeral loopback SOCKS port (fully isolated from the main
// engine — never touches `instance`/`running`), fires a few HTTP probes through
// it in parallel, tears everything down, and returns a JSON verdict.
//
// Used by the "Тест" button / "проверить видимые" in the client, because the
// public pool has a lot of dead keys.

import (
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/net/proxy"
)

type probeReq struct {
	Outbound  map[string]any `json:"outbound"`
	Targets   []string       `json:"targets"`
	TimeoutMs int            `json:"timeout_ms"`

	// ExitGeo also asks where the node's traffic actually leaves — see
	// probeSummary.ExitCountry.
	ExitGeo bool `json:"exit_geo"`
}

type probeHit struct {
	URL       string `json:"url"`
	OK        bool   `json:"ok"`
	Status    string `json:"status,omitempty"`
	LatencyMs int64  `json:"latency_ms"`
	Blocked   bool   `json:"blocked"` // reachable, but the response looks like a stub / block page
	Err       string `json:"err,omitempty"`
}

type probeSummary struct {
	OK        bool       `json:"ok"`        // at least one clean hit
	Reachable bool       `json:"reachable"` // the proxy carried *something* to at least one target
	BestMs    int64      `json:"best_ms"`   // fastest clean hit, or -1
	Hits      []probeHit `json:"hits"`
	Err       string     `json:"err,omitempty"` // engine-level failure (never started)

	// ExitCountry is the ISO-3166 alpha-2 country the node's traffic comes out
	// in, as seen from outside (only when the request set exit_geo). The pool's
	// `geo` is a GeoIP guess about the *entry* address; a relay or a CDN-fronted
	// node exits somewhere else, and registry-based GeoIP mislabels hosting
	// ranges. Empty = could not tell.
	ExitCountry string `json:"exit_country,omitempty"`

	// ExitCountryAlt is a second, independent opinion about the same thing.
	// "Which country is this address in" is each geolocation database's own
	// guess, and for leased address space they disagree — the caller compares
	// the two rather than trusting either.
	ExitCountryAlt string `json:"exit_country_alt,omitempty"`

	// ExitIP is the exit address itself, so the caller can ask its own offline
	// table for a third opinion.
	ExitIP string `json:"exit_ip,omitempty"`
}

const (
	// exitGeoURL answers with plain `key=value` lines, among them the
	// requester's address and country (`ip=…`, `loc=NL`) by Cloudflare's data.
	// Reached through the tunnel, the requester is the node's exit address.
	exitGeoURL = "https://www.cloudflare.com/cdn-cgi/trace"
	// exitGeoAltURL answers `{"ip":"…","country":"NL"}` from MaxMind GeoLite2 —
	// the database most websites use to decide where a visitor is.
	exitGeoAltURL = "https://api.country.is/"
)

var defaultProbeTargets = []string{
	"https://www.google.com/generate_204",
	"https://www.youtube.com/favicon.ico",
	"https://www.cloudflare.com/cdn-cgi/trace",
}

func probeSummaryErr(msg string) string {
	out, _ := json.Marshal(probeSummary{BestMs: -1, Err: msg})
	return string(out)
}

// testNodeJSON is the body behind wrnTestNode.
func testNodeJSON(reqJSON string) string {
	var req probeReq
	if err := json.Unmarshal([]byte(reqJSON), &req); err != nil {
		return probeSummaryErr("bad request json: " + err.Error())
	}
	targets := req.Targets
	if len(targets) == 0 {
		targets = defaultProbeTargets
	}
	if len(targets) > 8 {
		targets = targets[:8]
	}
	per := time.Duration(req.TimeoutMs) * time.Millisecond
	if per < time.Second || per > 20*time.Second {
		per = 7 * time.Second
	}

	san, err := sanitizeOutbound(req.Outbound, proxyTag)
	if err != nil {
		return probeSummaryErr("rejected outbound: " + err.Error())
	}
	port, err := freeLoopbackPort()
	if err != nil {
		return probeSummaryErr(err.Error())
	}
	// While the main engine holds a tun, bind this engine to the physical
	// interface — otherwise the probe would travel through the active node and
	// say nothing about whether the candidate is reachable from here.
	raw, err := buildBoundProxyConfig([]map[string]any{san.Outbound}, port, "warn", probeBinding())
	if err != nil {
		return probeSummaryErr("config: " + err.Error())
	}

	b, cancel, err := newBox(raw)
	if err != nil {
		return probeSummaryErr(err.Error())
	}
	defer cancel()
	if err := b.Start(); err != nil {
		_ = b.Close()
		return probeSummaryErr("engine start: " + err.Error())
	}
	defer b.Close()

	dialer, err := proxy.SOCKS5("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)), nil, proxy.Direct)
	if err != nil {
		return probeSummaryErr("socks: " + err.Error())
	}

	hits := make([]probeHit, len(targets))
	var exitCountry, exitIP, exitAlt string
	var wg sync.WaitGroup
	for i, t := range targets {
		wg.Add(1)
		go func(i int, target string) {
			defer wg.Done()
			hits[i] = httpProbe(dialer, target, per)
		}(i, t)
	}
	if req.ExitGeo {
		wg.Add(2)
		go func() {
			defer wg.Done()
			if body, ok := getThrough(dialer, exitGeoURL, per); ok {
				exitCountry, exitIP = parseTraceCountry(body), parseTraceIP(body)
			}
		}()
		go func() {
			defer wg.Done()
			if body, ok := getThrough(dialer, exitGeoAltURL, per); ok {
				exitAlt = parseCountryIs(body)
			}
		}()
	}
	wg.Wait()

	sum := probeSummary{
		BestMs: -1, Hits: hits,
		ExitCountry: exitCountry, ExitCountryAlt: exitAlt, ExitIP: exitIP,
	}
	for _, h := range hits {
		if h.OK {
			sum.OK = true
			sum.Reachable = true
			if sum.BestMs < 0 || h.LatencyMs < sum.BestMs {
				sum.BestMs = h.LatencyMs
			}
		} else if h.Status != "" || h.Blocked {
			sum.Reachable = true // handshake worked; the response was just bad
		}
	}
	out, _ := json.Marshal(sum)
	return string(out)
}

func httpProbe(dialer proxy.Dialer, target string, timeout time.Duration) probeHit {
	h := probeHit{URL: target}
	tr := &http.Transport{DisableKeepAlives: true, TLSHandshakeTimeout: timeout}
	if cd, ok := dialer.(proxy.ContextDialer); ok {
		tr.DialContext = cd.DialContext
	} else {
		tr.DialContext = func(_ context.Context, network, addr string) (net.Conn, error) {
			return dialer.Dial(network, addr)
		}
	}
	client := &http.Client{
		Transport:     tr,
		Timeout:       timeout,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	start := time.Now()
	resp, err := client.Get(target)
	h.LatencyMs = time.Since(start).Milliseconds()
	if err != nil {
		h.Err = err.Error()
		return h
	}
	defer resp.Body.Close()
	h.Status = resp.Status
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))

	switch {
	case resp.StatusCode == 204:
		h.OK = true // the ideal answer for a generate_204 target
	case resp.StatusCode >= 200 && resp.StatusCode < 300:
		ct := strings.ToLower(resp.Header.Get("Content-Type"))
		blockish := strings.Contains(ct, "text/html") || looksLikeHTML(body)
		if strings.Contains(target, "generate_204") && blockish {
			h.Blocked = true // 200 + HTML where a 204 was due = captive/DPI page
		} else {
			h.OK = true
		}
	case resp.StatusCode >= 300 && resp.StatusCode < 400:
		h.Blocked = true // an unexpected redirect — captive portal
	default:
		h.Blocked = resp.StatusCode == 403 || resp.StatusCode == 451
	}
	return h
}

// getThrough fetches a small text body through the proxy; ok is false on any
// failure or a non-200 answer.
func getThrough(dialer proxy.Dialer, url string, timeout time.Duration) (body string, ok bool) {
	tr := &http.Transport{DisableKeepAlives: true, TLSHandshakeTimeout: timeout}
	if cd, isCtx := dialer.(proxy.ContextDialer); isCtx {
		tr.DialContext = cd.DialContext
	} else {
		tr.DialContext = func(_ context.Context, network, addr string) (net.Conn, error) {
			return dialer.Dial(network, addr)
		}
	}
	client := &http.Client{Transport: tr, Timeout: timeout}
	resp, err := client.Get(url)
	if err != nil {
		return "", false
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", false
	}
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	return string(raw), true
}

// countryCode normalises a would-be ISO-3166 alpha-2 code. Only a real
// two-letter code counts: "XX" (unknown) and "T1" (Tor) come back empty.
func countryCode(s string) string {
	cc := strings.ToUpper(strings.TrimSpace(s))
	if len(cc) != 2 || cc == "XX" {
		return ""
	}
	for _, r := range cc {
		if r < 'A' || r > 'Z' {
			return ""
		}
	}
	return cc
}

// traceField returns the value of `key=` in a /cdn-cgi/trace body.
func traceField(body, key string) string {
	for _, line := range strings.Split(body, "\n") {
		if value, ok := strings.CutPrefix(strings.TrimSpace(line), key+"="); ok {
			return strings.TrimSpace(value)
		}
	}
	return ""
}

// parseTraceCountry pulls the requester's country (`loc=`) out of a trace body.
func parseTraceCountry(body string) string { return countryCode(traceField(body, "loc")) }

// parseTraceIP pulls the requester's address (`ip=`) out of a trace body; ""
// unless it really is an IP address.
func parseTraceIP(body string) string {
	ip := net.ParseIP(traceField(body, "ip"))
	if ip == nil {
		return ""
	}
	return ip.String()
}

// parseCountryIs reads `{"ip":"…","country":"NL"}`.
func parseCountryIs(body string) string {
	var answer struct {
		Country string `json:"country"`
	}
	if err := json.Unmarshal([]byte(body), &answer); err != nil {
		return ""
	}
	return countryCode(answer.Country)
}

func looksLikeHTML(b []byte) bool {
	s := strings.ToLower(strings.TrimSpace(string(b)))
	return strings.HasPrefix(s, "<!doctype html") || strings.HasPrefix(s, "<html")
}
