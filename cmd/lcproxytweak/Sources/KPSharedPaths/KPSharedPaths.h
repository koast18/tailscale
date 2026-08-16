//
//  KPSharedPaths.h
//  LCProxyTweak
//
//  共享配置根（PLAN 3.5 修正版）：
//  LiveContainer 会给每个 guest app 独立数据容器（HOME 重定向），
//  NSDocumentDirectory 会落在当前 guest app 的私有目录 → 换 app 配置/日志就丢。
//  解决：以 tweak 自身 dylib 的绝对路径（dladdr）为锚，定位 LC 自己的 Documents，
//  配置/日志/core 统一放 <LC Documents>/KingProxy/，所有 guest app 共享。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 纯函数（可单测）：由 dylib 绝对路径推导 LC 自己的 Documents 根目录
/// - .../Tweaks/LCProxyTweak.dylib              → <LC Documents>
/// - .../Tweaks/LCProxyTweak.framework/Bin      → <LC Documents>
/// - 其它目录（如 per-app tweak 目录）           → <该目录>（退化行为，仍可写）
/// 各模块在此根下追加 "KingProxy/..." 使用。
FOUNDATION_EXPORT NSString *_Nullable KPSharedRootFromTweakPath(NSString *tweakPath);

/// 当前共享根目录：dladdr 定位本 dylib 路径推导；失败回退 NSDocumentDirectory
FOUNDATION_EXPORT NSString *KPSharedRootDirectory(void);

NS_ASSUME_NONNULL_END
