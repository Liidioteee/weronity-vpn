package main

import (
	"bytes"
	"io"
	"net"
	"testing"
	"time"
)

func TestCountingRelayPipesAndCounts(t *testing.T) {
	// upstream: echo server
	up, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer up.Close()
	go func() {
		for {
			c, err := up.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) { defer c.Close(); io.Copy(c, c) }(c)
		}
	}()

	r, err := startCountingRelay("127.0.0.1:0", up.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()

	conn, err := net.Dial("tcp", r.addr())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()

	payload := bytes.Repeat([]byte("weronity"), 128) // 1024 bytes
	if _, err := conn.Write(payload); err != nil {
		t.Fatal(err)
	}
	got := make([]byte, len(payload))
	_ = conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	if _, err := io.ReadFull(conn, got); err != nil {
		t.Fatalf("read back: %v", err)
	}
	if !bytes.Equal(got, payload) {
		t.Fatal("payload did not round-trip through the relay")
	}

	// counters settle after the copy goroutines run
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if r.upBytes() >= int64(len(payload)) && r.downBytes() >= int64(len(payload)) {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if r.upBytes() < int64(len(payload)) {
		t.Errorf("up bytes = %d, want >= %d", r.upBytes(), len(payload))
	}
	if r.downBytes() < int64(len(payload)) {
		t.Errorf("down bytes = %d, want >= %d", r.downBytes(), len(payload))
	}
}

func TestCountingRelayCloseIsIdempotent(t *testing.T) {
	up, _ := net.Listen("tcp", "127.0.0.1:0")
	defer up.Close()
	r, err := startCountingRelay("127.0.0.1:0", up.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	if err := r.Close(); err != nil {
		t.Fatalf("first close: %v", err)
	}
	if err := r.Close(); err != nil {
		t.Fatalf("second close should be a no-op: %v", err)
	}
}
