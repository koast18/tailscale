//
//  KPTsCore.m
//  LCProxyTweak
//

#import "KPTsCore.h"
#import "KPLogger.h"
#import "KPSharedPaths.h"
#import <dlfcn.h>

NSNotificationName const KPTsCoreStateChangedNotification = @"KPTsCoreStateChanged";
NSNotificationName const KPTsCoreSocks5ChangedNotification = @"KPTsCoreSocks5Changed";

// ---------- C ABI（对应 TAILSCALE_DYLIB_API.md） ----------

typedef void (*TsLogFn)(const char *msg);
typedef void (*TsStateFn)(int state);

typedef int  (*TsInitFn)(const char *dir, const char *hostname);
typedef int  (*TsStartFn)(void);
typedef void (*TsStopFn)(void);
typedef int  (*TsIsRunningFn)(void);
typedef int  (*TsLoginFn)(const char *authKey);
typedef int  (*TsNeedsLoginFn)(void);
typedef const char *(*TsLoginURLFn)(void);
typedef int  (*TsSetHttpProxyFn)(const char *proxyURL);
typedef const char *(*TsSocks5AddrFn)(void);
typedef const char *(*TsSocks5CredFn)(void);
typedef void (*TsFreeStringFn)(const char *p);
typedef void (*TsSetLogCallbackFn)(TsLogFn fn);
typedef void (*TsSetStateCallbackFn)(TsStateFn fn);
typedef const char *(*TsListExitNodesFn)(void);
typedef const char *(*TsGetExitNodeStatusFn)(void);
typedef const char *(*TsSuggestExitNodeFn)(void);
typedef int  (*TsSetExitNodeFn)(const char *nameOrIP);
typedef int  (*TsClearExitNodeFn)(void);
typedef int  (*TsSetExitNodeAllowLANAccessFn)(int enable);
typedef const char *(*TsPingFn)(const char *ip, const char *pingType);
typedef const char *(*TsNetcheckFn)(void);
typedef const char *(*TsDebugDERPRegionFn)(const char *regionCode);
typedef const char *(*TsStatusDetailJSONFn)(void);
typedef const char *(*TsGetPrefsJSONFn)(void);
typedef int  (*TsSetPrefsJSONFn)(const char *prefsJSON);
typedef int  (*TsSetHostnameFn)(const char *name);
typedef int  (*TsSetRouteAllFn)(int enable);
typedef const char *(*TsFileTargetsFn)(void);
typedef int  (*TsPushFileFn)(const char *nodeID, const char *name, const char *dataBase64, int size);
typedef const char *(*TsWaitingFilesFn)(void);
typedef const char *(*TsGetWaitingFileFn)(const char *name);
typedef int  (*TsDeleteWaitingFileFn)(const char *name);
typedef const char *(*TsTailscaleIPsFn)(void);
typedef const char *(*TsWhoIsFn)(const char *ipOrAddr);
typedef const char *(*TsListPeersFn)(void);
typedef int  (*TsStartLocalHTTPProxyFn)(int port);
typedef void (*TsStopLocalHTTPProxyFn)(void);
typedef const char *(*TsVersionFn)(void);
typedef int  (*TsSetDerpOnlyFn)(int enable);
typedef int  (*TsGetDerpOnlyFn)(void);
typedef const char *(*TsCurrentUserFn)(void);
typedef const char *(*TsGetHttpProxyFn)(void);

// ---------- C 回调桥接 ----------

static void KPTsLogCB(const char *msg) {
    if (msg) {
        [[KPLogger shared] logTscoreMessage:@(msg)];
    }
}

static void KPTsStateCB(int state) {
    [[KPLogger shared] logWithLevel:KPLogLevelInfo module:KPLogModuleTscore
                             format:@"[core 回调] state=%d", state];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:KPTsCoreStateChangedNotification
                                                            object:@(state)];
    });
}

@interface KPTsCore ()
@property (nonatomic, assign) void *handle;
@property (nonatomic, assign) BOOL coreInitialized;
@property (nonatomic, assign) TsInitFn fTsInit;
@property (nonatomic, assign) TsStartFn fTsStart;
@property (nonatomic, assign) TsStopFn fTsStop;
@property (nonatomic, assign) TsIsRunningFn fTsIsRunning;
@property (nonatomic, assign) TsLoginFn fTsLogin;
@property (nonatomic, assign) TsNeedsLoginFn fTsNeedsLogin;
@property (nonatomic, assign) TsLoginURLFn fTsLoginURL;
@property (nonatomic, assign) TsSetHttpProxyFn fTsSetHttpProxy;
@property (nonatomic, assign) TsSocks5AddrFn fTsSocks5Addr;
@property (nonatomic, assign) TsSocks5CredFn fTsSocks5Cred;
@property (nonatomic, assign) TsFreeStringFn fTsFreeString;
@property (nonatomic, assign) TsSetLogCallbackFn fTsSetLogCallback;
@property (nonatomic, assign) TsSetStateCallbackFn fTsSetStateCallback;
@property (nonatomic, assign) TsListExitNodesFn fTsListExitNodes;
@property (nonatomic, assign) TsGetExitNodeStatusFn fTsGetExitNodeStatus;
@property (nonatomic, assign) TsSuggestExitNodeFn fTsSuggestExitNode;
@property (nonatomic, assign) TsSetExitNodeFn fTsSetExitNode;
@property (nonatomic, assign) TsClearExitNodeFn fTsClearExitNode;
@property (nonatomic, assign) TsSetExitNodeAllowLANAccessFn fTsSetExitNodeAllowLANAccess;
@property (nonatomic, assign) TsPingFn fTsPing;
@property (nonatomic, assign) TsNetcheckFn fTsNetcheck;
@property (nonatomic, assign) TsDebugDERPRegionFn fTsDebugDERPRegion;
@property (nonatomic, assign) TsStatusDetailJSONFn fTsStatusDetailJSON;
@property (nonatomic, assign) TsGetPrefsJSONFn fTsGetPrefsJSON;
@property (nonatomic, assign) TsSetPrefsJSONFn fTsSetPrefsJSON;
@property (nonatomic, assign) TsSetHostnameFn fTsSetHostname;
@property (nonatomic, assign) TsSetRouteAllFn fTsSetRouteAll;
@property (nonatomic, assign) TsFileTargetsFn fTsFileTargets;
@property (nonatomic, assign) TsPushFileFn fTsPushFile;
@property (nonatomic, assign) TsWaitingFilesFn fTsWaitingFiles;
@property (nonatomic, assign) TsGetWaitingFileFn fTsGetWaitingFile;
@property (nonatomic, assign) TsDeleteWaitingFileFn fTsDeleteWaitingFile;
@property (nonatomic, assign) TsTailscaleIPsFn fTsTailscaleIPs;
@property (nonatomic, assign) TsWhoIsFn fTsWhoIs;
@property (nonatomic, assign) TsListPeersFn fTsListPeers;
@property (nonatomic, assign) TsStartLocalHTTPProxyFn fTsStartLocalHTTPProxy;
@property (nonatomic, assign) TsStopLocalHTTPProxyFn fTsStopLocalHTTPProxy;
@property (nonatomic, assign) TsVersionFn fTsVersion;
@property (nonatomic, assign) TsSetDerpOnlyFn fTsSetDerpOnly;
@property (nonatomic, assign) TsGetDerpOnlyFn fTsGetDerpOnly;
@property (nonatomic, assign) TsCurrentUserFn fTsCurrentUser;
@property (nonatomic, assign) TsGetHttpProxyFn fTsGetHttpProxy;
@property (nonatomic, assign) BOOL loaded;

- (NSArray<NSString *> *)symbolNames;
- (void)setSymbol:(void *)fn forName:(NSString *)name;
@end

@implementation KPTsCore

+ (instancetype)shared {
    static KPTsCore *instance = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[KPTsCore alloc] init];
    });
    return instance;
}

+ (dispatch_queue_t)coreQueue {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.lcproxy.tscore", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

- (NSString *)defaultBaseDirectory {
    return KPSharedRootDirectory(); // <LC Documents>，core 位于 <LC Documents>/KingProxy/TailscaleCore.bin
}

- (NSString *)baseDirectory {
    return _baseDirectory ?: [self defaultBaseDirectory];
}

- (NSString *)corePath {
    // 优先 Tweaks/ 副本（LC 强制签名后 dlopen 可通过），其次 KingProxy/ 源文件
    // 文件名带版本号（libTailscaleCore-v<tag>.dylib）→ 扫描取最新版本。
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *tweaksDir = [self.baseDirectory stringByAppendingPathComponent:@"Tweaks"];
    NSString *tweaksNewest = [self newestCoreInDirectory:tweaksDir];
    if (tweaksNewest && [fm fileExistsAtPath:tweaksNewest]) return tweaksNewest;
    NSString *kingDir = [self.baseDirectory stringByAppendingPathComponent:@"KingProxy"];
    NSString *kingNewest = [self newestCoreInDirectory:kingDir];
    if (kingNewest && [fm fileExistsAtPath:kingNewest]) return kingNewest;
    // 兼容旧固定名
    NSString *tweaksLegacy = [tweaksDir stringByAppendingPathComponent:@"libTailscaleCore.dylib"];
    if ([fm fileExistsAtPath:tweaksLegacy]) return tweaksLegacy;
    return [[kingDir stringByAppendingPathComponent:@"TailscaleCore.bin"] copy];
}

// 扫描目录内 libTailscaleCore-*.dylib（含 Tweaks/ 与 KingProxy/），返回版本最高者
- (NSString *)newestCoreInDirectory:(NSString *)dir {
    NSArray *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
    NSString *best = nil;
    NSArray *bestVer = nil;
    for (NSString *n in names) {
        if (![n hasPrefix:@"libTailscaleCore-"] || ![n hasSuffix:@".dylib"]) continue;
        // libTailscaleCore-v0.1.0.dylib → ["0","1","0"]
        NSString *stem = [n substringWithRange:NSMakeRange(@"libTailscaleCore-".length,
                                                           n.length - @"libTailscaleCore-".length - @".dylib".length)];
        if ([stem hasPrefix:@"v"]) stem = [stem substringFromIndex:1];
        NSArray *parts = [stem componentsSeparatedByString:@"."];
        NSMutableArray *nums = [NSMutableArray array];
        BOOL ok = YES;
        for (NSString *p in parts) {
            NSInteger v = [p integerValue];
            if (!p.length || [p integerValue] == 0 && ![@"0" isEqualToString:p]) { ok = NO; break; }
            [nums addObject:@(v)];
        }
        if (!ok) continue;
        if (!bestVer || [self compareVersion:nums vs:bestVer] == NSOrderedDescending) {
            best = [dir stringByAppendingPathComponent:n];
            bestVer = nums;
        }
    }
    return best;
}

- (NSComparisonResult)compareVersion:(NSArray *)a vs:(NSArray *)b {
    NSUInteger n = MAX(a.count, b.count);
    for (NSUInteger i = 0; i < n; i++) {
        NSInteger x = i < a.count ? [a[i] integerValue] : 0;
        NSInteger y = i < b.count ? [b[i] integerValue] : 0;
        if (x != y) return x > y ? NSOrderedDescending : NSOrderedAscending;
    }
    return NSOrderedSame;
}

// 实际 dlopen 的路径（与 corePath 一致，供日志显示）
- (NSString *)coreActualPath {
    return self.corePath;
}

- (NSString *)versionTxtPath {
    return [[self.baseDirectory stringByAppendingPathComponent:@"KingProxy"]
            stringByAppendingPathComponent:@"version.txt"];
}

- (BOOL)corePresent {
    return [[NSFileManager defaultManager] fileExistsAtPath:self.corePath];
}

// 防呆：用户若误把 core 放进 Tweaks/（LC 会当 tweak 加载导致报错），启动时给出明确警告
- (void)warnIfCoreMisplaced {
    NSString *tweaks = [[self.baseDirectory stringByAppendingPathComponent:@"Tweaks"]
                        stringByAppendingPathComponent:@"libTailscaleCore.dylib"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:tweaks]) {
        [[KPLogger shared] logWithLevel:KPLogLevelInfo module:KPLogModuleTscore
                                 format:@"Tweaks/libTailscaleCore.dylib 存在：将优先加载该副本（需 LC 已用证书签名，否则 dlopen 失败）"];
    }
}

- (void *)resolveSymbol:(const char *)name {
    if (!self.handle) return NULL;
    return dlsym(self.handle, name);
}

- (BOOL)loadCoreIfPresent {
    if (self.loaded) return YES;
    if (!self.corePresent) {
        [[KPLogger shared] stepCheckModule:KPLogModuleTscore name:@"加载 TailscaleCore"
                                       ok:NO format:@"文件不存在: %@", self.corePath];
        return NO;
    }
    void *h = dlopen(self.corePath.UTF8String, RTLD_NOW | RTLD_GLOBAL);
    if (!h) {
        const char *err = dlerror();
        [[KPLogger shared] stepCheckModule:KPLogModuleTscore name:@"dlopen TailscaleCore"
                                       ok:NO format:@"%@", err ? @(err) : @"unknown error"];
        return NO;
    }
    self.handle = h;
    self.loaded = YES;  // dlopen 成功即置位（web 端 /api/login 等依赖 loaded）

    // 逐个解析符号（缺失不阻断，降级处理）
    int missing = 0;
    for (NSString *name in self.symbolNames) {
        void *fn = dlsym(h, name.UTF8String);
        if (!fn) { missing++; continue; }
        [self setSymbol:fn forName:name];
    }

    if (self.fTsSetLogCallback) self.fTsSetLogCallback(KPTsLogCB);
    if (self.fTsSetStateCallback) self.fTsSetStateCallback(KPTsStateCB);

    NSString *ver = self.versionString;
    [[KPLogger shared] stepCheckModule:KPLogModuleTscore name:@"加载 TailscaleCore"
                                   ok:YES
                                format:@"dlopen OK 版本=%@ 缺失符号=%d", ver ?: @"(未知)", missing];
    if (missing > 0) {
        [[KPLogger shared] logWithLevel:KPLogLevelWarn module:KPLogModuleTscore
                                 format:@"%d 个符号缺失（旧版 core），相关功能降级", missing];
    }
    return YES;
}

- (void)setSymbol:(void *)fn forName:(NSString *)name {
    if ([name isEqualToString:@"TsInit"]) self.fTsInit = fn;
    else if ([name isEqualToString:@"TsStart"]) self.fTsStart = fn;
    else if ([name isEqualToString:@"TsStop"]) self.fTsStop = fn;
    else if ([name isEqualToString:@"TsIsRunning"]) self.fTsIsRunning = fn;
    else if ([name isEqualToString:@"TsLogin"]) self.fTsLogin = fn;
    else if ([name isEqualToString:@"TsNeedsLogin"]) self.fTsNeedsLogin = fn;
    else if ([name isEqualToString:@"TsLoginURL"]) self.fTsLoginURL = fn;
    else if ([name isEqualToString:@"TsSetHttpProxy"]) self.fTsSetHttpProxy = fn;
    else if ([name isEqualToString:@"TsSocks5Addr"]) self.fTsSocks5Addr = fn;
    else if ([name isEqualToString:@"TsSocks5Cred"]) self.fTsSocks5Cred = fn;
    else if ([name isEqualToString:@"TsFreeString"]) self.fTsFreeString = fn;
    else if ([name isEqualToString:@"TsSetLogCallback"]) self.fTsSetLogCallback = fn;
    else if ([name isEqualToString:@"TsSetStateCallback"]) self.fTsSetStateCallback = fn;
    else if ([name isEqualToString:@"TsListExitNodes"]) self.fTsListExitNodes = fn;
    else if ([name isEqualToString:@"TsGetExitNodeStatus"]) self.fTsGetExitNodeStatus = fn;
    else if ([name isEqualToString:@"TsSuggestExitNode"]) self.fTsSuggestExitNode = fn;
    else if ([name isEqualToString:@"TsSetExitNode"]) self.fTsSetExitNode = fn;
    else if ([name isEqualToString:@"TsClearExitNode"]) self.fTsClearExitNode = fn;
    else if ([name isEqualToString:@"TsSetExitNodeAllowLANAccess"]) self.fTsSetExitNodeAllowLANAccess = fn;
    else if ([name isEqualToString:@"TsPing"]) self.fTsPing = fn;
    else if ([name isEqualToString:@"TsNetcheck"]) self.fTsNetcheck = fn;
    else if ([name isEqualToString:@"TsDebugDERPRegion"]) self.fTsDebugDERPRegion = fn;
    else if ([name isEqualToString:@"TsStatusDetailJSON"]) self.fTsStatusDetailJSON = fn;
    else if ([name isEqualToString:@"TsGetPrefsJSON"]) self.fTsGetPrefsJSON = fn;
    else if ([name isEqualToString:@"TsSetPrefsJSON"]) self.fTsSetPrefsJSON = fn;
    else if ([name isEqualToString:@"TsSetHostname"]) self.fTsSetHostname = fn;
    else if ([name isEqualToString:@"TsSetRouteAll"]) self.fTsSetRouteAll = fn;
    else if ([name isEqualToString:@"TsFileTargets"]) self.fTsFileTargets = fn;
    else if ([name isEqualToString:@"TsPushFile"]) self.fTsPushFile = fn;
    else if ([name isEqualToString:@"TsWaitingFiles"]) self.fTsWaitingFiles = fn;
    else if ([name isEqualToString:@"TsGetWaitingFile"]) self.fTsGetWaitingFile = fn;
    else if ([name isEqualToString:@"TsDeleteWaitingFile"]) self.fTsDeleteWaitingFile = fn;
    else if ([name isEqualToString:@"TsTailscaleIPs"]) self.fTsTailscaleIPs = fn;
    else if ([name isEqualToString:@"TsWhoIs"]) self.fTsWhoIs = fn;
    else if ([name isEqualToString:@"TsListPeers"]) self.fTsListPeers = fn;
    else if ([name isEqualToString:@"TsStartLocalHTTPProxy"]) self.fTsStartLocalHTTPProxy = fn;
    else if ([name isEqualToString:@"TsStopLocalHTTPProxy"]) self.fTsStopLocalHTTPProxy = fn;
    else if ([name isEqualToString:@"TsVersion"]) self.fTsVersion = fn;
    else if ([name isEqualToString:@"TsSetDerpOnly"]) self.fTsSetDerpOnly = fn;
    else if ([name isEqualToString:@"TsGetDerpOnly"]) self.fTsGetDerpOnly = fn;
    else if ([name isEqualToString:@"TsCurrentUser"]) self.fTsCurrentUser = fn;
    else if ([name isEqualToString:@"TsGetHttpProxy"]) self.fTsGetHttpProxy = fn;
}

- (void)unload {
    if (self.handle) {
        dlclose(self.handle);
        self.handle = NULL;
        self.loaded = NO;
        self.coreInitialized = NO;
        [[KPLogger shared] stepCheckModule:KPLogModuleTscore name:@"卸载 core" ok:YES format:@""];
    }
}

#pragma mark - 字符串工具

- (NSString *)stringFromCTs:(const char *)p {
    if (!p) return nil;
    NSString *s = @(p);
    if (self.fTsFreeString) self.fTsFreeString(p);
    return s;
}

- (NSArray<NSString *> *)symbolNames {
    static NSArray *names = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = @[
            @"TsInit", @"TsStart", @"TsStop", @"TsIsRunning", @"TsLogin",
            @"TsNeedsLogin", @"TsLoginURL", @"TsSetHttpProxy", @"TsSocks5Addr", @"TsSocks5Cred",
            @"TsFreeString", @"TsSetLogCallback", @"TsSetStateCallback",
            @"TsListExitNodes", @"TsGetExitNodeStatus", @"TsSuggestExitNode",
            @"TsSetExitNode", @"TsClearExitNode", @"TsSetExitNodeAllowLANAccess",
            @"TsPing", @"TsNetcheck", @"TsDebugDERPRegion", @"TsStatusDetailJSON",
            @"TsGetPrefsJSON", @"TsSetPrefsJSON", @"TsSetHostname", @"TsSetRouteAll",
            @"TsFileTargets", @"TsPushFile", @"TsWaitingFiles", @"TsGetWaitingFile", @"TsDeleteWaitingFile",
            @"TsTailscaleIPs", @"TsWhoIs", @"TsListPeers",
            @"TsStartLocalHTTPProxy", @"TsStopLocalHTTPProxy",
            @"TsVersion", @"TsSetDerpOnly", @"TsGetDerpOnly", @"TsCurrentUser", @"TsGetHttpProxy",
        ];
    });
    return names;
}

- (void)loadCoreIfPresentStep {
    // 防呆：误放 Tweaks/ 的 core 给出明确警告
    [self warnIfCoreMisplaced];
    // 重新解析缺失符号（core 升级热加载场景可调用）
    if (!self.handle) return;
    int missing = 0;
    for (NSString *name in self.symbolNames) {
        void *fn = dlsym(self.handle, name.UTF8String);
        if (!fn) { missing++; continue; }
        [self setSymbol:fn forName:name];
    }
    [[KPLogger shared] logWithLevel:KPLogLevelInfo module:KPLogModuleTscore
                             format:@"符号重解析完成，缺失=%d", missing];
}

#pragma mark - 生命周期

- (int)initCoreWithDirectory:(NSString *)dir hostname:(NSString *)hostname {
    if (!self.fTsInit) return -1;
    int rc = self.fTsInit(dir.UTF8String, hostname.UTF8String);
    self.coreInitialized = (rc == 0);
    [[KPLogger shared] stepCheckModule:KPLogModuleTscore name:@"TsInit" ok:(rc == 0)
                                 format:@"rc=%d dir=%@ host=%@", rc, dir, hostname];
    return rc;
}

- (int)start {
    if (!self.fTsStart) return -1;
    int rc = self.fTsStart();
    return rc;
}

- (void)stop {
    if (self.fTsStop) self.fTsStop();
}

- (int)loginWithAuthKey:(NSString *)authKey {
    if (!self.fTsLogin) return -1;
    int rc = self.fTsLogin(authKey.UTF8String);
    [[KPLogger shared] stepCheckModule:KPLogModuleAuth name:@"TsLogin(AuthKey)" ok:(rc == 0)
                                 format:@"rc=%d", rc];
    return rc;
}

- (int)needsLogin {
    if (!self.fTsNeedsLogin) return 1;
    return self.fTsNeedsLogin();
}

- (NSString *)loginURL {
    if (!self.fTsLoginURL) {
        [[KPLogger shared] logWithLevel:KPLogLevelWarn module:KPLogModuleAuth
                                 format:@"[login] TsLoginURL 符号缺失"];
        return nil;
    }
    NSTimeInterval t0 = [NSDate timeIntervalSinceReferenceDate];
    const char *p = self.fTsLoginURL();
    NSTimeInterval dt = [NSDate timeIntervalSinceReferenceDate] - t0;
    NSString *s = p ? @(p) : @"";
    if (self.fTsFreeString) self.fTsFreeString(p);
    [[KPLogger shared] logWithLevel:KPLogLevelInfo module:KPLogModuleAuth
                             format:@"[login] TsLoginURL 返回=%@ 耗时=%.2fs", s.length ? s : @"(空)", dt];
    return s.length ? s : nil;
}

- (int)isRunning {
    if (!self.fTsIsRunning) return 0;
    return self.fTsIsRunning();
}

#pragma mark - 代理 / DERP-only

- (int)setHttpProxy:(NSString *)proxyURL {
    if (!self.fTsSetHttpProxy) return -1;
    int rc = self.fTsSetHttpProxy(proxyURL ? proxyURL.UTF8String : NULL);
    [[KPLogger shared] stepCheckModule:KPLogModuleTscore name:@"TsSetHttpProxy" ok:(rc == 0)
                                 format:@"proxy=%@ rc=%d", proxyURL ?: @"(清空)", rc];
    return rc;
}

- (NSString *)getHttpProxy {
    if (!self.fTsGetHttpProxy) return nil;
    return [self stringFromCTs:self.fTsGetHttpProxy()];
}

- (int)setDerpOnly:(BOOL)enable {
    if (!self.fTsSetDerpOnly) {
        [[KPLogger shared] stepCheckModule:KPLogModuleTscore name:@"TsSetDerpOnly" ok:NO
                                     format:@"符号缺失（core 版本过旧），DERP-only 不可用"];
        return -1;
    }
    int rc = self.fTsSetDerpOnly(enable ? 1 : 0);
    [[KPLogger shared] stepCheckModule:KPLogModuleTscore name:@"TsSetDerpOnly" ok:(rc == 0)
                                 format:@"enable=%d rc=%d（生效后后端重启，断连数秒）", enable, rc];
    return rc;
}

- (int)getDerpOnly {
    if (!self.fTsGetDerpOnly) return 0;
    return self.fTsGetDerpOnly();
}

#pragma mark - 节点信息

- (NSString *)socks5Addr {
    if (!self.fTsSocks5Addr) return nil;
    return [self stringFromCTs:self.fTsSocks5Addr()];
}

- (NSString *)socks5Cred {
    if (!self.fTsSocks5Cred) return nil;
    return [self stringFromCTs:self.fTsSocks5Cred()];
}

- (NSString *)currentUser {
    if (!self.fTsCurrentUser) return nil;
    return [self stringFromCTs:self.fTsCurrentUser()];
}

- (NSString *)versionString {
    if (!self.fTsVersion) return nil;
    return [self stringFromCTs:self.fTsVersion()];
}

- (NSString *)coreVersionCached {
    if (self.loaded && self.fTsVersion) {
        NSString *v = [self versionString];
        if (v.length) return v;
    }
    NSString *vt = [NSString stringWithContentsOfFile:self.versionTxtPath encoding:NSUTF8StringEncoding error:nil];
    return [vt stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (NSString *)tailscaleIPsJSON {
    if (!self.fTsTailscaleIPs) return nil;
    return [self stringFromCTs:self.fTsTailscaleIPs()];
}

- (NSString *)listPeersJSON {
    if (!self.fTsListPeers) return nil;
    return [self stringFromCTs:self.fTsListPeers()];
}

- (NSString *)whoIs:(NSString *)ipOrAddr {
    if (!self.fTsWhoIs) return nil;
    return [self stringFromCTs:self.fTsWhoIs(ipOrAddr.UTF8String)];
}

#pragma mark - 控制

- (NSString *)listExitNodesJSON {
    if (!self.fTsListExitNodes) return nil;
    return [self stringFromCTs:self.fTsListExitNodes()];
}

- (NSString *)getExitNodeStatusJSON {
    if (!self.fTsGetExitNodeStatus) return nil;
    return [self stringFromCTs:self.fTsGetExitNodeStatus()];
}

- (NSString *)suggestExitNodeJSON {
    if (!self.fTsSuggestExitNode) return nil;
    return [self stringFromCTs:self.fTsSuggestExitNode()];
}

- (int)setExitNode:(NSString *)nameOrIP {
    if (!self.fTsSetExitNode) return -1;
    int rc = self.fTsSetExitNode(nameOrIP.UTF8String);
    [[KPLogger shared] stepCheckModule:KPLogModuleTscore name:@"设置出口节点" ok:(rc == 0)
                                 format:@"node=%@ rc=%d", nameOrIP, rc];
    return rc;
}

- (int)clearExitNode {
    if (!self.fTsClearExitNode) return -1;
    return self.fTsClearExitNode();
}

- (int)setExitNodeAllowLANAccess:(BOOL)enable {
    if (!self.fTsSetExitNodeAllowLANAccess) return -1;
    return self.fTsSetExitNodeAllowLANAccess(enable ? 1 : 0);
}

- (NSString *)pingIP:(NSString *)ip type:(NSString *)type {
    if (!self.fTsPing) return nil;
    return [self stringFromCTs:self.fTsPing(ip.UTF8String, type.UTF8String)];
}

- (NSString *)netcheckJSON {
    if (!self.fTsNetcheck) return nil;
    return [self stringFromCTs:self.fTsNetcheck()];
}

- (NSString *)debugDERPRegion:(NSString *)code {
    if (!self.fTsDebugDERPRegion) return nil;
    return [self stringFromCTs:self.fTsDebugDERPRegion(code.UTF8String)];
}

- (NSString *)statusDetailJSON {
    if (!self.fTsStatusDetailJSON) return nil;
    return [self stringFromCTs:self.fTsStatusDetailJSON()];
}

- (NSString *)getPrefsJSON {
    if (!self.fTsGetPrefsJSON) return nil;
    return [self stringFromCTs:self.fTsGetPrefsJSON()];
}

- (int)setPrefsJSON:(NSString *)prefsJSON {
    if (!self.fTsSetPrefsJSON) return -1;
    return self.fTsSetPrefsJSON(prefsJSON.UTF8String);
}

- (int)setHostname:(NSString *)name {
    if (!self.fTsSetHostname) return -1;
    return self.fTsSetHostname(name.UTF8String);
}

- (int)setRouteAll:(BOOL)enable {
    if (!self.fTsSetRouteAll) return -1;
    return self.fTsSetRouteAll(enable ? 1 : 0);
}

@end
