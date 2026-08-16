//
//  ViewController.m
//  LCProxyConsole
//
//  全屏 WKWebView → http://127.0.0.1:19092。
//  服务未就绪时显示提示并每 2 秒自动重试，直到首次加载成功。
//

#import "ViewController.h"
#import "AutoUpdater.h"
#import <WebKit/WebKit.h>

static NSString *const KPCConsoleURL = @"http://127.0.0.1:19092/";

@interface ViewController () <WKNavigationDelegate>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) UIView *errorView;
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong) UIButton *logCopyButton;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, assign) BOOL loadedOnce;
@property (nonatomic, copy) NSString *lastFullLog;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];

    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    self.webView = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:config];
    self.webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.webView.navigationDelegate = self;
    self.webView.scrollView.bounces = NO;
    [self.view addSubview:self.webView];

    [self setupErrorView];

    // 阶段一：初始化（自动下载两个 dylib）。完成之前不连接 19092 ——
    // tweak 未就绪时连控制台没有意义，且错误信息会被冲掉。
    [self startAutoUpdate];
}

- (void)startAutoUpdate {
    self.errorView.hidden = NO;
    [self showLog:@"正在初始化（下载两个 dylib）…\n请保持 LiveContainer 在前台"];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *result = [AutoUpdater runAutoUpdateWithProgress:^(NSString *stage, double fraction) {
            NSString *line = stage;
            if (fraction >= 0) line = [NSString stringWithFormat:@"%@ %.0f%%", stage, fraction * 100];
            [self showLog:line];
        }];
        BOOL downloaded = [AutoUpdater downloadedAnything];
        BOOL failed = result.length > 0 && [result containsString:@"失败"];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.errorView.hidden = NO;
            self.spinner.hidden = YES;
            if (failed || downloaded) {
                // 下载完成（或失败）：全量信息上屏，不连 19092，等用户重启
                NSString *msg = result ?: @"（无输出）";
                if (!failed) {
                    msg = [msg stringByAppendingString:@"\n\n请退出 App 重新打开（或重启 LiveContainer），tweak 签名生效后自动进入控制台。"];
                }
                [self showLog:msg];
            } else {
                // 两个 dylib 都已存在（重启后的再次打开）：直接连控制台
                [self showLog:@"正在连接控制台 127.0.0.1:19092 …"];
                [self loadConsole];
            }
        });
    });
}

// 追加一行日志到可滚动视图（长日志不会被截断），并更新复制缓存
- (void)showLog:(NSString *)line {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.lastFullLog = line;
        self.logView.text = line;
        [self.logView scrollRangeToVisible:NSMakeRange(self.logView.text.length, 0)];
    });
}

- (void)copyLog {
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    pb.string = self.lastFullLog ?: @"";
    [self.logCopyButton setTitle:@"已复制 ✓" forState:UIControlStateNormal];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [self.logCopyButton setTitle:@"📋 复制日志" forState:UIControlStateNormal];
    });
}

- (void)setupErrorView {
    self.errorView = [[UIView alloc] initWithFrame:self.view.bounds];
    self.errorView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.errorView.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1];
    self.errorView.hidden = YES;

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.spinner.color = [UIColor whiteColor];
    self.spinner.center = CGPointMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds) - 60);
    [self.errorView addSubview:self.spinner];
    [self.spinner startAnimating];

    // 可滚动日志（UITextView）：长诊断不截断，可选中复制
    self.logView = [[UITextView alloc] initWithFrame:CGRectMake(20, 60, CGRectGetWidth(self.view.bounds) - 40,
                                                              CGRectGetHeight(self.view.bounds) - 140)];
    self.logView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.logView.backgroundColor = [UIColor clearColor];
    self.logView.textColor = [UIColor colorWithWhite:0.85 alpha:1];
    self.logView.font = [UIFont systemFontOfSize:14];
    self.logView.editable = NO;
    self.logView.selectable = YES;
    [self.errorView addSubview:self.logView];

    // 复制日志按钮
    self.logCopyButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.logCopyButton.frame = CGRectMake(20, CGRectGetHeight(self.view.bounds) - 56, 140, 40);
    self.logCopyButton.autoresizingMask = UIViewAutoresizingFlexibleTopMargin;
    [self.logCopyButton setTitle:@"📋 复制日志" forState:UIControlStateNormal];
    self.logCopyButton.titleLabel.font = [UIFont systemFontOfSize:15];
    [self.logCopyButton addTarget:self action:@selector(copyLog) forControlEvents:UIControlEventTouchUpInside];
    [self.errorView addSubview:self.logCopyButton];
    [self.view addSubview:self.errorView];
}

- (void)loadConsole {
    if (self.loadedOnce) return;
    NSURLRequest *req = [NSURLRequest requestWithURL:[NSURL URLWithString:KPCConsoleURL]
                                         cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                     timeoutInterval:5];
    [self.webView loadRequest:req];
}

// 首次加载失败 → 提示 + 2 秒后重试（服务可能还没起来）
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    if (self.loadedOnce) return;
    self.errorView.hidden = NO;
    [self showLog:[NSString stringWithFormat:@"无法连接 127.0.0.1:19092\n%@\n2 秒后自动重试…", error.localizedDescription]];
    [self performSelector:@selector(loadConsole) withObject:nil afterDelay:2.0];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    self.loadedOnce = YES;
    self.errorView.hidden = YES;
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    // 已加载过则静默（可能只是瞬时断连），下次操作自动恢复
}

@end
