//
//  KPCrashCatcher.m
//  LCProxyTweak
//
//  崩溃捕获：NSException + SIGSEGV/SIGABRT/SIGBUS/SIGILL handler。
//  崩溃时把堆栈写进 KPLogger 日志目录的 crash-<time>.log，避免真机调试
//  只能看到"闪退"而拿不到堆栈。
//

#import "KPCrashCatcher.h"
#import "KPLogger.h"
#import <execinfo.h>
#import <signal.h>
#import <sys/time.h>

static NSString *KPCrashLogPath(void) {
    NSString *logDir = [[KPLogger shared] logsDirectory];
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (!logDir.length && paths.count) {
        logDir = [[paths.firstObject stringByAppendingPathComponent:@"KingProxy"] stringByAppendingPathComponent:@"logs"];
    }
    static NSDateFormatter *fmt;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"yyyyMMdd-HHmmss";
    });
    return [logDir stringByAppendingPathComponent:
            [NSString stringWithFormat:@"crash-%@.log", [fmt stringFromDate:[NSDate date]]]];
}

static void KPCrashWrite(NSString *reason, NSArray<NSString *> *extra) {
    @autoreleasepool {
        NSMutableString *out = [NSMutableString string];
        [out appendString:@"=== CRASH ===\n"];
        [out appendFormat:@"time=%s\n", [[[NSDate date] description] UTF8String]];
        if (reason) [out appendFormat:@"reason=%@\n", reason];
        for (NSString *e in extra) [out appendFormat:@"%@\n", e];
        [out writeToFile:KPCrashLogPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
        // 也打到 stderr（系统日志可查）
        if (reason) fprintf(stderr, "LCProxy CRASH: %s\n", reason.UTF8String);
    }
}

static void KPCrashSignalHandler(int sig, siginfo_t *info, void *context) {
    void *frames[128];
    int n = backtrace(frames, 128);
    char **syms = backtrace_symbols(frames, n);
    NSMutableArray *lines = [NSMutableArray array];
    [lines addObject:[NSString stringWithFormat:@"signal=%d (%s) si_addr=%p",
                      sig, strsignal(sig), info ? info->si_addr : NULL]];
    if (syms) {
        for (int i = 0; i < n; i++) {
            [lines addObject:[NSString stringWithFormat:@"  %d %s", i, syms[i] ?: "?"]];
        }
        free(syms);
    }
    KPCrashWrite([NSString stringWithFormat:@"signal %d", sig], lines);
    // 恢复默认 handler 再自杀，避免死循环
    signal(sig, SIG_DFL);
    raise(sig);
    _exit(128 + sig);
}

static void KPUncaughtExceptionHandler(NSException *exception) {
    NSMutableArray *lines = [NSMutableArray array];
    [lines addObject:[NSString stringWithFormat:@"name=%@", exception.name]];
    [lines addObject:[NSString stringWithFormat:@"reason=%@", exception.reason]];
    for (NSString *s in exception.callStackSymbols) {
        [lines addObject:[NSString stringWithFormat:@"  %@", s]];
    }
    KPCrashWrite(exception.description, lines);
}

@implementation KPCrashCatcher

+ (void)install {
    NSSetUncaughtExceptionHandler(&KPUncaughtExceptionHandler);

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = KPCrashSignalHandler;
    sa.sa_flags = SA_SIGINFO | SA_RESETHAND;
    sigemptyset(&sa.sa_mask);
    const int sigs[] = {SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGFPE};
    for (size_t i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++) {
        sigaction(sigs[i], &sa, NULL);
    }
    [[KPLogger shared] stepCheckModule:KPLogModuleBoot name:@"崩溃捕获"
                                   ok:YES format:@"handler 已安装（NSException+signal）"];
}

@end
