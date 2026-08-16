//
//  KPTsCore.h
//  LCProxyTweak
//
//  TailscaleCore.dylib（Go tsnet 纯库）的 dlsym 封装。
//  - dlopen + 解析全部 Ts* 符号（TAILSCALE_DYLIB_API.md，含 4.8 新增）
//  - 缺失符号 → 降级（返回安全默认值），不崩溃
//  - 状态缓存：core 存在性/版本/运行态/登录态/SOCKS5，供 REST 层读取
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// core 状态回调（0 idle 1 connecting 2 running 3 error）通知名
FOUNDATION_EXPORT NSNotificationName const KPTsCoreStateChangedNotification;
/// SOCKS5 地址变化通知（userInfo: {addr, cred}）
FOUNDATION_EXPORT NSNotificationName const KPTsCoreSocks5ChangedNotification;

@interface KPTsCore : NSObject

/// 后台串行队列：TsInit/TsStart 等慢操作专用（避免阻塞主线程）
+ (dispatch_queue_t)coreQueue;

@property (class, nonatomic, readonly) KPTsCore *shared;

/// 配置根目录（其下 KingProxy/TailscaleCore.bin，测试可覆盖）
@property (nonatomic, copy) NSString *baseDirectory;

/// dlopen 是否成功
@property (nonatomic, readonly) BOOL loaded;

/// TsInit 成功返回后为 YES（SOCKS5/功能可用的前置条件）
@property (nonatomic, readonly) BOOL coreInitialized;

#pragma mark - 生命周期

/// 尝试加载 core（路径不存在 → 返回 NO 并置 loaded=NO，不崩溃）
- (BOOL)loadCoreIfPresent;
- (void)unload;

- (int)initCoreWithDirectory:(NSString *)dir hostname:(NSString *)hostname;
- (int)start;
- (void)stop;
- (int)loginWithAuthKey:(NSString *)authKey;
- (int)needsLogin;
- (nullable NSString *)loginURL;
- (int)isRunning;

#pragma mark - 代理 / DERP-only

- (int)setHttpProxy:(nullable NSString *)proxyURL;
- (nullable NSString *)getHttpProxy;
- (int)setDerpOnly:(BOOL)enable;
- (int)getDerpOnly;

#pragma mark - 节点信息

- (nullable NSString *)socks5Addr;
- (nullable NSString *)socks5Cred;
- (nullable NSString *)currentUser;      // JSON
- (nullable NSString *)versionString;    // TsVersion
- (nullable NSString *)tailscaleIPsJSON;
- (nullable NSString *)listPeersJSON;
- (nullable NSString *)whoIs:(NSString *)ipOrAddr;

#pragma mark - 控制（返回 JSON 字符串）

- (nullable NSString *)listExitNodesJSON;
- (nullable NSString *)getExitNodeStatusJSON;
- (nullable NSString *)suggestExitNodeJSON;
- (int)setExitNode:(NSString *)nameOrIP;
- (int)clearExitNode;
- (int)setExitNodeAllowLANAccess:(BOOL)enable;
- (nullable NSString *)pingIP:(NSString *)ip type:(NSString *)type;
- (nullable NSString *)netcheckJSON;
- (nullable NSString *)debugDERPRegion:(NSString *)code;
- (nullable NSString *)statusDetailJSON;
- (nullable NSString *)getPrefsJSON;
- (int)setPrefsJSON:(NSString *)prefsJSON;
- (int)setHostname:(NSString *)name;
- (int)setRouteAll:(BOOL)enable;

#pragma mark - 状态缓存（不触发网络）

/// core 文件路径（Documents/KingProxy/TailscaleCore.bin）
- (NSString *)corePath;
/// sidecar 版本号（Documents/KingProxy/version.txt）
- (NSString *)versionTxtPath;
/// TsVersion 或 version.txt sidecar
- (NSString *)coreVersionCached;
- (BOOL)corePresent;

@end

NS_ASSUME_NONNULL_END
