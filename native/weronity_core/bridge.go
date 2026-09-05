// Package main builds the Weronity native core as a C shared library
// (weronity_core.dll / libweronity_core.so) consumed by the Flutter client over
// dart:ffi.
//
// Phase 3.0 (this file): the smallest possible surface that proves the whole
// toolchain — cgo build, c-shared linkage, DLL/so loading from Dart, string and
// callback marshalling. Phase 3.1 replaces the stub engine with a real sing-box
// (libbox) engine; the exported C signatures are meant to stay stable.
//
// The C-facing functions here are thin shims; the actual logic lives in plain
// Go (engine.go) so it stays unit-testable without cgo.
package main

/*
#include <stdlib.h>

// Event callback: the core hands ownership of `json` back to Go immediately
// after the call returns, so the Dart side must copy anything it keeps.
typedef void (*wrn_event_cb)(const char* json);

static void wrn_invoke_event_cb(wrn_event_cb cb, const char* json) {
    if (cb != NULL) {
        cb(json);
    }
}
*/
import "C"

import "unsafe"

//export wrnCoreVersion
func wrnCoreVersion() *C.char {
	// Caller frees with wrnFree.
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

//export wrnSetEventCallback
func wrnSetEventCallback(cb C.wrn_event_cb) {
	if cb == nil {
		setEmitter(nil)
		return
	}
	setEmitter(func(payload string) {
		cs := C.CString(payload)
		C.wrn_invoke_event_cb(cb, cs)
		C.free(unsafe.Pointer(cs))
	})
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

//export wrnStatsJSON
func wrnStatsJSON() *C.char {
	// Caller frees with wrnFree.
	return C.CString(statsJSON())
}

func main() {}
