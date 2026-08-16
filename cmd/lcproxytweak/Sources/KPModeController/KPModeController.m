//
//  KPModeController.m
//  LCProxyTweak
//

#import "KPModeController.h"
#import "KPLogger.h"
#import "KPTsCore.h"
#import "KPKingForwarder.h"
#import "KPConfig.h"

NSString *KPModeName(KPMode mode) {
    switch (mode) {
        case KPModeA: return @"A(tailscale+免流)";
        case KPModeB: return @"B(tailscale)";
        case KPModeC: return @"C(纯免流)";
        case KPModeD: return @"D(全关)";
    }
    return @"?";
}

static NSString *const KPHookProxyKeyKind = @"kind";
static NSString *const KPHookProxyKeyHost = @"host";
static NSString *const KPHookProxyKeyPort = @"port";
static NSString *const KPHookProxyKeyUser = @"user";
static NSString *const KPHookProxyKeyPass = @"pass";

@interface KPModeController ()
@property (nonatomic, assign) KPMode mode;
@property (nonatomic, copy, nullable) NSDictionary *proxy;
@property (nonatomic, copy) NSString *lastSocks5Addr;
@property (nonatomic, copy) NSString *lastSocks5Cred;
@property (nonatomic, strong) NSLock *lock;
@end

@implementation KPModeController

+ (instancetype)shared {
    static KPModeController *instance = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[KPModeController alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _mode = KPModeD;
        _lock = [[NSLock alloc] init];
        // 订阅 core state 回调：引擎就绪/重启后 SOCKS5 端口变化 → 重新读取并更新 hook
        __weak typeof(self) weakSelf = self;
        [[NSNotificationCenter defaultCenter] addObserverForName:KPTsCoreStateChangedNotification
                                                          object:nil queue:nil
                                                      usingBlock:^(NSNotification *note) {
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            KPTsCore *core = [KPTsCore shared];
            if (!core.coreInitialized) return;
            NSString *addr = [core socks5Addr];
            if (addr.length) {
                NSString *cred = [core socks5Cred] ?: @"";
                [strongSelf onSocks5ChangedToAddr:addr cred:cred];
                [[KPLogger shared] logWithLevel:KPLogLevelInfo module:KPLogModuleHook
                                         format:@"state 回调：SOCKS5 地址更新 → %@", addr];
            }
        }];
    }
    return self;
}

- (KPMode)currentMode { return self.mode; }
- (NSDictionary *)desiredProxy { return self.proxy; }

- (KPMode)computeModeWithConfig:(NSDictionary *)config {
    BOOL ts = [config[@"tailscale"][@"enabled"] boolValue];
    BOOL king = [config[@"king"][@"enabled"] boolValue];
    if (ts && king) return KPModeA;
    if (ts && !king) return KPModeB;
    if (!ts && king) return KPModeC;
    return KPModeD;
}

- (void)applyConfig:(NSDictionary *)config {
    KPMode newMode = [self computeModeWithConfig:config];
    BOOL ts = [config[@"tailscale"][@"enabled"] boolValue];
    BOOL king = [config[@"king"][@"enabled"] boolValue];

    [self.lock lock];
    BOOL changed = (newMode != self.mode);
    KPMode oldMode = self.mode;
    self.mode = newMode;
    [self.lock unlock];

    [[KPLogger shared] stepCheckModule:KPLogModuleMode
                                  name:@"模式计算"
                                    ok:YES
                                format:@"tailscale=%@ 免流=%@ → 模式%@", @(ts), @(king), KPModeName(newMode)];
    if (changed) {
        [[KPLogger shared] logWithLevel:KPLogLevelInfo module:KPLogModuleMode
                                 format:@"模式切换 %@ → %@", KPModeName(oldMode), KPModeName(newMode)];
    }

    // tailscale 侧：core 生命周期 + 代理/derp 联动
    if (ts) {
        BOOL loaded = [[KPTsCore shared] loadCoreIfPresent];
        [[KPLogger shared] stepCheckModule:KPLogModuleTscore name:@"加载 TailscaleCore"
                                       ok:loaded format:@"文件存在=%d", [[KPTsCore shared] corePresent]];
        if (loaded) {
            NSString *dir = [[[KPTsCore shared] baseDirectory] stringByAppendingPathComponent:@"KingProxy"];
            NSString *hostname = [config[@"tailscale"][@"hostname"] isKindOfClass:[NSString class]]
                ? config[@"tailscale"][@"hostname"] : @"lcproxy";
            BOOL doKing = king;
            // TsInit/TsStart 首次启动 Go runtime + 可能同步连接控制面，耗时不可控：
            // 移到后台队列，避免阻塞主线程导致黑屏。联动随其后同一队列顺序执行。
            dispatch_async([KPTsCore coreQueue], ^{
                [[KPLogger shared] logWithLevel:KPLogLevelInfo module:KPLogModuleTscore
                                         format:@"TsInit 开始(后台) dir=%@", dir];
                // 超时告警：20s 未完成则标记 tscore 侧问题（不阻塞本队列后续任务）
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)),
                               [KPTsCore coreQueue], ^{
                    if (![[KPTsCore shared] coreInitialized]) {
                        [[KPLogger shared] logWithLevel:KPLogLevelError module:KPLogModuleTscore
                                                 format:@"TsInit 超时(>20s)未完成：tscore 引擎初始化卡住（属 tscore 侧问题，非本 tweak）。请检查 tscore 的 TsInit 实现是否阻塞在网络/状态文件上"];
                    }
                });
                int rc = [[KPTsCore shared] initCoreWithDirectory:dir hostname:hostname];
                int rc2 = [[KPTsCore shared] start];
                [[KPLogger shared] stepCheckModule:KPLogModuleTscore name:@"TsStart" ok:(rc2 == 0)
                                             format:@"rc=%d", rc2];
                if (doKing) {
                    int rc3 = [[KPTsCore shared] setHttpProxy:@"http://127.0.0.1:18080"];
                    int rc4 = [[KPTsCore shared] setDerpOnly:YES];
                    [[KPLogger shared] stepCheckModule:KPLogModuleMode name:@"免流联动(HTTPS_PROXY+DERP-only)"
                                                   ok:(rc3 == 0 && rc4 == 0)
                                                format:@"setHttpProxy rc=%d setDerpOnly rc=%d", rc3, rc4];
                } else {
                    int rc3 = [[KPTsCore shared] setHttpProxy:nil];
                    int rc4 = [[KPTsCore shared] setDerpOnly:NO];
                    [[KPLogger shared] stepCheckModule:KPLogModuleMode name:@"取消免流联动"
                                                   ok:(rc3 == 0 && rc4 == 0)
                                                format:@"clearHttpProxy rc=%d setDerpOnly(0) rc=%d", rc3, rc4];
                }
            });
        }
    } else {
        // unload 也走 coreQueue 串行：避免与后台 TsInit/TsStart 竞争（正在运行的 dylib 被 dlclose 会闪退）
        dispatch_async([KPTsCore coreQueue], ^{
            [[KPTsCore shared] unload];
            [[KPLogger shared] stepCheckModule:KPLogModuleTscore name:@"core 卸载(模式C/D不加载)"
                                           ok:YES format:@""];
        });
        [[KPLogger shared] logWithLevel:KPLogLevelInfo module:KPLogModuleTscore
                                 format:@"core 卸载已入队(模式C/D不加载)"];
    }

    // king 侧：转发器启停（启动为异步，成功与否由 KPKingForwarder 内部日志确认）
    if (king) {
        [[KPKingForwarder shared] startWithConfig:config[@"king"]];
    } else {
        [[KPKingForwarder shared] stop];
        [[KPLogger shared] stepCheckModule:KPLogModuleKing name:@"停止 king 转发器" ok:YES format:@""];
    }

    // 期望 hook 代理
    NSDictionary *proxy = [self computeDesiredProxyForMode:newMode];
    [self.lock lock];
    BOOL proxyChanged = !self.proxy || ![self.proxy isEqualToDictionary:proxy];
    self.proxy = proxy;
    [self.lock unlock];
    if (proxyChanged) {
        [[KPLogger shared] logWithLevel:KPLogLevelInfo module:KPLogModuleHook
                                 format:@"期望代理更新: %@", proxy];
        [[KPLogger shared] stepCheckModule:KPLogModuleHook name:@"hook 代理指向"
                                       ok:YES format:@"%@", [self describeProxy:proxy]];
        id delegate = self.delegate;
        if (delegate && [delegate respondsToSelector:@selector(modeController:desiredProxyDidChange:)]) {
            [delegate modeController:self desiredProxyDidChange:proxy];
        }
    }
}

- (NSDictionary *)computeDesiredProxyForMode:(KPMode)mode {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    switch (mode) {
        case KPModeA:
        case KPModeB: {
            // 优先使用最近一次 SOCKS5 变更事件缓存的地址；否则用 TsCore 当前值（仅 core 已初始化后）
            NSString *addr = nil;
            NSString *cred = nil;
            [self.lock lock];
            if (self.lastSocks5Addr.length) {
                addr = self.lastSocks5Addr;
                cred = self.lastSocks5Cred;
            }
            [self.lock unlock];
            if (!addr.length && [[KPTsCore shared] coreInitialized]) addr = [[KPTsCore shared] socks5Addr];
            if (!cred.length && [[KPTsCore shared] coreInitialized]) cred = [[KPTsCore shared] socks5Cred];
            if (!addr.length) {
                // SOCKS5 未就绪（tscore 初始化未完成/未提供地址）：不 hook，避免系统流量指向死端口黑洞
                d[KPHookProxyKeyKind] = @(KPProxyKindNone);
                [[KPLogger shared] logWithLevel:KPLogLevelWarn module:KPLogModuleMode
                                         format:@"SOCKS5 未就绪（tscore 初始化未完成），暂不设置系统代理，避免流量黑洞"];
                break;
            }
            NSString *host = @"127.0.0.1";
            int port = 19091;
            if (addr.length) {
                NSArray *parts = [addr componentsSeparatedByString:@":"];
                if (parts.count == 2) {
                    host = parts[0];
                    port = [parts[1] intValue];
                }
            }
            d[KPHookProxyKeyKind] = @(KPProxyKindSOCKS5);
            d[KPHookProxyKeyHost] = host;
            d[KPHookProxyKeyPort] = @(port);
            if (cred.length) {
                NSArray *parts = [cred componentsSeparatedByString:@":"];
                if (parts.count == 2) {
                    d[KPHookProxyKeyUser] = parts[0];
                    d[KPHookProxyKeyPass] = parts[1];
                }
            }
            break;
        }
        case KPModeC:
            d[KPHookProxyKeyKind] = @(KPProxyKindHTTP);
            d[KPHookProxyKeyHost] = @"127.0.0.1";
            d[KPHookProxyKeyPort] = @(KPKingForwarderDefaultPort);
            break;
        case KPModeD:
        default:
            d[KPHookProxyKeyKind] = @(KPProxyKindNone);
            break;
    }
    return d;
}

- (NSString *)describeProxy:(NSDictionary *)proxy {
    NSNumber *kindNum = proxy[KPHookProxyKeyKind];
    KPProxyKind kind = kindNum ? (KPProxyKind)[kindNum integerValue] : KPProxyKindNone;
    switch (kind) {
        case KPProxyKindSOCKS5:
            return [NSString stringWithFormat:@"SOCKS5 %@:%@ (user=%@ pass=%@)",
                    proxy[KPHookProxyKeyHost], proxy[KPHookProxyKeyPort],
                    proxy[KPHookProxyKeyUser] ?: @"-",
                    KPMaskSecret(proxy[KPHookProxyKeyPass] ?: @"")];
        case KPProxyKindHTTP:
            return [NSString stringWithFormat:@"HTTP %@:%@",
                    proxy[KPHookProxyKeyHost], proxy[KPHookProxyKeyPort]];
        default:
            return @"none（不 hook）";
    }
}

- (void)onTsStateChanged:(int)state {
    [[KPLogger shared] logWithLevel:KPLogLevelInfo module:KPLogModuleTscore
                             format:@"state 回调 -> %d", state];
    if (state == 2) {
        NSString *addr = [[KPTsCore shared] socks5Addr];
        NSString *cred = [[KPTsCore shared] socks5Cred];
        [self onSocks5ChangedToAddr:addr cred:cred];
    }
}

- (void)onSocks5ChangedToAddr:(NSString *)addr cred:(NSString *)cred {
    if (!addr.length) return;
    [self.lock lock];
    BOOL changed = (![self.lastSocks5Addr isEqualToString:addr] || ![self.lastSocks5Cred isEqualToString:cred]);
    self.lastSocks5Addr = addr;
    self.lastSocks5Cred = cred;
    [self.lock unlock];
    [[KPLogger shared] stepCheckModule:KPLogModuleTscore name:@"SOCKS5 地址更新"
                                   ok:changed format:@"addr=%@ cred=%@", addr, KPMaskSecret(cred)];
    if (changed) {
        [[NSNotificationCenter defaultCenter] postNotificationName:KPTsCoreSocks5ChangedNotification
                                                            object:self
                                                          userInfo:@{@"addr": addr ?: @"", @"cred": cred ?: @""}];
        // 重新计算期望代理并上报
        KPMode m = self.currentMode;
        NSDictionary *proxy = [self computeDesiredProxyForMode:m];
        [self.lock lock];
        self.proxy = proxy;
        [self.lock unlock];
        [[KPLogger shared] logWithLevel:KPLogLevelInfo module:KPLogModuleHook
                                 format:@"期望代理更新(SOCKS5 变化): %@", [self describeProxy:proxy]];
        id delegate = self.delegate;
        if (delegate && [delegate respondsToSelector:@selector(modeController:desiredProxyDidChange:)]) {
            [delegate modeController:self desiredProxyDidChange:proxy];
        }
    }
}

@end
