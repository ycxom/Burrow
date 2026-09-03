# 沙箱与回滚

> 本文只讲「为什么这么选」。怎么用看 `lib/src/sandbox/` 里的代码注释。

---

## 1. Android 砍掉了哪些常规选项

codex 在桌面 Linux 上的方案是 bubblewrap + Landlock + seccomp。搬到 Android 上，
前两项大部分失效：

| 机制 | Android 上的情况 | 结论 |
|---|---|---|
| user namespace (`CONFIG_USER_NS`) | 多数厂商内核编译时关闭或用 `sysctl` 禁掉非特权使用 | **bwrap 起不来** |
| mount namespace / chroot | 需要 `CAP_SYS_ADMIN`，无 root 拿不到 | **真 chroot 不可用** |
| overlayfs / fuse-overlayfs | `/dev/fuse` 打不开；overlayfs 挂载同样要 CAP_SYS_ADMIN | **COW 文件系统不可用** |
| Landlock | 内核 5.13+ 且 `CONFIG_SECURITY_LANDLOCK=y`。GKI 5.15/6.1 上部分厂商开了 | **机会性可用，必须运行时探测** |
| seccomp-bpf | Android O (API 26) 起 CTS 强制要求 | **可靠可用** |
| `setrlimit` | 一直可用 | **可靠可用** |
| ptrace（proot 靠它） | 同 UID 内可用 | **可靠可用** |

「COW 文件系统不可用」这一条直接决定了回滚必须在应用层做 —— 这是 §3 的全部前提。

关于 Android 的 `isolatedProcess`：它确实是个真沙箱，但它**没有文件系统访问权限**，
也不能 exec 我们 rootfs 里的二进制。它适合跑不可信的解析器，不适合跑一个 shell。

---

## 2. 五层，逐层降级

```sh
burrow-launch --seccomp-no-net \
              --landlock-rw=<发行版 rootfs> --landlock-ro=/system \
              --landlock-rw=<workspace> --rlimit-nproc=64 -- \
  proot -0 -l -L -r <发行版 rootfs> \
        -b /dev -b /proc -b /sys \
        -b <workspace>:/workspace \
        -w /workspace \
    /bin/sh -lc "<command>"
```

用 `/bin/sh` 而不是 `/usr/bin/bash`：任何发行版都保证有前者，
而 Alpine 默认不带 bash。写死一个不一定存在的解释器，会让整个沙箱
在用户选了 Alpine 之后静默失效。

`-0 -l -L` 三个都是**装包的必需品**，各自对应一种「apt 跑到最后一步才倒」：

| 缺哪个 | 报错 | 真正原因 |
| --- | --- | --- |
| `-0` | `dpkg: error: requested operation requires superuser privilege` | guest 里不是 root。uid 0 只在 proot 眼里成立，内核看到的仍是 app 自己那个 uid，实体机上什么都没多拿 |
| `-l` | `dpkg: error: error creating new backup file '/var/lib/dpkg/status-old': Permission denied` | dpkg 用 `link()` 备份 status，而 Android 的 SELinux 不许在 app 数据区建硬链接。同目录 `touch` 是通的，所以这个报错**看着像磁盘只读，其实不是** |
| `-L` | tar / dpkg 校验尺寸时翻车 | `-l` 把硬链接全换成了符号链接，`lstat` 的 `st_size` 得跟着变成链接本身的长度 |

rootfs 给的是 `--landlock-rw` 而不是 `--landlock-ro`：装包本来就是往
`/var/lib/dpkg`、`/usr/bin` 里写，钉死只读等于 Agent 永远装不上环境。
这不放宽对实体机的约束 —— landlock 是白名单，没列出来的路径一律拒绝，
而这一条指向的是 app 私有目录下的一棵树。只有 `readOnly` 级别才给 `ro`。

### L0 命令策略（`exec_policy.dart`）

抄 codex `execpolicy` 的 `Decision{Allow, Prompt, Forbidden}` + 前缀规则。
两处改动：

1. **加了 `WriteScope`** —— 决定要不要在执行前打检查点，以及走哪条快照路
   （workspace 反向增量 vs 发行版 rootfs 代切换）。codex 靠平台沙箱兜底，我们靠回滚兜底。
2. **加了 shell 结构拆分** —— LLM 极爱写 `a && b | c > d`。只看第一个词会把
   `ls && rm -rf /` 判成 `ls`。按 `;`/`&&`/`||`/`|`/`&` 拆段，每段独立判定，取最严。

**规则表刻意保持短。** 长规则表给人「已经防住了」的错觉，而字符串解析器
永远赢不了 `eval "$(printf '\x72\x6d')"`。L0 挡的是「一眼就该拦」和
「该问一句」这两类，真正的防线在 L1/L2。

未命中任何规则时默认 `prompt` 而不是 `allow`：规则表不可能穷尽，
未知命令让用户看一眼比默默放行安全。同时把 scope 保守设成 `workspace`，
于是未知命令**一定会打检查点** —— 不确定的时候多存一次档，代价极低。

### L1 proot

用户态 chroot，ptrace 实现。**由我们自己用 NDK 编译、随 APK 出厂**，
不从发行版里取 —— 那是先有鸡还是先有蛋：要先能 chroot 进 rootfs
才拿得到里面的 proot。打包方式和 `burrow-launch` 相同（伪装成 `libproot.so`，
配合 `useLegacyPackaging = true`，见 ARCHITECTURE.md §3.1）。

给出：
- agent 看不见用户真实 HOME、`/sdcard`、其它 app 的数据
- 发行版 rootfs 挂成 `/`，里面的二进制按标准 FHS 路径正常解析
- 只有 `/workspace` 可写

`-r <rootfs>` 这个重定向正是换掉自建 Termux bootstrap 的理由：
Ubuntu / Alpine 的二进制硬编码的就是 `/usr`、`/lib`，proot 直接把它们指过来，
不需要重编任何东西。

**proot 是隔离手段，不是安全边界。** ptrace 转换 syscall 有已知的逃逸面
（尤其是 `clone`/`vfork` 边界）。真正的安全边界是 Android 自己的 app sandbox：
agent 再怎么逃也只在本 app 的 UID 里，碰不到别的应用。L3 是对**同 UID 内**
敏感数据（API key、聊天数据库、用户真实 HOME）的补充。

代价：ptrace 让每个 syscall 多两次上下文切换，重 I/O 负载下慢 20~40%。
可以在设置里给「我信任这个任务」提供关闭选项，但默认必须开。

### L2 seccomp 断网（`burrow_launch.c`）

只拦 `socket(AF_INET)` 和 `socket(AF_INET6)`，返回 `EPERM`。

**为什么不拦整个 `socket`**：`AF_UNIX` 必须放行，否则 dbus、X11 转发、
Android 自己的一堆东西全废，表现为程序莫名起不来 —— 比「网络不通」难查得多。

**为什么返回 EPERM 而不是 KILL**：让程序自己报「网络不可用」并优雅退出。
`SandboxSession._scanDenials` 会把这类 errno 识别出来，在给模型的输出里
加一行「这是沙箱拦的，不是网络故障，重试不会成功」—— 不加这句的话，
LLM 会把它误诊成网络抖动然后重试到天荒地老。

**装不上就拒绝执行，不降级放行。** 用户以为自己在离线沙箱里而实际上不是，
比明着失败危险得多。

### L3 Landlock（机会性）

运行时探测 `landlock_create_ruleset(NULL, 0, LANDLOCK_CREATE_RULESET_VERSION)`，
返回 ABI 版本；`EOPNOTSUPP` 就跳过。探测结果会一路传到 UI 上显示 ——
**用户有权知道自己现在实际被保护到什么程度**，而不是看到一个笼统的「已启用沙箱」。

规则很简单：发行版 rootfs 和 workspace 读写，`/system` 只读，`/dev` 读写，`/proc` 只读。
`/dev` 和 `/proc` 必须放行，否则 pty、`/dev/null`、`/proc/self/exe` 全不可用。
rootfs 只有在 `readOnly` 级别才降成只读 —— 其余级别下它就是包管理器的家，见 §2。

**这里的白名单是全部**：没列出来的路径，landlock 一律拒绝。所以「rootfs 可写」
放宽的只是 app 自己私有目录下的一棵树，实体机上的任何东西都还是碰不到。

### L4 资源上限

```
nproc 64    够跑 make -j4 和一条 pip 安装链，挡得住 fork 炸弹
fsize 2G    单文件上限，挡住 `yes > f` 写满存储
as    4G    虚拟地址空间。比物理内存宽松 —— JVM/python 会大量 reserve
            而不 commit，卡太紧会误杀正常程序
cpu   600   墙钟超时之外的第二道保险，防死循环耗电
```

外加墙钟超时 + `killpg` 杀整个进程组。**必须杀进程组**：只 kill 主进程的话，
`make -j8` 拉起的 gcc 会变成孤儿继续跑，在手机上表现为「命令早就超时了但机器还在发烫」。

---

## 3. 回滚：为什么是三套机制而不是一套

### 3.1 通用整机快照做不到

一个 Ubuntu base rootfs 有一万两千多个文件，装几个包就上五万。每条命令前全盘 stat 一遍要几秒，手机上直接劝退。
所以必须按「谁会变、多久变一次、变化量多大」拆开。

### 3.2 hardlink 快照的致命缺陷

`cp -al` / `rsync --link-dest` 是 Linux 上做快照的标准手法，在这里是错的：

```sh
cp -al work snap        # snap/f 和 work/f 是同一个 inode
echo x >> work/f        # 直接改 inode → snap/f 的内容跟着变了
```

**in-place 追加会穿透 hardlink，快照静默失真且没有任何报错。**
（`sed -i` 走 rename 所以安全，但你没法要求 LLM 只用 rename 语义的工具。）
Time Machine 靠 APFS clonefile 绕开，Linux 上没有 per-file COW 可用。

### 3.3 三套机制

| 状态 | 机制 | 为什么是它 |
|---|---|---|
| **workspace** | content-addressed 反向增量 | 唯一能躲开 hardlink 穿透的做法。工作副本永远最新，每代只存「回滚需要的旧内容」 |
| **发行版 rootfs** | 代目录 + 原子 rename | dpkg **从不 in-place 改文件**（总是写新文件再 rename），所以对包管理器 hardlink 是安全的 |
| **工具层写入** | 写前直接记 journal | 我们已经知道要改哪个文件，零扫描，100% 精确 |

**两个地方用两套机制不是不统一，是前提不同。** dpkg 的 rename 语义是它自己
为了保证安装原子性的既有设计，我们只是搭了个顺风车；普通 shell 命令没有这条保证。

前提失效的情况也要认：某些包的 postinst 会直接 `sed -i` 改 `etc/` 下的配置。
所以 `commit()` 之后对 `etc/` 做一次 `nlink` 校验（`PrefixGenerations.verifyEtc`），
发现还共享着 inode 的文件就断链成实体副本。只有几百个小文件，代价可忽略。

### 3.4 扫描式快照的已知损失

`checkpoint()` 扫描到一个文件变了时，存的是**当前**内容，不是变更前的内容 ——
因为上一代没保存它。所以扫描式路径只能回滚到「上次 checkpoint 之后第一次改动前」，
同一个 turn 内的中间态会丢。

这不是 bug，是这条路径的固有代价。要精确就走工具层。
**这也正是要把 LLM 往 `apply_patch` 上引导的理由**，而不只是为了省 token。

### 3.5 回滚必须诚实

`RollbackReport.unrecoverable` 列出旧内容没存下来的文件（超过 `maxBlobBytes`，
或扫描式路径记的删除）。这个列表**必须原样展示给用户和模型**。

一次「部分成功」的回滚如果被报告成成功，用户和模型都会基于错误的前提继续操作 ——
那比回滚失败本身糟糕得多。

---

## 4. 把 rollback 交给 LLM 自己用

`checkpoint` / `rollback` / `list_checkpoints` 是暴露给模型的工具，不只是 UI 按钮。

理由：比起让它小心翼翼地试探，不如让它知道「搞砸了能撤」，反而敢做更彻底的尝试。
一个不敢动手的 agent 在终端场景里几乎没用。

这也是 §3 必须做到毫秒级的原因 —— 慢了它就不敢用了，工具形同虚设。
