/// OAuth 账号的持久化。**同一个服务商可以登录多个账号。**
///
/// token 存在 flutter_secure_storage 里（Android 上落在 Keystore 加持的
/// EncryptedSharedPreferences），和 API key 同级 —— 一个 refresh_token
/// 的价值和 API key 完全一样，拿到就能一直用下去，不该退到明文 prefs 里。
///
/// ## 存储布局
///
/// ```
/// burrow.oauth.index                     -> [{provider, id, email}, ...]
/// burrow.oauth.<provider>.<accountId>    -> OAuthCredential JSON
/// burrow.oauth.<provider>                -> 旧版单账号（读到就迁移）
/// ```
///
/// 索引单独存一份，是因为 flutter_secure_storage 的 `readAll` 在部分设备上
/// 会把**整个 app 的**安全存储都读出来（包括 API key），既慢又容易撞上
/// 某一条坏数据导致整体失败。存一份索引就只读该读的。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:http/http.dart' as http;

import '../llm/google_oauth.dart';
import '../llm/oauth.dart';
import '../net/proxy_client.dart';
import 'channel_store.dart';

/// 一个已登录的账号。
class OAuthAccount {
  /// 服务商 id（`openai` / `xai`）。
  final String providerId;

  /// 同一服务商下的唯一标识。优先用邮箱 —— 用户认得出来的才是标识。
  final String id;

  final String? email;

  const OAuthAccount({
    required this.providerId,
    required this.id,
    this.email,
  });

  /// 界面上显示的名字。
  String get label => email?.isNotEmpty == true ? email! : id;

  /// secure storage 的键。
  String get storageKey => '${AccountStore.prefix}$providerId.$id';

  Map<String, Object?> toJson() =>
      {'provider': providerId, 'id': id, 'email': email};

  static OAuthAccount fromJson(Map<String, Object?> j) => OAuthAccount(
        providerId: j['provider']! as String,
        id: j['id']! as String,
        email: j['email'] as String?,
      );
}

/// 界面上的一行登录入口。
///
/// 一个家族可能有多个登录模式（Google 有免费额度和 Vertex 两种），但它们
/// 共用同一个账号体系和同一个代理设置。
class OAuthFamily {
  const OAuthFamily({
    required this.id,
    required this.name,
    required this.modes,
    required this.accounts,
    this.proxy,
  });

  final String id;
  final String name;
  final List<OAuthProvider> modes;
  final List<OAuthAccount> accounts;
  final String? proxy;

  bool get isMultiMode => modes.length > 1;
}

class AccountStore extends ChangeNotifier {
  AccountStore._(
    this._secure,
    this._providers,
    this._accounts,
    this._cache,
    this._googleClient,
    this._proxies,
    this._quotas,
  );

  static const prefix = 'burrow.oauth.';
  static const _indexKey = '${prefix}index';

  /// 自定义 OAuth 客户端凭据的存储键。
  ///
  /// 和 token 放在同一个安全存储里：client_secret 虽然按 OAuth 规范对
  /// "installed application" 不算秘密，但它是用户自己 GCP 项目的凭据，
  /// 退到明文 prefs 里没有任何理由。
  static const _googleClientKey = '${prefix}client.google';

  /// 每个家族的登录代理。
  ///
  /// **登录和调模型是两条独立的网络路径。** 渠道上那个代理只作用于模型请求；
  /// 登录要打的是 accounts.google.com / auth.openai.com 这些认证域名，它们和
  /// 模型接口经常不在同一张网里（自建网关在内网直连，但认证域名要翻出去）。
  /// 所以代理必须能单独配。
  ///
  /// 存在安全存储里不是因为它是秘密，而是因为 AccountStore 手上只有这一个
  /// 存储 —— 为一个字符串再引一份 SharedPreferences 不值得。
  static const _proxyKey = '${prefix}proxies';

  /// 上一次查到的套餐和余量。缓存起来是为了冷启动时渠道列表立刻有东西显示 ——
  /// 每次打开都现查的话，列表会先空一秒再跳出来。
  static const _quotaKey = '${prefix}quotas';

  final FlutterSecureStorage _secure;

  /// 可变：换自定义客户端要重建 Google 那两个 provider（客户端 id 是
  /// 构造时注入的）。
  final List<OAuthProvider> _providers;

  /// 账号索引，顺序即登录顺序。
  final List<OAuthAccount> _accounts;

  /// 已读出来的凭据。键是 [OAuthAccount.storageKey]。
  final Map<String, OAuthCredential> _cache;

  /// 当前生效的 Google 客户端凭据。null = 用内嵌那份。
  GoogleOAuthClient? _googleClient;

  /// family → 代理地址。
  final Map<String, String> _proxies;

  /// [OAuthAccount.storageKey] → 套餐余量。
  final Map<String, AccountQuota> _quotas;

  List<OAuthProvider> get providers => List.unmodifiable(_providers);
  List<OAuthAccount> get accounts => List.unmodifiable(_accounts);

  /// 用户自己填的 Google 客户端。null 表示正在用内嵌那份。
  GoogleOAuthClient? get googleClient => _googleClient;

  bool get usesBundledGoogleClient => _googleClient == null;

  List<OAuthAccount> accountsOf(String providerId) =>
      _accounts.where((a) => a.providerId == providerId).toList();

  /// 按家族分组的 provider。顺序稳定 —— 界面上登录入口的位置不该每次都变。
  List<OAuthFamily> get families {
    final byFamily = <String, List<OAuthProvider>>{};
    for (final provider in _providers) {
      byFamily
          .putIfAbsent(provider.family, () => <OAuthProvider>[])
          .add(provider);
    }
    return <OAuthFamily>[
      for (final entry in byFamily.entries)
        OAuthFamily(
          id: entry.key,
          name: entry.value.first.familyName,
          modes: List<OAuthProvider>.unmodifiable(entry.value),
          proxy: _proxies[entry.key],
          accounts: List<OAuthAccount>.unmodifiable(
            _accounts.where(
              (a) => entry.value.any((p) => p.id == a.providerId),
            ),
          ),
        ),
    ];
  }

  /// 一个家族的登录代理。空 = 直连。
  String? proxyOf(String family) => _proxies[family];

  /// 这个账号上一次查到的套餐余量。
  AccountQuota? quotaOf(OAuthAccount account) => _quotas[account.storageKey];

  AccountQuota? quotaFor(Channel channel) {
    if (!channel.usesOAuth) return null;
    final bound = account(channel.oauthProviderId!, channel.oauthAccountId!);
    return bound == null ? null : quotaOf(bound);
  }

  OAuthProvider? providerById(String id) {
    for (final p in _providers) {
      if (p.id == id) return p;
    }
    return null;
  }

  OAuthAccount? account(String providerId, String accountId) {
    for (final a in _accounts) {
      if (a.providerId == providerId && a.id == accountId) return a;
    }
    return null;
  }

  OAuthCredential? credentialOf(OAuthAccount account) =>
      _cache[account.storageKey];

  OAuthCredential? credentialFor(Channel channel) {
    if (!channel.usesOAuth) return null;
    final bound = account(channel.oauthProviderId!, channel.oauthAccountId!);
    return bound == null ? null : credentialOf(bound);
  }

  static Future<AccountStore> load({
    List<OAuthProvider>? providers,
    FlutterSecureStorage? secure,
  }) async {
    final storage = secure ?? const FlutterSecureStorage();

    // 自定义客户端要在造 provider **之前**读出来 —— 客户端 id 是构造参数，
    // 造完再改就得重建一遍。
    GoogleOAuthClient? googleClient;
    try {
      final raw = await storage.read(key: _googleClientKey);
      if (raw != null && raw.isNotEmpty) {
        googleClient = GoogleOAuthClient.fromJson(
          jsonDecode(raw) as Map<String, Object?>,
        );
      }
    } catch (_) {
      // 存坏了就当没设过，回落内嵌凭据。这里抛出去会让 app 起不来，
      // 而"登录用的是内嵌凭据"顶多是不合某些人的预期。
    }

    final proxies = <String, String>{};
    try {
      final raw = await storage.read(key: _proxyKey);
      if (raw != null && raw.isNotEmpty) {
        for (final entry in (jsonDecode(raw) as Map).entries) {
          final value = entry.value;
          if (value is String && value.isNotEmpty) {
            proxies[entry.key.toString()] = value;
          }
        }
      }
    } catch (_) {
      // 代理配置坏了就当直连。这里抛出去会让 app 起不来。
    }

    final quotas = <String, AccountQuota>{};
    try {
      final raw = await storage.read(key: _quotaKey);
      if (raw != null && raw.isNotEmpty) {
        for (final entry in (jsonDecode(raw) as Map).entries) {
          final value = entry.value;
          if (value is! Map) continue;
          final quota = AccountQuota.fromJson(value.cast<String, Object?>());
          if (quota != null) quotas[entry.key.toString()] = quota;
        }
      }
    } catch (_) {
      // 缓存坏了就当没查过 —— 它本来就是可以随时重查的展示信息。
    }

    final list = providers ?? _defaultProviders(googleClient, proxies);

    final accounts = <OAuthAccount>[];
    final cache = <String, OAuthCredential>{};

    try {
      final raw = await storage.read(key: _indexKey);
      if (raw != null && raw.isNotEmpty) {
        for (final entry in jsonDecode(raw) as List) {
          accounts.add(OAuthAccount.fromJson(entry as Map<String, Object?>));
        }
      }
    } catch (_) {
      // 索引坏了就当没登录过。抛出去会让 app 起不来，
      // 而重新登录一次的代价远小于打不开。
    }

    for (final account in List<OAuthAccount>.from(accounts)) {
      try {
        final raw = await storage.read(key: account.storageKey);
        if (raw == null || raw.isEmpty) {
          // 索引里有、凭据没了：登录状态是假的，从索引里摘掉。
          accounts.remove(account);
          continue;
        }
        cache[account.storageKey] =
            OAuthCredential.fromJson(jsonDecode(raw) as Map<String, Object?>);
      } catch (_) {
        accounts.remove(account);
      }
    }

    final store = AccountStore._(
      storage,
      list,
      accounts,
      cache,
      googleClient,
      proxies,
      quotas,
    );
    await store._migrateLegacy();
    return store;
  }

  /// 出厂的服务商列表。
  ///
  /// Google 占两条：同一个账号登录，但登完之后打的是两个完全不同的后端
  /// （免费额度的内部接口 / 自己项目的 Vertex），`apiBaseUrl` 和 `apiFormat`
  /// 都不一样。合成一条带开关的话，每个用到 provider 的地方都要再判断一次
  /// "现在是哪个模式"。
  static List<OAuthProvider> _defaultProviders(
    GoogleOAuthClient? google,
    Map<String, String> proxies,
  ) {
    final client = google ?? GoogleOAuthClient.bundled;
    // 每个家族一个客户端实例：代理是按家族配的，共用一个的话改一家会影响
    // 另一家 —— 而"改了 Google 的代理，ChatGPT 也跟着走代理了"是那种用户
    // 完全不会想到要去检查的问题。
    http.Client clientFor(String family) =>
        buildHttpClient(proxy: proxies[family]);

    return <OAuthProvider>[
      OpenAiDeviceFlow(client: clientFor('openai_oauth')),
      XaiDeviceFlow(client: clientFor('xai_oauth')),
      GoogleCodeAssistFlow(client: client, httpClient: clientFor(googleFamily)),
      GoogleVertexFlow(client: client, httpClient: clientFor(googleFamily)),
    ];
  }

  /// 换一个家族的登录代理。
  ///
  /// provider 的 http 客户端是构造时注入的，所以只能整批重建 —— 已登录的
  /// 账号和凭据不受影响，它们存在别处。
  Future<void> setProxy(String family, String? proxy) async {
    final normalized = normalizeProxy(proxy);
    if (normalized == null) {
      _proxies.remove(family);
    } else {
      _proxies[family] = normalized;
    }
    _rebuildProviders();
    await _secure.write(key: _proxyKey, value: jsonEncode(_proxies));
    notifyListeners();
  }

  void _rebuildProviders() {
    final rebuilt = _defaultProviders(_googleClient, _proxies);
    _providers
      ..clear()
      ..addAll(rebuilt);
  }

  /// 现查一个账号的套餐余量并缓存。
  ///
  /// 查不到不抛 —— 这是附加信息，失败不该让渠道列表变成错误页。
  Future<AccountQuota?> refreshQuota(OAuthAccount account) async {
    final provider = providerById(account.providerId);
    final credential = _cache[account.storageKey];
    if (provider == null || credential == null) return null;
    try {
      final token = await validToken(account);
      final quota = await provider.fetchQuota(
        OAuthCredential(
          accessToken: token,
          refreshToken: credential.refreshToken,
          expiresAt: credential.expiresAt,
          email: credential.email,
          accountId: credential.accountId,
        ),
      );
      if (quota == null) return null;
      return await _storeQuota(account.storageKey, quota);
    } catch (_) {
      return _quotas[account.storageKey];
    }
  }

  /// 记下一次从**响应头**里读到的余量。
  ///
  /// ChatGPT 唯一能拿到真实余量的地方就是聊天响应头，所以这条路是由 LLM
  /// 客户端反向推进来的，而不是我们主动去查。
  Future<void> noteQuota(
    String providerId,
    String accountId,
    AccountQuota quota,
  ) async {
    final target = account(providerId, accountId);
    if (target == null) return;
    await _storeQuota(target.storageKey, quota);
  }

  Future<AccountQuota> _storeQuota(String key, AccountQuota quota) async {
    final stamped = quota.withFetchedAt(quota.fetchedAt ?? DateTime.now());
    _quotas[key] = stamped;
    notifyListeners();
    await _secure.write(
      key: _quotaKey,
      value: jsonEncode(
        _quotas.map((k, v) => MapEntry(k, v.toJson())),
      ),
    );
    return stamped;
  }

  /// 换掉 Google 的 OAuth 客户端凭据。传 null 恢复内嵌那份。
  ///
  /// **已登录的账号不动。** 换客户端不会让已有的 access_token 立刻失效，
  /// 但下一次刷新会用新客户端去刷一个旧客户端签发的 refresh_token，那必然
  /// 失败。所以这里明确告诉调用方要不要提示用户重登（返回值是受影响的账号数）。
  Future<int> setGoogleClient(GoogleOAuthClient? client) async {
    _googleClient = client;
    // provider 是不可变对象，只能整批换掉。
    _rebuildProviders();

    if (client == null) {
      await _secure.delete(key: _googleClientKey);
    } else {
      await _secure.write(
        key: _googleClientKey,
        value: jsonEncode(client.toJson()),
      );
    }
    notifyListeners();
    return _accounts
        .where((a) =>
            a.providerId == GoogleCodeAssistFlow.providerId ||
            a.providerId == GoogleVertexFlow.providerId)
        .length;
  }

  /// 把旧版「每个服务商一个账号」的数据搬进新布局。
  ///
  /// 旧键是 `burrow.oauth.<provider>`，没有账号维度。直接不管的话，
  /// 用户升级后会发现自己"被登出了"，而 token 其实还在。
  Future<void> _migrateLegacy() async {
    var changed = false;
    for (final provider in _providers) {
      final legacyKey = '$prefix${provider.id}';
      String? raw;
      try {
        raw = await _secure.read(key: legacyKey);
      } catch (_) {
        continue;
      }
      if (raw == null || raw.isEmpty) continue;

      try {
        final credential =
            OAuthCredential.fromJson(jsonDecode(raw) as Map<String, Object?>);
        final id = _idFor(credential);
        if (account(provider.id, id) == null) {
          final migrated = OAuthAccount(
              providerId: provider.id, id: id, email: credential.email);
          _accounts.add(migrated);
          _cache[migrated.storageKey] = credential;
          await _secure.write(
              key: migrated.storageKey, value: jsonEncode(credential.toJson()));
          changed = true;
        }
      } catch (_) {
        // 解不出来就只删旧键，不制造一个坏账号。
      }
      await _secure.delete(key: legacyKey);
    }
    if (changed) {
      await _writeIndex();
      notifyListeners();
    }
  }

  /// 账号 id。邮箱优先 —— 它是用户唯一认得出来的东西。
  ///
  /// 都没有时退回时间戳：宁可显示一个难看的 id，也不能让两个账号
  /// 撞成同一个键、后登录的把先登录的覆盖掉。
  static String _idFor(OAuthCredential c) {
    final email = c.email?.trim() ?? '';
    if (email.isNotEmpty) return email;
    final accountId = c.accountId?.trim() ?? '';
    if (accountId.isNotEmpty) return accountId;
    return 'acct-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
  }

  Future<void> _writeIndex() => _secure.write(
        key: _indexKey,
        value: jsonEncode(_accounts.map((a) => a.toJson()).toList()),
      );

  /// 存一个新登录（或刷新后）的账号。同一个 id 再登录就是覆盖。
  Future<OAuthAccount> save(
      String providerId, OAuthCredential credential) async {
    final id = _idFor(credential);
    var target = account(providerId, id);
    if (target == null) {
      target =
          OAuthAccount(providerId: providerId, id: id, email: credential.email);
      _accounts.add(target);
    }
    _cache[target.storageKey] = credential;
    notifyListeners();
    await _secure.write(
        key: target.storageKey, value: jsonEncode(credential.toJson()));
    await _writeIndex();
    return target;
  }

  Future<void> remove(OAuthAccount account) async {
    _accounts.removeWhere(
        (a) => a.providerId == account.providerId && a.id == account.id);
    _cache.remove(account.storageKey);
    // 额度缓存跟着账号走。留着的话，重新登录同一个邮箱会看到一份上次的
    // 陈旧数字，而它看起来和刚查的一模一样。
    _quotas.remove(account.storageKey);
    notifyListeners();
    await _secure.delete(key: account.storageKey);
    await _writeIndex();
  }

  /// 一个渠道这次请求该带的 Authorization 值。
  ///
  /// 走 API key 的渠道原样返回传进来的 key；走 OAuth 的**每次现取** ——
  /// 把 access_token 抄进渠道配置的话，它一过期那份副本就成了必然 401
  /// 的死值，而界面上还显示着"已登录"。
  Future<String> authFor(Channel channel, {required String apiKey}) async {
    if (!channel.usesOAuth) return apiKey;
    final bound = account(channel.oauthProviderId!, channel.oauthAccountId!);
    if (bound == null) throw const OAuthException('绑定的账号已经不存在了');
    return validToken(bound);
  }

  /// 拿一个当前可用的 access_token，过期就先刷新。
  ///
  /// 刷新失败时**清掉这个账号**再抛：留着一个刷不动的凭据，
  /// UI 上会一直显示"已登录"，而每次请求都 401 —— 用户根本不会想到
  /// 要去点一下"退出"再重登。
  Future<String> validToken(OAuthAccount account) async {
    final credential = _cache[account.storageKey];
    if (credential == null) {
      throw OAuthException('账号 ${account.label} 还没有登录');
    }
    if (!credential.isExpired) return credential.accessToken;

    final provider = providerById(account.providerId);
    if (provider == null) {
      throw OAuthException('未知的服务商 ${account.providerId}');
    }

    try {
      final refreshed = await provider.refresh(credential);
      await save(account.providerId, refreshed);
      return refreshed.accessToken;
    } on OAuthException {
      await remove(account);
      rethrow;
    }
  }
}
