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

@implementation AutoUpdater

+ (NSString *)lcRootDirectory {
    const char *home = getenv("LC_HOME_PATH");
    if (home && home[0]) {
        return [NSString stringWithUTF8String:home];
    }
    // 回退：本 app 的 Documents（非 LC 环境时仅用于测试）
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return paths.firstObject ?: NSHomeDirectory();
}

+ (NSString *)latestReleaseTag {
    NSURL *url = [NSURL URLWithString:
        [NSString stringWithFormat:@"https://api.github.com/repos/%@/releases/latest", KPAutoUpdateRepo]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 20;
    [req setValue:@"LCProxyConsole/1.0" forHTTPHeaderField:@"User-Agent"];
    NSHTTPURLResponse *resp = nil;
    NSData *data = [NSURLConnection sendSynchronousRequest:req
                                         returningResponse:&resp error:nil];
    if (!data || resp.statusCode != 200) return nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) return nil;
    NSString *tag = json[@"tag_name"];
    return tag.length ? tag : nil;
}

+ (BOOL)downloadAsset:(NSString *)assetName toPath:(NSString *)dst {
    NSURL *url = [NSURL URLWithString:
        [NSString stringWithFormat:@"https://github.com/%@/releases/latest/download/%@",
                                   KPAutoUpdateRepo, assetName]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 300; // core 20MB
    [req setValue:@"LCProxyConsole/1.0" forHTTPHeaderField:@"User-Agent"];
    NSHTTPURLResponse *resp = nil;
    NSData *data = [NSURLConnection sendSynchronousRequest:req
                                         returningResponse:&resp error:nil];
    if (!data || resp.statusCode != 200) {
        return NO;
    }
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
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = [self lcRootDirectory];
    if (!root.length) return @"无法定位 LiveContainer 目录";

    NSString *tweaksDir = [root stringByAppendingPathComponent:@"Tweaks"];
    NSString *kingDir = [root stringByAppendingPathComponent:@"KingProxy"];
    [fm createDirectoryAtPath:tweaksDir withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtPath:kingDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *tag = [self latestReleaseTag];
    if (!tag.length) return @"获取最新版本失败（网络/API）";

    NSMutableArray *steps = [NSMutableArray array];

    // 1) tweak → Tweaks/（LiveContainer 强制签名后由 TweakLoader 加载）
    NSString *tweakName = [NSString stringWithFormat:@"%@%@.dylib", KPAutoUpdateTweakNamePrefix, tag];
    NSString *tweakDst = [tweaksDir stringByAppendingPathComponent:tweakName];
    BOOL needTweak = ![fm fileExistsAtPath:tweakDst];
    if (needTweak) {
        if ([self downloadAsset:tweakName toPath:tweakDst]) {
            [steps addObject:[NSString stringWithFormat:@"tweak %@ 已下载", tag]];
        } else {
            return [NSString stringWithFormat:@"下载 tweak 失败: %@", tweakName];
        }
    } else {
        [steps addObject:[NSString stringWithFormat:@"tweak %@ 已存在", tag]];
    }

    // 2) core → KingProxy/（版本源；Tweaks/ 副本由 tweak 侧在签名后同步）
    NSString *coreName = [NSString stringWithFormat:@"%@%@.dylib", KPAutoUpdateCoreNamePrefix, tag];
    NSString *coreDst = [kingDir stringByAppendingPathComponent:coreName];
    BOOL needCore = ![fm fileExistsAtPath:coreDst];
    if (needCore) {
        if ([self downloadAsset:coreName toPath:coreDst]) {
            [steps addObject:[NSString stringWithFormat:@"core %@ 已下载", tag]];
        } else {
            return [NSString stringWithFormat:@"下载 core 失败: %@", coreName];
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
    NSArray *oldCore = [self existingVersionedFilesIn:kingDir prefix:KPAutoUpdateCoreNamePrefix
                                                 keep:coreName];
    for (NSString *p in oldCore) {
        [fm removeItemAtPath:p error:nil];
        [steps addObject:[NSString stringWithFormat:@"清理旧 core %@", p.lastPathComponent]];
    }

    NSString *summary = [steps componentsJoinedByString:@"\n"];
    return [NSString stringWithFormat:@"✅ %@\n\n请到 LiveContainer「设置 → 签名证书」确保证书已导入，然后对 Tweaks 强制签名一次并重启 App 使 tweak 生效。", summary];
}

@end
