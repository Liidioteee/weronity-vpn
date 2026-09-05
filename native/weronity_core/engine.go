package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
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

const coreVersion = "weronity-core 0.1.0 (sing-box v1.14.0)"

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
	engMu     sync.Mutex
	running   atomic.Bool
	instance  *box.Box
	cancelBox context.CancelFunc
	socksPort int
	startedAt time.Time

	selfMu   sync.Mutex
	selfTest selfTestResult
)

func engineRunning() bool { return running.Load() }

// startEngine sanitises the node outbound, generates a loopback-only sing-box
// config, boots the engine and (optionally) runs a one-shot connectivity probe
// through the local SOCKS inbound.
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

	san, e := sanitizeOutbound(sc.Outbound)
	if e != nil {
		emit("error", "core", "rejected node outbound: "+e.Error())
		return e
	}
	for _, w := range san.Warnings {
		emit("warn", "core", w)
	}

	port := sc.SocksPort
	if port == 0 {
		port, e = freeLoopbackPort()
		if e != nil {
			return e
		}
	}

	raw, e := buildSingBoxConfig(san.Outbound, port, sc.logLevel())
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
	// NB: no PlatformLogWriter in box.Options — that would force sing-box to
	// build an in-memory clash server *and* a cache.db in the CWD. We attach the
	// log writer to the factory afterwards instead (see below), which keeps the
	// build free of with_clash_api and drops no logs that matter.
	b, e := box.New(box.Options{
		Context: runCtx,
		Options: options,
	})
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

	instance = b
	cancelBox = cancel
	socksPort = port
	startedAt = time.Now()
	running.Store(true)
	selfMu.Lock()
	selfTest = selfTestResult{}
	selfMu.Unlock()

	emit("info", "core", fmt.Sprintf("sing-box up — socks 127.0.0.1:%d", port))

	if sc.selfTestEnabled() {
		go runSelfTest(port, sc.selfTestURL())
	}
	return nil
}

func stopEngine() {
	engMu.Lock()
	defer engMu.Unlock()
	if !running.Load() {
		return
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
	emit("info", "core", "sing-box stopped")
}

func statsJSON() string {
	selfMu.Lock()
	st := selfTest
	selfMu.Unlock()

	snap := map[string]any{
		"running":    running.Load(),
		"socks_port": socksPort,
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

// runSelfTest performs one HTTP request through the local SOCKS proxy so we can
// confirm the tunnel actually carries traffic and measure real latency.
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
