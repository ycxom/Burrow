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

import '../llm/oauth.dart';

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

class AccountStore extends ChangeNotifier {
  AccountStore._(this._secure, this._providers, this._accounts, this._cache);

  static const prefix = 'burrow.oauth.';
  static const _indexKey = '${prefix}index';

  final FlutterSecureStorage _secure;
  final List<DeviceFlowProvider> _providers;

  /// 账号索引，顺序即登录顺序。
  final List<OAuthAccount> _accounts;

  /// 已读出来的凭据。键是 [OAuthAccount.storageKey]。
  final Map<String, OAuthCredential> _cache;

  List<DeviceFlowProvider> get providers => List.unmodifiable(_providers);
  List<OAuthAccount> get accounts => List.unmodifiable(_accounts);

  List<OAuthAccount> accountsOf(String providerId) =>
      _accounts.where((a) => a.providerId == providerId).toList();

  DeviceFlowProvider? providerById(String id) {
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

  static Future<AccountStore> load({
    List<DeviceFlowProvider>? providers,
    FlutterSecureStorage? secure,
  }) async {
    final storage = secure ?? const FlutterSecureStorage();
    final list = providers ?? [OpenAiDeviceFlow(), XaiDeviceFlow()];

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

    final store = AccountStore._(storage, list, accounts, cache);
    await store._migrateLegacy();
    return store;
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
    notifyListeners();
    await _secure.delete(key: account.storageKey);
    await _writeIndex();
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
