#!/usr/bin/env bash
# 用 Android NDK 交叉编译 proot，产物直接放进 jniLibs 供 AGP 打包。
#
#     tool/build_proot.sh [arm64-v8a|x86_64] ...
#
# ## 为什么不放进 CMake
#
# proot 有一个**内嵌的 freestanding loader**：先把 loader.c + assembly.S 链成一个
# 静态无 libc 的 ELF、链接地址写死在 arch.h 里，再用 objcopy 把整个二进制塞进
# 一个 .o，最后和主程序链在一起。CMake 表达这套多阶段流程很别扭，
# 而它又不常变 —— 做成离线脚本、产物入 jniLibs，比让每次 Gradle 构建都跑一遍划算。
#
# ## 为什么不用 proot 自带的 GNUmakefile
#
# 它假设一个 POSIX 环境 + `gcc -m32` 能生成 32 位目标。在 Windows 上跑 make 本身
# 就要绕一圈，而且 `-m32` 对 aarch64 clang 根本不成立 —— 32 位 loader 必须换成
# `armv7a-linux-androideabi` 这个 target triple，不是加一个 flag。所以自己走一遍流程，
# 顺便把 makefile 里那些 `git describe`、`readelf | awk` 的隐式依赖显式化。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="$(dirname "$HERE")"

PROOT_VERSION="${PROOT_VERSION:-master}"
TALLOC_VERSION="${TALLOC_VERSION:-2.4.2}"

: "${ANDROID_NDK_HOME:=${ANDROID_NDK_ROOT:-$HOME/AppData/Local/Android/Sdk/ndk/28.2.13676358}}"
WORK="${PROOT_BUILD_DIR:-$PROJECT/.proot-build}"
OUT="$PROJECT/android/app/src/main/jniLibs"

# NDK 的宿主目录名。脚本要能在 Windows(Git Bash) / Linux / macOS 上都跑。
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) HOSTTAG=windows-x86_64; EXE=.exe ;;
  Darwin)               HOSTTAG=darwin-x86_64;  EXE=     ;;
  *)                    HOSTTAG=linux-x86_64;   EXE=     ;;
esac

TOOLS="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$HOSTTAG/bin"
CLANG="$TOOLS/clang$EXE"
OBJCOPY="$TOOLS/llvm-objcopy$EXE"
OBJDUMP="$TOOLS/llvm-objdump$EXE"
READELF="$TOOLS/llvm-readelf$EXE"
STRIP="$TOOLS/llvm-strip$EXE"

[ -x "$CLANG" ] || { echo "找不到 NDK clang：$CLANG"; echo "设 ANDROID_NDK_HOME 指向 NDK 根目录"; exit 1; }

# minSdk。proot 用到的 ptrace/process_vm 接口在 24 上都有。
API="${ANDROID_API:-24}"

# ---------------------------------------------------------------------------
# 取源码
# ---------------------------------------------------------------------------
mkdir -p "$WORK"
cd "$WORK"

fetch() { # url outfile
  [ -f "$2" ] && return 0
  echo "  下载 $2"
  curl -fsSL --retry 3 -o "$2.part" "$1" && mv "$2.part" "$2"
}

if [ ! -d "proot-$PROOT_VERSION" ]; then
  # 用 termux 的 fork 而不是上游 proot：它带着 Android 上必需的补丁
  # （bionic 的 ptrace 差异、SELinux 下的行为、ashmem/memfd 处理等）。
  fetch "https://github.com/termux/proot/archive/refs/heads/$PROOT_VERSION.tar.gz" "proot.tar.gz"
  tar xzf proot.tar.gz
fi
if [ ! -d "talloc-$TALLOC_VERSION" ]; then
  fetch "https://www.samba.org/ftp/talloc/talloc-$TALLOC_VERSION.tar.gz" "talloc.tar.gz"
  tar xzf talloc.tar.gz
fi

PROOT_SRC="$WORK/proot-$PROOT_VERSION/src"
TALLOC_SRC="$WORK/talloc-$TALLOC_VERSION"

# ---- 上游修补 ----
#
# termux/proot 的 ashmem_memfd.c 用了 strcmp/memset 却没 include <string.h>。
# 老编译器把隐式声明当 warning，clang 19 按 C99 规则直接报 error。
# 这不是「新编译器太严格」——隐式声明下 strcmp 的返回值会被当成 int，
# 在 LP64 上碰巧对，但 memset 返回指针被截成 int 就是实打实的未定义行为。
if ! grep -q '#include <string.h>' "$PROOT_SRC/extension/ashmem_memfd/ashmem_memfd.c"; then
  echo "  修补 ashmem_memfd.c：补上缺失的 <string.h>"
  sed -i '3i #include <string.h>' "$PROOT_SRC/extension/ashmem_memfd/ashmem_memfd.c"
fi

# talloc 正常要靠 samba 的 libreplace + waf 生成 config.h。
# bionic 已经提供了 talloc 需要的一切，所以给一个最小 shim，
# 完全跳过那套构建系统。
mkdir -p "$WORK/shim"
cat > "$WORK/shim/replace.h" <<'SHIM'
#ifndef _BURROW_REPLACE_H
#define _BURROW_REPLACE_H
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/types.h>
#ifndef MIN
#define MIN(a,b) ((a)<(b)?(a):(b))
#endif
#ifndef MAX
#define MAX(a,b) ((a)>(b)?(a):(b))
#endif
#ifndef likely
#define likely(x)   __builtin_expect(!!(x), 1)
#endif
#ifndef unlikely
#define unlikely(x) __builtin_expect(!!(x), 0)
#endif
#endif
SHIM

# ---------------------------------------------------------------------------
# 每个 ABI 走一遍
# ---------------------------------------------------------------------------

# 从 arch.h 里问一个宏的值。makefile 里是 `$(CC) -E -dM arch.h | grep -w X`，
# 这里同样做 —— 那些地址是按架构定死的，猜不得。
arch_macro() { # target macro
  "$CLANG" --target="$1" -E -dM -DNO_LIBC_HEADER "$PROOT_SRC/arch.h" 2>/dev/null \
    | awk -v m="$2" '$1=="#define" && $2==m {print $3}'
}

build_abi() {
  local abi="$1" target target32 bdir
  case "$abi" in
    arm64-v8a) target="aarch64-linux-android$API";  target32="armv7a-linux-androideabi$API" ;;
    x86_64)    target="x86_64-linux-android$API";   target32="i686-linux-android$API" ;;
    *) echo "不支持的 ABI: $abi"; return 1 ;;
  esac

  bdir="$WORK/build-$abi"
  rm -rf "$bdir"; mkdir -p "$bdir"
  cd "$bdir"

  local CC="$CLANG --target=$target"
  local CC32="$CLANG --target=$target32"
  echo "=== $abi ($target) ==="

  # ---- talloc ----
  $CC -O2 -fPIC -I "$WORK/shim" -I "$TALLOC_SRC" \
      -DTALLOC_BUILD_VERSION_MAJOR=2 \
      -DTALLOC_BUILD_VERSION_MINOR=4 \
      -DTALLOC_BUILD_VERSION_RELEASE=2 \
      -DHAVE_VA_COPY -DHAVE_CONSTRUCTOR_ATTRIBUTE \
      -c "$TALLOC_SRC/talloc.c" -o talloc.o
  # HAVE_VA_COPY 不是可选的：不定义的话 talloc 会用 `(dest)=(src)` 顶替 va_copy，
  # 而 aarch64 的 va_list 是结构体，那样会破坏「两个 va_list 独立遍历」的语义。

  # talloc.h 要在包含路径里 —— proot 是 `#include <talloc.h>`。
  local CPPFLAGS="-D_FILE_OFFSET_BITS=64 -D_GNU_SOURCE -I$bdir -I$PROOT_SRC -I$TALLOC_SRC"
  local CFLAGS="-Wall -O2"

  # ---- 编译期特性检测（makefile 里的 CHECK_FEATURES）----
  # 真去编一遍，不靠猜。**必须带上 CPPFLAGS**：bionic 把
  # process_vm_readv/writev 挡在 _GNU_SOURCE 后面，不带这个宏检测必然
  # 报「无」，于是 proot 退化成按字长 PTRACE_PEEKDATA 逐字读 tracee 内存 ——
  # 能跑，但每次读内存都多一轮系统调用，重 I/O 下差别很明显。
  : > build.h
  echo "/* 由 tool/build_proot.sh 生成 */" >> build.h
  echo "#ifndef BUILD_H"  >> build.h
  echo "#define BUILD_H"  >> build.h
  echo "#define VERSION \"burrow-$PROOT_VERSION\"" >> build.h
  for feat in process_vm seccomp_filter; do
    if $CC $CPPFLAGS -c "$PROOT_SRC/.check_$feat.c" -o ".check_$feat.o" >/dev/null 2>&1; then
      echo "#define HAVE_$(echo "$feat" | tr 'a-z' 'A-Z')" >> build.h
      echo "  特性 $feat: 有"
    else
      echo "  特性 $feat: 无"
    fi
  done
  echo "#endif" >> build.h

  # ---- loader（freestanding，链接地址来自 arch.h）----
  build_loader() { # suffix cc target
    local sfx="$1" cc="$2" tgt="$3"
    local addr; addr="$(arch_macro "$tgt" LOADER_ADDRESS)"
    [ -n "$addr" ] || { echo "  取不到 $tgt 的 LOADER_ADDRESS"; return 1; }
    echo "  loader$sfx 链接地址 $addr"

    mkdir -p loader
    $cc $CPPFLAGS $CFLAGS -fPIC -ffreestanding \
        -c "$PROOT_SRC/loader/loader.c" -o "loader/loader$sfx.o"
    $cc $CPPFLAGS $CFLAGS -fPIC -ffreestanding \
        -c "$PROOT_SRC/loader/assembly.S" -o "loader/assembly$sfx.o"
    $cc -o "loader/loader$sfx" "loader/loader$sfx.o" "loader/assembly$sfx.o" \
        -static -nostdlib -Wl,--build-id=none,-Ttext="$addr",-z,noexecstack

    # objcopy 把整个 loader 二进制塞进一个 .o，符号名由文件名决定 ——
    # 所以这里的文件名必须正好是 `loader.exe` / `loader-m32.exe`，
    # C 侧引用的是 `_binary_loader_exe_start` / `_binary_loader_m32_exe_start`。
    cp "loader/loader$sfx" "loader$sfx.exe"
    "$STRIP" "loader$sfx.exe"
    "$OBJCOPY" --input-target=binary \
      --output-target="$OUTPUT_TARGET" \
      --binary-architecture="$BIN_ARCH" \
      "loader$sfx.exe" "loader/loader$sfx-wrapped.o"
  }

  # objcopy 需要知道目标格式。从一个已经编好的 .o 上问出来，
  # 而不是按架构写死一张对照表 —— NDK 换版本时那张表会悄悄过时。
  OUTPUT_TARGET="$("$OBJDUMP" -f talloc.o | awk '/file format/{print $NF}')"
  BIN_ARCH="$("$OBJDUMP" -f talloc.o | awk '/^architecture/{sub(/,$/,"",$2); print $2}')"
  echo "  objcopy 目标: $OUTPUT_TARGET / $BIN_ARCH"

  build_loader ""     "$CC"   "$target"
  build_loader "-m32" "$CC32" "$target32"

  local EXTRA_OBJS="loader/loader-wrapped.o loader/loader-m32-wrapped.o"

  # ---- loader-info（只有需要 POKEDATA 变通的架构才有）----
  if [ -n "$(arch_macro "$target" HAS_POKEDATA_WORKAROUND)" ]; then
    echo "  生成 loader-info（本架构需要 POKEDATA 变通）"
    mkdir -p loader
    "$READELF" -s "loader/loader" | awk -f "$PROOT_SRC/loader/loader-info.awk" \
      > loader/loader-info.c
    $CC $CPPFLAGS $CFLAGS -c loader/loader-info.c -o loader/loader-info.o
    EXTRA_OBJS="$EXTRA_OBJS loader/loader-info.o"
  fi

  # ---- 主程序 ----
  # 对象列表直接从 makefile 里抠，避免手抄一份之后和上游漂移。
  local objs=()
  while read -r o; do
    [ -n "$o" ] || continue
    mkdir -p "$(dirname "$o")"
    $CC $CPPFLAGS $CFLAGS -c "$PROOT_SRC/${o%.o}.c" -o "$o"
    objs+=("$o")
  done < <(awk '
      /^OBJECTS \+= \\$/ { f = 1; next }
      f {
        # 按「行尾有没有反斜杠」判断续行，而不是按缩进字符。
        # makefile 里 helper_functions.o 那一行是空格缩进而非 tab，
        # 按 tab 判断会在那里提前截断 —— 静默少编十几个对象，
        # 一直要到链接阶段才炸出一堆 undefined symbol。
        cont = ($0 ~ /\\$/)
        line = $0
        gsub(/[\\ \t]/, "", line)
        if (line != "") print line
        if (!cont) f = 0
      }' "$PROOT_SRC/GNUmakefile" | grep -v 'loader/')

  echo "  链接 ${#objs[@]} 个对象"
  $CC -o proot "${objs[@]}" $EXTRA_OBJS talloc.o -Wl,-z,noexecstack
  "$STRIP" proot

  # 伪装成 lib*.so 才会被 Android 解压到 nativeLibraryDir 并可执行，
  # 详见 ARCHITECTURE.md §3.1（还需要 useLegacyPackaging = true 配合）。
  mkdir -p "$OUT/$abi"
  cp proot "$OUT/$abi/libproot.so"

  # loader 也单独打包。
  #
  # proot 默认把内嵌的 loader 解到临时目录再 execve 它 —— 而那个临时目录
  # 在 app 的数据区，Android 10+ 对「执行自己写出来的文件」有 W^X 限制，
  # 实测报 `execve("/bin/sh"): Permission denied`（错误信息指向 /bin/sh，
  # 极具误导性，真正被拒的是 loader）。
  #
  # enter.c 在调 extract_loader() 之前会先查 PROOT_LOADER 环境变量，
  # 所以把 loader 作为 lib*.so 打进 APK、从 nativeLibraryDir 执行就能绕开 ——
  # 那是 Android 明确允许执行的位置（burrow-launch 已经证明过）。
  cp loader/loader      "$OUT/$abi/libproot-loader.so"
  cp loader/loader-m32  "$OUT/$abi/libproot-loader32.so"

  echo "  ✅ $OUT/$abi/libproot.so ($(wc -c < proot) 字节) + loader/loader32"
}

for abi in "${@:-arm64-v8a x86_64}"; do
  build_abi "$abi"
done
