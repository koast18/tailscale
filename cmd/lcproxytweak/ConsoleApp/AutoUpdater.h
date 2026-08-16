//
//  AutoUpdater.h
//  LCProxyConsole
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface AutoUpdater : NSObject

/// 启动时调用：自动下载最新版本的两个 dylib（带版本号文件名）。
/// 返回状态描述（nil = 无可用更新路径）；完成后清理旧版本。
+ (nullable NSString *)runAutoUpdate;

/// 本次运行是否下载了任何新 dylib（决定是否需要重启才能让 tweak 生效）
+ (BOOL)downloadedAnything;

@end

NS_ASSUME_NONNULL_END
