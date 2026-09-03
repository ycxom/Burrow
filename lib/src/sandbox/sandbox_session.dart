/// L1–L4 沙箱：把一条命令包成受限进程。
///
/// Android 上没 root，所以 codex 那套（bubblewrap / Landlock 全量 / seatbelt）
/// 大部分用不了：
///   - `CONFIG_USER_NS` 在多数厂商内核里被关 → bwrap 起不来
///   - `/dev/fuse` 拿不到 → fuse-overlayfs 用不了
///   - 挂载点操作需要 CAP_SYS_ADMIN → 真 chroot 用不了
///
/// 还剩什么：
///   - **proot**（ptrace 实现的用户态 chroot，Termux 自带）→ 路径隔离
///   - **seccomp-bpf**（Android O 起强制支持）→ 断网
///   - **Landlock**（GKI 5.15+ 部分开启）→ 机会性的文件系统强制
///   - **rlimit / 进程组超时**  → 资源上限
///
/// 分层是**逐层降级**的：探测不到就跳过，绝不因为某层不可用就整体放弃隔离。
/// [SandboxCapabilities.probe] 负责一次性探测并缓存结果，UI 上应该把
/// 实际生效的层显示出来 —— 用户有权知道自己现在被保护到什么程度。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 沙箱的强度档位。语义对齐 codex 的 `SandboxPolicy`。
enum SandboxLevel {
  /// 只读：workspace 也不可写。适合"先看看代码"的探索阶段。
  readOnly,

  /// 只有 workspace 可写，`$PREFIX` 只读，无网。默认档。
  workspaceWrite,

  /// workspace 可写 + 放通网络。装包、拉仓库时临时切进来。
  workspaceWriteNetwork,

  /// 关沙箱。UI 必须显示醒目警告。
  dangerFullAccess,
}

/// 运行时探测出来的可用能力。**不要在编译期假设**任何一项可用 ——
/// 同一个 APK 会跑在从 Android 8 到 16、内核 4.14 到 6.6 的机器上。
class SandboxCapabilities {
  final bool proot;
  final bool seccomp;
  final int landlockAbi; // 0 = 不支持
  final bool rlimit;

  const SandboxCapabilities({
    required this.proot,
    required this.seccomp,
    required this.landlockAbi,
    required this.rlimit,
  });

  bool get hasLandlock => landlockAbi > 0;

  /// 一句话说明当前实际生效的隔离层，给 UI 直接显示。
  String describe() {
    final active = <String>[
      if (proot) '路径隔离(proot)',
      if (seccomp) '断网(seccomp)',
      if (hasLandlock) '文件系统强制(landlock v$landlockAbi)',
      if (rlimit) '资源限制',
    ];
    if (active.isEmpty) return '仅命令策略检查（无进程级隔离）';
    return active.join(' + ');
  }

  static SandboxCapabilities? _cached;

  /// 探测一次并缓存。
  ///
  /// proot 不再来自发行版内部（那是先有鸡还是先有蛋：要先能 chroot 进去
  /// 才能拿到它），而是和 burrow-launch 一样由我们自己编译、随 APK 出厂。
  /// 所以这里只是确认那个二进制真的能跑起来。
  static Future<SandboxCapabilities> probe({
    required String? prootPath,
    required Future<Map<String, Object?>> Function() nativeProbe,
  }) async {
    if (_cached != null) return _cached!;

    var hasProot = false;
    if (prootPath != null) {
      try {
        final r = await Process.run(prootPath, ['--version'])
            .timeout(const Duration(seconds: 3));
        hasProot = r.exitCode == 0;
      } catch (_) {
        hasProot = false;
      }
    }

    final native = await nativeProbe();
    return _cached = SandboxCapabilities(
      proot: hasProot,
      seccomp: native['seccomp'] as bool? ?? false,
      landlockAbi: native['landlock_abi'] as int? ?? 0,
      rlimit: native['rlimit'] as bool? ?? true,
    );
  }
}

/// 一条命令的执行结果。
class ExecResult {
  final int exitCode;

  /// 完整输出的引用（已落盘进 objects）。上下文里只放蒸馏版，
  /// 需要细节时用 `grep_output(ref)` 回查。见 OutputDistiller。
  final String outputRef;

  final int outputBytes;
  final Duration elapsed;

  /// 被超时杀掉时为 true。这和 `exitCode != 0` 语义不同，
  /// LLM 需要区分「命令失败了」和「命令还没跑完就被掐了」。
  final bool timedOut;

  /// 被沙箱拦下的操作（seccomp 返回 EPERM 的 socket 调用等）。
  /// 有值时要原样告诉 LLM —— 否则它会把「网络被禁」误诊成「网络故障」，
  /// 然后陷入无意义的重试循环。
  final List<String> sandboxDenials;

  const ExecResult({
    required this.exitCode,
    required this.outputRef,
    required this.outputBytes,
    required this.elapsed,
    this.timedOut = false,
    this.sandboxDenials = const [],
  });
}

class SandboxSession {
  PtyHandle? _activeHandle;

  /// 发行版 rootfs 的路径（`distros/<id>/rootfs`）。proot 的 `-r` 指向它。
  ///
  /// **可变**。用户可以在聊天里当场勾选终端模式并装一个基座，装完必须
  /// 立刻生效 —— 要求重启 app 会把「勾一下就能用」直接变成「勾一下、
  /// 等下载、再手动杀进程重开」，那条路没人会走完。
  /// 改这个字段的唯一入口是 [attachDistro]。
  String rootfsPath;

  final String workspacePath;
  final SandboxCapabilities caps;

  /// 发行版 rootfs 是否已装好。
  ///
  /// 为 false 时只能退回 Android 自带的 `/system/bin/sh`。
  /// 这不是「优雅降级」的漂亮话 —— 那个 shell 里没有 git、没有 python、
  /// 没有包管理器，能做的事非常有限。它唯一的价值是让 pty 链路
  /// （JNI → Kotlin → EventChannel → xterm）能脱离发行版单独验证。
  /// UI 必须明确告诉用户环境没装。
  bool distroReady;

  /// 发行版的显示名与包管理器名字。只用于拼给模型看的系统提示 ——
  /// 告诉它这里是 apt 还是 apk，能省掉一整轮「试了 apt 发现没有」。
  String distroLabel;
  String packageManager;

  /// proot 二进制路径。和 burrow-launch 一样从 APK 的 nativeLibraryDir 取，
  /// null 表示不可用 —— 那样就没有 L1 路径隔离，只剩策略层。
  final String? prootPath;

  /// proot 的外置 loader（**宿主路径**）。null 表示让 proot 自己解内嵌的那份。
  ///
  /// 必须外置。proot 默认把内嵌 loader 解到临时目录再 execve 它，而那个临时
  /// 目录在 app 数据区 —— Android 10+ 对「执行自己写出来的文件」有 W^X 限制，
  /// 实测报 `execve("/bin/sh"): Permission denied`。错误信息指向 /bin/sh，
  /// 极具误导性：真正被拒的是 loader，不是目标程序。
  ///
  /// `enter.c` 在调 `extract_loader()` 之前先查 `PROOT_LOADER`，所以把 loader
  /// 作为 `lib*.so` 打进 APK、从 nativeLibraryDir 执行就绕开了 ——
  /// 那是 Android 明确允许执行的位置。
  final String? prootLoaderPath;
  final String? prootLoader32Path;

  /// 给 proot 自己用的临时目录（**宿主路径**，不是 rootfs 内的路径）。
  ///
  /// proot 启动时要把 loader 落成一个临时文件再映射进去。它默认找 `/tmp`，
  /// 而 app UID 下那个目录不存在也不可写，于是报
  /// `can't create temporary file: Permission denied`，接着
  /// `execve("/bin/sh"): No such file or directory` —— 后面这条极具误导性，
  /// 看起来像 rootfs 坏了，其实是 proot 自己没地方放 loader。
  final String tmpPath;

  /// burrow-launch 的实际路径，null 表示不可用（此时 L2/L3/L4 全部失效）。
  ///
  /// **不要硬编码成 `$PREFIX/libexec/burrow-launch`。** 它有两个合法位置：
  /// bootstrap 装好后在 `$PREFIX/libexec/`，装好之前就在 APK 解出来的
  /// `nativeLibraryDir/libburrow-launch.so`。后者在降级模式下照样可执行，
  /// 所以降级模式不该白白丢掉 seccomp 断网和 rlimit —— 那两层和
  /// bootstrap 没有任何关系。
  final String? launcherPath;

  /// 通过 MethodChannel 调到原生的 pty spawn。
  /// 签名: (argv, env, cwd, sandboxFlags) -> Stream<List<int>> + exitCode
  final NativePtySpawner spawner;

  SandboxSession({
    required this.rootfsPath,
    required this.workspacePath,
    required this.caps,
    required this.spawner,
    this.distroReady = true,
    this.distroLabel = '',
    this.packageManager = '',
    this.launcherPath,
    this.prootPath,
    this.prootLoaderPath,
    this.prootLoader32Path,
    required this.tmpPath,
  });

  bool get canIsolate => distroReady && prootPath != null;

  /// 挂上一个刚装好的发行版。
  ///
  /// [buildArgv] / [buildEnv] 每次调用都重新读这些字段，所以挂上之后
  /// **下一条命令**就落在新 rootfs 里。已经跑起来的交互 shell 不会自己
  /// 搬家（它的 argv 在 spawn 那一刻就定死了），调用方需要重启它。
  void attachDistro({
    required String rootfsPath,
    required String label,
    required String packageManager,
  }) {
    this.rootfsPath = rootfsPath;
    distroLabel = label;
    this.packageManager = packageManager;
    distroReady = true;
  }

  /// 降级时用的 shell。Android 上 `/system/bin/sh` 是 mksh，
  /// 它**不认 `-l`**（没有 login shell 概念），所以参数也要跟着换。
  static const _fallbackShell = '/system/bin/sh';

  /// 组装 argv。这是整个沙箱的收口处：所有隔离都体现在这一层的包装上。
  ///
  /// 最终形态（能力全开时）：
  /// ```
  /// burrow-launch --seccomp-no-net
  ///               --landlock-rw=<rootfs> --landlock-ro=/system
  ///               --landlock-rw=<workspace> --rlimit-nproc=64 ...
  ///   -- proot -0 -l -L -r <rootfs>
  ///            -b /dev -b /proc -b /sys
  ///            -b <workspace>:/workspace
  ///            -w /workspace
  ///      /bin/sh -lc "<command>"
  /// ```
  ///
  /// `-0 -l -L` 三个都是「让发行版的包管理器能正常工作」的必需品，
  /// 缺一个就是一种装不上包的姿势，具体见下面各自的注释。
  ///
  /// `burrow-launch` 是我们自己的原生小程序：装 seccomp filter、设 rlimit、
  /// （可选）装 landlock ruleset，然后 execve。它必须在 proot **外面** ——
  /// seccomp filter 会被子进程继承，装在外层才能覆盖 proot 拉起的整棵树。
  List<String> buildArgv(String command, SandboxLevel level) {
    final argv = <String>[];

    final launcher = launcherPath;
    if (level != SandboxLevel.dangerFullAccess && launcher != null) {
      argv.add(launcher);

      final noNetwork = level == SandboxLevel.readOnly ||
          level == SandboxLevel.workspaceWrite;
      if (caps.seccomp && noNetwork) argv.add('--seccomp-no-net');

      if (caps.hasLandlock) {
        // landlock 是 proot 的兜底：proot 靠 ptrace 转换路径，理论上有
        // 逃逸面；landlock 是内核强制的。规则是白名单 —— 没列出来的
        // 路径一律拒绝，所以实体机上除了这几条之外什么都碰不到。
        //
        // rootfs 跟着可写级别走，**不能钉死成只读**：装包就是往 rootfs
        // 里写（/var/lib/dpkg、/usr/bin……），钉死只读等于 Agent 永远
        // 装不上环境。这条曾经写死成 ro，而手头的测试机 landlock_abi=0，
        // 于是整条规则根本没生效、问题一直没暴露 —— 换一台内核 5.13+
        // 的设备，apt 会在第一个写操作上就倒，且报错和 -l 那个一模一样
        // （Permission denied），极难分辨到底是哪一层拦的。
        //
        // rootfs 可写不等于实体机可写：那是 app 私有目录下的一棵树，
        // 本来就该由沙箱里的包管理器随便改。
        argv.add(level == SandboxLevel.readOnly
            ? '--landlock-ro=$rootfsPath'
            : '--landlock-rw=$rootfsPath');
        argv.add('--landlock-ro=/system');
        if (level != SandboxLevel.readOnly) {
          argv.add('--landlock-rw=$workspacePath');
        }
      }

      if (caps.rlimit) {
        // 这几个数字的取法：
        //   nproc 64  —— 够跑 make -j4 和一条 pip 安装链，挡得住 fork 炸弹
        //   fsize 2G  —— 单文件上限，挡住 `yes > f` 写满存储
        //   cpu   600 —— 墙钟超时之外的第二道保险，防死循环耗电
        //
        // **刻意不设 RLIMIT_AS。** 它限的是虚拟地址空间，不是实际内存占用，
        // 在 64 位上基本没有约束意义 —— 现代分配器和动态链接器会大量 reserve
        // 而不 commit。实测（x86_64 模拟器）：4GB 和 8GB 都让 proot 直接
        // SIGABRT，16GB 以上才起得来。也就是说想拦住真实内存滥用就得设到
        // 一个大到毫无意义的值，而设小一点就是纯粹的误杀。
        // 真要限内存得靠 cgroup，那是 app 拿不到的东西 ——
        // 目前只能靠 Android 自己的 LMK 兜底。
        argv.addAll([
          '--rlimit-nproc=64',
          '--rlimit-fsize=2147483648',
          '--rlimit-cpu=600',
        ]);
      }
      argv.add('--');
    }

    if (canIsolate && level != SandboxLevel.dangerFullAccess) {
      argv.addAll([
        prootPath!,
        // 让 rootfs 里认为自己是 root。**装包全靠它**：dpkg 会直接拒绝
        // 非 root 运行（`requested operation requires superuser privilege`），
        // apt 下载完一整轮 40MB 之后倒在最后一步。
        //
        // 这不是把权限放给了实体机 —— proot 是用户态的路径重定向，uid 0
        // 只在 guest 眼里成立，对 Android 内核来说仍然是 app 自己那个 uid，
        // 能碰到的东西一个都没变多。proot-distro / Termux 也是默认开这个。
        '-0',
        // 用符号链接顶替硬链接。**装包同样全靠它**：dpkg 更新 status 前
        // 会先 `link(status, status-old)` 做备份，而 Android 的 SELinux
        // 策略不允许在 app 数据区建硬链接 —— 实测 `ln a b` 直接
        // `Permission denied`，但同目录 `touch` 是通的，所以这既不是
        // 目录权限问题也不是 landlock（那两条都放行了）。
        //
        // 不加这个的表现极具误导性：apt 下载解包全都正常，最后倒在
        // `error creating new backup file '/var/lib/dpkg/status-old':
        // Permission denied`，看着像磁盘只读。
        '-l',
        // 让 lstat 对符号链接返回正确的 st_size。上面这一开，rootfs 里
        // 原本的硬链接全都变成了符号链接，读到错的大小会让 tar / dpkg
        // 这类会核对尺寸的工具翻车。proot-distro 也是这两个成对给的。
        '-L',
        '-r', rootfsPath,
        // rootfs 里的二进制硬编码的是 /usr /lib /etc 这些标准 FHS 路径，
        // proot 的 -r 正好把它们重定向过来 —— 这就是换掉自建 Termux
        // bootstrap 的全部理由：不需要重编任何东西。
        '-b', '/dev',
        '-b', '/proc',
        '-b', '/sys',
        '-b', '/dev/urandom:/dev/random', // Android 的 /dev/random 可能阻塞
        // 让 rootfs 里看到一个像样的 /etc/resolv.conf 由 DistroManager
        // 在解压后写好，这里不再 bind 宿主的（宿主那份 app 读不到）。
      ]);
      if (level != SandboxLevel.readOnly) {
        argv.addAll(['-b', '$workspacePath:/workspace']);
      }
      // /bin/sh 在任何发行版里都存在；bash 不一定（Alpine 默认没有）。
      argv.addAll(['-w', '/workspace', '/bin/sh', '-lc', command]);
    } else if (distroReady) {
      // 有 rootfs 但没有 proot：只能直接跑宿主的 shell，没有路径隔离。
      argv.addAll([_fallbackShell, '-c', command]);
    } else {
      argv.addAll([_fallbackShell, '-c', command]);
    }

    return argv;
  }

  Map<String, String> buildEnv(SandboxLevel level) {
    // 白名单而不是黑名单。继承宿主环境会把 API key、Android 的一堆
    // `ANDROID_*` 路径，以及用户 shell 里的 alias 全带进去，破坏可复现性 ——
    // 同一条命令在两台机器上行为不同是最难查的一类 bug。
    if (!canIsolate || level == SandboxLevel.dangerFullAccess) {
      // Android 自带环境。PATH 给全一点，否则连 ls 都找不到
      // （toybox 的软链在 /system/bin，部分机型还有 /vendor/bin）。
      return {
        'HOME': workspacePath,
        'PATH': '/system/bin:/system/xbin:/vendor/bin',
        'TMPDIR': workspacePath,
        'TERM': 'xterm-256color',
        'BURROW_SANDBOX': '${level.name}(no-distro)',
        'PROOT_TMP_DIR': tmpPath,
        if (prootLoaderPath != null) 'PROOT_LOADER': prootLoaderPath!,
        if (prootLoader32Path != null) 'PROOT_LOADER_32': prootLoader32Path!,
      };
    }

    // rootfs 视角下的标准 FHS 环境。
    return {
      'HOME': '/workspace',
      'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
      'TMPDIR': '/tmp',
      'TERM': 'xterm-256color',
      'LANG': 'C.UTF-8',
      // 让沙箱内的程序（和 LLM 自己）能知道当前处境。
      // 有些工具会据此关掉交互式提问，避免卡在等输入上。
      'BURROW_SANDBOX': level.name,
      'BURROW_IN_SANDBOX': '1',
      // 以下三个都是**宿主路径**，给 proot 自己用。和上面的 TMPDIR
      // （=/tmp，rootfs 内的路径）是两回事，别合并。
      'PROOT_TMP_DIR': tmpPath,
      if (prootLoaderPath != null) 'PROOT_LOADER': prootLoaderPath!,
      if (prootLoader32Path != null) 'PROOT_LOADER_32': prootLoader32Path!,
      'CI': '1',
      'DEBIAN_FRONTEND': 'noninteractive',
    };
  }

  /// 执行一条命令。输出全文落盘，返回引用。
  ///
  /// [onChunk] 用于实时把字节喂给 UI 的终端视图 —— Agent 跑命令时用户
  /// 应该能看见进度，而不是盯着一个转圈等三分钟。
  Future<ExecResult> run(
    String command, {
    required SandboxLevel level,
    required File outputSink,
    Duration timeout = const Duration(minutes: 5),
    void Function(List<int> chunk)? onChunk,
  }) async {
    final started = DateTime.now();
    final sink = outputSink.openWrite();
    var bytes = 0;
    final denials = <String>[];

    final handle = await spawner.spawn(
      argv: buildArgv(command, level),
      env: buildEnv(level),
      cwd: workspacePath,
    );
    _activeHandle = handle;

    var timedOut = false;
    final timer = Timer(timeout, () {
      timedOut = true;
      // 杀进程组而不是单个 pid —— `make -j` 的子进程不会因为父进程死了就退出，
      // 留下来的编译进程会一直烧电。原生侧对 -pgid 发 SIGKILL。
      handle.killGroup();
    });

    await for (final chunk in handle.output) {
      bytes += chunk.length;
      sink.add(chunk);
      onChunk?.call(chunk);
      _scanDenials(chunk, denials);
    }

    final exitCode = await handle.exitCode;
    if (identical(_activeHandle, handle)) _activeHandle = null;
    timer.cancel();
    await sink.close();

    return ExecResult(
      exitCode: exitCode,
      outputRef: outputSink.path,
      outputBytes: bytes,
      elapsed: DateTime.now().difference(started),
      timedOut: timedOut,
      sandboxDenials: denials,
    );
  }

  void cancelActive() {
    _activeHandle?.killGroup();
    _activeHandle = null;
  }

  /// 从输出里认出「这是被沙箱拦的，不是程序自己坏了」。
  ///
  /// seccomp 把 `socket()` 变成 `EPERM`，而应用层看到的是
  /// "Operation not permitted" / "Network is unreachable"，
  /// 和真实的网络故障长得一模一样。不点破的话 LLM 会重试到天荒地老。
  static const _denialMarkers = <String, String>{
    'Operation not permitted': '可能是沙箱断网拦截',
    'Network is unreachable': '可能是沙箱断网拦截',
    'Temporary failure in name resolution': '可能是沙箱断网拦截（DNS）',
    'Read-only file system': '沙箱只读区写入被拒',
    'Permission denied': '路径不在可写区内',
  };

  void _scanDenials(List<int> chunk, List<String> out) {
    final text = utf8.decode(chunk, allowMalformed: true);
    for (final entry in _denialMarkers.entries) {
      if (text.contains(entry.key) && !out.contains(entry.value)) {
        out.add(entry.value);
      }
    }
  }
}

/// 原生 pty 的抽象。真实实现走 MethodChannel + EventChannel（见 PtyBridge.kt）；
/// 测试里换成假的，于是 buildArgv/buildEnv 这些纯逻辑可以脱离设备跑单测。
abstract class NativePtySpawner {
  Future<PtyHandle> spawn({
    required List<String> argv,
    required Map<String, String> env,
    required String cwd,
    int rows = 24,
    int cols = 80,
  });
}

abstract class PtyHandle {
  Stream<List<int>> get output;
  Future<int> get exitCode;
  void write(List<int> data);
  void resize(int rows, int cols);
  void killGroup();
}
