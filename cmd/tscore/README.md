# cmd/tscore — Tailscale core dylib for iOS sideloading (dlopen)

A pure function library: the host app dlopens the dylib and drives everything
through the exported `Ts*` C functions (or, in the gomobile build, the
generated `TsCore*` Objective-C classes). Built on `tailscale.com/tsnet`
(userspace gVisor netstack, no TUN/root) plus `client/local`'s LocalClient.

## How it is built (the mechanism that matters)

Go's `-buildmode=c-archive` (the default way to embed Go on iOS) on Go 1.26.6
no longer emits the load-time initializer (`_rt0_arm64_ios_lib`): DCE removes
it, so a c-archive → clang-dylib has **no constructor** and the Go runtime
never starts after dlopen.

The working mechanism is `-buildmode=c-shared` (the supported dynamic-library
mode on darwin), enabled on ios/arm64 by a 2-line Go toolchain patch:

- `cmd/tscore/patches/toolchain/ios-cshared.patch` — add `"ios/amd64",
  "ios/arm64"` to the c-shared platform list in `internal/platform/supported.go`.
- Build the patched toolchain (`cd src && GOROOT_BOOTSTRAP=… ./make.bash`) and
  then:

```bash
CGO_ENABLED=1 GOOS=ios GOARCH=arm64 \
CC="$(xcrun --find clang) -arch arm64 -isysroot $(xcrun --sdk iphoneos --show-sdk-path) -mios-version-min=15.0" \
CGO_CFLAGS="-arch arm64 -isysroot $(xcrun --sdk iphoneos --show-sdk-path) -mios-version-min=15.0" \
CGO_LDFLAGS="-arch arm64 -isysroot $(xcrun --sdk iphoneos --show-sdk-path) -mios-version-min=15.0" \
go build -buildmode=c-shared -trimpath -ldflags "-s -w" -o libTailscaleCore.dylib ./cmd/tscore
```

`-buildmode=c-shared` emits `__TEXT,__init_offsets` with the runtime entry, so
dyld starts the Go runtime at dlopen (ctor spawns the init thread, exported
calls block until package init completes — Go's standard c-shared contract).

Two variants are shipped:

- **`libTailscaleCore.dylib`** — ctor intact; the Go runtime starts at dlopen.
- **`libTailscaleCore-lazy.dylib`** — `cmd/tscore/tools/stripinits.py` zeroes
  the initializer section (`__TEXT,__init_offsets` / `__DATA,__mod_init_func`)
  so dyld performs no constructor. The host then calls `TsEnsureInit()` right
  after dlopen to wait for (ctor-started) init; intended for hosts that want
  full control of when the runtime kicks off.

The lazy/plain distinction matters less than it used to: the earlier
on-device "black screen at dlopen" hang was **not** the constructor — it was a
self-deadlock in `TsInit` (`restoreDerpOnly` re-locked the `sync.Mutex` that
`TsInit` already holds; fixed in cmd/tscore/derp.go).

## Layout

```
cmd/tscore/
├── main.go         // lifecycle: TsInit/TsStart/TsStop/TsLogin/…/TsEnsureInit
├── export.go       // exit node, diagnostics, prefs, taildrop, node info
├── http_proxy.go   // local HTTP CONNECT + reverse proxy onto the tailnet
├── derp.go         // derp-only mode (persisted)
├── bind/           // gomobile-bindable API (clean Go types; no C ABI)
├── hostapp/        // minimal iOS host app for on-device verification
├── tools/
│   ├── stripinits.py    // zero initializer sections of a Mach-O dylib
│   └── dlopen_test.c    // C dlopen harness (used by CI)
└── patches/
    └── toolchain/
        ├── ios-cshared.patch      // enable ios c-shared (2 lines)
        └── gomobile-cshared.patch // gomobile bind uses c-shared + compiles
                                   // the ObjC glue into the dylib
```

## Verification (GitHub Actions)

- `.github/workflows/ios-dylib-cshared.yml` — builds the patched toolchain,
  the c-shared dylib for the simulator + device, validates the device dylib's
  dlopen-readiness, and runs a real host app (`cmd/tscore/hostapp`) in a
  booted **iOS 18.6 simulator** (`com.apple.CoreSimulator.SimRuntime.iOS-18-6`)
  via `simctl launch --console`. **Result (run #31922548162):**

  ```
  selected runtime: com.apple.CoreSimulator.SimRuntime.iOS-18-6
  OK dlopen
  OK dlsym TsEnsureInit/TsVersion/TsInit/TsIsRunning
  OK TsEnsureInit returned
  TsVersion -> dev
  TsInit -> 0 (0 = OK)
  TsIsRunning -> 0
  VERIFY-PASS: dlopen OK, TsEnsureInit OK, exported calls OK
  ```

  Device dylib dlopen-readiness (same run): dependencies are all system
  images (`/usr/lib/libSystem.B.dylib`, CoreFoundation, Security,
  libresolv — everything dyld resolves from the iOS shared cache), undefined
  symbols only reference system frameworks, ad-hoc signature present, and
  the ctor check passes: `__init_offsets` size 12 (plain) / 0 (lazy).
  macOS native dlopen test also passes (TEST-PASS, diagnostic control).

- `.github/workflows/ios-dylib-gomobile.yml` — `gomobile bind -target=ios
  -prefix TsCore` on `cmd/tscore/bind` (patched to use c-shared and to
  compile the generated Objective-C glue into the dylib), producing
  `TsCore.xcframework` whose binaries are dlopen-able dylibs with the `TsCore*`
  ObjC classes inside; verified on the **iOS 18.6 simulator** by dlopening the
  dylib, dlsym-ing the exported C entry points and calling ObjC methods
  (run #31923417922):

  ```
  OBJCTEST-OK dlopen
  OBJCTEST-OK dlsym TsCoreTscorebindNewServer/VersionString
  OBJCTEST-OK TsCoreTscorebindNewServer
  OBJCTEST-INFO versionString=dev
  OBJCTEST-INFO isRunning=0
  OBJCTEST-PASS
  ```

- `.github/workflows/ios-dylib.yml` — builds the patched toolchain, the
  **device** dylibs (plain + lazy, `-buildmode=c-shared`, iphoneos arm64),
  checks every expected symbol (`nm -gU` → **All 43 expected Ts* symbols
  exported**), assembles the `TsCoreVerify.ipa` host app, and publishes the
  Release (run #31920789078).

## Integration (C ABI dylib)

```objc
void *h = dlopen(".../libTailscaleCore.dylib", RTLD_NOW);   // ctor starts runtime
TsEnsureInit();                    // wait until init completes (always safe)
TsInit(stateDirPath, "myNode");    // 0 on success
TsSetLogCallback(myLog);
TsSetStateCallback(myState);       // 0 idle 1 connecting 2 running 3 error
TsStart();                         // async; SOCKS5 via TsSocks5Addr/TsSocks5Cred
// exit node / prefs / taildrop / diagnostics via the other Ts* functions
// free every returned string with TsFreeString()
```

## Integration (gomobile ObjC dylib)

The generated API ships two flavors: Objective-C classes (`TsCoreTscorebindServer`
etc., for code compiled against the generated headers) and plain C entry
points for package-level Go functions (`TsCoreTscorebindNewServer(...)`).
Both live inside the dylib. For a host app that is compiled independently
(dlopen at runtime), resolve the C entry points via dlsym and call the ObjC
methods on the returned object:

```objc
void *h = dlopen(".../TsCore", RTLD_NOW);

// package-level Go functions are exported C functions:
typedef id (*NewServerFn)(NSString*, NSString*, NSError**);
NewServerFn newServer = (NewServerFn)dlsym(h, "TsCoreTscorebindNewServer");

id srv = newServer(stateDir, @"myNode", NULL);   // TsCoreTscorebindServer instance
BOOL running = [srv isRunning];
// [srv startWithError:NULL], [srv socks5Addr], [srv listPeers] …
```

Compiled against the headers instead: `#import "TsCore.h"` (generated by
gomobile), then `TsCoreTscorebindNewServer(...)` directly — the C functions
are declared there.

## LiveContainer notes

`LC_HOME_PATH` (LiveContainer sandbox root) is honored for the boot trace
(`<LC_HOME_PATH>/Documents/tscore-boot.log`, else `/tmp/tscore-boot.log`) and
as a fallback state directory. Load the dylib with LiveContainer's "Sign All
Tweaks" (force) so ZSign re-signs it with your imported certificate; a plain
ad-hoc signature is not enough for dyld on a real device.

Notes:

- All returned strings are Go-side `C.CString` allocations; free with
  `TsFreeString`.
- `TsLogin(authKey)` is synchronous (≤2 min timeout); alternatively start
  unauthenticated and use `TsLoginURL()` for interactive login.
- `TsSetHttpProxy` sets `HTTPS_PROXY` (control plane + DERP via
  `ProxyFromEnvironment`).
- Runtime behavior inside a sideloaded sandbox (Go runtime signal handlers,
  UDP sockets) requires on-device validation — the simulator test covers the
  dlopen + exported-call path on Apple's iOS runtime, but the final word is
  the physical device (iOS 18.6.2).
