#!/bin/bash
# 构建并运行 macOS 宿主单元测试（验证 KPLogger / KPKIngCore / KPModeController / KPTsCore / KPSharedPaths）
set -euo pipefail
cd "$(dirname "$0")/.."

ROOT="$PWD"
OUT="build/kp_tests"
mkdir -p build

SRCS="Tests/test_main.m \
Sources/KPLogger/KPLogger.m \
Sources/KPConfig/KPConfig.m \
Sources/KPModeController/KPModeController.m \
Sources/KPKingForwarder/KPKIngCore.c \
Sources/KPKingForwarder/KPKingForwarder.m \
Sources/KPTsCore/KPTsCore.m \
Sources/KPSharedPaths/KPSharedPaths.m \
Sources/KPHook/KPHookManager.m \
Sources/KPHook/KPFishhook.c \
Sources/KPHook/KPSocketHook.c"

CFLAGS="-fobjc-arc -O1 -g \
  -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations \
  -I ${ROOT}/Sources -I ${ROOT}/Sources/KPLogger -I ${ROOT}/Sources/KPConfig \
  -I ${ROOT}/Sources/KPModeController -I ${ROOT}/Sources/KPKingForwarder \
  -I ${ROOT}/Sources/KPTsCore -I ${ROOT}/Sources/KPWebServer \
  -I ${ROOT}/Sources/KPSharedPaths -I ${ROOT}/Sources/KPHook"

echo ">> compile + link $OUT"
clang $CFLAGS $SRCS -framework Foundation -lz -o "$OUT"

echo ">> run"
"$OUT"
