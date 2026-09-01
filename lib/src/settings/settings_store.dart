import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../agent/agent_loop.dart';
import '../context/overflow_manager.dart';
import '../llm/llm_client.dart';
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
  SettingsStore._(
    this._temperature,
    this._streamOutput,
    this._terminalModeDefault,
    this._embeddingModel,
    this._modelsByChannel,
    this._legacyModels,
    this._sandboxLevel,
    this._approvalMode,
    this._overflowTrigger,
    this._messageThreshold,
    this._tokenThreshold,
    this._chatColorStyle,
    this._chatWallpaperPreset,
    this._chatWallpaperPath,
    this._chatWallpaperDim,
    this._assistantAvatarPath,
    this._userAvatarPath,
    this._showMessageAvatars,
    this._chatComposerEffect,
    this._chatComposerBlur,
    this._chatComposerOpacity,
    this._prefs,
  );

  static const _prefix = 'burrow.llm.';
  static const _keyTerminalDefault = 'burrow.terminalMode.default';
  static const _keyEmbeddingModel = 'burrow.llm.embeddingModel';
  static const _keyCachedModels = 'burrow.llm.cachedModels';
  static const _keyModelsByChannel = 'burrow.llm.modelsByChannel';
  static const _keySandboxLevel = 'burrow.sandbox.level';
  static const _keyApprovalMode = 'burrow.sandbox.approval';
  static const _keyOverflowTrigger = 'burrow.context.trigger';
  static const _keyMessageThreshold = 'burrow.context.messageThreshold';
  static const _keyTokenThreshold = 'burrow.context.tokenThreshold';
  static const _keyChatColorStyle = 'burrow.appearance.colorStyle';
  static const _keyChatWallpaperPreset = 'burrow.appearance.wallpaperPreset';
  static const _keyChatWallpaperPath = 'burrow.appearance.wallpaperPath';
  static const _keyChatWallpaperDim = 'burrow.appearance.wallpaperDim';
  static const _keyAssistantAvatarPath =
      'burrow.appearance.assistantAvatarPath';
  static const _keyUserAvatarPath = 'burrow.appearance.userAvatarPath';
  static const _keyShowMessageAvatars = 'burrow.appearance.showMessageAvatars';
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
  String _embeddingModel;

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
  ChatWallpaperPreset _chatWallpaperPreset;
  String _chatWallpaperPath;
  double _chatWallpaperDim;
  String _assistantAvatarPath;
  String _userAvatarPath;
  bool _showMessageAvatars;
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
    );
  }

  ChannelStore? get channels => _channels;

  double get temperature => _temperature;
  bool get streamOutput => _streamOutput;

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

  /// 记忆检索用的嵌入模型。空 = 不启用，检索退回两路词法。
  ///
  /// 和对话模型分开存：它们通常**不是同一个模型**，而且嵌入模型一旦选定就
  /// 不该乱换 —— 换了之后旧向量和新向量不在同一个空间里，余弦没有意义。
  String get embeddingModel => _embeddingModel;

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
  ChatWallpaperPreset get chatWallpaperPreset => _chatWallpaperPreset;
  String get chatWallpaperPath => _chatWallpaperPath;
  double get chatWallpaperDim => _chatWallpaperDim;
  String get assistantAvatarPath => _assistantAvatarPath;
  String get userAvatarPath => _userAvatarPath;
  bool get showMessageAvatars => _showMessageAvatars;
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
    return SettingsStore._(
      prefs.getDouble('${_prefix}temperature') ?? 0.3,
      prefs.getBool('${_prefix}streamOutput') ?? true,
      prefs.getBool(_keyTerminalDefault) ?? false,
      prefs.getString(_keyEmbeddingModel) ?? '',
      _decodeModels(prefs.getString(_keyModelsByChannel)),
      prefs.getStringList(_keyCachedModels),
      _byName(SandboxLevel.values, prefs.getString(_keySandboxLevel),
          SandboxLevel.workspaceWrite),
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

  /// 换对话模型 —— 改的是**当前渠道**的模型。
  ///
  /// 底部快切改一次就落到渠道上，而不是另存一份「临时模型」：
  /// 那样渠道管理里显示的和实际在用的就对不上了。
  Future<void> setModel(String model) async {
    final channels = _channels;
    final active = channels?.active;
    if (channels == null || active == null || active.model == model) return;
    await channels.upsert(active.copyWith(model: model));
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

  Future<void> setEmbeddingModel(String model) async {
    if (_embeddingModel == model) return;
    _embeddingModel = model;
    notifyListeners();
    await _prefs?.setString(_keyEmbeddingModel, model);
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
    _chatWallpaperPreset = ChatWallpaperPreset.classic;
    _chatWallpaperPath = '';
    _chatWallpaperDim = 0;
    _assistantAvatarPath = '';
    _userAvatarPath = '';
    _showMessageAvatars = true;
    _chatComposerEffect = ChatComposerEffect.liquid;
    _chatComposerBlur = 20;
    _chatComposerOpacity = 0.68;
    notifyListeners();

    final prefs = _prefs;
    if (prefs == null) return;
    await Future.wait(<Future<bool>>[
      prefs.remove(_keyChatColorStyle),
      prefs.remove(_keyChatWallpaperPreset),
      prefs.remove(_keyChatWallpaperPath),
      prefs.remove(_keyChatWallpaperDim),
      prefs.remove(_keyAssistantAvatarPath),
      prefs.remove(_keyUserAvatarPath),
      prefs.remove(_keyShowMessageAvatars),
      prefs.remove(_keyChatComposerEffect),
      prefs.remove(_keyChatComposerBlur),
      prefs.remove(_keyChatComposerOpacity),
    ]);
  }
}
