package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sync/atomic"
	"time"
	"unsafe"

	"tailscale.com/wgengine/magicsock"
)

// derpOnly mirrors the runtime magicsock flag and is persisted to
// stateDir/derp-only.json so the setting survives app restarts.
var derpOnly atomic.Bool

const derpOnlyFile = "derp-only.json"

func derpOnlyPath() string {
	mu.Lock()
	defer mu.Unlock()
	return filepath.Join(stateDir, derpOnlyFile)
}

func saveDerpOnly(v bool) error {
	mu.Lock()
	dir := stateDir
	mu.Unlock()
	if dir == "" {
		return errors.New("no state dir (TsInit not called)")
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	b, err := json.Marshal(map[string]bool{"derpOnly": v})
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(dir, derpOnlyFile), b, 0o600)
}

// restoreDerpOnly is called from TsInit (which already holds mu): re-applies
// the persisted flag so the derp-only setting survives app restarts.
// NOTE: must NOT take mu itself - TsInit holds it (sync.Mutex is not
// reentrant; locking again here self-deadlocks, which manifested as the
// "black screen at dlopen" hang in earlier on-device tests).
func restoreDerpOnly() {
	dir := stateDir
	if dir == "" {
		return
	}
	b, err := os.ReadFile(filepath.Join(dir, derpOnlyFile))
	if err != nil {
		return // never set
	}
	var st struct {
		DerpOnly bool `json:"derpOnly"`
	}
	if err := json.Unmarshal(b, &st); err != nil {
		tslogf("restoreDerpOnly: bad %s: %v", derpOnlyFile, err)
		return
	}
	derpOnly.Store(st.DerpOnly)
	magicsock.SetAlwaysDERP(st.DerpOnly)
	if st.DerpOnly {
		tslogf("TsInit: restored derp-only=true from %s", derpOnlyFile)
	}
}

// export TsSetDerpOnly enables/disables "DERP-only" mode: when enabled, UDP
// (P2P/hole punching) is disabled and all peer traffic is relayed via DERP.
//
// Behavior:
//   - sets the magicsock runtime flag (effective on the next socket bind);
//   - persists to stateDir/derp-only.json (survives app restarts);
//   - if the backend is running/connecting, synchronously restarts it
//     (Stop → Init → Start) and waits up to 30s for Running, so sockets
//     rebind with the new mode. Callers only see the state callback
//     2→0→1→2 ("brief disconnect").
//
// Returns 0 on success, non-zero on failure. Idempotent for repeated calls
// with the same value.
//
//export TsSetDerpOnly
func TsSetDerpOnly(enable C.int) (rc C.int) {
	defer func() { if p := recover(); p != nil { tslogf("PANIC in TsSetDerpOnly: %v", p); rc = -1 } }()
	v := enable != 0
	if derpOnly.Load() == v {
		return 0 // idempotent
	}

	// 1. Flip the magicsock runtime flag (read at socket bind/rebind time).
	magicsock.SetAlwaysDERP(v)
	derpOnly.Store(v)

	// 2. Persist so the setting survives app restarts.
	if err := saveDerpOnly(v); err != nil {
		tslogf("TsSetDerpOnly: persist failed: %v", err)
		return -1
	}
	tslogf("TsSetDerpOnly: derpOnly=%v", v)

	// 3. If the backend is up (or coming up), restart it so sockets rebind
	//    with the new mode. The flag only takes effect on (re)bind.
	if currentState() != stateIdle {
		if code := restartBackend(); code != 0 {
			tslogf("TsSetDerpOnly: backend restart failed (code %d)", code)
			return code
		}
	}
	return 0
}

//export TsGetDerpOnly
func TsGetDerpOnly() (rc C.int) {
	defer func() { if p := recover(); p != nil { tslogf("PANIC in TsGetDerpOnly: %v", p); rc = -1 } }()
	if derpOnly.Load() {
		return 1
	}
	return 0
}

// restartBackend performs Stop → Init → Start and waits for state Running
// (or up to 30s / error). Returns 0 on success.
func restartBackend() C.int {
	mu.Lock()
	dir, host := stateDir, hostname
	mu.Unlock()
	if dir == "" {
		return -1
	}
	tslogf("derp-only: restarting backend to rebind sockets")

	TsStop()

	cdir := C.CString(dir)
	chost := C.CString(host)
	code := TsInit(cdir, chost)
	C.free(unsafe.Pointer(cdir))
	C.free(unsafe.Pointer(chost))
	if code != 0 {
		return code
	}
	if code := TsStart(); code != 0 {
		return code
	}

	deadline := time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		switch currentState() {
		case stateRunning:
			tslogf("derp-only: backend running after restart")
			return 0
		case stateError:
			tslogf("derp-only: backend error after restart")
			return 1
		}
		time.Sleep(150 * time.Millisecond)
	}
	tslogf("derp-only: restart timed out waiting for Running")
	return 1
}
