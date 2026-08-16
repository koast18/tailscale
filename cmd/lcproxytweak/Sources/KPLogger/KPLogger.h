//
//  KPLogger.h
//  LCProxyTweak
//
//  统一日志模块（PLAN.md 3.7 规格）：
//  - 目录 Documents/KingProxy/logs/（基目录可注入，测试可覆盖）
//  - 每次进程启动一个新文件 LCProxy-YYYYMMDD-HHmmss-SSS.log
//  - 创建前若已有 ≥50 个文件，从最旧删除直到 <50
//  - 每行 ISO8601时间 [级别] [模块] 内容
//  - GUID 仅前 4 位、TOKEN 打码不落明文
//  - 串行 dispatch 队列写入，不阻塞业务；异常兜底
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, KPLogLevel) {
    KPLogLevelDebug = 0,
    KPLogLevelInfo  = 1,
    KPLogLevelWarn  = 2,
    KPLogLevelError = 3,
};

typedef NS_ENUM(NSInteger, KPLogModule) {
    KPLogModuleBoot   = 0, // 启动/环境
    KPLogModuleConfig = 1, // 配置
    KPLogModuleMode   = 2, // 模式切换
    KPLogModuleHook   = 3, // URLSession hook（预留）
    KPLogModuleKing   = 4, // 王卡转发器
    KPLogModuleTscore = 5, // Tailscale core
    KPLogModuleWeb    = 6, // Web 控制台
    KPLogModuleUpdate = 7, // core 更新下载
    KPLogModuleAuth   = 8, // 登录/凭证
};

FOUNDATION_EXPORT NSString *KPLogLevelName(KPLogLevel level);
FOUNDATION_EXPORT NSString *KPLogModuleName(KPLogModule module);

/// GUID 脱敏：仅保留前 4 位
FOUNDATION_EXPORT NSString *KPMaskGUID(NSString *guid);
/// 敏感串脱敏：只显示长度，不落明文（TOKEN 用）
FOUNDATION_EXPORT NSString *KPMaskSecret(NSString *secret);
/// 长字母数字串脱敏：连续 ≥10 位字母数字替换为 <run:N>（用于诊断响应体，保留短错误码如 820/821）
FOUNDATION_EXPORT NSString *KPMaskLongRuns(NSString *string);

@interface KPLogger : NSObject

@property (class, nonatomic, readonly) KPLogger *shared;

/// 日志根目录（其下建 KingProxy/logs/）。默认 NSDocumentDirectory；测试可覆盖。
@property (nonatomic, copy) NSString *baseDirectory;
/// 最低记录级别，默认 Debug。
@property (nonatomic, assign) KPLogLevel minLevel;

/// 调试模式（默认 YES）：开启时强制 minLevel=Debug 且所有级别镜像 NSLog，便于真机调试。
@property (nonatomic, assign) BOOL debugMode;

/// 逐步验证：记录 {模块, 步骤名, 成功?, 详情} 到内存环（最近 200 条），
/// 并在日志里输出 ✓/✗。控制台 /api/debug 可查看。
- (void)stepCheckModule:(KPLogModule)module
                   name:(NSString *)name
                     ok:(BOOL)ok
                 format:(NSString *)format, ... NS_FORMAT_FUNCTION(4, 5);

/// 最近步骤记录（供 /api/debug）
@property (nonatomic, copy, readonly) NSArray<NSDictionary *> *recentSteps;
/// 清空步骤记录
- (void)resetSteps;

- (void)logWithLevel:(KPLogLevel)level
              module:(KPLogModule)module
              format:(NSString *)format, ... NS_FORMAT_FUNCTION(3, 4);

/// tscore 的 TsSetLogCallback 汇入口（由 KPTsCore 的 C 回调调用）
- (void)logTscoreMessage:(NSString *)message;

/// 当前日志文件路径（可能尚未创建）
@property (nonatomic, copy, readonly, nullable) NSString *currentLogFilePath;

/// 安装未捕获异常兜底（写入一条 ERROR 后转交原 handler）
+ (void)installCrashHandler;

@end

NS_ASSUME_NONNULL_END
