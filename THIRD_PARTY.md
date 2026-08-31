# 第三方组件与许可证

Burrow **自身的源码是 Apache-2.0**（见 [LICENSE](LICENSE)）。
下面这些是别人的东西，**各自保留原本的许可证** —— 已经以 Apache-2.0 / GPL
发布的代码不会因为被放进这个仓库就改变许可条款。

Burrow 会**随 APK 分发**其中一部分。分发 APK 的人需要连带满足它们的许可证义务，
所以这里把来源、许可证和义务写清楚。

---

## 随 APK 一起分发的二进制

### PRoot — GPL-2.0

- 来源：<https://github.com/termux/proot>（termux 的 fork，带 Android 必需的补丁）
- 版权：STMicroelectronics（Compilation Expertise Center）及后续贡献者
- 打包形式：`lib/<abi>/libproot.so`、`libproot-loader.so`、`libproot-loader32.so`
  —— 名字是 `.so` 只为让 Android 把它解压到 `nativeLibraryDir` 并可执行，
  实际上是三个独立可执行文件（见 ARCHITECTURE.md §3.1）
- 调用方式：**独立进程，通过 `execve` 调起**，不与 app 代码链接

**义务**：分发含 proot 的 APK 时，必须同时提供 proot 的对应源码，
或提供一份获取源码的书面承诺。本仓库通过 `tool/build_proot.sh` 记录了
确切的源码出处、版本与构建步骤 —— 那份脚本本身就是「对应源码」的指引。
如果你要正式分发，建议把构建时实际用到的 proot 源码存档一并发布。

> proot 以独立进程运行、只通过 `execve` 调用，所以按通行理解它不会把
> Burrow 自身的代码变成衍生作品。但**分发它的二进制这件事本身**仍然
> 落在 GPL-2.0 的义务范围内，与是否链接无关。

### talloc — LGPL-3.0

- 来源：<https://www.samba.org/ftp/talloc/>
- 打包形式：静态链接进 proot（proot 的唯一硬依赖）
- 由于它只存在于 GPL 的 proot 里面，实际义务并入上面那条

---

## 派生的源码

### `android/app/src/main/cpp/pty.c` — Apache-2.0

派生自 termux-app 的 `terminal-emulator/src/main/jni/termux.c`，
后者又派生自 [jackpal/Android-Terminal-Emulator](https://github.com/jackpal/Android-Terminal-Emulator)。

- Copyright (C) 2011-2023 Termux contributors
- Copyright (C) 2011 Jack Palevich

**注意一个容易搞错的地方**：termux-app 仓库整体是 **GPLv3-only**，
但它的 `LICENSE.md` 明确把 `terminal-view` 和 `terminal-emulator` 两个库
列为例外，沿用上游 Android-Terminal-Emulator 的 **Apache-2.0**。
`termux.c` 属于后者，所以它是 Apache-2.0 而不是 GPLv3 ——
Burrow 自身的代码因此不受 GPL 传染。

Apache-2.0 要求保留版权声明与许可证提示，`pty.c` 文件头已包含。

### `TermuxInstaller` 的 staging + 原子 rename 手法

同属 termux-app（GPLv3 部分），但我们只借用了**做法**（先解压到暂存目录，
成功后 `rename` 顶替），没有复制代码。做法不受版权保护。

---

## 运行时下载的内容

发行版 rootfs 由用户在首次启动时选择并下载，**不随 APK 分发**：

| 发行版 | 来源 | 许可证 |
|---|---|---|
| Alpine Linux | <https://dl-cdn.alpinelinux.org/> | 各软件包各自的许可证（多为 MIT / BSD / GPL） |
| Ubuntu Base | <https://cdimage.ubuntu.com/ubuntu-base/> | 同上 |
| Debian | <https://github.com/debuerreotype/docker-debian-artifacts> | 同上 |

用户可以在安装页选下载源（大陆镜像 / 国际镜像）。**换源不影响安全性**：
sha256 校验的是文件内容，镜像提供的是同一份字节，改一个字节就过不了校验。
换源同时会把 rootfs 里的 `sources.list` / `apk/repositories` 一起写成
对应镜像，否则装完基座之后 `apt update` 又回到慢的那条线路上。

下载地址与 sha256 硬编码在 `lib/src/bootstrap/distro.dart` 里，
每次下载都强制校验（见 ARCHITECTURE.md §2.3）。

---

## 设计参考（未复制代码）

下列项目提供了设计思路，实现是重写的：

- [openai/codex](https://github.com/openai/codex) —— `SandboxPolicy` 三档模型、
  `execpolicy` 的 `Decision{Allow, Prompt, Forbidden}` 前缀规则、seccomp 断网思路
- VPetLLM —— `ContextLimitGuard`（从 400 错误反推真实 n_ctx 并校准估算器）、
  滚动摘要 + 滑动窗口、BM25 + 覆盖率 + 向量的 RRF 融合排序
- [chatbox](https://github.com/Bin-Huang/chatbox) —— provider 抽象、
  小模型工具调用 JSON 的修复思路
