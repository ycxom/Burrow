cmake_minimum_required(VERSION 3.22)
project(burrow C)

# ---------------------------------------------------------------------------
# libburrow.so —— pty 的 JNI 部分，随 APK 加载进 Flutter 进程
# ---------------------------------------------------------------------------
add_library(burrow SHARED pty.c)
target_compile_options(burrow PRIVATE -Wall -Wextra -Werror)
target_link_libraries(burrow log)

# ---------------------------------------------------------------------------
# burrow-launch —— 沙箱启动器，独立可执行文件
#
# 必须是独立进程：seccomp filter 装上去就摘不掉，在 JVM 线程里装禁网 filter
# 会把 Flutter 自己调 LLM API 的 HTTP 一起禁掉。见 burrow_launch.c 顶部说明。
#
# 静态链接 libc：它要跑在 proot 的 rootfs 之外，那里的动态链接器和
# $PREFIX/lib 的可见性都不保证。一个 ~200KB 的静态二进制换来确定性，值。
# ---------------------------------------------------------------------------
add_executable(burrow-launch burrow_launch.c)
target_compile_options(burrow-launch PRIVATE -Wall -Wextra -Os)
target_link_options(burrow-launch PRIVATE -static)

# 关键一招：把可执行文件命名成 libburrow-launch.so。
#
# Android 打包时只会把 lib/<abi>/ 下形如 lib*.so 的文件解压到
# nativeLibraryDir，其它文件一律留在 APK 里（不可执行）。所以一个需要被
# exec 的原生小程序，必须伪装成一个 .so 才能进得去、跑得起来。
# termux 和一众带内置二进制的 app 都是这么干的。
#
# 另一半在 build.gradle.kts 的 useLegacyPackaging = true —— 不设的话
# AGP 会让 .so 留在 APK 内直接 mmap（System.loadLibrary 仍可用，
# 但 exec 不行），burrow-launch 就永远起不来。
set_target_properties(burrow-launch PROPERTIES
    PREFIX "lib"
    OUTPUT_NAME "burrow-launch"
    SUFFIX ".so")
