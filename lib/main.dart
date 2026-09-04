/// 应用入口与装配。
///
/// 这个文件只做一件事：把各个部件按依赖顺序接起来。
/// 所有判断逻辑都在部件内部 —— 装配代码里出现业务 if 就说明分层有问题。
/// （这里确实有一个 if：发行版装没装。那是环境事实，不是业务判断。）
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';

import 'src/agent/agent_loop.dart';
import 'src/bootstrap/distro.dart';
import 'src/context/context_limit_guard.dart';
import 'src/context/memory_retrieval.dart';
import 'src/context/output_distiller.dart';
import 'src/context/overflow_manager.dart';
import 'src/data/chat_store.dart';
import 'src/data/db_cipher.dart';
import 'src/data/task_runtime.dart';
import 'src/llm/embeddings.dart';
import 'src/llm/llm_client.dart';
import 'src/llm/model_registry_store.dart';
import 'src/llm/vision.dart';
import 'src/net/proxy_client.dart';
import 'src/sandbox/exec_policy.dart';
import 'src/sandbox/prefix_generations.dart';
import 'src/sandbox/pty_channel.dart';
import 'src/sandbox/sandbox_session.dart';
import 'src/sandbox/snapshot_store.dart';
import 'src/settings/account_store.dart';
import 'src/settings/channel_store.dart';
import 'src/settings/model_roles.dart';
import 'src/settings/settings_store.dart';
import 'src/settings/thread_lock.dart';
import 'src/skills/skill_store.dart';
import 'src/ui/app.dart';
import 'src/ui/database_gate.dart';
import 'src/ui/liquid_glass.dart';
import 'src/ui/skin_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 输入框那块玻璃的折射着色器。不 await —— 编译要几十毫秒，挡在启动路径上
  // 只会让首帧更晚；编好之前输入框自己会先画成普通毛玻璃。
  unawaited(LiquidGlassProgram.warmUp());

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

/// prefs 里存密钥材料的两个键。
///
/// **盐和校验值都跟着备份走**，密钥本身不落盘 —— 那正是"换手机能读、
/// 拿到备份不能读"的分界线。
const _dbSaltKey = 'burrow.db.salt';
const _dbCheckKey = 'burrow.db.check';

/// 安全存储里缓存的那把钥匙。
///
/// 由系统（Android Keystore）保管，**不跟着备份走** —— 所以到了新手机上
/// 它自然是空的，于是会问一次密码。这不是缺陷，是这套方案成立的原因。
const _dbKeyCache = 'burrow.db.key';

/// 拿到数据库密钥。拿不到就弹一道门问用户。
Future<DbCipher> _unlockDatabase(
  SharedPreferences prefs,
  ChatStore chats,
) async {
  const secure = FlutterSecureStorage();
  var salt = prefs.getString(_dbSaltKey);
  var check = prefs.getString(_dbCheckKey);

  // 日常这条路：钥匙在安全存储里，一句都不用问。
  if (salt != null && check != null) {
    try {
      final cached = DbCipher.fromHex(await secure.read(key: _dbKeyCache));
      if (cached != null && DbKeyCheck.verify(cached, check)) return cached;
    } catch (_) {
      // 安全存储读不出来（换过设备、系统重置过密钥库）就当没有，走下面问密码。
    }
  }

  final creating = salt == null || check == null;
  if (creating) {
    salt = DbCipher.newSalt();
    await prefs.setString(_dbSaltKey, salt);
  }

  final completer = Completer<DbCipher>();
  runApp(DatabaseGateApp(
    mode: creating ? DatabaseGateMode.create : DatabaseGateMode.unlock,
    salt: salt,
    check: check,
    onUnlocked: (cipher) async {
      // 校验值只在第一次写。之后它是"密码对不对"的唯一判据，
      // 每次启动重写一遍等于把任何一个输错的密码都变成正确答案。
      if (creating) {
        await prefs.setString(_dbCheckKey, DbKeyCheck.make(cipher));
      }
      try {
        await secure.write(key: _dbKeyCache, value: cipher.keyHex);
      } catch (_) {
        // 缓存不上只是以后每次启动都要输一遍，不影响能不能用。
      }
      if (!completer.isCompleted) completer.complete(cipher);
    },
    onReset: () async {
      // 忘了密码 = 那些密文永远打不开了。清掉重来，并且**换一份新的盐** ——
      // 沿用旧盐的话，新密码派生出来的钥匙会去撞一堆解不开的旧数据。
      await chats.wipeConversations();
      final fresh = DbCipher.newSalt();
      await prefs.setString(_dbSaltKey, fresh);
      await prefs.remove(_dbCheckKey);
      try {
        await secure.delete(key: _dbKeyCache);
      } catch (_) {}
      // 重新走一遍这道门，这次是"设一个新密码"。
      final again = await _unlockDatabase(prefs, chats);
      if (!completer.isCompleted) completer.complete(again);
    },
  ));
  return completer.future;
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
  // 当前基座是**可变的**：用户可以在聊天里勾「终端模式」时当场装一个。
  // 装完之后新建的会话必须看到它，所以这里存的是一个 notifier 而不是值。
  final activeDistro = ValueNotifier<InstalledDistro?>(active);

  final sandboxRoot = Directory('${files.path}/sandbox');
  // proot 要一个可写的宿主临时目录来落 loader，见 SandboxSession.tmpPath。
  final tmp = Directory('${sandboxRoot.path}/tmp');
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

  Future<TaskRuntime> buildRuntime(String taskId) async {
    // 每次都重新读 —— 运行中装的基座要能被之后新建的会话用上。
    final current = activeDistro.value;
    final root = taskRootFor(sandboxRoot, taskId);
    final workspace = Directory('${root.path}/workspace');
    await workspace.create(recursive: true);
    await Directory('${root.path}/outputs').create(recursive: true);
    final snapshots = SnapshotStore(
      workspace: workspace,
      metaRoot: Directory('${root.path}/meta'),
    );
    await snapshots.open();
    return TaskRuntime(
      id: taskId,
      root: root,
      snapshots: snapshots,
      sandbox: SandboxSession(
        rootfsPath: current?.rootfs.path ?? '',
        workspacePath: workspace.path,
        caps: caps,
        spawner: spawner,
        distroReady: current != null,
        distroLabel: current?.distro.displayName ?? '',
        packageManager: current?.distro.packageManager ?? '',
        launcherPath: native.launcher,
        prootPath: native.proot,
        prootLoaderPath: native.prootLoader,
        prootLoader32Path: native.prootLoader32,
        tmpPath: tmp.path,
      ),
    );
  }

  // LLM 客户端等设置页配置完成后才可用。没配也要能进主界面 ——
  // 手动开终端、看检查点这些都不依赖模型。
  final settings = await SettingsStore.load();

  // 渠道是接入点的唯一来源；SettingsStore 只是把「当前那个」加上生成参数
  // 投影成下游要的 LlmConfig（见 SettingsStore.config）。
  final legacyPrefs = await SharedPreferences.getInstance();
  final channels = await ChannelStore.load(prefs: legacyPrefs);
  settings.bindChannels(channels);

  // 模型能力表：先用随包快照/本地缓存把界面撑起来，联网刷新放到后台。
  //
  // **不 await 刷新。** 这是启动路径，为了一份"提示性"的数据多等几秒网络
  // 不划算；而且拉不到也完全不影响使用，只是少几个能力图标。
  final modelRegistry = ModelRegistryStore(
    cacheFile: File('${files.path}/model_registry.json'),
  );
  await modelRegistry.load();
  channels.registry = modelRegistry.registry;
  modelRegistry.changes
      .listen((_) => channels.registry = modelRegistry.registry);
  unawaited(modelRegistry.refresh());
  final chats = await ChatStore.open();

  // 数据库密钥。拿不到就先弹一道门问密码，拿到了才往下走。
  final cipher = await _unlockDatabase(legacyPrefs, chats);
  chats.useCipher(cipher);
  // 还是明文的那些行就地搬成密文。**不 await 之前不能让用户开始用** ——
  // 边写边搬会让新写进去的行和正在搬的行撞在一起。它一行一行走，
  // 中途断了下次接着搬（见 ChatStore.encryptExisting）。
  final migrated = await chats.encryptExisting();
  if (migrated > 0) debugPrint('burrow: 加密了 $migrated 行历史数据');

  // 会话锁的"这次运行开过哪些"。只活在内存里 —— 落盘的话开过一次就一直
  // 开着，这道锁只在第一次有用。
  final unlocked = ThreadUnlockSession();
  final llm = ConfigurableLlmClient(config: settings.config);

  // **不在这里挂"设置一变就推配置"。**
  //
  // 那条监听会把全局设置推给所有会话，而模型策略现在是**按会话**的
  // （见 settings/thread_prefs.dart）：改一次全局温度就把每个聊天室的温度
  // 都改掉，正是要根治的事。改成由当前打开的那个会话自己往 client 上写
  // （app.dart 的 `_applyConfig`）—— 同一时刻只有一个会话活着，
  // "当前生效的配置"和"当前打开的会话"是一一对应的。

  final accounts = await AccountStore.load();

  /// 一个配角模型这次落到哪儿。**每次现算** —— 分工表和渠道都随时会变。
  ResolvedRole? role(ModelRole which) => channels.resolveRole(which);

  // 嵌入后端。地址、密钥、代理全跟着**嵌入模型自己那个渠道**走，
  // 而不是当前对话渠道 —— 那正是「聊天用 A、嵌入用 B」以前配不出来的原因。
  final embedder = OpenAiEmbedder(
    baseUrl: () => role(ModelRole.embedding)?.channel.baseUrl ?? '',
    apiKey: () async {
      final bound = role(ModelRole.embedding);
      if (bound == null) return '';
      return accounts.authFor(bound.channel,
          apiKey: channels.apiKeyOf(bound.channel));
    },
    model: () => role(ModelRole.embedding)?.model ?? '',
    proxy: () => role(ModelRole.embedding)?.channel.proxy ?? '',
  );

  // 老版本把 baseUrl/key/model 存在 prefs 的单份配置里。不迁的话，
  // 升级后用户看到的是一个空的渠道列表 —— 那看起来就是"我的配置丢了"。
  await channels.migrateFrom(
    config: LlmConfig(
      apiFormat: legacyPrefs.getString('burrow.llm.format') ?? 'openAI',
      baseUrl: legacyPrefs.getString('burrow.llm.baseUrl') ?? '',
      apiKey:
          await const FlutterSecureStorage().read(key: 'burrow.llm.apiKey') ??
              '',
      model: legacyPrefs.getString('burrow.llm.model') ?? '',
      summaryModel: legacyPrefs.getString('burrow.llm.summaryModel'),
    ),
    providerName: legacyPrefs.getString('burrow.llm.provider') ?? '',
  );

  // OAuth 渠道的 access_token 每次请求前现取 —— 存进配置就等于存了一份
  // 马上失效的副本。
  llm.bearerProvider = () async {
    final channel = channels.active;
    if (channel == null || !channel.usesOAuth) {
      return channel == null ? '' : channels.apiKeyOf(channel);
    }
    final account =
        accounts.account(channel.oauthProviderId!, channel.oauthAccountId!);
    if (account == null) return '';
    return accounts.validToken(account);
  };
  llm.chatGptAccountIdProvider = () async {
    final channel = channels.active;
    return channel == null ? null : accounts.credentialFor(channel)?.accountId;
  };

  // ChatGPT 的真实余量只出现在聊天响应头上，没有独立的查询接口。所以它是
  // 反向推进来的：客户端读到头就回调，我们记到**当时那个渠道绑的账号**上。
  //
  // 现取 channels.active 而不是闭包里存一份：一次请求发出去到响应回来之间，
  // 用户完全可能已经切了渠道，记到新渠道头上就是错的账。
  llm.onRateLimit = (quota) {
    final channel = channels.active;
    if (channel == null || !channel.usesOAuth) return;
    unawaited(accounts.noteQuota(
      channel.oauthProviderId!,
      channel.oauthAccountId!,
      quota,
    ));
  };

  /// 压缩历史。
  ///
  /// 摘要模型指到别的渠道时，**得用那个渠道自己的客户端**：主客户端的地址、
  /// 密钥、代理都是当前对话渠道的，拿它去发一个属于别家的模型名，结果不是
  /// 404 就是安静地摘出一段空的（[ConfigurableLlmClient.summarize] 出错时
  /// 返回空串，不抛）。
  ///
  /// 没指派、或者指派的就是当前渠道时走主客户端 —— 那条路上有连接复用，
  /// 而摘要在长对话里会反复发生。
  Future<String> summarize(String systemPrompt, String payload) async {
    final bound = role(ModelRole.summary);
    if (bound == null ||
        bound.inherited ||
        bound.channel.id == channels.activeId) {
      return llm.summarize(systemPrompt, payload);
    }
    final client = ConfigurableLlmClient(
      config: channels.configForRole(bound),
      httpClient: buildHttpClient(proxy: bound.channel.proxy),
    )..bearerProvider = () => accounts.authFor(bound.channel,
        apiKey: channels.apiKeyOf(bound.channel));
    try {
      return await client.summarize(systemPrompt, payload);
    } finally {
      client.cancel();
    }
  }

  // Skill 装在 rootfs 的 /opt/burrow-skills 里，索引留在 app 私有目录 ——
  // rootfs 会被「代目录 + 原子 rename」整个换掉，索引跟着丢的话
  // 用户会看到「我明明装过的 skill 不见了」。见 SkillStore 的注释。
  final skills = SkillStore(
    root: activeDistro.value == null
        ? null
        : Directory('${activeDistro.value!.rootfs.path}/opt/burrow-skills'),
    indexFile: File('${files.path}/skills/index.json'),
    fetch: (url) async {
      final resp = await http.get(Uri.parse(url));
      if (resp.statusCode != 200) {
        throw SkillException('下载失败：HTTP ${resp.statusCode}  $url');
      }
      return resp.bodyBytes;
    },
  );
  await skills.open();

  // 皮肤包装在 app 私有目录，**不是** rootfs —— rootfs 会被整个换掉，
  // 换个发行版皮肤就没了；而降级模式下压根没有 rootfs，那样连主题都起不来。
  //
  // 在 runApp 之前 await：异步在首帧之后加载会先闪一下默认主题，
  // 而主题闪烁是那种"看着就很廉价"的 bug。
  final skins = ChatSkinStore(root: Directory('${files.path}/skins'));
  await skins.open();

  // 前置多模态：对话模型不认图时，先找一个配了视觉模型的渠道把图描述成文字。
  //
  // 候选**每次现算**而不是启动时定好：渠道随时会被改、被删，
  // 定好的一份列表迟早会指向一个不存在的渠道。
  //
  // 分工表里点名的那个排最前（[VisionCandidate.preferred]），剩下的仍然是
  // 「哪些渠道自己配了视觉模型」那份。点名的失败了还能退到别人身上。
  final vision = VisionPreprocessor(
    candidates: () {
      final named = role(ModelRole.vision);
      return <VisionCandidate>[
        if (named != null)
          VisionCandidate(
            label: '${named.channel.name} · ${named.model}',
            config: channels.configForRole(named, sendImagesInline: true),
            auth: () => accounts.authFor(named.channel,
                apiKey: channels.apiKeyOf(named.channel)),
            preferred: true,
          ),
        for (final channel in channels.channels)
          if (channel.canDescribeImages &&
              // 点名的那个已经在上面了，别再作为普通候选进一次池 ——
              // 进两次的话它在"随机挑"里的权重会翻倍，而它本来就不该参与随机。
              !(named != null &&
                  named.channel.id == channel.id &&
                  named.model == channel.visionModel))
            VisionCandidate(
              label: '${channel.name} · ${channel.visionModel}',
              // 地址、协议、代理都跟着那个渠道走，只把模型换成视觉模型。
              config: channels
                  .configFor(channel, sendImagesInline: true)
                  .copyWith(model: channel.visionModel),
              auth: () =>
                  accounts.authFor(channel, apiKey: channels.apiKeyOf(channel)),
            ),
      ];
    },
    createClient: (config, auth) => ConfigurableLlmClient(
      config: config,
      httpClient: buildHttpClient(proxy: config.proxy),
    )..bearerProvider = auth,
  );

  runApp(BurrowApp(
    skins: skins,
    buildRuntime: buildRuntime,
    buildAgent: (host, runtime) => AgentLoop(
      llm: llm,
      host: host,
      // 包管理器的名字随发行版变（apk / apt），策略表要跟着走。
      // 放行名单跟着设置走：用户在弹窗里点「以后允许」、或在设置里删掉
      // 一条，下一次判定就得按新的来。
      policy: ExecPolicy(allowed: () => settings.allowedCommands),
      sandbox: runtime.sandbox,
      snapshots: runtime.snapshots,
      prefixGens: gens,
      overflow: OverflowManager(
        summarize: summarize,
        trigger: settings.overflowTrigger,
        messageThreshold: settings.messageThreshold,
        tokenThreshold: settings.tokenThreshold,
      ),
      // 每个会话一份向量索引：语料是这个会话的历史，跨会话共用没有意义。
      //
      // 指纹交给它自己盯：换了嵌入模型（或者把那个渠道删了）之后旧向量
      // 就不在同一个空间里了，而算出来的余弦仍然是个"看着挺正常"的数。
      retrieval: MemoryRetrieval(
        embedder: embedder.call,
        fingerprint: () => role(ModelRole.embedding)?.fingerprint ?? '',
      ),
      distiller: OutputDistiller(),
      limitGuard: ContextLimitGuard(),
      skills: skills,
      vision: vision,
      mode: settings.approvalMode,
      sandboxLevel: settings.sandboxLevel,
      outputArchiveDir:
          Directory('${sandboxRoot.path}/tasks/${runtime.id}/outputs'),
    ),
    capabilities: caps,
    prefixGens: gens,
    spawner: spawner,
    activeDistro: activeDistro,
    distros: distros,
    abi: native.abi,
    llm: llm,
    settings: settings,
    chats: chats,
    skills: skills,
    accounts: accounts,
    channels: channels,
    unlocked: unlocked,
  ));
}
