//
//  test_c_main.c
//  LCProxyTweak 纯 C 宿主测试（ubuntu CI 运行，不依赖 Foundation）
//
//  覆盖：取号解析、绝对 URI 解析/重建、转发器端到端（CONNECT/绝对 URI/事件驱动刷新）、
//  登录激活双通道（本地假上游）。KPSocketHook 以 stub 形式提供。
//

#include "KPKIngCore.h"
#include "KPSocketHook.h"

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
#include <zlib.h>

// ---- KPSocketHook stub（Linux 无 mach-o/dyld；bypass 标记 no-op）----
void kp_socket_set_bypass(int on) { (void)on; }
void kp_socket_hook_install(int target_port, const char *upstream_ip, int upstream_port,
                            void (*cred_fn)(char *, size_t, char *, size_t)) { (void)target_port; (void)upstream_ip; (void)upstream_port; (void)cred_fn; }
void kp_socket_hook_set_active(int active) { (void)active; }
void kp_socket_hook_set_udp_block(int on) { (void)on; }

static int gFailed = 0;
static int gPassed = 0;
#define CHECK(cond, name, ...) do { \
    if (cond) { gPassed++; printf("  ✓ %s\n", name); } \
    else { gFailed++; printf("  ✗ %s : ", name); \
          printf("" __VA_ARGS__); \
          printf("\n"); } \
} while (0)

// ---------- 取号解析 ----------
static void TestParse(void) {
    printf("[KPKIngCore] 取号/URI 解析\n");
    char g[128], t[128];
    CHECK(kp_parse_guid_token("abc,def", 7, g, sizeof(g), t, sizeof(t)) == 0 &&
          strcmp(g, "abc") == 0 && strcmp(t, "def") == 0, "逗号分隔");
    {
        char big[256];
        size_t bl = 0;
        for (int i = 0; i < 32; i++) big[bl++] = 'A' + (i % 26);
        big[bl++] = ',';
        for (int i = 0; i < 96; i++) big[bl++] = '0' + (i % 10);
        CHECK(kp_parse_guid_token(big, bl, g, sizeof(g), t, sizeof(t)) == 0 &&
              strlen(g) == 32 && strlen(t) == 96, "32+96 真实场景");
    }
    CHECK(kp_parse_guid_token("GUIDA1B2,Tok+en/==", 18, g, sizeof(g), t, sizeof(t)) == 0, "宽松字符集");
    const char *js = "{\"guid\":\"gg\",\"token\":\"tt\"}";
    CHECK(kp_parse_guid_token(js, strlen(js), g, sizeof(g), t, sizeof(t)) == 0, "JSON 兜底");
    CHECK(kp_parse_guid_token("not-a-token", 11, g, sizeof(g), t, sizeof(t)) != 0, "垃圾报错");
    CHECK(kp_validate_creds_for_host("Abc123", "xyz-789") == 0, "host 安全字符");
    CHECK(kp_validate_creds_for_host("a+b", "t") != 0, "含+拒绝拼Host");
    CHECK(kp_build_login_host("g1", "t2", g, sizeof(g)) == 0 &&
          strcmp(g, "g1.t2.iikira.com.token") == 0, "登录域拼接");

    // 绝对 URI 解析
    char m[16], h[256], p[1024];
    int port = 0;
    CHECK(kp_parse_absolute_uri("GET http://example.com/x HTTP/1.1\r\n\r\n", 40,
                                m, sizeof(m), h, sizeof(h), &port, p, sizeof(p)) == 0 &&
          strcmp(m, "GET") == 0 && strcmp(h, "example.com") == 0 && port == 80 &&
          strcmp(p, "/x") == 0, "绝对URI解析");
    CHECK(kp_parse_absolute_uri("GET http://example.com:8080/ HTTP/1.1\r\n", 41,
                                m, sizeof(m), h, sizeof(h), &port, p, sizeof(p)) == 0 &&
          port == 8080 && strcmp(p, "/") == 0, "带端口解析");
    CHECK(kp_parse_absolute_uri("CONNECT example.com:443 HTTP/1.1\r\n", 37,
                                m, sizeof(m), h, sizeof(h), &port, p, sizeof(p)) != 0, "CONNECT 不走绝对URI");

    // 请求重建：绝对 URI → path 形式 + Host + 过滤原 Host
    const char *absreq = "GET http://example.com/x HTTP/1.1\r\nHost: example.com\r\nUser-Agent: T\r\n\r\n";
    char rebuilt[1024];
    int rn = kp_rebuild_proxy_request(absreq, strlen(absreq), "GET", "example.com", 80, "/x",
                                      rebuilt, sizeof(rebuilt));
    CHECK(rn > 0 && strstr(rebuilt, "GET /x HTTP/1.1") != NULL &&
          strstr(rebuilt, "Host: example.com:80") != NULL &&
          strstr(rebuilt, "http://example.com") == NULL, "重建为path形式");
    int host_cnt = 0;
    char *pos = rebuilt;
    while ((pos = strstr(pos, "Host: ")) != NULL) { host_cnt++; pos += 6; }
    CHECK(host_cnt == 1, "Host 头不重复", "count=%d", host_cnt);

    // kp_analyze_body
    int reason = 0, fpos = 0;
    char st[520];
    kp_analyze_body("ab!cd,xyz", 10, 128, 128, st, sizeof(st), &reason, &fpos);
    CHECK(reason == 4, "analyze 非法字符");
}

// ---------- 转发器端到端 ----------
static int gHookCalls = 0;
static int gUpstreamMode = 0; // 0=总是200 1=第一次401 2=200+读隧道请求回HTTP
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

static int test_refresh_hook(void *ctx) {
    gHookCalls++;
    kp_forwarder *fw = (kp_forwarder *)ctx;
    kp_forwarder_set_creds(fw, "g2", "t2");
    return 0;
}

static kp_forwarder *spawn_forwarder(int upstream_port, int *out_port) {
    for (int try = 0; try < 8; try++) {
        int port = 20000 + (rand() % 30000);
        kp_forwarder *fw = kp_forwarder_new("127.0.0.1", port, "127.0.0.1", upstream_port);
        if (!fw) return NULL;
        kp_forwarder_set_creds(fw, "g1", "t1");
        kp_forwarder_set_refresh_hook(fw, test_refresh_hook, fw);
        if (kp_forwarder_start(fw) == 0) { *out_port = port; return fw; }
        kp_forwarder_free(fw);
    }
    return NULL;
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

static void TestForwarder(void) {
    printf("[KPKIngCore] 转发器端到端（本地回环）\n");

    // case 1: 401 → 刷新 1 次 → 重试 200
    int up_port = 0;
    int upfd = start_fake_upstream(&up_port);
    CHECK(upfd >= 0 && up_port > 0, "启动假上游");
    gUpstreamMode = 1; gUpstreamConns = 0; gHookCalls = 0;
    int fw_port = 0;
    kp_forwarder *fw = spawn_forwarder(up_port, &fw_port);
    CHECK(fw != NULL, "转发器启动");
    char resp[512] = {0};
    int rc = client_connect_tunnel(fw_port, resp, sizeof(resp));
    CHECK(rc == 0 && strstr(resp, "200 Connection Established") != NULL, "CONNECT 200（刷新后重试）");
    CHECK(gHookCalls == 1, "刷新 hook 恰好 1 次", "calls=%d", gHookCalls);
    kp_forwarder_free(fw);
    close(upfd);
    usleep(200000);

    // case 2: HTTP 绝对 URI → 上游隧道内 path 形式
    int up_port2 = 0;
    int upfd2 = start_fake_upstream(&up_port2);
    gUpstreamMode = 2; gUpstreamConns = 0; gTunnelReq[0] = '\0';
    int fw_port2 = 0;
    kp_forwarder *fw2 = spawn_forwarder(up_port2, &fw_port2);
    CHECK(fw2 != NULL, "转发器启动(2)");
    {
        int cfd = socket(AF_INET, SOCK_STREAM, 0);
        struct sockaddr_in sa;
        memset(&sa, 0, sizeof(sa));
        sa.sin_family = AF_INET;
        sa.sin_port = htons((uint16_t)fw_port2);
        inet_pton(AF_INET, "127.0.0.1", &sa.sin_addr);
        int rc2 = connect(cfd, (struct sockaddr *)&sa, sizeof(sa));
        const char *absreq = "GET http://203.0.113.5/x HTTP/1.1\r\nHost: 203.0.113.5\r\nUser-Agent: T\r\n\r\n";
        write(cfd, absreq, strlen(absreq));
        struct timeval tv = {3, 0};
        setsockopt(cfd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        char rb[1024] = {0};
        ssize_t rn = read(cfd, rb, sizeof(rb) - 1);
        CHECK(rc2 == 0 && rn > 0 && strstr(rb, "200 OK") != NULL && strstr(rb, "hi") != NULL,
              "绝对URI经上游隧道成功", "resp=%.120s", rb);
        CHECK(gTunnelReq[0] && strstr(gTunnelReq, "GET /x HTTP/1.1") != NULL &&
              strstr(gTunnelReq, "http://203.0.113.5") == NULL,
              "隧道内为path形式", "tunnel=%.120s", gTunnelReq);
        close(cfd);
    }
    kp_forwarder_free(fw2);
    close(upfd2);
    usleep(200000);
}

// ---------- 登录激活双通道（假上游） ----------
static void TestLogin(void) {
    printf("[KPKIngCore] 登录激活（CONNECT 优先 → 绝对 URI 兜底）\n");
    int up_port = 0;
    int upfd = start_fake_upstream(&up_port);
    CHECK(upfd >= 0 && up_port > 0, "启动假上游");
    gUpstreamMode = 0; gUpstreamConns = 0;
    // 假上游对 CONNECT 回 200 → 通道 1 成功
    char diag[160] = {0};
    int rc = kp_login_via_proxy("127.0.0.1", up_port, "g1.t2.iikira.com.token", "g1", "t2",
                                5000, diag, sizeof(diag));
    CHECK(rc == 0, "CONNECT 通道激活成功", "diag=%.80s", diag);
    close(upfd);
    usleep(200000);
}

int main(int argc, const char *argv[]) {
    (void)argc; (void)argv;
    srand(12345);
    printf("==== LCProxyTweak pure C host tests ====\n");
    TestParse();
    TestForwarder();
    TestLogin();
    printf("\n结果: %d 通过, %d 失败\n", gPassed, gFailed);
    return gFailed == 0 ? 0 : 1;
}
