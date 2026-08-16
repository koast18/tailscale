//
//  KPSocketHook.c
//  LCProxyTweak
//
//  socket 层强行代理：rebind connect/connectx，把非豁免 TCP 连接重定向到
//  本地转发器（127.0.0.1:<port>），自动完成 HTTP CONNECT 握手（带 Q-GUID/Q-Token），
//  应用对代理无感知。握手失败 = 连接失败（按用户要求"走不了就丢掉"）。
//

#include "KPSocketHook.h"
#include "KPFishhook.h"
#include <dlfcn.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <errno.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// ---- 原实现（dlsym 解析真实地址，避免 lazy stub 递归）----
static int (*sOrigConnect)(int, const struct sockaddr *, socklen_t);
static int (*sOrigConnectx)(int, const struct sockaddr *, socklen_t, int, int,
                            const struct sockaddr *, socklen_t, unsigned int, int *);
static int (*gRealConnect)(int, const struct sockaddr *, socklen_t);
static int (*gRealConnectx)(int, const struct sockaddr *, socklen_t, int, int,
                            const struct sockaddr *, socklen_t, unsigned int, int *);
static ssize_t (*gRealSendto)(int, const void *, size_t, int, const struct sockaddr *, socklen_t);
static ssize_t (*gRealSendmsg)(int, const struct msghdr *, int);

// ---- 状态 ----
static _Atomic int sActive = 0;
static _Atomic int sUdpBlockActive = 0; // 模式C：禁止非 TCP 出站（DNS 豁免）
static _Atomic int sTargetPort = 18080;
static char sUpstreamHost[64] = "157.148.54.212";
static _Atomic int sUpstreamPort = 8091;
static void (*sCredFn)(char *, size_t, char *, size_t) = NULL;

// ---- 线程局部 bypass ----
static pthread_key_t sBypassKey;
static pthread_once_t sOnce = PTHREAD_ONCE_INIT;

static void kp_sock_key_destroy(void *v) { (void)v; }

static void kp_sock_once(void) {
    pthread_key_create(&sBypassKey, kp_sock_key_destroy);
}

void kp_socket_set_bypass(int on) {
    pthread_once(&sOnce, kp_sock_once);
    pthread_setspecific(sBypassKey, (void *)(intptr_t)(on ? 1 : 0));
}

static int kp_sock_bypass(void) {
    pthread_once(&sOnce, kp_sock_once);
    return (int)(intptr_t)pthread_getspecific(sBypassKey);
}

// ---- 工具 ----
static int kp_sock_wait(int fd, int for_write, int timeout_ms) {
    struct pollfd pfd;
    pfd.fd = fd;
    pfd.events = for_write ? POLLOUT : POLLIN;
    pfd.revents = 0;
    for (;;) {
        int r = poll(&pfd, 1, timeout_ms);
        if (r < 0 && errno == EINTR) continue;
        return r;
    }
}

static int kp_sock_send_all(int fd, const char *buf, size_t n, int timeout_ms) {
    size_t off = 0;
    while (off < n) {
        ssize_t w = send(fd, buf + off, n - off, 0);
        if (w > 0) { off += (size_t)w; continue; }
        if (w < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) {
            if (kp_sock_wait(fd, 1, timeout_ms) <= 0) return -1;
            continue;
        }
        return -1;
    }
    return 0;
}

static int kp_sock_recv_some(int fd, char *buf, size_t cap, int timeout_ms) {
    for (;;) {
        ssize_t r = recv(fd, buf, cap, 0);
        if (r > 0) return (int)r;
        if (r == 0) return 0;
        if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) {
            if (kp_sock_wait(fd, 0, timeout_ms) <= 0) return -1;
            continue;
        }
        return -1;
    }
}

// 解析 sockaddr → host/port；仅支持 IPv4/IPv6 文本
static int kp_sock_extract(const struct sockaddr *addr, socklen_t len,
                           char *host, size_t host_cap, int *port) {
    if (!addr || !host || !port || host_cap < 1) return -1;
    host[0] = '\0';
    if (len >= sizeof(struct sockaddr_in) && addr->sa_family == AF_INET) {
        const struct sockaddr_in *a = (const struct sockaddr_in *)addr;
        if (inet_ntop(AF_INET, &a->sin_addr, host, (socklen_t)host_cap) == NULL) return -1;
        *port = ntohs(a->sin_port);
        return 0;
    }
    if (len >= sizeof(struct sockaddr_in6) && addr->sa_family == AF_INET6) {
        const struct sockaddr_in6 *a = (const struct sockaddr_in6 *)addr;
        if (inet_ntop(AF_INET6, &a->sin6_addr, host, (socklen_t)host_cap) == NULL) return -1;
        *port = ntohs(a->sin6_port);
        return 0;
    }
    return -1;
}

static int kp_sock_is_loopback(const char *host) {
    if (!host) return 0;
    return strcmp(host, "127.0.0.1") == 0 || strcmp(host, "::1") == 0 ||
           strcmp(host, "localhost") == 0 || strncmp(host, "127.", 4) == 0;
}

static int kp_sock_is_upstream(const char *host, int port) {
    if (!host) return 0;
    return (port == sUpstreamPort) && (strcmp(host, sUpstreamHost) == 0);
}

// 重定向 + CONNECT 握手（同步完成；失败返回 -1）
static int kp_sock_connect_via_proxy(int fd, const char *host, int port) {
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_port = htons((uint16_t)sTargetPort);
    if (inet_pton(AF_INET, "127.0.0.1", &sa.sin_addr) != 1) return -1;

    if (gRealConnect(fd, (struct sockaddr *)&sa, sizeof(sa)) != 0) {
        if (errno == EINPROGRESS) {
            if (kp_sock_wait(fd, 1, 3000) <= 0) return -1;
            int soerr = 0;
            socklen_t sl = sizeof(soerr);
            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &sl) != 0 || soerr != 0) return -1;
        } else {
            return -1;
        }
    }

    char guid[128] = "", token[128] = "";
    if (sCredFn) sCredFn(guid, sizeof(guid), token, sizeof(token));
    char req[1024];
    int n = snprintf(req, sizeof(req),
                     "CONNECT %s:%d HTTP/1.1\r\n"
                     "Host: %s:%d\r\n"
                     "Q-GUID: %s\r\n"
                     "Q-Token: %s\r\n"
                     "User-Agent: LCProxy/0.2.12\r\n"
                     "Connection: keep-alive\r\n\r\n",
                     host, port, host, port, guid, token);
    if (n <= 0 || n >= (int)sizeof(req)) return -1;
    if (kp_sock_send_all(fd, req, (size_t)n, 5000) != 0) return -1;

    char rbuf[2048];
    size_t got = 0;
    int found = 0;
    while (got < sizeof(rbuf) - 1) {
        int r = kp_sock_recv_some(fd, rbuf + got, sizeof(rbuf) - 1 - got, 5000);
        if (r <= 0) return -1;
        got += (size_t)r;
        rbuf[got] = '\0';
        if (strstr(rbuf, "\r\n\r\n")) { found = 1; break; }
    }
    if (!found) return -1;
    // 2xx → 成功；否则失败（丢弃）
    if (strncmp(rbuf, "HTTP/1.1 200", 12) != 0 && strncmp(rbuf, "HTTP/1.0 200", 12) != 0) {
        return -1;
    }
    // 上游可能顺带发了数据（CONNECT 后隧道数据），已读部分无处安放：
    // 转发器在 CONNECT 200 后不会立即发数据（等待客户端），此处丢弃不影响正确性。
    return 0;
}

// ---- 替换实现 ----
static int kp_connect_replacement(int fd, const struct sockaddr *addr, socklen_t len) {
    if (!atomic_load(&sActive) || kp_sock_bypass()) {
        return gRealConnect(fd, addr, len);
    }
    char host[128] = "";
    int port = 0;
    if (kp_sock_extract(addr, len, host, sizeof(host), &port) != 0 ||
        kp_sock_is_loopback(host) || port == 53 || kp_sock_is_upstream(host, port)) {
        return gRealConnect(fd, addr, len);
    }
    return kp_sock_connect_via_proxy(fd, host, port);
}

static int kp_connectx_replacement(int s,
                                   const struct sockaddr *dest_sa, socklen_t dest_salen,
                                   int sotype, int soflags,
                                   const struct sockaddr *src_sa, socklen_t src_salen,
                                   unsigned int ifscope, int *error_out) {
    if (!atomic_load(&sActive) || kp_sock_bypass()) {
        return gRealConnectx(s, dest_sa, dest_salen, sotype, soflags, src_sa, src_salen, ifscope, error_out);
    }
    char host[128] = "";
    int port = 0;
    if (!dest_sa ||
        kp_sock_extract(dest_sa, dest_salen, host, sizeof(host), &port) != 0 ||
        kp_sock_is_loopback(host) || port == 53 || kp_sock_is_upstream(host, port)) {
        return gRealConnectx(s, dest_sa, dest_salen, sotype, soflags, src_sa, src_salen, ifscope, error_out);
    }
    // 复用手动握手机制（s 已由应用创建）
    int rc = kp_sock_connect_via_proxy(s, host, port);
    if (rc != 0 && error_out) *error_out = ECONNREFUSED;
    return rc;
}

// ---- 安装 ----
void kp_socket_hook_install(int target_port, const char *upstream_ip, int upstream_port,
                            void (*cred_fn)(char *, size_t, char *, size_t)) {
    if (target_port > 0) atomic_store(&sTargetPort, target_port);
    if (upstream_ip) snprintf(sUpstreamHost, sizeof(sUpstreamHost), "%s", upstream_ip);
    if (upstream_port > 0) atomic_store(&sUpstreamPort, upstream_port);
    sCredFn = cred_fn;
    if (!sOrigConnect) {
        kp_rebind_symbol("connect", (void *)kp_connect_replacement, (void **)&sOrigConnect);
    }
    if (!sOrigConnectx) {
        kp_rebind_symbol("connectx", (void *)kp_connectx_replacement, (void **)&sOrigConnectx);
    }
    // 真实实现：dlsym 解析（槽值可能是 lazy stub，直接调用会递归/被 dyld 覆盖）
    if (!gRealConnect) {
        gRealConnect = (int (*)(int, const struct sockaddr *, socklen_t))dlsym(RTLD_NEXT, "connect");
        if (!gRealConnect) gRealConnect = sOrigConnect;
    }
    if (!gRealConnectx) {
        gRealConnectx = (int (*)(int, const struct sockaddr *, socklen_t, int, int,
                                 const struct sockaddr *, socklen_t, unsigned int, int *))
            dlsym(RTLD_NEXT, "connectx");
        if (!gRealConnectx) gRealConnectx = sOrigConnectx;
    }
    // UDP 出站（sendto/sendmsg）——模式C 禁止非 TCP
    if (!gRealSendto) {
        gRealSendto = (ssize_t (*)(int, const void *, size_t, int, const struct sockaddr *, socklen_t))
            dlsym(RTLD_NEXT, "sendto");
    }
    if (!gRealSendmsg) {
        gRealSendmsg = (ssize_t (*)(int, const struct msghdr *, int))dlsym(RTLD_NEXT, "sendmsg");
    }
    if (gRealSendto) {
        kp_rebind_symbol("sendto", (void *)kp_sendto_replacement, NULL);
    }
    if (gRealSendmsg) {
        kp_rebind_symbol("sendmsg", (void *)kp_sendmsg_replacement, NULL);
    }
}

void kp_socket_hook_set_active(int active) {
    atomic_store(&sActive, active ? 1 : 0);
}

void kp_socket_hook_set_udp_block(int on) {
    atomic_store(&sUdpBlockActive, on ? 1 : 0);
}

// 模式C：非 TCP 出站禁止（sendto/sendmsg 层，DNS/UDP53 与 loopback 豁免）
static ssize_t kp_sendto_replacement(int fd, const void *buf, size_t len, int flags,
                                     const struct sockaddr *to, socklen_t tolen) {
    if (atomic_load(&sUdpBlockActive) && to) {
        char host[128] = "";
        int port = 0;
        if (kp_sock_extract(to, tolen, host, sizeof(host), &port) == 0 &&
            !kp_sock_is_loopback(host) && port != 53) {
            errno = EPERM;
            return -1; // 非 TCP 禁止：仅允许 DNS/本地
        }
    }
    if (gRealSendto) return gRealSendto(fd, buf, len, flags, to, tolen);
    return -1;
}

static ssize_t kp_sendmsg_replacement(int fd, const struct msghdr *msg, int flags) {
    if (atomic_load(&sUdpBlockActive) && msg && msg->msg_name) {
        char host[128] = "";
        int port = 0;
        if (kp_sock_extract((const struct sockaddr *)msg->msg_name, msg->msg_namelen,
                            host, sizeof(host), &port) == 0 &&
            !kp_sock_is_loopback(host) && port != 53) {
            errno = EPERM;
            return -1;
        }
    }
    if (gRealSendmsg) return gRealSendmsg(fd, msg, flags);
    return -1;
}
