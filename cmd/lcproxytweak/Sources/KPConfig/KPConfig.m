//
//  KPConfig.m
//  LCProxyTweak
//

#import "KPConfig.h"
#import "KPLogger.h"
#import "KPSharedPaths.h"

static NSString *const KPConfigFileName = @"conf.json";

NSDictionary *KPConfigDefaults(void) {
    return @{
        @"tailscale": @{
            @"enabled": @NO,
            @"hostname": @"lcproxy",
            @"exitNode": [NSNull null],
            @"updateRepo": @"koast18/tailscale",
        },
        @"king": @{
            @"enabled": @NO,
            @"refreshURL": @"http://kc.iikira.com/kingcard",
            @"proxyHost": @"157.148.54.212",
            @"proxyPort": @8091,
            @"guidOverride": [NSNull null],
            @"tokenOverride": [NSNull null],
        },
        @"debug": @{
            @"enabled": @YES,          // 无配置文件时也默认开启
            @"logLevel": @"debug",    // debug|info|warn|error
        },
    };
}

@interface KPConfig ()
@property (nonatomic, strong) NSLock *lock;
@end

@implementation KPConfig

+ (instancetype)shared {
    static KPConfig *instance = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[KPConfig alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = [[NSLock alloc] init];
    }
    return self;
}

- (NSString *)defaultBaseDirectory {
    return KPSharedRootDirectory(); // <LC Documents>，conf 位于 <LC Documents>/KingProxy/conf.json
}

- (NSString *)baseDirectory {
    return _baseDirectory ?: [self defaultBaseDirectory];
}

- (NSString *)filePath {
    return [[self.baseDirectory stringByAppendingPathComponent:@"KingProxy"]
            stringByAppendingPathComponent:KPConfigFileName];
}

- (NSDictionary *)load {
    [self.lock lock];
    NSString *path = self.filePath;
    [self.lock unlock];

    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) {
        return KPConfigDefaults();
    }
    NSError *err = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (err || ![obj isKindOfClass:[NSDictionary class]]) {
        [[KPLogger shared] logWithLevel:KPLogLevelWarn
                                 module:KPLogModuleConfig
                                 format:@"conf.json 解析失败(%@)，使用默认配置", err ?: @"not a dict"];
        return KPConfigDefaults();
    }
    return obj;
}

- (BOOL)save:(NSDictionary *)config {
    [self.lock lock];
    NSString *path = self.filePath;
    [self.lock unlock];

    NSString *dir = [path stringByDeletingLastPathComponent];
    if (![[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES attributes:nil error:nil]) {
        return NO;
    }
    NSError *err = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:config options:NSJSONWritingPrettyPrinted error:&err];
    if (err) {
        [[KPLogger shared] logWithLevel:KPLogLevelError module:KPLogModuleConfig
                                 format:@"conf.json 序列化失败: %@", err];
        return NO;
    }
    BOOL ok = [data writeToFile:path options:NSDataWritingAtomic error:&err];
    if (!ok) {
        [[KPLogger shared] logWithLevel:KPLogLevelError module:KPLogModuleConfig
                                 format:@"conf.json 写入失败: %@", err];
    }
    return ok;
}

- (NSMutableDictionary *)deepMutableCopy:(NSDictionary *)dict {
    NSMutableDictionary *m = [NSMutableDictionary dictionary];
    for (NSString *key in dict) {
        id v = dict[key];
        if ([v isKindOfClass:[NSDictionary class]]) {
            m[key] = [self deepMutableCopy:v];
        } else {
            m[key] = v;
        }
    }
    return m;
}

- (BOOL)boolForKeyPath:(NSArray<NSString *> *)path inDict:(NSDictionary *)dict defaultValue:(BOOL)dv {
    id cur = dict;
    for (NSString *key in path) {
        if (![cur isKindOfClass:[NSDictionary class]]) return dv;
        cur = cur[key];
    }
    return [cur isKindOfClass:[NSNumber class]] ? [cur boolValue] : dv;
}

- (BOOL)hasConfigFile {
    return [[NSFileManager defaultManager] fileExistsAtPath:self.filePath];
}

- (BOOL)debugEnabled {
    // 没有配置文件 → 默认开启（方便调试）
    if (![self hasConfigFile]) return YES;
    id v = [self load][@"debug"][@"enabled"];
    return [v isKindOfClass:[NSNumber class]] ? [v boolValue] : YES;
}

- (NSString *)debugLogLevel {
    id v = [self load][@"debug"][@"logLevel"];
    return [v isKindOfClass:[NSString class]] ? v : @"debug";
}

- (BOOL)tailscaleEnabled {
    return [self boolForKeyPath:@[@"tailscale", @"enabled"] inDict:[self load] defaultValue:NO];
}

- (BOOL)kingEnabled {
    return [self boolForKeyPath:@[@"king", @"enabled"] inDict:[self load] defaultValue:NO];
}

- (void)setTailscaleEnabled:(BOOL)ts kingEnabled:(BOOL)king {
    NSDictionary *cur = [self load];
    NSMutableDictionary *merged = [self deepMutableCopy:cur];
    NSMutableDictionary *tsDict = [NSMutableDictionary dictionaryWithDictionary:merged[@"tailscale"] ?: @{}];
    tsDict[@"enabled"] = @(ts);
    merged[@"tailscale"] = tsDict;
    NSMutableDictionary *kingDict = [NSMutableDictionary dictionaryWithDictionary:merged[@"king"] ?: @{}];
    kingDict[@"enabled"] = @(king);
    merged[@"king"] = kingDict;
    [self save:merged];
    [[KPLogger shared] logWithLevel:KPLogLevelInfo module:KPLogModuleConfig
                             format:@"模式保存 tailscale=%@ king=%@", @(ts), @(king)];
}

/// 上游代理（免流网关或用户自己的翻墙代理）：conf.king.proxyHost / proxyPort
- (NSString *)proxyHost {
    NSDictionary *king = [self load][@"king"];
    id v = king[@"proxyHost"];
    return [v isKindOfClass:[NSString class]] && [v length] ? v : @"157.148.54.212";
}

- (int)proxyPort {
    NSDictionary *king = [self load][@"king"];
    id v = king[@"proxyPort"];
    return [v isKindOfClass:[NSNumber class]] ? [v intValue] : 8091;
}

- (void)setProxyHost:(NSString *)host port:(int)port {
    NSDictionary *cur = [self load];
    NSMutableDictionary *merged = [self deepMutableCopy:cur];
    NSMutableDictionary *kingDict = [NSMutableDictionary dictionaryWithDictionary:merged[@"king"] ?: @{}];
    kingDict[@"proxyHost"] = host ?: @"157.148.54.212";
    kingDict[@"proxyPort"] = @(port > 0 ? port : 8091);
    merged[@"king"] = kingDict;
    [self save:merged];
    [[KPLogger shared] logWithLevel:KPLogLevelInfo module:KPLogModuleConfig
                             format:@"上游代理保存 %@:%d", host, port];
}

@end
