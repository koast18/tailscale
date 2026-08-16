package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httputil"
	"strings"
	"sync"
	"time"
)

// Self-implemented local HTTP proxy. Two modes:
//
//   - CONNECT (TLS tunneling): hijack the client connection and pipe bytes
//     bidirectionally to srv.Dial on the tailnet.
//   - Plain HTTP: reverse-proxy through a transport whose DialContext is
//     srv.Dial, so every request exits via the tailnet.
//
// This is more predictable under iOS app hooks than relying on the SOCKS5
// loopback proxy in 4.1.

var (
	httpProxyMu sync.Mutex
	httpProxyLn net.Listener
	httpProxy   *http.Server
	httpProxyTr *http.Transport
)

//export TsStartLocalHTTPProxy
func TsStartLocalHTTPProxy(port C.int) (rc C.int) {
	defer func() { if p := recover(); p != nil { tslogf("PANIC in TsStartLocalHTTPProxy: %v", p); rc = -1 } }()
	httpProxyMu.Lock()
	defer httpProxyMu.Unlock()
	if httpProxy != nil {
		tslogf("TsStartLocalHTTPProxy: already running on %s", httpProxyLn.Addr())
		return 0
	}
	s, err := getSrv()
	if err != nil {
		tslogf("TsStartLocalHTTPProxy: %v", err)
		return -1
	}

	ln, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", int(port)))
	if err != nil {
		tslogf("TsStartLocalHTTPProxy: listen: %v", err)
		return -1
	}

	httpProxyTr = &http.Transport{
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			return s.Dial(ctx, network, addr)
		},
		ForceAttemptHTTP2:     true,
		MaxIdleConns:          100,
		IdleConnTimeout:       90 * time.Second,
		TLSHandshakeTimeout:   10 * time.Second,
		ExpectContinueTimeout: 1 * time.Second,
	}

	httpProxy = &http.Server{
		Handler: http.HandlerFunc(handleProxy),
	}
	httpProxyLn = ln
	go func() {
		if err := httpProxy.Serve(ln); err != nil && err != http.ErrServerClosed {
			tslogf("TsStartLocalHTTPProxy: serve: %v", err)
		}
	}()
	tslogf("TsStartLocalHTTPProxy: listening on %s", ln.Addr())
	return 0
}

//export TsStopLocalHTTPProxy
func TsStopLocalHTTPProxy() {
	httpProxyMu.Lock()
	defer httpProxyMu.Unlock()
	if httpProxy != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		_ = httpProxy.Shutdown(ctx)
		httpProxy = nil
		httpProxyLn = nil
		if httpProxyTr != nil {
			httpProxyTr.CloseIdleConnections()
			httpProxyTr = nil
		}
		tslogf("TsStopLocalHTTPProxy: stopped")
	}
}

func handleProxy(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodConnect {
		handleConnect(w, r)
		return
	}
	// Plain HTTP: reverse proxy out through the tailnet.
	httpProxyMu.Lock()
	tr := httpProxyTr
	httpProxyMu.Unlock()
	if tr == nil {
		http.Error(w, "proxy not initialized", http.StatusServiceUnavailable)
		return
	}
	rp := &httputil.ReverseProxy{
		Director: func(req *http.Request) {
			req.URL.Scheme = "http"
			req.URL.Host = req.Host
		},
		Transport: tr,
	}
	rp.ServeHTTP(w, r)
}

// handleConnect implements the HTTP CONNECT tunnel: hijack, reply 200, then
// pipe bytes between the client and the tailnet destination via srv.Dial.
func handleConnect(w http.ResponseWriter, r *http.Request) {
	s, err := getSrv()
	if err != nil {
		http.Error(w, err.Error(), http.StatusServiceUnavailable)
		return
	}
	dst := r.Host
	if !strings.Contains(dst, ":") {
		dst = net.JoinHostPort(dst, "443")
	}

	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	up, err := s.Dial(ctx, "tcp", dst)
	if err != nil {
		http.Error(w, fmt.Sprintf("dial %s: %v", dst, err), http.StatusBadGateway)
		return
	}

	hj, ok := w.(http.Hijacker)
	if !ok {
		up.Close()
		http.Error(w, "hijacking not supported", http.StatusInternalServerError)
		return
	}
	conn, buf, err := hj.Hijack()
	if err != nil {
		up.Close()
		return
	}
	if _, err := buf.WriteString("HTTP/1.1 200 Connection Established\r\n\r\n"); err != nil {
		conn.Close()
		up.Close()
		return
	}
	if err := buf.Flush(); err != nil {
		conn.Close()
		up.Close()
		return
	}

	// Bidirectional copy. The buffered reader may already hold client bytes.
	done := make(chan struct{}, 2)
	cp := func(dst io.Writer, src io.Reader) {
		io.Copy(dst, src)
		done <- struct{}{}
	}
	go cp(up, buf) // buffered reader wraps conn
	go cp(conn, up)

	// Close both once either direction finishes (standard tunnel teardown).
	<-done
	conn.Close()
	up.Close()
	<-done
}
