# Burrow 地洞

手机上的 LLM 客户端 —— 平时就是聊天，需要动手时它有一整台 Linux 可用。

对话、终端、检查点三个页签。输入框上方有一个「终端模式」勾选框：
不勾就是普通聊天（模型拿不到任何工具），勾上模型才能在沙箱里装包、
改代码、跑脚本；搞坏了退回上一个检查点，环境和文件一起回去。

📄 许可证：[Apache-2.0](LICENSE)（第三方组件各自的许可证见
[THIRD_PARTY.md](THIRD_PARTY.md)）

> **为什么叫 Burrow**：地洞是自己挖的、封闭的、安全的空间 —— 正是这个
> app 给 Agent 的东西（发行版 rootfs + proot 隔离 + 可回滚）。而
> *burrow into* 又是「一头扎进去把事情搞明白」，正是它干活的样子。
> 两层意思刚好覆盖「随便聊聊」和「认真干活」两种用法。

> **基座为什么不是 Termux bootstrap**：Termux 的二进制硬编码了
> `/data/data/com.termux/files/usr`，要用在自己的包名下就得 fork
> `termux-packages` 重编整套包。而 Ubuntu / Alpine 的二进制硬编码的是
> `/usr`、`/lib` 这些标准 FHS 路径，proot 的 `-r <rootfs>` 正好把它们重定向过来 ——
> 官方 base tarball 直接可用，那条流水线整个不需要了。
> 仍然沿用 termux-app 的两样东西：pty JNI，和 `TermuxInstaller` 的
> staging + 原子 rename 安装法（它是整个回滚机制的原型）。

📐 设计：[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) ·
🔒 沙箱与回滚：[docs/SANDBOX.md](docs/SANDBOX.md) ·
🧠 超长上下文：[docs/CONTEXT.md](docs/CONTEXT.md)

---

## 两种模式，一个勾选框

日常聊天和 Agent 干活是两种对话，但不该是两个 app。区别收敛成输入框上方
的一个勾选框，**它跟着会话走**（会话列表里的图标能看出哪个是哪个）：

| | 不勾（聊天） | 勾上（终端） |
|---|---|---|
| 发给模型的工具 | 一个都没有 | 全套 11 个 |
| 每轮开头扫 workspace 打检查点 | 不做 | 做 |
| 系统提示 | 明说「你没有工具，需要的话让用户去勾」 | 沙箱规则 + 当前发行版和包管理器 |
| 需要发行版基座 | 不需要 | 需要，没装会当场跳安装页 |

**工具是真的收走了，不是提示词里说一句「别用」。** 大量模型只要看见工具
就倾向于调，用户问「Rust 的所有权是什么意思」也会先 `ls` 一遍 workspace。
同时省下每轮上千 token 的 schema。

第一次勾选时如果还没装基座，会直接推出安装页（可选 Alpine / Ubuntu，
下载源有大陆和国际镜像可选）。装完**立刻生效，不用重启 app** ——
沙箱、装包事务的代目录、交互 shell 三处一起换过去。

---

## 三个核心设计

### 1. 回滚：三类状态，三种机制

不存在通用的「整机快照」—— 一个 Ubuntu base rootfs 有一万两千多个文件，
装几个包就上五万，每条命令前全盘扫一遍要几秒，手机上直接劝退。按变更频率拆开：

| 状态 | 机制 | 代价 |
|---|---|---|
| workspace | content-addressed **反向增量** | 毫秒 |
| 发行版 rootfs | **代目录 + 原子 rename**（`TermuxInstaller` 的手法） | 秒级 |
| 工具层写入 | 写前记 journal，零扫描 | 微秒 |

刻意**不用** hardlink 快照：`echo x >> f` 会穿透 hardlink 让快照静默失真，
而 Linux 上没有 per-file COW 可用（详见 SANDBOX.md §3.2）。

### 2. 沙箱：五层，逐层降级

Android 上没 root，user namespace 多被关，`/dev/fuse` 拿不到 ——
codex 那套 bwrap 方案搬不过来。重新组合成：

```
L0 命令策略（前缀规则 + shell 拆段）  永远可用
L1 proot 路径隔离                    永远可用
L2 seccomp 断网                     Android O+ 可用
L3 Landlock 文件系统强制             运行时探测
L4 rlimit + 杀进程组                 永远可用
```

每层探测不到就跳过，实际生效的层会显示在 UI 上 ——
用户有权知道自己被保护到什么程度。

### 3. 上下文：VPetLLM 那套 + 输出蒸馏

- `ContextLimitGuard`：从 400 错误里读出真实 `n_ctx`，**并用 `n_prompt_tokens`
  反向校准我们的 token 估算器**。手机上连本地模型时这是必需品，不是优化。
- `OverflowManager`：滚动摘要 + 滑动窗口，历史永不删除。
- `MemoryRetrieval`：BM25 + 覆盖率 + 向量三路 RRF 融合。
- **`OutputDistiller`（新增）**：终端输出是上下文杀手 ——
  一次 `pip install torch` 吐 15k token。全文落盘，上下文里只放折叠后的摘要 + `ref`，
  模型用 `grep_output(ref, pattern)` 按需回查。

---

## 目录

```
docs/                    设计文档
lib/
  main.dart              装配（只接线，不判断）
  src/
    agent/
      agent_loop.dart    主循环：策略 → 审批 → 检查点 → 执行 → 蒸馏
      tools.dart         工具定义与只读/写入工具实现
    sandbox/
      exec_policy.dart       L0 前缀规则引擎
      sandbox_session.dart   L1-L4 的 argv/env 组装
      snapshot_store.dart    workspace 反向增量回滚
      prefix_generations.dart rootfs 代目录 + 原子 rename
      pty_channel.dart       Flutter 侧 pty 通道
    bootstrap/
      distro.dart            可选发行版目录 + 下载/校验/解压/原子切换
      zip_reader.dart        central directory 随机访问，支持 ZIP64
      tar_reader.dart        tar.gz 流式，GNU 长名 / PAX / 硬链接 / 设备节点
    context/
      context_limit_guard.dart  读 n_ctx + 校准估算器
      overflow_manager.dart     滚动摘要 + 滑动窗口
      memory_retrieval.dart     BM25 / RRF / 三路融合
      output_distiller.dart     输出蒸馏 + grep_output
      token_counter.dart
android/app/src/main/
  cpp/pty.c              pty 创建（改自 termux.c，加了进程组管理）
  cpp/burrow_launch.c        沙箱启动器：seccomp / landlock / rlimit
  kotlin/.../PtyBridge.kt  MethodChannel + EventChannel
test/
  core_test.dart         策略 / 上下文 / 检索 / 快照回滚
  archive_test.dart      zip / tar 解析（用系统 tar 造真实归档）
tool/
  build_proot.sh         NDK 交叉编译 proot + talloc → jniLibs
  verify_rootfs.dart     拿真实发行版 rootfs 压测 TarReader
```

---

## 状态

Flutter 3.47.2 / Dart 3.13.2 / NDK 28.2.13676358，在 Android 模拟器
（x86_64 / API 36 / 内核 6.6.66）上跑通。

```
dart analyze lib test   →  No issues found!
flutter test            →  All tests passed!  (51 通过 / 5 跳过)
flutter build apk       →  Built app-debug.apk (41.3 MB)
adb install + am start  →  运行中
```

### 已实测通过

| 项 | 证据 |
|---|---|
| Dart 层 | analyze 零错误零警告；51 个单测覆盖策略引擎 / 上下文窗口学习 / 输出蒸馏 / BM25+RRF / 快照回滚 / zip·tar 解析 / 聊天↔终端模式切换 |
| Kotlin 桥接层 | 编译通过；`PtySession` 的 FileDescriptor 反射在 Android 16 上仍可用 |
| `pty.c` → `libburrow.so` | arm64 + x86_64 编译通过，10KB；运行时 `nativeloader: Load libburrow.so ... ok` |
| `burrow_launch.c` → `libburrow-launch.so` | 静态链接 405KB；设备上 `--probe` 返回 `{"seccomp":true,"landlock_abi":0,"rlimit":true}` |
| **L2 seccomp 断网** | 不加 filter：`ping 8.8.8.8` 通（395ms）／ 加 filter：`socket: Operation not permitted` ／ AF_UNIX 不受影响 |
| **L3 Landlock 运行时探测** | 两台设备（内核 5.10 与 6.6）均返回 ABI=0，降级逻辑生效 |
| **M1 交互终端** | Flutter 里敲 `id` 拿到真实 `uid=10215(u0_a215) ... context=u:r:untrusted_app:s0` |
| 降级模式 | 未装发行版时自动接 `/system/bin/sh`，橙色横幅标明，seccomp/rlimit 仍生效 |
| **proot 交叉编译** | `tool/build_proot.sh` 产出 arm64-v8a / x86_64 两个 `libproot.so`（310KB / 325KB） |
| **L1 proot 隔离** | 设备上 chroot 进真实 Alpine rootfs：`cat /etc/os-release` → Alpine Linux，`apk --version` → apk-tools 2.14.6 |
| **L1+L2+L4 叠加** | 联网档 `ping 10.0.2.2` 通（5.99ms）／离线档 `permission denied`／`--rlimit-nproc=1` 让 proot 连 fork 都做不了 |
| `ZipReader` / `TarReader` | 单测 + 真实 Alpine 3.21 rootfs：88 文件 / 96 目录 / **335 软链** / 0 跳过，568ms |
| 发行版校验和 | Alpine x86_64 实测 sha256 与官方 `.sha256` 一致 |
| **DistroManager 端到端** | 模拟器上从聊天页勾「终端模式」→ 跳安装页 → 走 USTC 镜像下 Ubuntu 24.04 → 校验 → 解压 → 原子 rename，全流程走通 |
| **终端模式开关** | 未装基座时勾选会推出安装页；装完自动回到聊天且开关已打开，状态条变成「路径隔离(proot) + 断网(seccomp) + 资源限制」 |
| **运行中挂载基座（不重启 app）** | 装完后交互 shell 自动重开，`ps` 里能看到 `libproot.so → sh`，shell 里 `cat /etc/os-release` 返回 Ubuntu 24.04.4 LTS |

### 尚未验证 / 未完成

| 部分 | 状态 |
|---|---|
| Debian | **整体不可用**。上游 `docker-debian-artifacts` 改成 OCI 布局后不再提供 `rootfs.tar.xz`，pin 死的两个 commit 路径实测三种取法全 404。XZ 解码链路本身是好的（有单测），等有可固定 URL + 校验和的下载点再放开。Ubuntu 24.04 覆盖同一个「glibc + apt」需求 |
| 清华 TUNA 镜像 | 本机实测对 `alpine/` 和 `ubuntu-cdimage/` 都返回 403（页面明说「您目前无法访问此页面」），疑似按来源 IP 拦。已从默认降到备选，默认改用 USTC |
| Alpine on arm64 | x86_64 上被 musl 的裸 `fork` 撞上 zygote seccomp（已在目录里按 ABI 屏蔽）。arm64 无 `__NR_fork` 所以理论上没问题，但**没有实机验证过** |
| Agent 主循环端到端 | 未接模型，只有单测 |
| 快照/回滚在设备上 | 只有单测通过，未在真机 workspace 上跑过 |

### 从零构建

```bash
flutter pub get

# 必须先编 proot —— 它没有入库（GPL 二进制，见 THIRD_PARTY.md）。
# 需要 Android NDK 28.2.13676358 和一次联网（拉 proot / talloc 源码）。
export ANDROID_NDK_HOME=~/Android/Sdk/ndk/28.2.13676358
tool/build_proot.sh arm64-v8a x86_64

flutter build apk
```

**Windows 上的一个坑**：`android/gradle.properties` 里有一条
`kotlin.incremental=false`。不加这条，`:shared_preferences_android:compileDebugKotlin`
必然失败在 `Could not close incremental caches ... *.tab`（删缓存、停 daemon、
改 in-process 策略都不管用）。报错落在插件模块上，和本项目的 Kotlin 代码无关。

**跳过第二步会怎样**：APK 照样能编能装，但没有 proot 就没有 L1 路径隔离，
app 进降级模式（接 Android 自带的 `/system/bin/sh`，没有包管理器），
UI 上有橙色横幅说明。不会变成一个难以定位的静默故障，但也确实少了半个产品。

---

## 许可证

Burrow 自身的源码采用 **[Apache License 2.0](LICENSE)** ——
可以自由使用、修改、再分发，包括商用；带专利授权；要求保留版权声明，
并在改动过的文件上注明改动。

仓库里和 APK 里还有几样第三方组件，它们**保留各自原本的许可证**：

| 组件 | 许可证 | 形式 |
|---|---|---|
| `android/.../cpp/pty.c` | Apache-2.0 | 派生自 termux-app 的 `terminal-emulator`（该库是 termux LICENSE.md 里明确列出的 GPLv3 例外） |
| proot | GPL-2.0 | 随 APK 分发的独立可执行文件，`execve` 调起，不与 app 代码链接 |
| talloc | LGPL-3.0 | 静态链接进 proot |
| 发行版 rootfs | 各软件包各自的许可证 | 运行时下载，不随 APK 分发 |

**分发 APK 前请读 [THIRD_PARTY.md](THIRD_PARTY.md)。** 里面写清了 proot 的
GPL 源码提供义务 —— 那条义务落在分发者身上，和 Burrow 自己是什么许可证无关。

### 本机网络须知

国内网络下 `services.gradle.org` 和 `repo.maven.apache.org` 会被 DNS 污染，
而 `storage.googleapis.com` 上的 120MB 引擎 jar 走代理会中途卡死。两件事都要处理：

```
# ~/.gradle/gradle.properties —— 走本地代理，但 googleapis 直连
systemProp.https.proxyHost=127.0.0.1
systemProp.https.proxyPort=10808
systemProp.https.nonProxyHosts=storage.googleapis.com|*.googleapis.com|localhost|127.0.0.1

# 环境变量 —— 引擎产物换国内镜像（这一条是关键，能把"卡死 30 分钟"变成 67 秒）
FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
PUB_HOSTED_URL=https://pub.flutter-io.cn
```

### 四个容易踩的实现细节

**`burrow-launch` 必须叫 `libburrow-launch.so`。** Android 只把 `lib/<abi>/lib*.so`
解压到 `nativeLibraryDir`，别的文件留在 APK 里没法 exec。光改名还不够 ——
还要 `useLegacyPackaging = true`，否则 AGP 让 .so 直接从 APK 里 mmap，
`System.loadLibrary` 能用但 `exec` 不行。两个开关缺一个，沙箱启动器就起不来。

**proot 不能从发行版里取。** 那是先有鸡还是先有蛋：要先能 chroot 进 rootfs
才拿得到里面的 proot。所以它和 burrow-launch 一样必须随 APK 出厂。同理，
降级模式（没装发行版）下 seccomp 断网和 rlimit 照样生效 —— 那两层和基座无关，
不该一起丢掉。

**CMake 的 `abiFilters` 要单独设一份。** `defaultConfig { ndk { abiFilters } }`
只约束打包，管不住 CMake 去编哪些 ABI。漏掉 `externalNativeBuild.cmake.abiFilters`
的后果是：armeabi-v7a 被编出 `burrow-launch` 却没有 `libproot.so`（那个是离线脚本
只为 arm64/x86_64 构建的），32 位设备装得上但沙箱起不来。

**交叉编译 proot 的四个坑**（细节见 `tool/build_proot.sh` 和 ARCHITECTURE.md §9）：
talloc 不必用 waf（bionic 够全，二十行 shim 就能单文件编）；`-DHAVE_VA_COPY`
不是可选的（aarch64 的 `va_list` 是结构体，talloc 的回退实现会破坏语义）；
特性检测必须带 `_GNU_SOURCE`（否则 `process_vm_readv` 检测不到，proot 退化成
逐字 `PTRACE_PEEKDATA`）；上游 `ashmem_memfd.c` 漏了 `<string.h>`（clang 19 直接报错）。

## 里程碑

1. ~~**M1** pty JNI + Kotlin bridge + xterm.dart，手动敲命令有回显~~ ✅ 已完成
2. ~~**M2** 发行版基座 —— 归档解析 ✅ / DistroManager ✅ / 编译 proot ✅~~ （只差设备上端到端跑一次安装）
3. **M3** Agent 单工具 `exec`，接一个 provider，流式看到输出
4. ~~**M4** ExecPolicy + proot 隔离~~ ✅（审批弹窗代码完成，未接模型验证）
5. **M5** 反向增量回滚 + 检查点时间线 ← **做完这步才算达成核心目标**
6. **M6** ContextLimitGuard + OverflowManager + OutputDistiller
7. **M7** BM25 + RRF 检索
8. ~~**M8** seccomp 断网 + landlock 探测 + rlimit~~ ✅ 已完成（提前，因为它不依赖基座）
