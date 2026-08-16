//
//  ViewController.m
//  LCProxyConsole
//
//  全屏 WKWebView → http://127.0.0.1:19092。
//  服务未就绪时显示提示并每 2 秒自动重试，直到首次加载成功。
//

#import "ViewController.h"
#import <WebKit/WebKit.h>

static NSString *const KPCConsoleURL = @"http://127.0.0.1:19092/";

@interface ViewController () <WKNavigationDelegate>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) UIView *errorView;
@property (nonatomic, strong) UILabel *errorLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, assign) BOOL loadedOnce;
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
    [self loadConsole];
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

    self.errorLabel = [[UILabel alloc] initWithFrame:CGRectMake(24, 0, CGRectGetWidth(self.view.bounds) - 48, 120)];
    self.errorLabel.center = CGPointMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds) + 20);
    self.errorLabel.textAlignment = NSTextAlignmentCenter;
    self.errorLabel.numberOfLines = 0;
    self.errorLabel.textColor = [UIColor colorWithWhite:0.75 alpha:1];
    self.errorLabel.font = [UIFont systemFontOfSize:15];
    self.errorLabel.text = @"正在连接控制台 127.0.0.1:19092 …\n请保持 LiveContainer 在前台";
    [self.errorView addSubview:self.errorLabel];
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
    self.errorLabel.text = [NSString stringWithFormat:@"无法连接 127.0.0.1:19092\n%@\n2 秒后自动重试…", error.localizedDescription];
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
