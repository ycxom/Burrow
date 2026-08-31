/// 应用入口与装配。
///
/// 这个文件只做一件事：把各个部件按依赖顺序接起来。
/// 所有判断逻辑都在部件内部 —— 装配代码里出现业务 if 就说明分层有问题。
/// （这里确实有一个 if：发行版装没装。那是环境事实，不是业务判断。）
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'src/agent/agent_loop.dart';
import 'src/bootstrap/distro.dart';
import 'src/context/context_limit_guard.dart';
import 'src/context/memory_retrieval.dart';
import 'src/context/output_distiller.dart';
import 'src/context/overflow_manager.dart';
import 'src/llm/llm_client.dart';
import 'src/sandbox/exec_policy.dart';
import 'src/sandbox/prefix_generations.dart';
import 'src/sandbox/pty_channel.dart';
import 'src/sandbox/sandbox_session.dart';
import 'src/sandbox/snapshot_store.dart';
import 'src/ui/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // app 私有目录。rename 要求同一文件系统，而发行版的
  // rootfs / rootfs.staging / rootfs.gen 三者必须能互相 rename，
  // 所以它们都得在这里 —— 外部存储不满足。
  final files = await getApplicationSupportDirectory();
  final distroRoot = Directory('${files.path}/distros');

  final native = await _NativeBits.probe();

  final distros = DistroManager(
    root: distroRoot,
    abi: native.abi,
    fetch: (url) async {
      final req = http.Request('GET', Uri.parse(url));
      final resp = await http.Client().send(req);
      if (resp.statusCode != 200) {
        throw DistroInstallException('下载失败：HTTP ${resp.statusCode}  $url');
      }
      return resp.stream;
    },
  );

  final installed = await distros.listInstalled();
  if (installed.isNotEmpty) {
    // 已装过就直接进主界面。多个发行版时先用第一个 ——
    // 切换入口在设置里，不该在启动路径上再问一次。
    await _boot(
      files: files,
      distros: distros,
      active: installed.first,
      native: native,
    );
    return;
  }

  // 没装过：让用户选一个。**不自动装** —— 这一步要联网下几十 MB，
  // 而且装哪个发行版影响之后所有命令的行为，必须是用户的显式选择。
  runApp(DistroSetupApp(
    manager: distros,
    abi: native.abi,
    onReady: (chosen) => _boot(
      files: files,
      distros: distros,
      active: chosen,
      native: native,
    ),
    onSkip: () => _boot(
      files: files,
      distros: distros,
      active: null,
      native: native,
    ),
  ));
}

/// APK 里随包出厂的原生件。
///
/// proot 和 burrow-launch 都由我们自己用 NDK 编译、伪装成 `lib*.so` 打进 APK
/// （见 CMakeLists.txt 的说明）。**不能从发行版里取 proot** —— 那是先有鸡
/// 还是先有蛋：要先能 chroot 进 rootfs 才拿得到里面的 proot。
class _NativeBits {
  final String abi;
  final String? launcher;
  final String? proot;
  final String? prootLoader;
  final String? prootLoader32;

  const _NativeBits({
    required this.abi,
    this.launcher,
    this.proot,
    this.prootLoader,
    this.prootLoader32,
  });

  static Future<_NativeBits> probe() async {
    final dir = await PtyChannel.nativeLibraryDir();
    final abi = await PtyChannel.abi() ?? 'arm64-v8a';
    if (dir == null) return _NativeBits(abi: abi);

    Future<String?> find(String name) async {
      final f = File('$dir/$name');
      return await f.exists() ? f.path : null;
    }

    return _NativeBits(
      abi: abi,
      launcher: await find('libburrow-launch.so'),
      proot: await find('libproot.so'),
      prootLoader: await find('libproot-loader.so'),
      prootLoader32: await find('libproot-loader32.so'),
    );
  }
}

Future<void> _boot({
  required Directory files,
  required DistroManager distros,
  required InstalledDistro? active,
  required _NativeBits native,
}) async {
  final sandboxRoot = Directory('${files.path}/sandbox');
  final workspace = Directory('${sandboxRoot.path}/workspace');
  final archive = Directory('${sandboxRoot.path}/outputs');
  // proot 要一个可写的宿主临时目录来落 loader，见 SandboxSession.tmpPath。
  final tmp = Directory('${sandboxRoot.path}/tmp');
  await workspace.create(recursive: true);
  await archive.create(recursive: true);
  await tmp.create(recursive: true);

  // 环境代管理挂在当前发行版的 rootfs 上。没装发行版时给一个占位目录，
  // 这样 UI 不必到处判空 —— 它的代列表就是空的。
  final gens = PrefixGenerations(
    filesRoot: active != null
        ? active.rootfs.parent
        : Directory('${files.path}/distros/_none'),
  );
  await gens.open();
  if (await gens.recover()) {
    debugPrint('burrow: 从中断的环境事务中恢复');
  }

  // 必须在 probe 之前设好 —— 探测本身就是跑一次 `burrow-launch --probe`，
  // 找不到它就只能返回兜底值，UI 上会显示成「seccomp 不可用」，
  // 而实际上它是可用的。
  if (native.launcher != null) {
    await PtyChannel.setLauncher(native.launcher!);
  }

  final caps = await SandboxCapabilities.probe(
    prootPath: native.proot,
    nativeProbe: PtyChannel.probeSandbox,
  );
  debugPrint('burrow: 沙箱能力 —— ${caps.describe()}');
  debugPrint('burrow: 发行版 —— ${active?.distro.displayName ?? '未安装（降级模式）'}');

  final spawner = PtyChannel();

  final snapshots = SnapshotStore(
    workspace: workspace,
    metaRoot: Directory('${sandboxRoot.path}/meta'),
  );
  await snapshots.open();

  final sandbox = SandboxSession(
    rootfsPath: active?.rootfs.path ?? '',
    workspacePath: workspace.path,
    caps: caps,
    spawner: spawner,
    distroReady: active != null,
    launcherPath: native.launcher,
    prootPath: native.proot,
    prootLoaderPath: native.prootLoader,
    prootLoader32Path: native.prootLoader32,
    tmpPath: tmp.path,
  );

  // LLM 客户端等设置页配置完成后才可用。没配也要能进主界面 ——
  // 手动开终端、看检查点这些都不依赖模型。
  final llm = ConfigurableLlmClient();

  final overflow = OverflowManager(
    summarize: llm.summarize,
    // 手机上默认按 token 触发而不是消息数：本地模型窗口小，
    // 20 条带命令输出的消息就能撑爆一个 4k 窗口，而 20 条闲聊撑不爆。
    trigger: OverflowTrigger.either,
    messageThreshold: 30,
    tokenThreshold: 4000,
  );

  runApp(BurrowApp(
    buildAgent: (host) => AgentLoop(
      llm: llm,
      host: host,
      // 包管理器的名字随发行版变（apk / apt），策略表要跟着走。
      policy: ExecPolicy(),
      sandbox: sandbox,
      snapshots: snapshots,
      prefixGens: gens,
      overflow: overflow,
      retrieval: MemoryRetrieval(),
      distiller: OutputDistiller(),
      limitGuard: ContextLimitGuard(),
      outputArchiveDir: archive,
    ),
    capabilities: caps,
    snapshots: snapshots,
    prefixGens: gens,
    spawner: spawner,
    sandbox: sandbox,
    activeDistro: active,
  ));
}
