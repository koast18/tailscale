// Minimal dlopen probe for iOS: an otherwise empty Go dylib (no tailscale)
// that writes boot-trace lines to <LC_HOME_PATH>/Documents/tscore-boot.log.
//
// Purpose: bisect the black-screen hang. If THIS dylib also hangs at dlopen,
// the problem is the Go runtime itself initializing under iOS dlopen
// (dyld holds its lock while running constructors; Go's lib entry
// pthread_create's a thread to init). If it loads fine, the hang is caused
// by one of the tailscale packages' inits in cmd/tscore.
package main

/*
#include <stdlib.h>
#include <stdio.h>
#include <time.h>
#include <string.h>

__attribute__((constructor))
static void probe_ctor_trace(void) {
    const char *home = getenv("LC_HOME_PATH");
    char p[1024];
    if (home && *home) {
        snprintf(p, sizeof p, "%s/Documents/tscore-boot.log", home);
    } else {
        snprintf(p, sizeof p, "/tmp/tscore-boot.log");
    }
    FILE *f = fopen(p, "a");
    if (f) {
        fprintf(f, "%lld ctor-probe: minimal Go dylib entering ctor\n", (long long)time(NULL));
        fclose(f);
    }
}
*/
import "C"

import (
	"fmt"
	"os"
	"time"
)

func probeLog(tag, msg string) {
	p := "/tmp/tscore-boot.log"
	if h := os.Getenv("LC_HOME_PATH"); h != "" {
		p = h + "/Documents/tscore-boot.log"
	}
	f, err := os.OpenFile(p, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	fmt.Fprintf(f, "%d %s %s\n", time.Now().Unix(), tag, msg)
	f.Close()
}

func init() {
	// Runs after the Go runtime finished initializing and all package
	// inits ran. Absence of this line means the runtime init is stuck.
	probeLog("probe-go-init:", "Go runtime init done (minimal dylib)")
}

//export TsMinProbe
func TsMinProbe() *C.char {
	probeLog("probe-export:", "TsMinProbe called")
	return C.CString("min")
}

func main() {}
