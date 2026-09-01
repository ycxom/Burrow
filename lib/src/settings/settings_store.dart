import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../agent/agent_loop.dart';
import '../context/overflow_manager.dart';
import '../llm/llm_client.dart';
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
    this._config,
    this._provider,
    this._terminalModeDefault,
    this._embeddingModel,
    this._cachedModels,
    this._sandboxLevel,
    this._approvalMode,
    this._overflowTrigger,
    this._messageThreshold,
    this._tokenThreshold,
    this._prefs,
    this._secure,
  );

  static const _keyName = 'burrow.llm.apiKey';
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

  LlmConfig _config;
  String _provider;
  bool _terminalModeDefault;
  String _embeddingModel;
  List<String> _cachedModels;
  SandboxLevel _sandboxLevel;
  ApprovalMode _approvalMode;
  OverflowTrigger _overflowTrigger;
  int _messageThreshold;
  int _tokenThreshold;
  final SharedPreferences? _prefs;
  final FlutterSecureStorage? _secure;

  LlmConfig get config => _config;
  String get provider => _provider;

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
    const secure = FlutterSecureStorage();
    final key = await secure.read(key: _keyName) ?? '';
    return SettingsStore._(
      LlmConfig(
        apiFormat: prefs.getString('${_prefix}format') ?? 'openAI',
        baseUrl: prefs.getString('${_prefix}baseUrl') ?? '',
        apiKey: key,
        model: prefs.getString('${_prefix}model') ?? '',
        // 空串归一成 null：设置页留空存下来的是 ''，而"留空"的语义是
        // 「跟对话模型一样」，不是「模型名叫空字符串」。
        summaryModel: _emptyToNull(prefs.getString('${_prefix}summaryModel')),
        temperature: prefs.getDouble('${_prefix}temperature') ?? 0.3,
        streamOutput: prefs.getBool('${_prefix}streamOutput') ?? true,
      ),
      prefs.getString('${_prefix}provider') ?? 'OpenAI',
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
      secure,
    );
  }

  static String? _emptyToNull(String? v) =>
      (v == null || v.trim().isEmpty) ? null : v;

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

  /// 换对话模型。只动 model 那一项，其余配置原样留着。
  Future<void> setModel(String model) async {
    if (_config.model == model) return;
    _config = _config.copyWith(model: model);
    notifyListeners();
    await _prefs?.setString('${_prefix}model', model);
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

  Future<void> save(
      {required String provider, required LlmConfig config}) async {
    _provider = provider;
    _config = config;
    notifyListeners();
    final prefs = _prefs;
    if (prefs == null) return;
    await Future.wait(<Future<bool>>[
      prefs.setString('${_prefix}provider', provider),
      prefs.setString('${_prefix}format', config.apiFormat),
      prefs.setString('${_prefix}baseUrl', config.baseUrl),
      prefs.setString('${_prefix}model', config.model),
      prefs.setString('${_prefix}summaryModel', config.summaryModel ?? ''),
      prefs.setDouble('${_prefix}temperature', config.temperature),
      prefs.setBool('${_prefix}streamOutput', config.streamOutput),
    ]);
    await _secure?.write(key: _keyName, value: config.apiKey);
  }
}
