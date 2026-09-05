import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../agent/agent_loop.dart';
import '../context/overflow_manager.dart';
import '../llm/llm_client.dart';
import '../llm/thinking_effort.dart';
import '../llm/vision.dart';
import 'channel_store.dart';
import '../sandbox/sandbox_session.dart';

class ProviderPreset {
  const ProviderPreset({
    required this.name,
    required this.baseUrl,
    required this.models,
    this.apiFormat = 'openAI',
  });

  final String name;
  final String apiFormat;
  final String baseUrl;
  final List<String> models;
}

const providerPresets = <ProviderPreset>[
  ProviderPreset(
    name: 'OpenAI',
    baseUrl: 'https://api.openai.com/v1',
    models: <String>['gpt-5', 'gpt-5-mini'],
  ),
  ProviderPreset(
    name: 'Anthropic',
    apiFormat: 'anthropic',
    baseUrl: 'https://api.anthropic.com',
    models: <String>['claude-sonnet-4-6', 'claude-opus-4-6'],
  ),
  ProviderPreset(
    // 走 OpenAI 兼容层而不是 Gemini 原生 REST：兼容层的请求体、流式解析和
    // 工具调用全都能复用现成的那条路径。
    //
    // 地址必须到 `/v1beta/openai` 为止 —— 从 Google 文档里复制来的
    // `.../v1beta/models/<model>:generateContent` 是原生端点，填进来必 404。
    name: 'Google Gemini（API Key）',
    // 原生层而不是 OpenAI 兼容层：兼容层接进来省事，但**拿不到联网搜索**。
    apiFormat: 'geminiNative',
    baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
    models: <String>['gemini-flash-latest', 'gemini-2.5-pro'],
  ),
  ProviderPreset(
    name: 'DeepSeek',
    baseUrl: 'https://api.deepseek.com',
    models: <String>['deepseek-chat', 'deepseek-reasoner'],
  ),
  ProviderPreset(
    name: '智谱 GLM',
    baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
    models: <String>['glm-4.6', 'glm-4.5-flash'],
  ),
  ProviderPreset(
    name: 'Kimi（月之暗面）',
    baseUrl: 'https://api.moonshot.cn/v1',
    models: <String>['kimi-k2.5', 'kimi-k2-thinking'],
  ),
  ProviderPreset(
    name: '硅基流动',
    baseUrl: 'https://api.siliconflow.cn/v1',
    models: <String>['deepseek-ai/DeepSeek-V3.2', 'Qwen/Qwen3-Coder'],
  ),
  ProviderPreset(
    name: '自定义兼容接口',
    baseUrl: 'http://127.0.0.1:11434/v1',
    models: <String>[],
  ),
];

/// 聊天区的内置壁纸。自定义图片单独由 [SettingsStore.chatWallpaperPath]
/// 表示；清掉图片后会回到用户最后选中的这一个预设。
enum ChatWallpaperPreset {
  classic,
  aurora,
  sunset,
  midnight,
}

/// 聊天应用的整体明暗风格。默认使用参考图里的 Nekogram 夜间色板；
/// 仍保留跟随系统和明亮模式，避免把外观选择绑死在 Android 系统主题上。
enum ChatColorStyle {
  nekogramNight,
  followSystem,
  light,
}

/// 悬浮输入区的材质。数值参数（模糊和不透明度）与材质分开存，切换回来时
/// 用户调好的手感仍然保留。
enum ChatComposerEffect {
  solid,
  frosted,
  liquid,
  outline,
}

class SettingsStore extends ChangeNotifier {
  /// 内置皮肤和未来外部皮肤共同使用的稳定 ID。皮肤 catalog 只认 ID，
  /// SharedPreferences 不保存显示名，避免改名后用户的选择失效。
  static const defaultChatSkinId = 'nekogram';

  SettingsStore._(
    this._temperature,
    this._streamOutput,
    this._terminalModeDefault,
    this._imageMode,
    this._systemPrompt,
    this._modelsByChannel,
    this._legacyModels,
    this._sandboxLevel,
    this._approvalMode,
    this._overflowTrigger,
    this._messageThreshold,
    this._tokenThreshold,
    this._chatColorStyle,
    this._chatSkinId,
    this._chatSkinSuspended,
    this._chatWallpaperPreset,
    this._chatWallpaperPath,
    this._chatWallpaperDim,
    this._assistantAvatarPath,
    this._userAvatarPath,
    this._showMessageAvatars,
    this._showTokenUsage,
    this._chatComposerEffect,
    this._chatComposerBlur,
    this._chatComposerOpacity,
    this._prefs,
  );

  static const _prefix = 'burrow.llm.';
  static const _keyTerminalDefault = 'burrow.terminalMode.default';
  static const _keyLastThread = 'burrow.ui.lastThread';
  static const _keyBatteryHint = 'burrow.ui.batteryHintShown';
  static const _keyImageMode = 'burrow.llm.imageMode';
  static const _keySystemPrompt = 'burrow.llm.systemPrompt';
  static const _keyThinkingEffort = 'burrow.llm.thinkingEffort';
  static const _keyAllowedCommands = 'burrow.sandbox.allowedCommands';
  static const _keyCachedModels = 'burrow.llm.cachedModels';
  static const _keyModelsByChannel = 'burrow.llm.modelsByChannel';
  static const _keySandboxLevel = 'burrow.sandbox.level';
  static const _keyApprovalMode = 'burrow.sandbox.approval';
  static const _keyOverflowTrigger = 'burrow.context.trigger';
  static const _keyMessageThreshold = 'burrow.context.messageThreshold';
  static const _keyTokenThreshold = 'burrow.context.tokenThreshold';
  static const _keyChatColorStyle = 'burrow.appearance.colorStyle';
  static const _keyChatSkinId = 'burrow.appearance.skinId';
  static const _keyChatSkinSuspended = 'burrow.appearance.skinSuspended';
  static const _keyChatWallpaperPreset = 'burrow.appearance.wallpaperPreset';
  static const _keyChatWallpaperPath = 'burrow.appearance.wallpaperPath';
  static const _keyChatWallpaperDim = 'burrow.appearance.wallpaperDim';
  static const _keyAssistantAvatarPath =
      'burrow.appearance.assistantAvatarPath';
  static const _keyUserAvatarPath = 'burrow.appearance.userAvatarPath';
  static const _keyShowMessageAvatars = 'burrow.appearance.showMessageAvatars';
  static const _keyShowTokenUsage = 'burrow.appearance.showTokenUsage';
  static const _keyChatComposerEffect = 'burrow.appearance.composerEffect';
  static const _keyChatComposerBlur = 'burrow.appearance.composerBlur';
  static const _keyChatComposerOpacity = 'burrow.appearance.composerOpacity';

  /// 摘要阈值的下限。定得太低会变成「每说两句就摘要一次」——
  /// 摘要本身要发一次请求，比它省下来的那点 token 贵得多。
  static const minMessageThreshold = 6;
  static const minTokenThreshold = 1000;

  double _temperature;
  bool _streamOutput;
  bool _terminalModeDefault;

  /// 渠道列表。由 main 注入 —— [config] 是它的投影。
  ///
  /// 为什么不让 SettingsStore 自己存一份 baseUrl/key/model：那样就有两份
  /// 真相了。渠道是唯一的来源，这里只负责把「当前那个」加上生成参数
  /// 摊成下游要的 [LlmConfig]。
  ChannelStore? _channels;
  ImageMode _imageMode;
  String _systemPrompt;

  /// 渠道 id → 上一次从**那个渠道**拉回来的模型列表。
  ///
  /// 曾经是一份全局列表，那是个会让人花错钱的设计：在 A 渠道拉一次，
  /// 切到 B 渠道，选择器里列的还是 A 的模型 —— 挑一个发出去，
  /// 要么 404，要么更糟，B 那边刚好有个同名模型于是照常计费。
  /// 模型列表属于渠道，就得跟着渠道存。
  final Map<String, List<String>> _modelsByChannel;

  /// 迁移用：旧版那份全局列表。[bindChannels] 里认领给当前渠道后清掉。
  List<String>? _legacyModels;
  SandboxLevel _sandboxLevel;
  ApprovalMode _approvalMode;
  OverflowTrigger _overflowTrigger;
  int _messageThreshold;
  int _tokenThreshold;
  ChatColorStyle _chatColorStyle;
  String _chatSkinId;
  bool _chatSkinSuspended;
  ChatWallpaperPreset _chatWallpaperPreset;
  String _chatWallpaperPath;
  double _chatWallpaperDim;
  String _assistantAvatarPath;
  String _userAvatarPath;
  bool _showMessageAvatars;
  bool _showTokenUsage;
  ChatComposerEffect _chatComposerEffect;
  double _chatComposerBlur;
  double _chatComposerOpacity;
  final SharedPreferences? _prefs;

  /// 当前渠道 + 生成参数。没有任何渠道时是 [LlmConfig.empty]。
  LlmConfig get config {
    final channels = _channels;
    if (channels == null) return LlmConfig.empty;
    return channels.configFor(
      channels.active,
      temperature: _temperature,
      streamOutput: _streamOutput,
      sendImagesInline: sendImagesInline,
      thinkingEffort: _thinkingEffort,
    );
  }

  ChannelStore? get channels => _channels;

  double get temperature => _temperature;
  bool get streamOutput => _streamOutput;

  /// 让模型想多久。默认「自动」= 一个参数都不发。
  ///
  /// 全局而不是跟着渠道走：它和 temperature 是同一类东西 —— "我希望模型
  /// 怎么答"，跟人走，不跟接入点走。各协议怎么翻译它是 [ThinkingEffort]
  /// 自己的事。
  ThinkingEffort get thinkingEffort => _thinkingEffort;
  ThinkingEffort _thinkingEffort = ThinkingEffort.auto;

  /// 用户在审批弹窗里点过"以后允许"的命令前缀。
  ///
  /// **这份名单是用户自己的，随时能在设置里删。** 它存在的前提是：关掉
  /// 沙箱之后每条命令都要问，而反复问同一条命令只会把人逼得去开 yolo，
  /// 那反而更危险。
  List<String> get allowedCommands => List.unmodifiable(_allowedCommands);
  List<String> _allowedCommands = <String>[];

  Future<void> allowCommand(String prefix) async {
    final key = prefix.trim();
    if (key.isEmpty || _allowedCommands.contains(key)) return;
    _allowedCommands = <String>[..._allowedCommands, key];
    notifyListeners();
    await _prefs?.setStringList(_keyAllowedCommands, _allowedCommands);
  }

  Future<void> revokeCommand(String prefix) async {
    if (!_allowedCommands.contains(prefix)) return;
    _allowedCommands =
        _allowedCommands.where((entry) => entry != prefix).toList();
    notifyListeners();
    await _prefs?.setStringList(_keyAllowedCommands, _allowedCommands);
  }

  Future<void> setThinkingEffort(ThinkingEffort value) async {
    if (_thinkingEffort == value) return;
    _thinkingEffort = value;
    notifyListeners();
    await _prefs?.setString(_keyThinkingEffort, value.storage);
  }

  /// 接上渠道列表。渠道一变就跟着通知 —— 下游只订阅了 SettingsStore，
  /// 不接这一条的话换渠道不会触发任何刷新。
  void bindChannels(ChannelStore channels) {
    _channels = channels;
    channels.addListener(_onChannelsChanged);
    unawaited(_claimLegacyModels());
    notifyListeners();
  }

  void _onChannelsChanged() {
    unawaited(_claimLegacyModels());
    unawaited(_pruneModels());
    notifyListeners();
  }

  /// 把旧版那份全局模型列表认领给当前渠道。
  ///
  /// 迁移过来的时候只有一个渠道，那份列表当初就是从它拉的 —— 认领是对的。
  /// 但只认领一次：之后再有第二个渠道，它得自己拉。
  Future<void> _claimLegacyModels() async {
    final legacy = _legacyModels;
    if (legacy == null) return;
    // 渠道迁移比 bindChannels 晚一步（main 里先 bind、再 migrateFrom），
    // 所以这一刻很可能一个渠道都还没有。留着下次渠道变动再认领，
    // 在这里直接丢掉的话，升级后第一次打开选择器会是空的。
    final id = _channels?.activeId;
    if (id == null) return;
    _legacyModels = null;
    if (legacy.isNotEmpty && !_modelsByChannel.containsKey(id)) {
      _modelsByChannel[id] = List<String>.from(legacy);
      await _persistModels();
    }
    await _prefs?.remove(_keyCachedModels);
  }

  /// 丢掉已删渠道留下的模型列表。
  ///
  /// 不清的话它们会一直躺在 prefs 里；更要紧的是 [ChannelStore.newId] 万一
  /// 撞了 id，新渠道一打开就会显示上一个渠道的模型 —— 又回到那个花错钱的坑。
  Future<void> _pruneModels() async {
    final channels = _channels;
    if (channels == null || _modelsByChannel.isEmpty) return;
    final alive = {for (final c in channels.channels) c.id};
    final dead = _modelsByChannel.keys.where((id) => !alive.contains(id));
    if (dead.isEmpty) return;
    for (final id in dead.toList()) {
      _modelsByChannel.remove(id);
    }
    await _persistModels();
  }

  static Map<String, List<String>> _decodeModels(String? raw) {
    if (raw == null || raw.isEmpty) return <String, List<String>>{};
    try {
      final decoded = jsonDecode(raw) as Map<String, Object?>;
      return <String, List<String>>{
        for (final entry in decoded.entries)
          entry.key: <String>[
            for (final m in entry.value! as List) m! as String,
          ],
      };
    } catch (_) {
      // 缓存坏了重新拉一次就有了，不值得让 app 起不来。
      return <String, List<String>>{};
    }
  }

  Future<void> _persistModels() =>
      _prefs?.setString(_keyModelsByChannel, jsonEncode(_modelsByChannel)) ??
      Future<void>.value();

  /// 全局系统提示词。空 = 只用内置的那份。
  ///
  /// 会话可以有自己的一份把它盖掉（见 [ChatThread.systemPrompt]）——
  /// 全局的是"我一般想要的样子"，会话级的是"这一次不一样"。
  String get systemPrompt => _systemPrompt;

  Future<void> setSystemPrompt(String value) async {
    if (_systemPrompt == value) return;
    _systemPrompt = value;
    notifyListeners();
    await _prefs?.setString(_keySystemPrompt, value);
  }

  /// 图片怎么送到模型手里。
  ImageMode get imageMode => _imageMode;

  /// 这一刻要不要把图直接塞进请求。
  ///
  /// 两件事共用一个开关：模型认不认图（按**当前模型**查的，不是渠道），
  /// 以及用户有没有强制走前置（省钱）。**强制前置时即使模型认图也不直发**
  /// —— 那正是这个选项存在的意义，不然它和 auto 就没区别了。
  bool get sendImagesInline => switch (_imageMode) {
        ImageMode.native => true,
        ImageMode.preprocess => false,
        ImageMode.auto => activeCapability.vision,
      };

  /// 当前渠道 + 当前模型的能力。解析（手动 > 自动 > 渠道默认）在
  /// ChannelStore 里做 —— 只有它同时拿得到渠道配置和 models.dev 那张表。
  ResolvedCapability get activeCapability =>
      _channels?.activeCapability ??
      const ResolvedCapability(vision: false, tools: true, search: false);

  /// 当前模型支持工具调用。终端模式靠它决定能不能开。
  bool get supportsTools => activeCapability.tools;

  Future<void> setImageMode(ImageMode mode) async {
    if (_imageMode == mode) return;
    _imageMode = mode;
    notifyListeners();
    await _prefs?.setString(_keyImageMode, mode.name);
  }

  /// 当前渠道上一次拉回来的模型 id 列表。
  ///
  /// 缓存下来是为了让底部那条快速切换器**一打开就有东西**。每次都现拉的话，
  /// 切个模型要先等一次网络往返，那就不叫快速切换了。
  List<String> get cachedModels => modelsOf(_channels?.activeId);

  /// 某个渠道缓存下来的模型列表。没拉过是空的 —— 选择器据此自动拉一次。
  List<String> modelsOf(String? channelId) => List.unmodifiable(
      (channelId == null ? null : _modelsByChannel[channelId]) ??
          const <String>[]);

  /// 当前来源的署名，形如 `提供商 · 模型名`。
  /// Base URL 是连接细节，不应在聊天界面里反复暴露。
  String get sourceLabel {
    final model = config.model;
    final channels = _channels;
    final active = channels?.active;
    if (active == null) return model;
    return model.isEmpty
        ? active.providerLabel
        : '${active.providerLabel} · $model';
  }

  /// 命令的执行边界。真的会进 argv/env（见 SandboxSession.buildArgv），
  /// 不是一个只给人看的标签。
  SandboxLevel get sandboxLevel => _sandboxLevel;

  /// 新会话的审批档位。聊天页顶部的档位按钮会写回这里 ——
  /// 两个地方显示同一件事，就不该有两份状态。
  ApprovalMode get approvalMode => _approvalMode;

  OverflowTrigger get overflowTrigger => _overflowTrigger;
  int get messageThreshold => _messageThreshold;
  int get tokenThreshold => _tokenThreshold;

  ChatColorStyle get chatColorStyle => _chatColorStyle;
  String get chatSkinId => _chatSkinId;

  /// 逃生舱：为真时忽略当前皮肤，整个界面回到内置外观。
  ///
  /// 持久化而不是只存在内存里 —— 一个把界面搞坏的皮肤，重启后要是又
  /// 生效了，用户就得在看不见按钮的情况下再摸一次同样的操作。
  bool get chatSkinSuspended => _chatSkinSuspended;

  ChatWallpaperPreset get chatWallpaperPreset => _chatWallpaperPreset;
  String get chatWallpaperPath => _chatWallpaperPath;
  double get chatWallpaperDim => _chatWallpaperDim;
  String get assistantAvatarPath => _assistantAvatarPath;
  String get userAvatarPath => _userAvatarPath;
  bool get showMessageAvatars => _showMessageAvatars;

  /// 在气泡里显示 token 用量。
  ///
  /// 默认开：用的是自己的 API key，「这一句花了多少」是每次发送都该看得见
  /// 的信息，而不是要翻账单才知道的事。
  bool get showTokenUsage => _showTokenUsage;
  ChatComposerEffect get chatComposerEffect => _chatComposerEffect;
  double get chatComposerBlur => _chatComposerBlur;
  double get chatComposerOpacity => _chatComposerOpacity;

  /// 新建会话时终端模式的初值 = 上一次的选择。
  ///
  /// 每个会话自己存开关（见 ChatThread.terminalMode），但新会话总得有个
  /// 起点。固定成「关」的话，主要拿它当 Agent 用的人每开一个新对话都要
  /// 重勾一次；跟着上次走则两类用户都只在真正切换用途时动手。
  bool get terminalModeDefault => _terminalModeDefault;

  static Future<SettingsStore> load() async {
    final prefs = await SharedPreferences.getInstance();
    final store = SettingsStore._(
      prefs.getDouble('${_prefix}temperature') ?? 0.3,
      prefs.getBool('${_prefix}streamOutput') ?? true,
      prefs.getBool(_keyTerminalDefault) ?? false,
      _byName(ImageMode.values, prefs.getString(_keyImageMode), ImageMode.auto),
      prefs.getString(_keySystemPrompt) ?? '',
      _decodeModels(prefs.getString(_keyModelsByChannel)),
      prefs.getStringList(_keyCachedModels),
      _byName(
          SandboxLevel.values,
          prefs.getString(_keySandboxLevel),
          // 默认放通网络。断网档看着更安全，实际后果是 Agent 一装东西就
          // 卡住：apt/pip/git 全部要网，而沙箱本来就够不着实体机 ——
          // 拦在这里换不到安全，只换来"什么都干不成"。
          SandboxLevel.workspaceWriteNetwork),
      _byName(ApprovalMode.values, prefs.getString(_keyApprovalMode),
          ApprovalMode.onRequest),
      _byName(OverflowTrigger.values, prefs.getString(_keyOverflowTrigger),
          OverflowTrigger.either),
      prefs.getInt(_keyMessageThreshold) ?? 30,
      prefs.getInt(_keyTokenThreshold) ?? 4000,
      _byName(
        ChatColorStyle.values,
        prefs.getString(_keyChatColorStyle),
        ChatColorStyle.nekogramNight,
      ),
      prefs.getString(_keyChatSkinId) ?? defaultChatSkinId,
      prefs.getBool(_keyChatSkinSuspended) ?? false,
      _byName(
        ChatWallpaperPreset.values,
        prefs.getString(_keyChatWallpaperPreset),
        ChatWallpaperPreset.classic,
      ),
      prefs.getString(_keyChatWallpaperPath) ?? '',
      (prefs.getDouble(_keyChatWallpaperDim) ?? 0.0).clamp(0.0, 0.6).toDouble(),
      prefs.getString(_keyAssistantAvatarPath) ?? '',
      prefs.getString(_keyUserAvatarPath) ?? '',
      prefs.getBool(_keyShowMessageAvatars) ?? true,
      prefs.getBool(_keyShowTokenUsage) ?? true,
      _byName(
        ChatComposerEffect.values,
        prefs.getString(_keyChatComposerEffect),
        ChatComposerEffect.liquid,
      ),
      (prefs.getDouble(_keyChatComposerBlur) ?? 20.0)
          .clamp(0.0, 30.0)
          .toDouble(),
      (prefs.getDouble(_keyChatComposerOpacity) ?? 0.68)
          .clamp(0.25, 1.0)
          .toDouble(),
      prefs,
    );
    store._thinkingEffort =
        ThinkingEffort.fromStorage(prefs.getString(_keyThinkingEffort));
    store._allowedCommands =
        prefs.getStringList(_keyAllowedCommands) ?? <String>[];
    return store;
  }

  /// 按 name 反查枚举，认不出来就用默认值。
  ///
  /// 用 name 而不是 index 存：index 会被「往枚举中间插一个值」这种
  /// 完全正常的改动悄悄改掉含义 —— 用户的「只读」会变成「关闭沙箱」。
  static T _byName<T extends Enum>(List<T> values, String? name, T fallback) {
    for (final v in values) {
      if (v.name == name) return v;
    }
    return fallback;
  }

  /// 上次打开的是哪个会话。null = 上次停在新对话上。
  ///
  /// **这条存在是因为 app 会被系统回收。** 切出去几分钟再回来，Android
  /// 很可能已经把进程杀了；不记这一条的话，回来永远是一个空白的「新对话」
  /// —— 用户看到的是"用着用着自己退出去了"，而聊天记录其实一条没少，
  /// 只是没人把他送回原来那间屋子。
  ///
  /// 不进构造函数、也不 notifyListeners：它只在启动那一刻读一次，
  /// 之后就是纯粹的写入。
  String? get lastThreadId => _prefs?.getString(_keyLastThread);

  Future<void> setLastThreadId(String? id) async {
    if (id == null) {
      await _prefs?.remove(_keyLastThread);
      return;
    }
    await _prefs?.setString(_keyLastThread, id);
  }

  /// 「后台可能被冻住」那句提示是不是已经说过了。
  ///
  /// **只说一次。** 它问的是"要不要让这个 app 一直在后台耗电"，反复问
  /// 只会把人逼到把整个 app 的通知和权限一起关掉；而且第一次说完之后，
  /// 设置里那一行一直在那儿，想开随时能开。
  bool get batteryHintShown => _prefs?.getBool(_keyBatteryHint) ?? false;

  Future<void> markBatteryHintShown() async {
    await _prefs?.setBool(_keyBatteryHint, true);
  }

  Future<void> setTemperature(double value) async {
    if (_temperature == value) return;
    _temperature = value;
    notifyListeners();
    await _prefs?.setDouble('${_prefix}temperature', value);
  }

  Future<void> setStreamOutput(bool value) async {
    if (_streamOutput == value) return;
    _streamOutput = value;
    notifyListeners();
    await _prefs?.setBool('${_prefix}streamOutput', value);
  }

  /// 记下**某个渠道**拉回来的模型列表。
  ///
  /// 必须带 channelId：拉取是异步的，拉的过程中用户完全可能已经切走了，
  /// 记到"当前渠道"上就会把 A 的列表安到 B 头上。
  Future<void> setModelsFor(String channelId, List<String> models) async {
    _modelsByChannel[channelId] = List<String>.from(models);
    notifyListeners();
    await _persistModels();
  }

  Future<void> setSandboxLevel(SandboxLevel level) async {
    if (_sandboxLevel == level) return;
    _sandboxLevel = level;
    notifyListeners();
    await _prefs?.setString(_keySandboxLevel, level.name);
  }

  Future<void> setApprovalMode(ApprovalMode mode) async {
    if (_approvalMode == mode) return;
    _approvalMode = mode;
    notifyListeners();
    await _prefs?.setString(_keyApprovalMode, mode.name);
  }

  Future<void> setContextLimits({
    OverflowTrigger? trigger,
    int? messageThreshold,
    int? tokenThreshold,
  }) async {
    final nextTrigger = trigger ?? _overflowTrigger;
    final nextMessages =
        (messageThreshold ?? _messageThreshold).clamp(minMessageThreshold, 200);
    final nextTokens =
        (tokenThreshold ?? _tokenThreshold).clamp(minTokenThreshold, 60000);
    if (nextTrigger == _overflowTrigger &&
        nextMessages == _messageThreshold &&
        nextTokens == _tokenThreshold) {
      return;
    }
    _overflowTrigger = nextTrigger;
    _messageThreshold = nextMessages;
    _tokenThreshold = nextTokens;
    notifyListeners();
    final prefs = _prefs;
    if (prefs == null) return;
    await Future.wait(<Future<bool>>[
      prefs.setString(_keyOverflowTrigger, nextTrigger.name),
      prefs.setInt(_keyMessageThreshold, nextMessages),
      prefs.setInt(_keyTokenThreshold, nextTokens),
    ]);
  }

  Future<void> setTerminalModeDefault(bool on) async {
    if (_terminalModeDefault == on) return;
    _terminalModeDefault = on;
    notifyListeners();
    await _prefs?.setBool(_keyTerminalDefault, on);
  }

  Future<void> setChatColorStyle(ChatColorStyle value) async {
    if (_chatColorStyle == value) return;
    _chatColorStyle = value;
    notifyListeners();
    await _prefs?.setString(_keyChatColorStyle, value.name);
  }

  Future<void> setChatSkinId(String value) async {
    final next = value.trim();
    if (next.isEmpty || _chatSkinId == next) return;
    _chatSkinId = next;
    notifyListeners();
    await _prefs?.setString(_keyChatSkinId, next);
  }

  Future<void> setChatSkinSuspended(bool value) async {
    if (_chatSkinSuspended == value) return;
    _chatSkinSuspended = value;
    notifyListeners();
    await _prefs?.setBool(_keyChatSkinSuspended, value);
  }

  Future<void> setShowTokenUsage(bool value) async {
    if (_showTokenUsage == value) return;
    _showTokenUsage = value;
    notifyListeners();
    await _prefs?.setBool(_keyShowTokenUsage, value);
  }

  Future<void> setChatWallpaperPreset(ChatWallpaperPreset preset) async {
    if (_chatWallpaperPreset == preset && _chatWallpaperPath.isEmpty) return;
    _chatWallpaperPreset = preset;
    _chatWallpaperPath = '';
    notifyListeners();
    final prefs = _prefs;
    if (prefs == null) return;
    await Future.wait(<Future<bool>>[
      prefs.setString(_keyChatWallpaperPreset, preset.name),
      prefs.remove(_keyChatWallpaperPath),
    ]);
  }

  Future<void> setChatWallpaperPath(String path) async {
    if (_chatWallpaperPath == path) return;
    _chatWallpaperPath = path;
    notifyListeners();
    if (path.isEmpty) {
      await _prefs?.remove(_keyChatWallpaperPath);
    } else {
      await _prefs?.setString(_keyChatWallpaperPath, path);
    }
  }

  Future<void> setChatWallpaperDim(double value) async {
    final next = value.clamp(0.0, 0.6).toDouble();
    if (_chatWallpaperDim == next) return;
    _chatWallpaperDim = next;
    notifyListeners();
    await _prefs?.setDouble(_keyChatWallpaperDim, next);
  }

  Future<void> setAssistantAvatarPath(String path) async {
    if (_assistantAvatarPath == path) return;
    _assistantAvatarPath = path;
    notifyListeners();
    if (path.isEmpty) {
      await _prefs?.remove(_keyAssistantAvatarPath);
    } else {
      await _prefs?.setString(_keyAssistantAvatarPath, path);
    }
  }

  Future<void> setUserAvatarPath(String path) async {
    if (_userAvatarPath == path) return;
    _userAvatarPath = path;
    notifyListeners();
    if (path.isEmpty) {
      await _prefs?.remove(_keyUserAvatarPath);
    } else {
      await _prefs?.setString(_keyUserAvatarPath, path);
    }
  }

  Future<void> setShowMessageAvatars(bool value) async {
    if (_showMessageAvatars == value) return;
    _showMessageAvatars = value;
    notifyListeners();
    await _prefs?.setBool(_keyShowMessageAvatars, value);
  }

  Future<void> setChatComposerEffect(ChatComposerEffect value) async {
    if (_chatComposerEffect == value) return;
    _chatComposerEffect = value;
    notifyListeners();
    await _prefs?.setString(_keyChatComposerEffect, value.name);
  }

  Future<void> setChatComposerBlur(double value) async {
    final next = value.clamp(0.0, 30.0).toDouble();
    if (_chatComposerBlur == next) return;
    _chatComposerBlur = next;
    notifyListeners();
    await _prefs?.setDouble(_keyChatComposerBlur, next);
  }

  Future<void> setChatComposerOpacity(double value) async {
    final next = value.clamp(0.25, 1.0).toDouble();
    if (_chatComposerOpacity == next) return;
    _chatComposerOpacity = next;
    notifyListeners();
    await _prefs?.setDouble(_keyChatComposerOpacity, next);
  }

  /// 只重置视觉项，不碰渠道、模型或沙箱配置。
  Future<void> resetChatAppearance() async {
    _chatColorStyle = ChatColorStyle.nekogramNight;
    _chatSkinId = defaultChatSkinId;
    _chatSkinSuspended = false;
    _chatWallpaperPreset = ChatWallpaperPreset.classic;
    _chatWallpaperPath = '';
    _chatWallpaperDim = 0;
    _assistantAvatarPath = '';
    _userAvatarPath = '';
    _showMessageAvatars = true;
    _showTokenUsage = true;
    _chatComposerEffect = ChatComposerEffect.liquid;
    _chatComposerBlur = 20;
    _chatComposerOpacity = 0.68;
    notifyListeners();

    final prefs = _prefs;
    if (prefs == null) return;
    await Future.wait(<Future<bool>>[
      prefs.remove(_keyChatColorStyle),
      prefs.remove(_keyChatSkinId),
      prefs.remove(_keyChatSkinSuspended),
      prefs.remove(_keyChatWallpaperPreset),
      prefs.remove(_keyChatWallpaperPath),
      prefs.remove(_keyChatWallpaperDim),
      prefs.remove(_keyAssistantAvatarPath),
      prefs.remove(_keyUserAvatarPath),
      prefs.remove(_keyShowMessageAvatars),
      prefs.remove(_keyShowTokenUsage),
      prefs.remove(_keyChatComposerEffect),
      prefs.remove(_keyChatComposerBlur),
      prefs.remove(_keyChatComposerOpacity),
    ]);
  }
}
