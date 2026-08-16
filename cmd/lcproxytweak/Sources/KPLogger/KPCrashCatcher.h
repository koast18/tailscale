//
//  KPCrashCatcher.h
//  LCProxyTweak
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface KPCrashCatcher : NSObject
/// 安装 NSException + signal 崩溃捕获（堆栈写入 <LC Documents>/KingProxy/logs/crash-*.log）
+ (void)install;
@end

NS_ASSUME_NONNULL_END
