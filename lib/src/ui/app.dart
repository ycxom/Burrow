/// UI 层。三个页签：对话、终端、检查点。
///
/// 设计取向：**把沙箱状态和回滚入口做成一等公民**，而不是藏在设置里。
/// 用户随时该能看到「我现在被保护到什么程度」和「出事了退到哪」——
/// 这两件事是这个 app 相对普通 LLM 客户端的全部价值所在。
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:xterm/xterm.dart';

import '../agent/agent_loop.dart';
import '../agent/tools.dart';
import '../bootstrap/distro.dart';
import '../context/overflow_manager.dart';
import '../context/token_counter.dart';
import '../data/chat_store.dart';
import '../data/task_runtime.dart';
import '../sandbox/exec_policy.dart';
import '../sandbox/interactive_shell.dart';
import '../sandbox/prefix_generations.dart';
import '../sandbox/pty_channel.dart';
import '../sandbox/sandbox_session.dart';
import '../sandbox/snapshot_store.dart';
import '../llm/llm_client.dart';
import '../llm/thinking_effort.dart';
import '../llm/vision.dart';
import '../settings/settings_store.dart';
import '../settings/thread_lock.dart';
import '../settings/thread_prefs.dart';
import 'sampling_page.dart';
import '../settings/account_store.dart';
import '../settings/channel_store.dart';
import '../skills/skill_store.dart';
import 'channels_page.dart';
import 'chat_drawer.dart';
import 'chat_appearance_page.dart';
import 'chat_skin.dart';
import 'skin_affordance.dart';
import 'skin_parts.dart';
import 'skin_store.dart';
import 'skin_style.dart';
import 'chat_theme.dart';
import 'branch_plan.dart';
import 'message_index.dart';
import 'interactive_terminal.dart';
import 'chat_view.dart';
import 'image_attachments.dart';
import 'anchored_menu.dart';
import 'model_bar.dart';
import 'model_sources.dart';
import 'settings_page.dart';
import 'system_prompt_page.dart';
import 'skills_page.dart';
import 'tool_card.dart';

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
          Icon(Icons.downloading_rounded, size: 48, color: context.chat.brand),
          const SizedBox(height: 24),
          Text('正在安装 ${_installing!.displayName}',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          if (_sourceFor(_installing!) case final source?)
            Text('下载源：${_sourceLabel(source)}',
                style:
                    TextStyle(fontSize: 12, color: context.chat.tintSecondary)),
          const SizedBox(height: 40),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(_progress.stage,
                        style: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w500)),
                    if (_progress.fraction >= 0)
                      Text('${(_progress.fraction * 100).toInt()}%',
                          style: TextStyle(
                              fontSize: 12, color: context.chat.brand)),
                  ],
                ),
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: _progress.fraction < 0 ? null : _progress.fraction,
                    minHeight: 8,
                    backgroundColor: context.chat.bgTertiary,
                    valueColor:
                        AlwaysStoppedAnimation<Color>(context.chat.brand),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 40),
          const Text('首次安装需要联网下载 rootfs，之后不再需要。',
              style: TextStyle(fontSize: 11)),
        ],
      );

  Widget _buildPicker(List<Distro> available) => ListView(
        physics: const BouncingScrollPhysics(),
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
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(
                  color: Theme.of(context).dividerColor.withValues(alpha: 0.1),
                ),
              ),
              child: Column(children: [
                ListTile(
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
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

  /// 会话锁：这次运行里哪些私密会话已经开过。见 thread_lock.dart。
  final ThreadUnlockSession unlocked;

  /// 已安装的外部皮肤包。和 settings 一起被监听 —— 装完一个皮肤要立刻
  /// 出现在列表里，而它不属于 SettingsStore。
  final ChatSkinStore skins;

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
    required this.unlocked,
    required this.skins,
  });

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: Listenable.merge(<Listenable>[settings, skins]),
        builder: (context, _) {
          // 逃生舱：停用中就整套回内置外观，连解析都不做 —— 一个能让
          // 界面不可用的皮肤，不该在"已经停用它"之后还有机会参与渲染。
          final skin = settings.chatSkinSuspended
              ? ChatSkinCatalog.fallback
              : ChatSkinCatalog.resolve(
                  settings.chatSkinId,
                  installed: skins.packs,
                );
          return MaterialApp(
            title: 'Burrow',
            locale: _appLocale,
            supportedLocales: _supportedLocales,
            localizationsDelegates: _localizationsDelegates,
            theme: buildSkinTheme(Brightness.light, skin),
            darkTheme: buildSkinTheme(Brightness.dark, skin),
            themeMode: switch (settings.chatColorStyle) {
              ChatColorStyle.nekogramNight => ThemeMode.dark,
              ChatColorStyle.followSystem => ThemeMode.system,
              ChatColorStyle.light => ThemeMode.light,
            },
            home: ChatShell(
              skins: skins,
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
              unlocked: unlocked,
            ),
          );
        },
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
  final ThreadUnlockSession unlocked;

  /// 只往下传，见 BurrowApp.skins。
  final ChatSkinStore skins;

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
    required this.unlocked,
    required this.skins,
  });

  @override
  State<ChatShell> createState() => _ChatShellState();
}

class _ChatShellState extends State<ChatShell> {
  String? _threadId;
  String _title = '新对话';
  int? _searchTargetMessageId;

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

  Future<void> _openSearchHit(String threadId, int messageId) async {
    if (threadId != _threadId) await _select(threadId);
    if (!mounted) return;
    setState(() => _searchTargetMessageId = messageId);
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
      unlocked: widget.unlocked,
      skins: widget.skins,
      threadId: _threadId,
      title: _title,
      onSelectThread: _select,
      onTitleChanged: (title) => setState(() => _title = title),
      onOpenSearchHit: _openSearchHit,
      searchTargetMessageId: _searchTargetMessageId,
      onSearchTargetConsumed: () {
        if (mounted) setState(() => _searchTargetMessageId = null);
      },
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
  final ThreadUnlockSession unlocked;

  /// 只往下传，见 BurrowApp.skins。
  final ChatSkinStore skins;
  final String? threadId;
  final String title;

  /// 抽屉里选了别的会话。
  final ValueChanged<String?> onSelectThread;

  /// 第一条消息落库之后，把标题回传给外壳。
  final ValueChanged<String> onTitleChanged;

  /// 抽屉消息搜索结果要求换会话并定位。
  final Future<void> Function(String threadId, int messageId) onOpenSearchHit;

  /// 抽屉里的搜索结果要打开的那条消息；null = 没有待定位目标。
  final int? searchTargetMessageId;
  final VoidCallback onSearchTargetConsumed;

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
    required this.unlocked,
    required this.skins,
    required this.threadId,
    required this.title,
    required this.onSelectThread,
    required this.onTitleChanged,
    required this.onOpenSearchHit,
    required this.searchTargetMessageId,
    required this.onSearchTargetConsumed,
  });

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin
    implements AgentHost {
  late final AgentLoop _agent;
  late final TaskRuntime _runtime;
  late final Terminal _terminal;

  final List<ChatMessage> _visible = [];
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _messageKeys = <int, GlobalKey>{};
  int? _highlightMessageId;
  Timer? _highlightTimer;

  /// 抽屉入口是我们自己 compose 的（见 _buildDrawerButton），所以要一个 key
  /// 才能从 AppBar 里够到 Scaffold。
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  /// 两个浮层菜单的锚点。菜单从按钮所在的那个角展开，所以得知道按钮
  /// 在屏幕上的位置（见 anchored_menu.dart）。
  final _plusKey = GlobalKey();
  final _terminalKey = GlobalKey();

  /// 页签之间的**淡出淡入**（Material 3 的 fade through）。
  ///
  /// 三个页签都常驻在 IndexedStack 里（那是滚动位置不丢的前提），所以做不了
  /// 两个页面同时在场的交叉淡化 —— 那种需要把旧的留在树上。这里用的是它的
  /// 单轨版本：**先把当前这个淡出去、换完再淡回来**，中间那一瞬间屏幕上
  /// 只有一样东西。M3 管这个叫 fade through，正是给"两个页面之间没有空间
  /// 关系"的切换用的 —— 对话和终端确实没有上下左右可言。
  ///
  /// 顺带一点点放大：只有透明度变化的话，短促的切换在眼睛里会读成"闪了一下"
  /// 而不是"换了一个"。
  late final AnimationController _tabFade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 210),
    value: 1,
  );

  Future<void> _switchTab(int tab) async {
    if (tab == _tab) return;
    HapticFeedback.selectionClick();
    // 淡出用的时间比淡回来短：离开是"已经决定了"，慢慢淡出只会让人等；
    // 而新页面淡进来那一下才是要看清的。
    await _tabFade.animateTo(0,
        duration: const Duration(milliseconds: 90), curve: Curves.easeOutCubic);
    if (!mounted) return;
    setState(() => _tab = tab);
    unawaited(_tabFade.animateTo(1,
        duration: const Duration(milliseconds: 210),
        curve: Curves.easeOutCubic));
  }

  /// 列表是否已经滚离顶部。皮肤的 `header:scrolled` 状态靠它。
  /// 只在**跨过阈值**时 setState，不是每帧 —— 顶栏样式没有中间态。
  bool _scrolledAway = false;

  /// 用户的手指正压在列表上，或者刚甩出去还在惯性里。
  ///
  /// 生成过程中每 33ms 要跟一次底部，而 `animateTo` 和 `jumpTo` **都会掐掉
  /// 用户当前的滚动**（两者都要 `beginActivity`，那会终止正在进行的 drag）。
  /// 所以只要用户在动它，自动跟随就得整个让开。
  ///
  /// 光靠 [_scrolledAway] 那个 120 像素的阈值不够：跟随每 33ms 把人拽回底部
  /// 一次，手指根本攒不够 120 像素的位移，阈值永远翻不过去 —— 表现就是
  /// 「AI 在输出时界面划不动」。划了，33 毫秒后被打断，再划再被打断。
  bool _userScrolling = false;

  /// 已经选好、还没发出去的图。存的是**拷进会话目录之后**的路径 ——
  /// 相册给的那个路径在系统缓存里，随时会被清掉。
  final List<String> _attachments = <String>[];
  late final ImageAttachmentStore _images;

  int _tab = 0;
  String? _status;
  Timer? _statusTimer;
  bool _busy = false;
  bool _loadingHistory = true;
  bool _cancelRequested = false;
  bool _runtimeReady = false;
  bool _installingDistro = false;
  String? _threadId;

  /// 这个会话自己的系统提示词。null = 没设过，用全局那份。
  String? _threadPrompt;

  /// 这个会话自己的模型策略。见 settings/thread_prefs.dart。
  ///
  /// 和 [_threadPrompt] 一条路子：会话还没落库时先存在内存里，
  /// 第一条消息落库时一起写进去。
  ThreadPrefs _prefs = const ThreadPrefs();

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

  /// 这一轮的思考过程。和 [_streaming] 一样是攒着的 —— 它同样按 token 到达，
  /// 而且推理模型的思考往往比答案还长。
  final _reasoning = StringBuffer();

  /// 第一段思考到达的时刻。界面靠它走秒；这一轮结束时换成
  /// [AgentLoop] 那份量出来的定值。
  DateTime? _thinkStartedAt;

  /// 正在跑的那个工具：标题 + 起跑时刻。null = 现在没有命令在跑。
  ///
  /// 它撑起的是**跑命令那段时间里屏幕上唯一在动的东西**。在此之前，
  /// 模型说完一句话去跑一条 ssh，那十几秒里界面完全静止 —— 输入框还灰着，
  /// 但没有任何东西说明它在等什么，看起来就是卡死了。
  ({String title, DateTime startedAt})? _runningTool;

  /// branchId → 这个分支点有几个版本、正在看第几个。
  ///
  /// 缓存而不是画的时候现查：`build` 里不能等异步结果，而每条消息都去查一次
  /// 数据库，滚动时会变成几十次查询。
  final Map<String, BranchState> _branches = <String, BranchState>{};

  /// 「编辑重发」按下之后、真正发出去之前的挂账。
  ///
  /// 编辑那一刻只是把旧的一段收进版本库并清空正文，新版本要等用户真的按下
  /// 发送才存在。记着这笔账，发送时才知道这条新消息属于哪个分支点。
  ({String branchId, int anchorIndex})? _pendingBranch;

  /// 用户手动敲命令的那个 shell。**和 Agent 用的是两个不同的会话** ——
  /// 共用一个的话，Agent 的 cd 会污染用户的会话，用户的 export 会污染
  /// Agent 的可复现性（见 ARCHITECTURE.md §3）。
  PtyHandle? _shell;

  /// 终端选区。要自己拿一份而不是让 TerminalView 内部默认造一份——
  /// 默认那份是它自己私有的，外面拿不到 selection，也就没法实现复制。
  final _terminalController = TerminalController();

  @override
  void initState() {
    super.initState();
    _terminal = Terminal(maxLines: 5000);
    _threadId = widget.threadId;
    // 设置页改了排版或模型名要立刻反映到这里。不订阅的话，从设置返回后
    // 界面还是旧的，用户会以为那个开关坏了 —— 而它其实已经存下去了，
    // 只是要杀进程重开才看得到，这是最难自证的一类"没生效"。
    widget.settings.addListener(_onSettingsChanged);
    _scroll.addListener(_onScroll);
    // 切到别的 app 时把"读到哪儿"落盘。等 dispose 太晚 —— 被系统回收的
    // 进程根本走不到那里，而"切出去一趟回来位置就没了"正是要修的事。
    WidgetsBinding.instance.addObserver(this);
    _prepareRuntime();
  }

  @override
  void didUpdateWidget(covariant HomeShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    final target = widget.searchTargetMessageId;
    if (target != null && target != oldWidget.searchTargetMessageId) {
      _revealMessage(target);
    }
  }

  String? _displayMessageSource(String? source) {
    if (source == null || source.isEmpty) return source;
    final separator = source.indexOf(' · ');
    final prefix = separator < 0 ? source : source.substring(0, separator);
    if (Uri.tryParse(prefix)?.hasScheme != true) return source;
    final provider = Channel.providerLabelForBaseUrl(prefix);
    final suffix = separator < 0 ? '' : source.substring(separator);
    return '$provider$suffix';
  }

  void _onSettingsChanged() {
    if (!mounted) return;
    // 设置页改完要**当场**对正在进行的会话生效，而不是等下次新建会话。
    // `_agent` 是 late final，runtime 没准备好时读它会抛，所以要守一下。
    if (_runtimeReady) {
      _agent.sandboxLevel = widget.settings.sandboxLevel;
      _agent.mode = widget.settings.approvalMode;
      // 配置、署名、能不能看图、支不支持工具 —— 全部按**这个会话自己的**
      // 渠道和模型算，而不是全局那份。见 [_applyConfig]。
      _applyConfig();
      // 换到一个不支持工具的模型时，把已经开着的终端模式关掉。
      //
      // 不关的话下一次发送就会带着 tools 打过去，然后收到一个只说"参数错误"
      // 的 400 —— 而真正的原因（刚才换了个模型）在两步操作之前，没人会
      // 联想到那里。
      if (_agent.terminalMode && !_agent.supportsTools) {
        _agent.terminalMode = false;
        _setStatus('已退出终端模式：'
            '「${_effectiveModel.isEmpty ? '当前模型' : _effectiveModel}」'
            '不支持工具调用');
      }
      // 改了全局提示词、而这个会话没有自己那份时，要当场跟上。
      _agent.userSystemPrompt = _effectiveSystemPrompt;
      _agent.overflow
        ..trigger = widget.settings.overflowTrigger
        ..messageThreshold = widget.settings.messageThreshold
        ..tokenThreshold = widget.settings.tokenThreshold;
    }
    setState(() {});
  }

  /// 这一刻实际生效的系统提示词。会话级优先 —— 全局是"我一般想要的样子"，
  /// 会话级是"这一次不一样"，后者不该被前者盖住。
  String get _effectiveSystemPrompt =>
      _threadPrompt ?? widget.settings.systemPrompt;

  /// 当前全局设置摊成一份会话策略。新会话的起点。
  ThreadPrefs _globalPrefs() => ThreadPrefs(
        channelId: widget.channels.activeId,
        model: widget.channels.active?.model,
        thinkingEffort: widget.settings.thinkingEffort,
        temperature: widget.settings.temperature,
      );

  /// 把这一刻真正在用的那套定死成这个会话自己的。
  ///
  /// 会话建出来的那一刻调一次。不定死的话，用户之后改一次全局设置，
  /// 所有老会话会跟着变 —— 而"每个聊天室各走各的"正是要躲开这件事。
  ThreadPrefs _pinPrefs() {
    final resolved = _effectiveChannel;
    return ThreadPrefs(
      channelId: _prefs.channelId ?? resolved?.id,
      model: _prefs.model ?? resolved?.model,
      thinkingEffort: _prefs.thinkingEffort ?? widget.settings.thinkingEffort,
      temperature: _prefs.temperature ?? widget.settings.temperature,
    );
  }

  /// 这个会话发往哪个渠道。会话指定的优先，指的那个没了就退回当前渠道。
  ///
  /// 退回而不是报错：渠道是会被删的，而一个指向已删渠道的会话不该变成
  /// 打不开的死会话 —— 它只是回到"跟着当前渠道"，和没设过一样。
  Channel? get _effectiveChannel {
    final id = _prefs.channelId;
    return (id == null ? null : widget.channels.byId(id)) ??
        widget.channels.active;
  }

  String get _effectiveModel {
    final channel = _effectiveChannel;
    final model = _prefs.model?.trim() ?? '';
    return model.isNotEmpty ? model : (channel?.model ?? '');
  }

  ThinkingEffort get _effectiveThinking =>
      _prefs.thinkingEffort ?? widget.settings.thinkingEffort;

  double get _effectiveTemperature =>
      _prefs.temperature ?? widget.settings.temperature;

  ResolvedCapability get _effectiveCapability =>
      widget.channels.capabilityOf(_effectiveChannel, _effectiveModel);

  /// 能不能把图直接塞进请求体里。
  ///
  /// 「自动」这一档要问的是**这个会话用的那个模型**认不认图，不是全局那个。
  bool get _effectiveSendImagesInline => switch (widget.settings.imageMode) {
        ImageMode.native => true,
        ImageMode.preprocess => false,
        ImageMode.auto => _effectiveCapability.vision,
      };

  /// 助手消息署的名，也是底栏那行字。
  String get _effectiveSourceLabel {
    final channel = _effectiveChannel;
    if (channel == null) return '';
    final model = _effectiveModel;
    return model.isEmpty
        ? channel.providerLabel
        : '${channel.providerLabel} · $model';
  }

  /// 这个会话这一刻真正要发出去的那套配置。
  ///
  /// 以前这里没有"这个会话"的概念：main 里挂了一条
  /// `settings.addListener(() => llm.config = settings.config)`，全局设置一变
  /// 就把**所有**会话的配置改掉。那条监听已经去掉了，改成由当前打开的这个
  /// 会话自己往 client 上写 —— 同一时刻只有一个 HomeShell 活着，
  /// 所以"当前生效的配置"和"当前打开的会话"天然是一一对应的。
  LlmConfig get _effectiveConfig {
    final channel = _effectiveChannel;
    if (channel == null) return LlmConfig.empty;
    final capability = widget.channels.capabilityOf(channel, _effectiveModel);
    return widget.channels
        .configFor(
          channel,
          temperature: _effectiveTemperature,
          streamOutput: widget.settings.streamOutput,
          sendImagesInline: switch (widget.settings.imageMode) {
            ImageMode.native => true,
            ImageMode.preprocess => false,
            ImageMode.auto => capability.vision,
          },
          thinkingEffort: _effectiveThinking,
        )
        .copyWith(model: _effectiveModel, sampling: _prefs.sampling);
  }

  /// 把这个会话的配置推给 client，并且把跟着模型走的那几个开关同步给 agent。
  ///
  /// 这几样以前全读全局（`settings.sourceLabel` / `sendImagesInline` /
  /// `supportsTools`）。会话有了自己的渠道之后那就错了：请求发往 A，
  /// 而"能不能看图""支不支持工具"却在问 B。
  void _applyConfig() {
    if (!_runtimeReady) return;
    widget.llm.config = _effectiveConfig;
    _agent.sourceLabel = _effectiveSourceLabel;
    _agent.sendImagesInline = _effectiveSendImagesInline;
    _agent.supportsTools = _effectiveCapability.tools;
  }

  /// 改这个会话的策略：内存里先生效，落库看会话建了没有。
  Future<void> _updatePrefs(ThreadPrefs next) async {
    if (next == _prefs) return;
    setState(() => _prefs = next);
    _applyConfig();
    final id = _threadId;
    if (id != null) await widget.chats.setPrefs(id, next);
  }

  Future<void> _prepareRuntime() async {
    final threadId = widget.threadId;
    if (threadId != null) {
      _threadPrompt = await widget.chats.systemPromptOf(threadId);
      _prefs = await widget.chats.prefsOf(threadId);
    } else {
      // 新会话从当前的全局设置起步。**只是起步** —— 第一条消息落库时会把
      // 这一刻的值定死（见 _pinPrefs），之后改全局不再影响它。
      _prefs = _globalPrefs();
    }
    _runtime = await widget.runtime;
    _images = ImageAttachmentStore(Directory('${_runtime.root.path}/images'));
    _agent = widget.buildAgent(this, _runtime);
    _agent.userSystemPrompt = _effectiveSystemPrompt;
    await _restoreTerminalMode();
    await _loadHistory();
    if (!mounted) return;
    // **不等 shell。** 起一个 shell 要 fork 一个 proot 进程，那是这一串里最慢
    // 的一步，而它和"把对话画出来"没有任何关系 —— 只有终端页要用。等它等到
    // 的是一屏转圈，而用户点进来是要看对话的。
    setState(() => _runtimeReady = true);
    // 这个会话的配置要在第一次发送之前就推给 client。
    _applyConfig();
    unawaited(_startShell());
    // 位置要等 ListView 真的建出来才摆得了 —— 见 [_applyInitialScroll]。
    unawaited(_applyInitialScroll());
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

  /// 一页装多少。**条数和 token 取先到的那个。**
  ///
  /// 一开始只设了 token 预算（1M），结果是它对绝大多数会话等于"全读" ——
  /// 几千条中文消息才凑得够 1M，分页写了等于没写。日常真正决定一页多大的
  /// 是「一屏放得下几条」：手机上也就五六条，多读的每一条都是首屏之前的
  /// 纯等待。Telegram 系客户端首屏取 20 条，就是这个道理。
  ///
  /// token 预算留着管另一头：一条几十 KB 的命令输出，光它自己就该成一页，
  /// 按条数切会让那一页大得离谱。
  static const _pageMessages = 40;
  static const _pageTokens = 24000;

  /// 完整历史补完之前，这个 Future 没完成。
  ///
  /// **落盘必须等它。** `replaceMessages` 是"删掉这个会话的全部行再重插"，
  /// 拿一份只有尾巴的历史去执行，就是把用户前面的对话删了 —— 不可恢复。
  Future<void>? _backfill;

  /// 库里比 `_visible` 更早的消息还有多少条。0 = 已经翻到头了。
  int _olderInStore = 0;

  /// 正在往上补一页。防止一次滚动触发好几轮。
  bool _loadingOlder = false;

  Future<void> _loadHistory() async {
    final id = _threadId;
    if (id != null) {
      // 只读最后一段。一个聊了几个月的会话有几千条消息，全量读出来再造
      // 几千个对象、算一遍日期分组，是首屏前唯一那段纯等待 —— 而用户打开
      // 会话十有八九是接着最近这几句说。
      final messages = await widget.chats.tailMessages(
        id,
        tokenBudget: _pageTokens,
        messageLimit: _pageMessages,
      );
      final total = await widget.chats.messageCountOf(id);
      _olderInStore = total - messages.length;
      _agent.history.addAll(messages);

      // 剩下的在后台补进 history（**不进 `_visible`**）。
      //
      // history 必须是完整的：落盘要拿它整份重写，overflow 的 checkpoint 是
      // 它的下标，记忆检索的语料也是它。而界面那份是另一回事 —— 用户没往上
      // 翻，就不该为几千条看不见的消息付排版的钱。
      if (_olderInStore > 0) {
        _backfill = _fillOlderHistory(id, messages.first.messageId);
      }
      // 把上一次的滚动摘要接回来。不接的话 checkpoint 归 0，这个会话的
      // 整段历史会在下一次发送时原样发出去 —— 而摘要要等那一轮**结束之后**
      // 才会重新触发，也就是说最该被压缩的那一次请求恰恰没被压缩。
      final memory = await widget.chats.memoryOf(id);
      if (memory != null) {
        _agent.overflow.restore(
          summary: memory.summary,
          checkpoint: memory.checkpoint,
          historyLength: messages.length,
        );
      }
      // tool 消息也进来。以前这里把它们滤掉，代价是同一个回合的两段
      // 正文变成两个紧挨着的气泡、中间什么都没有 —— 看着像一条消息
      // 断成了两半。现在它们画成一张工具卡片，那个"断"就有了理由。
      _visible.addAll(messages);
    }
    if (mounted) setState(() => _loadingHistory = false);
    await _refreshBranches();

    // **这里只决定停在哪，不真的滚。**
    //
    // 这一刻 `_runtimeReady` 还是 false，界面上是一个转圈 —— ListView 压根
    // 不存在，滚动请求发给一个没有 client 的 controller，安静地什么都不做。
    // 「回到上次的位置」一直不生效就是因为这个；而它原本那句 `_scrollToEnd()`
    // 其实也从来没生效过，只是"停在底部"恰好和空列表的表现一样，没人发现。
    //
    // 真正的滚动在 [_applyInitialScroll]，等列表建出来之后。
    final target = widget.searchTargetMessageId;
    if (target != null) {
      _initialAnchor = target;
      _initialHighlight = true;
      return;
    }
    final anchor = id == null ? null : await widget.chats.lastReadOf(id);
    // 上次停在最后一条 = 其实就是在底部。按底部处理，省掉一次
    // 「贴着底边但差几像素」的定位。
    if (anchor != null &&
        _visible.isNotEmpty &&
        _visible.last.messageId != anchor) {
      _initialAnchor = anchor;
      _readingAnchor = anchor;
    }
  }

  /// 把首屏那一页之前的历史补进 `_agent.history`。
  ///
  /// 只补 history，不动 `_visible` —— 界面上要不要显示它们由用户往上翻决定。
  Future<void> _fillOlderHistory(String threadId, int? firstLoadedId) async {
    if (firstLoadedId == null) return;
    try {
      final older = await widget.chats.messages(threadId);
      if (!mounted) return;
      final head = <ChatMessage>[
        for (final m in older)
          if ((m.messageId ?? 0) < firstLoadedId) m,
      ];
      if (head.isEmpty) return;
      _agent.history.insertAll(0, head);
      // checkpoint 是 history 的下标，前面插了一段就得跟着往后挪，
      // 否则摘要覆盖范围会指到一段完全不相干的消息上。
      _agent.overflow.shiftBy(head.length);
    } catch (_) {
      // 补不上就当没有更早的。**但落盘那条路仍然被挡住** ——
      // 见 [_persistMessages]：宁可这次不存，也不能拿残缺的历史去重写。
      rethrow;
    }
  }

  /// 打开这个会话时停在哪一条。null = 停在底部。
  int? _initialAnchor;

  /// 那一条要不要闪一下高亮。只有搜索命中才要 —— 每次打开会话都闪一下
  /// 是在提醒一件用户并没有在找的事。
  bool _initialHighlight = false;

  /// 列表真的建出来之后，才把打开时的位置摆好。
  Future<void> _applyInitialScroll() async {
    // 等一帧：`_runtimeReady` 刚翻成 true，ListView 这一帧才第一次布局。
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final anchor = _initialAnchor;
    if (anchor == null) {
      await _settleToEnd();
      return;
    }
    // 摆在靠下的位置：那是"最后看见的那条"，它下面的才是没看的。
    await _scrollToMessage(anchor, alignment: 0.82);
    if (_initialHighlight) _flashMessage(anchor);
  }

  /// 回到最新那条。
  ///
  /// 倒序列表里"底"就是 offset 0 —— 一个**常量**，不用先把整个列表量一遍。
  /// 正着排的时候这里是个循环：跳到 maxScrollExtent、等它因为多建了几行又
  /// 变大、再跳，直到不动为止。
  Future<void> _settleToEnd() async {
    if (!mounted || !_scroll.hasClients) return;
    _scroll.jumpTo(0);
  }

  GlobalKey? _messageKey(int? messageId) {
    final id = messageId;
    if (id == null) return null;
    return _messageKeys.putIfAbsent(id, GlobalKey.new);
  }

  void _revealMessage(int messageId) {
    // 在不在 `_visible` 里由 [_ensureVisible] 去管 —— 目标可能还在没显示的
    // 那一段里，这里直接判"没有"会把搜索跳转变成一个哑动作。
    _flashMessage(messageId);
    unawaited(_scrollToMessage(messageId, alignment: 0.28));
    widget.onSearchTargetConsumed();
  }

  /// 让某条消息闪一下。**只有"这是你搜的那条"才该闪** ——
  /// 恢复阅读位置每次打开都闪一下，是在提醒一件用户并没有在找的事。
  void _flashMessage(int messageId) {
    _highlightTimer?.cancel();
    if (!mounted) return;
    setState(() => _highlightMessageId = messageId);
    _highlightTimer = Timer(const Duration(milliseconds: 2200), () {
      if (mounted) setState(() => _highlightMessageId = null);
    });
  }

  /// 把界面往上补，直到那条消息进来为止。
  ///
  /// 首屏只显示最后一页，而搜索命中和「回到上次的位置」都可能指向更早的
  /// 消息。不补的话它们会静静地什么都不做 —— 用户点了个搜索结果，界面纹丝
  /// 不动，看不出是"没找到"还是"点歪了"。
  Future<bool> _ensureVisible(int messageId) async {
    bool shown() => _visible.any((m) => m.messageId == messageId);
    if (shown()) return true;
    await _backfill;
    if (!mounted) return false;
    // 库里都没有就别白翻了。
    if (!_agent.history.any((m) => m.messageId == messageId)) return false;
    while (_olderInStore > 0 && !shown()) {
      final before = _visible.length;
      await _loadOlderPage();
      if (!mounted || _visible.length == before) break;
    }
    return shown();
  }

  /// 滚到某条消息。不闪高亮。
  ///
  /// **要跳好几轮。** `ListView.builder` 只建视口附近的行，特别长的对话里
  /// 目标压根还没被创建（拿不到 context 就没法精确定位）；而按行号比例估
  /// 位置又要用 `maxScrollExtent`，那个值在只建了首屏时本身就是估出来的，
  /// 跳过去之后还会长。一次跳到位只在短对话里成立 —— 而短对话根本不需要
  /// 这个功能。
  Future<void> _scrollToMessage(
    int messageId, {
    required double alignment,
  }) async {
    if (!await _ensureVisible(messageId)) return;
    final visibleIndex =
        _visible.indexWhere((message) => message.messageId == messageId);
    if (visibleIndex < 0) return;

    final rows = _buildRows(null);
    final rowIndex = rows.indexWhere((row) => row.index == visibleIndex);

    // [alignment] 按「从视口顶部往下数的比例」传进来，而倒序列表的
    // "leading" 边是**底边** —— ensureVisible 的 0 在这里指底部。
    // 在这一处翻过来，调用方就不用记住列表是倒着的。
    final viewportAlignment = 1 - alignment;

    bool reveal() {
      final keyContext = _messageKey(messageId)?.currentContext;
      if (keyContext == null) return false;
      Scrollable.ensureVisible(
        keyContext,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        alignment: viewportAlignment,
      );
      return true;
    }

    await WidgetsBinding.instance.endOfFrame;
    for (var attempt = 0; attempt < 8; attempt++) {
      if (!mounted || !_scroll.hasClients) return;
      if (reveal()) return;
      if (rowIndex < 0) return;

      // rows 是倒序的，所以行号越大离底边越远 —— 和滚动 offset 同向，
      // 按比例估位置这件事不用改。
      final maxExtent = _scroll.position.maxScrollExtent;
      final estimate =
          rows.length <= 1 ? 0.0 : maxExtent * rowIndex / (rows.length - 1);
      final target =
          (estimate - _scroll.position.viewportDimension * viewportAlignment)
              .clamp(0.0, maxExtent);
      // 跳不动了就收手：再跳一次也是同一个位置，而目标始终建不出来说明
      // 行号和实际布局对不上，接着试只是在空转。
      if (attempt > 0 && (target - _scroll.offset).abs() < 1) return;
      _scroll.jumpTo(target);
      await WidgetsBinding.instance.endOfFrame;
    }
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
    final shellCommand = await interactiveShellCommand(_distro?.rootfs);
    final argv = _runtime.sandbox.buildArgv(
      shellCommand,
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
      // 起 shell 现在不挡着界面了（见 _prepareRuntime），于是它很可能在
      // 用户已经切走之后才返回 —— 那时候 dispose 里的 `_shell?.killGroup()`
      // 早就跑过了，而 `_shell` 当时还是 null。不在这里补一刀的话，
      // 每切一次会话就漏一个 proot 进程。
      if (!mounted) {
        handle.killGroup();
        return;
      }
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

  // ---- 顶栏：骨架固定，皮肤只提供样式 ----

  PartStyle get _header {
    final parts = context.parts;
    return (_scrolledAway ? parts.header.on(SkinState.scrolled) : null) ??
        parts.header;
  }

  /// 顶栏的渐变、背景图和毛玻璃。放 flexibleSpace 而不是 backgroundColor：
  /// 后者只吃得下一个纯色。
  Widget? _buildHeaderBackdrop() {
    final style = _header;
    if (style.gradient == null && style.image == null && style.blur == null) {
      return null;
    }
    return SkinBox(style: style, child: const SizedBox.expand());
  }

  /// 抽屉入口。**必留部件**，见 skin_affordance.dart 的说明。
  Widget _buildDrawerButton() {
    final t = context.chat;
    return Center(
      child: SkinAffordance(
        style: context.parts.headerDrawer,
        icon: Icons.menu_rounded,
        foreground: t.tintPrimary,
        behind: _header.fillColor(t.headerBg) ?? t.headerBg,
        tooltip: '会话与设置（长按可临时停用皮肤）',
        onTap: () => _scaffoldKey.currentState?.openDrawer(),
        onLongPress: _showSkinSafetyMenu,
      ),
    );
  }

  /// 逃生舱菜单。
  ///
  /// **整个菜单用内置主题渲染**，不受当前皮肤影响 —— 这个菜单存在的唯一理由
  /// 就是"皮肤把界面搞坏了"，让它跟着坏掉的皮肤走就等于没有这个功能。
  Future<void> _showSkinSafetyMenu() async {
    final settings = widget.settings;
    final safe = buildSkinTheme(
      Theme.of(context).brightness,
      ChatSkinCatalog.fallback,
    );
    final tokens = safe.extension<ChatTokens>() ?? ChatTokens.dark;
    final suspended = settings.chatSkinSuspended;

    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: tokens.bgPrimary,
      builder: (sheetContext) => Theme(
        data: safe,
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                leading: Icon(
                  suspended
                      ? Icons.palette_outlined
                      : Icons.format_paint_outlined,
                  color: tokens.tintPrimary,
                ),
                title: Text(
                  suspended ? '恢复皮肤' : '临时停用皮肤',
                  style: TextStyle(color: tokens.tintPrimary),
                ),
                subtitle: Text(
                  suspended ? '重新应用当前选中的皮肤包' : '整个界面回到内置外观，皮肤包不会被卸载',
                  style: TextStyle(color: tokens.tintSecondary, fontSize: 12),
                ),
                onTap: () => Navigator.of(sheetContext).pop('toggle'),
              ),
              ListTile(
                leading: Icon(Icons.tune_rounded, color: tokens.tintPrimary),
                title:
                    Text('聊天外观', style: TextStyle(color: tokens.tintPrimary)),
                onTap: () => Navigator.of(sheetContext).pop('appearance'),
              ),
            ],
          ),
        ),
      ),
    );

    if (!mounted) return;
    switch (choice) {
      case 'toggle':
        await settings.setChatSkinSuspended(!suspended);
      case 'appearance':
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => ChatAppearancePage(
              store: settings,
              skins: widget.skins,
            ),
          ),
        );
        if (mounted) setState(() {});
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
          chats: widget.chats,
          skins: widget.skins,
          // 闭包而不是值：这一路只在会话跑着的时候才会失败，
          // 取快照的话用户改完配置回到分工表看到的还是上一次那条错误。
          embeddingError: () => _agent.retrieval.lastEmbeddingError,
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
    final id = _threadId;
    final original = _visible[visibleIndex];
    final historyIndex = _historyIndexOf(visibleIndex);
    // 静默返回是这个功能之前"点了没反应"的原因之一：对不上位置时什么都
    // 不做，也什么都不说。宁可说一句让人能去反馈，也别装作没点过。
    if (historyIndex < 0) {
      _setStatus('这条消息在上下文里对不上位置，编辑不了');
      return;
    }

    // 「重发」只对用户消息成立：助手那条已经答完了，没有可以重发的提问。
    final choice = await _promptEdit(
      original.content,
      canResend: original.role == 'user',
      reasoning: original.reasoning,
      resendWarning: _rewindWarning(visibleIndex),
    );
    if (choice == null || !mounted) return;

    if (!choice.resend) {
      await _saveMessageEdit(
        visibleIndex,
        choice.text,
        reasoning: choice.reasoning,
      );
      return;
    }

    final text = choice.text.trim();
    // 空内容不能走重发：这条会被截掉，而 _send 又会因为没内容直接返回，
    // 结果是"点一下，对话少了一截，什么也没发生"。
    if (text.isEmpty) {
      _setStatus('内容是空的，没法重发');
      return;
    }

    // 分支 id 要在截断**之前**拿到并存下旧的一段 —— 截断之后那段就没了。
    final branchId = id == null ? null : _ensureBranchId(historyIndex);
    final oldTail =
        branchId == null ? null : _agent.history.sublist(historyIndex);

    // 不再弹第二个确认框：编辑框里那句提示已经把同一件事说过了。
    final ok = await _applyRewind(visibleIndex);
    if (!ok) return;

    if (id != null && branchId != null && oldTail != null) {
      await widget.chats.saveVariant(
        threadId: id,
        branchId: branchId,
        tail: oldTail,
        active: false,
      );
      // 新版本是这一次发送的产物，发完在 _runTurn 里结账。
      _pendingBranch = (branchId: branchId, anchorIndex: historyIndex);
    }

    if (!mounted) return;
    // **真的发出去。** 之前只是把文字填回输入框就收工了，按钮写着"重发"
    // 却要用户自己再按一次发送 —— 那是"编辑"，不是"编辑并重发"。
    _input.text = text;
    _input.selection = TextSelection.collapsed(offset: text.length);
    await _send();
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

  /// 回退会丢掉什么。编辑框和「回到这里」的确认框共用这一句 ——
  /// 两处说法不一致的话，用户在其中一处建立的预期到另一处就是错的。
  String _rewindWarning(int visibleIndex) {
    final message = _visible[visibleIndex];
    return message.checkpoint != null
        ? '这条消息之后的对话会被丢弃，workspace 里的文件也会一起回到'
            '发这条消息之前的状态（检查点 #${message.checkpoint}）。'
        // 老会话没有检查点记录。**必须说出来** —— 用户点「回到这里」
        // 的预期就是文件也回去，静默地只截对话会让他在一个已经被改过的
        // workspace 上继续操作而不自知。
        : '这条消息之后的对话会被丢弃。\n'
            '这条消息是旧版本存下的，没有检查点记录，'
            'workspace 里的文件不会回滚。';
  }

  Future<bool> _rewind(int visibleIndex, {required String confirmTitle}) async {
    final confirmed =
        await _confirm(confirmTitle, _rewindWarning(visibleIndex));
    if (!confirmed) return false;
    return _applyRewind(visibleIndex);
  }

  /// 真正执行回退：截断对话 + 回滚文件。**不问**。
  ///
  /// 和确认分开，是因为「编辑并重发」在编辑框里就已经把同一件事问过一遍了。
  /// 同一个决定问两遍，第二遍会被当成"是不是刚才没点上"。
  Future<bool> _applyRewind(int visibleIndex) async {
    final historyIndex = _historyIndexOf(visibleIndex);
    if (historyIndex < 0) {
      // 用户已经在确认框上点过"确定"了，这里再无声失败最容易被当成卡死。
      _setStatus('这条消息在上下文里对不上位置，回退不了');
      return false;
    }

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

  /// 界面那份和 `history` 的下标不保证一致，见 message_index.dart。
  /// 规则见 [historyIndexOfVisible]。
  int _historyIndexOf(int visibleIndex) =>
      historyIndexOfVisible(_visible, _agent.history, visibleIndex);

  /// 重新读一遍当前可见消息涉及的分支状态。
  Future<void> _refreshBranches() async {
    final ids = <String>{
      for (final message in _visible)
        if (message.branchId != null) message.branchId!,
    };
    final next = <String, BranchState>{};
    for (final id in ids) {
      final state = await widget.chats.branchStateOf(id);
      if (state != null) next[id] = state;
    }
    if (!mounted) return;
    setState(() {
      _branches
        ..clear()
        ..addAll(next);
    });
  }

  /// 给某条用户消息拿到分支 id，第一次分支时现生成一个。
  ///
  /// **两个列表里换的必须是同一个对象**：`_historyIndexOf` 用 `identical`
  /// 做匹配，换成两个内容相同但不同一的实例，之后的「回到这里」会找不到位置。
  String _ensureBranchId(int historyIndex) {
    final anchor = _agent.history[historyIndex];
    final existing = anchor.branchId;
    if (existing != null) return existing;

    final id = 'b${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
    final tagged = anchor.copyWith(branchId: id);
    _agent.history[historyIndex] = tagged;
    _retagVisible(historyIndex, anchor, tagged);
    return id;
  }

  /// 把 `history[historyIndex]` 上刚换好的那条同步到界面那份。
  ///
  /// **不能只用 `identical` 找。** 当前这一轮刚发出去的用户消息在两个列表里
  /// 是两个不同的实例（见 message_index.dart），恒等匹配对它永远是 -1 ——
  /// 于是分支 id 只挂到了 history 那条上，界面那条还是干净的。
  /// `_refreshBranches` 是扫 `_visible` 收集 branchId 的，收不到就一个版本
  /// 切换器都不画：**刚发完消息就点「重新生成」，分支数据全进了库，界面上
  /// 却什么都没有**，而重开一次会话又好了。那正是"重新生成有时候不创建
  /// 分支点"的原因。
  void _retagVisible(int historyIndex, ChatMessage before, ChatMessage after) {
    final direct = _visible.indexWhere((message) => identical(message, before));
    if (direct >= 0) {
      _visible[direct] = after;
      return;
    }
    final mapped =
        visibleIndexOfHistory(_visible, _agent.history, historyIndex);
    if (mapped >= 0) _visible[mapped] = after;
  }

  /// 切到这个分支点的另一个版本。
  ///
  /// 换掉的是**从锚点那条用户消息开始的一整段**，不只是助手那一条 ——
  /// 编辑重发会连问话本身一起变，只换回答的话两边就对不上了。
  Future<void> _switchVariant(
    String branchId,
    int target, {
    /// 删完一个版本之后调进来的：这时"目标序号"可能和删之前那个相同，
    /// 但它背后已经是另一段内容了，必须真的换一次。
    bool force = false,
  }) async {
    if (_busy) return;
    final id = _threadId;
    if (id == null) return;
    if (!force && _branches[branchId]?.active == target) return;

    final tail = await widget.chats.loadVariant(branchId, target);
    if (tail == null || !mounted) return;

    final anchorIndex =
        _agent.history.indexWhere((message) => message.branchId == branchId);
    if (anchorIndex < 0) return;
    final anchor = _agent.history[anchorIndex];
    final visibleAnchor =
        _visible.indexWhere((message) => identical(message, anchor));
    if (visibleAnchor < 0) return;

    setState(() {
      _agent.history
        ..removeRange(anchorIndex, _agent.history.length)
        ..addAll(tail);
      _visible
        ..removeRange(visibleAnchor, _visible.length)
        ..addAll(tail);
    });
    // 历史换了一段，长度多半也变了。checkpoint 是 history 的下标 ——
    // 不跟着收的话它可能落在新历史的末尾之后，那时窗口里一条消息都不剩
    // （`history.skip(checkpoint)` 是空的），模型当场失忆；而下一次摘要
    // 还会在 `sublist(checkpoint, …)` 上直接抛。
    _agent.overflow.clampTo(_agent.history.length);
    await _persist();
    await widget.chats.setActiveVariant(branchId, target);
    await _refreshBranches();
    HapticFeedback.selectionClick();
  }

  /// 删掉正在看的这个版本。
  ///
  /// 删完要把界面换到剩下的某一版上 —— 停在一个已经不存在的版本上，屏幕上
  /// 那段内容就没有任何东西对应得上了。全删光时锚点上的分支 id 也就没人
  /// 引用，和从来没分过支一样。
  Future<void> _deleteVariant(String branchId, int index) async {
    if (_busy) return;
    final id = _threadId;
    if (id == null) return;
    final before = _branches[branchId];
    if (before == null) return;
    // 只剩一个版本时，"删这一版"等于把这段对话删掉 —— 那是另一个动作
    // （长按 → 删除这条及之后），有它自己的确认。这里不接这活。
    if (before.total <= 1) return;

    final ok = await _confirm(
      '删掉这一版',
      '这个版本会被删除，剩下的 ${before.total - 1} 版还在。'
          '当前正在看的内容会换成其中一版。',
    );
    if (!ok || !mounted) return;

    final left = await widget.chats.deleteVariant(branchId, index);
    if (!mounted) return;
    if (left <= 0) {
      await _refreshBranches();
      return;
    }
    // 换到删完之后活动的那一版上。deleteVariant 已经把序号重排成 0..n-1，
    // 并把活动位往前退了一个 —— 这里读回来照着切，不自己算第二遍。
    final after = await widget.chats.branchStateOf(branchId);
    if (after == null || !mounted) return;
    await _switchVariant(branchId, after.active, force: true);
  }

  /// 历史被**改小**之后落盘：编辑、删除、回到某条、切分支。
  ///
  /// 和发送时的落盘分开，是因为只有这几条路会把消息拿走 —— 而拿走消息就
  /// 可能留下没人要的图。发送只会加，加不出孤儿。
  Future<void> _persist() async {
    final id = _threadId;
    if (id == null) return;
    await _persistMessages(id);
    await _sweepOrphanImages(id);
  }

  /// 收掉这个会话里没人要的图。
  ///
  /// 只扫这一个会话的目录：一次编辑重发只会在一个会话里留下孤儿，没必要
  /// 每次都走一遍全部会话的磁盘。
  ///
  /// 引用集合是**全库**算的，不是只算这个会话 —— 内容相同的分支段会被两个
  /// 会话共用，按会话算的话会删掉另一个会话还在用的图。
  Future<void> _sweepOrphanImages(String threadId) async {
    if (!_runtimeReady) return;
    try {
      final referenced = await widget.chats.referencedImagePaths();
      await reclaimOrphanImages(
        _runtime.root.parent,
        referenced,
        scope: <String>[threadId],
      );
    } catch (_) {
      // 回收失败只是多占点空间。用户刚做完的编辑已经存好了，
      // 不该因为扫盘出问题就在界面上报一句他看不懂的话。
    }
  }

  Future<void> _persistMessages(String id) async {
    // **等历史补齐。** replaceMessages 是"删掉这个会话的全部行再重插"，
    // 拿一份只有尾巴的历史去执行，就是把用户前面的对话删了 —— 不可恢复。
    // 补齐失败时这里会跟着抛，那是对的：宁可这次不存，也不能删。
    await _backfill;
    final persisted = await widget.chats.replaceMessages(id, _agent.history);
    // 摘要状态跟着历史一起存，而且就在这一个出口 —— 发送、编辑、回滚、
    // 切分支全都收敛到这里，分散去存的话漏掉任何一处都会留下
    // 「checkpoint 指向一段已经不存在的历史」。
    await widget.chats.setMemory(
      id,
      _agent.overflow.summary,
      _agent.overflow.checkpoint,
    );
    if (persisted.length != _agent.history.length) return;

    // replaceMessages 删掉旧行重插，数据库 id 会变。把新 id 同步回内存，
    // 否则刚发完的消息立刻在当前会话里搜得到，点过去却定位不到。
    for (var i = 0; i < persisted.length; i++) {
      final original = _agent.history[i];
      final updated = persisted[i];
      _agent.history[i] = updated;
      // 同样不能只靠恒等匹配：这一轮自己发出去的那条用户消息在界面那份里
      // 是另一个实例，只用 identical 的话它永远拿不到数据库 id ——
      // 表现是"刚发的消息搜得到，点过去却定位不到"。
      _retagVisible(i, original, updated);
    }
  }

  /// 打开编辑框。返回用户选了哪个动作，取消返回 null。
  ///
  /// 两个动作是分开的，这是"编辑"在聊天里本来就有的两种意思：
  ///
  ///   - **保存**：就地改掉这条的内容，不重新生成。改 AI 回复只有这一种
  ///     解释——模型已经答完了，没有"重发"可言；而改完之后模型看到的
  ///     上下文也跟着变，这正是想改它的理由（纠正一个事实、删掉一段
  ///     跑偏的推理，好让后面的对话接着对的前提走）。
  ///   - **保存并重发**：只对用户消息成立，语义是"当我没说过，重说一遍"，
  ///     它会丢弃这条之后的全部对话。
  Future<({String text, String reasoning, bool resend})?> _promptEdit(
    String original, {
    required bool canResend,
    String reasoning = '',
    String resendWarning = '',
  }) async {
    final body = TextEditingController(text: original);
    body.selection = TextSelection.collapsed(offset: original.length);
    // 思考只在**本来就有**的时候才给编辑框。给一条没有思考的消息摆一个空
    // 输入框，等于邀请用户凭空写一段模型没想过的东西，那不是"编辑"。
    final hasReasoning = reasoning.isNotEmpty;
    final thought = TextEditingController(text: reasoning);

    ({String text, String reasoning, bool resend}) result(bool resend) => (
          text: body.text,
          reasoning: hasReasoning ? thought.text : reasoning,
          resend: resend,
        );

    try {
      return await showDialog<({String text, String reasoning, bool resend})>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('编辑消息'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (hasReasoning) ...<Widget>[
                  const Padding(
                    padding: EdgeInsets.only(bottom: 6),
                    child: Text('思考', style: TextStyle(fontSize: 12)),
                  ),
                  TextField(
                    controller: thought,
                    maxLines: 6,
                    minLines: 2,
                    style: const TextStyle(fontSize: 13),
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.only(top: 14, bottom: 6),
                    child: Text('正文', style: TextStyle(fontSize: 12)),
                  ),
                ],
                TextField(
                  controller: body,
                  autofocus: !hasReasoning,
                  maxLines: 8,
                  minLines: 3,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                // 破坏性后果要在**做决定的这一屏**上说。原来它在点完之后
                // 才弹出来，那时用户已经把话打完了，等于先让人干活再告诉
                // 他代价。
                if (canResend && resendWarning.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      '「保存并重发」：$resendWarning',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: context.chat.tintTertiary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(result(false)),
              child: const Text('保存'),
            ),
            if (canResend)
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(result(true)),
                child: const Text('保存并重发'),
              ),
          ],
        ),
      );
    } finally {
      body.dispose();
      thought.dispose();
    }
  }

  /// 就地改掉一条消息的内容。
  ///
  /// **两个列表都要改，而且换成同一个对象。** 只改 `_visible` 的话界面变了
  /// 但模型看到的还是旧的，是一种最难发现的假象；而换成两个内容相同的
  /// 不同实例，会让 [historyIndexOfVisible] 的身份快路径失效。
  Future<void> _saveMessageEdit(
    int visibleIndex,
    String text, {
    required String reasoning,
  }) async {
    final historyIndex = _historyIndexOf(visibleIndex);
    if (historyIndex < 0) {
      _setStatus('这条消息在上下文里对不上位置，改不了');
      return;
    }
    final edited = _agent.history[historyIndex]
        .copyWith(content: text, reasoning: reasoning);
    setState(() {
      _agent.history[historyIndex] = edited;
      _visible[visibleIndex] = edited;
    });
    await _persist();
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

    // 当前模型不支持工具调用时不让开：终端模式的全部内容就是给模型一堆
    // tools，不支持的模型收到之后要么直接 400，要么把 tools 当没看见然后
    // 用自然语言描述"我打算执行 ls" —— 后者尤其糟，看起来像在干活，
    // 实际上一条命令都没跑。
    if (on && !_effectiveCapability.tools) {
      final model = _effectiveModel.isEmpty ? '当前模型' : _effectiveModel;
      _setStatus('「$model」被标记为不支持工具调用，终端模式用不了');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('「$model」不支持工具调用。如果它其实支持，'
                '可以在渠道管理里改这个模型的能力标记。'),
            duration: const Duration(seconds: 5),
          ),
        );
      }
      return;
    }

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
  void deactivate() {
    // 换会话时这个 State 会被整个换掉。在 deactivate 里存而不是 dispose：
    // 那时候 RenderObject 还在，还量得出"视口底边是哪一条"。
    unawaited(_persistReadingPosition());
    super.deactivate();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      unawaited(_persistReadingPosition());
      // 私密会话全部重新锁上。把手机递给别人之前，用户唯一会做的动作
      // 就是切出去或者息屏 —— 那一刻不锁，这道锁只在第一次有用。
      widget.unlocked.lockAll();
    }
  }

  @override
  void dispose() {
    _tabFade.dispose();
    WidgetsBinding.instance.removeObserver(this);
    widget.settings.removeListener(_onSettingsChanged);
    _statusTimer?.cancel();
    _highlightTimer?.cancel();
    _shell?.killGroup();
    if (_runtimeReady && _threadId == null) {
      unawaited(_runtime.root.delete(recursive: true));
    }
    _input.dispose();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _streamPaintTimer?.cancel();
    _terminalController.dispose();
    super.dispose();
  }

  // ---- AgentHost ----

  @override
  Future<bool> requestApproval(ToolCall call, PolicyVerdict verdict) async {
    final detail = call.name == 'exec'
        ? call.args['command'] as String? ?? ''
        : '${call.name} ${call.args}';

    // 「以后允许」只对 exec 给：写文件那几个工具没有稳定的命令前缀可存，
    // 存了也匹配不上。
    final allowKey = call.name == 'exec' ? ExecPolicy.allowKeyFor(detail) : '';
    var remember = false;

    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => StatefulBuilder(
            builder: (ctx, setLocal) => AlertDialog(
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
                  // 关掉沙箱之后每条命令都要问。没有这个口子的话，人会被
                  // 问烦然后去开 yolo —— 那等于把所有确认一次性全关掉，
                  // 比放行单独一条命令危险得多。
                  if (allowKey.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: CheckboxListTile(
                        value: remember,
                        onChanged: (v) => setLocal(() => remember = v ?? false),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: Text('以后允许 $allowKey',
                            style: const TextStyle(fontSize: 13)),
                        subtitle: const Text('可以在设置 → 沙箱模式里撤销',
                            style: TextStyle(fontSize: 11)),
                      ),
                    ),
                ],
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('拒绝')),
                FilledButton(
                    onPressed: () async {
                      if (remember && allowKey.isNotEmpty) {
                        await widget.settings.allowCommand(allowKey);
                      }
                      if (ctx.mounted) Navigator.pop(ctx, true);
                    },
                    child: const Text('允许')),
              ],
            ),
          ),
        ) ??
        false;
  }

  @override
  void onAssistantDelta(String text) {
    _streaming.write(text);
    _schedulePaint();
  }

  /// 这一轮最后一条助手消息量出来的思考时长。找不到就是 0。
  int _lastAssistantReasoningMs() {
    for (var i = _agent.history.length - 1; i >= 0; i--) {
      if (_agent.history[i].role == 'assistant') {
        return _agent.history[i].reasoningMs;
      }
    }
    return 0;
  }

  /// 网络分片可能细到一个字符一次。最多约 30fps 刷新，既保持实时感，
  /// 又避免 Markdown 每个 token 全量排版造成跳动和掉帧。
  void _schedulePaint() {
    _streamPaintTimer ??= Timer(const Duration(milliseconds: 33), () {
      _streamPaintTimer = null;
      if (mounted) {
        setState(() {});
        // 用户主动往上翻看历史时不该被拽回底部。只有本来就跟在底部的才
        // 继续跟；翻上去之后输出照样在后台流，翻回底部会自动接上。
        //
        // **不带动画。** 每 33ms 起一次 animateTo，上一次永远跑不完，
        // 既跟不准也更容易和用户的手势打架；而正文是往下长的，
        // 直接跳到新的底边就是"待在底部"本身。
        if (_canFollowBottom) _scrollToEnd();
      }
    });
  }

  @override
  void onAssistantReasoning(String text) {
    _thinkStartedAt ??= DateTime.now();
    _reasoning.write(text);
    // 和正文共用同一个节流器：两股流会交错到达，各自开一个的话
    // 一秒钟能排到 60 次，白白多一倍的重排。
    _schedulePaint();
  }

  @override
  void onTerminalChunk(List<int> chunk) {
    // Agent 跑命令时用户应该能实时看见，而不是盯着转圈等三分钟。
    _terminal.write(String.fromCharCodes(chunk));
  }

  @override
  void onStatus(String message) => _setStatus(message);

  @override
  void onAssistantMessage(ChatMessage message) {
    if (!mounted) return;
    // 这一段正文已经进 history 了，界面把流式缓冲收口成同一条消息。
    //
    // **必须用 AgentLoop 给的这一条，不能拿 _streaming 自己再造一条。**
    // 思考、耗时、用量都挂在它上面；自己造的那份取不到，只能靠猜，
    // 而猜出来的和重开会话之后读到的对不上。
    setState(() {
      _visible.add(message);
      _streaming.clear();
      _reasoning.clear();
      _thinkStartedAt = null;
    });
    if (_canFollowBottom) _scrollToEnd(animated: true);
  }

  @override
  void onToolStart(ToolCall call) {
    if (!mounted) return;
    setState(() {
      _runningTool = (
        title: toolCallTitle(call.name, call.args),
        startedAt: DateTime.now(),
      );
    });
    if (_canFollowBottom) _scrollToEnd(animated: true);
  }

  @override
  void onToolEnd(ChatMessage message) {
    if (!mounted) return;
    setState(() {
      _runningTool = null;
      _visible.add(message);
    });
    if (_canFollowBottom) _scrollToEnd(animated: true);
  }

  @override
  void onContextMessage(ChatMessage message) {
    // 插在流式气泡**之前**：这条是模型开口之前就已经存在的输入，
    // 排在回答后面会让人以为是模型说的。
    if (mounted) setState(() => _visible.add(message));
  }

  // ---- 交互 ----

  Future<void> _send() async {
    final text = _input.text.trim();
    final images = List<String>.from(_attachments);
    // 只有图、没有文字也能发 —— 「你看这个」本来就是一种完整的表达。
    if ((text.isEmpty && images.isEmpty) || _busy || _loadingHistory) return;

    HapticFeedback.mediumImpact();
    var id = _threadId;
    if (id == null) {
      id = await widget.chats.createThread(
        text.isEmpty ? '[图片]' : text,
        preferredId: widget.runtimeId,
        terminalMode: _agent.terminalMode,
      );
      _threadId = id;
      // 会话是刚建的，之前设的那份策略还只在内存里，补写进去。
      //
      // 内存里那份也要换成定死之后的：不换的话它还留着一堆 null（"跟全局"），
      // 而下一次在 `+` 里调温度会把这份带 null 的整体写回库，
      // 刚定死的渠道和模型又变回"跟全局"了。
      _prefs = _pinPrefs();
      await widget.chats.setPrefs(id, _prefs);
      // 会话是刚建的，之前设的那份提示词还只在内存里，补写进去。
      if (_threadPrompt != null) {
        await widget.chats.setSystemPrompt(id, _threadPrompt);
      }
      // 外壳的标题要跟上，否则顶栏会一直显示「新对话」，
      // 而抽屉里那一条已经有名字了 —— 两处对不上很像是坏了。
      final title = text.isEmpty ? '[图片]' : text;
      widget.onTitleChanged(
          title.length > 28 ? '${title.substring(0, 28)}…' : title);
    }
    _input.clear();
    setState(() {
      _busy = true;
      _cancelRequested = false;
      _visible.add(ChatMessage(
        role: 'user',
        content: text,
        at: DateTime.now(),
        images: images,
      ));
      // 发消息是主动动作：不管发送前翻到对话哪个位置，都该跳到底部去看
      // 这句话和接下来的回复——用户没有理由发了消息却还盯着旧历史。
      _scrolledAway = false;
      // 顺手把手势状态清干净。万一某次 ScrollStart 没等到配对的 ScrollEnd，
      // 跟随会被永久关掉，而那种卡死没有任何迹象可查。
      _userScrolling = false;
      _attachments.clear();
      _streaming.clear();
      _reasoning.clear();
      _thinkStartedAt = null;
    });
    await widget.chats.append(id, _visible.last);

    // 编辑重发：这条新消息其实是某个分支点上的新版本，把账接上。
    final pending = _pendingBranch;
    _pendingBranch = null;

    await _runTurn(
      id,
      () => _agent.send(text, images: images),
      branchId: pending?.branchId,
      anchorIndex: pending?.anchorIndex,
    );
  }

  /// 跑一个回合：发请求、收流、把结果落成一条助手消息。
  ///
  /// [branchId] 非空时，这一轮的产物会作为该分支点的新版本存下来并设为当前
  /// 版本 —— 「重新生成」和「编辑重发」都靠它留下可切回的旧版本。
  Future<void> _runTurn(
    String id,
    Future<void> Function() body, {
    String? branchId,
    int? anchorIndex,
  }) async {
    try {
      await body();
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
      // 整轮期间用户可能翻上去看历史；那种情况下结束时也不该把人拽回
      // 底部——和流式过程中的道理一样，是不是"跟着"要在内容落地前判断。
      final wasFollowingBottom = !_scrolledAway;
      setState(() {
        // 正常写完的每一段都已经由 onAssistantMessage 收进 _visible 了，
        // 缓冲这时是空的。走到这里说明这一轮**没能正常收尾** —— 用户按了
        // 停止，或者中途断线：文字流出来了一半，AgentLoop 那边还没来得及
        // 把它记进 history。
        if (_streaming.isNotEmpty) {
          final partial = ChatMessage(
            role: 'assistant',
            content: _streaming.toString(),
            at: DateTime.now(),
            source: _effectiveSourceLabel,
            // 思考也接上，不接的话回答断掉的瞬间那一块会整个消失，
            // 而它明明刚刚还在。
            reasoning: _reasoning.toString(),
            // 时长只有 AgentLoop 那边量得到。取最后一条助手消息的。
            reasoningMs: _lastAssistantReasoningMs(),
            // 用量取整轮的：这条是界面现造的，history 上没有对应的那一条。
            usage: _agent.lastTurnUsage,
          );
          // **两份都要加。** 只加 _visible 的话，用户看得见这半句话，
          // 但它没进 history，重开会话就没了 —— 而"刚才明明说了一半"
          // 是用户最想留下的那种残骸（尤其是他主动按停止的时候）。
          _agent.history.add(partial);
          _visible.add(partial);
          _streaming.clear();
          _reasoning.clear();
          _thinkStartedAt = null;
        }
        // 被取消时 onToolEnd 不会到，卡片会永远停在"执行中"。
        _runningTool = null;
        _busy = false;
      });
      // 分支点上的新版本要先挂上 id 再存，否则重开 App 之后这条消息
      // 就找不到自己属于哪个分支了。
      if (branchId != null &&
          anchorIndex != null &&
          anchorIndex < _agent.history.length) {
        final anchor = _agent.history[anchorIndex];
        if (anchor.branchId != branchId) {
          final tagged = anchor.copyWith(branchId: branchId);
          _agent.history[anchorIndex] = tagged;
          _retagVisible(anchorIndex, anchor, tagged);
        }
      }
      await _persistMessages(id);
      if (branchId != null && anchorIndex != null) {
        await widget.chats.saveVariant(
          threadId: id,
          branchId: branchId,
          tail: _agent.history.sublist(anchorIndex),
        );
        await _refreshBranches();
      }
      if (wasFollowingBottom) _scrollToEnd();
    }
  }

  void _stop() {
    _cancelRequested = true;
    _agent.cancel();
    _setStatus('正在停止当前请求和命令…');
  }

  /// 重新生成界面上第 [visibleIndex] 条回复。
  ///
  /// 长按任意一条助手消息都能来这儿 —— 不再只有最后一条能重来。
  Future<void> _retryVisible(int visibleIndex) async {
    if (_busy) return;
    final historyIndex = _historyIndexOf(visibleIndex);
    if (historyIndex < 0) {
      _setStatus('这条消息在上下文里对不上位置，重新生成不了');
      return;
    }
    await _regenerateAt(historyIndex);
  }

  /// 重新生成 `history[targetIndex]` 这一条，以及它之后的一切。
  ///
  /// **锚点是它前面那一条，不是"最后一条问话"**（见 branch_plan.dart）：
  /// 一轮里模型说了好几段、或者中间夹着工具结果时，锚在问话上会把这一轮
  /// 已经跑出来的东西一起丢掉 —— 命令白跑一遍，而用户只是想让最后那段
  /// 答案换个说法。
  ///
  /// 被换掉的那一段不会丢，而是存成这个锚点下的一个版本，可以切回去。
  Future<void> _regenerateAt(int targetIndex) async {
    if (_busy) return;
    final id = _threadId;
    if (id == null) return;
    if (targetIndex < 0 || targetIndex >= _agent.history.length) return;

    final pivot = forkPivotIndex(_agent.history, targetIndex);
    if (pivot < 0) {
      // 这是对话的第一句，前面没有可锚的消息。分支没地方挂，
      // 说一句比默默重跑一遍好 —— 后者会把旧回复直接丢掉。
      _setStatus('这是对话的第一条，没有可以分支的位置');
      return;
    }

    HapticFeedback.mediumImpact();
    // `_busy` 要在第一个 await 之前同步落地：这里到 saveVariant 落盘之间
    // 有一段异步空档，_ensureBranchId 是同步的没问题，但下面 saveVariant
    // 要等库。锁晚一步的话，两次快速点击「重新生成」会在锁生效前都通过
    // 顶部那句 `if (_busy) return`，各自存一份旧版本、各自截断历史。
    final branchId = _ensureBranchId(pivot);
    final visiblePivot = visibleIndexOfHistory(_visible, _agent.history, pivot);
    setState(() {
      // 界面上对不上锚点位置时不动它，等这一轮结束后统一重画。
      // 猜一个位置去截，会把用户看得见的消息删错。
      if (visiblePivot >= 0) {
        _visible.removeRange(visiblePivot + 1, _visible.length);
      }
      _busy = true;
      _cancelRequested = false;
      _streaming.clear();
      _reasoning.clear();
      _thinkStartedAt = null;
      _scrolledAway = false;
      _userScrolling = false;
    });

    // 先把即将被替换的这一段收进版本库，再动它。
    await widget.chats.saveVariant(
      threadId: id,
      branchId: branchId,
      tail: _agent.history.sublist(pivot),
      active: false,
    );
    _agent.history.removeRange(pivot + 1, _agent.history.length);
    // 同 [_switchVariant]：砍短了历史就得把 checkpoint 收回来。
    _agent.overflow.clampTo(_agent.history.length);

    await _runTurn(
      id,
      () => _agent.regenerate(),
      branchId: branchId,
      anchorIndex: pivot,
    );
  }

  /// 往界面上再接一页更早的消息。
  ///
  /// 消息本身从 `_agent.history` 里取，不查库 —— 后台早就把完整历史补进去了
  /// （见 [_fillOlderHistory]）。这里做的只是"让界面认下它们"。
  ///
  /// **接完要把滚动位置补回去。** 在列表**顶部**插内容会把已有内容整个往下
  /// 推，用户正看着的那一段会瞬间跳走一屏 —— 那比停顿更让人迷惑。
  Future<void> _loadOlderPage() async {
    if (_loadingOlder || _olderInStore <= 0 || !mounted) return;
    _loadingOlder = true;
    try {
      await _backfill;
      if (!mounted) return;
      final loaded = _visible.length;
      final head = _agent.history.length - loaded;
      if (head <= 0) {
        _olderInStore = 0;
        return;
      }
      // 按 token 预算取一段，从已显示的那条往前数。
      var budget = _pageTokens;
      var start = head;
      while (start > 0 && budget > 0 && head - start < _pageMessages) {
        start--;
        budget -= TokenCounter.estimate(_agent.history[start].content) +
            TokenCounter.perMessageOverhead;
      }
      final batch = _agent.history.sublist(start, head);
      if (batch.isEmpty) return;

      // 直接插，**不用补位置**。倒序列表里更早的消息是往列表**尾部**加的，
      // 而尾部离锚点（底边）最远 —— 视口纹丝不动。正着排的时候这里要先记下
      // 「离底部还有多远」、插完再跳回去，因为在顶部插内容会把用户正看的那段
      // 整个往下推一屏。
      setState(() {
        _visible.insertAll(0, batch);
        _olderInStore = start;
      });
    } finally {
      _loadingOlder = false;
    }
  }

  /// 现在可以自动跟着底部走吗。
  ///
  /// 两个条件缺一不可：用户没翻上去看历史，**而且**手指没在动它。
  bool get _canFollowBottom => !_scrolledAway && !_userScrolling;

  /// 用户开始 / 结束用手滚这个列表。
  ///
  /// 拖动一开始就立刻停掉跟随，不等 120 像素那个阈值 —— 那个阈值是给
  /// "翻上去看历史"用的，而它在生成过程中永远翻不过去（见 [_userScrolling]）。
  bool _onScrollNotification(ScrollNotification notification) {
    // 只认这个列表自己的。气泡里那些能横向滚的代码块也会往上冒通知，
    // 认了的话「横着拖一下代码」就把跟随关掉了。
    if (notification.depth != 0) return false;
    if (notification is ScrollStartNotification) {
      // 只认**手指**发起的。程序自己的 jumpTo/animateTo 也会发这个通知，
      // 认了的话跟随会把自己关掉。
      if (notification.dragDetails != null) {
        _userScrolling = true;
        if (!_scrolledAway && mounted) setState(() => _scrolledAway = true);
      }
    } else if (notification is ScrollEndNotification) {
      // 甩出去之后的惯性也算"用户在动它" —— ScrollEnd 要等惯性停下来才来，
      // 正好是想要的边界。停下来之后由 [_onScroll] 的距离判定接手。
      _userScrolling = false;
      _onScroll();
    }
    return false;
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    // 倒序列表里 offset **就是**「离底部还有多远」：0 = 贴着最新那条。
    // 正着排的时候这里要拿 maxScrollExtent 去减，而那个值在长对话里是估出来
    // 的、还会边滚边长 —— 判据本身就在抖。
    final away = _scroll.offset > 120;
    if (away != _scrolledAway && mounted) setState(() => _scrolledAway = away);

    // 快翻到顶了就提前补下一页。**提前**是关键：等真的到顶再去查库，
    // 用户会撞上一次肉眼可见的停顿，而滚动惯性正好在那一刻最快。
    // 一屏的余量足够在惯性停下来之前把下一页接上。
    //
    // 倒序列表里"顶"是 maxScrollExtent 那一头。首屏没填满时这个差值本来
    // 就小于一屏，于是会立刻再补一页 —— 那正是想要的：先把屏幕填满。
    final position = _scroll.position;
    if (position.maxScrollExtent - position.pixels <
        position.viewportDimension) {
      unawaited(_loadOlderPage());
    }

    // 「读到哪儿」300ms 采一次样。每帧都算的话，一个五百条的会话每秒要走
    // 几万次循环，而这个值的唯一用途是"下次打开停在哪"—— 它不需要精确到帧。
    final now = DateTime.now();
    if (now.difference(_anchorSampledAt).inMilliseconds < 300) return;
    _anchorSampledAt = now;
    _readingAnchor = _viewportBottomMessageId();
  }

  /// 上次看到哪一条。null = 在底部，也就是"没有特别的位置"。
  int? _readingAnchor;
  DateTime _anchorSampledAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 视口底边压着的那条消息的 id。在底部时返回 null。
  ///
  /// 取**底边**那条而不是顶边：聊天是往下长的，「我读到这儿了」指的是
  /// 最后看见的那条，不是屏幕最上面那条。
  ///
  /// 倒序列表里 `getOffsetToReveal(box, 0)` 给的是「把这条摆到**底边**时
  /// 该滚到哪」，越旧的消息这个值越大。所以从最新往回找，第一条 `>= pixels`
  /// 的就是当前压在底边上的那条 —— 比它更新的都已经滑到视口下面去了。
  int? _viewportBottomMessageId() {
    if (!_scroll.hasClients || !_scrolledAway) return null;
    final pixels = _scroll.position.pixels;
    // 从后往前找。没被 ListView 构建出来的行 currentContext 是 null，
    // 跳过它们很快 —— 真正要量的只有视口附近那几条。
    for (var i = _visible.length - 1; i >= 0; i--) {
      final id = _visible[i].messageId;
      if (id == null) continue;
      final box = _messageKeys[id]?.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached) continue;
      final viewport = RenderAbstractViewport.maybeOf(box);
      if (viewport == null) continue;
      if (viewport.getOffsetToReveal(box, 0).offset >= pixels) return id;
    }
    return null;
  }

  /// 把「读到哪儿」写进库。
  ///
  /// 落盘而不是只留在内存里：切出去一趟、或者被系统回收之后再回来，
  /// 内存里那份早没了 —— 而那恰恰是最需要它的时候。
  Future<void> _persistReadingPosition() async {
    final id = _threadId;
    if (id == null || !_runtimeReady) return;
    // 还挂在树上就现量一次，量不到再退回上一次采样的值。
    final anchor =
        _scroll.hasClients ? _viewportBottomMessageId() : _readingAnchor;
    await widget.chats.setLastRead(id, anchor);
  }

  void _scrollToEnd({bool animated = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 排进队之后、真正跑之前，用户可能已经把手指按上去了。
      // jumpTo/animateTo 都会掐掉他那一下。
      if (!_scroll.hasClients || _userScrolling) return;
      // 倒序列表里最新那条就在 offset 0。
      if (animated) {
        _scroll.animateTo(0,
            duration: const Duration(milliseconds: 90), curve: Curves.easeOut);
      } else {
        _scroll.jumpTo(0);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // 这里以前有一段「键盘弹起时把聊天内容跟着往上挪」。倒序列表之后不需要了
    // ——它的 0 点就锚在底边上，视口一矮，内容自己跟着输入框走。
    // 那段补偿是"列表锚在顶部"逼出来的，锚点一换就整个消失了。
    if (!_runtimeReady) return _buildLoadingShell();
    // 底栏没了之后，「怎么从终端回到对话」只剩顶栏那个图标。
    // 返回键也得能回来 —— 否则用户按返回会直接退出 app。
    return PopScope(
      canPop: _tab == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_switchTab(0));
      },
      child: Scaffold(
        key: _scaffoldKey,
        // 顶栏透明时让壁纸从它下面穿过去。**层序不变** —— AppBar 仍然画在
        // body 之上，所以必留的抽屉入口不可能被皮肤控制的图层盖住。
        extendBodyBehindAppBar:
            context.parts.headerStyle == SkinHeaderStyle.transparent,
        drawer: ChatDrawer(
          store: widget.chats,
          currentThreadId: _threadId,
          unlocked: widget.unlocked,
          // 找回时那道选择题的干扰项：用用户自己渠道上的模型，
          // 假选项才看起来同样可信。
          modelPool: () => <String>[
            for (final channel in widget.channels.channels) ...<String>[
              channel.model,
              ...widget.settings.modelsOf(channel.id),
            ],
          ],
          // 每个会话一个目录，父目录就是全部会话的容器。
          tasksRoot: _runtime.root.parent,
          onSelect: widget.onSelectThread,
          onOpenMessage: widget.onOpenSearchHit,
          onOpenSettings: _openSettings,
          onOpenSkills: _openSkills,
          onOpenChannels: _openChannels,
        ),
        appBar: AppBar(
          backgroundColor: _header.fillColor(
            context.parts.headerStyle == SkinHeaderStyle.transparent
                ? Colors.transparent
                : context.chat.headerBg,
          ),
          flexibleSpace: _buildHeaderBackdrop(),
          toolbarHeight: _header.height,
          // 抽屉入口是**必留部件**：皮肤能改图标、底色、形状、大小，不能让它
          // 消失。Scaffold 默认会自己插一个汉堡，这里换成我们钳制过的那颗。
          leading: _buildDrawerButton(),
          leadingWidth: math.max(56, (_header.size ?? 0) + 56),
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
                    diameter: context.parts.headerAvatar.size ?? 38,
                    style: context.parts.headerAvatar,
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
                          style: context.parts.headerTitle.styled(
                            TextStyle(
                              fontSize: 16.5,
                              fontWeight: FontWeight.w600,
                              color: context.chat.tintPrimary,
                            ),
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
            IconButton(
              tooltip: _threadPrompt == null ? '系统提示词' : '这个会话有自己的系统提示词',
              icon: Icon(
                Icons.psychology_outlined,
                size: context.parts.headerAction.iconSizeOr(24),
                // 会话有自己那份时点亮：它会盖掉全局，而"为什么这个会话
                // 说话方式不一样"要能一眼看出来。皮肤能改常态色，改不了
                // 这个点亮色 —— 它是状态指示，不是装饰。
                color: _threadPrompt == null
                    ? context.parts.headerAction.icon?.color
                    : context.chat.brand,
              ),
              onPressed: _editThreadPrompt,
            ),
            _tabAction(2, Icons.history_outlined, '检查点'),
            _buildTerminalAction(),
            // 设置 / 技能 / 账号都在抽屉里。
          ],
        ),
        // **IndexedStack，不是 AnimatedSwitcher。**
        //
        // 原来三个页签之间做淡入淡出，代价是切走的那个**整棵子树被拆掉**：
        // 聊天列表的 ScrollPosition 跟着没了，切回来是一个全新的、offset 为 0
        // 的列表 —— 表现就是"点一下检查点再回来，对话被拽回最开头"。
        //
        // 换成 IndexedStack 之后没有东西被拆，也就没有什么需要恢复：位置
        // 原封不动，终端那边的滚动条同理。顺带还省掉了每次切页签重新排版
        // 整个消息列表的开销。
        //
        // 代价是那 200ms 的淡入淡出没了。页签切换本来也不该有过场动画 ——
        // 它是"看另一样东西"，不是"去另一个地方"。
        body: FadeTransition(
          opacity: _tabFade,
          child: ScaleTransition(
            // 幅度压得很小。这是"换了一个"的提示，不是一次表演 ——
            // 页签切换一天要发生几十次，动静大了很快就烦。
            scale: Tween<double>(begin: 0.985, end: 1).animate(_tabFade),
            child: IndexedStack(
              index: _tab,
              children: <Widget>[
                _buildChat(),
                Column(
                  children: [
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
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Container(
                          decoration: BoxDecoration(
                            color: context.chat.bgSecondary,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: context.chat.borderPrimary,
                              width: 0.5,
                            ),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: InteractiveTerminal(
                            terminal: _terminal,
                            controller: _terminalController,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                _CheckpointTimeline(
                  snapshots: _runtime.snapshots,
                  prefixGens: widget.prefixGens,
                  onRolledBack: _setStatus,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 还没准备好时的样子。
  ///
  /// **不是一块空白加转圈。** 那样会在点进会话和看到对话之间插一个长得完全
  /// 不同的界面：标题变成「Burrow」、壁纸没了、输入框没了 —— 一次跳转看起来
  /// 像去了两个地方。Telegram 系客户端从来不这么做：聊天页的外壳（标题、
  /// 壁纸、输入框）第一帧就在，只有消息那块是空的，转圈画在那块的中间。
  ///
  /// 所以这里保留**同一张壁纸、同一个标题**，只把消息区留空。切过去的那一下
  /// 只有内容在变，框架是连续的。
  Widget _buildLoadingShell() {
    final t = context.chat;
    return Scaffold(
      backgroundColor: t.bgPrimary,
      appBar: AppBar(
        backgroundColor: t.headerBg,
        foregroundColor: t.tintPrimary,
        elevation: 0,
        // 真标题，不是 app 名。这一下切换里唯一该变的是消息，不是"我在哪"。
        title: Text(
          widget.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      body: ChatWallpaper(
        preset: widget.settings.chatWallpaperPreset,
        imagePath: widget.settings.chatWallpaperPath,
        dim: widget.settings.chatWallpaperDim,
        child: const Center(child: _DelayedSpinner()),
      ),
    );
  }

  Widget _buildChat() {
    // 流式那条单独接在后面，而不是每个 delta 都往 _visible 里塞 ——
    // 否则每个 token 都要重建整个列表。
    // 正在跑就一定有这一行，哪怕一个字都还没到 —— 那一行会画成三个跳动的
    // 点。**发出消息之后界面上什么都不变**是这个页面最容易被当成 bug 的
    // 表现，而它恰好发生在等待最久的推理模型上。
    // 有命令在跑的时候不画打字气泡：那一刻真正在发生的事是"命令在跑"，
    // 底下再挂三个跳动的点等于同时说两件事，而其中一件是假的
    // —— 模型此刻并没有在输出。
    final rows = _buildRows(
        _busy && _runningTool == null ? _streaming.toString() : null);

    final bottomInset = MediaQuery.paddingOf(context).bottom;
    // 弹层菜单（`+`、终端、长按消息）和输入框用同一套材质。放在这里一次，
    // 底下每个弹层自己取 —— 挨个往下传三个参数的话，迟早有一个忘了传，
    // 而那一个会长得和别的都不一样。
    return MenuMaterial(
      effect: widget.settings.chatComposerEffect,
      blur: widget.settings.chatComposerBlur,
      opacity: widget.settings.chatComposerOpacity,
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: NotificationListener<ScrollNotification>(
              onNotification: _onScrollNotification,
              child: ChatWallpaper(
                preset: widget.settings.chatWallpaperPreset,
                imagePath: widget.settings.chatWallpaperPath,
                dim: widget.settings.chatWallpaperDim,
                child: ListView.builder(
                  controller: _scroll,
                  // **倒着排：第 0 项在最底下，offset 0 就是最新消息。**
                  //
                  // 聊天列表天生是从底部长起来的，正着排等于每次都要先问
                  // "总高度是多少"才知道底在哪 —— 而变长条目的懒加载列表
                  // 不量到底就不知道 maxScrollExtent，于是打开会话得反复跳。
                  // 这一节课交过两次学费（"回到起始点"和"恢复位置不生效"）。
                  //
                  // 倒过来之后：打开即在底部，不用滚；键盘顶上来时内容自己
                  // 贴着输入框走，不用补偿；往上翻是往列表**尾部**追加，
                  // 视口纹丝不动，也不用补偿。三处补丁一起消失。
                  reverse: true,
                  physics: const BouncingScrollPhysics(
                    parent: AlwaysScrollableScrollPhysics(),
                  ),
                  // 输入区悬浮在列表上面；给最后一条消息留下同等空间，
                  // 否则它会停在玻璃下面，看得见却点不到。
                  padding: context.parts.list.padded(
                    EdgeInsets.fromLTRB(0, 8, 0, 84 + bottomInset),
                  ),
                  itemCount: rows.length,
                  // 划出视口的行直接丢掉，不留一份"以后可能还要用"的副本。
                  //
                  // 消息里最占内存的是解码后的图 —— 一张 1600px 的截图是
                  // 10MB 的 RGBA。翻过几十条带图的消息之后，那份缓存能顶得上
                  // 整个 app 的其余部分。行被回收，图跟着从内存里出去；
                  // 翻回来重新解一次是几十毫秒，而 OOM 是直接闪退。
                  addAutomaticKeepAlives: false,
                  itemBuilder: (_, i) => _buildRow(rows[i]),
                ),
              ),
            ),
          ),
          if (_scrolledAway)
            Positioned(
              right: 16,
              bottom: 100 + bottomInset,
              child: FloatingActionButton.small(
                heroTag: 'scroll_to_bottom',
                onPressed: () {
                  _scrollToEnd(animated: true);
                  HapticFeedback.lightImpact();
                },
                backgroundColor: context.chat.bgPrimary.withOpacity(0.9),
                foregroundColor: context.chat.brand,
                shape: const CircleBorder(),
                child: const Icon(Icons.arrow_downward_rounded),
              ),
            ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                AttachmentTray(
                  paths: _attachments,
                  onRemove: (path) => setState(() {
                    _attachments.remove(path);
                    // 文件也删掉。留着的话，会话目录里会慢慢堆满"选了又取消"的图，
                    // 而没有任何一条消息引用它们 —— 谁也不会想起来去清。
                    unawaited(
                        File(path).delete().catchError((_) => File(path)));
                  }),
                ),
                ChatComposer(
                  controller: _input,
                  generating: _busy,
                  enabled: !_busy && !_loadingHistory,
                  hasExternalContent: _attachments.isNotEmpty,
                  hintText:
                      _agent.terminalMode ? '描述你希望 Agent 完成的任务' : '随便聊点什么',
                  onSend: _send,
                  onStop: _stop,
                  effect: widget.settings.chatComposerEffect,
                  blur: widget.settings.chatComposerBlur,
                  opacity: widget.settings.chatComposerOpacity,
                  leading: [_buildPlusButton()],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 把 `_visible` 摊成列表要画的那些行：日期分隔 + 消息 + 流式那条。
  ///
  /// 先算成一个扁平的行表再交给 `ListView.builder`，而不是在 itemBuilder 里
  /// 现算下标 —— 一旦掺进日期分隔，「第 i 行是第几条消息」就不再是同一个数，
  /// 而 `_editMessage(i)` 这些操作要的是**消息下标**。分开算就不会串。
  List<_ChatRow> _buildRows(String? streaming) {
    final rows = <_ChatRow>[];
    // 0 表示「没有边界」，**必须据此不插那一行** —— 0 同时也是个合法下标，
    // 当成位置用就会在最前面插一条没有对应消息的空行（见 summaryBoundaryIndex）。
    final summaryAt = _agent.overflow.hasSummary
        ? summaryBoundaryIndex(
            _visible, _agent.history, _agent.overflow.checkpoint)
        : 0;
    for (var i = 0; i < _visible.length; i++) {
      final message = _visible[i];
      // 分隔线插在**被覆盖的最后一条之后**，而不是列表最前面：它标的是
      // 一个位置（"这条线以上模型只通过摘要知道"），摆错地方就不再是标记
      // 而是装饰。
      if (summaryAt > 0 && i == summaryAt) {
        rows.add(_ChatRow.summary(summaryAt));
      }
      if (i == 0 || !_sameDay(_visible[i - 1].at, message.at)) {
        rows.add(_ChatRow.date(message.at));
      }
      // 连续同一方的消息算一组：只有最后一条画尾巴和头像。
      final next = i + 1 < _visible.length ? _visible[i + 1] : null;
      final lastInGroup = next == null
          ? streaming == null || message.role != 'assistant'
          : next.role != message.role || !_sameDay(message.at, next.at);
      // 组内第一条。皮肤的 `:first` 状态要它 —— 判据和上面插日期分隔的那条
      // 一致，否则"组"在两处会是两个不同的概念。
      final previous = i > 0 ? _visible[i - 1] : null;
      final firstInGroup = previous == null ||
          previous.role != message.role ||
          !_sameDay(previous.at, message.at);
      rows.add(_ChatRow.message(i, lastInGroup, firstInGroup));
    }
    final running = _runningTool;
    if (running != null) rows.add(_ChatRow.runningTool(running));
    if (streaming != null) rows.add(_ChatRow.streaming(streaming));
    // **倒过来给列表。** 上面这一段仍然按"从旧到新"算 —— 日期分隔、分组、
    // 摘要分隔线的判据全是"和上一条比"，正着算才读得懂。倒序只是交付方式：
    // 列表是 reverse 的，它的第 0 项画在最底下。
    return rows.reversed.toList();
  }

  Widget _buildRow(_ChatRow row) {
    final running = row.runningTool;
    if (running != null) {
      return ToolCallCard(
        title: running.title,
        state: ToolCallState.running,
        startedAt: running.startedAt,
      );
    }

    final streaming = row.streaming;
    if (streaming != null) {
      return ChatBubble(
        role: 'assistant',
        text: streaming,
        generating: true,
        reasoning: _reasoning.toString(),
        // 正文一开始流，思考就算结束了 —— 模型不会先答一半再回去想。
        reasoningActive: streaming.isEmpty,
        reasoningStartedAt: _thinkStartedAt,
        avatarPath: widget.settings.assistantAvatarPath,
        showAvatar: widget.settings.showMessageAvatars,
      );
    }

    if (row.summaryCovered > 0) {
      return SummaryDivider(
        covered: row.summaryCovered,
        summary: _agent.overflow.summary ?? '',
      );
    }

    final day = row.day;
    if (day != null) return ServicePill(text: _dayLabel(day));

    final i = row.index;
    // 越界就什么都不画。抛出去的话 release 构建会把这一行渲染成一块纯灰色
    // 方块 —— 而那块灰色和"哪一行算错了"之间没有任何可见的联系，
    // 上一版就是这么在聊天记录上方糊出一大片灰的。
    if (i < 0 || i >= _visible.length) return const SizedBox.shrink();
    final message = _visible[i];

    // 工具调用不是"谁说的话"，画成卡片而不是气泡 —— 做成气泡的话，
    // 一屏里会有一半的"发言"其实是命令输出。
    if (message.role == 'tool') {
      return _messageSurface(
        message,
        ToolCallCard(
          // 老会话（v11 之前）的 tool 消息没记下是谁跑的，只能给一个泛称。
          title: message.toolTitle ?? message.toolName ?? '工具调用',
          state: message.toolOk ? ToolCallState.ok : ToolCallState.failed,
          output: message.content,
          elapsedMs: message.toolMs,
        ),
      );
    }

    final isError =
        message.role == 'system' && message.content.startsWith(kErrorPrefix);

    // 系统提示不是"谁说的话"，做成居中胶囊和左右两侧的气泡分开 ——
    // 长得像助手发言的话，用户会以为模型在自言自语。
    // 报错除外：它可能很长，压进胶囊会读不了，仍然走气泡。
    if (message.role == 'system' && !isError) {
      return _messageSurface(message, ServicePill(text: message.content));
    }

    final isUser = message.role == 'user';

    // 这条消息该不该带版本切换器：它自己就是锚点（用户消息），或者它是
    // 某个锚点下这一轮的最后一条回复。
    String? branchOwner = message.branchId;
    if (branchOwner == null && i == _visible.length - 1 && !_busy) {
      // 往回找**最近一个真正的锚点**，而不是最近一条用户消息。
      // 锚点现在可能是助手消息或工具结果（见 branch_plan.dart），
      // 只认用户消息的话那几种分支一个切换器都画不出来。
      for (var j = i - 1; j >= 0; j--) {
        if (_visible[j].branchId != null) {
          branchOwner = _visible[j].branchId;
          break;
        }
      }
    }
    final branch = branchOwner == null ? null : _branches[branchOwner];
    return _messageSurface(
        message,
        ChatBubble(
          role: message.role,
          text: message.content,
          images: message.images,
          time: message.at,
          // 用消息**自己记下的**来源，而不是当前配置。换个渠道就把满屏历史
          // 全部改署成新渠道的话，恰好会在用户回头查"刚才那次是谁花的额度"时
          // 给出错误答案。老消息没有这个记录，那就不署名。
          meta: _displayMessageSource(message.source),
          usage: message.usage,
          showTokens: widget.settings.showTokenUsage,
          reasoning: message.reasoning,
          reasoningMs: message.reasoningMs,
          // 切换器画在两个地方：分支锚点那条问话下面，以及这一轮最后一条回复
          // 下面。它们背后是同一个分支状态 —— 点「重新生成」的人会去回复那边
          // 找，点「编辑」的人会去问话那边找，两处都放才不会有人找不到。
          variantCount: branch?.total ?? 0,
          variantIndex: branch?.active ?? 0,
          onSwitchVariant: branch == null || _busy
              ? null
              : (target) => _switchVariant(branchOwner!, target),
          onDeleteVariant: branch == null || _busy
              ? null
              : () => _deleteVariant(branchOwner!, branch.active),
          isError: isError,
          lastInGroup: row.lastInGroup,
          firstInGroup: row.firstInGroup,
          avatarPath: isUser
              ? widget.settings.userAvatarPath
              : message.role == 'assistant'
                  ? widget.settings.assistantAvatarPath
                  : '',
          showAvatar: widget.settings.showMessageAvatars,
          // 任意一条回复都能重来，不只是最后一条 —— 重新生成会把它和
          // 它之后的一切存成一个版本，切得回去。
          //
          // 报错那条也给：一轮挂在网络上的时候，界面最后是一条红气泡，
          // 而它前面那条助手消息早就不是最后一条了 —— 只给最后一条的话，
          // 恰恰是最需要重试的那一刻没有重试按钮。
          onRetry: (message.role == 'assistant' || isError) && !_busy
              ? () => _retryVisible(i)
              : null,
          // 编辑对用户和助手都开放，但两者能做的事不同（见 _editMessage）：
          // 用户消息可以「保存并重发」，助手消息只能就地改内容 —— 改完模型
          // 看到的上下文也跟着变，这正是要改它的理由。
          onEdit: (isUser || message.role == 'assistant') && !_busy
              ? () => _editMessage(i)
              : null,
          // 回退仍然只给用户消息：它的语义是「从这句重来」，
          // 挂在助手消息上没有对应的动作。
          onRewind: isUser && !_busy ? () => _rewindTo(i) : null,
          onDelete: !_busy ? () => _deleteFrom(i) : null,
        ));
  }

  Widget _messageSurface(ChatMessage message, Widget child) {
    final key = _messageKey(message.messageId);
    Widget result = key == null ? child : KeyedSubtree(key: key, child: child);
    if (message.messageId != null && message.messageId == _highlightMessageId) {
      final t = context.chat;
      result = AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        decoration: BoxDecoration(
          color: t.bgBrandSecondary.withValues(alpha: 0.42),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: t.brand, width: 1.25),
        ),
        child: result,
      );
    }
    return result;
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
      final model = _effectiveSourceLabel;
      text = model.isEmpty ? '未配置模型' : model;
    }

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      layoutBuilder: (currentChild, previousChildren) => Stack(
        alignment: Alignment.centerLeft,
        children: <Widget>[
          ...previousChildren,
          if (currentChild != null) currentChild,
        ],
      ),
      child: Text(
        text,
        key: ValueKey(text),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        // 危险态的红色不让皮肤改：它是"沙箱关了"的唯一提示，
        // 被一个皮肤调成灰色就等于没有这个提示。
        style: danger
            ? TextStyle(fontSize: 12.5, height: 1.2, color: t.tintError)
            : context.parts.headerSubtitle.styled(
                TextStyle(fontSize: 12.5, height: 1.2, color: t.tintTertiary),
              ),
      ),
    );
  }

  /// 顶栏那两个页签入口。已经在那一页时再点一次回到对话 ——
  /// 图标既是"去"也是"回"，省掉一个返回键。
  /// 顶栏那个终端图标。
  ///
  /// 它同时是**状态指示**和**入口**：图标实心 + 品牌色 = 模型手里现在有工具。
  /// 这件事以前挂在输入框的 `+` 上，可那个加号还要同时表示"有东西配坏了"，
  /// 一个按钮说两件不相干的事，哪件都说不清。现在它归终端图标 —— 名副其实。
  ///
  /// 已经在终端页时点它是**返回对话**，不弹菜单：那一刻用户要的是出去，
  /// 而不是再翻一层设置。
  Widget _buildTerminalAction() {
    final armed = _agent.terminalMode;
    final inTerminal = _tab == 1;
    return IconButton(
      key: _terminalKey,
      tooltip: inTerminal
          ? '返回对话'
          : armed
              ? '终端 · 模式开着'
              : '终端',
      onPressed: () {
        HapticFeedback.selectionClick();
        if (inTerminal) {
          unawaited(_switchTab(0));
        } else {
          _showTerminalMenu();
        }
      },
      icon: Icon(
        armed ? Icons.terminal : Icons.terminal_outlined,
        size: context.parts.headerAction.iconSizeOr(24),
      ),
      // 点亮色是状态指示，不是装饰 —— 皮肤能改常态色，改不了它。
      color: inTerminal || armed
          ? context.chat.brand
          : context.parts.headerAction.icon?.color,
    );
  }

  Widget _tabAction(int tab, IconData icon, String tooltip) {
    final active = _tab == tab;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: IconButton(
        key: ValueKey(active),
        tooltip: active ? '返回对话' : tooltip,
        onPressed: () {
          unawaited(_switchTab(active ? 0 : tab));
        },
        icon: Icon(icon, size: context.parts.headerAction.iconSizeOr(24)),
        color: active
            ? context.chat.brand
            : context.parts.headerAction.icon?.color,
      ),
    );
  }

  /// 「有哪些来源、怎么从一个来源拉列表」。
  ///
  /// 和设置里那张模型分工表共用一份 —— 拉取那一步必须走渠道自己的代理和
  /// 认证，抄两份迟早有一份会漏掉其中一样。
  late final ModelSourceCatalog _catalog = ModelSourceCatalog(
    channels: widget.channels,
    accounts: widget.accounts,
    settings: widget.settings,
  );

  /// 换这个会话用的模型。**只换这一个会话。**
  ///
  /// 以前这里调的是 `channels.assignRole(ModelRole.chat, …)` —— 那是全局的：
  /// 在一个会话里为了一段代码换成 Opus，另外二十个会话（包括那个只用来
  /// 跑命令的本地小模型会话）跟着一起换了，而且不会有任何提示。
  Future<void> _pickModel() async {
    final picked = await showModelPicker(
      context,
      title: '对话模型',
      current: _effectiveModel,
      sources: _catalog.sources(),
      activeSourceId: _effectiveChannel?.id ?? widget.channels.activeId,
      onRefresh: _catalog.refresh,
      onToggleStar: _catalog.toggleStar,
    );
    if (picked == null || picked.model.isEmpty) return;
    final switched = picked.sourceId != _effectiveChannel?.id;
    await _updatePrefs(_prefs.copyWith(
      channelId: picked.sourceId,
      model: picked.model,
    ));
    if (switched && mounted) {
      final name =
          widget.channels.byId(picked.sourceId)?.name ?? picked.sourceId;
      _setStatus('这个会话已改用渠道「$name」');
    }
  }

  Future<void> _pickThinkingEffort() async {
    final t = context.chat;
    final current = _effectiveThinking;
    final picked = await showModalBottomSheet<ThinkingEffort>(
      context: context,
      backgroundColor: t.bgPrimary,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final effort in ThinkingEffort.values)
              ListTile(
                leading: Icon(effort == current
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked),
                title: Text(effort.label),
                subtitle:
                    Text(effort.hint, style: const TextStyle(fontSize: 11)),
                onTap: () => Navigator.pop(ctx, effort),
              ),
          ],
        ),
      ),
    );
    if (picked != null) {
      await _updatePrefs(_prefs.copyWith(thinkingEffort: picked));
    }
  }

  /// 温度。滑到哪儿算哪儿，松手才落库。
  ///
  /// 上界跟着**这个会话自己的**渠道走：Anthropic 到 1，OpenAI 兼容到 2。
  /// 拿另一套的上界去限，滑到一半就被悄悄截断。
  Future<void> _pickTemperature() async {
    final t = context.chat;
    final anthropic = _effectiveChannel?.apiFormat == 'anthropic';
    var value = _effectiveTemperature.clamp(0.0, anthropic ? 1.0 : 2.0);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: t.bgPrimary,
      builder: (ctx) => SafeArea(
        child: StatefulBuilder(
          builder: (ctx, setSheet) => Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.thermostat_outlined),
                title: Text('Temperature  ${value.toStringAsFixed(1)}'),
                subtitle: Text(
                  value <= 0.3
                      ? '稳，几乎每次都给同一个答案'
                      : value <= 0.8
                          ? '中间档，日常够用'
                          : '发散，适合写点东西',
                  style: const TextStyle(fontSize: 11),
                ),
              ),
              Slider(
                value: value,
                min: 0,
                max: anthropic ? 1 : 2,
                divisions: anthropic ? 10 : 20,
                onChanged: (v) => setSheet(() => value = v),
                onChangeEnd: (v) => _updatePrefs(
                  _prefs.copyWith(temperature: v),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  /// `+` 里那一行的说明：设了几项，以及有没有当前渠道不认的。
  String _samplingSummary() {
    final sampling = _prefs.sampling;
    if (sampling.isEmpty) return 'top_p / 输出上限 / 停止词 …（都跟默认）';
    final format = _effectiveChannel?.apiFormat ?? 'openAI';
    final ignored = sampling.ignoredBy(format);
    final touched = '已设 ${sampling.touched.length} 项';
    // 有设了却发不出去的，就在这一行直接说 —— 不说的话它只会以"毫无变化"
    // 的形式表现出来，而那看起来像是模型的问题。
    return ignored.isEmpty ? touched : '$touched · ${ignored.length} 项当前渠道不认';
  }

  Future<void> _editSampling() async {
    await showSamplingPage(
      context,
      initial: _prefs.sampling,
      apiFormat: _effectiveChannel?.apiFormat ?? 'openAI',
      channelLabel: _effectiveChannel?.name ?? '当前渠道',
      onChanged: (sampling) =>
          _updatePrefs(_prefs.copyWith(sampling: sampling)),
    );
  }

  /// 选图。相册 / 拍照两个入口摊在一个小弹层里。
  ///
  /// 不做成"长按相册图标拍照"那种隐藏手势：这两件事同样常用，
  /// 把其中一个藏起来只会让人以为不支持。
  /// 编这个会话的系统提示词。
  ///
  /// 会话还没落库（一条消息都没发）时也能设 —— 先存在内存里，
  /// 第一条消息落库时一起写进去。否则"新开一个对话、先定好人格再说话"
  /// 这个很自然的顺序做不了。
  Future<void> _editThreadPrompt() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => SystemPromptPage(
        title: '这个会话的系统提示词',
        initial: _threadPrompt,
        globalPreview: widget.settings.systemPrompt,
        terminalMode: _agent.terminalMode,
        onSave: (value) async {
          setState(() => _threadPrompt = value);
          _agent.userSystemPrompt = _effectiveSystemPrompt;
          final id = _threadId;
          if (id != null) await widget.chats.setSystemPrompt(id, value);
        },
        onRevertToGlobal: () async {
          setState(() => _threadPrompt = null);
          _agent.userSystemPrompt = _effectiveSystemPrompt;
          final id = _threadId;
          if (id != null) await widget.chats.setSystemPrompt(id, null);
        },
      ),
    ));
    if (mounted) setState(() {});
  }

  /// 选图。来源已经由 `+` 菜单选好了，这里只管取和存。
  ///
  /// 以前这里自己弹一层「相册 / 拍照」，现在那两项直接摆在 `+` 菜单里 ——
  /// 少一层嵌套，也少一次"点开又点开"。
  Future<void> _pickImages({required bool camera}) async {
    if (_busy) return;
    if (_attachments.length >= maxAttachments) {
      _setStatus('一次最多附 $maxAttachments 张图');
      return;
    }
    try {
      final room = maxAttachments - _attachments.length;
      final picked = camera
          ? await _images.pickFromCamera()
          : await _images.pickFromGallery(limit: room);
      if (!mounted || picked.isEmpty) return;
      setState(() => _attachments.addAll(picked.take(room)));
      // 图片进不了模型手里的话，现在说比发出去之后再报错好 ——
      // 那时用户已经等了一次网络往返。
      final warning = _visionWarning();
      if (warning != null) _setStatus(warning);
    } catch (e) {
      // 用户拒权限、相机不可用都走这里。原样显示 —— 这类错误的原文
      // （"用户拒绝了访问照片"）比任何转述都清楚。
      if (mounted) _setStatus('选图失败：$e');
    }
  }

  /// 当前配置能不能真的把图送到模型手里。能就返回 null。
  String? _visionWarning() {
    if (_effectiveSendImagesInline) return null;
    if (widget.channels.channels.any((c) => c.canDescribeImages)) {
      return widget.settings.imageMode == ImageMode.preprocess
          ? '会先用视觉模型把图描述成文字，再发给对话模型'
          : '当前模型不认图，会先用视觉模型描述一遍';
    }
    return '当前渠道不认图，也没有配视觉模型 —— 发出去图会被丢掉。'
        '到「设置 → 模型分工」里指一个「图片转文字」模型';
  }

  static const _approvalLabels = <ApprovalMode, String>{
    ApprovalMode.readOnly: '只读',
    ApprovalMode.onRequest: '按需审批',
    ApprovalMode.auto: '自动执行',
    ApprovalMode.yolo: '关闭沙箱',
  };

  /// 输入框左边那个 `+`。
  ///
  /// 里面只放**「这条消息怎么发」**：加图、换对话模型、想多久。会话级的
  /// 开关（终端模式、审批档位）搬到顶栏的终端图标下面去了 —— 它们和这几项
  /// 不是一类东西，混在一个菜单里，用户每次都要读一遍才知道哪个是哪个。
  ///
  /// 收进菜单的代价是状态看不见，所以按钮自己要画出**有东西配坏了**
  /// （没模型 / 嵌入不可用 / 图发不出去）：一个警告小点。终端模式开没开
  /// 归顶栏那个图标管，这里不再重复表态 —— 一个按钮说两件不相干的事，
  /// 哪件都说不清。
  Widget _buildPlusButton() {
    final t = context.chat;
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        ComposerIconButton(
          key: _plusKey,
          icon: Icons.add,
          tooltip: '更多',
          enabled: !_busy && !_installingDistro,
          onTap: _showComposerMenu,
        ),
        if (_composerWarning != null)
          Positioned(
            right: 6,
            top: 8,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: Container(
                key: const ValueKey('warning_dot'),
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: t.tintWarning,
                  shape: BoxShape.circle,
                  // 描一圈底色，免得小点落在图标上时糊成一团。
                  border: Border.all(color: t.composerField, width: 1),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// 有没有配坏的东西。有就返回那句话，用来点亮 `+` 上的小点。
  ///
  /// 按严重程度排：没模型是"整个 app 现在不能用"，排最前。
  String? get _composerWarning {
    if (_effectiveModel.isEmpty) return '还没有配对话模型';
    final embedError = _agent.retrieval.lastEmbeddingError;
    // 指路到分工表：嵌入模型的入口从这个菜单搬走了，只说"不可用"
    // 的话用户得自己找一遍。
    if (embedError != null) return '嵌入检索不可用（设置 → 模型分工）：$embedError';
    if (!_effectiveSendImagesInline &&
        !widget.channels.channels.any((c) => c.canDescribeImages)) {
      return '当前渠道不认图，也没指图片转文字模型 —— 现在发不了图';
    }
    return null;
  }

  Future<void> _showComposerMenu() async {
    await showAnchoredMenu<void>(
      context: context,
      anchor: _plusKey,
      builder: (menuContext, refresh) => <Widget>[
        if (_composerWarning case final warning?) MenuNotice(text: warning),
        MenuAction(
          icon: Icons.photo_library_outlined,
          label: '从相册选择',
          onTap: () {
            Navigator.pop(menuContext);
            _pickImages(camera: false);
          },
        ),
        MenuAction(
          icon: Icons.photo_camera_outlined,
          label: '拍一张',
          onTap: () {
            Navigator.pop(menuContext);
            _pickImages(camera: true);
          },
        ),
        // 模型 / 思考强度 / 温度这三项都是**这个会话自己的**，改了不动别的
        // 会话（见 settings/thread_prefs.dart）。设置页里的同名项现在只决定
        // 新会话从哪儿起步。
        MenuAction(
          icon: Icons.auto_awesome,
          label: '对话模型',
          detail: _effectiveSourceLabel.isEmpty ? '还没配' : _effectiveSourceLabel,
          onTap: () {
            Navigator.pop(menuContext);
            _pickModel();
          },
        ),
        // 思考强度在这里而不是只在设置里：它是按问题变的 ——「这题难，
        // 多想会儿」是发送前那一刻的决定，而设置页隔着三层导航，走到那里
        // 的时候人已经忘了要问什么了。
        MenuAction(
          icon: Icons.speed_outlined,
          label: '思考强度',
          detail: '${_effectiveThinking.label} · 只对会思考的模型有效',
          onTap: () async {
            await _pickThinkingEffort();
            refresh();
          },
        ),
        MenuAction(
          icon: Icons.thermostat_outlined,
          label: '温度',
          detail: '${_effectiveTemperature.toStringAsFixed(1)} · 越高越发散',
          onTap: () async {
            await _pickTemperature();
            refresh();
          },
        ),
        MenuAction(
          icon: Icons.tune,
          label: '极客设置',
          detail: _samplingSummary(),
          onTap: () {
            Navigator.pop(menuContext);
            _editSampling();
          },
        ),
      ],
    );
    if (mounted) setState(() {});
  }

  /// 顶栏那个终端图标的二级菜单。
  ///
  /// 「终端模式」和「审批档位」原来摆在输入框的 `+` 里。搬到这儿是因为它们
  /// 和 `+` 里其余几项**根本不是一类东西**：那几项是"这条消息怎么发"
  /// （加图、换模型、想多久），而这两项是"模型手里有没有工具、动手前问不问"
  /// —— 一个会话级的开关，不是一次发送的参数。
  ///
  /// 而且顶栏那个终端图标本来就是它们的自然位置：图标亮着 = 模型手里有工具，
  /// 点开就是那件事的全部设置。原来点它只能跳到终端页面，一个纯粹的
  /// "看一眼"入口占着屏幕上最显眼的位置之一。
  Future<void> _showTerminalMenu() async {
    await showAnchoredMenu<void>(
      context: context,
      anchor: _terminalKey,
      builder: (menuContext, refresh) {
        final t = context.chat;
        final yolo = _agent.mode == ApprovalMode.yolo;
        return <Widget>[
          MenuAction(
            icon:
                _agent.terminalMode ? Icons.terminal : Icons.terminal_outlined,
            label: '终端模式',
            detail: _agent.terminalMode
                ? '模型可以在 ${_distro?.distro.displayName ?? '沙箱'} 里执行命令'
                : !_effectiveCapability.tools
                    // 说清是"哪个模型"而不是只说不支持：用户随时在换模型，
                    // 不点名的话他不知道该去改哪一条。
                    ? '「${_effectiveModel.isEmpty ? '当前模型' : _effectiveModel}」'
                        '被标记为不支持工具调用'
                    : _distro == null
                        ? '开启后会先装一个 Linux 基座（约 3–30MB）'
                        : '普通聊天，模型没有任何工具',
            trailing: Switch(
              value: _agent.terminalMode,
              onChanged: (on) async {
                // 装基座会推一个整页出来，菜单得先让开。
                if (on && _distro == null) Navigator.pop(menuContext);
                await _setTerminalMode(on);
                refresh();
              },
            ),
            onTap: () async {
              final on = !_agent.terminalMode;
              if (on && _distro == null) Navigator.pop(menuContext);
              await _setTerminalMode(on);
              refresh();
            },
          ),
          // 审批档位只在终端模式下有意义：聊天模式没有工具可审批。
          if (_agent.terminalMode)
            MenuAction(
              icon: yolo ? Icons.gpp_maybe : Icons.shield_outlined,
              label: '审批档位',
              detail: _approvalLabels[_agent.mode] ?? '',
              tone: yolo ? t.tintError : null,
              onTap: () async {
                final picked = await showModalBottomSheet<ApprovalMode>(
                  context: menuContext,
                  backgroundColor: t.bgPrimary,
                  builder: (pickerContext) => SafeArea(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        for (final entry in _approvalLabels.entries)
                          ListTile(
                            leading: Icon(entry.key == _agent.mode
                                ? Icons.radio_button_checked
                                : Icons.radio_button_unchecked),
                            title: Text(entry.value),
                            onTap: () =>
                                Navigator.pop(pickerContext, entry.key),
                          ),
                      ],
                    ),
                  ),
                );
                if (picked != null) {
                  // 写回设置而不是只改 _agent —— 这个入口和设置页里的
                  // 「审批档位」是同一件事，两份状态迟早会不一致。
                  await widget.settings.setApprovalMode(picked);
                  refresh();
                }
              },
            ),
          // 跳转排在最后。它是「去看一眼」，而上面两项是「怎么跑」——
          // 后者才是用户点开这个菜单十有八九要做的事。
          MenuAction(
            icon: Icons.open_in_full_rounded,
            label: '打开终端',
            detail: _distro == null
                ? '降级模式 —— 只有 Android 自带的 sh'
                : '手动敲命令，和模型共用同一个 ${_distro!.distro.displayName}',
            onTap: () {
              Navigator.pop(menuContext);
              unawaited(_switchTab(1));
            },
          ),
        ];
      },
    );
    if (mounted) setState(() {});
  }
}

/// 消息列表里的一行。
///
/// 四种：日期分隔（[day] 非空）、摘要分隔线（[summaryCovered] > 0）、
/// 一条消息（[index] >= 0）、流式输出那条（[streaming] 非空）。
class _ChatRow {
  final DateTime? day;
  final int index;
  final String? streaming;
  final bool lastInGroup;
  final bool firstInGroup;

  /// 正在跑的那个工具。跑完之后它会变成 `_visible` 里的一条 tool 消息，
  /// 由 [_ChatRow.message] 接手 —— 所以这一种只在命令跑着的时候存在。
  final ({String title, DateTime startedAt})? runningTool;

  /// 这一行是摘要分隔线时，线以上被覆盖的消息条数。0 = 不是这种行。
  final int summaryCovered;

  const _ChatRow.date(this.day)
      : index = -1,
        streaming = null,
        runningTool = null,
        summaryCovered = 0,
        lastInGroup = true,
        firstInGroup = true;

  const _ChatRow.summary(this.summaryCovered)
      : day = null,
        index = -1,
        streaming = null,
        runningTool = null,
        lastInGroup = true,
        firstInGroup = true;

  const _ChatRow.message(this.index, this.lastInGroup, this.firstInGroup)
      : day = null,
        streaming = null,
        runningTool = null,
        summaryCovered = 0;

  const _ChatRow.streaming(this.streaming)
      : day = null,
        index = -1,
        runningTool = null,
        summaryCovered = 0,
        lastInGroup = true,
        firstInGroup = false;

  const _ChatRow.runningTool(this.runningTool)
      : day = null,
        index = -1,
        streaming = null,
        summaryCovered = 0,
        lastInGroup = true,
        firstInGroup = false;
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

/// 等一会儿才出现的转圈。
///
/// 读一页消息通常几十毫秒。在那点时间里闪一下转圈**比什么都不显示更差** ——
/// 用户看到的是一次没有内容的闪烁，而不是"在加载"。所以先什么都不画，
/// 拖过这个门槛还没好，才淡进来。
///
/// 淡进来而不是"啪"地出现，理由一样：突然出现的东西会被眼睛当成故障。
class _DelayedSpinner extends StatefulWidget {
  const _DelayedSpinner();

  @override
  State<_DelayedSpinner> createState() => _DelayedSpinnerState();
}

class _DelayedSpinnerState extends State<_DelayedSpinner> {
  static const _threshold = Duration(milliseconds: 220);

  bool _show = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(_threshold, () {
      if (mounted) setState(() => _show = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedOpacity(
        opacity: _show ? 1 : 0,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        child: SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(
            strokeWidth: 2.4,
            color: context.chat.brand,
          ),
        ),
      );
}
