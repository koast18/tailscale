//
//  AutoUpdater.m
//  LCProxyConsole
//
//  安装 IPA 后打开 App 即自动从 GitHub Release 下载两个 dylib：
//    - LCProxyTweak-<tag>.dylib        → <LC Documents>/Tweaks/   （LiveContainer TweakLoader 加载）
//    - libTailscaleCore-<tag>.dylib    → <LC Documents>/KingProxy/ （tweak 的 KPTsCore 加载）
//  文件名带版本号（GitHub Release 资产名即版本号）；下载完成后清理同前缀旧版本，
//  保证 LiveContainer 里只有一个 tweak 实例。
//
//  定位 LC Documents：LiveContainer 把 LC 数据根暴露为环境变量 LC_HOME_PATH
//  （<LC Documents> 即其值）。tweak/console 共享目录均在其下。
//

#import "AutoUpdater.h"

static NSString *const KPAutoUpdateRepo = @"koast18/tailscale";
static NSString *const KPAutoUpdateCoreNamePrefix = @"libTailscaleCore-";
static NSString *const KPAutoUpdateTweakNamePrefix = @"LCProxyTweak-";
// 镜像优先（中国大陆网络无法直连 GitHub 时可用），失败回退官方直连
static NSString *const KPAutoUpdateMirrorPrefix = @"https://gh-proxy.com/";

@interface _KPDownloadDelegate : NSObject <NSURLSessionDataDelegate>
@property (nonatomic, copy) void (^onProgress)(double);
@property (nonatomic, copy) void (^onComplete)(NSError *);
@property (nonatomic, strong) NSMutableData *acc;
@property (nonatomic, assign) int64_t expected;
@property (nonatomic, strong) NSHTTPURLResponse *httpResponse;
@end

@implementation _KPDownloadDelegate
- (instancetype)init {
    if ((self = [super init])) {
        _acc = [NSMutableData data];
        _expected = -1;
    }
    return self;
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task
    didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    self.httpResponse = (NSHTTPURLResponse *)response;
    self.expected = response.expectedContentLength;
    completionHandler(NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    [self.acc appendData:data];
    if (self.onProgress && self.expected > 0) {
        self.onProgress(MIN(1.0, (double)self.acc.length / (double)self.expected));
    }
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (self.onComplete) self.onComplete(error);
}
@end

@implementation AutoUpdater
// NSURLSession dataTask 同步封装：真实进度（received/total）经 progress 回调
+ (NSData *)downloadSynchronous:(NSString *)urlString progress:(void (^)(double))progress {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) { [self diag:@"[跳过] 非法 URL: %@", urlString]; return nil; }
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.timeoutIntervalForResource = 600;
    _KPDownloadDelegate *dlg = [[_KPDownloadDelegate alloc] init];
    dlg.onProgress = progress;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg delegate:dlg
                                                     delegateQueue:[NSOperationQueue new]];
    dlg.onComplete = ^(NSError *err) {
        [session finishTasksAndInvalidate];
        dispatch_semaphore_signal(sem);
    };
    NSURLSessionDataTask *task = [session dataTaskWithURL:url];
    [task resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 600 * NSEC_PER_SEC));
    NSData *result = dlg.acc.length ? [dlg.acc copy] : nil;
    NSInteger code = dlg.httpResponse.statusCode;
    if (!result) {
        [self diag:@"[%@] 连接失败（无数据）", urlString];
    } else if (code == 200) {
        [self diag:@"[%@] HTTP 200, %ld bytes ✓", urlString, (long)result.length];
    } else {
        [self diag:@"[%@] HTTP %ld", urlString, (long)code];
    }
    return result;
}


// 诊断记录：每次网络尝试的 URL / 状态码 / 错误，失败时随错误信息上屏
static NSMutableString *gDiag = nil;
static BOOL gDownloadedNew = NO;

+ (BOOL)downloadedAnything {
    return gDownloadedNew;
}

+ (void)diag:(NSString *)fmt, ... {
    if (!gDiag) gDiag = [NSMutableString string];
    va_list args;
    va_start(args, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    [gDiag appendFormat:@"%@\n", s];
}

+ (NSString *)diagnostics {
    return gDiag ?: @"";
}

+ (void)resetDiagnostics {
    gDiag = nil;
}

+ (NSString *)lcRootDirectory {
    const char *home = getenv("LC_HOME_PATH");
    if (home && home[0]) {
        return [NSString stringWithUTF8String:home];
    }
    // 回退：本 app 的 Documents（非 LC 环境时仅用于测试）
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return paths.firstObject ?: NSHomeDirectory();
}

// 依次尝试多个 URL，返回第一个 200 响应体（镜像优先，直连兜底）；失败原因记录到诊断
+ (NSData *)fetchFirstSuccess:(NSArray<NSString *> *)urlStrings {
    for (NSString *u in urlStrings) {
        NSURL *url = [NSURL URLWithString:u];
        if (!url) { [self diag:@"[跳过] 非法 URL: %@", u]; continue; }
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
        req.timeoutInterval = 90;
        [req setValue:@"LCProxyConsole/1.0" forHTTPHeaderField:@"User-Agent"];
        NSHTTPURLResponse *resp = nil;
        NSError *err = nil;
        NSData *data = [NSURLConnection sendSynchronousRequest:req
                                             returningResponse:&resp error:&err];
        if (err) {
            [self diag:@"[%@] 连接错误: %@ (%ld)", u, err.localizedDescription ?: @"?", (long)err.code];
        } else if (resp.statusCode == 200 && data) {
            [self diag:@"[%@] HTTP 200, %ld bytes ✓", u, (long)data.length];
            return data;
        } else {
            [self diag:@"[%@] HTTP %ld (%ld bytes)", u, (long)resp.statusCode,
                            (long)data.length];
        }
    }
    return nil;
}

+ (NSString *)latestReleaseTag {
    // 镜像 → 直连，谁先 200 用谁
    NSData *data = [self apiLatestRelease];
    if (!data) return nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) return nil;
    NSString *tag = json[@"tag_name"];
    return tag.length ? tag : nil;
}

// api.github.com releases/latest 响应体（镜像优先）
+ (NSData *)apiLatestRelease {
    NSArray *urls = @[
        [NSString stringWithFormat:@"%@https://api.github.com/repos/%@/releases/latest",
                                   KPAutoUpdateMirrorPrefix, KPAutoUpdateRepo],
        [NSString stringWithFormat:@"https://api.github.com/repos/%@/releases/latest",
                                   KPAutoUpdateRepo],
    ];
    return [self fetchFirstSuccess:urls];
}

// 从 latest release 的 assets 里找指定资产名 → browser_download_url（github.com/releases/download/...，可整体走镜像，无 302 链）
+ (NSString *)assetDownloadURL:(NSString *)assetName {
    NSData *data = [self apiLatestRelease];
    if (!data) return nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) {
        NSString *preview = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        [self diag:@"[解析] API 响应不是 JSON: %@", preview.length > 300 ? [preview substringToIndex:300] : preview];
        return nil;
    }
    NSArray *assets = json[@"assets"];
    if (![assets isKindOfClass:[NSArray class]]) {
        [self diag:@"[解析] API 响应缺 assets 字段 (tag=%@)", json[@"tag_name"]];
        return nil;
    }
    NSMutableArray *names = [NSMutableArray array];
    for (NSDictionary *a in assets) {
        if ([a[@"name"] isEqualToString:assetName]) {
            NSString *url = a[@"browser_download_url"];
            [self diag:@"[资产] 找到 %@ → %@", assetName, url ?: @"(无 URL)"];
            return url.length ? url : nil;
        }
        [names addObject:a[@"name"] ?: @"?"];
    }
    [self diag:@"[资产] 未找到 %@；实际资产: %@", assetName, [names componentsJoinedByString:@", "]];
    return nil;
}

+ (BOOL)downloadAsset:(NSString *)assetName toPath:(NSString *)dst
           progress:(void (^)(double))progress {
    NSString *browser = [self assetDownloadURL:assetName];
    if (!browser) return NO;
    // 镜像 → 直连
    NSArray *urls = @[
        [NSString stringWithFormat:@"%@%@", KPAutoUpdateMirrorPrefix, browser],
        browser,
    ];
    for (NSString *u in urls) {
        NSData *data = [self downloadSynchronous:u progress:progress];
        if (data) {
            NSFileManager *fm = [NSFileManager defaultManager];
            [fm removeItemAtPath:dst error:nil];
            NSError *werr = nil;
            BOOL ok = [data writeToFile:dst options:NSDataWritingAtomic error:&werr];
            if (ok) return YES;
            [self diag:@"[写入] 失败 %@: %@ (err=%ld)", dst,
                            werr.localizedDescription ?: @"未知错误", (long)werr.code];
            // 回退：写入本 app Documents（至少保住文件，供人工拷贝）
            NSString *fb = [[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
                             stringByAppendingPathComponent:@"KingProxy"]
                            stringByAppendingPathComponent:dst.lastPathComponent];
            [fm createDirectoryAtPath:[fb stringByDeletingLastPathComponent]
                  withIntermediateDirectories:YES attributes:nil error:nil];
            NSError *fberr = nil;
            if ([data writeToFile:fb options:NSDataWritingAtomic error:&fberr]) {
                [self diag:@"[写入] 已回退写入: %@", fb];
                return NO; // 未落位到 Tweaks/，视为失败并暴露诊断
            }
            [self diag:@"[写入] 回退也失败: %@ (err=%ld)", fberr.localizedDescription ?: @"?", (long)fberr.code];
        }
    }
    return NO;
}

// NSURLSession dataTask 进度代理：累计已收字节 / 预期总长 → 进度回调
+ (NSArray<NSString *> *)existingVersionedFilesIn:(NSString *)dir prefix:(NSString *)prefix
                                            keep:(NSString *)keepName {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *names = [fm contentsOfDirectoryAtPath:dir error:nil];
    NSMutableArray *remove = [NSMutableArray array];
    for (NSString *n in names) {
        if ([n hasPrefix:prefix] && [n hasSuffix:@".dylib"] && ![n isEqualToString:keepName]) {
            [remove addObject:[dir stringByAppendingPathComponent:n]];
        }
    }
    return remove;
}

/// 自动更新入口：返回状态描述（含完整诊断）；progress 在主线程回调
+ (nullable NSString *)runAutoUpdate {
    return [self runAutoUpdateWithProgress:nil];
}

+ (nullable NSString *)runAutoUpdateWithProgress:(KPAutoUpdateProgress)progress {
    [self resetDiagnostics];
    gDownloadedNew = NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = [self lcRootDirectory];
    if (!root.length) return @"无法定位 LiveContainer 目录";

    NSString *tweaksDir = [root stringByAppendingPathComponent:@"Tweaks"];
    NSString *kingDir = [root stringByAppendingPathComponent:@"KingProxy"];
    NSError *dErr1 = nil, *dErr2 = nil;
    [fm createDirectoryAtPath:tweaksDir withIntermediateDirectories:YES attributes:nil error:&dErr1];
    [fm createDirectoryAtPath:kingDir withIntermediateDirectories:YES attributes:nil error:&dErr2];
    [self diag:@"[路径] root=%@", root];
    if (dErr1) [self diag:@"[路径] 创建 Tweaks 失败: %@", dErr1.localizedDescription ?: @"?"];
    if (dErr2) [self diag:@"[路径] 创建 KingProxy 失败: %@", dErr2.localizedDescription ?: @"?"];

    void (^emit)(NSString *, double) = ^(NSString *stage, double f) {
        if (progress) dispatch_async(dispatch_get_main_queue(), ^{ progress(stage, f); });
    };

    emit(@"获取最新版本…", -1);
    NSString *tag = [self latestReleaseTag];
    if (!tag.length) {
        return [NSString stringWithFormat:@"获取最新版本失败\n\n%@", [self diagnostics]];
    }

    NSMutableArray *steps = [NSMutableArray array];

    // 1) tweak → Tweaks/（LiveContainer 检测到无签名会自动用用户证书 ZSign 重签，
    //    然后由 TweakLoader 加载）
    NSString *tweakName = [NSString stringWithFormat:@"%@%@.dylib", KPAutoUpdateTweakNamePrefix, tag];
    NSString *tweakDst = [tweaksDir stringByAppendingPathComponent:tweakName];
    BOOL needTweak = ![fm fileExistsAtPath:tweakDst];
    if (needTweak) {
        emit(@"下载 tweak…", 0);
        if ([self downloadAsset:tweakName toPath:tweakDst
                       progress:^(double f) { emit(@"下载 tweak…", f); }]) {
            gDownloadedNew = YES;
            [steps addObject:[NSString stringWithFormat:@"tweak %@ 已下载", tag]];
        } else {
            return [NSString stringWithFormat:@"下载 tweak 失败: %@\n\n%@", tweakName, [self diagnostics]];
        }
    } else {
        [steps addObject:[NSString stringWithFormat:@"tweak %@ 已存在", tag]];
    }

    // 2) core → 同样放 Tweaks/（未签名无法 dlopen；与 tweak 一起被 LC 签名，
    //    KPTsCore 扫描 Tweaks/libTailscaleCore-*.dylib 取最新版本加载）
    NSString *coreName = [NSString stringWithFormat:@"%@%@.dylib", KPAutoUpdateCoreNamePrefix, tag];
    NSString *coreDst = [tweaksDir stringByAppendingPathComponent:coreName];
    BOOL needCore = ![fm fileExistsAtPath:coreDst];
    if (needCore) {
        emit(@"下载 core（19.8MB）…", 0);
        if ([self downloadAsset:coreName toPath:coreDst
                       progress:^(double f) { emit(@"下载 core（19.8MB）…", f); }]) {
            gDownloadedNew = YES;
            [steps addObject:[NSString stringWithFormat:@"core %@ 已下载", tag]];
        } else {
            return [NSString stringWithFormat:@"下载 core 失败: %@\n\n%@", coreName, [self diagnostics]];
        }
    } else {
        [steps addObject:[NSString stringWithFormat:@"core %@ 已存在", tag]];
    }

    // 3) 清理旧版本（Tweaks 下必须只留当前版 tweak，避免 TweakLoader 重复加载）
    NSArray *oldTweak = [self existingVersionedFilesIn:tweaksDir prefix:KPAutoUpdateTweakNamePrefix
                                                  keep:tweakName];
    for (NSString *p in oldTweak) {
        [fm removeItemAtPath:p error:nil];
        [steps addObject:[NSString stringWithFormat:@"清理旧 tweak %@", p.lastPathComponent]];
    }
    NSArray *oldCore = [self existingVersionedFilesIn:tweaksDir prefix:KPAutoUpdateCoreNamePrefix
                                                 keep:coreName];
    for (NSString *p in oldCore) {
        [fm removeItemAtPath:p error:nil];
        [steps addObject:[NSString stringWithFormat:@"清理旧 core %@", p.lastPathComponent]];
    }

    emit(@"完成", 1);
    NSString *summary = [steps componentsJoinedByString:@"\n"];
    return [NSString stringWithFormat:@"✅ %@\n\n两个 dylib 均已放入 Tweaks/（版本化文件名）：LiveContainer 检测到无签名会自动用你导入的证书重签。请退出 App 重新打开（或重启 LiveContainer）使 tweak 生效。", summary];
}

@end
