//
//  KPSharedPaths.m
//  LCProxyTweak
//

#import "KPSharedPaths.h"
#import <dlfcn.h>

NSString *KPSharedRootFromTweakPath(NSString *tweakPath) {
    if (!tweakPath.length) return nil;
    NSString *dir = [tweakPath stringByDeletingLastPathComponent]; // 去掉 dylib 文件名
    // .framework/.app 形态：二进制在目录内，再上一层
    NSString *base = [dir lastPathComponent];
    if ([base hasSuffix:@".framework"] || [base hasSuffix:@".app"]) {
        dir = [dir stringByDeletingLastPathComponent];
    }
    // 全局 tweak 目录（TweakLoader 的 LC_GLOBAL_TWEAKS_FOLDER = <LC Documents>/Tweaks）
    if ([[dir lastPathComponent] isEqualToString:@"Tweaks"]) {
        dir = [dir stringByDeletingLastPathComponent]; // = LC Documents
    }
    return dir;
}

NSString *KPSharedRootDirectory(void) {
    // 用本函数自身地址做 dladdr：任何位于 LCProxyTweak.dylib 内的符号都行，
    // 能拿到该 image 的绝对路径（TweakLoader 用绝对路径 dlopen）。
    // 宿主测试二进制里也会解析到测试可执行文件自身（无害，测试均显式覆盖 baseDirectory）。
    Dl_info info;
    if (dladdr((const void *)&KPSharedRootDirectory, &info) &&
        info.dli_fname && info.dli_fname[0]) {
        NSString *root = KPSharedRootFromTweakPath([NSString stringWithUTF8String:info.dli_fname]);
        if (root.length) {
            return root;
        }
    }
    // 回退：当前进程 Documents
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return paths.count > 0 ? paths[0] : NSHomeDirectory();
}
