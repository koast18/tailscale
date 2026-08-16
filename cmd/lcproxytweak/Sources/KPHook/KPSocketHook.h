//
//  KPSocketHook.h
//  LCProxyTweak
//
#ifndef KPSocketHook_h
#define KPSocketHook_h

#include <stddef.h>

/// 设置线程局部"绕过代理"标记（取号/登录/探活等自身连接使用，避免被重定向）
void kp_socket_set_bypass(int on);

/// 安装 socket 层 hook（connect/connectx → 重定向转发器 + 自动 CONNECT 握手）。
/// target_port: 转发器端口；upstream_ip/upstream_port: 免流网关（豁免）；
/// cred_fn: 填 guid/token（可空）。
void kp_socket_hook_install(int target_port, const char *upstream_ip, int upstream_port,
                            void (*cred_fn)(char *guid, size_t guid_cap, char *token, size_t token_cap));

/// 激活/停用（激活=劫持非豁免 TCP 连接到转发器）
void kp_socket_hook_set_active(int active);

/// 模式C：禁止非 TCP 出站（UDP sendto/sendmsg 拒绝，DNS/UDP53 与 loopback 豁免）
void kp_socket_hook_set_udp_block(int on);

#endif
