//
//  KPModeController.h
//  LCProxyTweak
//
//  四模式状态机（PLAN 3.2）：
//    A: tailscale 开 + 免流开    → SOCKS5 + HTTPS_PROXY(king) + DERP-only
//    B: tailscale 开 + 免流关    → SOCKS5，无代理限制
//    C: tailscale 关 + 免流开    → HTTP 代理(king 转发器)，不加载 core
//    D: 全关                    → 不 hook
//  联动：免流开 → TsSetHttpProxy(18080) + TsSetDerpOnly(1)；关 → 清空 + TsSetDerpOnly(0)
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, KPMode) {
    KPModeA = 0,
    KPModeB = 1,
    KPModeC = 2,
    KPModeD = 3,
};

FOUNDATION_EXPORT NSString *KPModeName(KPMode mode);

/// 期望的 hook 代理配置（由未来 hook 模块消费；本目标只计算+日志）
typedef NS_ENUM(NSInteger, KPProxyKind) {
    KPProxyKindNone = 0,   // 不 hook
    KPProxyKindSOCKS5,     // 127.0.0.1:<ts socks5 端口>
    KPProxyKindHTTP,       // http://127.0.0.1:18080（king 转发器）
};

@protocol KPModeControllerDelegate <NSObject>
@optional
- (void)modeController:(id)controller desiredProxyDidChange:(NSDictionary *)proxy;
@end

@interface KPModeController : NSObject

@property (class, nonatomic, readonly) KPModeController *shared;

@property (nonatomic, weak) id<KPModeControllerDelegate> delegate;
@property (nonatomic, readonly) KPMode currentMode;
/// 当前期望代理（{kind, host, port, user?, pass?}）
@property (nonatomic, copy, readonly, nullable) NSDictionary *desiredProxy;

/// 依据配置应用模式（幂等；内部记录每步 ✓/✗）
- (void)applyConfig:(NSDictionary *)config;

/// tailscale core 状态回调（0 idle 1 connecting 2 running 3 error）
- (void)onTsStateChanged:(int)state;

/// SOCKS5 地址/凭证变更（core 重启后端口变化，需更新期望代理）
- (void)onSocks5ChangedToAddr:(NSString *)addr cred:(NSString *)cred;

@end

NS_ASSUME_NONNULL_END
