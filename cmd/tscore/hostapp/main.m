// TsCoreVerify — minimal iOS host app that dlopens the Tailscale core dylib
// and verifies the exported functions are callable.
//
// Purpose: on-device verification on iOS 18.6.2 without Xcode. CI assembles
// this into an .ipa (ad-hoc signed); you sideload it with your signing tool
// (Sideloadly / AltStore / LiveContainer ZSign / your own cert) and the app
// prints every step on screen and to Documents/verify.log.
//
// Variant under test: libTailscaleCore-lazy.dylib (initializer stripped).
// Contract: call TsEnsureInit() once, right after dlopen; then all Ts*
// functions are usable. See cmd/tscore/README.md.
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <stdio.h>
#import <unistd.h>

typedef void (*TsEnsureInitFn)(void);
typedef const char *(*TsVersionFn)(void);
typedef int (*TsInitFn)(const char *, const char *);
typedef int (*TsIsRunningFn)(void);
typedef int (*TsStartFn)(void);
typedef int (*TsNeedsLoginFn)(void);

static NSString *g_logPath;

static void logLine(NSMutableString *buf, NSString *line) {
    NSLog(@"%@", line);
    [buf appendString:line];
    [buf appendString:@"\n"];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:g_logPath];
    if (!fh) {
        [[NSFileManager defaultManager] createFileAtPath:g_logPath contents:nil attributes:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:g_logPath];
    }
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
}

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) UILabel *label;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    g_logPath = [paths.firstObject stringByAppendingPathComponent:@"verify.log"];

    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.backgroundColor = UIColor.whiteColor;
    self.label = [[UILabel alloc] initWithFrame:CGRectZero];
    self.label.numberOfLines = 0;
    self.label.font = [UIFont systemFontOfSize:13];
    self.label.text = @"TsCoreVerify starting...";
    UIViewController *root = [UIViewController new];
    root.view.backgroundColor = UIColor.whiteColor;
    self.label.frame = UIEdgeInsetsInsetRect(root.view.bounds,
                                             UIEdgeInsetsMake(80, 20, 40, 20));
    self.label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [root.view addSubview:self.label];
    self.window.rootViewController = root;
    [self.window makeKeyAndVisible];
    [self performSelectorInBackground:@selector(runVerification) withObject:nil];
    return YES;
}

- (void)runVerification {
    NSMutableString *out = [NSMutableString string];
    logLine(out, @"== TsCoreVerify ==");
    logLine(out, [NSString stringWithFormat:@"iOS %@ on %@", UIDevice.currentDevice.systemVersion,
                  UIDevice.currentDevice.model]);

    NSString *dylibPath = [[NSBundle mainBundle].bundlePath
        stringByAppendingPathComponent:@"libTailscaleCore-lazy.dylib"];
    logLine(out, [NSString stringWithFormat:@"dlopen %@", dylibPath.lastPathComponent]);

    void *h = dlopen(dylibPath.UTF8String, RTLD_NOW);
    if (!h) {
        logLine(out, [NSString stringWithFormat:@"FAIL dlopen: %s", dlerror()]);
        [self showResult:out];
        return;
    }
    logLine(out, @"OK dlopen");

    TsEnsureInitFn ensure = (TsEnsureInitFn)dlsym(h, "TsEnsureInit");
    TsVersionFn version = (TsVersionFn)dlsym(h, "TsVersion");
    TsInitFn init = (TsInitFn)dlsym(h, "TsInit");
    TsIsRunningFn running = (TsIsRunningFn)dlsym(h, "TsIsRunning");
    if (!ensure || !version || !init || !running) {
        logLine(out, [NSString stringWithFormat:@"FAIL dlsym: %s", dlerror()]);
        [self showResult:out];
        return;
    }
    logLine(out, @"OK dlsym TsEnsureInit/TsVersion/TsInit/TsIsRunning");

    ensure(); // starts the Go runtime; blocks until package init completes
    logLine(out, @"OK TsEnsureInit returned");

    const char *v = version();
    logLine(out, [NSString stringWithFormat:@"TsVersion -> %s", v ? v : "(null)"]);

    // TsInit: create the tsnet.Server singleton (no network connection yet).
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *stateDir = [paths.firstObject stringByAppendingPathComponent:@"tsstate"];
    int rc = init(stateDir.UTF8String, "verify-node");
    logLine(out, [NSString stringWithFormat:@"TsInit -> %d (0 = OK)", rc]);

    int ir = running();
    logLine(out, [NSString stringWithFormat:@"TsIsRunning -> %d", ir]);

    // Real network test: TsStart() connects to the Tailscale control plane
    // (controlplane.tailscale.com). On the simulator this must not return
    // "Bad Request" from the control server (that happens when the request
    // is mangled by a proxy/MITM or rejected by the server).
    TsStartFn start = (TsStartFn)dlsym(h, "TsStart");
    TsNeedsLoginFn needsLogin = (TsNeedsLoginFn)dlsym(h, "TsNeedsLogin");
    if (!start || !needsLogin) {
        logLine(out, [NSString stringWithFormat:@"FAIL dlsym TsStart/TsNeedsLogin: %s", dlerror()]);
        [self showResult:out];
        return;
    }
    logLine(out, @"calling TsStart() (async connect, 25s window) ...");
    int sr = start();
    logLine(out, [NSString stringWithFormat:@"TsStart -> %d", sr]);
    sleep(25);
    ir = running();
    logLine(out, [NSString stringWithFormat:@"TsIsRunning(after 25s) -> %d", ir]);
    int nl = needsLogin();
    logLine(out, [NSString stringWithFormat:@"TsNeedsLogin -> %d", nl]);
    logLine(out, @"NETTEST-DONE (see tailscaled log for control server status)");

    logLine(out, @"VERIFY-PASS: dlopen OK, TsEnsureInit OK, exported calls OK");
    [self showResult:out];
}

- (void)showResult:(NSString *)text {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.label.text = text;
    });
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
