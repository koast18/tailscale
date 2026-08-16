//
//  KPKingForwarder.m
//  LCProxyTweak
//

#import "KPKingForwarder.h"
#import "KPKIngCore.h"
#import "KPLogger.h"
#import "KPSharedPaths.h"

int const KPKingForwarderDefaultPort = 18080;

static int const KPFetchAttempts  = 3;    // 取号链整体重试次数
static int const KPFetchBackoffMs = 300;  // 重试间隔
static int const KPFetchTimeoutMs = 10000;

NSString *KPMaskedLoginHost(NSString *guid, NSString *token) {
    NSString *g = KPMaskGUID(guid ?: @"");
    NSString *t = KPMaskSecret(token ?: @"");
    return [NSString stringWithFormat:@"%@.%@.iikira.com.token", g, t];
}

@interface KPKingForwarder ()
@property (nonatomic, assign) kp_forwarder *forwarder;
@property (nonatomic, strong) dispatch_queue_t workQueue;
@property (nonatomic, copy) NSString *guid;
@property (nonatomic, copy) NSString *token;
@property (nonatomic, copy) NSDictionary *config;
@property (nonatomic, strong) NSDate *lastRefresh;
@property (nonatomic, assign) BOOL lastProbeOk;
@property (nonatomic, assign) BOOL lastProbeRan;
@property (nonatomic, assign) BOOL lastLoginOk;
@property (nonatomic, assign) BOOL lastFetchOk;
@property (nonatomic, copy) NSString *lastRefreshSource; // boot / manual / event
@property (nonatomic, copy) NSString *lastFetchRoute;           // proxy / direct / override
@property (nonatomic, assign) NSInteger refreshCount;
@property (nonatomic, strong) NSLock *stateLock;

- (BOOL)refreshCredentialsSyncWithTrigger:(NSString *)trigger;
@end

// 转发器事件驱动刷新回调（上游非 200/连接失败时由 C 层调用；成功返回 0 以便重试一次）
static int KPForwarderRefreshHook(void *ctx) {
    KPKingForwarder *fw = (__bridge KPKingForwarder *)ctx;
    __block int ok = -1;
    dispatch_sync(fw.workQueue, ^{ // 需串行化，避免与手动刷新并发
        ok = [fw refreshCredentialsSyncWithTrigger:@"event"] ? 0 : -1;
    });
    return ok;
}

@implementation KPKingForwarder

+ (instancetype)shared {
    static KPKingForwarder *instance = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[KPKingForwarder alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _workQueue = dispatch_queue_create("lcproxy.king", DISPATCH_QUEUE_SERIAL);
        _stateLock = [[NSLock alloc] init];
        _forwarder = NULL;
        _lastRefreshSource = @"none";
        _lastFetchRoute = @"";
        _refreshCount = 0;
    }
    return self;
}

- (NSString *)defaultBaseDirectory {
    return KPSharedRootDirectory();
}

- (NSString *)baseDirectory {
    return _baseDirectory ?: [self defaultBaseDirectory];
}

- (NSString *)refreshURLFromConfig {
    id v = self.config[@"refreshURL"];
    return [v isKindOfClass:[NSString class]] ? v : @"http://kc.iikira.com/kingcard";
}

- (NSString *)proxyHostFromConfig {
    id v = self.config[@"proxyHost"];
    return [v isKindOfClass:[NSString class]] ? v : @"157.148.54.212";
}

- (int)proxyPortFromConfig {
    id v = self.config[@"proxyPort"];
    return [v isKindOfClass:[NSNumber class]] ? [v intValue] : 8091;
}

static void KPKIngDebugLog(const char *line) {
    if (!line || !line[0]) return;
    [[KPLogger shared] logWithLevel:KPLogLevelDebug module:KPLogModuleKing
                             format:@"[C] %@", [NSString stringWithUTF8String:line]];
}

- (void)startWithConfig:(NSDictionary *)kingConfig {
    // 注册 C 层调试日志（KPKIngCore 每步网络操作输出到这里）
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        kp_set_debug_logger(KPKIngDebugLog);
    });
    self.config = kingConfig ?: @{};
    dispatch_async(self.workQueue, ^{
        [self startSync];
    });
}

- (void)startSync {
    if (self.forwarder && kp_forwarder_is_running(self.forwarder)) {
        [[KPLogger shared] logWithLevel:KPLogLevelInfo module:KPLogModuleKing
                                 format:@"转发器已在运行，跳过启动"];
        return;
    }
    kp_forwarder *fw = kp_forwarder_new("127.0.0.1", KPKingForwarderDefaultPort,
                                        [self.proxyHostFromConfig UTF8String],
                                        [self proxyPortFromConfig]);
    if (!fw) {
        [[KPLogger shared] logWithLevel:KPLogLevelError module:KPLogModuleKing format:@"转发器创建失败"];
        return;
    }
    // 事件驱动刷新钩子：上游非 200/连接失败 → 刷新凭证 → 重试一次
    kp_forwarder_set_refresh_hook(fw, KPForwarderRefreshHook, (__bridge void *)self);

    if (kp_forwarder_start(fw) != 0) {
        [[KPLogger shared] logWithLevel:KPLogLevelError module:KPLogModuleKing
                                 format:@"转发器启动失败（端口 %d 被占用？）", KPKingForwarderDefaultPort];
        kp_forwarder_free(fw);
        self.forwarder = NULL;
        return;
    }
    self.forwarder = fw;
    [[KPLogger shared] logWithLevel:KPLogLevelInfo module:KPLogModuleKing
                             format:@"转发器已启动 127.0.0.1:%d → %@:%d（事件驱动刷新已启用）",
                             KPKingForwarderDefaultPort, self.proxyHostFromConfig, [self proxyPortFromConfig]];

    // 启动即取号+登录+验证一次（无定时器）
    if (!self.offlineMode) {
        [self refreshCredentialsSyncWithTrigger:@"boot"];
    }
}

- (void)stop {
    dispatch_sync(self.workQueue, ^{
        if (self.forwarder) {
            kp_forwarder_free(self.forwarder);
            self.forwarder = NULL;
            [[KPLogger shared] logWithLevel:KPLogLevelInfo module:KPLogModuleKing format:@"转发器已停止"];
        }
    });
}

- (BOOL)isRunning {
    return self.forwarder != NULL && kp_forwarder_is_running(self.forwarder);
}

- (void)refreshCredentialsWithCompletion:(void (^)(BOOL))completion {
    dispatch_async(self.workQueue, ^{
        BOOL ok = [self refreshCredentialsSyncWithTrigger:@"manual"];
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(ok); });
        }
    });
}

// 必须在 workQueue 上调用；返回取号是否成功
- (BOOL)refreshCredentialsSync {
    return [self refreshCredentialsSyncWithTrigger:@"manual"];
}

// 必须在 workQueue 上调用；trigger: boot/manual/event
- (BOOL)refreshCredentialsSyncWithTrigger:(NSString *)trigger {
    if (self.offlineMode) return NO;

    NSString *guidOverride = [self.config[@"guidOverride"] isKindOfClass:[NSString class]] ? self.config[@"guidOverride"] : nil;
    NSString *tokenOverride = [self.config[@"tokenOverride"] isKindOfClass:[NSString class]] ? self.config[@"tokenOverride"] : nil;

    char guid[128] = {0}, token[128] = {0};
    BOOL fetched = NO;
    NSString *fetchRoute = @"";
    if (guidOverride.length && tokenOverride.length) {
        [[KPLogger shared] logWithLevel:KPLogLevelInfo module:KPLogModuleKing
                                 format:@"使用手动凭证覆盖 guid=%@ token=%@",
                                 KPMaskGUID(guidOverride), KPMaskSecret(tokenOverride)];
        [guidOverride getCString:guid maxLength:sizeof(guid) encoding:NSUTF8StringEncoding];
        [tokenOverride getCString:token maxLength:sizeof(token) encoding:NSUTF8StringEncoding];
        fetched = YES;
        fetchRoute = @"override";
    } else {
        char route[16] = {0};
        kp_fetch_diag diag;
        kp_fetch_diag_init(&diag);
        int rc = kp_fetch_guid_token_best([self.refreshURLFromConfig UTF8String],
                                          [self.proxyHostFromConfig UTF8String],
                                          [self proxyPortFromConfig],
                                          self.guid.length ? self.guid.UTF8String : NULL,
                                          self.token.length ? self.token.UTF8String : NULL,
                                          KPFetchAttempts, KPFetchBackoffMs, KPFetchTimeoutMs,
                                          guid, sizeof(guid), token, sizeof(token),
                                          &diag, route, sizeof(route));
        if (rc == 0) {
            fetched = YES;
            fetchRoute = @(route);
            [[KPLogger shared] logWithLevel:KPLogLevelInfo module:KPLogModuleKing
                                     format:@"取号成功 触发=%@ 路由=%@ guid=%@", trigger, fetchRoute, KPMaskGUID(@(guid))];
        } else {
            // 详细诊断：状态行 + Content-Encoding + 响应体前 512B（脱敏）
            [[KPLogger shared] logWithLevel:KPLogLevelWarn module:KPLogModuleKing
                                     format:@"取号失败 rc=%d 触发=%@ url=%@", rc, trigger, self.refreshURLFromConfig];
            if (diag.status_line[0]) {
                const char *reason = "?";
                switch (diag.parse_fail_reason) {
                    case 0: reason = "无"; break;
                    case 1: reason = "无逗号且非JSON"; break;
                    case 2: reason = "段为空"; break;
                    case 3: reason = "段超容量"; break;
                    case 4: reason = "含非法字符"; break;
                    case 5: reason = "响应结构异常"; break;
                    default: break;
                }
                NSString *loc = diag.location[0] ? [NSString stringWithFormat:@" location=%@", KPMaskLongRuns(@(diag.location))] : @"";
                NSString *extra = @"";
                if (diag.parse_fail_reason) {
                    extra = [NSString stringWithFormat:@" fail_reason=%s(%d) pos=%d struct=%@",
                             reason, diag.parse_fail_reason, diag.parse_fail_pos,
                             @(diag.body_struct)];
                }
                [[KPLogger shared] logWithLevel:KPLogLevelWarn module:KPLogModuleKing
                                         format:@"取号诊断 status=%@ encoding=%@ bodylen=%u body=%@%@%@",
                                         @(diag.status_line),
                                         @(diag.content_encoding),
                                         diag.body_len,
                                         KPMaskLongRuns(@(diag.body_head)),
                                         loc, extra];
            }
        }
    }

    if (fetched && self.forwarder) {
        kp_forwarder_set_creds(self.forwarder, guid, token);
    }

    // 登录激活（经上游代理绝对 URI 直发，与 boxjs 一致；网关本地识别魔改域名）
    if (fetched) {
        char loginHost[256] = {0};
        if (kp_build_login_host(guid, token, loginHost, sizeof(loginHost)) == 0) {
            char diagStatus[160] = {0};
            int rc = kp_login_via_proxy([self.proxyHostFromConfig UTF8String],
                                        [self proxyPortFromConfig], loginHost,
                                        guid, token, KPFetchTimeoutMs,
                                        diagStatus, sizeof(diagStatus));
            [self.stateLock lock];
            self.lastLoginOk = (rc == 0);
            [self.stateLock unlock];
            // 安全：loginHost 含完整 GUID+TOKEN，绝不直接落日志；用脱敏版本
            [self logLoginAttemptWithGuid:@(guid) token:@(token) rc:rc];
            if (rc != 0 && diagStatus[0]) {
                [[KPLogger shared] logWithLevel:KPLogLevelWarn module:KPLogModuleKing
                                         format:@"登录激活诊断 status=%@", KPMaskLongRuns(@(diagStatus))];
            }
        }
    }

    [self.stateLock lock];
    self.guid = @(guid);
    self.token = @(token);
    self.lastRefresh = [NSDate date];
    self.lastFetchOk = fetched;
    self.refreshCount += 1;
    self.lastRefreshSource = trigger;
    self.lastFetchRoute = fetchRoute;
    [self.stateLock unlock];

    // 取号成功才探活验证链路；失败不探活（无意义）
    if (fetched) {
        [self probeSync];
    } else {
        [[KPLogger shared] logWithLevel:KPLogLevelInfo module:KPLogModuleKing
                                 format:@"取号未成功，跳过探活（待转发器事件驱动重试）"];
    }
    return fetched;
}

// 必须在 workQueue 上调用
- (void)probeSync {
    if (self.offlineMode) return;
    char guid[128] = {0}, token[128] = {0};
    [self.stateLock lock];
    if (self.guid.length) [self.guid getCString:guid maxLength:sizeof(guid) encoding:NSUTF8StringEncoding];
    if (self.token.length) [self.token getCString:token maxLength:sizeof(token) encoding:NSUTF8StringEncoding];
    [self.stateLock unlock];
    if (guid[0] == '\0' || token[0] == '\0') return;
    int ok = kp_probe_generate204([self.proxyHostFromConfig UTF8String],
                                  [self proxyPortFromConfig], guid, token, 8000);
    [self.stateLock lock];
    self.lastProbeOk = (ok == 1);
    self.lastProbeRan = YES;
    [self.stateLock unlock];
    [[KPLogger shared] logWithLevel:ok ? KPLogLevelInfo : KPLogLevelWarn
                             module:KPLogModuleKing
                             format:@"探活 generate_204 -> %@", ok ? @"OK" : @"FAIL"];
}

- (void)logLoginAttemptWithGuid:(NSString *)guid token:(NSString *)token rc:(int)rc {
    // 登录域名由完整 guid+token 拼接，落日志前必须脱敏
    [[KPLogger shared] logWithLevel:rc == 0 ? KPLogLevelInfo : KPLogLevelWarn
                             module:KPLogModuleKing
                             format:@"免流登录激活 %@ rc=%d",
                             KPMaskedLoginHost(guid, token), rc];
}

- (NSDictionary *)statusDictionary {
    [self.stateLock lock];
    NSString *guidMasked = KPMaskGUID(self.guid);
    NSDate *lastRefresh = self.lastRefresh;
    BOOL probeOk = self.lastProbeOk;
    BOOL probeRan = self.lastProbeRan;
    BOOL loginOk = self.lastLoginOk;
    BOOL fetchOk = self.lastFetchOk;
    NSString *source = self.lastRefreshSource;
    NSString *route = self.lastFetchRoute;
    NSInteger count = self.refreshCount;
    [self.stateLock unlock];

    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"enabled"] = @(self.isRunning);
    d[@"running"] = @(self.isRunning);
    d[@"port"] = @(KPKingForwarderDefaultPort);
    d[@"guidMasked"] = guidMasked.length ? guidMasked : @"(none)";
    d[@"lastRefresh"] = lastRefresh ? [NSISO8601DateFormatter stringFromDate:lastRefresh timeZone:[NSTimeZone localTimeZone] formatOptions:NSISO8601DateFormatWithInternetDateTime] : @"(never)";
    d[@"lastFetchOk"] = @(fetchOk);
    d[@"lastLoginOk"] = @(loginOk);
    d[@"probeRan"] = @(probeRan);
    d[@"probeOk"] = @(probeOk);
    d[@"lastRefreshSource"] = source ?: @"none";
    d[@"lastFetchRoute"] = route ?: @"";
    d[@"refreshCount"] = @(count);
    d[@"refreshURL"] = self.refreshURLFromConfig;
    d[@"upstream"] = [NSString stringWithFormat:@"%@:%d", self.proxyHostFromConfig, [self proxyPortFromConfig]];
    return d;
}

@end
