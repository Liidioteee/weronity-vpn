// Package main builds the Weronity native core as a C shared library
// (weronity_core.dll / libweronity_core.so) consumed by the Flutter client over
// dart:ffi.
//
// The C-facing functions here are thin shims; the real logic lives in plain Go
// (engine.go / config.go / events.go) so it stays unit-testable without cgo.
//
// String returns (wrnCoreVersion, wrnStatsJSON, wrnDrainEvents) transfer
// ownership — the caller must release them with wrnFree.
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"encoding/json"
	"unsafe"
)

//export wrnCoreVersion
func wrnCoreVersion() *C.char {
	return C.CString(coreVersion)
}

//export wrnPing
func wrnPing(x C.int) C.int {
	return C.int(ping(int(x)))
}

//export wrnFree
func wrnFree(p *C.char) {
	C.free(unsafe.Pointer(p))
}

//export wrnStart
func wrnStart(configJSON *C.char) C.int {
	if err := startEngine(C.GoString(configJSON)); err != nil {
		return 1
	}
	return 0
}

//export wrnStop
func wrnStop() C.int {
	stopEngine()
	return 0
}

//export wrnIsRunning
func wrnIsRunning() C.int {
	if engineRunning() {
		return 1
	}
	return 0
}

// wrnIsElevated: 1 = process is elevated (admin), 0 = not, -1 = unknown /
// not applicable (non-Windows).
//
//export wrnIsElevated
func wrnIsElevated() C.int {
	return C.int(isElevated())
}

// wrnRelaunchElevated re-launches this executable with a UAC prompt.
// Returns 0 (elevated instance starting — caller should exit), 1 (user
// declined), or -1 (failed / not applicable).
//
//export wrnRelaunchElevated
func wrnRelaunchElevated() C.int {
	return C.int(relaunchElevated())
}

//export wrnStatsJSON
func wrnStatsJSON() *C.char {
	return C.CString(statsJSON())
}

// wrnTestNode runs an isolated reachability test for one node and returns a
// JSON `probeSummary`. Blocking (up to ~timeout*targets); call it off the
// caller's UI thread. Does not touch the main engine.
//
//export wrnTestNode
func wrnTestNode(reqJSON *C.char) *C.char {
	return C.CString(testNodeJSON(C.GoString(reqJSON)))
}

// wrnDrainEvents returns a JSON array of event objects queued since the last
// call, then clears the queue. The Dart side polls this while the engine runs.
//
//export wrnDrainEvents
func wrnDrainEvents() *C.char {
	events := drainEvents()
	if len(events) == 0 {
		return C.CString("[]")
	}
	// events are already-marshalled JSON objects; assemble the array by hand to
	// avoid a re-encode.
	buf := make([]byte, 0, 32*len(events))
	buf = append(buf, '[')
	for i, e := range events {
		if i > 0 {
			buf = append(buf, ',')
		}
		buf = append(buf, e...)
	}
	buf = append(buf, ']')
	// validate once in debug-ish fashion; on the off chance a payload was not
	// valid JSON, fall back to an empty array rather than handing back garbage.
	if !json.Valid(buf) {
		return C.CString("[]")
	}
	return C.CString(string(buf))
}

func main() {}
