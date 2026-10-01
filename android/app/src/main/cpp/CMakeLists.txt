# ============================================================================
# 原生 JPEG 编码器（libjpeg-turbo）
#
# 为什么需要它：采集链路里最贵的一步是把相机给的 NV21 压成 JPEG。
# Android 自带的 YuvImage.compressToJpeg 在 720p 上实测 50~90 ms/帧，
# A53 上一个核就这么被吃掉了，帧率被编码卡住而不是被相机卡住。
# libjpeg-turbo 的 DCT/Huffman 有 AArch64 NEON 实现，同样画质通常快 3~6 倍。
#
# 为什么用预编译静态库而不是源码参与构建：
# libjpeg-turbo 的 CMake 明确禁止被 add_subdirectory() 集成（它要求
# ExternalProject_Add）。每次 Gradle 构建都重编它会多花半分钟，而它的代码
# 一年也不会动一次 —— 所以预编译一次、把 .a 和头文件放进 prebuilt/ 提交，
# Gradle 每次只编我们自己的一个 C 文件（秒级）。
# 需要重建时跑同目录下的 build_libjpeg_turbo.sh（会自动下载源码并编译）。
# ============================================================================

cmake_minimum_required(VERSION 3.22.1)
project("pcspeaker-jpeg" C)

set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_C_STANDARD 99)

# 预编译好的 libjpeg-turbo（含 TurboJPEG API），按 ABI 分目录
add_library(turbojpeg STATIC IMPORTED)
set_target_properties(turbojpeg PROPERTIES
        IMPORTED_LOCATION
        ${CMAKE_CURRENT_SOURCE_DIR}/prebuilt/${ANDROID_ABI}/libturbojpeg.a)

add_library(pcspeaker-jpeg SHARED jpeg_codec.c)

target_include_directories(pcspeaker-jpeg PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/prebuilt/include)

target_link_libraries(pcspeaker-jpeg PRIVATE turbojpeg)

# libjpeg 的几百个内部符号没必要出现在 .so 的动态符号表里 —— 收起来能
# 明显减小体积（也避免和别的库里的 libjpeg 撞符号）。
# --exclude-libs,ALL 只对静态库生效，不会动我们自己的 JNI 入口。
target_link_options(pcspeaker-jpeg PRIVATE "-Wl,--exclude-libs,ALL")
set_target_properties(pcspeaker-jpeg PROPERTIES
        C_VISIBILITY_PRESET hidden
        CXX_VISIBILITY_PRESET hidden)

# 抓 NEON：jpeg_codec.c 里用 vld2q_u8 拆交错的 VU 平面，
# 万一将来要编到没有 NEON 的 ABI，这里会给出明确提示而不是静默变慢。
if(ANDROID_ABI STREQUAL "arm64-v8a")
    set_target_properties(pcspeaker-jpeg PROPERTIES COMPILE_OPTIONS "-O2")
else()
    message(WARNING "pcspeaker-jpeg：ABI=${ANDROID_ABI} 只有预编译的 arm64-v8a 库，"
            "请先在 prebuilt/ 下补一个同 ABI 的 libturbojpeg.a")
endif()
