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

class SettingsStore extends ChangeNotifier {
  SettingsStore._(
    this._temperature,
    this._streamOutput,
    this._terminalModeDefault,
    this._embeddingModel,
    this._cachedModels,
    this._sandboxLevel,
    this._approvalMode,
    this._overflowTrigger,
    this._messageThreshold,
    this._tokenThreshold,
    this._prefs,
  );

  static const _prefix = 'burrow.llm.';
  static const _keyTerminalDefault = 'burrow.terminalMode.default';
  static const _keyEmbeddingModel = 'burrow.llm.embeddingModel';
  static const _keyCachedModels = 'burrow.llm.cachedModels';
  static const _keySandboxLevel = 'burrow.sandbox.level';
  static const _keyApprovalMode = 'burrow.sandbox.approval';
  static const _keyOverflowTrigger = 'burrow.context.trigger';
  static const _keyMessageThreshold = 'burrow.context.messageThreshold';
  static const _keyTokenThreshold = 'burrow.context.tokenThreshold';

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
  List<String> _cachedModels;
  SandboxLevel _sandboxLevel;
  ApprovalMode _approvalMode;
  OverflowTrigger _overflowTrigger;
  int _messageThreshold;
  int _tokenThreshold;
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
    channels.addListener(notifyListeners);
    notifyListeners();
  }

  /// 记忆检索用的嵌入模型。空 = 不启用，检索退回两路词法。
  ///
  /// 和对话模型分开存：它们通常**不是同一个模型**，而且嵌入模型一旦选定就
  /// 不该乱换 —— 换了之后旧向量和新向量不在同一个空间里，余弦没有意义。
  String get embeddingModel => _embeddingModel;

  /// 上一次从服务端拉回来的模型 id 列表。
  ///
  /// 缓存下来是为了让底部那条快速切换器**一打开就有东西**。每次都现拉的话，
  /// 切个模型要先等一次网络往返，那就不叫快速切换了。
  List<String> get cachedModels => List.unmodifiable(_cachedModels);

  /// 命令的执行边界。真的会进 argv/env（见 SandboxSession.buildArgv），
  /// 不是一个只给人看的标签。
  SandboxLevel get sandboxLevel => _sandboxLevel;

  /// 新会话的审批档位。聊天页顶部的档位按钮会写回这里 ——
  /// 两个地方显示同一件事，就不该有两份状态。
  ApprovalMode get approvalMode => _approvalMode;

  OverflowTrigger get overflowTrigger => _overflowTrigger;
  int get messageThreshold => _messageThreshold;
  int get tokenThreshold => _tokenThreshold;

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
      prefs.getStringList(_keyCachedModels) ?? const <String>[],
      _byName(SandboxLevel.values, prefs.getString(_keySandboxLevel),
          SandboxLevel.workspaceWrite),
      _byName(ApprovalMode.values, prefs.getString(_keyApprovalMode),
          ApprovalMode.onRequest),
      _byName(OverflowTrigger.values, prefs.getString(_keyOverflowTrigger),
          OverflowTrigger.either),
      prefs.getInt(_keyMessageThreshold) ?? 30,
      prefs.getInt(_keyTokenThreshold) ?? 4000,
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

  Future<void> setCachedModels(List<String> models) async {
    _cachedModels = List<String>.from(models);
    notifyListeners();
    await _prefs?.setStringList(_keyCachedModels, _cachedModels);
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
}
