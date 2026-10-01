#!/usr/bin/env bash
# ============================================================================
# 重建预编译的 libjpeg-turbo 静态库（prebuilt/）
#
# 平时不需要跑：prebuilt/ 里的 .a 和头文件已经提交进仓库，
# Gradle 每次只编我们自己的 jpeg_codec.c。
# 只有在这几种情况下才需要跑本脚本：
#   · 要升级 libjpeg-turbo 版本
#   · 要新增 ABI（当前只有 arm64-v8a）
#   · prebuilt/ 被人误删了
#
# 用法（在 Git Bash / macOS / Linux 下）：
#   cd android/app/src/main/cpp && ./build_libjpeg_turbo.sh
# 可选环境变量：
#   LJT_VERSION=3.0.4  要拉的版本号
# ============================================================================
set -euo pipefail

LJT_VERSION="${LJT_VERSION:-3.0.4}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/libjpeg-turbo"
BUILD="$HERE/_build_ljt"

ANDROID_SDK="${ANDROID_SDK:-$ANDROID_HOME}"
if [ -z "${ANDROID_SDK:-}" ]; then
  ANDROID_SDK="$(grep -m1 '^sdk\.dir=' "$HERE/../../../local.properties" 2>/dev/null | cut -d= -f2 || true)"
fi
if [ -z "${ANDROID_SDK:-}" ]; then
  echo "找不到 Android SDK：请设置 ANDROID_SDK 环境变量" >&2
  exit 1
fi
# Windows 上 local.properties 里的路径是 E:/Android/Sdk 这种，直接用即可

NDK="$(ls -d "$ANDROID_SDK"/ndk/* 2>/dev/null | sort -V | tail -1)"
CMAKE_BIN="$(ls -d "$ANDROID_SDK"/cmake/* 2>/dev/null | sort -V | tail -1)/bin/cmake"
if [ -z "$NDK" ] || [ ! -x "$CMAKE_BIN" ]; then
  echo "需要 NDK 与 CMake，请在 SDK Manager 里安装：ndk 与 cmake" >&2
  exit 1
fi
echo "SDK = $ANDROID_SDK"
echo "NDK = $NDK"
echo "CMake = $CMAKE_BIN"

# ── 1. 取源码（只在还没有的时候下载） ─────────────────────────────────
if [ ! -f "$SRC/CMakeLists.txt" ]; then
  echo "==> 下载 libjpeg-turbo $LJT_VERSION"
  rm -rf "$SRC"
  curl -sSL -o /tmp/libjpeg-turbo.tar.gz \
    "https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/$LJT_VERSION/libjpeg-turbo-$LJT_VERSION.tar.gz"
  mkdir -p "$SRC"
  tar xzf /tmp/libjpeg-turbo.tar.gz -C "$SRC" --strip-components=1
fi

# ── 2. 逐个 ABI 交叉编译成静态库 ──────────────────────────────────────
#
# arm64-v8a 开 SIMD：AArch64 一定带 NEON，jpeglib 里的 DCT/Huffman 会走
# NEON intrinsics，这是提速的主要来源。
#
# armeabi-v7a / x86_64 关 SIMD：
#   · 32 位 ARM 的 NEON 是可选的，编译期打开就会在无 NEON 的老机器上 SIGILL，
#     而 libjpeg-turbo 在 32 位 ARM 上没有运行时检测 —— 安全优先，宁可慢一点；
#   · x86_64 的 SIMD 要 NASM 汇编器，而我们只为模拟器/极少数设备编它，不值得。
# 这两个 ABI 上 libjpeg-turbo 的标量实现依然比 YuvImage 快一截。
mkdir -p "$HERE/prebuilt/include"

build_abi() {
  local abi="$1" simd="$2"
  local dir="$BUILD-$abi"
  echo "==> 编译 $abi（SIMD=$simd）"
  "$CMAKE_BIN" \
    -H"$SRC" -B"$dir" \
    -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="$abi" \
    -DANDROID_PLATFORM=android-24 \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DENABLE_SHARED=OFF -DENABLE_STATIC=ON \
    -DWITH_SIMD="$simd" -DWITH_TURBOJPEG=ON -DWITH_JAVA=OFF \
    -DCMAKE_MAKE_PROGRAM="$(dirname "$CMAKE_BIN")/ninja" -GNinja

  "$CMAKE_BIN" --build "$dir" --target turbojpeg-static \
    -j "$(nproc 2>/dev/null || echo 4)"

  mkdir -p "$HERE/prebuilt/$abi"
  cp "$dir/libturbojpeg.a" "$HERE/prebuilt/$abi/"

  # 去掉调试符号：8MB → 1.3MB
  local strip_bin
  strip_bin="$(ls "$NDK"/toolchains/llvm/prebuilt/*/bin/llvm-strip* 2>/dev/null | head -1)"
  if [ -n "$strip_bin" ]; then
    "$strip_bin" --strip-debug "$HERE/prebuilt/$abi/libturbojpeg.a"
  fi
  echo "    → prebuilt/$abi/libturbojpeg.a"
}

build_abi arm64-v8a ON
build_abi armeabi-v7a OFF
build_abi x86_64 OFF

# ── 3. 头文件（三个 ABI 共用一份：唯一的差别是 WITH_SIMD，不影响 API） ──
cp "$BUILD-arm64-v8a/jconfig.h" "$BUILD-arm64-v8a/jconfigint.h" "$HERE/prebuilt/include/"
cp "$SRC/turbojpeg.h" "$SRC/jpeglib.h" "$SRC/jerror.h" "$SRC/jmorecfg.h" "$HERE/prebuilt/include/"

echo "==> 完成"
ls -la "$HERE"/prebuilt/*/libturbojpeg.a
