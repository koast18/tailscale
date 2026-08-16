//
//  KPConfig.h
//  LCProxyTweak
//
//  配置读写：Documents/KingProxy/conf.json（Web UI 与文件编辑双通道）
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface KPConfig : NSObject

@property (class, nonatomic, readonly) KPConfig *shared;

/// 配置根目录（其下为 KingProxy/conf.json）。默认 NSDocumentDirectory；测试可覆盖。
@property (nonatomic, copy) NSString *baseDirectory;

/// 配置文件完整路径
@property (nonatomic, copy, readonly) NSString *filePath;

/// 是否存在配置文件（无文件 → debug 默认开启）
- (BOOL)hasConfigFile;
/// 调试模式：无配置文件或未显式关闭 → YES
- (BOOL)debugEnabled;
/// 日志级别字符串（"debug"|"info"|"warn"|"error"），默认 "debug"
- (NSString *)debugLogLevel;

/// 读取（无文件/解析失败返回默认字典，不抛错）
- (NSDictionary *)load;
/// 保存（原子写）
- (BOOL)save:(NSDictionary *)config;

// 便捷读写（同步落盘 + 日志）
- (BOOL)tailscaleEnabled;
- (BOOL)kingEnabled;
- (void)setTailscaleEnabled:(BOOL)ts kingEnabled:(BOOL)king;

@end

/// 默认配置
FOUNDATION_EXPORT NSDictionary *KPConfigDefaults(void);

NS_ASSUME_NONNULL_END
