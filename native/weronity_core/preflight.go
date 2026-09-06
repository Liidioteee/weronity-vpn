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

	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/include"
	"github.com/sagernet/sing-box/option"
	singjson "github.com/sagernet/sing/common/json"
	"golang.org/x/net/proxy"
)

type probeReq struct {
	Outbound  map[string]any `json:"outbound"`
	Targets   []string       `json:"targets"`
	TimeoutMs int            `json:"timeout_ms"`
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
}

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

	san, err := sanitizeOutbound(req.Outbound)
	if err != nil {
		return probeSummaryErr("rejected outbound: " + err.Error())
	}
	port, err := freeLoopbackPort()
	if err != nil {
		return probeSummaryErr(err.Error())
	}
	raw, err := buildSingBoxConfig(san.Outbound, port, "warn")
	if err != nil {
		return probeSummaryErr("config: " + err.Error())
	}

	baseCtx := include.Context(context.Background())
	opts, err := singjson.UnmarshalExtendedContext[option.Options](baseCtx, raw)
	if err != nil {
		return probeSummaryErr("config parse: " + err.Error())
	}
	runCtx, cancel := context.WithCancel(baseCtx)
	defer cancel()
	b, err := box.New(box.Options{Context: runCtx, Options: opts})
	if err != nil {
		return probeSummaryErr("engine create: " + err.Error())
	}
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
	var wg sync.WaitGroup
	for i, t := range targets {
		wg.Add(1)
		go func(i int, target string) {
			defer wg.Done()
			hits[i] = httpProbe(dialer, target, per)
		}(i, t)
	}
	wg.Wait()

	sum := probeSummary{BestMs: -1, Hits: hits}
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

func looksLikeHTML(b []byte) bool {
	s := strings.ToLower(strings.TrimSpace(string(b)))
	return strings.HasPrefix(s, "<!doctype html") || strings.HasPrefix(s, "<html")
}
