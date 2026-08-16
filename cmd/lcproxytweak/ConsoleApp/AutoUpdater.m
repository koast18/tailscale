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

@implementation AutoUpdater

// 诊断记录：每次网络尝试的 URL / 状态码 / 错误，失败时随错误信息上屏
static NSMutableString *gDiag = nil;

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

+ (BOOL)downloadAsset:(NSString *)assetName toPath:(NSString *)dst {
    NSString *browser = [self assetDownloadURL:assetName];
    if (!browser) return NO;
    // 镜像 → 直连
    NSArray *urls = @[
        [NSString stringWithFormat:@"%@%@", KPAutoUpdateMirrorPrefix, browser],
        browser,
    ];
    NSData *data = [self fetchFirstSuccess:urls];
    if (!data) return NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:dst error:nil];
    return [data writeToFile:dst atomically:YES];
}

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

/// 自动更新入口：返回状态描述（无网络时返回 nil）
+ (nullable NSString *)runAutoUpdate {
    [self resetDiagnostics];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = [self lcRootDirectory];
    if (!root.length) return @"无法定位 LiveContainer 目录";

    NSString *tweaksDir = [root stringByAppendingPathComponent:@"Tweaks"];
    NSString *kingDir = [root stringByAppendingPathComponent:@"KingProxy"];
    [fm createDirectoryAtPath:tweaksDir withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtPath:kingDir withIntermediateDirectories:YES attributes:nil error:nil];
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
        if ([self downloadAsset:tweakName toPath:tweakDst]) {
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
        if ([self downloadAsset:coreName toPath:coreDst]) {
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

    NSString *summary = [steps componentsJoinedByString:@"\n"];
    return [NSString stringWithFormat:@"✅ %@\n\n两个 dylib 均已放入 Tweaks/（版本化文件名）：LiveContainer 检测到无签名会自动用你导入的证书重签。请退出 App 重新打开（或重启 LiveContainer）使 tweak 生效。", summary];
}

@end
