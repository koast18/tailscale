#!/bin/bash
# 构建 LCProxyConsole.ipa（LiveContainer 控制台 App，WebView → 127.0.0.1:19092）。
# 不需要 xcodeproj：clang 直编 arm64 iOS 15+ 可执行文件 → 拼 .app → Payload 结构 .ipa。
# 不签名（导入 LiveContainer 时由 LC/ZSign 本地签名）。
set -euo pipefail
cd "$(dirname "$0")/.."

ROOT="$PWD"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
MIN=15.0
ARCH=arm64
APP="build/LCProxyConsole.app"

mkdir -p build
rm -rf "$APP"
mkdir -p "$APP"

echo ">> compile ConsoleApp"
clang -target ${ARCH}-apple-ios${MIN} -isysroot "$SDK" \
  -fobjc-arc -O2 -DNDEBUG \
  -Wall -Wextra -Wno-unused-parameter \
  -I "$ROOT/ConsoleApp" \
  -framework UIKit -framework WebKit -framework Foundation -framework CoreGraphics \
  "$ROOT/ConsoleApp/main.m" \
  "$ROOT/ConsoleApp/AppDelegate.m" \
  "$ROOT/ConsoleApp/ViewController.m" \
  "$ROOT/ConsoleApp/AutoUpdater.m" \
  -o "$APP/LCProxyConsole"

echo ">> assemble .app"
cp "$ROOT/ConsoleApp/Info.plist" "$APP/Info.plist"
printf 'APPL????' > "$APP/PkgInfo"
file "$APP/LCProxyConsole"

echo ">> 不签名（由 LiveContainer 导入时处理；与 tweak 策略一致）"

echo ">> package .ipa"
cd build
rm -rf Payload
mkdir -p Payload
cp -R LCProxyConsole.app Payload/
rm -f LCProxyConsole.ipa
zip -qry LCProxyConsole.ipa Payload
cd "$ROOT"
echo ">> done: build/LCProxyConsole.ipa"
ls -la build/LCProxyConsole.ipa
