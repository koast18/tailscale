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

# 版本唯一源：version.txt → build/Version.h（所有源码 #include "Version.h" 使用，禁止硬编码）
VER="$(cat version.txt | tr -d ' \r\n')"
if [ -z "$VER" ]; then echo "version.txt 为空" >&2; exit 1; fi
cat > build/Version.h <<EOF
#define KPTWEAK_VERSION "$VER"
#define KPTWEAK_UA "LCProxy/$VER"
EOF
echo ">> Version.h: KPTWEAK_VERSION=$VER KPTWEAK_UA=LCProxy/$VER"

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
  -I ${ROOT}/build \
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
