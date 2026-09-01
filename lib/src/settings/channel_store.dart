/// 渠道：一个可用的模型接入点。
///
/// 「渠道」把原来散在设置页里的 baseUrl / key / 协议 / 模型收成一个对象，
/// 并且允许存**多个**。理由是这三件事本来就是绑在一起变的 —— 换服务商时
/// 不可能只换 baseUrl 而留着上一家的 key，而原来的单份配置逼着用户每次
/// 手动改三个输入框，改错一个就是一串莫名其妙的报错。
///
/// 认证有两种，二选一：
///   - **API key**：手填的密钥，存在 secure storage 里。
///   - **OAuth 账号**：指向 [AccountStore] 里的某个账号。token 会过期，
///     所以这里只存"用哪个账号"，真正的 access_token 每次请求前现取。
///
/// 代理是**每个渠道各自的**：一个渠道走内网直连、另一个走梯子，是很常见的
/// 组合，全局代理会把前者也拖进去。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../llm/llm_client.dart';

@immutable
class Channel {
  /// 稳定 id。改名字不影响它，所以「当前渠道」的指向不会因为改名而丢。
  final String id;
  final String name;

  /// `openAI` 或 `anthropic`。
  final String apiFormat;
  final String baseUrl;
  final String model;
  final String? summaryModel;

  /// `host:port`。空 = 直连。
  final String? proxy;

  /// OAuth 账号绑定。两个都非空时走 OAuth，否则用 API key。
  final String? oauthProviderId;
  final String? oauthAccountId;

  const Channel({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.model,
    this.apiFormat = 'openAI',
    this.summaryModel,
    this.proxy,
    this.oauthProviderId,
    this.oauthAccountId,
  });

  /// 地址里的 `host[:port]`，认不出来时退回原串。
  ///
  /// 界面上光有渠道名是不够的：名字是用户自己起的，「测试」「新渠道2」
  /// 之类重名或含糊的叫法很常见，而**花的是谁的额度由地址决定**。
  /// 所以凡是要让用户确认"发给谁"的地方，都把 host 一起摆出来。
  String get host {
    final uri = Uri.tryParse(baseUrl);
    if (uri == null || uri.host.isEmpty) return baseUrl;
    return uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
  }

  bool get usesOAuth =>
      (oauthProviderId?.isNotEmpty ?? false) &&
      (oauthAccountId?.isNotEmpty ?? false);

  /// 只用于聊天界面署名，不暴露 Base URL。
  String get providerLabel {
    switch (oauthProviderId) {
      case 'openai_oauth':
        return 'ChatGPT';
      case 'xai_oauth':
        return 'xAI';
    }
    final inferred = providerLabelForBaseUrl(baseUrl);
    if (inferred != '自定义 API') return inferred;
    final trimmed = name.trim();
    return trimmed.isEmpty || Uri.tryParse(trimmed)?.hasScheme == true
        ? '自定义 API'
        : trimmed;
  }

  static String providerLabelForBaseUrl(String value) {
    final host = Uri.tryParse(value.trim())?.host.toLowerCase() ?? '';
    if (host == 'chatgpt.com') return 'ChatGPT';
    if (host == 'api.openai.com') return 'OpenAI';
    if (host == 'api.anthropic.com') return 'Anthropic';
    if (host.contains('deepseek.com')) return 'DeepSeek';
    if (host.contains('bigmodel.cn')) return 'GLM';
    if (host.contains('moonshot.cn') || host.contains('moonshot.ai')) {
      return 'Kimi';
    }
    if (host.contains('siliconflow')) return '硅基流动';
    if (host == 'api.x.ai') return 'xAI';
    if (host == 'localhost' || host == '127.0.0.1') return '本地模型';
    return '自定义 API';
  }

  /// secure storage 里放这个渠道 API key 的键。
  String get apiKeyStorageKey => '${ChannelStore.keyPrefix}$id';

  Channel copyWith({
    String? name,
    String? apiFormat,
    String? baseUrl,
    String? model,
    String? summaryModel,
    String? proxy,
    String? oauthProviderId,
    String? oauthAccountId,
    bool clearOAuth = false,
  }) =>
      Channel(
        id: id,
        name: name ?? this.name,
        apiFormat: apiFormat ?? this.apiFormat,
        baseUrl: baseUrl ?? this.baseUrl,
        model: model ?? this.model,
        summaryModel: summaryModel ?? this.summaryModel,
        proxy: proxy ?? this.proxy,
        oauthProviderId:
            clearOAuth ? null : (oauthProviderId ?? this.oauthProviderId),
        oauthAccountId:
            clearOAuth ? null : (oauthAccountId ?? this.oauthAccountId),
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'api_format': apiFormat,
        'base_url': baseUrl,
        'model': model,
        'summary_model': summaryModel,
        'proxy': proxy,
        'oauth_provider': oauthProviderId,
        'oauth_account': oauthAccountId,
      };

  static Channel fromJson(Map<String, Object?> j) => Channel(
        id: j['id']! as String,
        name: (j['name'] as String?) ?? '未命名渠道',
        apiFormat: (j['api_format'] as String?) ?? 'openAI',
        baseUrl: (j['base_url'] as String?) ?? '',
        model: (j['model'] as String?) ?? '',
        summaryModel: j['summary_model'] as String?,
        proxy: j['proxy'] as String?,
        oauthProviderId: j['oauth_provider'] as String?,
        oauthAccountId: j['oauth_account'] as String?,
      );
}

class ChannelStore extends ChangeNotifier {
  ChannelStore._(
      this._channels, this._activeId, this._keys, this._prefs, this._secure);

  static const keyPrefix = 'burrow.channel.key.';
  static const _listKey = 'burrow.channels';
  static const _activeKey = 'burrow.channels.active';

  final List<Channel> _channels;
  String? _activeId;

  /// 渠道 id → API key。启动时一次性读出来，之后在内存里用 ——
  /// 每次请求都去 secure storage 取会明显拖慢首字延迟。
  final Map<String, String> _keys;

  final SharedPreferences? _prefs;
  final FlutterSecureStorage? _secure;

  List<Channel> get channels => List.unmodifiable(_channels);

  Channel? get active {
    for (final c in _channels) {
      if (c.id == _activeId) return c;
    }
    return _channels.isEmpty ? null : _channels.first;
  }

  String? get activeId => active?.id;

  String apiKeyOf(Channel channel) => _keys[channel.id] ?? '';

  Channel? byId(String id) {
    for (final c in _channels) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// 不落盘的实例，只给单测用。
  ///
  /// prefs / secure storage 在单测环境里没有平台通道，而投影和增删改的
  /// 逻辑本身不依赖它们 —— 两个存储字段都是可空的，就是为了这个。
  @visibleForTesting
  factory ChannelStore.forTest({
    List<Channel> channels = const [],
    Map<String, String> keys = const {},
    String? activeId,
  }) =>
      ChannelStore._(
        List<Channel>.from(channels),
        activeId,
        Map<String, String>.from(keys),
        null,
        null,
      );

  /// 单调递增的后缀。
  ///
  /// 只用时间戳是**会撞的**：`microsecondsSinceEpoch` 的实际精度取决于平台，
  /// Windows 上是毫秒级，同一毫秒内连着生成就是同一个数。撞了的后果是
  /// [upsert] 把前一个渠道整个覆盖掉 —— 不报错，只是少了一个渠道。
  /// 单测里连生成 200 个只得到 3 个不同值，就是这么发现的。
  static int _seq = 0;

  static String newId() {
    _seq++;
    final now = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    return 'ch-$now-${_seq.toRadixString(36)}';
  }

  static Future<ChannelStore> load({
    SharedPreferences? prefs,
    FlutterSecureStorage? secure,
  }) async {
    final p = prefs ?? await SharedPreferences.getInstance();
    final s = secure ?? const FlutterSecureStorage();

    final channels = <Channel>[];
    try {
      final raw = p.getString(_listKey);
      if (raw != null && raw.isNotEmpty) {
        for (final entry in jsonDecode(raw) as List) {
          channels.add(Channel.fromJson(entry as Map<String, Object?>));
        }
      }
    } catch (_) {
      // 列表坏了当成没有渠道。抛出去会让 app 起不来。
    }

    final keys = <String, String>{};
    for (final c in channels) {
      try {
        final k = await s.read(key: c.apiKeyStorageKey);
        if (k != null && k.isNotEmpty) keys[c.id] = k;
      } catch (_) {
        // 单个 key 读不出来只影响那一个渠道。
      }
    }

    return ChannelStore._(channels, p.getString(_activeKey), keys, p, s);
  }

  /// 把旧版的单份配置搬成第一个渠道。
  ///
  /// 不迁的话，升级后用户会看到一个空的渠道列表，而设置其实都还在 prefs 里
  /// —— 那看起来就是"我的配置丢了"。
  Future<void> migrateFrom({
    required LlmConfig config,
    required String providerName,
  }) async {
    if (_channels.isNotEmpty) return;
    if (config.baseUrl.trim().isEmpty && config.model.trim().isEmpty) return;

    final channel = Channel(
      id: newId(),
      name: providerName.isEmpty ? '默认渠道' : providerName,
      apiFormat: config.apiFormat,
      baseUrl: config.baseUrl,
      model: config.model,
      // 空串归一成 null。旧 prefs 里"没填摘要模型"存的是 ''，
      // 带着它迁过来的话，空串就会在新结构里继续传播 ——
      // 而 `?? model` 对空串不成立，那正是之前踩过的坑。
      summaryModel: (config.summaryModel?.trim().isEmpty ?? true)
          ? null
          : config.summaryModel,
    );
    await upsert(channel, apiKey: config.apiKey);
    await setActive(channel.id);
  }

  Future<void> upsert(Channel channel, {String? apiKey}) async {
    final i = _channels.indexWhere((c) => c.id == channel.id);
    if (i < 0) {
      _channels.add(channel);
    } else {
      _channels[i] = channel;
    }
    if (apiKey != null) {
      if (apiKey.isEmpty) {
        _keys.remove(channel.id);
        await _secure?.delete(key: channel.apiKeyStorageKey);
      } else {
        _keys[channel.id] = apiKey;
        await _secure?.write(key: channel.apiKeyStorageKey, value: apiKey);
      }
    }
    _activeId ??= channel.id;
    notifyListeners();
    await _persist();
  }

  Future<void> remove(String id) async {
    _channels.removeWhere((c) => c.id == id);
    _keys.remove(id);
    // 删掉的渠道正好是当前渠道时，落到第一个上而不是留一个悬空指向 ——
    // 悬空的话 active 会静默回退到 first，用户看不出发生了什么。
    if (_activeId == id) {
      _activeId = _channels.isEmpty ? null : _channels.first.id;
    }
    notifyListeners();
    await _secure?.delete(key: '$keyPrefix$id');
    await _persist();
  }

  Future<void> setActive(String id) async {
    if (_activeId == id) return;
    if (byId(id) == null) return;
    _activeId = id;
    notifyListeners();
    await _prefs?.setString(_activeKey, id);
  }

  Future<void> _persist() async {
    final prefs = _prefs;
    if (prefs == null) return;
    await prefs.setString(
        _listKey, jsonEncode(_channels.map((c) => c.toJson()).toList()));
    final id = _activeId;
    if (id != null) await prefs.setString(_activeKey, id);
  }

  /// 当前渠道投影成 [LlmConfig]。
  ///
  /// OAuth 渠道的 apiKey 留空 —— access_token 会过期，抄进配置就等于抄了
  /// 一份马上失效的副本。真正的 token 由 [ConfigurableLlmClient.bearerProvider]
  /// 在每次请求前现取。
  LlmConfig configFor(Channel? channel,
      {double temperature = 0.3, bool streamOutput = true}) {
    if (channel == null) return LlmConfig.empty;
    return LlmConfig(
      apiFormat: channel.oauthProviderId == 'openai_oauth'
          ? 'chatgptOAuth'
          : channel.apiFormat,
      baseUrl: channel.baseUrl,
      apiKey: channel.usesOAuth ? '' : apiKeyOf(channel),
      model: channel.model,
      summaryModel: channel.summaryModel,
      proxy: channel.proxy,
      temperature: temperature,
      streamOutput: streamOutput,
    );
  }
}
