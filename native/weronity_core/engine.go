package main

import (
	"encoding/json"
	"errors"
	"sync"
	"sync/atomic"
	"time"
)

const coreVersion = "weronity-core 0.0.1 (phase 3.0 skeleton)"

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
	emitMu.Lock()
	sink := emitSink
	emitMu.Unlock()
	if sink == nil {
		return
	}
	payload, _ := json.Marshal(map[string]string{
		"kind":    "log",
		"level":   level,
		"tag":     tag,
		"message": message,
	})
	sink(string(payload))
}

// ---- stub engine -----------------------------------------------------

var (
	engMu      sync.Mutex
	running    atomic.Bool
	stopTicker chan struct{}
	rxBytes    atomic.Int64
	txBytes    atomic.Int64
	startedAt  time.Time
)

func engineRunning() bool { return running.Load() }

// startEngine accepts a sing-box config JSON. Phase 3.0 only checks that it is
// syntactically valid JSON, flips the running flag and starts a synthetic stats
// ticker, so the Dart bridge can be built and tested against a real library
// before the sing-box dependency lands.
func startEngine(configJSON string) error {
	engMu.Lock()
	defer engMu.Unlock()
	if running.Load() {
		return nil
	}
	var probe any
	if err := json.Unmarshal([]byte(configJSON), &probe); err != nil {
		emit("error", "core", "invalid config json: "+err.Error())
		return errors.New("invalid config json")
	}

	rxBytes.Store(0)
	txBytes.Store(0)
	startedAt = time.Now()
	running.Store(true)
	stopTicker = make(chan struct{})
	go statsLoop(stopTicker)

	emit("info", "core", "engine started (phase 3.0 stub)")
	return nil
}

func stopEngine() {
	engMu.Lock()
	defer engMu.Unlock()
	if !running.Load() {
		return
	}
	close(stopTicker)
	running.Store(false)
	emit("info", "core", "engine stopped")
}

func statsJSON() string {
	snap := map[string]any{
		"running":  running.Load(),
		"rx_bytes": rxBytes.Load(),
		"tx_bytes": txBytes.Load(),
	}
	if running.Load() {
		snap["uptime_ms"] = time.Since(startedAt).Milliseconds()
	} else {
		snap["uptime_ms"] = int64(0)
	}
	out, _ := json.Marshal(snap)
	return string(out)
}

func statsLoop(stop <-chan struct{}) {
	t := time.NewTicker(time.Second)
	defer t.Stop()
	for {
		select {
		case <-stop:
			return
		case <-t.C:
			rxBytes.Add(64 * 1024)
			txBytes.Add(12 * 1024)
			emit("debug", "core", "keepalive ok")
		}
	}
}
