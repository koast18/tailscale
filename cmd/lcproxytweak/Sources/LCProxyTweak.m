//
//  LCProxyTweak.m
//  LCProxyTweak
//

#import "LCProxyTweak.h"
#import "KPLogger.h"
#import "KPCrashCatcher.h"
#import "KPConfig.h"
#import "KPModeController.h"
#import "KPTsCore.h"
#import "KPKingForwarder.h"
#import "KPWebServer.h"
#import "KPHookManager.h"
#import "Version.h"

#import <UIKit/UIKit.h>
#import <sys/utsname.h>
#import <unistd.h>

NSString *const KPTweakVersionString = @KPTWEAK_VERSION;

__attribute__((constructor))
void LCProxyTweakConstructor(void) {
    @autoreleasepool {
        KPLogger *logger = [KPLogger shared];
        [KPLogger installCrashHandler];

        // ============ boot ============
        struct utsname un = {0};
        uname(&un);
        NSString *device = @(un.machine);
        NSString *iosVer = [[UIDevice currentDevice] systemVersion] ?: @"?";
        NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier] ?: @"?";
        pid_t pid = getpid();

        // 崩溃捕获最先安装：后续任何闪退都会留下 crash-*.log（含堆栈）
        [KPCrashCatcher install];

        [logger stepCheckModule:KPLogModuleBoot name:@"tweak 载入" ok:YES
                         format:@"LCProxyTweak v%@ pid=%d", KPTweakVersionString, (int)pid];
        [logger logWithLevel:KPLogLevelInfo module:KPLogModuleBoot
                      format:@"设备=%@ iOS=%@ bundle=%@", device, iosVer, bundleId];

        // 单例/passive 检测（M2 接入：探测 127.0.0.1:19091；当前假定主实例）
        [logger stepCheckModule:KPLogModuleBoot name:@"单例检测(19091)"
                           ok:YES format:@"M2 接入，当前按主实例处理"];

        // ============ config ============
        KPConfig *cfg = [KPConfig shared];
        BOOL debugEnabled = [cfg debugEnabled];
        logger.debugMode = debugEnabled;
        NSString *logLevel = [cfg debugLogLevel];
        if ([logLevel isEqualToString:@"info"]) logger.minLevel = KPLogLevelInfo;
        else if ([logLevel isEqualToString:@"warn"]) logger.minLevel = KPLogLevelWarn;
        else if ([logLevel isEqualToString:@"error"]) logger.minLevel = KPLogLevelError;
        else logger.minLevel = KPLogLevelDebug;

        [logger stepCheckModule:KPLogModuleConfig name:@"配置加载" ok:YES
                         format:@"conf=%@ 存在=%d debug=%@ level=%@",
                         [cfg filePath], [cfg hasConfigFile], @(debugEnabled), logLevel];

        // ============ 模式应用（联动） ============
        NSDictionary *conf = [cfg load];
        KPModeController *modeCtrl = [KPModeController shared];
        // 底层代理 hook：先安装再应用模式（applyConfig 会触发期望代理 → 注入）
        KPHookManager *hook = [KPHookManager shared];
        [hook install];
        modeCtrl.delegate = (id<KPModeControllerDelegate>)hook;
        [modeCtrl applyConfig:conf];

        // ============ Web 控制台 ============
        KPWebServer *web = [KPWebServer shared];
        [web start];

        // ============ boot 汇总 ============
        [logger logWithLevel:KPLogLevelInfo module:KPLogModuleBoot
                      format:@"启动完成 模式=%@ core存在=%d 日志=%@",
                      KPModeName([modeCtrl currentMode]),
                      [[KPTsCore shared] corePresent],
                      [logger currentLogFilePath] ?: @"(未创建)"];
        [logger stepCheckModule:KPLogModuleBoot name:@"启动完成" ok:YES
                         format:@"模式=%@ 日志=%@", KPModeName([modeCtrl currentMode]),
                         [logger currentLogFilePath] ?: @"(未创建)"];
    }
}
