//
//  KPHookManager.m
//  LCProxyTweak
//

#import "KPHookManager.h"
#import "KPLogger.h"
#import "KPModeController.h"
#import "KPKingForwarder.h"
#import "KPSocketHook.h"
#import "KPFishhook.h"

#import <objc/runtime.h>
#include <objc/message.h>
#include <dlfcn.h>

// _CFNetworkCopySystemProxySettings（私有）：读系统代理设置的公共入口
// （NSURLConnection / Chromium / CFNetwork 栈），fishhook 覆盖
CFDictionaryRef _CFNetworkCopySystemProxySettings(void);

static CFDictionaryRef (*sOrigSysProxySettings)(void);
static CFDictionaryRef (*gRealSysProxySettings)(void);

static CFDictionaryRef kp_sys_proxy_replacement(void) {
    NSDictionary *cur = [KPHookManager shared].currentProxyDict;
    if (cur) return (__bridge_retained CFDictionaryRef)cur; // Copy 语义：调用者负责释放
    if (gRealSysProxySettings) return gRealSysProxySettings();
    if (sOrigSysProxySettings) return sOrigSysProxySettings();
    return NULL;
}

// 凭证桥：socket hook 构造 CONNECT 头时取当前 GUID/TOKEN
static void kp_cred_bridge(char *guid, size_t guid_cap, char *token, size_t token_cap) {
    NSString *g = [KPKingForwarder shared].guid;
    NSString *t = [KPKingForwarder shared].token;
    if (guid && guid_cap > 0) { g ? [g getCString:guid maxLength:guid_cap encoding:NSUTF8StringEncoding] : (void)(guid[0] = '\0'); }
    if (token && token_cap > 0) { t ? [t getCString:token maxLength:token_cap encoding:NSUTF8StringEncoding] : (void)(token[0] = '\0'); }
}

@interface KPHookManager ()
@property (nonatomic, copy, nullable) NSDictionary *currentProxyDict;
@property (nonatomic, assign) BOOL installed;
@end

static NSDictionary *(*sOrigConnectionProxyDictionary)(id, SEL);
static NSDictionary *KPProxyDictForSession(id self, SEL _cmd);

@implementation KPHookManager

+ (instancetype)shared {
    static KPHookManager *instance = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[KPHookManager alloc] init];
    });
    return instance;
}

- (void)install {
    if (self.installed) return;
    // 1) NSURLSessionConfiguration.connectionProxyDictionary
    Class nsc = [NSURLSessionConfiguration class];
    Method m = class_getInstanceMethod(nsc, @selector(connectionProxyDictionary));
    if (m) {
        sOrigConnectionProxyDictionary = (NSDictionary *(*)(id, SEL))method_getImplementation(m);
        method_setImplementation(m, (IMP)KPProxyDictForSession);
    } else {
        [[KPLogger shared] logWithLevel:KPLogLevelWarn module:KPLogModuleHook
                                 format:@"NSURLSessionConfiguration.connectionProxyDictionary 不存在，无法注入 URLSession 代理"];
    }
    // 2) WKWebsiteDataStore.proxyConfigurations（iOS 15+，尽力）
    Class wds = NSClassFromString(@"WKWebsiteDataStore");
    if (wds) {
        Method m2 = class_getInstanceMethod(wds, @selector(proxyConfigurations));
        if (m2) {
            method_setImplementation(m2, (IMP)KPProxyConfigurationsForStore);
            [[KPLogger shared] logWithLevel:KPLogLevelInfo module:KPLogModuleHook
                                     format:@"已注入 WKWebsiteDataStore.proxyConfigurations（WKWebView 浏览器代理）"];
        }
    }
    self.installed = YES;
    // 3) socket 层强行代理（connect/connectx）
    kp_socket_hook_install(KPKingForwarderDefaultPort, "157.148.54.212", 8091, kp_cred_bridge);
    // 4) _CFNetworkCopySystemProxySettings（NSURLConnection/Chromium/CFNetwork 栈）
    kp_rebind_symbol("CFNetworkCopySystemProxySettings", (void *)kp_sys_proxy_replacement,
                     (void **)&sOrigSysProxySettings);
    if (!gRealSysProxySettings) {
        void *sym = dlsym(RTLD_NEXT, "_CFNetworkCopySystemProxySettings");
        gRealSysProxySettings = (CFDictionaryRef (*)(void))sym;
    }
    [[KPLogger shared] logWithLevel:KPLogLevelInfo module:KPLogModuleHook
                             format:@"底层 hook 已安装：NSURLSession / WKWebView / 系统代理 / socket(connect)"];
}

static NSDictionary *KPProxyDictForSession(id self, SEL _cmd) {
    NSDictionary *cur = [KPHookManager shared].currentProxyDict;
    if (cur) return cur;
    if (sOrigConnectionProxyDictionary) return sOrigConnectionProxyDictionary(self, _cmd);
    return nil;
}

// WKWebsiteDataStore.proxyConfigurations（iOS 15+）：运行时安全构造 WKProxyConfiguration。
// 构造失败返回 nil（WebKit 回退默认），绝不崩溃。
static id KPProxyConfigurationsForStore(id self, SEL _cmd) {
    NSDictionary *cur = [KPHookManager shared].currentProxyDict;
    if (!cur) return nil;
    Class wpc = NSClassFromString(@"WKProxyConfiguration");
    Class se = NSClassFromString(@"NSURLSessionEndpoint");
    if (!wpc || !se) return nil;
    NSString *host = cur[@"HTTPProxy"] ?: cur[@"SOCKSProxy"];
    NSNumber *port = cur[@"HTTPPort"] ?: cur[@"SOCKSPort"];
    if (!host || !port) return nil;
    [[KPLogger shared] logWithLevel:KPLogLevelDebug module:KPLogModuleHook
                             format:@"[hook] 构造 WKProxyConfiguration: host=%@ port=%@ (iOS %@)",
                                    host, port, [[UIDevice currentDevice] systemVersion]];
    id endpoint = nil;
    // NSURLSessionEndpoint（iOS 15.3+ 公开）：先试 initWithHost:port:，失败再试 endpointWithHost:port:
    SEL s1 = @selector(initWithHost:port:);
    if ([se instancesRespondToSelector:s1]) {
        id (*fn)(id, SEL, id, NSUInteger) = (void *)objc_msgSend;
        endpoint = fn([se alloc], s1, host, [port unsignedIntegerValue]);
        [[KPLogger shared] logWithLevel:KPLogLevelDebug module:KPLogModuleHook
                                 format:@"[hook] NSURLSessionEndpoint initWithHost:port: → %@", endpoint ? @"OK" : @"nil"];
    }
    if (!endpoint) {
        SEL s1b = @selector(endpointWithHost:port:);
        if ([se respondsToSelector:s1b]) {
            id (*fn)(id, SEL, id, NSUInteger) = (void *)objc_msgSend;
            endpoint = fn(se, s1b, host, [port unsignedIntegerValue]);
            [[KPLogger shared] logWithLevel:KPLogLevelDebug module:KPLogModuleHook
                                     format:@"[hook] NSURLSessionEndpoint endpointWithHost:port: → %@", endpoint ? @"OK" : @"nil"];
        }
    }
    if (!endpoint) {
        [[KPLogger shared] logWithLevel:KPLogLevelError module:KPLogModuleHook
                                 format:@"[hook] NSURLSessionEndpoint 构造失败（类=%@）→ WKWebView 代理不可用", se];
        return nil;
    }
    id config = nil;
    SEL s2 = @selector(initWithEndpoint:);
    if ([wpc instancesRespondToSelector:s2]) {
        id (*fn)(id, SEL, id) = (void *)objc_msgSend;
        config = fn([wpc alloc], s2, endpoint);
        [[KPLogger shared] logWithLevel:KPLogLevelDebug module:KPLogModuleHook
                                 format:@"[hook] WKProxyConfiguration initWithEndpoint: → %@", config ? @"OK" : @"nil"];
    }
    if (!config) {
        [[KPLogger shared] logWithLevel:KPLogLevelError module:KPLogModuleHook
                                 format:@"[hook] WKProxyConfiguration 构造失败（类=%@）→ WKWebView 代理不可用", wpc];
        return nil;
    }
    [[KPLogger shared] logWithLevel:KPLogLevelInfo module:KPLogModuleHook
                             format:@"[hook] WKProxyConfiguration 就绪: %@:%@（WKWebView 将走此代理）", host, port];
    return @[config];
}

- (BOOL)setProxy:(NSDictionary *)proxy {
    NSInteger kind = [proxy[@"kind"] integerValue];
    if (kind == KPProxyKindNone) {
        self.currentProxyDict = nil;
        kp_socket_hook_set_active(0);
        kp_socket_hook_set_udp_block(0);
        [[KPLogger shared] logWithLevel:KPLogLevelInfo module:KPLogModuleHook
                                 format:@"代理已恢复直连（不 hook）"];
        return YES;
    }
    NSString *host = proxy[@"host"] ?: @"127.0.0.1";
    NSInteger port = [proxy[@"port"] integerValue] ?: 0;
    if (port <= 0) {
        [[KPLogger shared] logWithLevel:KPLogLevelWarn module:KPLogModuleHook
                                 format:@"期望代理缺少端口，忽略（kind=%ld host=%@）", (long)kind, host];
        return NO;
    }
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    // 本地地址豁免：控制台/转发器自身不走代理
    dict[@"ExceptionsList"] = @[@"127.0.0.1", @"localhost", @"*.local"];
    if (kind == KPProxyKindHTTP) {
        dict[@"HTTPEnable"] = @YES;
        dict[@"HTTPProxy"] = host;
        dict[@"HTTPPort"] = @(port);
        dict[@"HTTPSEnable"] = @YES;
        dict[@"HTTPSProxy"] = host;
        dict[@"HTTPSPort"] = @(port);
        // 免流模式：socket 层也劫持（原生 socket 直连流量 → 转发器）+ 禁止非 TCP 出站
        kp_socket_hook_set_active(1);
        kp_socket_hook_set_udp_block(1);
        [[KPLogger shared] logWithLevel:KPLogLevelInfo module:KPLogModuleHook
                                 format:@"socket 层代理已激活：非豁免 TCP 连接强制走转发器；非 TCP(UDP) 出站禁止（DNS 豁免）"];
    } else if (kind == KPProxyKindSOCKS5) {
        dict[@"SOCKSEnable"] = @YES;
        dict[@"SOCKSProxy"] = host;
        dict[@"SOCKSPort"] = @(port);
        // tailscale SOCKS5 模式：socket 层不劫持（避免与 tailscale 网络栈冲突）
        kp_socket_hook_set_active(0);
        kp_socket_hook_set_udp_block(0);
    } else {
        [[KPLogger shared] logWithLevel:KPLogLevelWarn module:KPLogModuleHook
                                 format:@"未知代理 kind=%ld，忽略", (long)kind];
        return NO;
    }
    self.currentProxyDict = [dict copy];
    [[KPLogger shared] logWithLevel:KPLogLevelInfo module:KPLogModuleHook
                             format:@"已注入代理：%@（URLSession 全量生效；WKWebView/Chromium 可能不覆盖）", [self describeDict:dict]];
    return YES;
}

- (NSString *)describeDict:(NSDictionary *)dict {
    if (dict[@"SOCKSEnable"]) {
        return [NSString stringWithFormat:@"SOCKS5 %@:%@", dict[@"SOCKSProxy"], dict[@"SOCKSPort"]];
    }
    return [NSString stringWithFormat:@"HTTP %@:%@", dict[@"HTTPProxy"], dict[@"HTTPPort"]];
}

@end
