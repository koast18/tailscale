//
//  KPLogger.m
//  LCProxyTweak
//

#import "KPLogger.h"
#import "KPSharedPaths.h"

static NSString *const KPLogDirName        = @"KingProxy";
static NSString *const KPLogSubdirName     = @"logs";
static NSString *const KPLogFilePrefix     = @"LCProxy-";
static NSString *const KPLogFileSuffix     = @".log";
static NSUInteger const KPLogMaxFiles      = 50;
static NSUInteger const KPLogMaxFallback   = 2000; // 单行内容截断，防误打大对象

NSString *KPLogLevelName(KPLogLevel level) {
    switch (level) {
        case KPLogLevelDebug: return @"DEBUG";
        case KPLogLevelInfo:  return @"INFO";
        case KPLogLevelWarn:  return @"WARN";
        case KPLogLevelError: return @"ERROR";
    }
    return @"?";
}

NSString *KPLogModuleName(KPLogModule module) {
    switch (module) {
        case KPLogModuleBoot:   return @"boot";
        case KPLogModuleConfig: return @"config";
        case KPLogModuleMode:   return @"mode";
        case KPLogModuleHook:   return @"hook";
        case KPLogModuleKing:   return @"king";
        case KPLogModuleTscore: return @"tscore";
        case KPLogModuleWeb:    return @"web";
        case KPLogModuleUpdate: return @"update";
        case KPLogModuleAuth:   return @"auth";
    }
    return @"?";
}

NSString *KPMaskGUID(NSString *guid) {
    if (guid.length <= 4) return [NSString stringWithFormat:@"%@****", guid];
    return [NSString stringWithFormat:@"%@****", [guid substringToIndex:4]];
}

NSString *KPMaskSecret(NSString *secret) {
    if (secret.length == 0) return @"(empty)";
    return [NSString stringWithFormat:@"<secret:%lu>", (unsigned long)secret.length];
}

NSString *KPMaskLongRuns(NSString *string) {
    if (!string.length) return @"";
    NSMutableString *out = [NSMutableString string];
    NSMutableString *run = [NSMutableString string];
    NSCharacterSet *alnum = [NSCharacterSet alphanumericCharacterSet];
    for (NSUInteger i = 0; i < string.length; i++) {
        unichar c = [string characterAtIndex:i];
        if ([alnum characterIsMember:c]) {
            [run appendFormat:@"%C", c];
        } else {
            if (run.length >= 10) {
                [out appendFormat:@"<run:%lu>", (unsigned long)run.length];
            } else {
                [out appendString:run];
            }
            [run setString:@""];
            [out appendFormat:@"%C", c];
        }
    }
    if (run.length >= 10) {
        [out appendFormat:@"<run:%lu>", (unsigned long)run.length];
    } else {
        [out appendString:run];
    }
    return out;
}

#pragma mark -

static NSUncaughtExceptionHandler *gPreviousExceptionHandler = NULL;
static void KPUncaughtExceptionHandler(NSException *exception);

@interface KPLogger ()
@property (nonatomic, strong) dispatch_queue_t ioQueue;
@property (nonatomic, strong) NSFileHandle *fileHandle;
@property (nonatomic, copy) NSString *filePath;
@property (nonatomic, strong) NSDateFormatter *fileNameFormatter;
@property (nonatomic, strong) NSISO8601DateFormatter *lineDateFormatter;
@property (nonatomic, strong) NSLock *stepLock;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *steps;
@end

@implementation KPLogger

@synthesize baseDirectory = _baseDirectory;

+ (instancetype)shared {
    static KPLogger *instance = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[KPLogger alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _ioQueue = dispatch_queue_create("lcproxy.kplogger.io", DISPATCH_QUEUE_SERIAL);
        _minLevel = KPLogLevelDebug;
        _debugMode = YES;
        _stepLock = [[NSLock alloc] init];
        _steps = [NSMutableArray array];

        NSDateFormatter *fn = [[NSDateFormatter alloc] init];
        fn.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        fn.dateFormat = @"yyyyMMdd-HHmmss-SSS";
        fn.timeZone = [NSTimeZone localTimeZone];
        _fileNameFormatter = fn;

        NSISO8601DateFormatter *ld = [[NSISO8601DateFormatter alloc] init];
        ld.formatOptions = NSISO8601DateFormatWithInternetDateTime |
                           NSISO8601DateFormatWithFractionalSeconds |
                           NSISO8601DateFormatWithColonSeparatorInTimeZone;
        _lineDateFormatter = ld;
    }
    return self;
}

- (NSString *)defaultBaseDirectory {
    return KPSharedRootDirectory(); // <LC Documents>，各模块自行追加 KingProxy/
}

- (void)setBaseDirectory:(NSString *)baseDirectory {
    _baseDirectory = [baseDirectory copy];
    _fileHandle = nil;
    _filePath = nil;
}

- (NSString *)baseDirectory {
    return _baseDirectory ?: [self defaultBaseDirectory];
}

- (NSString *)logsDirectory {
    return [self.baseDirectory stringByAppendingPathComponent:KPLogDirName];
}

- (void)rotateIfNeeded {
    // 建目录
    NSString *logsDir = [[self logsDirectory] stringByAppendingPathComponent:KPLogSubdirName];
    NSError *err = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:logsDir
                                  withIntermediateDirectories:YES attributes:nil error:&err]) {
        NSLog(@"[KPLogger] create logs dir failed: %@", err);
        return;
    }
    // 列出已有日志文件，按文件名（时间序）排序
    NSArray<NSString *> *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:logsDir error:nil];
    NSMutableArray<NSString *> *logs = [NSMutableArray array];
    for (NSString *name in files) {
        if ([name hasPrefix:KPLogFilePrefix] && [name hasSuffix:KPLogFileSuffix]) {
            [logs addObject:name];
        }
    }
    [logs sortUsingSelector:@selector(compare:)];
    // 超过 50 个：从最旧删到 <50
    while (logs.count >= KPLogMaxFiles) {
        NSString *oldest = logs.firstObject;
        NSString *path = [logsDir stringByAppendingPathComponent:oldest];
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        [logs removeObjectAtIndex:0];
    }
    // 新文件
    NSString *name = [NSString stringWithFormat:@"%@%@%@",
                      KPLogFilePrefix,
                      [self.fileNameFormatter stringFromDate:[NSDate date]],
                      KPLogFileSuffix];
    NSString *path = [logsDir stringByAppendingPathComponent:name];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
    }
    _filePath = path;
    _fileHandle = [NSFileHandle fileHandleForWritingAtPath:path];
    [_fileHandle seekToEndOfFile];
}

- (void)setDebugMode:(BOOL)debugMode {
    _debugMode = debugMode;
    if (debugMode) {
        self.minLevel = KPLogLevelDebug;
    }
}

#pragma mark - 逐步验证

static NSUInteger const KPStepsMax = 200;

- (void)stepCheckModule:(KPLogModule)module
                   name:(NSString *)name
                     ok:(BOOL)ok
                 format:(NSString *)format, ... {
    va_list args;
    va_start(args, format);
    NSString *detail = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSDictionary *entry = @{
        @"t": [self.lineDateFormatter stringFromDate:[NSDate date]] ?: @"",
        @"module": KPLogModuleName(module),
        @"name": name ?: @"",
        @"ok": @(ok),
        @"detail": detail ?: @"",
    };
    [self.stepLock lock];
    [self.steps addObject:entry];
    if (self.steps.count > KPStepsMax) {
        [self.steps removeObjectsInRange:NSMakeRange(0, self.steps.count - KPStepsMax)];
    }
    [self.stepLock unlock];

    NSString *mark = ok ? @"✓" : @"✗";
    [self logWithLevel:ok ? KPLogLevelInfo : KPLogLevelError
                module:module
                format:@"STEP %@ %@: %@", mark, name, detail];
    if (self.debugMode) {
        NSLog(@"[KPSTEP] %@ %@ %@: %@", mark, KPLogModuleName(module), name, detail);
    }
}

- (NSArray<NSDictionary *> *)recentSteps {
    [self.stepLock lock];
    NSArray *copy = [self.steps copy];
    [self.stepLock unlock];
    return copy;
}

- (void)resetSteps {
    [self.stepLock lock];
    [self.steps removeAllObjects];
    [self.stepLock unlock];
}

- (void)logWithLevel:(KPLogLevel)level
              module:(KPLogModule)module
              format:(NSString *)format, ... {
    if (level < self.minLevel) return;
    va_list args;
    va_start(args, format);
    NSString *body = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (body.length > KPLogMaxFallback) {
        body = [body substringToIndex:KPLogMaxFallback];
    }

    // NSDateFormatter 非线程安全：tscore 回调线程并发打日志时需加锁
    NSString *ts;
    @synchronized (self) {
        ts = [self.lineDateFormatter stringFromDate:[NSDate date]];
    }
    NSString *line = [NSString stringWithFormat:@"%@ [%@] [%@] %@\n",
                      ts,
                      KPLogLevelName(level),
                      KPLogModuleName(module),
                      body];

    dispatch_async(self.ioQueue, ^{
        if (self.fileHandle == nil) {
            [self rotateIfNeeded];
        }
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        @try {
            [self.fileHandle writeData:data];
        } @catch (NSException *e) {
            NSLog(@"[KPLogger] write failed: %@", e);
            self.fileHandle = nil; // 下次重新打开
        }
    });

    // 镜像到控制台（调试模式全部镜像；否则 WARN/ERROR）
    if (self.debugMode || level >= KPLogLevelWarn) {
        NSLog(@"[%@][%@] %@", KPLogLevelName(level), KPLogModuleName(module), body);
    }
}

- (void)logTscoreMessage:(NSString *)message {
    [self logWithLevel:KPLogLevelInfo module:KPLogModuleTscore format:@"%@", message ?: @""];
}

- (NSString *)currentLogFilePath {
    return _filePath;
}

+ (void)installCrashHandler {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gPreviousExceptionHandler = NSGetUncaughtExceptionHandler();
        NSSetUncaughtExceptionHandler(&KPUncaughtExceptionHandler);
    });
}

static void KPUncaughtExceptionHandler(NSException *exception) {
    @autoreleasepool {
        KPLogger *logger = [KPLogger shared];
        // 同步写一条 ERROR（绕过异步队列，尽力而为）
        NSString *line = [NSString stringWithFormat:@"UNCAUGHT EXCEPTION: %@\n%@\n%@",
                          exception.name, exception.reason, exception.callStackSymbols];
        NSString *path = [logger currentLogFilePath];
        if (path) {
            NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
            [[NSFileHandle fileHandleForWritingAtPath:path] seekToEndOfFile];
            @try { [[NSFileHandle fileHandleForWritingAtPath:path] writeData:data]; } @catch (NSException *e) {}
        }
        NSLog(@"[KPLogger] %@", line);
    }
    if (gPreviousExceptionHandler) {
        gPreviousExceptionHandler(exception);
    }
}

@end
