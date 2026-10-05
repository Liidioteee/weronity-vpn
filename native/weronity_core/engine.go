package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"regexp"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/include"
	"github.com/sagernet/sing-box/log"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing-box/protocol/group"
	singjson "github.com/sagernet/sing/common/json"
	"golang.org/x/net/proxy"
)

const coreVersion = "weronity-core 0.3.1 (sing-box v1.14.0)"

// maxCandidates caps the selector group. Each candidate is a constructed (but
// not dialed) outbound, so the cost is small — this only guards against a
// runaway list from Dart.
const maxCandidates = 32

// ping is the FFI marshalling smoke test: x -> x+1.
func ping(x int) int { return x + 1 }

// ---- event emitter -----------------------------------------------------

var (
	emitMu   sync.Mutex
	emitSink func(payloadJSON string)
)

func setEmitter(fn func(string)) {
	emitMu.Lock()
	emitSink = fn
	emitMu.Unlock()
}

func emit(level, tag, message string) {
	payload, _ := json.Marshal(map[string]string{
		"kind":    "log",
		"level":   level,
		"tag":     tag,
		"message": message,
	})
	pushEvent(string(payload)) // for the Dart poll drain

	emitMu.Lock()
	sink := emitSink
	emitMu.Unlock()
	if sink != nil { // for in-process Go tests
		sink(string(payload))
	}
}

// platformLog bridges sing-box's logger into emit().
//
// The platform writer is handed *every* message regardless of the configured
// log level, coloured for a terminal. Unfiltered, that is a trace line per
// packet flooding the event buffer and the UI; so we apply the level ourselves
// and strip the colour codes.
type platformLog struct {
	// maxLevel is the most verbose level that is forwarded.
	maxLevel log.Level
}

var ansiSeq = regexp.MustCompile("\x1b\\[[0-9;]*m")

func (p platformLog) WriteMessage(level log.Level, message string) {
	if level > p.maxLevel {
		return
	}
	emit(log.FormatLevel(level), "sing-box", ansiSeq.ReplaceAllString(message, ""))
}

func newPlatformLog(levelName string) platformLog {
	level, err := log.ParseLevel(levelName)
	if err != nil {
		level = log.LevelInfo
	}
	return platformLog{maxLevel: level}
}

// ---- engine ---------------------------------------------------------

type selfTestResult struct {
	Done      bool   `json:"done"`
	OK        bool   `json:"ok"`
	Status    string `json:"status"`
	LatencyMs int64  `json:"latency_ms"`
}

var (
	// engMu serialises start / stop (and the instance lookup of a hot-swap).
	// It is held for the whole of a start, which in vpn mode can take seconds.
	engMu   sync.Mutex
	running atomic.Bool

	// stateMu guards the session snapshot below. It is only ever held for a
	// few assignments, so statsJSON never waits behind a slow start/stop —
	// those may now run on a different thread than the poll.
	stateMu    sync.RWMutex
	instance   *box.Box
	cancelBox  context.CancelFunc
	relay      *countingRelay
	engineMode string
	publicPort int
	socksPort  int
	startedAt  time.Time
	stopPing   chan struct{}

	pingMs atomic.Int64

	// sessionGen changes on every start, so a goroutine left over from an
	// earlier session can tell its result is stale.
	sessionGen atomic.Int64

	selfMu   sync.Mutex
	selfTest selfTestResult

	rateMu               sync.Mutex
	rateAt               time.Time
	rateUp, rateDown     int64
	rateUpBps, rateDnBps float64

	// tagsMu guards the selector's candidate tags and the currently selected one.
	// acceptedIdx[i] is the index that tags[i] had in the list Dart sent, so a
	// backup dropped during sanitisation does not shift the caller's numbering.
	tagsMu      sync.Mutex
	activeTags  []string
	acceptedIdx []int
	activeTag   string
)

func engineRunning() bool { return running.Load() }

// newBox parses a generated config and constructs (but does not start) a
// sing-box instance for it.
func newBox(raw []byte) (*box.Box, context.CancelFunc, error) {
	baseCtx := include.Context(context.Background())
	options, err := singjson.UnmarshalExtendedContext[option.Options](baseCtx, raw)
	if err != nil {
		return nil, nil, fmt.Errorf("config parse failed: %w", err)
	}
	runCtx, cancel := context.WithCancel(baseCtx)
	// No PlatformLogWriter in box.Options — that would force an in-memory clash
	// server + a cache.db in the CWD. Callers attach the writer to the factory.
	b, err := box.New(box.Options{Context: runCtx, Options: options})
	if err != nil {
		cancel()
		return nil, nil, fmt.Errorf("engine create failed: %w", err)
	}
	return b, cancel, nil
}

// outboundConstructs reports whether sing-box accepts a sanitised outbound
// (tagged "proxy") on its own. Sanitising only proves the *shape* is harmless;
// sing-box still rejects an unknown cipher, a bad Reality key, an unsupported
// flow or uTLS fingerprint — and it rejects the whole config for it. Checking
// each candidate alone lets one bad backup be dropped instead of failing the
// start of a perfectly good primary. Nothing is started and nothing is dialed.
func outboundConstructs(clean map[string]any) error {
	raw, err := buildSingBoxConfig([]map[string]any{clean}, 1, "error")
	if err != nil {
		return err
	}
	b, cancel, err := newBox(raw)
	if err != nil {
		return err
	}
	cancel()
	return b.Close()
}

// startEngine sanitises the node outbound, generates a hardened sing-box config
// for the requested mode, and boots the engine.
//
//	proxy mode: one loopback mixed inbound + a counting relay on the public port
//	            + a one-shot connectivity probe and a periodic latency probe.
//	vpn mode:   one `tun` inbound with auto_route — the whole system's traffic
//	            goes through the node. Needs OS privileges (admin on Windows,
//	            CAP_NET_ADMIN / root on Linux). No relay (there is no local
//	            port); the latency probe goes straight out, i.e. into the tun.
func startEngine(configJSON string) (err error) {
	engMu.Lock()
	defer engMu.Unlock()
	if running.Load() {
		return nil
	}

	// Everything acquired below is released here unless the start commits —
	// including on a panic inside sing-box.
	var (
		b         *box.Box
		cancel    context.CancelFunc
		rl        *countingRelay
		committed bool
	)
	defer func() {
		if r := recover(); r != nil {
			err = fmt.Errorf("panic starting engine: %v", r)
			emit("error", "core", err.Error())
		}
		if committed {
			return
		}
		if rl != nil {
			_ = rl.Close()
		}
		if b != nil {
			_ = b.Close()
		}
		if cancel != nil {
			cancel()
		}
	}()

	var sc StartConfig
	if e := json.Unmarshal([]byte(configJSON), &sc); e != nil {
		emit("error", "core", "invalid start config: "+e.Error())
		return errors.New("invalid start config json")
	}
	vpn := sc.mode() == "vpn"

	candidates := sc.nodes()
	if len(candidates) == 0 {
		emit("error", "core", "rejected node outbound: empty outbound")
		return errors.New("empty outbound")
	}
	if len(candidates) > maxCandidates {
		candidates = candidates[:maxCandidates]
	}

	// Sanitise and validate every candidate on its own. One we cannot use is
	// dropped, not fatal — unless it is the first one (that is the node the user
	// actually picked).
	cleans := make([]map[string]any, 0, len(candidates))
	var accepted []int
	for i, raw := range candidates {
		san, se := sanitizeOutbound(raw, proxyTag)
		if se == nil {
			se = outboundConstructs(san.Outbound)
		}
		if se != nil {
			if i == 0 {
				emit("error", "core", "rejected node outbound: "+se.Error())
				return se
			}
			emit("warn", "core", fmt.Sprintf("кандидат #%d отброшен: %s", i, se.Error()))
			continue
		}
		for _, w := range san.Warnings {
			emit("warn", "core", w)
		}
		cleans = append(cleans, san.Outbound)
		accepted = append(accepted, i)
	}
	// A single survivor keeps tag "proxy" (no selector); several become
	// node-0…node-N-1 under a selector group tagged "proxy".
	tags := make([]string, len(cleans))
	for k, c := range cleans {
		tags[k] = proxyTag
		if len(cleans) > 1 {
			tags[k] = nodeTag(k)
		}
		c["tag"] = tags[k]
	}

	var raw []byte
	var e error
	var inner int
	if vpn {
		raw, e = buildTunConfig(cleans, sc.logLevel(), sc.StrictRoute)
	} else {
		inner = sc.SocksPort
		if inner == 0 {
			inner, e = freeLoopbackPort()
			if e != nil {
				return e
			}
		}
		raw, e = buildSingBoxConfig(cleans, inner, sc.logLevel())
	}
	if e != nil {
		emit("error", "core", "config generation failed: "+e.Error())
		return e
	}

	b, cancel, e = newBox(raw)
	if e != nil {
		emit("error", "core", e.Error())
		return e
	}
	if of, ok := b.LogFactory().(log.ObservableFactory); ok {
		of.AttachPlatformWriter(newPlatformLog(sc.logLevel()))
	}
	if e = b.Start(); e != nil {
		if vpn {
			emit("error", "core", "не удалось поднять VPN (TUN): нужны права администратора — "+e.Error())
		} else {
			emit("error", "core", "engine start failed: "+e.Error())
		}
		return e
	}

	public := 0
	if !vpn {
		// Counting relay on the public proxy port, in front of the sing-box inbound.
		upstream := fmt.Sprintf("127.0.0.1:%d", inner)
		wantPort := sc.listenPort()
		rl, e = startCountingRelay(fmt.Sprintf("127.0.0.1:%d", wantPort), upstream)
		if e != nil && wantPort != 0 {
			emit("warn", "core",
				fmt.Sprintf("порт %d занят (%s) — беру свободный", wantPort, e.Error()))
			rl, e = startCountingRelay("127.0.0.1:0", upstream)
		}
		if e != nil {
			emit("error", "core", "не удалось открыть локальный порт: "+e.Error())
			return e
		}
		_, portStr, _ := net.SplitHostPort(rl.addr())
		public, _ = strconv.Atoi(portStr)
	}

	stop := make(chan struct{})
	mode := "proxy"
	if vpn {
		mode = "vpn"
	}

	stateMu.Lock()
	instance, cancelBox, relay = b, cancel, rl
	engineMode, publicPort, socksPort = mode, public, inner
	startedAt, stopPing = time.Now(), stop
	stateMu.Unlock()
	committed = true
	gen := sessionGen.Add(1)

	tagsMu.Lock()
	activeTags, acceptedIdx = tags, accepted
	activeTag = tags[0]
	tagsMu.Unlock()
	resetTunCounters()
	pingMs.Store(0)
	resetRate()
	selfMu.Lock()
	selfTest = selfTestResult{}
	selfMu.Unlock()
	running.Store(true)

	if vpn {
		emit("info", "core", "VPN (TUN) поднят — весь трафик системы идёт через узел")
		go pingLoop(directDial, stop)
		return nil
	}

	emit("info", "core", fmt.Sprintf("прокси поднят — 127.0.0.1:%d (ядро на :%d)", public, inner))
	go pingLoop(socksDial(public), stop)
	if sc.selfTestEnabled() {
		go runSelfTest(gen, public, sc.selfTestURL())
	}
	return nil
}

func stopEngine() {
	engMu.Lock()
	defer engMu.Unlock()
	if !running.Load() {
		return
	}
	running.Store(false)

	stateMu.Lock()
	b, cancel, rl, stop := instance, cancelBox, relay, stopPing
	instance, cancelBox, relay, stopPing = nil, nil, nil, nil
	engineMode, publicPort, socksPort = "", 0, 0
	stateMu.Unlock()

	if stop != nil {
		close(stop)
	}
	if rl != nil {
		_ = rl.Close()
	}
	if b != nil {
		_ = b.Close()
	}
	if cancel != nil {
		cancel()
	}
	tagsMu.Lock()
	activeTags, acceptedIdx, activeTag = nil, nil, ""
	tagsMu.Unlock()
	pingMs.Store(0)
	emit("info", "core", "движок остановлен")
}

// selectCandidate switches the live selector group to the candidate that had
// index `i` in the list passed to wrnStart, *without* restarting the engine —
// in vpn mode that means no tun teardown and therefore no total network drop.
//
// `i` is the caller's own index: a backup dropped during sanitisation shifts
// nothing, because the mapping to the selector's tags is kept here. Returns an
// error when the engine is not running, was started with a single node (so
// there is no selector group), or `i` names a candidate that was dropped; the
// caller then falls back to stop/start.
func selectCandidate(i int) error {
	engMu.Lock()
	defer engMu.Unlock()
	stateMu.RLock()
	b := instance
	stateMu.RUnlock()
	if !running.Load() || b == nil {
		return errors.New("engine is not running")
	}

	tagsMu.Lock()
	tags := append([]string(nil), activeTags...)
	orig := append([]int(nil), acceptedIdx...)
	tagsMu.Unlock()
	if len(tags) < 2 {
		return errors.New("engine was started with a single node — no selector group")
	}
	pos := -1
	for p, o := range orig {
		if o == i {
			pos = p
			break
		}
	}
	if pos < 0 {
		return fmt.Errorf("candidate %d is not part of this session", i)
	}
	i = pos

	out, ok := b.Outbound().Outbound(proxyTag)
	if !ok {
		return errors.New("no proxy outbound")
	}
	sel, ok := out.(*group.Selector)
	if !ok {
		return errors.New("the proxy outbound is not a selector group")
	}
	if !sel.SelectOutbound(tags[i]) {
		return fmt.Errorf("selector refused %q", tags[i])
	}

	tagsMu.Lock()
	activeTag = tags[i]
	tagsMu.Unlock()
	pingMs.Store(0) // the old node's latency says nothing about the new one
	emit("info", "core", fmt.Sprintf("узел переключён на %s без разрыва туннеля", tags[i]))
	return nil
}

// probeBinding tells the throwaway probe engine how to keep its own sockets out
// of the main engine's tun (see routeBinding). The zero value when no tun is up.
func probeBinding() (bind routeBinding) {
	stateMu.RLock()
	b, mode := instance, engineMode
	stateMu.RUnlock()
	if b == nil || mode != "vpn" {
		return routeBinding{}
	}
	bind = routeBinding{autoDetect: true}
	defer func() { _ = recover() }() // a closing box may panic under us; fall back
	if mon := b.Network().InterfaceMonitor(); mon != nil {
		if iface := mon.DefaultInterface(); iface != nil && iface.Name != "" {
			bind.iface = iface.Name
		}
	}
	return bind
}

func statsJSON() string {
	selfMu.Lock()
	st := selfTest
	selfMu.Unlock()

	stateMu.RLock()
	mode, port, rl, started := engineMode, publicPort, relay, startedAt
	stateMu.RUnlock()
	isRunning := running.Load()

	// proxy mode counts at the relay; vpn mode has no relay, so we read the tun
	// adapter's own octet counters from the OS (ifstat_*.go).
	var up, down int64
	listen := fmt.Sprintf("127.0.0.1:%d", port)
	if mode == "vpn" {
		listen = "tun"
		up, down = tunCounters()
	} else if rl != nil {
		up, down = rl.upBytes(), rl.downBytes()
	}
	upBps, dnBps := sampleRate(up, down)

	tagsMu.Lock()
	tag, n := activeTag, len(activeTags)
	accepted := append([]int(nil), acceptedIdx...)
	tagsMu.Unlock()

	snap := map[string]any{
		"running":     isRunning,
		"mode":        mode,
		"listen":      listen,
		"socks_port":  port,
		"up_bytes":    up,
		"down_bytes":  down,
		"up_bps":      upBps,
		"down_bps":    dnBps,
		"ping_ms":     pingMs.Load(),
		"self_test":   st,
		"active_tag":  tag,
		"candidates":  n,
		"can_hotswap": n > 1,
		"accepted":    accepted,
	}
	if isRunning {
		snap["uptime_ms"] = time.Since(started).Milliseconds()
	} else {
		snap["uptime_ms"] = int64(0)
	}
	out, _ := json.Marshal(snap)
	return string(out)
}

func resetRate() {
	rateMu.Lock()
	rateAt = time.Now()
	rateUp, rateDown = 0, 0
	rateUpBps, rateDnBps = 0, 0
	rateMu.Unlock()
}

// sampleRate turns cumulative byte counters into a bytes/second estimate based
// on the delta since the previous call.
func sampleRate(up, down int64) (float64, float64) {
	rateMu.Lock()
	defer rateMu.Unlock()
	now := time.Now()
	dt := now.Sub(rateAt).Seconds()
	if dt >= 0.2 {
		rateUpBps = float64(up-rateUp) / dt
		rateDnBps = float64(down-rateDown) / dt
		if rateUpBps < 0 {
			rateUpBps = 0
		}
		if rateDnBps < 0 {
			rateDnBps = 0
		}
		rateAt, rateUp, rateDown = now, up, down
	}
	return rateUpBps, rateDnBps
}

// ---- latency probe -------------------------------------------------------

const (
	// A plain-HTTP 204 endpoint: one small request, one small answer, no TLS —
	// the cheapest thing that still has to cross the tunnel and come back.
	latencyHost     = "www.gstatic.com"
	latencyInterval = 15 * time.Second
	latencyTimeout  = 6 * time.Second
)

type dialFunc func(network, addr string) (net.Conn, error)

// socksDial dials through the local proxy port (proxy mode).
func socksDial(port int) dialFunc {
	return func(network, addr string) (net.Conn, error) {
		d, err := proxy.SOCKS5("tcp", fmt.Sprintf("127.0.0.1:%d", port), nil,
			&net.Dialer{Timeout: latencyTimeout})
		if err != nil {
			return nil, err
		}
		return d.Dial(network, addr)
	}
}

// directDial dials with the OS routing table — with a tun + auto_route up that
// is the tunnel (vpn mode).
func directDial(network, addr string) (net.Conn, error) {
	return net.DialTimeout(network, addr, latencyTimeout)
}

// measureLatency is the time from "open a connection through the tunnel" to
// "first byte of the HTTP answer" — a real round trip via the node. A SOCKS
// greeting alone would be answered by the local inbound and measure nothing.
func measureLatency(dial dialFunc) (int64, bool) {
	start := time.Now()
	c, err := dial("tcp", net.JoinHostPort(latencyHost, "80"))
	if err != nil {
		return 0, false
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(latencyTimeout))
	req := "HEAD /generate_204 HTTP/1.1\r\nHost: " + latencyHost + "\r\nConnection: close\r\n\r\n"
	if _, err := c.Write([]byte(req)); err != nil {
		return 0, false
	}
	buf := make([]byte, 5)
	if _, err := c.Read(buf); err != nil || string(buf) != "HTTP/" {
		return 0, false
	}
	return max(1, time.Since(start).Milliseconds()), true
}

// pingLoop keeps `ping_ms` current for the Pro latency graph: 0 = unknown / the
// last probe failed.
func pingLoop(dial dialFunc, stop <-chan struct{}) {
	probe := func() {
		ms, ok := measureLatency(dial)
		select {
		case <-stop: // the session ended while we were measuring
			return
		default:
		}
		if !ok {
			ms = 0
		}
		pingMs.Store(ms)
	}
	// Let the tunnel settle before the first sample.
	first := time.NewTimer(2 * time.Second)
	defer first.Stop()
	t := time.NewTicker(latencyInterval)
	defer t.Stop()
	for {
		select {
		case <-stop:
			return
		case <-first.C:
			probe()
		case <-t.C:
			probe()
		}
	}
}

// runSelfTest performs one HTTP request through the local proxy to confirm the
// tunnel actually carries traffic and to measure real latency.
func runSelfTest(gen int64, port int, url string) {
	start := time.Now()
	res := selfTestResult{Done: true}

	dialer, e := proxy.SOCKS5("tcp", fmt.Sprintf("127.0.0.1:%d", port), nil, proxy.Direct)
	if e != nil {
		res.Status = "socks dialer: " + e.Error()
		if storeSelfTest(gen, res) {
			emit("warn", "preflight", res.Status)
		}
		return
	}

	transport := &http.Transport{
		DisableKeepAlives:   true,
		TLSHandshakeTimeout: 8 * time.Second,
	}
	if cd, ok := dialer.(proxy.ContextDialer); ok {
		transport.DialContext = cd.DialContext
	} else {
		transport.DialContext = func(_ context.Context, network, addr string) (net.Conn, error) {
			return dialer.Dial(network, addr)
		}
	}
	client := &http.Client{Transport: transport, Timeout: 10 * time.Second}

	resp, e := client.Get(url)
	res.LatencyMs = time.Since(start).Milliseconds()
	if e != nil {
		res.Status = e.Error()
		if storeSelfTest(gen, res) {
			emit("warn", "preflight", fmt.Sprintf("self-test failed after %dms: %s", res.LatencyMs, e.Error()))
		}
		return
	}
	defer resp.Body.Close()
	res.OK = resp.StatusCode >= 200 && resp.StatusCode < 400
	res.Status = resp.Status
	if !storeSelfTest(gen, res) {
		return
	}
	lvl := "info"
	if !res.OK {
		lvl = "warn"
	}
	emit(lvl, "preflight", fmt.Sprintf("self-test %s in %dms (%s)", boolWord(res.OK), res.LatencyMs, resp.Status))
}

// storeSelfTest records the result unless the session it was measured for is
// already gone (a late result must not be reported against the next session).
func storeSelfTest(gen int64, r selfTestResult) bool {
	if !running.Load() || sessionGen.Load() != gen {
		return false
	}
	selfMu.Lock()
	selfTest = r
	selfMu.Unlock()
	return true
}

func boolWord(ok bool) string {
	if ok {
		return "ok"
	}
	return "failed"
}
