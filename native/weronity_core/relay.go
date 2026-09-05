package main

import (
	"io"
	"net"
	"sync/atomic"
	"time"
)

// countingRelay is a transparent TCP relay that sits in front of sing-box's
// loopback inbound so we can report real byte counters in proxy mode.
//
// Clients speak SOCKS5/HTTP to the relay's public port; the relay blindly pipes
// the byte stream to sing-box's internal inbound and tallies each direction.
// (TCP only — SOCKS5 UDP ASSOCIATE bypasses the relay and is not counted; that
// is fine for browser/app proxying and is revisited with the TUN inbound.)
type countingRelay struct {
	ln       net.Listener
	upstream string
	up       atomic.Int64 // client -> upstream  (your upload)
	down     atomic.Int64 // upstream -> client  (your download)
	closed   atomic.Bool
}

func startCountingRelay(listenAddr, upstreamAddr string) (*countingRelay, error) {
	ln, err := net.Listen("tcp", listenAddr)
	if err != nil {
		return nil, err
	}
	r := &countingRelay{ln: ln, upstream: upstreamAddr}
	go r.acceptLoop()
	return r, nil
}

func (r *countingRelay) addr() string { return r.ln.Addr().String() }
func (r *countingRelay) upBytes() int64 {
	return r.up.Load()
}
func (r *countingRelay) downBytes() int64 { return r.down.Load() }

func (r *countingRelay) acceptLoop() {
	for {
		c, err := r.ln.Accept()
		if err != nil {
			if r.closed.Load() {
				return
			}
			continue
		}
		go r.handle(c)
	}
}

func (r *countingRelay) handle(client net.Conn) {
	defer client.Close()
	up, err := net.DialTimeout("tcp", r.upstream, 5*time.Second)
	if err != nil {
		return
	}
	defer up.Close()

	done := make(chan struct{}, 2)
	go func() {
		io.Copy(up, &countingReader{src: client, n: &r.up})
		if cw, ok := up.(interface{ CloseWrite() error }); ok {
			cw.CloseWrite()
		}
		done <- struct{}{}
	}()
	go func() {
		io.Copy(client, &countingReader{src: up, n: &r.down})
		if cw, ok := client.(interface{ CloseWrite() error }); ok {
			cw.CloseWrite()
		}
		done <- struct{}{}
	}()
	<-done
	<-done
}

func (r *countingRelay) Close() error {
	if r.closed.Swap(true) {
		return nil
	}
	return r.ln.Close()
}

type countingReader struct {
	src io.Reader
	n   *atomic.Int64
}

func (c *countingReader) Read(p []byte) (int, error) {
	n, err := c.src.Read(p)
	if n > 0 {
		c.n.Add(int64(n))
	}
	return n, err
}
