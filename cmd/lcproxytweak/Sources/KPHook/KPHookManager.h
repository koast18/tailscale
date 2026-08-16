//
//  KPHookManager.h
//  LCProxyTweak
//
//  真正的代理注入：swizzle NSURLSessionConfiguration.connectionProxyDictionary
//  （进程内所有 URLSession 请求）+ 尽力 swizzle WKWebsiteDataStore.proxyConfigurations
//  （WKWebView 浏览器，iOS 15+，运行时探测）。Chromium 类读系统代理，无法覆盖。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface KPHookManager : NSObject

/// 全局单例
+ (instancetype)shared;

/// 安装 swizzle（在进程生命周期早期调用一次）
- (void)install;

/// 更新期望代理。proxy 为 KPModeController 的期望代理 dict（kind/host/port/user/pass），
/// kind=0(none) 时恢复直连。返回 YES 表示已注入。
- (BOOL)setProxy:(NSDictionary *)proxy;

/// 当前注入的 CFNetwork 代理 dict（nil=直连）
@property (nonatomic, readonly, nullable) NSDictionary *currentProxyDict;

@end

NS_ASSUME_NONNULL_END
