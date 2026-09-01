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
  SandboxLevel _sandboxLevel;
  ApprovalMode _approvalMode;
  OverflowTrigger _overflowTrigger;
  int _messageThreshold;
  int _tokenThreshold;
  final SharedPreferences? _prefs;
  final FlutterSecureStorage? _secure;

  LlmConfig get config => _config;
  String get provider => _provider;

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
        summaryModel: prefs.getString('${_prefix}summaryModel'),
        temperature: prefs.getDouble('${_prefix}temperature') ?? 0.3,
        streamOutput: prefs.getBool('${_prefix}streamOutput') ?? true,
      ),
      prefs.getString('${_prefix}provider') ?? 'OpenAI',
      prefs.getBool(_keyTerminalDefault) ?? false,
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
