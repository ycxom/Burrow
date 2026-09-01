/// OAuth 账号的持久化。
///
/// token 存在 flutter_secure_storage 里（Android 上落在 Keystore 加持的
/// EncryptedSharedPreferences），和 API key 同级 —— 一个 refresh_token
/// 的价值和 API key 完全一样，拿到就能一直用下去，不该退到明文 prefs 里。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../llm/oauth.dart';
import 'dart:convert';

class AccountStore extends ChangeNotifier {
  AccountStore._(this._secure, this._providers, this._credentials);

  static const _prefix = 'burrow.oauth.';

  final FlutterSecureStorage _secure;
  final List<DeviceFlowProvider> _providers;
  final Map<String, OAuthCredential> _credentials;

  List<DeviceFlowProvider> get providers => List.unmodifiable(_providers);

  OAuthCredential? credentialFor(String providerId) => _credentials[providerId];

  DeviceFlowProvider? providerById(String id) {
    for (final p in _providers) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// 已登录的账号。UI 用它决定设置页里能选哪些服务商。
  List<DeviceFlowProvider> get signedIn =>
      _providers.where((p) => _credentials.containsKey(p.id)).toList();

  static Future<AccountStore> load({
    List<DeviceFlowProvider>? providers,
    FlutterSecureStorage? secure,
  }) async {
    final storage = secure ?? const FlutterSecureStorage();
    final list = providers ?? [OpenAiDeviceFlow(), XaiDeviceFlow()];
    final credentials = <String, OAuthCredential>{};

    for (final provider in list) {
      try {
        final raw = await storage.read(key: '$_prefix${provider.id}');
        if (raw == null || raw.isEmpty) continue;
        final json = jsonDecode(raw);
        if (json is Map<String, Object?>) {
          credentials[provider.id] = OAuthCredential.fromJson(json);
        }
      } catch (_) {
        // 存坏了就当没登录。抛出去会让 app 起不来，
        // 而重新登录一次的代价远小于打不开。
      }
    }
    return AccountStore._(storage, list, credentials);
  }

  Future<void> save(String providerId, OAuthCredential credential) async {
    _credentials[providerId] = credential;
    notifyListeners();
    await _secure.write(
      key: '$_prefix$providerId',
      value: jsonEncode(credential.toJson()),
    );
  }

  Future<void> remove(String providerId) async {
    _credentials.remove(providerId);
    notifyListeners();
    await _secure.delete(key: '$_prefix$providerId');
  }

  /// 拿一个当前可用的 access_token，过期就先刷新。
  ///
  /// 刷新失败时**清掉这个账号**再抛：留着一个刷不动的凭据，
  /// UI 上会一直显示"已登录"，而每次请求都 401 —— 用户根本不会想到
  /// 要去点一下"退出"再重登。
  Future<String> validTokenFor(String providerId) async {
    final credential = _credentials[providerId];
    if (credential == null) {
      throw OAuthException('还没有登录 $providerId');
    }
    if (!credential.isExpired) return credential.accessToken;

    final provider = providerById(providerId);
    if (provider == null) throw OAuthException('未知的服务商 $providerId');

    try {
      final refreshed = await provider.refresh(credential);
      await save(providerId, refreshed);
      return refreshed.accessToken;
    } on OAuthException {
      await remove(providerId);
      rethrow;
    }
  }
}
