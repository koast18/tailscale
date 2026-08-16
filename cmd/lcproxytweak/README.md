# LCProxyTweak

LiveContainer 容器内 App 全量流量走 Tailscale / 王卡免流（腾讯大王卡）的 ObjC tweak 壳 + 本地 Web 控制界面。

架构与模式矩阵见上级目录 `../PLAN.md`（四模式 A/B/C/D：tailscale × 免流），接口契约见 `../TAILSCALE_DYLIB_API.md`。

## 目录结构

```
LCProxyTweak/
├── Sources/
│   ├── LCProxyTweak.m          # 主入口 __attribute__((constructor))
│   ├── KPLogger/               # 统一日志（PLAN 3.7 规格）
│   ├── KPConfig/               # Documents/KingProxy/conf.json 读写
│   ├── KPModeController/       # 四模式状态机 + 免流↔DERP-only 联动
│   ├── KPKingForwarder/        # 王卡转发器（KPKIngCore.c 纯 C 核心）
│   ├── KPTsCore/               # TailscaleCore.dylib dlsym 封装
│   └── KPWebServer/            # GCDWebServer + REST API + 控制台 HTML
├── Vendor/GCDWebServer/        # GCDWebServer（Apache-2.0）
├── Resources/console.html      # 单文件四 Tab 控制台（源）
├── Scripts/                    # 构建 / 资源生成脚本
├── Tests/                      # macOS 宿主单元测试（CI 运行）
└── .github/workflows/build.yml # iOS dylib 构建 + 宿主测试
```

## 构建

```bash
# iOS dylib（需要 macOS + Xcode，CI 用）
./Scripts/build_ios.sh          # 产出 build/LCProxyTweak.dylib

# 宿主单元测试（macOS）
./Scripts/build_tests.sh && ./build/kp_tests

# 重新生成内嵌 HTML 头文件
node Scripts/gen_console_asset.js Resources/console.html Sources/KPWebServer/ConsoleHTML.h
```

## 发布

- **打 tag `v*` 或手动 workflow_dispatch** → CI 构建后发布到 **GitHub Release**，双资产：
  - `LCProxyTweak.dylib`（原文件，不打 zip）
  - `LCProxyConsole.ipa`（控制台 App，导入 LiveContainer 后点开即控制台）
- main 分支 push：只构建 + 宿主测试验证，不发布

## 签名策略（重要）

**产物故意不带任何签名。** 依据 LiveContainer 源码行为：

| 环节 | 对 ad-hoc 签名 | 对无签名 |
|---|---|---|
| LC `checkCodeSignature`（完整性） | 通过 → 跳过 ZSign 重签 | 失败 → 触发 ZSign 重签 |
| dyld dlopen（信任链） | 拒绝加载 | 已被 ZSign 用用户证书重签 → 可加载 |

- **ad-hoc 签名是死路**：落在缝隙里（LC 不重签 + dyld 拒绝）
- **无签名正确**：LC 检测到无签名 → 用「设置 → 签名证书」导入的证书 ZSign 自动重签 → dlopen 通过
- 因此使用前置条件：**LiveContainer 必须配置签名证书（p12）**；无证书时只能走 JIT 路径
- **core（TailscaleCore）同理**：控制台「下载并安装」会同时把 core 同步到 `Tweaks/libTailscaleCore.dylib`，由 LC 强制签名后，tweak 优先 dlopen 该已签名副本（`KingProxy/TailscaleCore.bin` 为版本源）；**每次更新 core 后需在 LC 点一次「强制签名」并重启**

## 控制台 App（LCProxyConsole）

- 全屏 WKWebView → `http://127.0.0.1:19092`；首次加载失败每 2 秒自动重试
- 使用方式：LiveContainer 导入 `LCProxyConsole.ipa` → 点开即控制台（LC 前台，控制服务器必然存活，无需 Safari 后台访问）

## 取号 / 保活（事件驱动，无定时器）

- 取号链：**经上游代理 → 直连**，整体重试 3 次（300ms 退避）；失败日志含状态行 + Content-Encoding + 响应体前 512B（脱敏）
- **无周期性探活/刷新定时器**；转发器上游 CONNECT **非 200/连接失败** → 触发凭证刷新（取号+登录激活）→ 成功后**重试该连接一次**，仍失败回 502
- 取号失败不探活；仅成功后做一次 generate_204 验证
- 状态区显示：刷新来源（boot/manual/event）、刷新次数、取号路由（proxy/direct/override）

## 流量劫持（多层，按需覆盖）

| 层 | 覆盖 | 说明 |
|---|---|---|
| `connectionProxyDictionary` swizzle | 进程内 NSURLSession 全部请求 | HTTP/C/SOCKS 指向 18080/19091，loopback 豁免 |
| `_CFNetworkCopySystemProxySettings` fishhook | NSURLConnection / Chromium / CFNetwork 栈 | 读系统代理的公共入口 |
| `WKWebsiteDataStore.proxyConfigurations` | WKWebView 浏览器（iOS 15+，运行时探测） | 构造失败静默回退 |
| **socket 层（connect/connectx）** | 原生 socket 直连（游戏/自定义协议） | 免流模式重定向到转发器 + 自动 CONNECT 握手；走不了即连接失败 |
| **UDP 禁止（sendto/sendmsg）** | 模式C 非 TCP 出站 | DNS/UDP53 与 loopback 豁免，其余拒绝 |

- 转发器（18080）同时支持 **CONNECT 隧道**（HTTPS）与 **HTTP 绝对 URI**（代理模式 http:// 流量，path 形式转发上游）；loopback 目标本机直连透传（保护控制台 19092）
- 自身连接（取号/登录/探活/出口检测）线程局部 bypass，不被劫持

## 运行配置（Documents/KingProxy/conf.json）

```json
{
  "tailscale": {
    "enabled": false,
    "hostname": "lcproxy",
    "exitNode": null,
    "updateRepo": "koast18/tailscale"
  },
  "king": {
    "enabled": false,
    "refreshURL": "http://kc.iikira.com/kingcard",
    "proxyHost": "157.148.54.212",
    "proxyPort": 8091,
    "guidOverride": null,
    "tokenOverride": null
  },
  "debug": {
    "enabled": true,
    "logLevel": "debug"
  }
}
```

GUID/TOKEN 默认自动从 `kc.iikira.com/kingcard` 获取（`GUID,TOKEN`），仅在需要时手动覆盖。

## 调试模式

- `debug.enabled`：**无配置文件时默认开启**；开启后日志级别最低、逐步验证每步 ✓/✗（可在控制台「关于 → 调试 · 启动步骤验证」查看）
- `debug.logLevel`：`debug|info|warn|error`

## 日志

`Documents/KingProxy/logs/LCProxy-YYYYMMDD-HHmmss-SSS.log`，每次启动一个新文件，最多保留 50 个（超限从最旧删除）。凭证打码（GUID 前 4 位、TOKEN 不落明文）。
