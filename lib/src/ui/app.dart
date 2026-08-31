/// UI 层。三个页签：对话、终端、检查点。
///
/// 设计取向：**把沙箱状态和回滚入口做成一等公民**，而不是藏在设置里。
/// 用户随时该能看到「我现在被保护到什么程度」和「出事了退到哪」——
/// 这两件事是这个 app 相对普通 LLM 客户端的全部价值所在。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
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
import '../settings/settings_store.dart';
import 'settings_page.dart';
import 'thread_list_page.dart';

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
  final Future<void> Function() onSkip;

  const DistroSetupScreen({
    super.key,
    required this.manager,
    required this.abi,
    required this.onReady,
    required this.onSkip,
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

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: _installing != null
              ? _buildInstalling()
              : _buildPicker(available),
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
          TextButton(
            onPressed: () => widget.onSkip(),
            child: const Text('暂不安装，先用 Android 自带的 shell'),
          ),
        ],
      );
}

// ---------------------------------------------------------------------------
// 主应用
// ---------------------------------------------------------------------------

class BurrowApp extends StatelessWidget {
  final AgentLoop Function(AgentHost host, TaskRuntime runtime) buildAgent;
  final Future<TaskRuntime> Function(String taskId) buildRuntime;
  final SandboxCapabilities capabilities;
  final PrefixGenerations prefixGens;
  final PtyChannel spawner;
  final InstalledDistro? activeDistro;
  final ConfigurableLlmClient llm;
  final SettingsStore settings;
  final ChatStore chats;

  const BurrowApp({
    super.key,
    required this.buildAgent,
    required this.buildRuntime,
    required this.capabilities,
    required this.prefixGens,
    required this.spawner,
    required this.activeDistro,
    required this.llm,
    required this.settings,
    required this.chats,
  });

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Burrow',
        locale: _appLocale,
        supportedLocales: _supportedLocales,
        localizationsDelegates: _localizationsDelegates,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF5065A8),
            brightness: Brightness.light,
          ),
          useMaterial3: true,
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF9CABFF),
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        home: ThreadListPage(
          store: chats,
          buildThread: (threadId, title) {
            final runtimeId = threadId ??
                'draft_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
            return HomeShell(
              buildAgent: buildAgent,
              runtime: buildRuntime(runtimeId),
              runtimeId: runtimeId,
              capabilities: capabilities,
              prefixGens: prefixGens,
              spawner: spawner,
              activeDistro: activeDistro,
              llm: llm,
              settings: settings,
              chats: chats,
              threadId: threadId,
              title: title,
            );
          },
        ),
      );
}

class HomeShell extends StatefulWidget {
  final AgentLoop Function(AgentHost host, TaskRuntime runtime) buildAgent;
  final Future<TaskRuntime> runtime;
  final String runtimeId;
  final SandboxCapabilities capabilities;
  final PrefixGenerations prefixGens;
  final PtyChannel spawner;
  final InstalledDistro? activeDistro;
  final ConfigurableLlmClient llm;
  final SettingsStore settings;
  final ChatStore chats;
  final String? threadId;
  final String title;

  const HomeShell({
    super.key,
    required this.buildAgent,
    required this.runtime,
    required this.runtimeId,
    required this.capabilities,
    required this.prefixGens,
    required this.spawner,
    required this.activeDistro,
    required this.llm,
    required this.settings,
    required this.chats,
    required this.threadId,
    required this.title,
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
  bool _busy = false;
  bool _loadingHistory = true;
  bool _cancelRequested = false;
  bool _runtimeReady = false;
  String? _threadId;

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
    _prepareRuntime();
  }

  Future<void> _prepareRuntime() async {
    _runtime = await widget.runtime;
    _agent = widget.buildAgent(this, _runtime);
    await _loadHistory();
    await _startShell();
    if (mounted) setState(() => _runtimeReady = true);
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
      widget.activeDistro != null ? 'exec /bin/sh -l' : 'exec sh',
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
      handle.output.listen(
        (chunk) => _terminal.write(String.fromCharCodes(chunk)),
        onDone: () => _terminal.write('\r\n[会话已结束]\r\n'),
      );
      handle.exitCode
          .then((code) => _terminal.write('\r\n[shell 退出，code=$code]\r\n'));
    } catch (e) {
      _terminal.write('无法启动 shell：$e\r\n');
    }
  }

  @override
  void dispose() {
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
  void onStatus(String message) => setState(() => _status = message);

  // ---- 交互 ----

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _busy || _loadingHistory) return;
    var id = _threadId;
    if (id == null) {
      id = await widget.chats.createThread(
        text,
        preferredId: widget.runtimeId,
      );
      _threadId = id;
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
          content: '出错：$e',
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
              at: DateTime.now()));
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
    setState(() => _status = '正在停止当前请求和命令…');
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
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(widget.title, overflow: TextOverflow.ellipsis),
            Text(_runtime.sandbox.workspacePath,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11)),
          ],
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(28),
          child: _SandboxBar(
            caps: widget.capabilities,
            mode: _agent.mode,
            level: _agent.sandboxLevel,
            status: _status,
          ),
        ),
        actions: [
          IconButton(
            tooltip: '打开终端',
            onPressed: () => setState(() => _tab = 1),
            icon: const Icon(Icons.terminal_outlined),
          ),
          IconButton(
            tooltip: '设置',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SettingsPage(
                  store: widget.settings,
                  client: widget.llm,
                ),
              ),
            ),
            icon: const Icon(Icons.settings_outlined),
          ),
          PopupMenuButton<ApprovalMode>(
            icon: const Icon(Icons.shield_outlined),
            initialValue: _agent.mode,
            onSelected: (m) => setState(() => _agent.mode = m),
            itemBuilder: (_) => const [
              PopupMenuItem(value: ApprovalMode.readOnly, child: Text('只读')),
              PopupMenuItem(value: ApprovalMode.onRequest, child: Text('按需审批')),
              PopupMenuItem(value: ApprovalMode.auto, child: Text('自动执行')),
              PopupMenuItem(value: ApprovalMode.yolo, child: Text('关闭沙箱')),
            ],
          ),
        ],
      ),
      body: IndexedStack(
        index: _tab,
        children: [
          _buildChat(),
          Column(children: [
            if (widget.activeDistro == null)
              Container(
                width: double.infinity,
                color: Colors.orange.shade900,
                padding: const EdgeInsets.all(8),
                child: const Text(
                  '降级模式：未安装发行版基座，当前是 Android 自带的 '
                  '/system/bin/sh。没有包管理器，也没有 proot 路径隔离。',
                  style: TextStyle(fontSize: 11),
                ),
              ),
            Expanded(child: TerminalView(_terminal)),
          ]),
          _CheckpointTimeline(
            snapshots: _runtime.snapshots,
            prefixGens: widget.prefixGens,
            onRolledBack: (msg) => setState(() => _status = msg),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.chat_outlined), label: '对话'),
          NavigationDestination(
              icon: Icon(Icons.terminal_outlined), label: '终端'),
          NavigationDestination(
              icon: Icon(Icons.history_outlined), label: '检查点'),
        ],
      ),
    );
  }

  Widget _buildChat() => Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
              itemCount: _visible.length + (_streaming.isEmpty ? 0 : 1),
              itemBuilder: (_, i) {
                if (i == _visible.length) {
                  return _Bubble(
                      role: 'assistant', text: _streaming.toString());
                }
                return _Bubble(
                  role: _visible[i].role,
                  text: _visible[i].content,
                  onRetry: i == _visible.length - 1 &&
                          _visible[i].role == 'assistant' &&
                          !_busy
                      ? _retry
                      : null,
                );
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Container(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                border: Border(
                  top: BorderSide(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      enabled: !_busy,
                      minLines: 1,
                      maxLines: 5,
                      decoration: InputDecoration(
                        hintText: '描述你希望 Agent 完成的任务',
                        filled: true,
                        fillColor: Theme.of(context)
                            .colorScheme
                            .surfaceContainerLow,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _busy ? _stop : _send,
                    icon: _busy
                        ? const Icon(Icons.stop_rounded)
                        : const Icon(Icons.arrow_upward),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
}

/// 常驻的沙箱状态条。
///
/// 这条不能折叠也不能隐藏：`yolo` 模式下用户必须一眼看到自己关了沙箱。
class _SandboxBar extends StatelessWidget {
  final SandboxCapabilities caps;
  final ApprovalMode mode;
  final SandboxLevel level;
  final String? status;

  const _SandboxBar({
    required this.caps,
    required this.mode,
    required this.level,
    this.status,
  });

  @override
  Widget build(BuildContext context) {
    final danger = mode == ApprovalMode.yolo;
    return Container(
      width: double.infinity,
      color: danger
          ? Colors.red.shade900
          : Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Text(
        status ?? (danger ? '⚠ 沙箱已关闭，命令直接在环境里执行' : caps.describe()),
        style: const TextStyle(fontSize: 11),
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final String role;
  final String text;
  final VoidCallback? onRetry;
  const _Bubble({required this.role, required this.text, this.onRetry});

  @override
  Widget build(BuildContext context) {
    final isUser = role == 'user';
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        constraints:
            BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.85),
        decoration: BoxDecoration(
          color:
              isUser ? scheme.primaryContainer : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(isUser ? Icons.person_outline : Icons.auto_awesome,
                    size: 18),
                const SizedBox(width: 8),
                Text(isUser ? '你' : 'Burrow',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(width: 8),
                Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    color: Color(0xFF66BB6A),
                    shape: BoxShape.circle,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            MarkdownBody(
              data: text,
              selectable: true,
              styleSheet: role == 'tool'
                  ? MarkdownStyleSheet(
                      p: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                    )
                  : null,
            ),
            if (!isUser && text.isNotEmpty) ...<Widget>[
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: '复制',
                    onPressed: () =>
                        Clipboard.setData(ClipboardData(text: text)),
                    icon: const Icon(Icons.copy_outlined, size: 17),
                  ),
                  if (onRetry != null)
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: '重新生成',
                      onPressed: onRetry,
                      icon: const Icon(Icons.refresh, size: 18),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
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
