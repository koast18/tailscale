//
//  KPKingForwarder.h
//  LCProxyTweak
//
//  王卡免流转发器（ObjC 壳，事件驱动）：
//  - 启动/停止转发器（18080）
//  - 取号链：经上游代理 → 直连，多次重试退避（kp_fetch_guid_token_best）
//  - 登录激活（魔改域名 CONNECT）成功后做一次 generate_204 验证；取号失败不探活
//  - 无周期性探活/刷新定时器；转发器上游 CONNECT 非 200/连接失败 → 触发凭证刷新 → 重试一次
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 默认监听端口（模式 C 下 App 的 HTTP 代理指向）
FOUNDATION_EXPORT int const KPKingForwarderDefaultPort; // 18080

/// 登录域名脱敏：{guid前4}****.<secret:N>.iikira.com.token（绝不含明文 TOKEN）
FOUNDATION_EXPORT NSString *KPMaskedLoginHost(NSString *guid, NSString *token);

@interface KPKingForwarder : NSObject

@property (class, nonatomic, readonly) KPKingForwarder *shared;

/// 当前 GUID（取号成功后非空）
@property (nonatomic, readonly, copy) NSString *guid;
/// 当前 TOKEN（取号成功后非空；仅内部使用，绝不落日志）
@property (nonatomic, readonly, copy) NSString *token;
/// 上游免流网关（配置）
@property (nonatomic, readonly, copy) NSString *proxyHostFromConfig;
@property (nonatomic, readonly) int proxyPortFromConfig;

/// 配置根目录（测试可覆盖）
@property (nonatomic, copy) NSString *baseDirectory;

/// 测试用：跳过一切网络（取号/登录/探活），仅验证状态机与启停
@property (nonatomic, assign) BOOL offlineMode;

- (void)startWithConfig:(NSDictionary *)kingConfig;   // 幂等；启动后立即取号+登录+验证
- (void)stop;
- (BOOL)isRunning;

/// 立即刷新凭证（取号链 + 登录 + 成功才探活；异步，完成回调 main 队列）
- (void)refreshCredentialsWithCompletion:(nullable void (^)(BOOL ok))completion;

/// 状态字典（供 REST /api/king/status）
- (NSDictionary *)statusDictionary;

/// 记录登录激活结果（内部对登录域做脱敏，绝不含明文 TOKEN；测试可调用做回归）
- (void)logLoginAttemptWithGuid:(NSString *)guid token:(NSString *)token rc:(int)rc;

@end

NS_ASSUME_NONNULL_END
