//
//  test_main.m
//  LCProxyTweak host tests（macOS，CI 运行）
//
//  覆盖：KPLogger（文件/轮换/打码）、KPKIngCore 纯函数、KPModeController 状态机。
//

#import <Foundation/Foundation.h>
#import "KPLogger.h"
#import "KPConfig.h"
#import "KPModeController.h"
#import "KPKingForwarder.h"
#import "KPTsCore.h"
#import "KPKIngCore.h"
#import "KPSharedPaths.h"
#import "KPHookManager.h"
#import "KPSocketHook.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <sys/socket.h>
#include <unistd.h>
#include <zlib.h>

static int gFailed = 0;
static int gPassed = 0;

#define CHECK(cond, name, ...) do { \
    if (cond) { gPassed++; printf("  ✓ %s\n", name); } \
    else { gFailed++; printf("  ✗ %s : ", name); \
          printf("" __VA_ARGS__); \
          printf("\n"); } \
} while (0)

static NSString *TempDir(void) {
    NSString *d = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
    [[NSFileManager defaultManager] createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}

static void TestMasks(void) {
    printf("[KPLogger] 打码\n");
    CHECK([KPMaskGUID(@"abcdef12") isEqualToString:@"abcd****"], "GUID 前4位+****");
    CHECK([KPMaskGUID(@"ab") isEqualToString:@"ab****"], "GUID 短串");
    CHECK([KPMaskSecret(@"xyz") isEqualToString:@"<secret:3>"], "TOKEN 只显示长度");
    CHECK([KPMaskSecret(@"") isEqualToString:@"(empty)"], "空串");
}

static void TestLoggerFileAndRotation(void) {
    printf("[KPLogger] 文件与轮换\n");
    NSString *base = TempDir();
    KPLogger *log = [KPLogger shared];
    log.baseDirectory = base;
    log.debugMode = NO;

    // 预置 55 个旧日志文件（覆盖 50 上限）
    NSString *logsDir = [base stringByAppendingPathComponent:@"KingProxy/logs"];
    [[NSFileManager defaultManager] createDirectoryAtPath:logsDir withIntermediateDirectories:YES attributes:nil error:nil];
    for (int i = 0; i < 55; i++) {
        NSString *name = [NSString stringWithFormat:@"LCProxy-202501%02d-000000-000.log", i + 1];
        [[NSFileManager defaultManager] createFileAtPath:[logsDir stringByAppendingPathComponent:name]
                                                contents:[@"old\n" dataUsingEncoding:NSUTF8StringEncoding] attributes:nil];
    }

    // 触发首次写入（内部会 rotateIfNeeded：删到 <50 再建新文件）
    [log logWithLevel:KPLogLevelInfo module:KPLogModuleBoot format:@"测试启动"];
    // 等 IO 队列写完
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];

    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:logsDir error:nil];
    NSUInteger logCount = 0;
    for (NSString *f in files) if ([f hasPrefix:@"LCProxy-"] && [f hasSuffix:@".log"]) logCount++;
    CHECK(logCount == 50, "轮换后恰 50 个文件", "got=%lu", (unsigned long)logCount);

    NSString *cur = log.currentLogFilePath;
    CHECK(cur.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:cur], "当前日志文件存在");
    NSString *content = [NSString stringWithContentsOfFile:cur encoding:NSUTF8StringEncoding error:nil];
    CHECK([content containsString:@"[INFO] [boot]"], "行格式含 [级别] [模块]");
    CHECK([content containsString:@"测试启动"], "内容写入");

    // 打码后的凭证不应出现在日志里
    [log logWithLevel:KPLogLevelInfo module:KPLogModuleKing format:@"凭证 guid=%@ token=%@",
     KPMaskGUID(@"aaaa1111"), KPMaskSecret(@"secret123")];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
    NSString *c2 = [NSString stringWithContentsOfFile:cur encoding:NSUTF8StringEncoding error:nil];
    CHECK(![c2 containsString:@"secret123"], "明文 TOKEN 不落盘");

    // 步骤记录
    [log stepCheckModule:KPLogModuleBoot name:@"测试步骤" ok:YES format:@"detail=%@", @"x"];
    CHECK(log.recentSteps.count >= 1, "步骤记录非空");
    CHECK([log.recentSteps.firstObject[@"ok"] boolValue] == YES, "步骤 ok 字段正确");

    log.baseDirectory = nil;
    log.debugMode = YES;
}

static void TestKingCorePure(void) {    printf("[KPKIngCore] 纯函数\n");
    char guid[64] = {0}, token[64] = {0};
    CHECK(kp_parse_guid_token("abc123,xyz789\n", 14, guid, sizeof(guid), token, sizeof(token)) == 0,
          "解析 GUID,TOKEN");
    CHECK(strcmp(guid, "abc123") == 0 && strcmp(token, "xyz789") == 0, "值正确");
    CHECK(kp_parse_guid_token("no-comma", 8, guid, sizeof(guid), token, sizeof(token)) != 0,
          "无逗号报错");

    char loginHost[256] = {0};
    CHECK(kp_build_login_host("g1", "t2", loginHost, sizeof(loginHost)) == 0, "构造登录域名");
    CHECK(strcmp(loginHost, "g1.t2.iikira.com.token") == 0, "域名格式正确");

    char req[1024] = {0};
    CHECK(kp_build_connect_request("example.com", 443, "g1", "t2", req, sizeof(req)) == 0, "构造 CONNECT 请求");
    CHECK(strstr(req, "CONNECT example.com:443 HTTP/1.1") != NULL, "CONNECT 行");
    CHECK(strstr(req, "Q-GUID: g1") != NULL && strstr(req, "Q-Token: t2") != NULL, "补 Q-GUID/Q-Token 头");

    char host[256] = {0};
    int port = 0;
    CHECK(kp_parse_connect_line("CONNECT example.com:443 HTTP/1.1", 33, host, sizeof(host), &port) == 0, "解析 CONNECT 行");
    CHECK(strcmp(host, "example.com") == 0 && port == 443, "host/port 正确");
    CHECK(kp_parse_connect_line("GET / HTTP/1.1", 15, host, sizeof(host), &port) != 0, "非 CONNECT 拒绝");
    CHECK(kp_response_is_2xx("HTTP/1.1 200 Connection Established\r\n", 37) == 1, "2xx 判定");
    CHECK(kp_response_is_2xx("HTTP/1.1 502 Bad Gateway\r\n", 25) == 0, "非 2xx 判定");
}

static void TestModeController(void) {
    printf("[KPModeController] 四模式\n");
    KPModeController *mc = [KPModeController shared];
    KPTsCore *core = [KPTsCore shared];
    NSString *base = TempDir();
    core.baseDirectory = base;
    [KPKingForwarder shared].offlineMode = YES; // 避免测试联网

    // 预置 SOCKS5 地址（模拟 core 初始化完成后的回调；无 core 时不 hook）
    [mc onSocks5ChangedToAddr:@"127.0.0.1:19091" cred:@""];

    NSDictionary *d = @{@"tailscale": @{@"enabled": @NO, @"hostname": @"t"}, @"king": @{@"enabled": @NO}};
    [mc applyConfig:d];
    CHECK(mc.currentMode == KPModeD, "关+关 → D");
    CHECK([mc.desiredProxy[@"kind"] integerValue] == KPProxyKindNone, "D 不 hook");

    d = @{@"tailscale": @{@"enabled": @YES, @"hostname": @"t"}, @"king": @{@"enabled": @NO}};
    [mc applyConfig:d];
    CHECK(mc.currentMode == KPModeB, "开+关 → B");
    CHECK([mc.desiredProxy[@"kind"] integerValue] == KPProxyKindSOCKS5, "B → SOCKS5 期望代理");

    d = @{@"tailscale": @{@"enabled": @NO, @"hostname": @"t"}, @"king": @{@"enabled": @YES}};
    [mc applyConfig:d];
    CHECK(mc.currentMode == KPModeC, "关+开 → C");
    CHECK([mc.desiredProxy[@"kind"] integerValue] == KPProxyKindHTTP, "C → HTTP(king) 期望代理");
    CHECK([mc.desiredProxy[@"port"] intValue] == KPKingForwarderDefaultPort, "C 指向 18080");

    d = @{@"tailscale": @{@"enabled": @YES, @"hostname": @"t"}, @"king": @{@"enabled": @YES}};
    [mc applyConfig:d];
    CHECK(mc.currentMode == KPModeA, "开+开 → A");
    CHECK([mc.desiredProxy[@"kind"] integerValue] == KPProxyKindSOCKS5, "A → SOCKS5 期望代理");

    // SOCKS5 变更 → 期望代理跟随
    [mc onSocks5ChangedToAddr:@"127.0.0.1:19555" cred:@"tsnet:pw"];
    CHECK([mc.desiredProxy[@"port"] intValue] == 19555, "SOCKS5 变更后端口更新");

    [mc applyConfig:@{@"tailscale": @{@"enabled": @NO}, @"king": @{@"enabled": @NO}}];
    [KPKingForwarder shared].offlineMode = NO;
    core.baseDirectory = nil;
}

static void TestLoginLogMasking(void) {
    printf("[KPKingForwarder] 登录日志脱敏回归\n");
    // 脱敏辅助：绝不含明文
    NSString *masked = KPMaskedLoginHost(@"AAAA1111", @"PLAINTEXTTOKEN123");
    CHECK(![masked containsString:@"PLAINTEXTTOKEN123"], "脱敏 host 不含明文 TOKEN");
    CHECK(![masked containsString:@"AAAA1111"], "脱敏 host 不含完整 GUID");
    CHECK([masked containsString:@"AAAA****"], "GUID 前4位保留");
    CHECK([masked containsString:@"<secret:17>"], "TOKEN 只显长度");
    CHECK([masked containsString:@"iikira.com.token"], "域名后缀保留");

    // 真实日志路径：走 logLoginAttemptWithGuid:token:rc:，落盘内容不得含明文
    NSString *base = TempDir();
    KPLogger *log = [KPLogger shared];
    log.baseDirectory = base;
    log.debugMode = NO;
    [[KPKingForwarder shared] logLoginAttemptWithGuid:@"AAAA1111" token:@"PLAINTEXTTOKEN123" rc:0];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
    NSString *content = [NSString stringWithContentsOfFile:log.currentLogFilePath encoding:NSUTF8StringEncoding error:nil];
    CHECK(content.length > 0, "日志已写入");
    CHECK(![content containsString:@"PLAINTEXTTOKEN123"], "登录日志不落明文 TOKEN");
    CHECK(![content containsString:@"AAAA1111"], "登录日志不含完整 GUID");
    CHECK([content containsString:@"AAAA****"], "登录日志含掩码 GUID");
    log.baseDirectory = nil;
    log.debugMode = YES;
}

static void TestSharedRoot(void) {
    printf("[KPSharedPaths] 共享根推导\n");
    NSString *a = KPSharedRootFromTweakPath(@"/var/mobile/Containers/Data/Application/ABCD/Documents/Tweaks/LCProxyTweak.dylib");
    CHECK([a isEqualToString:@"/var/mobile/Containers/Data/Application/ABCD/Documents"], "全局 tweak → LC Documents", "got=%@", a);

    NSString *b = KPSharedRootFromTweakPath(@"/var/mobile/Containers/Data/Application/ABCD/Documents/Tweaks/LCProxyTweak.framework/LCProxyTweak");
    CHECK([b isEqualToString:@"/var/mobile/Containers/Data/Application/ABCD/Documents"], ".framework 形态 → LC Documents", "got=%@", b);

    NSString *c = KPSharedRootFromTweakPath(@"/var/mobile/Containers/Data/Application/ABCD/Documents/Tweaks/AppX/LCProxyTweak.dylib");
    CHECK([c isEqualToString:@"/var/mobile/Containers/Data/Application/ABCD/Documents/Tweaks/AppX"], "非标准目录 → 该目录（退化）", "got=%@", c);

    NSString *d = KPSharedRootFromTweakPath(@"");
    CHECK(d == nil, "空路径返回 nil");

    // 模块默认基目录 = 共享根（dladdr 可解析到测试可执行文件自身，仅验证非空可写路径）
    CHECK(KPSharedRootDirectory().length > 0, "KPSharedRootDirectory 非空");
}

static void TestFetchParse(void) {
    printf("[KPKIngCore] 响应解析/gzip/容错\n");
    char body[1024];
    size_t bodylen = 0;
    kp_fetch_diag diag;
    kp_fetch_diag_init(&diag);
    const char *plain = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nGUID123,TOKEN456";
    CHECK(kp_parse_http_response(plain, strlen(plain), body, sizeof(body), &bodylen, &diag) == 0, "解析普通响应");
    CHECK(bodylen == 16 && strncmp(body, "GUID123,TOKEN456", bodylen) == 0, "body 提取正确");
    CHECK(strcmp(diag.status_line, "HTTP/1.1 200 OK") == 0, "状态行正确");

    // gzip/zlib 压缩 body
    char compressed[1024];
    uLongf clen = sizeof(compressed);
    const char *raw = "GZIPGUID1,GZIPTOKEN1";
    CHECK(compress2((Bytef *)compressed, &clen, (const Bytef *)raw, strlen(raw), 6) == Z_OK, "zlib 压缩构造");
    char full[2048];
    const char *gzhead = "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\n\r\n";
    memcpy(full, gzhead, strlen(gzhead));
    memcpy(full + strlen(gzhead), compressed, clen);
    size_t fulllen = strlen(gzhead) + clen;
    char out[1024];
    size_t outlen = 0;
    kp_fetch_diag d2;
    kp_fetch_diag_init(&d2);
    CHECK(kp_parse_http_response(full, fulllen, out, sizeof(out), &outlen, &d2) == 0, "gzip 响应解压成功");
    CHECK(outlen == strlen(raw) && strncmp(out, raw, outlen) == 0, "gzip 解压内容正确");
    CHECK(strcmp(d2.content_encoding, "gzip") == 0, "Content-Encoding 识别");

    char g[64], t[64];
    CHECK(kp_parse_guid_token("aa,bb\r\n", 7, g, sizeof(g), t, sizeof(t)) == 0 &&
          strcmp(g, "aa") == 0 && strcmp(t, "bb") == 0, "逗号+CRLF 容错");
    // 宽松字符集：base64 风格 token（+ / =）允许
    CHECK(kp_parse_guid_token("GUIDA1B2,Tok+en/==", 18, g, sizeof(g), t, sizeof(t)) == 0 &&
          strcmp(g, "GUIDA1B2") == 0 && strcmp(t, "Tok+en/==") == 0, "宽松字符集(+/=) 解析");
    // 真实场景：32 位 GUID + 96 位 token（真机 bodylen=129，旧缓冲 64 会拒）
    {
        char bigguid[128], bigtoken[128], bigbody[256];
        size_t biglen = 0;
        for (int i = 0; i < 32; i++) bigbody[biglen++] = 'A' + (i % 26);
        bigbody[biglen++] = ',';
        for (int i = 0; i < 96; i++) bigbody[biglen++] = '0' + (i % 10);
        CHECK(biglen == 129, "构造 129 字节 body");
        CHECK(kp_parse_guid_token(bigbody, biglen, bigguid, sizeof(bigguid),
                                  bigtoken, sizeof(bigtoken)) == 0, "96位token解析(缓冲128)");
        CHECK(strlen(bigguid) == 32 && strlen(bigtoken) == 96, "32+96 长度正确");
        CHECK(kp_validate_creds_for_host(bigguid, bigtoken) == 0, "96位token可拼Host");
    }
    const char *js = "{\"guid\":\"gg123\",\"token\":\"tt456\"}";
    CHECK(kp_parse_guid_token(js, strlen(js), g, sizeof(g), t, sizeof(t)) == 0 &&
          strcmp(g, "gg123") == 0 && strcmp(t, "tt456") == 0, "JSON 形式解析");
    CHECK(kp_parse_guid_token("not-a-token", 11, g, sizeof(g), t, sizeof(t)) != 0, "垃圾内容报错");
    // 拼 Host 严格校验：hostname 安全字符才允许
    CHECK(kp_validate_creds_for_host("Abc123", "xyz-789") == 0, "host 安全字符通过");
    CHECK(kp_validate_creds_for_host("a+b", "t") != 0, "含 + 拒绝拼 Host");
    CHECK(kp_build_login_host("g1", "t/2", NULL, 0) != 0, "非法 token 构造登录域失败");

    // kp_analyze_body：结构指纹 + 失败原因
    {
        int reason = 0, pos = 0;
        char st[520];
        kp_analyze_body("ABC,XYZ", 7, 128, 128, st, sizeof(st), &reason, &pos);
        CHECK(strcmp(st, "AAA,AAA") == 0 && reason == 0, "指纹AAA,AAA 无失败");
        kp_analyze_body("12a+b,tok", 9, 128, 128, st, sizeof(st), &reason, &pos);
        CHECK(reason == 0, "含+/= 宽松通过");
        kp_analyze_body("ab!cd,xyz", 10, 128, 128, st, sizeof(st), &reason, &pos);
        CHECK(reason == 4 && pos == 2, "含!非法(位置2)");
        kp_analyze_body("abcdefghij", 10, 128, 128, st, sizeof(st), &reason, &pos);
        CHECK(reason == 1, "无逗号非JSON");
        kp_analyze_body("abcdef,xyz", 10, 4, 128, st, sizeof(st), &reason, &pos);
        CHECK(reason == 3, "段超容量");
        // 129 字节真实场景：纯 alnum 32+1+96 → 无失败
        {
            char big[256];
            size_t bl = 0;
            for (int i = 0; i < 32; i++) big[bl++] = 'A' + (i % 26);
            big[bl++] = ',';
            for (int i = 0; i < 96; i++) big[bl++] = '0' + (i % 10);
            kp_analyze_body(big, bl, 128, 128, st, sizeof(st), &reason, &pos);
            CHECK(bl == 129 && reason == 0, "129字节真实场景无失败");
            CHECK(strlen(st) == 129 && st[0] == 'A' && st[31] == 'A' && st[32] == ',' && st[33] == 'A' && st[128] == 'A', "指纹结构正确(32A,96A)");
        }
    }

    // 诊断字段：body_len / location
    kp_fetch_diag d3;
    kp_fetch_diag_init(&d3);
    const char *redir = "HTTP/1.1 301 Moved Permanently\r\nLocation: http://kc.iikira.com/kingcard2\r\n\r\n";
    CHECK(kp_parse_http_response(redir, strlen(redir), body, sizeof(body), &bodylen, &d3) == 0, "解析 3xx 响应");
    CHECK(d3.body_len == 0, "3xx body 长度为 0");
    CHECK(strstr(d3.location, "kingcard2") != NULL, "Location 头提取");

    // 诊断体长串脱敏
    NSString *masked = KPMaskLongRuns(@"error code=820 invalid 1234567890abcdef");
    CHECK(![masked containsString:@"1234567890abcdef"], "长 alnum 串被脱敏");
    CHECK([masked containsString:@"error code=820 invalid "], "短内容保留");
}

// ---------- 事件驱动刷新（本地回环模拟上游） ----------

static int gHookCalls = 0;
static int gUpstreamMode = 0; // 0=总是200 1=第一次401 2=200+读隧道内请求回HTTP响应
static int gUpstreamConns = 0;
static char gTunnelReq[512] = "";

static void *fake_upstream_run(void *arg) {
    int listen_fd = *(int *)arg;
    for (;;) {
        int c = accept(listen_fd, NULL, NULL);
        if (c < 0) break;
        char buf[2048];
        ssize_t n = read(c, buf, sizeof(buf) - 1);
        if (n > 0) buf[n] = '\0';
        gUpstreamConns++;
        if (gUpstreamMode == 1 && gUpstreamConns == 1) {
            const char *r = "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n";
            write(c, r, strlen(r));
            close(c);
        } else if (gUpstreamMode == 2) {
            const char *r = "HTTP/1.1 200 Connection Established\r\n\r\n";
            write(c, r, strlen(r));
            // 读隧道内 HTTP 请求（绝对 URI 重建后）
            ssize_t n2 = read(c, buf, sizeof(buf) - 1);
            if (n2 > 0) {
                buf[n2] = '\0';
                snprintf(gTunnelReq, sizeof(gTunnelReq), "%s", buf);
            }
            const char *hr = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi";
            write(c, hr, strlen(hr));
            usleep(120000);
            close(c);
        } else {
            const char *r = "HTTP/1.1 200 Connection Established\r\n\r\n";
            write(c, r, strlen(r));
            usleep(120000);
            close(c);
        }
    }
    return NULL;
}

static int test_refresh_hook(void *ctx) {
    gHookCalls++;
    kp_forwarder *fw = (kp_forwarder *)ctx;
    kp_forwarder_set_creds(fw, "g2", "t2");
    return 0;
}

static int start_fake_upstream(int *port_out) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_port = 0;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(fd, (struct sockaddr *)&a, sizeof(a)) != 0 || listen(fd, 8) != 0) return -1;
    socklen_t len = sizeof(a);
    getsockname(fd, (struct sockaddr *)&a, &len);
    *port_out = ntohs(a.sin_port);
    int *pfd = malloc(sizeof(int));
    *pfd = fd;
    pthread_t t;
    pthread_create(&t, NULL, fake_upstream_run, pfd);
    return fd;
}

static int client_connect_tunnel(int fw_port, char *resp, size_t cap) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_port = htons((uint16_t)fw_port);
    inet_pton(AF_INET, "127.0.0.1", &a.sin_addr);
    if (connect(fd, (struct sockaddr *)&a, sizeof(a)) != 0) { close(fd); return -1; }
    const char *req = "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n";
    if (write(fd, req, strlen(req)) <= 0) { close(fd); return -1; }
    struct timeval tv = {3, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    ssize_t n = read(fd, resp, cap - 1);
    if (n <= 0) { close(fd); return -1; }
    resp[n] = '\0';
    close(fd);
    return 0;
}

static kp_forwarder *spawn_forwarder(int upstream_port, int *out_port) {
    for (int try = 0; try < 8; try++) {
        int port = 20000 + (arc4random() % 30000);
        kp_forwarder *fw = kp_forwarder_new("127.0.0.1", port, "127.0.0.1", upstream_port);
        if (!fw) return NULL;
        kp_forwarder_set_creds(fw, "g1", "t1");
        kp_forwarder_set_refresh_hook(fw, test_refresh_hook, fw);
        if (kp_forwarder_start(fw) == 0) { *out_port = port; return fw; }
        kp_forwarder_free(fw);
    }
    return NULL;
}

static void TestEventDrivenRefresh(void) {
    printf("[KPKIngCore] 事件驱动刷新（本地回环）\n");

    // case 1: 上游第一次 401 → hook 触发 1 次 → 重试 → 200
    int up_port = 0;
    int upfd = start_fake_upstream(&up_port);
    CHECK(upfd >= 0 && up_port > 0, "启动假上游");
    gUpstreamMode = 1; gUpstreamConns = 0; gHookCalls = 0;
    int fw_port = 0;
    kp_forwarder *fw = spawn_forwarder(up_port, &fw_port);
    CHECK(fw != NULL, "转发器启动");
    char resp[512] = {0};
    int rc = client_connect_tunnel(fw_port, resp, sizeof(resp));
    CHECK(rc == 0 && strstr(resp, "200 Connection Established") != NULL, "客户端最终拿到 200（刷新后重试）", "resp=%.100s", resp);
    CHECK(gHookCalls == 1, "刷新 hook 恰好 1 次", "calls=%d", gHookCalls);
    kp_forwarder_free(fw);
    close(upfd);
    usleep(200000);

    // case 2: 上游一直 200 → hook 不触发
    int up_port2 = 0;
    int upfd2 = start_fake_upstream(&up_port2);
    CHECK(upfd2 >= 0 && up_port2 > 0, "启动假上游(2)");
    gUpstreamMode = 0; gUpstreamConns = 0; gHookCalls = 0;
    int fw_port2 = 0;
    kp_forwarder *fw2 = spawn_forwarder(up_port2, &fw_port2);
    CHECK(fw2 != NULL, "转发器启动(2)");
    char resp2[512] = {0};
    int rc2 = client_connect_tunnel(fw_port2, resp2, sizeof(resp2));
    CHECK(rc2 == 0 && strstr(resp2, "200") != NULL, "正常路径 200");
    CHECK(gHookCalls == 0, "200 时 hook 不触发", "calls=%d", gHookCalls);
    kp_forwarder_free(fw2);
    close(upfd2);
    usleep(200000);

    // case 3: HTTP 绝对 URI（代理模式 http:// 流量）经转发器 → 上游隧道内 path 形式
    int up_port3 = 0;
    int upfd3 = start_fake_upstream(&up_port3);
    CHECK(upfd3 >= 0 && up_port3 > 0, "启动假上游(3)");
    gUpstreamMode = 2; gUpstreamConns = 0; gTunnelReq[0] = '\0';
    int fw_port3 = 0;
    kp_forwarder *fw3 = spawn_forwarder(up_port3, &fw_port3);
    CHECK(fw3 != NULL, "转发器启动(3)");
    {
        int cfd = socket(AF_INET, SOCK_STREAM, 0);
        struct sockaddr_in sa;
        memset(&sa, 0, sizeof(sa));
        sa.sin_family = AF_INET;
        sa.sin_port = htons((uint16_t)fw_port3);
        inet_pton(AF_INET, "127.0.0.1", &sa.sin_addr);
        int rc3 = connect(cfd, (struct sockaddr *)&sa, sizeof(sa));
        const char *absreq = "GET http://203.0.113.5/x HTTP/1.1\r\nHost: 203.0.113.5\r\nUser-Agent: T\r\n\r\n";
        write(cfd, absreq, strlen(absreq));
        struct timeval tv = {3, 0};
        setsockopt(cfd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        char rb[1024] = {0};
        ssize_t rn = read(cfd, rb, sizeof(rb) - 1);
        CHECK(rc3 == 0 && rn > 0 && strstr(rb, "200 OK") != NULL && strstr(rb, "hi") != NULL,
              "绝对URI经上游隧道成功", "resp=%.120s", rb);
        CHECK(gTunnelReq[0] && strstr(gTunnelReq, "GET /x HTTP/1.1") != NULL &&
              strstr(gTunnelReq, "http://203.0.113.5") == NULL,
              "隧道内为path形式请求", "tunnel=%.120s", gTunnelReq);
        close(cfd);
    }
    kp_forwarder_free(fw3);
    close(upfd3);
    usleep(200000);
}

// ---------- 底层 hook ----------
static int gFwdListenFd = -1;
static char gFwdReq[2][512];
static int gFwdGot = 0;
static pthread_mutex_t gFwdMtx = PTHREAD_MUTEX_INITIALIZER;

// 假转发器线程：accept → 读 CONNECT 行（2s 超时）→ 回 200 → 记录
static void *gFwdThread(void *arg) {
    (void)arg;
    for (int i = 0; i < 4; i++) {
        int c = accept(gFwdListenFd, NULL, NULL);
        if (c < 0) break;
        struct pollfd pfd = { c, POLLIN, 0 };
        char buf[512] = "";
        ssize_t n = 0;
        if (poll(&pfd, 1, 2000) > 0) {
            n = recv(c, buf, sizeof(buf) - 1, 0);
            if (n > 0) buf[n] = '\0';
        }
        pthread_mutex_lock(&gFwdMtx);
        if (gFwdGot < 2) {
            snprintf(gFwdReq[gFwdGot], sizeof(gFwdReq[gFwdGot]), "%s", n > 0 ? buf : "");
            gFwdGot++;
        }
        pthread_mutex_unlock(&gFwdMtx);
        const char *ok = "HTTP/1.1 200 Connection Established\r\n\r\n";
        send(c, ok, (size_t)strlen(ok), 0);
        close(c);
    }
    return NULL;
}

static void TestHook(void) {
    // 假转发器：监听 127.0.0.1:18080
    gFwdListenFd = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(gFwdListenFd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_port = htons(18080);
    sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    CHECK(bind(gFwdListenFd, (struct sockaddr *)&sa, sizeof(sa)) == 0 &&
          listen(gFwdListenFd, 8) == 0, "假转发器监听 18080");
    pthread_t tid;
    pthread_create(&tid, NULL, gFwdThread, NULL);

    kp_socket_hook_install(18080, "157.148.54.212", 8091, NULL);

    // 1) 非 loopback 目标 → 被劫持到假转发器，且收到 CONNECT 行
    kp_socket_hook_set_active(1);
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in tgt;
    memset(&tgt, 0, sizeof(tgt));
    tgt.sin_family = AF_INET;
    tgt.sin_port = htons(443);
    inet_pton(AF_INET, "203.0.113.9", &tgt.sin_addr);
    int rc = connect(fd, (struct sockaddr *)&tgt, sizeof(tgt));
    usleep(300000); // 等假转发器线程记录 CONNECT 行
    pthread_mutex_lock(&gFwdMtx);
    CHECK(gFwdGot >= 1 && strstr(gFwdReq[0], "CONNECT 203.0.113.9:443") != NULL,
          "socket hook 劫持非loopback到转发器(CONNECT行到达)");
    pthread_mutex_unlock(&gFwdMtx);
    if (fd >= 0) close(fd);

    // 2) loopback 目标 → 直连（不劫持，无需握手）
    int l2 = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in tgt2;
    memset(&tgt2, 0, sizeof(tgt2));
    tgt2.sin_family = AF_INET;
    tgt2.sin_port = htons(18080);
    tgt2.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    rc = connect(l2, (struct sockaddr *)&tgt2, sizeof(tgt2));
    CHECK(rc == 0, "loopback 目标直连（不劫持）");
    if (l2 >= 0) close(l2);
    usleep(300000);

    pthread_mutex_lock(&gFwdMtx);
    CHECK(gFwdGot >= 2 && gFwdReq[1][0] == '\0', "loopback 连接不产生 CONNECT 行");
    pthread_mutex_unlock(&gFwdMtx);

    // 3) bypass 标记：取号/探活自身连接不被劫持
    kp_socket_set_bypass(1);
    int fd3 = socket(AF_INET, SOCK_STREAM, 0);
    rc = connect(fd3, (struct sockaddr *)&tgt, sizeof(tgt)); // 非 loopback，直连失败
    CHECK(rc != 0, "bypass 标记下非loopback直连（未被劫持到18080）");
    kp_socket_set_bypass(0);
    if (fd3 >= 0) close(fd3);

    // 4) 停用后不再劫持
    kp_socket_hook_set_active(0);
    int fd4 = socket(AF_INET, SOCK_STREAM, 0);
    rc = connect(fd4, (struct sockaddr *)&tgt, sizeof(tgt));
    CHECK(rc != 0, "停用后非loopback直连失败(未被劫持)");
    if (fd4 >= 0) close(fd4);

    // 5) URLSession 注入
    KPHookManager *h = [KPHookManager shared];
    [h install];
    NSDictionary *p1 = @{@"kind": @(KPProxyKindHTTP), @"host": @"127.0.0.1", @"port": @18080};
    CHECK([h setProxy:p1], "注入 HTTP 代理");
    NSDictionary *d = [[NSURLSessionConfiguration defaultSessionConfiguration] connectionProxyDictionary];
    CHECK([d[@"HTTPProxy"] isEqualToString:@"127.0.0.1"] && [d[@"HTTPPort"] intValue] == 18080,
          "URLSession 读到注入代理");
    NSDictionary *p2 = @{@"kind": @(KPProxyKindNone)};
    CHECK([h setProxy:p2], "恢复直连");
    NSDictionary *d2 = [[NSURLSessionConfiguration defaultSessionConfiguration] connectionProxyDictionary];
    CHECK(d2 == nil || d2.count == 0, "恢复后无代理");

    // 6) 模式C：非 TCP 出站禁止（UDP sendto，DNS/UDP53 与 loopback 豁免）
    kp_socket_hook_set_udp_block(1);
    int u = socket(AF_INET, SOCK_DGRAM, 0);
    struct sockaddr_in ua;
    memset(&ua, 0, sizeof(ua));
    ua.sin_family = AF_INET;
    ua.sin_port = htons(9999);
    inet_pton(AF_INET, "203.0.113.9", &ua.sin_addr);
    errno = 0;
    ssize_t ur = sendto(u, "x", 1, 0, (struct sockaddr *)&ua, sizeof(ua));
    CHECK(ur == -1 && errno == EPERM, "UDP 非TCP出站被禁止(EPERM)");
    ua.sin_port = htons(53);
    errno = 0;
    ur = sendto(u, "x", 1, 0, (struct sockaddr *)&ua, sizeof(ua));
    CHECK(ur == 1 || errno != EPERM, "UDP53 DNS 豁免");
    kp_socket_hook_set_udp_block(0);
    if (u >= 0) close(u);

    close(gFwdListenFd);
    pthread_join(tid, NULL);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        printf("==== LCProxyTweak host tests ====\n");
        TestMasks();
        TestLoggerFileAndRotation();
        TestKingCorePure();
        TestFetchParse();
        TestModeController();
        TestLoginLogMasking();
        TestSharedRoot();
        TestEventDrivenRefresh();
        TestHook();
        printf("\n结果: %d 通过, %d 失败\n", gPassed, gFailed);
        return gFailed == 0 ? 0 : 1;
    }
}
