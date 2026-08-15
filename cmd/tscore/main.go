// Package main implements a Tailscale core dynamic library for iOS
// sideloading (LiveContainer-style hosts that dlopen a .dylib).
//
// The library is a pure function library: dlopen performs no business logic
// (only Go runtime initialization). Everything is driven by the exported
// Ts* C ABI functions below.
//
// Build (run in CI, macOS with Xcode):
//
//	SDK=$(xcrun --sdk iphoneos --show-sdk-path)
//	CGO_ENABLED=1 GOOS=ios GOARCH=arm64 \
//	CC="$(xcrun --find clang) -arch arm64 -isysroot $SDK -mios-version-min=15.0" \
//	CGO_CFLAGS="-arch arm64 -isysroot $SDK -mios-version-min=15.0" \
//	CGO_LDFLAGS="-arch arm64 -isysroot $SDK -mios-version-min=15.0" \
//	go build -buildmode=c-shared -trimpath -ldflags "-s -w" -o libTailscaleCore.dylib ./cmd/tscore
package main

/*
#include <stdlib.h>

typedef void (*TsLogFn)(const char* msg);
typedef void (*TsStateFn)(int state);

// cgo cannot call C function pointers directly from Go; these static
// trampolines let us invoke callbacks registered by the host.
static void cts_log(TsLogFn fn, const char* s) { if (fn) fn(s); }
static void cts_state(TsStateFn fn, int st) { if (fn) fn(st); }
*/
import "C"

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"sync"
	"sync/atomic"
	"time"
	"unsafe"

	"tailscale.com/tsnet"
)

// State values reported through the TsStateFn callback / TsIsRunning.
const (
	stateIdle       = 0
	stateConnecting = 1
	stateRunning    = 2
	stateError      = 3
)

var (
	mu sync.Mutex // guards all globals below

	srv        *tsnet.Server
	srvCancel  context.CancelFunc
	stateDir   string
	hostname   string
	socks5Addr string
	socks5Cred string

	runState int32 // atomic, one of the state* constants

	logCB   C.TsLogFn
	stateCB C.TsStateFn
)

// tslogf forwards a formatted log line to the host-registered C callback
// (TsSetLogCallback), falling back to stderr if none is registered.
func tslogf(format string, a ...any) {
	msg := fmt.Sprintf(format, a...)
	if fn := logCB; fn != nil {
		c := C.CString(msg)
		C.cts_log(fn, c)
		C.free(unsafe.Pointer(c))
		return
	}
	fmt.Fprintln(os.Stderr, "[tscore]", msg)
}

func currentState() int32 { return atomic.LoadInt32(&runState) }

func setState(s int32) {
	atomic.StoreInt32(&runState, s)
	if fn := stateCB; fn != nil {
		C.cts_state(fn, C.int(s))
	}
}

// getSrv returns the singleton server, or an error if TsInit hasn't been
// called (or the server was stopped with TsStop).
func getSrv() (*tsnet.Server, error) {
	mu.Lock()
	defer mu.Unlock()
	if srv == nil {
		return nil, errors.New("not initialized: call TsInit first")
	}
	return srv, nil
}

// export TsInit initializes the singleton tsnet.Server with the given
// persistence directory and hostname. It does not connect to the tailnet.
//
//export TsInit
func TsInit(dir *C.char, hostname *C.char) C.int {
	mu.Lock()
	defer mu.Unlock()

	if srv != nil {
		tslogf("TsInit: already initialized")
		return 0
	}
	d := ""
	if dir != nil {
		d = C.GoString(dir)
	}
	h := ""
	if hostname != nil {
		h = C.GoString(hostname)
	}
	if d == "" {
		base, err := os.UserConfigDir()
		if err != nil {
			tslogf("TsInit: no state dir provided and os.UserConfigDir failed: %v", err)
			return -1
		}
		d = base
	}
	stateDir = d
	hostname = h
	logCB = nil
	stateCB = nil
	socks5Addr = ""
	socks5Cred = ""
	atomic.StoreInt32(&runState, stateIdle)

	s := &tsnet.Server{
		Dir:      d,
		Hostname: h,
		Logf:     tslogf,
	}
	srv = s
	tslogf("TsInit: dir=%s hostname=%q", d, h)
	return 0
}

// export TsStart asynchronously connects to the tailnet (srv.Up in a
// goroutine) and returns immediately. When ready, the SOCKS5 loopback
// address/credentials are cached and the state callback fires with 2.
//
//export TsStart
func TsStart() C.int {
	s, err := getSrv()
	if err != nil {
		tslogf("TsStart: %v", err)
		return -1
	}
	if currentState() == stateRunning {
		return 0
	}

	ctx, cancel := context.WithCancel(context.Background())
	mu.Lock()
	srvCancel = cancel
	mu.Unlock()

	go func() {
		setState(stateConnecting)
		if _, err := s.Up(ctx); err != nil {
			if ctx.Err() != nil {
				return // stopped by TsStop
			}
			tslogf("TsStart: Up failed: %v", err)
			setState(stateError)
			return
		}
		if err := cacheLoopback(); err != nil {
			tslogf("TsStart: Loopback failed: %v", err)
			setState(stateError)
			return
		}
		mu.Lock()
		addr := socks5Addr
		mu.Unlock()
		tslogf("TsStart: running, SOCKS5 at %s", addr)
		setState(stateRunning)
	}()
	return 0
}

// cacheLoopback starts the tsnet loopback SOCKS5 + localapi server and caches
// the address and credential ("tsnet:<password>").
func cacheLoopback() error {
	s, err := getSrv()
	if err != nil {
		return err
	}
	addr, proxyCred, _, err := s.Loopback()
	if err != nil {
		return err
	}
	mu.Lock()
	socks5Addr = addr
	socks5Cred = "tsnet:" + proxyCred
	mu.Unlock()
	return nil
}

// export TsStop closes the tailnet connection and resets the singleton. A
// subsequent TsInit/TsStart begins a fresh lifecycle.
//
//export TsStop
func TsStop() {
	mu.Lock()
	s := srv
	cancel := srvCancel
	srv = nil
	srvCancel = nil
	socks5Addr = ""
	socks5Cred = ""
	mu.Unlock()

	if cancel != nil {
		cancel()
	}
	if s != nil {
		if err := s.Close(); err != nil && !errors.Is(err, net.ErrClosed) {
			tslogf("TsStop: Close: %v", err)
		}
	}
	setState(stateIdle)
	tslogf("TsStop: stopped")
}

//export TsIsRunning
func TsIsRunning() C.int {
	if currentState() == stateRunning {
		return 1
	}
	return 0
}

// export TsLogin authenticates with an AuthKey, synchronously waiting until
// the node is Running (up to loginTimeout). Idempotent: if already running
// it returns 0 immediately.
//
//export TsLogin
func TsLogin(authKey *C.char) C.int {
	s, err := getSrv()
	if err != nil {
		tslogf("TsLogin: %v", err)
		return -1
	}
	if currentState() == stateRunning {
		return 0
	}
	if authKey == nil {
		tslogf("TsLogin: nil auth key")
		return -1
	}

	// Cancel any pending asynchronous start so this synchronous login owns
	// the Up call.
	mu.Lock()
	if srvCancel != nil {
		srvCancel()
	}
	mu.Unlock()

	s.AuthKey = C.GoString(authKey)

	ctx, cancel := context.WithTimeout(context.Background(), loginTimeout)
	defer cancel()
	setState(stateConnecting)
	if _, err := s.Up(ctx); err != nil {
		if ctx.Err() == context.DeadlineExceeded {
			tslogf("TsLogin: timeout waiting for login")
		} else {
			tslogf("TsLogin: %v", err)
		}
		setState(stateError)
		return 1
	}
	if err := cacheLoopback(); err != nil {
		tslogf("TsLogin: Loopback failed: %v", err)
		setState(stateError)
		return 1
	}
	setState(stateRunning)
	return 0
}

const loginTimeout = 2 * time.Minute

//export TsNeedsLogin
func TsNeedsLogin() C.int {
	s, err := getSrv()
	if err != nil {
		return 1
	}
	lc, err := s.LocalClient()
	if err != nil {
		return 1
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	st, err := lc.StatusWithoutPeers(ctx)
	if err != nil {
		return 1
	}
	switch st.BackendState {
	case "NoState", "NeedsLogin", "NeedsMachineAuth":
		return 1
	}
	return 0
}

//export TsLoginURL
func TsLoginURL() *C.char {
	s, err := getSrv()
	if err != nil {
		return C.CString("")
	}
	lc, err := s.LocalClient()
	if err != nil {
		return C.CString("")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	st, err := lc.StatusWithoutPeers(ctx)
	if err != nil {
		return C.CString("")
	}
	return C.CString(st.AuthURL)
}

// export TsSetHttpProxy sets the HTTPS_PROXY environment variable used by the
// control plane and DERP connections (tsdial reads ProxyFromEnvironment when
// dialing). Pass an empty string to clear.
//
//export TsSetHttpProxy
func TsSetHttpProxy(proxyURL *C.char) C.int {
	if proxyURL == nil {
		os.Unsetenv("HTTPS_PROXY")
		return 0
	}
	u := C.GoString(proxyURL)
	if u == "" {
		os.Unsetenv("HTTPS_PROXY")
		return 0
	}
	if err := os.Setenv("HTTPS_PROXY", u); err != nil {
		tslogf("TsSetHttpProxy: %v", err)
		return -1
	}
	tslogf("TsSetHttpProxy: HTTPS_PROXY=%s", u)
	return 0
}

//export TsSocks5Addr
func TsSocks5Addr() *C.char {
	mu.Lock()
	a := socks5Addr
	mu.Unlock()
	return C.CString(a)
}

//export TsSocks5Cred
func TsSocks5Cred() *C.char {
	mu.Lock()
	c := socks5Cred
	mu.Unlock()
	return C.CString(c)
}

//export TsFreeString
func TsFreeString(p *C.char) {
	if p != nil {
		C.free(unsafe.Pointer(p))
	}
}

//export TsSetLogCallback
func TsSetLogCallback(fn C.TsLogFn) {
	mu.Lock()
	logCB = fn
	mu.Unlock()
}

//export TsSetStateCallback
func TsSetStateCallback(fn C.TsStateFn) {
	mu.Lock()
	stateCB = fn
	mu.Unlock()
}

func main() {}
