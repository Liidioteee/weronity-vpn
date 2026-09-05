package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/include"
	"github.com/sagernet/sing-box/log"
	"github.com/sagernet/sing-box/option"
	singjson "github.com/sagernet/sing/common/json"
	"golang.org/x/net/proxy"
)

const coreVersion = "weronity-core 0.2.0 (sing-box v1.14.0)"

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
type platformLog struct{}

func (platformLog) WriteMessage(level log.Level, message string) {
	emit(log.FormatLevel(level), "sing-box", message)
}

// ---- engine ---------------------------------------------------------

type selfTestResult struct {
	Done      bool   `json:"done"`
	OK        bool   `json:"ok"`
	Status    string `json:"status"`
	LatencyMs int64  `json:"latency_ms"`
}

var (
	engMu      sync.Mutex
	running    atomic.Bool
	instance   *box.Box
	cancelBox  context.CancelFunc
	relay      *countingRelay
	engineMode string
	publicPort int
	socksPort  int
	startedAt  time.Time
	stopPing   chan struct{}

	pingMs atomic.Int64

	selfMu   sync.Mutex
	selfTest selfTestResult

	rateMu               sync.Mutex
	rateAt               time.Time
	rateUp, rateDown     int64
	rateUpBps, rateDnBps float64
)

func engineRunning() bool { return running.Load() }

// startEngine sanitises the node outbound, generates a loopback-only sing-box
// config, boots the engine and — in proxy mode — a counting relay on the public
// port. It then runs a one-shot connectivity probe and a periodic latency probe.
func startEngine(configJSON string) (err error) {
	engMu.Lock()
	defer engMu.Unlock()
	if running.Load() {
		return nil
	}
	defer func() {
		if r := recover(); r != nil {
			err = fmt.Errorf("panic starting engine: %v", r)
			emit("error", "core", err.Error())
		}
	}()

	var sc StartConfig
	if e := json.Unmarshal([]byte(configJSON), &sc); e != nil {
		emit("error", "core", "invalid start config: "+e.Error())
		return errors.New("invalid start config json")
	}

	if sc.mode() == "vpn" {
		msg := "режим VPN (TUN) появится в Фазе 3.3 — пока доступен только режим прокси"
		emit("error", "core", msg)
		return errors.New("vpn/tun mode not implemented yet")
	}

	san, e := sanitizeOutbound(sc.Outbound)
	if e != nil {
		emit("error", "core", "rejected node outbound: "+e.Error())
		return e
	}
	for _, w := range san.Warnings {
		emit("warn", "core", w)
	}

	// Internal sing-box inbound port (loopback, ephemeral by default).
	inner := sc.SocksPort
	if inner == 0 {
		inner, e = freeLoopbackPort()
		if e != nil {
			return e
		}
	}

	raw, e := buildSingBoxConfig(san.Outbound, inner, sc.logLevel())
	if e != nil {
		emit("error", "core", "config generation failed: "+e.Error())
		return e
	}

	baseCtx := include.Context(context.Background())
	options, e := singjson.UnmarshalExtendedContext[option.Options](baseCtx, raw)
	if e != nil {
		emit("error", "core", "config parse failed: "+e.Error())
		return e
	}

	runCtx, cancel := context.WithCancel(baseCtx)
	// No PlatformLogWriter in box.Options — that would force an in-memory clash
	// server + a cache.db in the CWD. We attach the writer to the factory after.
	b, e := box.New(box.Options{Context: runCtx, Options: options})
	if e != nil {
		cancel()
		emit("error", "core", "engine create failed: "+e.Error())
		return e
	}
	if of, ok := b.LogFactory().(log.ObservableFactory); ok {
		of.AttachPlatformWriter(platformLog{})
	}
	if e = b.Start(); e != nil {
		_ = b.Close()
		cancel()
		emit("error", "core", "engine start failed: "+e.Error())
		return e
	}

	// Counting relay on the public proxy port, in front of the sing-box inbound.
	upstream := fmt.Sprintf("127.0.0.1:%d", inner)
	wantPort := sc.listenPort()
	rl, e := startCountingRelay(fmt.Sprintf("127.0.0.1:%d", wantPort), upstream)
	if e != nil {
		emit("warn", "core",
			fmt.Sprintf("порт %d занят (%s) — беру свободный", wantPort, e.Error()))
		rl, e = startCountingRelay("127.0.0.1:0", upstream)
	}
	if e != nil {
		_ = b.Close()
		cancel()
		emit("error", "core", "не удалось открыть локальный порт: "+e.Error())
		return e
	}
	_, portStr, _ := net.SplitHostPort(rl.addr())
	publicPort, _ = strconv.Atoi(portStr)

	instance = b
	cancelBox = cancel
	relay = rl
	engineMode = "proxy"
	socksPort = inner
	startedAt = time.Now()
	pingMs.Store(0)
	resetRate()
	running.Store(true)
	selfMu.Lock()
	selfTest = selfTestResult{}
	selfMu.Unlock()

	emit("info", "core", fmt.Sprintf("прокси поднят — 127.0.0.1:%d (ядро на :%d)", publicPort, inner))

	stopPing = make(chan struct{})
	go pingLoop(publicPort, stopPing)
	if sc.selfTestEnabled() {
		go runSelfTest(publicPort, sc.selfTestURL())
	}
	return nil
}

func stopEngine() {
	engMu.Lock()
	defer engMu.Unlock()
	if !running.Load() {
		return
	}
	if stopPing != nil {
		close(stopPing)
		stopPing = nil
	}
	if relay != nil {
		_ = relay.Close()
		relay = nil
	}
	if instance != nil {
		_ = instance.Close()
		instance = nil
	}
	if cancelBox != nil {
		cancelBox()
		cancelBox = nil
	}
	running.Store(false)
	emit("info", "core", "движок остановлен")
}

func statsJSON() string {
	selfMu.Lock()
	st := selfTest
	selfMu.Unlock()

	var up, down int64
	if relay != nil {
		up, down = relay.upBytes(), relay.downBytes()
	}
	upBps, dnBps := sampleRate(up, down)

	snap := map[string]any{
		"running":    running.Load(),
		"mode":       engineMode,
		"listen":     fmt.Sprintf("127.0.0.1:%d", publicPort),
		"socks_port": publicPort,
		"up_bytes":   up,
		"down_bytes": down,
		"up_bps":     upBps,
		"down_bps":   dnBps,
		"ping_ms":    pingMs.Load(),
		"self_test":  st,
	}
	if running.Load() {
		snap["uptime_ms"] = time.Since(startedAt).Milliseconds()
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

// pingLoop measures round-trip latency through the local proxy every 5s so the
// Pro latency graph shows real numbers.
func pingLoop(port int, stop <-chan struct{}) {
	probe := func() {
		start := time.Now()
		c, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", port), 3*time.Second)
		if err != nil {
			return
		}
		defer c.Close()
		// SOCKS5 no-auth handshake round-trip is a cheap, real RTT signal.
		if _, err := c.Write([]byte{0x05, 0x01, 0x00}); err != nil {
			return
		}
		buf := make([]byte, 2)
		_ = c.SetReadDeadline(time.Now().Add(3 * time.Second))
		if _, err := c.Read(buf); err != nil {
			return
		}
		pingMs.Store(time.Since(start).Milliseconds())
	}
	probe()
	t := time.NewTicker(5 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-stop:
			return
		case <-t.C:
			probe()
		}
	}
}

// runSelfTest performs one HTTP request through the local proxy to confirm the
// tunnel actually carries traffic and to measure real latency.
func runSelfTest(port int, url string) {
	start := time.Now()
	res := selfTestResult{Done: true}

	dialer, e := proxy.SOCKS5("tcp", fmt.Sprintf("127.0.0.1:%d", port), nil, proxy.Direct)
	if e != nil {
		res.Status = "socks dialer: " + e.Error()
		storeSelfTest(res)
		emit("warn", "preflight", res.Status)
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
		storeSelfTest(res)
		emit("warn", "preflight", fmt.Sprintf("self-test failed after %dms: %s", res.LatencyMs, e.Error()))
		return
	}
	defer resp.Body.Close()
	res.OK = resp.StatusCode >= 200 && resp.StatusCode < 400
	res.Status = resp.Status
	storeSelfTest(res)
	lvl := "info"
	if !res.OK {
		lvl = "warn"
	}
	emit(lvl, "preflight", fmt.Sprintf("self-test %s in %dms (%s)", boolWord(res.OK), res.LatencyMs, resp.Status))
}

func storeSelfTest(r selfTestResult) {
	selfMu.Lock()
	selfTest = r
	selfMu.Unlock()
}

func boolWord(ok bool) string {
	if ok {
		return "ok"
	}
	return "failed"
}
