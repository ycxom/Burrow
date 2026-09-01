# Burrow 地洞

手机上的 LLM 客户端 —— 平时就是聊天，需要动手时它有一整台 Linux 可用。

对话、终端、检查点三个页签。聊天页是 Telegram 的样子，输入框左边第一个
图标就是「终端模式」—— 不开就是普通聊天（模型拿不到任何工具），
开了模型才能在沙箱里装包、改代码、跑脚本；搞坏了退回上一个检查点，
环境和文件一起回去。

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

## 会话、技能、账号

### 侧边抽屉

聊天页是首页，会话列表在抽屉里（不是「列表是首页、点进去再打开聊天」）。
换会话是**原地替换**而不是 push —— 从抽屉点 A 再点 B，push 的话栈里会堆
两层，按返回键回到 A 是没人预期的行为。抽屉底部是技能 / 模型账号 / 设置。

### 消息级操作

每条消息下面挂着操作栏：复制、重新生成（助手）、编辑并重发、
**回到这里**、删除这条及之后。

「回到这里」是这个 app 相对普通聊天客户端的核心能力：它**同时**截断对话
和把 workspace 回滚到发那条消息之前的状态。只做前者的话，模型会对着一个
它以为还没改过、实际已经被改过的 workspace 重新推理 —— 那种不一致比不回滚
更难查。实现上每条用户消息都记下当时的检查点代号（`messages.checkpoint`，
v3 迁移加的列）。

老会话的消息没有这个记录，这时对话框会**明说文件不会回滚**——
假装能回滚才是危险的。

### OAuth 登录（OpenAI / xAI）

两家都走 **OAuth 2.0 设备码流程**（移植自 cc-switch 的
`codex_oauth_auth.rs` / `xai_oauth_auth.rs`）。手机上这个选择比浏览器回跳
更有理由：不用开本地 HTTP 端口收 `?code=`，也不用注册自定义 URL scheme
（Android 不保证 scheme 唯一，任何同名 app 都能抢到授权码）。

两家的协议**并不一样**，这一点不能想当然：

| | xAI | OpenAI |
|---|---|---|
| 协议 | 标准 RFC 8628 | 自己一套 |
| 端点 | 从 OIDC discovery 拉 | 写死 `deviceauth/usercode` + `deviceauth/token` |
| 「还没授权」 | JSON 里 `authorization_pending` | HTTP **403/404** |
| 「已过期」 | `expired_token` | HTTP **410** |
| 轮询成功返回 | 直接给 token | 给 `authorization_code` + `code_verifier`，**还要再换一次** |

### 技能（Skills）

一个 skill 就是一个带 `SKILL.md` 的目录，头部是 YAML frontmatter
（name / description）。连接一个 GitHub 仓库（`owner/name`、
`owner/name@branch` 或直接贴网址），仓库里每个带 SKILL.md 的子目录
都是一个技能。

**渐进式披露**：开着的技能只把 name + description 两行放进系统提示，
正文留在磁盘上，模型判断相关时用 `read_skill` 工具读全文。十个 skill
全量塞进提示词上下文就没了，而绝大多数对话一个都用不上。

装在 rootfs 的 `/opt/burrow-skills/` 而不是 workspace：workspace 会被
检查点回滚，而 skill 是环境的一部分，不该跟着任务的文件改动一起被撤销。

### 模型列表获取

`GET /v1/models`，但核心不是发个 GET 而是**猜对端点**——
`/v1` 结尾的只能补 `/models`，智谱的 `/api/paas/v4` 补 `/v1/models`
会得到 404。按候选列表依次试（移植自 cc-switch 的 `model_fetch.rs`）。

失败时分两种提示：**端点不对**和**端点对了但这个 key 下没有模型**
（聚合网关没配渠道）。这两种的处理方式相反，报成同一句话会让人
往错的方向查。

---

## 界面

Telegram 风格。整套色号写死在 `lib/src/ui/chat_theme.dart` 里，
**不用 Material 的 ColorScheme 近似**：让框架按种子色推导的话，
每个色号都会差一点，叠起来就不是同一个界面了。

几个不做就"看着像但不是"的地方：

- **气泡有尾巴，而且只有一组的最后一条才有。** 连续几条同一方的消息算
  一组，中间那些是无尾圆角块、间距收到 2px。这是 Telegram 最认得出来的
  节奏；每条都加尾巴会变成一串独立的对话框。
- **时间戳在气泡里面，正文绕着它排。** 做法是在文本流末尾塞一个和时间戳
  等宽的透明占位，再把真的时间戳绝对定位到右下角 —— 于是短消息的时间跟在
  同一行，长消息才换行。占位用 `Opacity(0, child: 时间戳)` 而不是手算宽度：
  宽度取决于字体和模型名长度，手算迟早差几个像素，差几个像素的表现就是
  最后一个字被压住。助手消息是 markdown，块级元素没法和一行文字共处，
  时间只能另起一行 —— Telegram 对长消息也是这么排的。
- **收发两侧的时间戳颜色不同**（发出去偏绿/蓝、收到偏灰）。它压在气泡上，
  对比度必须很低，同一个灰在浅绿气泡上会脏。
- **聊天区有壁纸**，气泡浮在渐变上，顶栏和输入区是实心的。少了这一层就是
  "卡片列表"，不是聊天。暗色下日期胶囊要比壁纸**亮** —— 用半透明黑会比
  背景还深，实测就是只看得见字。
- **底部没有页签栏，那一条给了模型切换器**。终端是给模型用的，用户偶尔进去
  看一眼，不值得占一整格；真正会反复做的动作是换模型 —— 换个更强的重答一次、
  换个便宜的接着聊。终端和检查点收进顶栏右上角，点亮的那个再点一次回对话，
  返回键也回对话。
- **顶栏是「标题 + 一行状态」**。Telegram 在第二行放「在线 / 正在输入」，
  我们放模型名和这一轮会怎么执行。状态是瞬时的，几秒后自己撤回去 ——
  不撤的话副标题会永远停在最后一条状态上，而沙箱档位恰恰是要求一直可见的。
- **消息操作走长按菜单**，气泡上不挂按钮。**这次换皮肤真正丢掉的东西是
  「回到这里」不再一眼可见** —— 它是这个 app 相对普通聊天客户端的核心能力，
  现在藏在长按里了。
- **亮/暗**跟随系统，两套色号各自写全，不是从一套里推另一套。

排版不再可选（原来有「气泡 / 左对齐」两档），Telegram 就一套样子。

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
| **底栏改模型快切** | 模拟器上换对话模型 → prefs 写入 → 芯片和顶栏副标题同时跟着变（副标题读的是 settings，芯片读的也是，两处一致说明推送到了运行中的客户端）。选择器会自动从服务端拉列表、可搜索。终端/检查点移到顶栏，点亮再点回对话，返回键也回对话 |
| **嵌入式记忆检索端到端** | 接真实网关跑通：摘要触发 → `retrieval.index` 发 `/embeddings` → 撞上网关 5 条上限 422 → 自动降批重试成功 → 检索注入 `[检索到的历史记录]` → 模型据此答出「torch —— 你 17 分钟前说的」。**同一个问题的前后两轮是对照组**：摘要建立前它答「你从来没告诉过我你最喜欢的包」 |
| **Telegram 风格界面** | 模拟器上亮/暗两套都核对过：壁纸渐变、带尾巴的气泡、连续消息分组（只有末条有尾巴和头像）、日期胶囊、长按菜单（复制 / 编辑并重发 / 回到这里 / 删除）。短消息的时间戳确实内联在同一行（`say OK in two words  00:22`），发送键在生成时变成停止键。接真实网关发了一轮，端到端正常 |
| **技能端到端** | 模拟器上连接真实的 `anthropics/skills`：下载 zipball → 解析 central directory → 找出全部 SKILL.md → 解析 frontmatter → 安装 `claude-api` 到 `rootfs/opt/burrow-skills/`，文件内容核对无误 |
| **模型列表获取** | 对真实 new-api 网关（`/v1/models` → 200 但空列表）给出的是「服务端没配渠道」而不是「端点不对」 |
| **OAuth 设备码** | OpenAI 端点实测可达，返回的是 OpenAI 自己的地区限制错误（`unsupported_country_region_territory`）并被原样呈现 —— 说明请求格式被接受，不是 400 |
| **对话回滚** | 「回到这里」在真机上截断对话并持久化；老消息（无检查点记录）会明确提示文件不会回滚 |
| **侧边抽屉** | 会话原地替换、搜索、长按重命名/删除、三个入口全部可用 |
| **M3 Agent 端到端** | 接真实网关（new-api / GLM-5）跑通完整回合：发工具 schema → 模型发起 `exec` → 策略放行 → proot 沙箱内执行 → OutputDistiller 蒸馏 → 结果回喂 → 模型据此作答。库里能看到完整的 tool 消息（`$ cat /etc/os-release` / `[exit 0, 179ms, 14 行 / 413B, ref=…]`）和用户消息上的检查点代号 |
| **Skill 被模型主动调用** | 装了 `claude-api` 之后问 Claude 模型 ID：模型自己调 `read_skill` 读全文，再照着手册作答。**同一个问题的前后两轮恰好是对照组** —— 没读 skill 时答的是「截至 2024 年底…Claude 3.5 Sonnet」，读了之后答的是手册里的 Fable 5 / Opus 5 |
| **聊天模式人格** | 关掉终端模式时模型明说「我无法联网……请在输入框下方勾选终端模式」，没有假装自己执行了什么 |
| **「Agent 与终端」三个子页** | 原先是三个只有箭头没有 `onTap` 的 `const ListTile`。接上之后模拟器上逐个点过：沙箱模式（改档位 → 写进 prefs → 列表副标题跟着变；选「关闭沙箱」弹确认；能力芯片来自真实探测，本机 Landlock 显示不可用；7 条禁令来自策略表本身）、默认工作目录（真实路径、13 个会话目录及占用、删除一个后磁盘上确实只剩 12）、上下文与检查点（阈值滑杆写进 prefs） |
| **设置改动当场生效** | 聊天页顶部的审批档位按钮改成写回 SettingsStore，选「自动执行」后 prefs 变成 `auto`，同时按钮标题也变了 —— 而它读的是 `_agent.mode`，所以这一步证明了监听器确实把设置应用到了**正在进行的会话**上，不用新建对话 |
| **滚动摘要** | 长 SKILL.md 进上下文后触发 `OverflowManager`，状态条显示「已整理长期记忆（摘要覆盖到第 3 条）」 |

### 尚未验证 / 未完成

| 部分 | 状态 |
|---|---|
| Debian | **整体不可用**。上游 `docker-debian-artifacts` 改成 OCI 布局后不再提供 `rootfs.tar.xz`，pin 死的两个 commit 路径实测三种取法全 404。XZ 解码链路本身是好的（有单测），等有可固定 URL + 校验和的下载点再放开。Ubuntu 24.04 覆盖同一个「glibc + apt」需求 |
| 清华 TUNA 镜像 | 本机实测对 `alpine/` 和 `ubuntu-cdimage/` 都返回 403（页面明说「您目前无法访问此页面」），疑似按来源 IP 拦。已从默认降到备选，默认改用 USTC |
| Alpine on arm64 | x86_64 上被 musl 的裸 `fork` 撞上 zygote seccomp（已在目录里按 ABI 屏蔽）。arm64 无 `__NR_fork` 所以理论上没问题，但**没有实机验证过** |
| OAuth 完整登录 | 协议实现有单测（含 403/410/slow_down 等分支）。但本机线路上 `auth.openai.com` 返回地区限制、`auth.x.ai` 直连超时，**没有真正走完一次登录换到 token** |
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

### 接口地址少一段 `/v1` 会静默失败

值得单独写一条，因为它把每一层都伪装成了成功：

Base URL 填服务根地址（`http://gateway:3000`，聚合网关的常见填法）时，
直接拼 `/chat/completions` 会打到**网关的前端页面**上。那个路径返回的是
**HTTP 200 + 一坨 HTML**，不是 4xx。于是：

1. 状态码检查通过 → 不抛
2. SSE 解析找不到 `data:` 行 → 返回空字符串 → 不抛
3. Agent 拿到空回合 → 什么都不加进历史 → 不抛

界面上的表现是「消息发出去了，没有任何回应，也没有报错」。
这是实测踩到的，修法有三处：

- `resolveApiEndpoint()` 统一负责补版本段（`/v1`、或者沿用 `/v4`），
  chat / messages / summarize / testConnection **四个地方都走它**；
- 一个回合既没有文本也没有工具调用时抛 `EmptyCompletionException`，
  错误信息直接指向「接口地址可能不对」；
- `summarize()` 永远不抛 —— 它是尽力而为的优化，
  `jsonDecode('<!doctype html>')` 的异常不该让用户这句话整个失败。

### 滚动摘要一直没生效 —— 三个 bug 叠在一起

实测「聊天模式下连聊十几轮，`checkpoint` 一直是 0」，查下去是三个独立的
bug 串在一条链上，每一个单独看都不显眼，而且**全都不会报错**：

1. **摘要检查写在工具轮循环的末尾。** 没有工具调用时
   `if (turn.toolCalls.isEmpty) break;` 会先跳出去，检查一次都执行不到 ——
   于是纯聊天的会话永远不摘要。而聊天模式恰恰最需要它：没有工具输出可蒸馏，
   全是原文。修法是在循环**外面**再查一次。
2. **`either` 模式下判定和切点用的不是同一个标准。** `_shouldSummarize`
   按条数说该摘要了，`_findCheckpoint` 却只按 token 找位置，短消息攒再多也
   累不到 token 阈值，返回的还是老 checkpoint，`_summarizeUpTo` 直接
   early return。表现是"判定说要做，实际什么都没做"，而且每加一条消息重算一遍。
   修法是两条都算，取更靠后的那个（两条约束都要满足）。
3. **摘要模型是空字符串。** 设置页留空时存进 prefs 的是 `''` 而不是 null，
   `summaryModel ?? model` 对空串不成立，于是摘要请求带着 `"model": ""`
   发出去，服务端 400。而 `summarize()` 是**永不抛**的（见上一节），
   所以它静默返回空，摘要永远建立不起来。

三个都修完之后，副标题上出现了「已整理长期记忆（摘要覆盖到第 13 条）」，
下一轮的检索也跟着跑起来了。

**这一串的共同点**：每一层都"成功"了，没有任何一处抛异常。和 `/v1` 那次
是同一类病 —— 静默降级用错了地方，就变成静默失效。

### 嵌入式记忆检索

`MemoryRetrieval` 的第三路（向量余弦）原来一直是空的：`Embedder` 抽象在，
但没有任何实现，`main.dart` 里构造的是 `MemoryRetrieval()`。现在接上了
OpenAI 兼容的 `/embeddings`，在输入框上面那条切换器里选嵌入模型即可，
留空就是不启用（检索退回 BM25 + 覆盖率两路词法）。

两个不做就会悄悄给出错误结果的地方：

- **按 `index` 字段对齐，不按数组下标。** 规范允许服务端乱序返回。
  按下标取的话，每条记忆配上别人的向量 —— 检索不会报错，只会永远
  给出莫名其妙的结果。数量对不上时**一条都不存**，同理。
- **批大小是运行时学出来的。** 各家网关对 `input` 数组的上限差得很远：
  OpenAI 官方 2048，而实测某个聚合网关只给 5 条（超了 422
  `input最多支持 5 条`）。写死一个数就是在赌。现在碰到"这批太大"就对半砍
  再试，砍到能过为止并记住 —— 和沙箱能力探测同一个思路：
  **不在编译期假设服务端的限制**。401 这类降批也不会好转的错误不重试。

换嵌入模型时会清空已有向量：不同模型的向量不在同一个空间里，混着算余弦
得到的是无意义的数。

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
