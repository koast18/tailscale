// dlopen_test.c — host-side test harness for the Tailscale core dylib.
//
// Usage: dlopen_test <dylib> [--lazy]
//
//   --lazy   the dylib was built WITHOUT its initializer section (lazy
//            variant): call TsEnsureInit() right after dlopen, then exercise
//            exported functions. Without --lazy the test relies on the
//            constructor having started the Go runtime at dlopen.
//
// Every step prints a line to stderr (simctl spawn forwards stderr). The
// final line "TEST-PASS" (or a FAIL line) is what the CI workflow greps for.
#include <dlfcn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef const char *(*TsVersionFn)(void);
typedef int (*TsInitFn)(const char *, const char *);
typedef void (*TsEnsureInitFn)(void);

static void say(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fflush(stderr);
}

int main(int argc, char **argv) {
    if (argc < 2) {
        say("usage: %s <dylib> [--lazy]\n", argv[0]);
        return 2;
    }
    const char *path = argv[1];
    int lazy = argc > 2 && strcmp(argv[2], "--lazy") == 0;

    say("TEST-START dylib=%s lazy=%d\n", path, lazy);

    void *h = dlopen(path, RTLD_NOW);
    if (!h) {
        say("FAIL dlopen: %s\n", dlerror());
        return 1;
    }
    say("OK dlopen\n");

    if (lazy) {
        TsEnsureInitFn ensure = (TsEnsureInitFn)dlsym(h, "TsEnsureInit");
        if (!ensure) {
            say("FAIL dlsym TsEnsureInit: %s\n", dlerror());
            return 1;
        }
        say("OK dlsym TsEnsureInit\n");
        ensure();
        say("OK TsEnsureInit returned\n");
    }

    TsVersionFn version = (TsVersionFn)dlsym(h, "TsVersion");
    TsInitFn init = (TsInitFn)dlsym(h, "TsInit");
    if (!version || !init) {
        say("FAIL dlsym TsVersion/TsInit: %s\n", dlerror());
        return 1;
    }
    say("OK dlsym TsVersion/TsInit\n");

    const char *v = version();
    if (!v || !*v) {
        say("FAIL TsVersion returned %s\n", v ? "(empty)" : "NULL");
        return 1;
    }
    say("OK TsVersion -> %s\n", v);

    int rc = init("/tmp/tsstate", "verify-node");
    say("OK TsInit -> %d\n", rc);

    say("TEST-PASS\n");
    return 0;
}
