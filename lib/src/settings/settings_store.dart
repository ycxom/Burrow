import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../llm/llm_client.dart';

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
  SettingsStore._(this._config, this._provider, this._prefs, this._secure);

  static const _keyName = 'burrow.llm.apiKey';
  static const _prefix = 'burrow.llm.';

  LlmConfig _config;
  String _provider;
  final SharedPreferences? _prefs;
  final FlutterSecureStorage? _secure;

  LlmConfig get config => _config;
  String get provider => _provider;

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
      prefs,
      secure,
    );
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
