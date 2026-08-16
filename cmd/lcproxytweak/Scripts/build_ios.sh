#!/bin/bash
# 构建 LCProxyTweak.dylib（iOS 15+ arm64）。需要 macOS + Xcode iOS SDK。
set -euo pipefail
cd "$(dirname "$0")/.."

ROOT="$PWD"
OUT="build/LCProxyTweak.dylib"
OBJDIR="build/obj"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
MIN=15.0
ARCH=arm64

mkdir -p build
rm -rf "$OBJDIR"
mkdir -p "$OBJDIR"

# 收集源码
SRCS="$(find Sources -name '*.m' -o -name '*.c' | sort) \
Vendor/GCDWebServer/Core/*.m \
Vendor/GCDWebServer/Requests/*.m \
Vendor/GCDWebServer/Responses/*.m"

CFLAGS="-target ${ARCH}-apple-ios${MIN} -isysroot ${SDK} \
  -fobjc-arc -O2 -DNDEBUG \
  -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations \
  -I ${ROOT}/Sources -I ${ROOT}/Sources/KPLogger -I ${ROOT}/Sources/KPConfig \
  -I ${ROOT}/Sources/KPModeController -I ${ROOT}/Sources/KPKingForwarder \
  -I ${ROOT}/Sources/KPTsCore -I ${ROOT}/Sources/KPWebServer -I ${ROOT}/Sources/KPSharedPaths -I ${ROOT}/Sources/KPHook \
  -I ${ROOT}/Vendor/GCDWebServer -I ${ROOT}/Vendor/GCDWebServer/Core -I ${ROOT}/Vendor/GCDWebServer/Requests -I ${ROOT}/Vendor/GCDWebServer/Responses"

OBJS=""
for f in $SRCS; do
  base="$(basename "${f%.*}")"
  o="${OBJDIR}/${base}.o"
  echo ">> compile $f"
  clang $CFLAGS -c "$f" -o "$o"
  OBJS="$OBJS $o"
done

echo ">> link $OUT"
clang -dynamiclib -arch $ARCH -mios-version-min=$MIN -isysroot "$SDK" \
  -fobjc-arc -O2 \
  $OBJS \
  -framework Foundation \
  -framework UIKit \
  -framework SystemConfiguration \
  -framework CoreServices \
  -framework CFNetwork \
  -lz \
  -o "$OUT"

echo ">> 不签名（LiveContainer 检测到无签名时用用户证书 ZSign 自动重签）"
echo ">> done: $OUT"
file "$OUT"
