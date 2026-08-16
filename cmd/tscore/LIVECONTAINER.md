# LiveContainer integration (iOS 18.6.2)

This is how to dlopen the Tailscale core dylib inside LiveContainer on a real
device and verify the exported functions are callable.

## 1. Get the dylib

Download `libTailscaleCore.dylib` (C ABI) or `TsCoreObjC-device.dylib`
(gomobile ObjC API) from the workflow artifacts / GitHub Release
(see `.github/workflows/ios-dylib.yml`, `.github/workflows/ios-dylib-gomobile.yml`).

Both are `-buildmode=c-shared` Mach-O arm64 dylibs with a load-time
constructor, so **dyld starts the Go runtime at dlopen**. They are ad-hoc
signed; LiveContainer's "Sign All Tweaks" (force) re-signs them with your
imported certificate (a bare ad-hoc signature is not enough on a device).

## 2. Copy into the LiveContainer sandbox

LiveContainer exposes the app sandbox via `LC_HOME_PATH`. Either drop the
dylib into the container's Documents and reference it by path, or load it
from your tweak's own bundle.

## 3. Load it and call the exports (C ABI dylib)

```objc
// in your LiveContainer tweak/host
#import <dlfcn.h>

void *h = dlopen([dylibPath UTF8String], RTLD_NOW);
if (!h) { NSLog(@"dlopen failed: %s", dlerror()); return; }

// optional: wait until Go runtime init finished (safe to always call)
TsEnsureInit();

// lifecycle
TsInit(stateDir, "myNode");          // 0 on success
TsSetLogCallback(myLog);
TsSetStateCallback(myState);         // 0 idle 1 connecting 2 running 3 error
TsStart();                           // async connect

// poll / query (all exported Ts* functions work the same way)
const char *v = TsVersion();
char *socks = TsSocks5Addr();        // "127.0.0.1:port" once running
TsFreeString(socks);
```

Every `char*` returned by `Ts*` is Go-side `C.CString` — free it with
`TsFreeString`.

## 4. Load it and call the exports (gomobile ObjC dylib)

The gomobile dylib exports both the `TsCoreTscorebind*` Objective-C classes
and the `TsCoreTscorebind*` C entry points (package-level Go functions).
Since the host app was not compiled against the generated headers, resolve
them at runtime:

```objc
void *h = dlopen([dylibPath UTF8String], RTLD_NOW);

// package-level Go functions are exported C functions:
typedef id (*NewServerFn)(NSString*, NSString*, NSError**);
typedef NSString* (*VersionFn)(void);
NewServerFn newServer = (NewServerFn)dlsym(h, "TsCoreTscorebindNewServer");
VersionFn version = (VersionFn)dlsym(h, "TsCoreTscorebindVersionString");

id srv = newServer(stateDir, @"myNode", NULL);
NSLog(@"version: %@", version());
BOOL running = [srv isRunning];      // instance methods work directly on the object
```

## 5. What "verified" means

- **Simulator (iOS 18.5 runtime, GitHub Actions)**: both dylibs dlopen,
  constructors run, and `TsVersion`/`TsInit`/`TsIsRunning` (C ABI) and
  `TsCoreTscorebindNewServer`/`VersionString`/`isRunning` (ObjC) return real
  values — see the `ios-dylib-cshared.yml` / `ios-dylib-gomobile.yml` runs.
- **Device (iOS 18.6.2)**: install the `TsCoreVerify.ipa` test app
  (`cmd/tscore/hostapp`) and confirm `VERIFY-PASS` appears in the on-screen
  log (it runs the exact dlopen + exported-call sequence above). The app's
  log is also written to `Documents/verify.log`.

## Boot trace

Both dylibs write `<LC_HOME_PATH>/Documents/tscore-boot.log` (fallback
`/tmp/tscore-boot.log`): a constructor line when dyld enters, and
`lazy-init:` lines around runtime init. Check it if something hangs.

## Known behavior notes

- The earlier on-device "black screen at dlopen" hang was a self-deadlock in
  `TsInit` (a `sync.Mutex` re-lock), fixed in `cmd/tscore/derp.go` — not a
  dlopen/constructor problem.
- Sideloaded sandbox caveats (Go signal handlers, UDP sockets) still need
  on-device confirmation; the control-plane + DERP path is exercised by
  `TsStart`/`TsLogin` once the node joins your tailnet.
