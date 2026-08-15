# cmd/tscore — Tailscale core dylib for iOS sideloading

A pure function library: dlopen loads it, executes no business logic (only Go
runtime init), and the host drives everything through the exported `Ts*` C ABI.

Built on `tailscale.com/tsnet` (userspace gVisor netstack, no TUN/root) plus
`client/local`'s LocalClient for control-plane operations. No upstream source
is modified — this package only consumes the official module.

## Layout

```
cmd/tscore/
├── main.go        // lifecycle: TsInit/TsStart/TsStop/TsLogin/…/callbacks
├── export.go      // exit node, diagnostics, prefs, taildrop, node info
└── http_proxy.go  // local HTTP CONNECT + reverse proxy onto the tailnet
```

## Build (macOS with Xcode; done by CI)

```bash
SDK=$(xcrun --sdk iphoneos --show-sdk-path)

# Note: Go does NOT support -buildmode=c-shared on ios/arm64 (hardcoded in
# internal/platform). Compile with c-archive (its Mach-O carries a
# __mod_init_func constructor, so the Go runtime initializes at dyld load
# time), then link the archive into a dylib with clang.

# 1) compile the Go core as a static archive (arm64 slice)
CGO_ENABLED=1 GOOS=ios GOARCH=arm64 \
CC="$(xcrun --find clang) -arch arm64 -isysroot $SDK -mios-version-min=15.0" \
CGO_CFLAGS="-arch arm64 -isysroot $SDK -mios-version-min=15.0" \
CGO_LDFLAGS="-arch arm64 -isysroot $SDK -mios-version-min=15.0" \
go build -buildmode=c-archive -trimpath -ldflags "-s -w" \
  -o libTailscaleCore-arm64.a ./cmd/tscore

# 2) link the archive into a dylib (arm64 slice)
clang -dynamiclib -arch arm64 -isysroot "$SDK" -mios-version-min=15.0 \
  -Wl,-all_load -Wl,-ObjC libTailscaleCore-arm64.a \
  -framework Foundation -framework Security -framework CoreFoundation \
  -o libTailscaleCore-arm64.dylib

# arm64e slice: repeat steps with GOARCH=arm64e / -arch arm64e, then merge:
lipo -create libTailscaleCore-arm64.dylib libTailscaleCore-arm64e.dylib \
  -output libTailscaleCore.dylib
```

Artifacts: `libTailscaleCore.dylib` + auto-generated `libTailscaleCore.h`.
No code signing is done here — sign adhoc (`codesign -s -`) or let the
sideload tool (e.g. LiveContainer's ZSign with your p12) sign on device.

## Verify

```bash
file libTailscaleCore.dylib      # Mach-O … arm64
lipo -info libTailscaleCore.dylib
nm -gU libTailscaleCore.dylib | grep -E '^_?Ts'   # all Ts* exports
otool -L libTailscaleCore.dylib                   # iOS system libs only
```

## Integration

```objc
#import "libTailscaleCore.h"

TsInit(stateDirPath, "myNode");
TsSetLogCallback(myLog);          // optional
TsSetStateCallback(myState);      // 0 idle 1 connecting 2 running 3 error
TsStart();                        // async; SOCKS5 via TsSocks5Addr/TsSocks5Cred
// exit node / prefs / taildrop / diagnostics via the Ts* functions above
// free every returned string with TsFreeString()
```

Notes:

- All returned strings are Go-side `C.CString` allocations; free with
  `TsFreeString`.
- `TsLogin(authKey)` is synchronous (≤2 min timeout); alternatively start
  unauthenticated and use `TsLoginURL()` for interactive login.
- `TsSetHttpProxy` sets `HTTPS_PROXY` (control plane + DERP via
  `ProxyFromEnvironment`).
- Runtime behavior inside a sideloaded sandbox (Go runtime signal handlers,
  UDP sockets) requires on-device validation — build-level guarantees only.
