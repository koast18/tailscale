//
//  AutoUpdater.h
//  LCProxyConsole
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 进度回调：stage 为阶段描述；fraction ∈ [0,1]，-1 表示该阶段无进度（不确定）
typedef void (^KPAutoUpdateProgress)(NSString *stage, double fraction);

@interface AutoUpdater : NSObject

/// 启动时调用：自动下载最新版本的两个 dylib（带版本号文件名）。
/// 返回状态描述（含完整诊断）；完成后清理旧版本。progress 在主线程回调。
+ (nullable NSString *)runAutoUpdateWithProgress:(nullable KPAutoUpdateProgress)progress;

/// 无进度回调版本
+ (nullable NSString *)runAutoUpdate;

/// 本次运行是否下载了任何新 dylib（决定是否需要重启才能让 tweak 生效）
+ (BOOL)downloadedAnything;

@end

NS_ASSUME_NONNULL_END
