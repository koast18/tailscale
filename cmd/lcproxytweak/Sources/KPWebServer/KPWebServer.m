//
//  KPWebServer.m
//  LCProxyTweak
//

#import "KPWebServer.h"
#import "ConsoleHTML.h"
#import "LCProxyTweak.h"
#import "KPLogger.h"
#import "KPConfig.h"
#import "KPTsCore.h"
#import "KPKingForwarder.h"
#import "KPModeController.h"
#import "KPKIngCore.h"

#import "GCDWebServer.h"
#import "GCDWebServerDataRequest.h"
#import "GCDWebServerDataResponse.h"
#import "GCDWebServerRequest.h"

int const KPWebServerDefaultPort = 19092;

@interface KPWebServer ()
@property (nonatomic, strong) GCDWebServer *server;
@property (nonatomic, strong) dispatch_queue_t loginQueue;
@property (nonatomic, strong) NSURLSession *session;
@end

@implementation KPWebServer

+ (instancetype)shared {
    static KPWebServer *instance = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[KPWebServer alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _loginQueue = dispatch_queue_create("lcproxy.web.login", DISPATCH_QUEUE_SERIAL);
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.timeoutIntervalForRequest = 30;
        _session = [NSURLSession sessionWithConfiguration:cfg];
    }
    return self;
}

- (BOOL)isRunning {
    return self.server != nil && self.server.isRunning;
}

- (int)port {
    return (int)self.server.port;
}

#pragma mark - JSON 工具

- (GCDWebServerResponse *)jsonResponse:(id)obj statusCode:(NSInteger)code {
    NSData *data = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    GCDWebServerDataResponse *resp = [GCDWebServerDataResponse responseWithData:data contentType:@"application/json; charset=utf-8"];
    resp.statusCode = code;
    return resp;
}

- (GCDWebServerResponse *)json:(id)obj { return [self jsonResponse:obj statusCode:200]; }
- (GCDWebServerResponse *)jsonError:(NSString *)msg statusCode:(NSInteger)code {
    return [self jsonResponse:@{@"error": msg ?: @""} statusCode:code];
}

- (NSString *)nowString {
    static NSDateFormatter *fmt;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"HH:mm:ss";
    });
    return [fmt stringFromDate:[NSDate date]];
}

- (NSDictionary *)jsonBody:(GCDWebServerRequest *)request {
    NSData *data = nil;
    if ([request isKindOfClass:[GCDWebServerDataRequest class]]) {
        data = [(GCDWebServerDataRequest *)request data];
    }
    if (!data) return @{};
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [obj isKindOfClass:[NSDictionary class]] ? obj : @{};
}

#pragma mark - 启动

- (BOOL)start {
    if (self.isRunning) return YES;

    GCDWebServer *server = [[GCDWebServer alloc] init];
    self.server = server;

    // 控制台首页
    [server addDefaultHandlerForMethod:@"GET"
                         requestClass:[GCDWebServerRequest class]
                         processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        return [GCDWebServerDataResponse responseWithHTML:[NSString stringWithUTF8String:kKPConsoleHTML]];
    }];

    [server addHandlerForMethod:@"GET" path:@"/api/status" requestClass:[GCDWebServerRequest class]
                   processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        return [self json:[self statusPayload]];
    }];

    [server addHandlerForMethod:@"GET" path:@"/api/version" requestClass:[GCDWebServerRequest class]
                   processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        return [self json:@{
            @"tweakVersion": KPTweakVersionString,
            @"coreVersion": [[KPTsCore shared] coreVersionCached] ?: @"",
        }];
    }];

    [server addHandlerForMethod:@"GET" path:@"/api/debug" requestClass:[GCDWebServerRequest class]
                   processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        return [self json:@{
            @"debugEnabled": @([[KPConfig shared] debugEnabled]),
            @"logLevel": [[KPConfig shared] debugLogLevel],
            @"logFile": [[KPLogger shared] currentLogFilePath] ?: @"",
            @"steps": [[KPLogger shared] recentSteps],
            @"mode": KPModeName([[KPModeController shared] currentMode]),
        }];
    }];

    [server addHandlerForMethod:@"POST" path:@"/api/debug" requestClass:[GCDWebServerDataRequest class]
                   processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        NSDictionary *body = [self jsonBody:request];
        KPConfig *cfg = [KPConfig shared];
        NSDictionary *cur = [cfg load];
        NSMutableDictionary *dbg = [NSMutableDictionary dictionaryWithDictionary:cur[@"debug"] ?: @{}];
        if ([body[@"enabled"] isKindOfClass:[NSNumber class]]) dbg[@"enabled"] = body[@"enabled"];
        if ([body[@"logLevel"] isKindOfClass:[NSString class]]) dbg[@"logLevel"] = body[@"logLevel"];
        NSMutableDictionary *merged = [NSMutableDictionary dictionaryWithDictionary:cur];
        merged[@"debug"] = dbg;
        [cfg save:merged];
        // 立即生效：更新日志级别
        if ([body[@"logLevel"] isKindOfClass:[NSString class]]) {
            NSString *lv = body[@"logLevel"];
            if ([lv isEqualToString:@"debug"]) [KPLogger shared].minLevel = KPLogLevelDebug;
            else if ([lv isEqualToString:@"warn"]) [KPLogger shared].minLevel = KPLogLevelWarn;
            else if ([lv isEqualToString:@"error"]) [KPLogger shared].minLevel = KPLogLevelError;
            else [KPLogger shared].minLevel = KPLogLevelInfo;
        } else if ([body[@"enabled"] isKindOfClass:[NSNumber class]]) {
            [KPLogger shared].minLevel = [body[@"enabled"] boolValue] ? KPLogLevelDebug : KPLogLevelInfo;
        }
        return [self json:@{@"ok": @YES}];
    }];

    [self addRestRoutes:server];

    NSError *err = nil;
    BOOL ok = [server startWithOptions:@{
        GCDWebServerOption_Port: @(KPWebServerDefaultPort),
        GCDWebServerOption_BindToLocalhost: @YES,
        GCDWebServerOption_AutomaticallySuspendInBackground: @NO,
    } error:&err];
    if (!ok) {
        [[KPLogger shared] stepCheckModule:KPLogModuleWeb name:@"Web 控制台启动" ok:NO
                                     format:@"%@", err.localizedDescription ?: @"unknown"];
        return NO;
    }
    [[KPLogger shared] stepCheckModule:KPLogModuleWeb name:@"Web 控制台启动" ok:YES
                                 format:@"http://127.0.0.1:%d（Safari 打开）", self.port];
    return YES;
}

- (void)stop {
    if (self.server) {
        [self.server stop];
        self.server = nil;
    }
}

#pragma mark - REST 路由

- (void)addRestRoutes:(GCDWebServer *)server {
    __weak typeof(self) weakSelf = self;

    // ---- Tailscale 控制 ----
    [server addHandlerForMethod:@"POST" path:@"/api/login" requestClass:[GCDWebServerDataRequest class]
                   processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        NSDictionary *body = [weakSelf jsonBody:request];
        NSString *authkey = body[@"authkey"];
        KPTsCore *core = [KPTsCore shared];
        if (!core.loaded) {
            return [weakSelf jsonError:@"TailscaleCore 未加载" statusCode:409];
        }
        if (!authkey.length) {
            NSString *url = [core loginURL];
            return [weakSelf json:@{@"loginURL": url ?: @""}];
        }
        // TsLogin 同步 ≤2min，放后台队列避免阻塞 HTTP
        dispatch_async(weakSelf.loginQueue, ^{
            int rc = [core loginWithAuthKey:authkey];
            [[KPLogger shared] logWithLevel:KPLogLevelInfo module:KPLogModuleAuth
                                     format:@"异步登录完成 rc=%d", rc];
        });
        return [weakSelf json:@{@"status": @"async", @"message": @"登录进行中（≤2分钟）"}];
    }];

    [server addHandlerForMethod:@"POST" path:@"/api/logout" requestClass:[GCDWebServerDataRequest class]
                   processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        // tscore 无独立登出；stop 后状态目录保留（下次启动自动登录）
        [[KPTsCore shared] stop];
        [[KPLogger shared] stepCheckModule:KPLogModuleAuth name:@"登出(TsStop)" ok:YES
                                     format:@"状态目录保留，重启后自动登录"];
        return [weakSelf json:@{@"ok": @YES, @"message": @"已停止 core（状态保留）"}];
    }];

    [server addHandlerForMethod:@"GET" path:@"/api/exitnodes" requestClass:[GCDWebServerRequest class]
                   processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        KPTsCore *core = [KPTsCore shared];
        if (!core.loaded) return [weakSelf json:@{@"nodes": @[]}];
        NSString *json = [core listExitNodesJSON];
        NSArray *nodes = json ? [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
        return [weakSelf json:@{@"nodes": nodes ?: @[]}];
    }];

    [server addHandlerForMethod:@"POST" path:@"/api/exitnode" requestClass:[GCDWebServerDataRequest class]
                   processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        NSDictionary *body = [weakSelf jsonBody:request];
        NSString *idOrName = body[@"id"] ?: body[@"name"];
        if (!idOrName.length) return [weakSelf jsonError:@"缺少 id/name" statusCode:400];
        int rc = [[KPTsCore shared] setExitNode:idOrName];
        if (rc != 0) return [weakSelf jsonError:@"设置失败（core 未加载或节点无效）" statusCode:409];
        return [weakSelf json:@{@"ok": @YES}];
    }];

    [server addHandlerForMethod:@"POST" path:@"/api/exitnode/clear" requestClass:[GCDWebServerDataRequest class]
                   processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        int rc = [[KPTsCore shared] clearExitNode];
        if (rc != 0) return [weakSelf jsonError:@"清除失败" statusCode:409];
        return [weakSelf json:@{@"ok": @YES}];
    }];

    [server addHandlerForMethod:@"GET" path:@"/api/netcheck" requestClass:[GCDWebServerRequest class]
                   processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        return [weakSelf netcheckResponse];
    }];
    [server addHandlerForMethod:@"POST" path:@"/api/netcheck" requestClass:[GCDWebServerDataRequest class]
                   processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        return [weakSelf netcheckResponse];
    }];

    [server addHandlerForMethod:@"POST" path:@"/api/ping" requestClass:[GCDWebServerDataRequest class]
                   processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        NSDictionary *body = [weakSelf jsonBody:request];
        NSString *ip = body[@"ip"] ?: @"";
        NSString *type = body[@"type"] ?: @"disco";
        KPTsCore *core = [KPTsCore shared];
        if (!core.loaded) {
            // mock（契约定死，core 就绪后走真数据）
            return [weakSelf json:@{@"result": @{@"ip": ip, @"latencyMs": @0, @"via": @"mock", @"mock": @YES}}];
        }
        NSString *json = [core pingIP:ip type:type];
        id result = json ? [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
        return [weakSelf json:@{@"result": result ?: @{}}];
    }];

    [server addHandlerForMethod:@"GET" path:@"/api/prefs" requestClass:[GCDWebServerRequest class]
                   processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        KPTsCore *core = [KPTsCore shared];
        if (!core.loaded) return [weakSelf json:@{@"routeAll": @NO, @"mock": @YES}];
        NSString *json = [core getPrefsJSON];
        id prefs = json ? [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
        return [weakSelf json:prefs ?: @{}];
    }];
    [server addHandlerForMethod:@"POST" path:@"/api/prefs" requestClass:[GCDWebServerDataRequest class]
                   processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        NSDictionary *body = [weakSelf jsonBody:request];
        if ([body[@"routeAll"] isKindOfClass:[NSNumber class]]) {
            int rc = [[KPTsCore shared] setRouteAll:[body[@"routeAll"] boolValue]];
            if (rc != 0) return [weakSelf jsonError:@"设置失败（core 未加载）" statusCode:409];
        }
        return [weakSelf json:@{@"ok": @YES}];
    }];

    // ---- 出口代理 / king ----
    [server addHandlerForMethod:@"POST" path:@"/api/tailscale" requestClass:[GCDWebServerDataRequest class]
                   processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        NSDictionary *body = [weakSelf jsonBody:request];
        KPConfig *cfg = [KPConfig shared];
        NSDictionary *cur = [cfg load];
        NSMutableDictionary *ts = [NSMutableDictionary dictionaryWithDictionary:cur[@"tailscale"] ?: @{}];
        if ([body[@"enabled"] isKindOfClass:[NSNumber class]]) ts[@"enabled"] = body[@"enabled"];
        NSMutableDictionary *merged = [NSMutableDictionary dictionaryWithDictionary:cur];
        merged[@"tailscale"] = ts;
        [cfg save:merged];
        // 重新应用模式（联动）
        [[KPModeController shared] applyConfig:merged];
        return [weakSelf json:@{@"ok": @YES}];
    }];

    [server addHandlerForMethod:@"POST" path:@"/api/ipcheck" requestClass:[GCDWebServerDataRequest class]
                   processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        KPKingForwarder *king = [KPKingForwarder shared];
        NSString *proxyHost = king.proxyHostFromConfig;
        int proxyPort = king.proxyPortFromConfig;
        NSString *guid = king.guid;
        NSString *token = king.token;
        if (!guid.length || !token.length) {
            return [self jsonError:@"无凭证：请先取号（立即刷新凭证）" statusCode:409];
        }
        // 经免流网关 CONNECT 到 IP 服务，取出口 IP
        static const char *targets[][3] = {
            {"checkip.amazonaws.com", "80", "/"},
            {"api.ipify.org", "80", "/"},
        };
        NSString *ip = nil;
        for (size_t i = 0; i < 2 && !ip; i++) {
            char body[1024] = {0};
            int rc = kp_http_get_via_proxy(proxyHost.UTF8String, proxyPort,
                                           targets[i][0], atoi(targets[i][1]), targets[i][2],
                                           guid.UTF8String, token.UTF8String,
                                           10000, body, sizeof(body));
            if (rc == 0) {
                NSString *s = [@(body) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (s.length >= 7) ip = s; // 粗校验像 IP
            }
        }
        if (!ip) {
            return [self jsonError:@"出口检测失败（经免流网关无法访问 IP 服务）" statusCode:502];
        }
        return [self json:@{
            @"ok": @YES,
            @"ip": ip,
            @"via": @"proxy",
            @"at": [self nowString],
        }];
    }];

    [server addHandlerForMethod:@"GET" path:@"/api/king/status" requestClass:[GCDWebServerRequest class]
                   processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        return [weakSelf json:[[KPKingForwarder shared] statusDictionary]];
    }];

    [server addHandlerForMethod:@"POST" path:@"/api/king" requestClass:[GCDWebServerDataRequest class]
                   processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        NSDictionary *body = [weakSelf jsonBody:request];
        KPConfig *cfg = [KPConfig shared];
        NSDictionary *cur = [cfg load];
        NSMutableDictionary *king = [NSMutableDictionary dictionaryWithDictionary:cur[@"king"] ?: @{}];
        if ([body[@"enabled"] isKindOfClass:[NSNumber class]]) king[@"enabled"] = body[@"enabled"];
        if ([body[@"guid"] isKindOfClass:[NSString class]]) king[@"guidOverride"] = body[@"guid"];
        if ([body[@"token"] isKindOfClass:[NSString class]]) king[@"tokenOverride"] = body[@"token"];
        NSMutableDictionary *merged = [NSMutableDictionary dictionaryWithDictionary:cur];
        merged[@"king"] = king;
        [cfg save:merged];
        // 重新应用模式（联动）
        [[KPModeController shared] applyConfig:merged];
        return [weakSelf json:@{@"ok": @YES}];
    }];

    [server addHandlerForMethod:@"POST" path:@"/api/king/refresh" requestClass:[GCDWebServerDataRequest class]
                   processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        [[KPKingForwarder shared] refreshCredentialsWithCompletion:nil];
        return [weakSelf json:@{@"ok": @YES, @"message": @"刷新已触发"}];
    }];

    [server addHandlerForMethod:@"GET" path:@"/api/derp" requestClass:[GCDWebServerRequest class]
                   processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        return [weakSelf json:@{@"derpOnly": @([[KPTsCore shared] getDerpOnly] == 1)}];
    }];
    [server addHandlerForMethod:@"POST" path:@"/api/derp" requestClass:[GCDWebServerDataRequest class]
                   processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        NSDictionary *body = [weakSelf jsonBody:request];
        if (![body[@"enable"] isKindOfClass:[NSNumber class]]) {
            return [weakSelf jsonError:@"缺少 enable" statusCode:400];
        }
        int rc = [[KPTsCore shared] setDerpOnly:[body[@"enable"] boolValue]];
        if (rc != 0) return [weakSelf jsonError:@"设置失败（core 未加载或版本过旧）" statusCode:409];
        return [weakSelf json:@{@"ok": @YES}];
    }];

    // ---- 核心更新 ----
    [server addHandlerForMethod:@"GET" path:@"/api/core/status" requestClass:[GCDWebServerRequest class]
                   processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        KPTsCore *core = [KPTsCore shared];
        return [weakSelf json:@{
            @"present": @([core corePresent]),
            @"loaded": @(core.loaded),
            @"version": [core coreVersionCached] ?: @"",
            @"path": [core corePath],
        }];
    }];

    [server addHandlerForMethod:@"POST" path:@"/api/core/check" requestClass:[GCDWebServerDataRequest class]
                   processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        NSString *repo = [weakSelf updateRepo];
        if (!repo.length) return [weakSelf jsonError:@"未配置更新源" statusCode:400];
        NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://api.github.com/repos/%@/releases/latest", repo]];
        NSURLSessionDataTask *task = [weakSelf.session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            if (err || !data) {
                [[KPLogger shared] stepCheckModule:KPLogModuleUpdate name:@"检查更新" ok:NO
                                             format:@"%@", err.localizedDescription ?: @"no data"];
                return;
            }
            id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSString *tag = [obj isKindOfClass:[NSDictionary class]] ? obj[@"tag_name"] : nil;
            NSString *local = [[KPTsCore shared] coreVersionCached] ?: @"";
            BOOL upToDate = tag.length && [tag isEqualToString:local];
            [[KPLogger shared] stepCheckModule:KPLogModuleUpdate name:@"检查更新" ok:(tag.length > 0)
                                         format:@"最新=%@ 本地=%@ upToDate=%d", tag ?: @"?", local ?: @"?", upToDate];
        }];
        [task resume];
        return [weakSelf json:@{@"status": @"async", @"message": @"检查已触发（结果见日志）"}];
    }];

    [server addHandlerForMethod:@"POST" path:@"/api/core/download" requestClass:[GCDWebServerDataRequest class]
                   processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        NSDictionary *body = [weakSelf jsonBody:request];
        NSString *customURL = [body[@"url"] isKindOfClass:[NSString class]] ? body[@"url"] : nil;
        return [weakSelf downloadCore:customURL];
    }];
}

- (GCDWebServerResponse *)netcheckResponse {
    KPTsCore *core = [KPTsCore shared];
    if (!core.loaded) {
        // mock：契约定死
        return [self json:@{
            @"udp": @YES,
            @"latencies": @{@"tok": @{@"latencyMs": @25, @"preferred": @YES}},
            @"mock": @YES,
        }];
    }
    NSString *json = [core netcheckJSON];
    id result = json ? [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
    return [self json:result ?: @{}];
}

#pragma mark - 状态聚合

- (NSDictionary *)statusPayload {
    KPTsCore *core = [KPTsCore shared];
    KPModeController *mode = [KPModeController shared];
    KPKingForwarder *king = [KPKingForwarder shared];
    KPConfig *cfg = [KPConfig shared];

    NSDictionary *exitNode = nil;
    if (core.loaded) {
        NSString *json = [core getExitNodeStatusJSON];
        id obj = json ? [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
        if ([obj isKindOfClass:[NSDictionary class]] && obj[@"id"]) exitNode = obj;
    }

    NSString *currentUser = nil;
    if (core.loaded) {
        NSString *json = [core currentUser];
        if (json) {
            id obj = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
            if ([obj isKindOfClass:[NSDictionary class]]) {
                NSString *login = obj[@"loginName"];
                NSString *display = obj[@"displayName"];
                currentUser = display.length ? [NSString stringWithFormat:@"%@ (%@)", display, login] : login;
            }
        }
    }

    NSString *ipsJSON = core.loaded ? [core tailscaleIPsJSON] : nil;
    NSArray *ips = @[];
    if (ipsJSON) {
        id obj = [NSJSONSerialization JSONObjectWithData:[ipsJSON dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        if ([obj isKindOfClass:[NSArray class]]) ips = obj;
    }

    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"tweakVersion"] = KPTweakVersionString;
    d[@"mode"] = KPModeName(mode.currentMode);
    d[@"tailscaleEnabled"] = @([cfg tailscaleEnabled]);
    d[@"kingEnabled"] = @([cfg kingEnabled]);
    d[@"derpOnly"] = @([core getDerpOnly] == 1);
    d[@"desiredProxy"] = [self describeDesiredProxy:mode.desiredProxy];
    d[@"core"] = @{
        @"present": @([core corePresent]),
        @"loaded": @(core.loaded),
        @"version": [core coreVersionCached] ?: @"",
        @"running": @([core isRunning] == 1),
        @"needsLogin": @([core needsLogin] == 1),
        @"currentUser": currentUser ?: @"",
        @"tailscaleIPs": ips,
    };
    d[@"exitNode"] = exitNode ?: @{};
    d[@"king"] = [king statusDictionary];
    return d;
}

- (NSString *)describeDesiredProxy:(NSDictionary *)proxy {
    if (!proxy) return @"—";
    NSNumber *kindNum = proxy[@"kind"];
    NSInteger kind = kindNum ? kindNum.integerValue : 0;
    switch (kind) {
        case 1: return [NSString stringWithFormat:@"SOCKS5 %@:%@", proxy[@"host"], proxy[@"port"]];
        case 2: return [NSString stringWithFormat:@"HTTP %@:%@", proxy[@"host"], proxy[@"port"]];
        default: return @"none";
    }
}

- (NSString *)updateRepo {
    id v = [[KPConfig shared] load][@"tailscale"][@"updateRepo"];
    if ([v isKindOfClass:[NSString class]]) {
        NSString *s = (NSString *)v;
        if (s.length) return s;
    }
    return @"koast18/tailscale";
}

#pragma mark - 核心下载（自动安装）

// 校验为 arm64 Mach-O（支持 FAT）。返回 YES 可安装。
- (BOOL)isValidMachOAtPath:(NSString *)path {
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) return NO;
    NSData *head = [fh readDataOfLength:4];
    [fh closeFile];
    if (head.length < 4) return NO;
    const uint8_t *b = head.bytes;
    uint32_t le = (uint32_t)b[0] | ((uint32_t)b[1] << 8) | ((uint32_t)b[2] << 16) | ((uint32_t)b[3] << 24);
    uint32_t be = ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | (uint32_t)b[3];
    // MH_MAGIC_64=0xFEEDFACF / MH_CIGAM_64=0xCFFAEDFE；FAT=0xCAFEBABE/0xBEBAFECA
    return le == 0xFEEDFACF || be == 0xFEEDFACF || le == 0xCAFEBABE || be == 0xCAFEBABE;
}

- (GCDWebServerResponse *)downloadCore:(NSString *)customURL {
    KPTsCore *core = [KPTsCore shared];
    NSString *kingDir = [[core baseDirectory] stringByAppendingPathComponent:@"KingProxy"];
    NSString *pendingDir = [kingDir stringByAppendingPathComponent:@"pending"];
    if (![[NSFileManager defaultManager] createDirectoryAtPath:pendingDir
                                  withIntermediateDirectories:YES attributes:nil error:nil]) {
        return [self jsonError:@"创建临时目录失败" statusCode:500];
    }
    NSString *version = nil;
    NSString *downloadURL = customURL;
    if (!downloadURL) {
        // 默认：GitHub Release 最新版（koast18/tailscale，资产 libTailscaleCore.dylib）
        NSString *repo = [self updateRepo];
        NSURL *apiURL = [NSURL URLWithString:[NSString stringWithFormat:@"https://api.github.com/repos/%@/releases/latest", repo]];
        NSData *data = [NSData dataWithContentsOfURL:apiURL];
        if (data) {
            id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([obj isKindOfClass:[NSDictionary class]]) {
                version = obj[@"tag_name"];
                for (NSDictionary *asset in obj[@"assets"] ?: @[]) {
                    if ([asset[@"name"] isEqualToString:@"libTailscaleCore.dylib"]) {
                        downloadURL = asset[@"browser_download_url"];
                        break;
                    }
                }
            }
        }
        if (!downloadURL) {
            return [self jsonError:@"获取 Release 信息失败（仓库或资产名不对）" statusCode:404];
        }
    }
    NSString *tmp = [pendingDir stringByAppendingPathComponent:@"libTailscaleCore.dylib.tmp"];
    [[KPLogger shared] stepCheckModule:KPLogModuleUpdate name:@"下载 core" ok:YES
                                 format:@"url=%@ -> tmp", downloadURL];
    NSError *err = nil;
    NSData *bin = [NSData dataWithContentsOfURL:[NSURL URLWithString:downloadURL] options:NSDataReadingMappedIfSafe error:&err];
    if (!bin) {
        [[KPLogger shared] stepCheckModule:KPLogModuleUpdate name:@"下载 core" ok:NO
                                     format:@"%@", err.localizedDescription ?: @"no data"];
        return [self jsonError:[NSString stringWithFormat:@"下载失败: %@", err.localizedDescription ?: @"?"] statusCode:502];
    }
    if (![bin writeToFile:tmp atomically:YES]) {
        return [self jsonError:@"写入临时文件失败" statusCode:500];
    }
    // 校验
    if (![self isValidMachOAtPath:tmp]) {
        [[KPLogger shared] stepCheckModule:KPLogModuleUpdate name:@"校验 core" ok:NO
                                     format:@"非 arm64 Mach-O，拒绝安装 (size=%lu)", (unsigned long)bin.length];
        [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
        return [self jsonError:@"文件校验失败：非 arm64 Mach-O，已拒绝" statusCode:415];
    }
    // 原子安装到 Tweaks/libTailscaleCore.dylib（LC 强制签名后 dlopen 可直接用；替换旧文件）
    NSString *tweaksDir = [[core baseDirectory] stringByAppendingPathComponent:@"Tweaks"];
    NSString *dest = [tweaksDir stringByAppendingPathComponent:@"libTailscaleCore.dylib"];
    [[NSFileManager defaultManager] removeItemAtPath:dest error:nil];
    NSError *mvErr = nil;
    if (![[NSFileManager defaultManager] moveItemAtPath:tmp toPath:dest error:&mvErr]) {
        [[KPLogger shared] stepCheckModule:KPLogModuleUpdate name:@"安装 core" ok:NO format:@"%@", mvErr.localizedDescription ?: @"move failed"];
        return [self jsonError:@"安装失败（文件移动出错）" statusCode:500];
    }
    // 版本元数据（不参与签名，放 KingProxy/ 统一管理）
    NSString *ver = version.length ? version : [NSString stringWithFormat:@"custom-%@", @((long)[[NSDate date] timeIntervalSince1970])];
    [[ver stringByAppendingString:@"\n"] writeToFile:[kingDir stringByAppendingPathComponent:@"version.txt"]
                                          atomically:YES encoding:NSUTF8StringEncoding error:nil];
    // 清理临时下载目录
    [[NSFileManager defaultManager] removeItemAtPath:pendingDir error:nil];
    [[KPLogger shared] stepCheckModule:KPLogModuleUpdate name:@"安装 core" ok:YES
                                 format:@"已安装 v%@ size=%lu -> %@（LC 强制签名后生效，重启 LC）", ver, (unsigned long)bin.length, dest];
    return [self json:@{
        @"ok": @YES,
        @"message": [NSString stringWithFormat:@"已安装 v%@ 到 %@，请在 LiveContainer 里点一次「强制签名」后重启", ver, dest],
        @"version": ver,
        @"installedPath": dest,
    }];
}

@end
