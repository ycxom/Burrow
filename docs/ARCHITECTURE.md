# Burrow 架构设计

手机上的 LLM 客户端：平时是聊天，需要动手时有一整台 Linux 可用。
可选的发行版 rootfs（Alpine / Ubuntu）+ proot 做基座，Flutter 做 UI，
沙箱保证 LLM 把环境搞坏之后能回滚。

**两种用法共用一套东西**，这是分层的前提：聊天走的是同一个上下文引擎
（§6），干活走的是同一个沙箱（§4）。区别只在于这一轮模型有没有发起工具调用。

---

## 0. 四个参考源分别贡献了什么

| 来源 | 复用的部分 |
|---|---|
| `termux-app` | `terminal-emulator` 的 pty JNI（`createSubprocess` / `setPtyWindowSize` / `waitFor`）；`TermuxInstaller` 的 **staging 目录 + 原子 rename** 安装法 —— 这是整个回滚机制的原型。**注意：只借这两样，不用它的 bootstrap**，理由见 §2 |
| `codex/codex-rs` | `SandboxPolicy` 的三档模型（`read-only` / `workspace-write` / `danger-full-access`）；`execpolicy` 的 `Decision{Allow, Prompt, Forbidden}` 前缀规则引擎；`linux-sandbox` 的 seccomp 断网 + `no_new_privs` |
| `VPetLLM` | `ContextLimitGuard`（从 400 错误里读出真实 n_ctx 并反向校准 token 估算器）；`OverflowManager`（滚动摘要 + 滑动窗口，历史永不删除）；`MemoryRetrievalService`（BM25 + 覆盖率 + 向量三路 RRF 融合排序） |
| `chatbox` | provider 抽象、流式解析、`tool-call-json-repair`（小模型吐坏 JSON 的修复）、`persistent-tool-call-pause` |
| `cc-switch` | 多渠道配置切换的数据模型 |

---

## 1. 分层

```
┌──────────────────────────────────────────────────────────┐
│  Flutter UI  (lib/src/ui)                                │
│  聊天流 · 终端视图(xterm.dart) · 检查点时间线 · 审批弹窗    │
├──────────────────────────────────────────────────────────┤
│  Agent Core  (lib/src/agent)                             │
│  turn loop · 工具分发 · 审批策略 · 输出蒸馏                 │
├──────────────────┬───────────────────────────────────────┤
│ Context Engine   │  Sandbox Engine (lib/src/sandbox)      │
│ (lib/src/context)│  ExecPolicy · SnapshotStore · Session  │
│ 滚动摘要/检索/预算 │                                       │
├──────────────────┴───────────────────────────────────────┤
│  Platform Channel  (MethodChannel + EventChannel)         │
├──────────────────────────────────────────────────────────┤
│  Android Native (Kotlin + JNI)                            │
│  PtyBridge · seccomp/landlock launcher · 快照 IO            │
├──────────────────────────────────────────────────────────┤
│  基座: proot + 发行版 rootfs (Alpine / Ubuntu)             │
└──────────────────────────────────────────────────────────┘
```

**关键分工原则**：原生层只做 Dart 做不了的事（fork/exec + pty、seccomp、landlock、大目录扫描）。
所有策略判断、上下文管理、检索排序都在 Dart 里 —— 因为这些要频繁迭代，而且要能写单元测试。

---

## 2. 基座：发行版 rootfs + proot（不是 Termux bootstrap）

### 2.1 为什么放弃自建 Termux bootstrap

Termux 的二进制里 **硬编码了 `/data/data/com.termux/files/usr`**
（见 `TermuxConstants.TERMUX_PREFIX_DIR_PATH` 的注释：*"The binaries compiled for termux have
TERMUX_PREFIX_DIR_PATH hardcoded in them"*）。要用在自己的包名下，就得 fork
`termux-packages`、设 `TERMUX_APP_PACKAGE=com.burrow` 把整套包重编一遍 ——
一条要长期维护的构建流水线。

**换成发行版 rootfs 之后这个问题自己消失了。** Ubuntu / Debian / Alpine 的二进制
硬编码的是 `/usr`、`/lib`、`/etc` 这些标准 FHS 路径，而 proot 的 `-r <rootfs>`
正是把这些路径重定向到我们目录下的机制。官方 base tarball 直接可用，不需要重编任何东西。

| | 自建 Termux bootstrap | 发行版 rootfs |
|---|---|---|
| 构建流水线 | 要 fork + 维护 | **不需要** |
| 软件源 | 自己维护 | 官方 apt / apk |
| 用户可选 | 只有一种 | **Alpine / Ubuntu / …** |
| 首次安装 | 打进 APK（APK 变大） | 联网下载 3~30MB |
| 运行开销 | 无 | proot 的 ptrace，重 I/O 下慢 20~40% |
| 回滚 | 代目录 + rename | 一样，且更干净（rootfs 就是个普通目录） |

代价是必须有 proot，而且它**不能从发行版里取** —— 那是先有鸡还是先有蛋：
要先能 chroot 进 rootfs 才拿得到里面的 proot。所以 proot 和 `burrow-launch` 一样，
由我们自己用 NDK 编译、伪装成 `libproot.so` 打进 APK（见 §3.1）。

### 2.2 目录布局

```
/data/data/com.burrow/files/
├── distros/
│   ├── alpine-3.21/
│   │   ├── rootfs/           # agent 眼里的 /
│   │   ├── rootfs.staging/   # 装包事务的暂存
│   │   ├── rootfs.gen/       # 环境代 000001/ 000002/ ...
│   │   └── .installed        # 哨兵：解压到一半被杀不会被当成装好了
│   └── ubuntu-24.04/…
└── sandbox/
    ├── workspace/            # agent 眼里的 /workspace，唯一常态可写区
    ├── objects/              # content-addressed 旧内容仓库（回滚用）
    ├── outputs/              # 命令全文输出，供 grep_output 回查
    ├── meta/                 # 检查点日志 + 清单 + HEAD
    └── rootfs/               # （降级模式占位）
```

### 2.3 目录（catalog）为什么写死在代码里

`DistroCatalog` 的 URL 和 sha256 是编译期常量，不从服务器拉一个「目录文件」。

一个可远程更新的目录等于给自己开了一个「换掉用户 rootfs 来源」的后门，
而这个 app 的全部意义就是在受控环境里跑不受信任的代码。加发行版就发版本更新。

**sha256 不是可选项。** 这是从网上下一坨东西然后在里面执行代码；
本机实测已经证明这条链路上的 DNS 是被污染的（见 README 的构建须知）。
校验失败直接丢弃并报错，不给「要不要继续」的选项。

### 2.4 解压：自己写的 tar / zip 解析器

不用 `package:archive`：它会把整个归档连同解压结果一起留在内存里，
Ubuntu base 解开 130MB，中低端机直接 OOM。

- `ZipReader` —— 走 **central directory 随机访问**。这样才能在解压前拿到
  条目总数（否则没法显示进度）和 Unix 权限位（它只存在于 central directory 的
  `externalFileAttributes` 高 16 位，local header 里没有；丢了权限位解出来的
  `bin/sh` 不可执行）。支持 ZIP64 —— 完整 rootfs 的条目数会超过经典格式 65535 的上限。
- `TarReader` —— 流式。tar 没有中央目录且外面套着 gzip（不可 seek），只能顺序读，
  代价是拿不到条目总数，进度只能按字节估。必须处理 GNU 长文件名（'L'）、
  PAX 扩展头（'x'）、硬链接（'1'）、设备节点（'3'/'4'，无 root 建不了，跳过并记录）
  和 base-256 数值 —— 真实 rootfs 里这些全都有。

实测：Alpine 3.21 minirootfs（3.35MB）解析出 88 个文件 / 96 个目录 /
**335 个符号链接** / 0 跳过，桌面上 568ms，`/bin/sh -> /bin/busybox` 正确解出。

---

## 3. 终端能力：pty 走原生，渲染走 Flutter

**不复用** termux 的 `TerminalView`（Android View）。用 PlatformView 嵌一个安卓 View 进 Flutter，
键盘处理、主题、选中复制会和 Flutter 层割裂，而且 Agent 需要的是**可编程的字节流**，不是一块屏幕。

采用：原生只留 pty，Dart 侧用 `xterm.dart` 做模拟器 + 渲染。

```
Dart                          Kotlin                     JNI (pty.c)
────                          ──────                     ───────────
Terminal (xterm.dart)
  ↑ EventChannel(bytes) ←── readerThread ←──────────── read(ptmx_fd)
  ↓ MethodChannel.write ──→ write(fd, bytes) ────────→ write(ptmx_fd)
  ↓ MethodChannel.resize ─→ setPtyWindowSize ────────→ ioctl(TIOCSWINSZ)
                            waitFor(pid) ────────────→ waitpid
```

`pty.c` 直接改自 `termux-app/terminal-emulator/src/main/jni/termux.c`：
`open("/dev/ptmx") → grantpt/unlockpt → fork → setsid → TIOCSCTTY → execvp`。
相对原版加了 `setpgid` —— Agent 场景没有终端驱动帮忙转发 Ctrl-C，
超时时必须自己 `killpg` 掉整棵进程树，否则 `make -j8` 拉起的 gcc 会变成孤儿继续烧电。

### 3.1 随 APK 出厂的两个原生二进制

`burrow-launch`（沙箱启动器）和 `proot`（路径隔离）都由我们自己用 NDK 编译，
**不从发行版里取**。proot 尤其不能 —— 那是先有鸡还是先有蛋。

Android 只把 `lib/<abi>/lib*.so` 解压到 `nativeLibraryDir`，别的文件留在 APK 里
没法 exec。所以一个需要被 exec 的原生小程序必须**伪装成 `.so`**：

```cmake
set_target_properties(burrow-launch PROPERTIES
    PREFIX "lib" OUTPUT_NAME "burrow-launch" SUFFIX ".so")
```

光改名还不够。现代 AGP 默认 `useLegacyPackaging = false`，.so 直接从 APK 里 mmap，
`System.loadLibrary` 能用但 `exec` 不行。两个开关缺一个，启动器就永远起不来：

```kotlin
packaging { jniLibs { useLegacyPackaging = true } }
```

**一个 pty，两种消费者**：
- **交互会话**：用户手动敲命令，字节流直接进 xterm.dart。
- **Agent 会话**：Agent 发的每条命令用独立、非交互的 pty，输出走「输出蒸馏」（见 §6.6）后才进上下文。
  绝不让 Agent 和用户共用一个 shell —— 否则 Agent 的 `cd` 会污染用户的会话，用户的 `export` 会污染 Agent 的可复现性。

---

## 4. 沙箱：五层，逐层降级

Android 上没 root，`CONFIG_USER_NS` 多数被关（bwrap 用不了），`/dev/fuse` 拿不到（overlayfs 用不了）。
所以不能照搬 codex 的 Linux 方案，得重新组合。详见 [SANDBOX.md](SANDBOX.md)。

| 层 | 机制 | 可用性 | 挡住什么 |
|---|---|---|---|
| **L0 策略** | 命令前缀规则引擎（抄 codex `execpolicy`） | 永远可用 | `rm -rf /`、`apt remove`、`curl \| sh` 这类在**执行前**就该拦下的 |
| **L1 路径隔离** | `proot -r <发行版 rootfs> -b workspace:/workspace` | 需要随 APK 出厂的 proot（§3.1） | agent 看不见真 HOME、`/sdcard`、其它 app 数据 |
| **L2 断网** | seccomp-bpf 拦 `socket(AF_INET/AF_INET6)` → `EPERM`，然后 execve | 永远可用（Android O 起强制支持 seccomp） | 离线模式下的偷偷外传 / 拉恶意脚本 |
| **L3 文件系统强制** | Landlock，运行时探测 ABI，不支持就跳过 | 机会性（GKI 5.15+ 部分开启） | proot 的 ptrace 逃逸兜底 |
| **L4 资源** | `RLIMIT_NPROC/FSIZE/AS/CPU` + 超时杀进程组 | 永远可用 | fork 炸弹、写满存储、跑飞的编译 |

L1 的 proot 是 ptrace 实现的，理论上有逃逸面（早期 `clone` 边界的已知问题）。
所以 **proot 是隔离手段，不是安全边界**；真正的安全边界是 Android 自己的 app sandbox ——
agent 再怎么逃也只在本 app 的 UID 里，碰不到别的 app。L3 是对同 UID 内数据（用户真实 HOME、
API key、聊天数据库）的额外一道墙。

---

## 5. 回滚：三类状态，三种机制

**核心判断：不存在一个通用的「整机快照」，硬做会慢到不可用。**
一个 Ubuntu base rootfs 有一万两千多个文件，装几个包就上五万；
每条命令前全盘扫一遍要好几秒，手机上直接劝退。
所以按「谁会变、多久变一次、变化量多大」拆成三类，各配各的机制。

| 状态 | 变更来源 | 快照机制 | 典型代价 |
|---|---|---|---|
| **workspace** 代码/数据 | 几乎每条写命令 | content-addressed **反向增量** | 毫秒 ~ 百毫秒 |
| **发行版 rootfs** 包环境 | `apk add` / `apt install` / `pip install` | **代目录 + 原子 rename**（hardlink 复制） | 秒级 |
| **工具层写入** | `write_file` / `apply_patch` | 写前直接记 journal，**零扫描** | 微秒 |

### 5.1 为什么不用 hardlink 快照（cp -al / rsync --link-dest）

hardlink 快照有个致命缺陷：**in-place 修改会穿透**。
`echo x >> f` 直接改 inode，快照里那份 hardlink 内容跟着变，快照静默失真。
（`sed -i` 是 rename 所以安全，但你没法要求 LLM 只用 rename 语义的工具。）
Time Machine 靠 APFS clonefile 绕开，Linux 上没有 per-file COW 可用。

### 5.2 反向增量（workspace 用这个）

工作副本永远是最新的；每一代只保存「**要回滚回去所需要的旧内容**」。

```
checkpoint(N):
  扫描 workspace → 清单 {path: (mtime, size, mode, inode)}
  与 gen(N-1) 清单 diff
  对每个 modified/deleted 的文件：把【旧内容】写进 objects/<sha256>
  记 gen(N).jsonl:  {op: modified, path, old_blob: sha256}
                    {op: created,  path}                  ← 回滚 = 删掉
                    {op: deleted,  path, old_blob: sha256}
```

回滚到第 K 代 = 从 HEAD 往回逐代 apply 反向增量。
好处：完全躲开 hardlink 污染；objects 去重（同一个文件反复改只存不同版本）；
扫描只覆盖 workspace（几百到几千个文件），毫秒级。

### 5.3 代目录 + 原子 rename（发行版 rootfs 用这个）

这就是 `TermuxInstaller` 的手法，我们把它变成常规操作：

```
apt install foo:
  1. cp -al rootfs rootfs.staging      # hardlink 复制，秒级、几乎不占空间
  2. 在 rootfs.staging 里跑 apt        # dpkg 是 unlink-then-create，
                                       #   从不 in-place 追加 → hardlink 安全
  3. 成功: mv rootfs rootfs.gen/00000N && mv rootfs.staging rootfs   # 原子切换
     失败: rm -rf rootfs.staging                                     # 什么都没发生
```

换成发行版基座之后这套机制比原方案更贴合：整个 rootfs 就是一个普通目录，
没有跨目录的硬编码路径要照顾，一次 rename 就整体换掉。
`AgentLoop._runInPrefixTransaction` 在事务期间把 `SandboxSession.rootfsPath`
指向 staging 副本，于是装包过程的一切写入天然落在副本里。

第 2 步的前提要说清楚：**dpkg/apt 从不 in-place 修改已有文件**，它总是写新文件再 rename。
所以对包管理器而言 hardlink 复制是安全的 —— 这条前提对普通 shell 命令不成立，
这也正是 workspace 必须用反向增量的原因。

### 5.4 工具层 journal（最精确的一层）

Agent 通过 `write_file` / `apply_patch` 改文件时，我们在写之前就知道旧内容，
直接存进 objects 并记 journal。**不需要任何扫描，100% 精确。**
只有当 Agent 走 `exec` 跑任意 shell 命令时，才需要退回到 5.2 的扫描式快照。

推论：**尽量把改动引导到工具层**。系统提示词里明确要求编辑文件用 `apply_patch` 而不是 `sed -i`，
既省 token 又让回滚变廉价。这条和 codex 的设计取向一致。

### 5.5 检查点时机

- 每个 turn 开始自动打一个（免费，因为多数 turn 不写文件，diff 为空）
- `ExecPolicy` 判定为 mutating 的命令执行前强制打一个
- 用户手动打（UI 上一个按钮）
- 每个检查点带一句 LLM 生成的摘要，在时间线上可读

---

## 6. 超长上下文（移植自 VPetLLM，加了手机端特有的一层）

详见 [CONTEXT.md](CONTEXT.md)。五个部件：

1. **`TokenCounter`** —— 本地估算，中文按字符、英文按词根加权。
2. **`ContextLimitGuard`** —— 从 400 错误体里正则抠出 `n_ctx` / `n_prompt_tokens`，
   **并用后者反向校准估算器的倍率**。这一步是 VPetLLM 里最值钱的设计：光知道服务端窗口是 8192
   没用，还得知道「我的尺子比服务端短了多少」，否则按自己的尺子量出 5000 以为没超，照发不误，再挨一次 400。
3. **`OverflowManager`** —— 滚动摘要 + 滑动窗口。摘要是**单份滚动文本**（每次把当前摘要喂回去生成完整新版），
   不是摘要链；历史**永不删除**，只是不进 prompt 窗口。
4. **`RecordManager`** —— 带权重的重要记录，随对话轮次衰减，被命中则加权。
5. **`MemoryRetrievalService`** —— 三路召回 RRF 融合：BM25（IDF 加权）/ 覆盖率 / 向量余弦。
   `final = 0.5·rrf + 0.25·importance + 0.25·recency`。
   RRF 只看排名不看分数，所以三路量纲不同（BM25 无上界、覆盖率 [0,1]、余弦 [-1,1]）也能融合。

**第 6 个部件是本项目新增的，因为终端场景才有**：

6. **`OutputDistiller`（输出蒸馏）** —— 终端输出是上下文杀手。
   一次 `pip install` 能吐几万 token，一次 `find /` 能吐十万。VPetLLM 是聊天场景，没这个问题。

   做法：命令输出**全文落盘**进 objects，只把 `head(N) + tail(M) + 统计行` 放进上下文，
   附一个 `output_ref`。Agent 想看细节就调 `grep_output(ref, pattern)` 按需取。
   再叠一层针对性规则：进度条行（`\r` 刷新）折叠、重复行折叠、
   编译输出只留 error/warning、`apt` 输出只留结果行。

---

## 7. Agent 循环与工具集

```dart
while (true) {
  final prompt = contextEngine.build(history, userInput);   // §6
  final delta  = await llm.stream(prompt, tools);
  if (delta.toolCalls.isEmpty) break;
  for (final call in delta.toolCalls) {
    final decision = execPolicy.evaluate(call);             // §4 L0
    if (decision == Decision.forbidden) { reject(); continue; }
    if (decision == Decision.prompt && !autoApprove) {
      if (!await ui.askApproval(call)) { reject(); continue; }
    }
    if (call.isMutating) await snapshots.checkpoint(reason: call.summary);
    final out = await sandbox.run(call);                    // §4 L1-L4
    history.add(outputDistiller.distill(out));              // §6.6
  }
}
```

工具集：

| 工具 | 说明 |
|---|---|
| `exec` | 沙箱内执行命令，流式输出，带超时 |
| `read_file` / `list_dir` / `grep` | 只读，永远 `Allow`，不触发检查点 |
| `write_file` / `apply_patch` | 走工具层 journal（§5.4），精确回滚 |
| `checkpoint` / `rollback` / `list_checkpoints` | 显式暴露给 LLM —— 让它自己在动手前存档、搞砸后回滚 |
| `recall_memory` | 主动检索被摘要挤出上下文的历史（§6.5） |
| `grep_output` | 按 `output_ref` 回查被蒸馏掉的完整输出（§6.6） |

**把 `rollback` 交给 LLM 自己用**是有意的：比起让它小心翼翼，不如让它知道「搞砸了能撤」，
反而敢做更彻底的尝试。这也是 §5 必须做到毫秒级的原因 —— 慢了它就不敢用了。

---

## 8. 审批模式

抄 codex 的四档，语义对齐：

| 模式 | 行为 |
|---|---|
| `readonly` | 只允许只读工具，任何写/exec 一律拒 |
| `on-request`（默认） | 策略判 `Allow` 的自动跑；`Prompt` 的弹框问；`Forbidden` 的直接拒 |
| `auto` | `Allow` + `Prompt` 都自动跑，但强制开检查点；`Forbidden` 仍拒 |
| `yolo` | 关沙箱关审批。UI 上要有明显的红色状态条 |

---

## 9. 首版落地顺序

| 阶段 | 里程碑 | 状态 |
|---|---|---|
| M1 | 终端能跑通 —— pty JNI + Kotlin bridge + xterm.dart，手动敲命令有回显 | ✅ 真机验证 |
| M8 | 加固 —— seccomp 断网 + landlock 探测 + rlimit | ✅ 真机验证（提前，它不依赖基座） |
| M2a | 归档解析 —— ZipReader（central directory + ZIP64）、TarReader（GNU/PAX/硬链接） | ✅ 单测 + 真实 Alpine rootfs 验证 |
| M2b | 发行版基座 —— DistroCatalog / DistroManager，下载+校验+解压+原子切换 | ⏳ 代码完成，未在设备上端到端跑过 |
| M2c | 编译 proot —— NDK 交叉编译 proot + talloc（`tool/build_proot.sh`） | ✅ 真机验证：在 Alpine rootfs 里跑通 `apk` |
| M3 | Agent 单工具 —— 只有 `exec`，接一个 provider，流式看到输出 | ⏳ 代码完成，未接模型验证 |
| M4 | 沙箱 L0+L1 —— ExecPolicy + proot 隔离 + 审批弹窗 | ✅ L0 单测；L1 真机验证 |
| M5 | 回滚 —— 反向增量 + 检查点时间线（**做完这步才算达成核心目标**） | ⏳ 单测通过，未在设备上跑过 |
| M6 | 上下文 —— ContextLimitGuard + OverflowManager + OutputDistiller | ⏳ 代码完成 + 单测 |
| M7 | 检索 —— BM25 + RRF + 可选向量后端 | ⏳ 代码完成 + 单测 |

### proot 的构建（`tool/build_proot.sh`）

proot 不用它自带的 GNUmakefile 构建，原因有两个：那份 makefile 假设
`gcc -m32` 能生成 32 位目标，而 clang 对 aarch64 根本不认这个 flag ——
32 位 loader 必须换成 `armv7a-linux-androideabi` 这个 target triple，
不是加一个编译选项；另外在 Windows 上跑 GNU make 本身就要绕一大圈。

脚本自己走一遍那套流程，顺便把 makefile 里的隐式依赖显式化。踩到的四个坑：

1. **talloc 不必用 waf。** bionic 已经提供了它需要的一切，给一个二十行的
   `replace.h` shim 就能单文件编过，整套 samba 构建系统可以跳过。
2. **`-DHAVE_VA_COPY` 不是可选的。** 不定义的话 talloc 会用 `(dest)=(src)`
   顶替 `va_copy`，而 aarch64 的 `va_list` 是结构体 —— 那样会破坏
   「两个 va_list 独立遍历」的语义。
3. **特性检测必须带 `CPPFLAGS`。** bionic 把 `process_vm_readv/writev`
   挡在 `_GNU_SOURCE` 后面。漏掉这个宏，检测报「无」，proot 就退化成按字长
   `PTRACE_PEEKDATA` 逐字读 tracee 内存 —— 能跑，但每次读内存都多一轮系统调用。
4. **上游 `ashmem_memfd.c` 漏了 `<string.h>`。** 老编译器只报 warning，
   clang 19 按 C99 规则直接报 error。这不是「新编译器太严格」——隐式声明下
   `memset` 的返回指针会被截成 `int`，是实打实的未定义行为。脚本自动补上。

产物放进 `jniLibs/<abi>/libproot.so`，由 AGP 直接打包。**CMake 的
`abiFilters` 要单独设一份**：`ndk { abiFilters }` 只约束打包，管不住 CMake
去编哪些 ABI，漏了它会得到「armeabi-v7a 有 burrow-launch 没 proot」的残缺组合。

另一个待办：**Debian 用不了**，因为官方只发布 `.tar.xz` 的 base rootfs，
而 Dart 没有内置 xz 解码。要么在原生层接 liblzma（~150KB，可以和 proot 一起编），
要么走 Docker Registry 的匿名 token 拉 gzip 层。目前 Ubuntu 已覆盖
「要 glibc + apt」这个需求，所以 Debian 在目录里被明确标为不可用而不是悄悄隐藏。
