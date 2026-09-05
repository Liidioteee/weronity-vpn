package main

import "sync"

// Bounded in-memory queue of event payloads (JSON strings). The Dart side polls
// wrnDrainEvents() while the engine runs — no C callback, so there is no
// cross-thread pointer-ownership hazard.
const eventBufferCap = 1000

var (
	evMu  sync.Mutex
	evBuf []string
)

func pushEvent(payloadJSON string) {
	evMu.Lock()
	evBuf = append(evBuf, payloadJSON)
	if len(evBuf) > eventBufferCap {
		evBuf = evBuf[len(evBuf)-eventBufferCap:]
	}
	evMu.Unlock()
}

// drainEvents returns everything queued since the last call and clears the queue.
func drainEvents() []string {
	evMu.Lock()
	out := evBuf
	evBuf = nil
	evMu.Unlock()
	return out
}
