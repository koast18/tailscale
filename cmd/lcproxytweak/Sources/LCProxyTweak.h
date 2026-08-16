//
//  LCProxyTweak.h
//  LCProxyTweak
//
//  主入口：TweakLoader dlopen 本 dylib 后，__attribute__((constructor))
//  自动执行（先于 guest app main）。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 导出的构造函数（CI 符号检查用）
FOUNDATION_EXPORT void LCProxyTweakConstructor(void) __attribute__((constructor));

/// tweak 版本号（/api/version 与 About 页显示）
FOUNDATION_EXPORT NSString *const KPTweakVersionString;

NS_ASSUME_NONNULL_END
