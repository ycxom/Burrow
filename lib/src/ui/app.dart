/// UI 层。三个页签：对话、终端、检查点。
///
/// 设计取向：**把沙箱状态和回滚入口做成一等公民**，而不是藏在设置里。
/// 用户随时该能看到「我现在被保护到什么程度」和「出事了退到哪」——
/// 这两件事是这个 app 相对普通 LLM 客户端的全部价值所在。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:xterm/xterm.dart';

import '../agent/agent_loop.dart';
import '../agent/tools.dart';
import '../bootstrap/distro.dart';
import '../context/overflow_manager.dart';
import '../data/chat_store.dart';
import '../data/task_runtime.dart';
import '../sandbox/exec_policy.dart';
import '../sandbox/prefix_generations.dart';
import '../sandbox/pty_channel.dart';
import '../sandbox/sandbox_session.dart';
import '../sandbox/snapshot_store.dart';
import '../llm/llm_client.dart';
import '../llm/model_catalog.dart';
import '../net/proxy_client.dart';
import '../settings/settings_store.dart';
import '../settings/account_store.dart';
import '../settings/channel_store.dart';
import '../skills/skill_store.dart';
import 'channels_page.dart';
import 'chat_drawer.dart';
import 'chat_theme.dart';
import 'chat_view.dart';
import 'model_bar.dart';
import 'settings_page.dart';
import 'skills_page.dart';

/// 当前 UI 文案是中文。把 locale 明确交给 Material 本地化后，TextField 的
/// 原生操作菜单也会使用“剪切 / 复制 / 粘贴 / 全选”，而不是落回英文。
/// 将来加入应用语言设置时，只需把这里替换成设置值，所有输入控件会一起切换。
const _appLocale = Locale('zh', 'CN');
const _supportedLocales = <Locale>[
  Locale('zh', 'CN'),
  Locale('en'),
];
const _localizationsDelegates = <LocalizationsDelegate<dynamic>>[
  GlobalMaterialLocalizations.delegate,
  GlobalWidgetsLocalizations.delegate,
  GlobalCupertinoLocalizations.delegate,
];

// ---------------------------------------------------------------------------
// 首次启动：选一个发行版基座
// ---------------------------------------------------------------------------

class DistroSetupApp extends StatelessWidget {
  final DistroManager manager;
  final String abi;
  final Future<void> Function(InstalledDistro chosen) onReady;

  /// 跳过安装，进降级模式（只有 Android 自带的 /system/bin/sh）。
  /// 保留这条路是为了让没网的用户至少能进得去，以及让 pty 链路
  /// 能脱离发行版单独验证。
  final Future<void> Function() onSkip;

  const DistroSetupApp({
    super.key,
    required this.manager,
    required this.abi,
    required this.onReady,
    required this.onSkip,
  });

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Burrow',
        locale: _appLocale,
        supportedLocales: _supportedLocales,
        localizationsDelegates: _localizationsDelegates,
        theme: ThemeData.dark(useMaterial3: true),
        home: DistroSetupScreen(
          manager: manager,
          abi: abi,
          onReady: onReady,
          onSkip: onSkip,
        ),
      );
}

class DistroSetupScreen extends StatefulWidget {
  final DistroManager manager;
  final String abi;
  final Future<void> Function(InstalledDistro chosen) onReady;

  /// null = 不显示「暂不安装」。
  ///
  /// 启动路径上必须给一条跳过的路（没网的用户否则连不进 app）；
  /// 而从聊天里点进来时不需要 —— 用户是奔着装基座来的，
  /// 不想装直接返回就行，再摆一个「暂不安装」只是同一个动作的第二个入口。
  final Future<void> Function()? onSkip;

  /// 作为一个页面被 push 进来（而不是启动时的全屏引导）。
  /// 影响的只有外壳：加标题栏和返回键。
  final bool asPage;

  const DistroSetupScreen({
    super.key,
    required this.manager,
    required this.abi,
    required this.onReady,
    this.onSkip,
    this.asPage = false,
  });

  @override
  State<DistroSetupScreen> createState() => _DistroSetupScreenState();
}

class _DistroSetupScreenState extends State<DistroSetupScreen> {
  Distro? _installing;
  final Map<String, DistroSource> _selectedSources = {};
  DistroProgress _progress = const DistroProgress('');
  Object? _error;

  Future<void> _install(Distro d) async {
    setState(() {
      _installing = d;
      _error = null;
      _progress = const DistroProgress('准备中');
    });
    try {
      final source = _sourceFor(d);
      await for (final p in widget.manager.install(d, source: source)) {
        if (mounted) setState(() => _progress = p);
      }
      await widget.onReady(InstalledDistro(d, widget.manager.rootfsDirFor(d)));
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _installing = null;
        });
      }
    }
  }

  DistroSource? _sourceFor(Distro distro) =>
      _selectedSources[distro.id] ??
      distro.defaultSource(MirrorRegion.china) ??
      (distro.sources.isEmpty ? null : distro.sources.first);

  static String _sourceLabel(DistroSource source) =>
      '${source.region == MirrorRegion.china ? '中国大陆' : '国际'} · '
      '${source.displayName}';

  @override
  Widget build(BuildContext context) {
    final available = DistroCatalog.forAbi(widget.abi);

    // 装到一半退出：staging 目录下次安装会自动清掉，但那条正在写的下载流
    // 没人收，它的 setState 会打在一个已经销毁的 State 上。所以安装期间
    // 连同硬件返回键一起挡住 —— 装完（几秒到一分钟）自然放开。
    return PopScope(
      canPop: _installing == null,
      child: Scaffold(
        appBar: widget.asPage
            ? AppBar(
                title: const Text('安装沙箱基座'),
                automaticallyImplyLeading: _installing == null,
              )
            : null,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: _installing != null
                ? _buildInstalling()
                : _buildPicker(available),
          ),
        ),
      ),
    );
  }

  Widget _buildInstalling() => Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text('正在安装 ${_installing!.displayName}',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (_sourceFor(_installing!) case final source?)
            Text('下载源：${_sourceLabel(source)}',
                style: const TextStyle(fontSize: 11)),
          const SizedBox(height: 20),
          Text(_progress.stage, style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 12),
          LinearProgressIndicator(
            value: _progress.fraction < 0 ? null : _progress.fraction,
          ),
          const SizedBox(height: 20),
          const Text('首次安装需要联网下载 rootfs，之后不再需要。',
              style: TextStyle(fontSize: 11)),
        ],
      );

  Widget _buildPicker(List<Distro> available) => ListView(
        children: [
          const SizedBox(height: 20),
          Text('选择沙箱基座', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          const Text(
            'Agent 的所有命令都在这个发行版里执行，和你手机的其它部分隔离。'
            '之后可以随时增删或切换。',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 8),
          const Row(
            children: [
              Icon(Icons.language, size: 16),
              SizedBox(width: 6),
              Expanded(
                child: Text(
                  '每个基座的下载源同时列出中国大陆与国际镜像，默认选择大陆镜像。',
                  style: TextStyle(fontSize: 11),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          if (_error != null)
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text('$_error', style: const TextStyle(fontSize: 12)),
              ),
            ),
          for (final d in available)
            Card(
              child: Column(children: [
                ListTile(
                  enabled: d.isAvailableOn(widget.abi),
                  title: Row(children: [
                    Text(d.displayName),
                    if (d.id == DistroCatalog.defaultDistro.id &&
                        d.isAvailableOn(widget.abi))
                      const Padding(
                        padding: EdgeInsets.only(left: 8),
                        child: Chip(
                          label: Text('推荐', style: TextStyle(fontSize: 10)),
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                        ),
                      ),
                  ]),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      // 不可用时把原因顶到最前面 —— 用户扫一眼就该知道
                      // 为什么这一项点不动，而不是以为 app 坏了。
                      d.isAvailableOn(widget.abi)
                          ? d.description
                          : '暂不可用：${d.blockedReasonFor(widget.abi)}\n'
                              '${d.description}',
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                  trailing: Icon(d.isAvailableOn(widget.abi)
                      ? Icons.download
                      : Icons.block),
                  onTap: d.isAvailableOn(widget.abi) ? () => _install(d) : null,
                ),
                if (d.isAvailableOn(widget.abi) && d.sources.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: DropdownButtonFormField<DistroSource>(
                      isExpanded: true,
                      initialValue: _sourceFor(d),
                      decoration: const InputDecoration(
                        labelText: '下载源（中国大陆 / 国际）',
                        prefixIcon: Icon(Icons.public),
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      items: d.sources
                          .map((s) => DropdownMenuItem(
                                value: s,
                                child: Text(_sourceLabel(s)),
                              ))
                          .toList(),
                      onChanged: (source) {
                        if (source != null) {
                          setState(() => _selectedSources[d.id] = source);
                        }
                      },
                    ),
                  ),
              ]),
            ),
          if (available.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  '当前设备的 ABI（${widget.abi}）没有可用的 rootfs。'
                  '目前只支持 arm64-v8a 和 x86_64。',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ),
          const SizedBox(height: 16),
          if (widget.onSkip case final skip?)
            TextButton(
              onPressed: () => skip(),
              child: const Text('暂不安装，先用 Android 自带的 shell'),
            ),
        ],
      );
}

// ---------------------------------------------------------------------------
// 主应用
// ---------------------------------------------------------------------------

/// 主题。种子色和各处底色见 chat_theme.dart，
/// 让 Material 组件（弹窗、按钮、进度条）和聊天区是同一套颜色 ——
/// 只改聊天区的话，一点开设置页就会看出是两个 app 拼起来的。
ThemeData _buildTheme(Brightness brightness) {
  final tokens =
      brightness == Brightness.light ? ChatTokens.light : ChatTokens.dark;
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: ColorScheme.fromSeed(
      seedColor: tokens.brand,
      brightness: brightness,
    ).copyWith(surface: tokens.bgPrimary),
    scaffoldBackgroundColor: tokens.bgPrimary,
    appBarTheme: AppBarTheme(
      backgroundColor: tokens.bgPrimary,
      foregroundColor: tokens.tintPrimary,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    extensions: <ThemeExtension<dynamic>>[tokens],
  );
}

class BurrowApp extends StatelessWidget {
  final AgentLoop Function(AgentHost host, TaskRuntime runtime) buildAgent;
  final Future<TaskRuntime> Function(String taskId) buildRuntime;
  final SandboxCapabilities capabilities;
  final PrefixGenerations prefixGens;
  final PtyChannel spawner;

  /// 当前挂载的发行版。**是个 ValueNotifier 而不是一个值** ——
  /// 用户可以在聊天里当场装一个基座，装完 buildRuntime 造出来的新会话
  /// 必须看到它，否则「装完了但新开的对话还是降级模式」。
  final ValueNotifier<InstalledDistro?> activeDistro;

  /// 聊天里勾终端模式、发现没装基座时要用它跳安装页。
  final DistroManager distros;
  final String abi;

  final ConfigurableLlmClient llm;
  final SettingsStore settings;
  final ChatStore chats;
  final SkillStore skills;
  final AccountStore accounts;
  final ChannelStore channels;

  const BurrowApp({
    super.key,
    required this.buildAgent,
    required this.buildRuntime,
    required this.capabilities,
    required this.prefixGens,
    required this.spawner,
    required this.activeDistro,
    required this.distros,
    required this.abi,
    required this.llm,
    required this.settings,
    required this.chats,
    required this.skills,
    required this.accounts,
    required this.channels,
  });

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Burrow',
        locale: _appLocale,
        supportedLocales: _supportedLocales,
        localizationsDelegates: _localizationsDelegates,
        theme: _buildTheme(Brightness.light),
        darkTheme: _buildTheme(Brightness.dark),
        home: ChatShell(
          buildAgent: buildAgent,
          buildRuntime: buildRuntime,
          capabilities: capabilities,
          prefixGens: prefixGens,
          spawner: spawner,
          activeDistro: activeDistro,
          distros: distros,
          abi: abi,
          llm: llm,
          settings: settings,
          chats: chats,
          skills: skills,
          accounts: accounts,
          channels: channels,
        ),
      );
}

/// 顶层外壳：管「当前打开的是哪个会话」。
///
/// 换会话是**原地替换**而不是 push 一个新页面。理由是导航栈：
/// 从抽屉里点会话 A 再点会话 B，push 的话栈里会堆两层，
/// 按返回键回到 A 是没人预期的行为（用户以为是退出）。
///
/// 替换的代价是 HomeShell 要连同它的 AgentLoop、TaskRuntime、pty 会话
/// 一起重建。用 ValueKey(threadId) 让 Flutter 自己做这件事 ——
/// 手动 dispose 再 init 极容易漏掉一个（尤其是 pty，漏了就泄露一个进程）。
class ChatShell extends StatefulWidget {
  final AgentLoop Function(AgentHost host, TaskRuntime runtime) buildAgent;
  final Future<TaskRuntime> Function(String taskId) buildRuntime;
  final SandboxCapabilities capabilities;
  final PrefixGenerations prefixGens;
  final PtyChannel spawner;
  final ValueNotifier<InstalledDistro?> activeDistro;
  final DistroManager distros;
  final String abi;
  final ConfigurableLlmClient llm;
  final SettingsStore settings;
  final ChatStore chats;
  final SkillStore skills;
  final AccountStore accounts;
  final ChannelStore channels;

  const ChatShell({
    super.key,
    required this.buildAgent,
    required this.buildRuntime,
    required this.capabilities,
    required this.prefixGens,
    required this.spawner,
    required this.activeDistro,
    required this.distros,
    required this.abi,
    required this.llm,
    required this.settings,
    required this.chats,
    required this.skills,
    required this.accounts,
    required this.channels,
  });

  @override
  State<ChatShell> createState() => _ChatShellState();
}

class _ChatShellState extends State<ChatShell> {
  String? _threadId;
  String _title = '新对话';

  /// 未存盘会话的 runtime id。每开一个新会话换一个 ——
  /// 复用的话两个草稿会共用同一个 workspace，互相看到对方的文件。
  late String _draftId = _newDraftId();

  static String _newDraftId() =>
      'draft_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';

  Future<void> _select(String? threadId) async {
    if (threadId == null) {
      setState(() {
        _threadId = null;
        _draftId = _newDraftId();
        _title = '新对话';
      });
      return;
    }
    // 标题从库里取。抽屉传过来也行，但那会让「重命名后立刻切过去」
    // 拿到旧标题 —— 多查一次的代价可以忽略。
    final threads = await widget.chats.threads();
    final match = threads.where((t) => t.id == threadId);
    setState(() {
      _threadId = threadId;
      _title = match.isEmpty ? '对话' : match.first.title;
    });
  }

  @override
  Widget build(BuildContext context) {
    final runtimeId = _threadId ?? _draftId;
    return HomeShell(
      // key 变了 Flutter 就重建整棵子树，连同 pty 会话一起收干净。
      key: ValueKey(runtimeId),
      buildAgent: widget.buildAgent,
      runtime: widget.buildRuntime(runtimeId),
      runtimeId: runtimeId,
      capabilities: widget.capabilities,
      prefixGens: widget.prefixGens,
      spawner: widget.spawner,
      activeDistro: widget.activeDistro,
      distros: widget.distros,
      abi: widget.abi,
      llm: widget.llm,
      settings: widget.settings,
      chats: widget.chats,
      skills: widget.skills,
      accounts: widget.accounts,
      channels: widget.channels,
      threadId: _threadId,
      title: _title,
      onSelectThread: _select,
      onTitleChanged: (title) => setState(() => _title = title),
    );
  }
}

/// 报错气泡的前缀。
///
/// 用前缀识别而不是给 ChatMessage 加一个 isError 字段：这条消息要落进
/// sqlite 再读回来，加字段要动表结构和迁移；而**不能**简单地"把 system
/// 角色一律画成报错" —— 检索注入的历史片段也是 system 角色，它们会被
/// 一起持久化，重开会话时同样出现在列表里。
///
/// 前缀对不上的最坏结果是报错画成了普通气泡，不会崩。
const kErrorPrefix = '出错：';

class HomeShell extends StatefulWidget {
  final AgentLoop Function(AgentHost host, TaskRuntime runtime) buildAgent;
  final Future<TaskRuntime> runtime;
  final String runtimeId;
  final SandboxCapabilities capabilities;
  final PrefixGenerations prefixGens;
  final PtyChannel spawner;
  final ValueNotifier<InstalledDistro?> activeDistro;
  final DistroManager distros;
  final String abi;
  final ConfigurableLlmClient llm;
  final SettingsStore settings;
  final ChatStore chats;
  final SkillStore skills;
  final AccountStore accounts;
  final ChannelStore channels;
  final String? threadId;
  final String title;

  /// 抽屉里选了别的会话。
  final ValueChanged<String?> onSelectThread;

  /// 第一条消息落库之后，把标题回传给外壳。
  final ValueChanged<String> onTitleChanged;

  const HomeShell({
    super.key,
    required this.buildAgent,
    required this.runtime,
    required this.runtimeId,
    required this.capabilities,
    required this.prefixGens,
    required this.spawner,
    required this.activeDistro,
    required this.distros,
    required this.abi,
    required this.llm,
    required this.settings,
    required this.chats,
    required this.skills,
    required this.accounts,
    required this.channels,
    required this.threadId,
    required this.title,
    required this.onSelectThread,
    required this.onTitleChanged,
  });

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> implements AgentHost {
  late final AgentLoop _agent;
  late final TaskRuntime _runtime;
  late final Terminal _terminal;

  final List<ChatMessage> _visible = [];
  final _input = TextEditingController();
  final _scroll = ScrollController();

  int _tab = 0;
  String? _status;
  Timer? _statusTimer;
  bool _busy = false;
  bool _loadingHistory = true;
  bool _cancelRequested = false;
  bool _runtimeReady = false;
  bool _installingDistro = false;
  String? _threadId;

  InstalledDistro? get _distro => widget.activeDistro.value;

  /// 顶栏副标题上的瞬时状态。
  ///
  /// **会自己撤掉。** 状态说的是"刚刚发生了什么"，副标题平时要显示的是
  /// "现在是什么"（模型 + 沙箱档位）。不撤的话副标题会永远停在最后一条
  /// 状态上，而那两样恰恰是这个 app 要求一直可见的东西。
  void _setStatus(String message) {
    _statusTimer?.cancel();
    setState(() => _status = message);
    _statusTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _status = null);
    });
  }

  /// 助手当前这一轮的流式文本。单独存而不是每个 delta 都往 _visible 里塞，
  /// 否则每个 token 都触发一次列表重建，长回复时会明显掉帧。
  final _streaming = StringBuffer();
  Timer? _streamPaintTimer;

  /// 用户手动敲命令的那个 shell。**和 Agent 用的是两个不同的会话** ——
  /// 共用一个的话，Agent 的 cd 会污染用户的会话，用户的 export 会污染
  /// Agent 的可复现性（见 ARCHITECTURE.md §3）。
  PtyHandle? _shell;

  @override
  void initState() {
    super.initState();
    _terminal = Terminal(maxLines: 5000);
    _threadId = widget.threadId;
    // 设置页改了排版或模型名要立刻反映到这里。不订阅的话，从设置返回后
    // 界面还是旧的，用户会以为那个开关坏了 —— 而它其实已经存下去了，
    // 只是要杀进程重开才看得到，这是最难自证的一类"没生效"。
    widget.settings.addListener(_onSettingsChanged);
    _prepareRuntime();
  }

  /// 当前渠道名，用来给模型标来源。只有一个渠道时是 null ——
  /// 没有第二个来源要区分，那个前缀就只是噪音。
  String? get _sourceName {
    if (widget.channels.channels.length < 2) return null;
    return widget.channels.active?.name;
  }

  void _onSettingsChanged() {
    if (!mounted) return;
    // 设置页改完要**当场**对正在进行的会话生效，而不是等下次新建会话。
    // `_agent` 是 late final，runtime 没准备好时读它会抛，所以要守一下。
    if (_runtimeReady) {
      _agent.sandboxLevel = widget.settings.sandboxLevel;
      _agent.mode = widget.settings.approvalMode;
      // 换渠道/换模型之后，接下来生成的助手消息要署新的来源。
      _agent.sourceLabel = widget.settings.sourceLabel;
      _agent.overflow
        ..trigger = widget.settings.overflowTrigger
        ..messageThreshold = widget.settings.messageThreshold
        ..tokenThreshold = widget.settings.tokenThreshold;
    }
    setState(() {});
  }

  Future<void> _prepareRuntime() async {
    _runtime = await widget.runtime;
    _agent = widget.buildAgent(this, _runtime);
    _agent.sourceLabel = widget.settings.sourceLabel;
    await _restoreTerminalMode();
    await _loadHistory();
    await _startShell();
    if (mounted) setState(() => _runtimeReady = true);
  }

  /// 恢复这个会话的终端模式。老会话按存的来，新会话按上次的选择来。
  ///
  /// 基座没装时一律按关处理，哪怕库里存的是开：开着而没有 rootfs 等于
  /// 把模型放进 Android 自带的 mksh 里，它会对着一串 command not found
  /// 原地打转。宁可让用户重勾一次 —— 那一勾会把安装流程带出来。
  Future<void> _restoreTerminalMode() async {
    final id = widget.threadId;
    final stored = id == null ? null : await widget.chats.terminalModeOf(id);
    final wanted = stored ?? widget.settings.terminalModeDefault;
    _agent.terminalMode = wanted && _distro != null;
  }

  Future<void> _loadHistory() async {
    final id = _threadId;
    if (id != null) {
      final messages = await widget.chats.messages(id);
      _agent.history.addAll(messages);
      _visible.addAll(messages.where((message) => message.role != 'tool'));
    }
    if (mounted) setState(() => _loadingHistory = false);
  }

  Future<void> _startShell() async {
    // 借 SandboxSession 组装 argv/env，这样交互 shell 和 Agent 跑的命令
    // 处在完全相同的环境里 —— 否则用户在终端里试通的命令，
    // Agent 跑起来可能是另一个结果，那种不一致极难排查。
    //
    // **档位必须和 argv/env 用同一个。** 这里曾经传 dangerFullAccess，
    // 本意是「交互会话不套 burrow-launch」，但那个档位同时也关掉了 proot ——
    // 于是终端落在宿主的 /system/bin/sh 里，`apk` 找不到、`/etc/os-release`
    // 不存在，而 Agent 却在 rootfs 内。正是上面这段注释警告的那种不一致。
    //
    // 用联网档而不是 workspaceWrite：用户手动敲命令时会想 `apk add`，
    // 断网档会让他对着一个没有解释的失败发呆。Agent 才需要默认断网。
    const level = SandboxLevel.workspaceWriteNetwork;
    final argv = _runtime.sandbox.buildArgv(
      _distro != null ? 'exec /bin/sh -l' : 'exec sh',
      level,
    );
    final env = _runtime.sandbox.buildEnv(level);

    try {
      final handle = await widget.spawner.spawn(
        argv: argv,
        env: env,
        cwd: _runtime.sandbox.workspacePath,
        rows: 24,
        cols: 80,
      );
      _shell = handle;

      // 键盘 → pty
      _terminal.onOutput = (data) => handle.write(data.codeUnits);
      _terminal.onResize = (w, h, _, __) => handle.resize(h, w);

      // pty → 屏幕
      //
      // 两条收尾消息都先确认这个 handle 还是当前那个。装完基座重开 shell 时
      // 旧 shell 是被我们自己 kill 的，它的 `[shell 退出，code=-9]` 会在新
      // shell 已经起来之后才到，读起来像是「刚开的 shell 当场就死了」。
      handle.output.listen(
        (chunk) => _terminal.write(String.fromCharCodes(chunk)),
        onDone: () {
          if (identical(_shell, handle)) {
            _terminal.write('\r\n[会话已结束]\r\n');
          }
        },
      );
      handle.exitCode.then((code) {
        if (identical(_shell, handle)) {
          _terminal.write('\r\n[shell 退出，code=$code]\r\n');
        }
      });
    } catch (e) {
      _terminal.write('无法启动 shell：$e\r\n');
    }
  }

  // ---- 抽屉里的入口 ----

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsPage(
          store: widget.settings,
          accounts: widget.accounts,
          channels: widget.channels,
          capabilities: widget.capabilities,
          // 每个会话一个目录，父目录就是全部会话的容器。
          tasksRoot: _runtime.root.parent,
          currentTaskId: _runtime.id,
          overflow: _agent.overflow,
          snapshots: _runtime.snapshots,
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _openSkills() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => SkillsPage(store: widget.skills)),
    );
    if (mounted) setState(() {});
  }

  Future<void> _openChannels() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
          builder: (_) => ChannelsPage(
                channels: widget.channels,
                accounts: widget.accounts,
              )),
    );
    if (mounted) setState(() {});
  }

  // ---- 消息操作 ----

  /// 把某条用户消息填回输入框，并丢弃它之后的一切。
  ///
  /// 「编辑」在聊天里的语义就是「当没说过，重说一遍」，所以它和
  /// 「回到这里」是同一个动作，只是多了一步把原文填回输入框。
  Future<void> _editMessage(int visibleIndex) async {
    if (_busy) return;
    final text = _visible[visibleIndex].content;
    final ok = await _rewind(visibleIndex, confirmTitle: '编辑并重发');
    if (!ok) return;
    _input.text = text;
    _input.selection = TextSelection.collapsed(offset: text.length);
  }

  /// 回到某条消息之前：截断对话 + 回滚文件。
  Future<void> _rewindTo(int visibleIndex) async {
    if (_busy) return;
    await _rewind(visibleIndex, confirmTitle: '回到这里');
  }

  /// 只截断对话，不动文件。
  Future<void> _deleteFrom(int visibleIndex) async {
    if (_busy) return;
    final confirmed = await _confirm(
      '删除这条及之后',
      '这条消息和它之后的所有消息都会被删除。\n'
          '文件不会回滚 —— 模型改过的东西还留在 workspace 里。',
    );
    if (!confirmed) return;

    final historyIndex = _historyIndexOf(visibleIndex);
    if (historyIndex >= 0) {
      _agent.history.removeRange(historyIndex, _agent.history.length);
    }
    setState(() => _visible.removeRange(visibleIndex, _visible.length));
    await _persist();
  }

  Future<bool> _rewind(int visibleIndex, {required String confirmTitle}) async {
    final message = _visible[visibleIndex];
    final hasCheckpoint = message.checkpoint != null;
    final confirmed = await _confirm(
      confirmTitle,
      hasCheckpoint
          ? '这条消息之后的对话会被丢弃，workspace 里的文件也会一起回到'
              '发这条消息之前的状态（检查点 #${message.checkpoint}）。'
          // 老会话没有检查点记录。**必须说出来** —— 用户点「回到这里」
          // 的预期就是文件也回去，静默地只截对话会让他在一个已经被改过的
          // workspace 上继续操作而不自知。
          : '这条消息之后的对话会被丢弃。\n'
              '这条消息是旧版本存下的，没有检查点记录，'
              'workspace 里的文件不会回滚。',
    );
    if (!confirmed) return false;

    final historyIndex = _historyIndexOf(visibleIndex);
    if (historyIndex < 0) return false;

    final result = await _agent.rewindTo(historyIndex);
    if (!mounted) return false;
    setState(() => _visible.removeRange(visibleIndex, _visible.length));
    await _persist();

    if (result.unrecoverable.isNotEmpty && mounted) {
      // 部分成功必须显式说。被报告成成功的话，用户会基于错误的前提继续做。
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${result.unrecoverable.length} 个文件的旧内容没存下来，'
            '没能恢复：${result.unrecoverable.take(3).join('、')}'),
        duration: const Duration(seconds: 6),
      ));
    }
    return true;
  }

  /// `_visible` 过滤掉了 tool 消息，所以下标和 `history` 对不上。
  /// 靠身份匹配而不是算偏移 —— 算偏移在「删了一条又加一条」之后就会错位，
  /// 而错位的表现是回滚到了错误的位置，非常难发现。
  int _historyIndexOf(int visibleIndex) {
    if (visibleIndex < 0 || visibleIndex >= _visible.length) return -1;
    final target = _visible[visibleIndex];
    return _agent.history.indexWhere((m) => identical(m, target));
  }

  Future<void> _persist() async {
    final id = _threadId;
    if (id != null) await widget.chats.replaceMessages(id, _agent.history);
  }

  Future<bool> _confirm(String title, String body) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('确定')),
        ],
      ),
    );
    return result ?? false;
  }

  // ---- 终端模式 ----

  /// 勾/取消「终端模式」。
  ///
  /// 勾上时如果还没装基座，先把安装页推出来 —— 这是用户唯一一次需要
  /// 关心「基座」这个概念的时刻，把它放在勾选的那一下，比放在设置里
  /// 某个二级页面要好：想用终端的人自然会走到这里。
  /// 装完立刻生效，不重启 app。
  Future<void> _setTerminalMode(bool on) async {
    // 跑到一半换模式会让这一轮已经发出去的工具调用悬空：
    // 模型以为有工具，回来时工具没了。等这轮结束再说。
    if (_busy || _installingDistro) return;

    if (on && _distro == null) {
      final installed = await _pushInstaller();
      if (installed == null) return; // 放弃安装 → 开关保持关着
      await _activateDistro(installed);
    }

    if (!mounted) return;
    setState(() => _agent.terminalMode = on);
    await widget.settings.setTerminalModeDefault(on);
    final id = _threadId;
    if (id != null) await widget.chats.setTerminalMode(id, on);
  }

  Future<InstalledDistro?> _pushInstaller() async {
    setState(() => _installingDistro = true);
    try {
      return await Navigator.of(context).push<InstalledDistro>(
        MaterialPageRoute<InstalledDistro>(
          builder: (routeContext) => DistroSetupScreen(
            manager: widget.distros,
            abi: widget.abi,
            asPage: true,
            onReady: (chosen) async => Navigator.of(routeContext).pop(chosen),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _installingDistro = false);
    }
  }

  /// 让刚装好的基座立刻生效。
  ///
  /// 三个地方都要换，漏一个就是一类静默错误：
  ///   - sandbox   → 下一条命令落在新 rootfs 里
  ///   - prefixGens→ 装包事务的暂存/代目录跟着 rootfs 走
  ///   - 交互 shell→ argv 在 spawn 那一刻就定死了，只能重开
  Future<void> _activateDistro(InstalledDistro installed) async {
    widget.activeDistro.value = installed;
    _runtime.sandbox.attachDistro(
      rootfsPath: installed.rootfs.path,
      label: installed.distro.displayName,
      packageManager: installed.distro.packageManager,
    );
    await widget.prefixGens.rebind(installed.rootfs.parent);
    // skill 装在 rootfs 里，换了基座就要跟着换 —— 不换的话技能页会
    // 一直显示"已安装"，而模型 read_skill 会读到一个不存在的路径。
    await widget.skills
        .rebindRoot(Directory('${installed.rootfs.path}/opt/burrow-skills'));
    await _restartShell();
    if (mounted) {
      _setStatus('${installed.distro.displayName} 已就绪，命令现在跑在沙箱里');
    }
  }

  Future<void> _restartShell() async {
    _shell?.killGroup();
    _shell = null;
    _terminal.write('\r\n[切换到新基座，正在重开 shell]\r\n');
    await _startShell();
  }

  @override
  void dispose() {
    widget.settings.removeListener(_onSettingsChanged);
    _statusTimer?.cancel();
    _shell?.killGroup();
    if (_runtimeReady && _threadId == null) {
      unawaited(_runtime.root.delete(recursive: true));
    }
    _input.dispose();
    _scroll.dispose();
    _streamPaintTimer?.cancel();
    super.dispose();
  }

  // ---- AgentHost ----

  @override
  Future<bool> requestApproval(ToolCall call, PolicyVerdict verdict) async {
    final detail = call.name == 'exec'
        ? call.args['command'] as String? ?? ''
        : '${call.name} ${call.args}';

    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            title: Row(children: [
              Icon(verdict.scope == WriteScope.prefix
                  ? Icons.inventory_2_outlined
                  : Icons.warning_amber_outlined),
              const SizedBox(width: 8),
              const Text('需要确认'),
            ]),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 命令原文用等宽字体、可选中。审批弹窗里最重要的就是让人
                // 看清到底要跑什么 —— 截断或换字体都会让人下意识点同意。
                SelectableText(detail,
                    style: const TextStyle(fontFamily: 'monospace')),
                const SizedBox(height: 12),
                Text(verdict.reason,
                    style: Theme.of(context).textTheme.bodySmall),
                if (verdict.scope == WriteScope.prefix)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text('会在环境暂存副本里执行，失败自动丢弃',
                        style: TextStyle(fontSize: 12)),
                  ),
              ],
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('拒绝')),
              FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('允许')),
            ],
          ),
        ) ??
        false;
  }

  @override
  void onAssistantDelta(String text) {
    _streaming.write(text);
    // 网络分片可能细到一个字符一次。最多约 30fps 刷新，既保持实时感，
    // 又避免 Markdown 每个 token 全量排版造成跳动和掉帧。
    _streamPaintTimer ??= Timer(const Duration(milliseconds: 33), () {
      _streamPaintTimer = null;
      if (mounted) {
        setState(() {});
        _scrollToEnd(animated: true);
      }
    });
  }

  @override
  void onTerminalChunk(List<int> chunk) {
    // Agent 跑命令时用户应该能实时看见，而不是盯着转圈等三分钟。
    _terminal.write(String.fromCharCodes(chunk));
  }

  @override
  void onStatus(String message) => _setStatus(message);

  // ---- 交互 ----

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _busy || _loadingHistory) return;
    var id = _threadId;
    if (id == null) {
      id = await widget.chats.createThread(
        text,
        preferredId: widget.runtimeId,
        terminalMode: _agent.terminalMode,
      );
      _threadId = id;
      // 外壳的标题要跟上，否则顶栏会一直显示「新对话」，
      // 而抽屉里那一条已经有名字了 —— 两处对不上很像是坏了。
      widget.onTitleChanged(
          text.length > 28 ? '${text.substring(0, 28)}…' : text);
    }
    _input.clear();
    setState(() {
      _busy = true;
      _cancelRequested = false;
      _visible
          .add(ChatMessage(role: 'user', content: text, at: DateTime.now()));
      _streaming.clear();
    });
    await widget.chats.append(id, _visible.last);

    try {
      await _agent.send(text);
    } catch (e) {
      if (!_cancelRequested) {
        final error = ChatMessage(
          role: 'system',
          content: '$kErrorPrefix$e',
          at: DateTime.now(),
        );
        _agent.history.add(error);
        setState(() => _visible.add(error));
      }
    } finally {
      setState(() {
        if (_streaming.isNotEmpty) {
          _visible.add(ChatMessage(
            role: 'assistant',
            content: _streaming.toString(),
            at: DateTime.now(),
            source: widget.settings.sourceLabel,
          ));
          _streaming.clear();
        }
        _busy = false;
      });
      await widget.chats.replaceMessages(id, _agent.history);
      _scrollToEnd();
    }
  }

  void _stop() {
    _cancelRequested = true;
    _agent.cancel();
    _setStatus('正在停止当前请求和命令…');
  }

  Future<void> _retry() async {
    if (_busy) return;
    final userIndex =
        _visible.lastIndexWhere((message) => message.role == 'user');
    if (userIndex < 0) return;
    final text = _visible[userIndex].content;
    setState(() {
      _visible.removeRange(userIndex, _visible.length);
      _input.text = text;
    });
    final historyIndex =
        _agent.history.lastIndexWhere((message) => message.role == 'user');
    if (historyIndex >= 0) {
      _agent.history.removeRange(historyIndex, _agent.history.length);
    }
    final id = _threadId;
    if (id != null) await widget.chats.replaceMessages(id, _agent.history);
    await _send();
  }

  void _scrollToEnd({bool animated = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        final end = _scroll.position.maxScrollExtent;
        if (animated) {
          _scroll.animateTo(end,
              duration: const Duration(milliseconds: 90),
              curve: Curves.easeOut);
        } else {
          _scroll.jumpTo(end);
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_runtimeReady) {
      return Scaffold(
        appBar: AppBar(title: const Text('Burrow')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    // 底栏没了之后，「怎么从终端回到对话」只剩顶栏那个图标。
    // 返回键也得能回来 —— 否则用户按返回会直接退出 app。
    return PopScope(
      canPop: _tab == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _tab = 0);
      },
      child: Scaffold(
        drawer: ChatDrawer(
          store: widget.chats,
          currentThreadId: _threadId,
          onSelect: widget.onSelectThread,
          onOpenSettings: _openSettings,
          onOpenSkills: _openSkills,
          onOpenChannels: _openChannels,
        ),
        appBar: AppBar(
          backgroundColor: context.chat.headerBg,
          titleSpacing: 0,
          // Telegram 的顶栏是「名字 + 一行状态」。点它进设置 ——
          // 对应 Telegram 里点头部进「聊天信息」。
          title: InkWell(
            onTap: _openSettings,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: <Widget>[
                  ChatAvatar(
                    role: 'assistant',
                    imagePath: widget.settings.assistantAvatarPath,
                    diameter: 38,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 16.5,
                            fontWeight: FontWeight.w600,
                            color: context.chat.tintPrimary,
                          ),
                        ),
                        const SizedBox(height: 1),
                        _buildSubtitle(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          // 终端和检查点都从顶栏进。终端本来就是给模型用的，用户偶尔进去看一眼，
          // 不值得在底部占一整格；底部那条留给真正会反复用的东西 —— 换模型。
          actions: [
            _tabAction(2, Icons.history_outlined, '检查点'),
            _tabAction(1, Icons.terminal_outlined, '终端'),
            // 设置 / 技能 / 账号都在抽屉里；终端模式和审批档位在输入框里。
          ],
        ),
        body: IndexedStack(
          index: _tab,
          children: [
            _buildChat(),
            Column(children: [
              if (_distro == null)
                Container(
                  width: double.infinity,
                  color: context.chat.tintWarning.withValues(alpha: 0.16),
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    '降级模式：未安装发行版基座，当前是 Android 自带的 '
                    '/system/bin/sh。没有包管理器，也没有 proot 路径隔离。',
                    style: TextStyle(
                        fontSize: 11, color: context.chat.tintPrimary),
                  ),
                ),
              Expanded(child: TerminalView(_terminal)),
            ]),
            _CheckpointTimeline(
              snapshots: _runtime.snapshots,
              prefixGens: widget.prefixGens,
              onRolledBack: _setStatus,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChat() {
    // 流式那条单独接在后面，而不是每个 delta 都往 _visible 里塞 ——
    // 否则每个 token 都要重建整个列表。
    final streaming = _streaming.toString();
    final rows = _buildRows(streaming.isEmpty ? null : streaming);

    final bottomInset = MediaQuery.paddingOf(context).bottom;
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: ChatWallpaper(
            preset: widget.settings.chatWallpaperPreset,
            imagePath: widget.settings.chatWallpaperPath,
            dim: widget.settings.chatWallpaperDim,
            child: ListView.builder(
              controller: _scroll,
              // 模型条和输入区悬浮在列表上面；给最后一条消息留下同等空间，
              // 否则它会停在玻璃下面，看得见却点不到。
              padding: EdgeInsets.fromLTRB(0, 8, 0, 136 + bottomInset),
              itemCount: rows.length,
              itemBuilder: (_, i) => _buildRow(rows[i]),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ModelSwitchBar(
                model: widget.settings.config.model,
                embeddingModel: widget.settings.embeddingModel,
                sourceName: _sourceName,
                embeddingError: _agent.retrieval.lastEmbeddingError,
                onPickModel: _pickModel,
                onPickEmbedding: _pickEmbeddingModel,
                floating: true,
              ),
              ChatComposer(
                controller: _input,
                generating: _busy,
                enabled: !_busy && !_loadingHistory,
                hintText: _agent.terminalMode ? '描述你希望 Agent 完成的任务' : '随便聊点什么',
                onSend: _send,
                onStop: _stop,
                effect: widget.settings.chatComposerEffect,
                blur: widget.settings.chatComposerBlur,
                opacity: widget.settings.chatComposerOpacity,
                leading: [_buildTerminalButton()],
                // 审批档位只在终端模式下有意义：聊天模式没有工具可审批。
                trailing: [if (_agent.terminalMode) _buildApprovalButton()],
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 把 `_visible` 摊成列表要画的那些行：日期分隔 + 消息 + 流式那条。
  ///
  /// 先算成一个扁平的行表再交给 `ListView.builder`，而不是在 itemBuilder 里
  /// 现算下标 —— 一旦掺进日期分隔，「第 i 行是第几条消息」就不再是同一个数，
  /// 而 `_editMessage(i)` 这些操作要的是**消息下标**。分开算就不会串。
  List<_ChatRow> _buildRows(String? streaming) {
    final rows = <_ChatRow>[];
    for (var i = 0; i < _visible.length; i++) {
      final message = _visible[i];
      if (i == 0 || !_sameDay(_visible[i - 1].at, message.at)) {
        rows.add(_ChatRow.date(message.at));
      }
      // 连续同一方的消息算一组：只有最后一条画尾巴和头像。
      final next = i + 1 < _visible.length ? _visible[i + 1] : null;
      final lastInGroup = next == null
          ? streaming == null || message.role != 'assistant'
          : next.role != message.role || !_sameDay(message.at, next.at);
      rows.add(_ChatRow.message(i, lastInGroup));
    }
    if (streaming != null) rows.add(_ChatRow.streaming(streaming));
    return rows;
  }

  Widget _buildRow(_ChatRow row) {
    final streaming = row.streaming;
    if (streaming != null) {
      return ChatBubble(
        role: 'assistant',
        text: streaming,
        generating: true,
        avatarPath: widget.settings.assistantAvatarPath,
        showAvatar: widget.settings.showMessageAvatars,
      );
    }

    final day = row.day;
    if (day != null) return ServicePill(text: _dayLabel(day));

    final i = row.index;
    final message = _visible[i];
    final isError =
        message.role == 'system' && message.content.startsWith(kErrorPrefix);

    // 系统提示不是"谁说的话"，做成居中胶囊和左右两侧的气泡分开 ——
    // 长得像助手发言的话，用户会以为模型在自言自语。
    // 报错除外：它可能很长，压进胶囊会读不了，仍然走气泡。
    if (message.role == 'system' && !isError) {
      return ServicePill(text: message.content);
    }

    final isLastAssistant =
        i == _visible.length - 1 && message.role == 'assistant' && !_busy;
    final isUser = message.role == 'user';
    return ChatBubble(
      role: message.role,
      text: message.content,
      time: message.at,
      // 用消息**自己记下的**来源，而不是当前配置。换个渠道就把满屏历史
      // 全部改署成新渠道的话，恰好会在用户回头查"刚才那次是谁花的额度"时
      // 给出错误答案。老消息没有这个记录，那就不署名。
      meta: message.source,
      isError: isError,
      lastInGroup: row.lastInGroup,
      avatarPath: isUser
          ? widget.settings.userAvatarPath
          : message.role == 'assistant'
              ? widget.settings.assistantAvatarPath
              : '',
      showAvatar: widget.settings.showMessageAvatars,
      onRetry: isLastAssistant ? _retry : null,
      // 编辑和回退只给用户消息：它们的语义都是「从这句重来」，
      // 挂在助手消息上没有对应的动作。
      onEdit: isUser && !_busy ? () => _editMessage(i) : null,
      onRewind: isUser && !_busy ? () => _rewindTo(i) : null,
      onDelete: !_busy ? () => _deleteFrom(i) : null,
    );
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  static String _dayLabel(DateTime t) {
    final now = DateTime.now();
    if (_sameDay(t, now)) return '今天';
    if (_sameDay(t, now.subtract(const Duration(days: 1)))) return '昨天';
    if (t.year == now.year) return '${t.month} 月 ${t.day} 日';
    return '${t.year} 年 ${t.month} 月 ${t.day} 日';
  }

  /// 顶栏第二行。Telegram 在这里放「在线 / 正在输入」，我们放的是
  /// 「模型 + 这一轮会怎么执行」—— 同样是"随时在变、必须一直看得见"的东西。
  ///
  /// `yolo` 尤其不能折叠：用户必须一眼看到自己关了沙箱。
  Widget _buildSubtitle() {
    final t = context.chat;
    // yolo 只在终端模式下才真的危险 —— 聊天模式下没有工具可关。
    final danger = _agent.terminalMode && _agent.mode == ApprovalMode.yolo;

    final String text;
    if (_status != null) {
      text = _status!;
    } else if (danger) {
      text = '⚠ 沙箱已关闭，命令直接在环境里执行';
    } else {
      // 带渠道名的署名（多渠道时才有）。顶栏这行是全程可见的那一行，
      // 「现在发给谁」属于必须一直看得见的东西 —— 和沙箱档位同一类。
      final model = widget.settings.sourceLabel;
      // 聊天模式下报「路径隔离 + 断网」是误导：没有任何东西在跑，
      // 那几层保护现在保护的是零。说清楚模型手里有没有工具更有用。
      final sandbox =
          _agent.terminalMode ? widget.capabilities.describe() : '聊天模式，模型没有工具';
      text = model.isEmpty ? '未配置模型 · $sandbox' : '$model · $sandbox';
    }

    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 12.5,
        height: 1.2,
        color: danger ? t.tintError : t.tintTertiary,
      ),
    );
  }

  /// 顶栏那两个页签入口。已经在那一页时再点一次回到对话 ——
  /// 图标既是"去"也是"回"，省掉一个返回键。
  Widget _tabAction(int tab, IconData icon, String tooltip) {
    final active = _tab == tab;
    return IconButton(
      tooltip: active ? '返回对话' : tooltip,
      onPressed: () => setState(() => _tab = active ? 0 : tab),
      icon: Icon(icon),
      color: active ? context.chat.brand : null,
    );
  }

  /// 拉**指定渠道**的模型列表并缓存到那个渠道名下。
  ///
  /// 带渠道参数而不是用"当前渠道"：选择器里可以翻别的来源，翻的时候
  /// 当前渠道并没有变；按当前渠道拉的话，用户看到的会是 A 的地址配 B 的列表。
  Future<List<String>> _refreshModels(String channelId) async {
    final channel = widget.channels.byId(channelId);
    if (channel == null) throw StateError('这个渠道已经不存在了');
    // 走**这个渠道自己**的代理和认证。用默认客户端的话，配了代理的渠道
    // 在这里会超时，而聊天本身是通的 —— 那种不一致最难查。
    final auth = await widget.accounts
        .authFor(channel, apiKey: widget.channels.apiKeyOf(channel));
    final client = buildHttpClient(proxy: channel.proxy);
    final List<FetchedModel> models;
    try {
      models = channel.oauthProviderId == 'openai_oauth'
          ? await fetchChatGptOAuthModels(
              accessToken: auth,
              accountId:
                  widget.accounts.credentialFor(channel)?.accountId ?? '',
              client: client,
            )
          : await fetchModels(
              baseUrl: channel.baseUrl,
              apiKey: auth,
              client: client,
            );
    } finally {
      client.close();
    }
    final ids = models.map((m) => m.id).toList();
    await widget.settings.setModelsFor(channelId, ids);
    return ids;
  }

  /// 选择器里那一排来源 = 渠道列表，各自带着自己缓存的模型。
  List<ModelSource> _modelSources() => <ModelSource>[
        for (final c in widget.channels.channels)
          ModelSource(
            id: c.id,
            name: c.name,
            host: c.host,
            models: widget.settings.modelsOf(c.id),
            configuredModel: c.model,
          ),
      ];

  /// 选中的来源不是当前渠道时，把渠道一起切过去。
  ///
  /// 顺序不能反：[SettingsStore.setModel] 改的是**当前**渠道的模型，
  /// 先设模型的话，那个模型会被写到用户正想离开的那个渠道上。
  Future<void> _adoptSource(String sourceId) async {
    if (sourceId == widget.channels.activeId) return;
    await widget.channels.setActive(sourceId);
    final name = widget.channels.byId(sourceId)?.name ?? sourceId;
    if (mounted) _setStatus('已切换到渠道「$name」');
  }

  Future<void> _pickModel() async {
    final picked = await showModelPicker(
      context,
      title: '对话模型',
      current: widget.settings.config.model,
      sources: _modelSources(),
      activeSourceId: widget.channels.activeId,
      onRefresh: _refreshModels,
    );
    if (picked == null || picked.model.isEmpty) return;
    await _adoptSource(picked.sourceId);
    await widget.settings.setModel(picked.model);
  }

  Future<void> _pickEmbeddingModel() async {
    final picked = await showModelPicker(
      context,
      title: '嵌入模型（记忆检索）',
      current: widget.settings.embeddingModel,
      sources: _modelSources(),
      activeSourceId: widget.channels.activeId,
      onRefresh: _refreshModels,
      allowNone: true,
      noneLabel: '不启用',
      error: _agent.retrieval.lastEmbeddingError,
    );
    if (picked == null) return;
    // 嵌入也发往当前渠道，所以在别的来源上挑嵌入模型同样要把渠道带过去 ——
    // 不带的话就是拿 A 的模型名去 B 那里请求，一路 404 或者更糟：
    // B 上刚好有个同名模型，于是照常计费。
    await _adoptSource(picked.sourceId);
    await widget.settings.setEmbeddingModel(picked.model);
    // 换了嵌入模型，旧向量作废：不同模型的向量不在同一个空间里，
    // 混着算余弦得到的是无意义的数。换渠道同理 —— 同名模型在两家服务商
    // 那里也是两个空间。
    _agent.retrieval.vectorIndex.clear();
    _agent.retrieval.lastEmbeddingError = null;
  }

  Widget _buildTerminalButton() {
    final on = _agent.terminalMode;
    return ComposerIconButton(
      icon: on ? Icons.terminal : Icons.terminal_outlined,
      tooltip: on
          ? '模型可以在 ${_distro?.distro.displayName ?? '沙箱'} 里执行命令'
          : _distro == null
              ? '开启后会先装一个 Linux 基座（约 3–30MB）'
              : '普通聊天，模型没有任何工具',
      active: on,
      enabled: !_busy && !_installingDistro,
      onTap: () => _setTerminalMode(!on),
    );
  }

  Widget _buildApprovalButton() {
    const labels = {
      ApprovalMode.readOnly: '只读',
      ApprovalMode.onRequest: '按需审批',
      ApprovalMode.auto: '自动执行',
      ApprovalMode.yolo: '关闭沙箱',
    };
    final danger = _agent.mode == ApprovalMode.yolo;
    return PopupMenuButton<ApprovalMode>(
      initialValue: _agent.mode,
      tooltip: '审批档位：${labels[_agent.mode]}',
      // 写回设置而不是只改 _agent —— 这个按钮和设置页里的「审批档位」
      // 是同一件事，两份状态迟早会不一致。写回之后 _onSettingsChanged
      // 会把它同步到 _agent 上。
      onSelected: (m) => widget.settings.setApprovalMode(m),
      itemBuilder: (_) => [
        for (final entry in labels.entries)
          PopupMenuItem(value: entry.key, child: Text(entry.value)),
      ],
      // 关掉沙箱是唯一需要抢眼的档位，用红色而不是品牌色 ——
      // 品牌色在输入框这一排已经表示「开着」了。
      child: ComposerIconButton(
        icon: danger ? Icons.gpp_maybe : Icons.shield_outlined,
        active: !danger && _agent.mode != ApprovalMode.onRequest,
        color: danger ? context.chat.tintError : null,
      ),
    );
  }
}

/// 消息列表里的一行。
///
/// 三种：日期分隔（[day] 非空）、一条消息（[index] >= 0）、
/// 流式输出那条（[streaming] 非空）。
class _ChatRow {
  final DateTime? day;
  final int index;
  final String? streaming;
  final bool lastInGroup;

  const _ChatRow.date(this.day)
      : index = -1,
        streaming = null,
        lastInGroup = true;

  const _ChatRow.message(this.index, this.lastInGroup)
      : day = null,
        streaming = null;

  const _ChatRow.streaming(this.streaming)
      : day = null,
        index = -1,
        lastInGroup = true;
}

/// 检查点时间线。回滚入口。
class _CheckpointTimeline extends StatefulWidget {
  final SnapshotStore snapshots;
  final PrefixGenerations prefixGens;
  final void Function(String message) onRolledBack;

  const _CheckpointTimeline({
    required this.snapshots,
    required this.prefixGens,
    required this.onRolledBack,
  });

  @override
  State<_CheckpointTimeline> createState() => _CheckpointTimelineState();
}

class _CheckpointTimelineState extends State<_CheckpointTimeline> {
  Future<void> _rollback(int generation) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('回滚'),
        content: Text('回滚到检查点 #$generation。'
            '此后的所有文件改动都会被撤销。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('回滚')),
        ],
      ),
    );
    if (ok != true) return;

    final report = await widget.snapshots.rollbackTo(generation);
    await widget.snapshots.gc();
    widget.onRolledBack(report.toString());
    if (mounted) setState(() {});

    // 部分成功必须让用户看见，不能只在状态条闪一下。
    if (!report.isClean && mounted) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('回滚未完全成功'),
          content: Text('以下文件的旧内容没有保存，无法恢复：\n\n'
              '${report.unrecoverable.join('\n')}'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('知道了')),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final checkpoints = widget.snapshots.checkpoints.reversed.toList();
    final envGens = widget.prefixGens.generations.reversed.toList();

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text('工作区检查点  (HEAD = #${widget.snapshots.head})',
            style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        if (checkpoints.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text('还没有检查点。Agent 每次动手前会自动创建。',
                style: TextStyle(fontSize: 12)),
          ),
        for (final cp in checkpoints)
          Card(
            child: ListTile(
              dense: true,
              leading: CircleAvatar(
                  radius: 14,
                  child: Text('${cp.generation}',
                      style: const TextStyle(fontSize: 11))),
              title:
                  Text(cp.reason, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text('${cp.changes.length} 处变更 · '
                  '${_time(cp.createdAt)}'),
              trailing: IconButton(
                icon: const Icon(Icons.restore),
                tooltip: '回滚到这里',
                onPressed: () => _rollback(cp.generation),
              ),
            ),
          ),
        const SizedBox(height: 24),
        Text('环境代  (rootfs)', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        if (envGens.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text('还没有装过包。', style: TextStyle(fontSize: 12)),
          ),
        for (final g in envGens)
          Card(
            child: ListTile(
              dense: true,
              leading: const Icon(Icons.inventory_2_outlined),
              title:
                  Text(g.reason, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text('${_time(g.createdAt)} · '
                  '独占 ${(g.uniqueBytes / 1024 / 1024).toStringAsFixed(1)}MB'),
              trailing: IconButton(
                icon: const Icon(Icons.restore),
                tooltip: '回退环境到这一代之前',
                onPressed: () async {
                  await widget.prefixGens.rollbackTo(g.id);
                  widget.onRolledBack('环境已回退到第 ${g.id} 代之前');
                  if (mounted) setState(() {});
                },
              ),
            ),
          ),
      ],
    );
  }

  static String _time(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return '刚刚';
    if (d.inMinutes < 60) return '${d.inMinutes} 分钟前';
    if (d.inHours < 24) return '${d.inHours} 小时前';
    return '${d.inDays} 天前';
  }
}
