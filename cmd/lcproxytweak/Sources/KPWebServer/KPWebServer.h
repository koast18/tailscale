//
//  KPWebServer.h
//  LCProxyTweak
//
//  Web 控制台（GCDWebServer）：
//  - 监听 127.0.0.1:19092
//  - GET / → 内嵌单文件 HTML 控制台（ConsoleHTML.h）
//  - REST API 覆盖 PLAN 3.4 全部端点 + /api/debug
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 默认监听端口
FOUNDATION_EXPORT int const KPWebServerDefaultPort; // 19092

@interface KPWebServer : NSObject

@property (class, nonatomic, readonly) KPWebServer *shared;

- (BOOL)start;   // 幂等
- (void)stop;
- (BOOL)isRunning;
- (int)port;

@end

NS_ASSUME_NONNULL_END
