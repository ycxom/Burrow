/// Google 账号登录：授权码 + PKCE + 本地回环回跳。
///
/// ## 为什么这一家不能走设备码
///
/// oauth.dart 里那两家走的都是设备码，理由（不用开端口、不用注册 scheme）在
/// 手机上仍然成立。但 Google 走不通：它的 limited-input device flow **把 scope
/// 锁死在一张白名单上** —— `email` / `openid` / `profile` 加 Drive、YouTube
/// 几个，`cloud-platform` 不在里面。照着设备码抄一个出来，用户能登录成功，
/// 然后发现调不了任何模型。那比没有这个功能更糟。
///
/// 所以这一家走回跳。文件头那三条顾虑分别是这么处理的：
///
///   - **不用注册自定义 scheme。** 回跳目标是
///     `http://localhost:51121/oauth-callback`，
///     不是 `burrow://`。Android 不保证 scheme 唯一，谁都能注册一个同名的把
///     授权码抢走；回环地址没有这个问题，它只可能回到本机。
///   - **端口固定为 51121。** 这是 Antigravity OAuth 客户端登记的回跳地址；
///     服务器只监听回环网卡，并且只活到收到本次登录的有效回跳为止。
///   - **换设备登不了。** 这是回跳相对设备码真实的损失：授权必须在这台机器的
///     浏览器里完成。接受它，因为另一条路根本到不了终点。
///
/// PKCE 是必须的：授权码要经过系统浏览器和回环地址两跳，中间任何一个能读到
/// 回跳 URL 的东西（别的 app 抢注了同端口、浏览器扩展）拿到码也换不出 token，
/// 因为它没有 verifier。
///
/// ## 两个后端
///
/// 登录拿到的是同一个 Google 账号，但之后打哪个接口是两回事：
///
///   - [GoogleCodeAssistFlow]：`cloudcode-pa.googleapis.com/v1internal`，
///     Antigravity / Code Assist 使用的内部接口。
///   - [GoogleVertexFlow]：Vertex AI 的 OpenAI 兼容端点。有正式文档、稳定，
///     但要用户自己的 GCP 项目和区域，而且要开通计费。
///
/// ## Antigravity 兼容
///
/// 这里使用 Antigravity 的 OAuth 客户端、固定回跳地址和完整 scope 集合。授权码
/// 换成 token 后还会走 `tokeninfo` 与 `userinfo`，验证客户端归属、scope、有效期
/// 和账号邮箱；只有这些检查全部通过，UI 才会显示登录成功。
///
/// 做成两个 provider 而不是一个带开关的：它们的 `apiBaseUrl` 和 `apiFormat`
/// 都不一样，而这两样正是 provider 存在的意义。合成一个的话，每个用到
/// provider 的地方都要再判断一次"现在是哪个模式"。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../secrets/google_oauth.dart'
    show googleOAuthClientId, googleOAuthClientSecret;
import 'oauth.dart';

/// OAuth 客户端凭据。
///
/// Google 不发公共客户端，必须注册一个。内嵌的是 Antigravity 桌面端公开凭据 ——
/// 它随 Antigravity 一起分发，本来就是公开的（"installed application" 类型的
/// secret 按 OAuth 规范就不是秘密），但那毕竟是 Google 发给 Antigravity 的，
/// **我们属于借用**：Google 可以吊销它，届时所有人的登录会同时失效。
///
/// 所以留了覆盖口子：介意的人可以在 Google Cloud Console 建自己的
/// 「桌面应用」客户端填进来，不受别人被吊销的牵连。
class GoogleOAuthClient {
  const GoogleOAuthClient({required this.id, required this.secret});

  final String id;
  final String secret;

  /// Antigravity 随包分发的公开凭据。
  ///
  /// 这些值来自 lib/secrets/google_oauth.dart，它不被 git 追踪。
  /// 用户可以编辑那个文件切换到自己注册的 Google Cloud 项目凭据。
  static const bundled = GoogleOAuthClient(
    id: googleOAuthClientId,
    secret: googleOAuthClientSecret,
  );

  bool get isBundled => id == bundled.id;

  Map<String, Object?> toJson() => {'id': id, 'secret': secret};

  static GoogleOAuthClient? fromJson(Map<String, Object?> j) {
    final id = (j['id'] as String? ?? '').trim();
    final secret = (j['secret'] as String? ?? '').trim();
    if (id.isEmpty) return null;
    return GoogleOAuthClient(id: id, secret: secret);
  }
}

/// Google 那两种模式在界面上收成一行的分组标识。
///
/// 它们是两个 provider（apiBaseUrl 和 apiFormat 都不一样），但对用户来说是
/// 同一家 —— 并排摆两条"Google 账号"只会让人以为要登两次。
const googleFamily = 'google';

/// Google 的 OAuth 端点。写死而不是走 discovery：Google 的这几个地址十年没动过，
/// 而多一次 discovery 请求就多一个登录会卡住的地方。
const _authEndpoint = 'https://accounts.google.com/o/oauth2/auth';
const _tokenEndpoint = 'https://oauth2.googleapis.com/token';
const _tokenInfoEndpoint = 'https://www.googleapis.com/oauth2/v3/tokeninfo';
const _userInfoEndpoint = 'https://www.googleapis.com/oauth2/v2/userinfo';

/// Antigravity 的 OAuth 客户端只登记了这个回跳地址，不能再让内核随机挑端口。
const _redirectPort = 51121;
const _redirectPath = '/oauth-callback';

/// 实际用的回跳端口。**生产环境必须是 [_redirectPort]** —— 那是登记在
/// Antigravity 客户端名下的地址，换一个 Google 直接 `redirect_uri_mismatch`。
///
/// 留这个口子只为测试：51121 落在 Windows 的 Hyper-V 保留端口段里
/// （`netsh int ipv4 show excludedportrange` 能看到 51113–51212），在 Windows
/// 上 bind 直接 `WSAEACCES`，整组回跳测试一个都跑不了。测试里换成 0 让内核
/// 挑一个 —— 那一组测的是"授权地址拼得对不对、state 校不校"，和具体端口无关。
@visibleForTesting
int googleRedirectPort = _redirectPort;

/// 把端口还原成生产值。测试的 tearDown 用。
@visibleForTesting
void resetGoogleRedirectPort() => googleRedirectPort = _redirectPort;

/// Antigravity 当前请求的完整 scope 集合。
const _antigravityScopes = <String>[
  'email',
  'profile',
  'openid',
  'https://www.googleapis.com/auth/aicode',
  'https://www.googleapis.com/auth/cloud-platform',
  'https://www.googleapis.com/auth/userinfo.email',
  'https://www.googleapis.com/auth/userinfo.profile',
  'https://www.googleapis.com/auth/cclog',
  'https://www.googleapis.com/auth/experimentsandconfigs',
];

/// Vertex 不需要 Antigravity 的日志、实验配置和 AI Code 权限。
const _vertexScopes = <String>[
  'openid',
  'https://www.googleapis.com/auth/cloud-platform',
  'https://www.googleapis.com/auth/userinfo.email',
  'https://www.googleapis.com/auth/userinfo.profile',
];

/// 本地回环服务器等回跳的上限。
///
/// 超时不是可选的：用户很可能切到浏览器之后就去干别的了，而一个一直挂着的
/// 监听端口是实打实的攻击面 —— 任何本机进程都能往它上面发东西。
const _redirectTimeout = Duration(minutes: 5);

/// 回跳登录的共同部分。两个后端只是登录后打的接口不同，登录本身一模一样。
class _GoogleAuthCore {
  _GoogleAuthCore({
    required this.client,
    required List<String> scopes,
    http.Client? httpClient,
  })  : _scopes = scopes,
        _http = httpClient ?? http.Client();

  final GoogleOAuthClient client;
  final List<String> _scopes;
  final http.Client _http;

  static const _userAgent = 'burrow-google-oauth';

  Future<RedirectAuthSession> start() async {
    // Antigravity 的 OAuth 客户端把回跳 URI 固定在 localhost:51121。
    // 只监听 IPv4 回环，不把这个临时端口暴露给局域网。
    late final HttpServer server;
    try {
      server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        googleRedirectPort,
      );
    } on SocketException catch (e) {
      // 说人话。用户看到的原文是一句 `SocketException: ... errno = 98`，
      // 而他真正需要知道的是"有别的程序占着这个端口"以及"该去关掉谁" ——
      // 这个端口是 Antigravity 系客户端共用的，冲突的多半就是它们。
      throw OAuthException(
        'Google 登录要用本机的 $_redirectPort 端口接收回跳，但它被占用了。'
        '常见原因是 Antigravity 或别的同系客户端正开着 —— 关掉再试。'
        '（原始错误：${e.osError?.message ?? e.message}）',
      );
    }
    final redirectUri = 'http://localhost:${server.port}$_redirectPath';

    final verifier = _randomUrlSafe(64);
    final challenge =
        base64Url.encode(_sha256(utf8.encode(verifier))).replaceAll('=', '');
    // state 防的是别的本机进程往我们的回环端口上塞一个它自己拿到的授权码。
    final state = _randomUrlSafe(24);

    final completer = Completer<OAuthCredential>();

    // 先挂一个空的错误处理器，保证这个 future 永远"有人接"。
    //
    // 不挂的话有一条真实的漏网路径：调用方 await 完 start() 之后、还没来得及
    // 接结果之前就取消（登录页在 `!mounted` 分支里就是这么做的），
    // completeError 会变成一次无人接收的异步错误，在 debug 下直接把 app 打崩。
    // 多挂一个监听不影响真正的调用方 —— 错误会发给每一个监听者。
    completer.future.ignore();

    Timer? timeout;

    Future<void> shutdown() async {
      timeout?.cancel();
      await server.close(force: true);
    }

    timeout = Timer(_redirectTimeout, () {
      if (completer.isCompleted) return;
      completer.completeError(const OAuthException('登录超时，没有等到浏览器回跳'));
      unawaited(shutdown());
    });

    unawaited(() async {
      try {
        await for (final request in server) {
          final query = request.uri.queryParameters;
          // 浏览器还会请求 /favicon.ico 之类的，别把它当回跳。
          if (request.method != 'GET' || request.uri.path != _redirectPath) {
            request.response.statusCode = HttpStatus.notFound;
            await request.response.close();
            continue;
          }

          final error = query['error'];
          final code = query['code'];
          final returned = query['state'];

          if (returned != state) {
            // 不把这次回跳当数：state 对不上意味着这个码不是我们发起的那次
            // 授权换来的。继续监听，真正的回跳可能还在路上。
            request.response
              ..statusCode = HttpStatus.badRequest
              ..headers.contentType = ContentType.html
              ..write(_resultPage('这次回跳不属于本次登录', '已忽略'));
            await request.response.close();
            continue;
          }

          if (completer.isCompleted) {
            request.response
              ..statusCode = HttpStatus.conflict
              ..headers.contentType = ContentType.html
              ..write(_resultPage('本次登录已经结束', '请回到 Burrow 查看结果'));
            await request.response.close();
            continue;
          }

          if (error != null) {
            final description = query['error_description'];
            final detail = description == null || description.isEmpty
                ? error
                : '$error：$description';
            request.response
              ..statusCode = HttpStatus.badRequest
              ..headers.contentType = ContentType.html
              ..write(_resultPage('登录被取消或失败', detail));
            await request.response.close();
            completer.completeError(OAuthException('授权失败：$detail'));
            await shutdown();
            continue;
          }

          if (code == null || code.isEmpty) {
            request.response
              ..statusCode = HttpStatus.badRequest
              ..headers.contentType = ContentType.html
              ..write(_resultPage('回跳里没有授权码', '请重试'));
            await request.response.close();
            continue;
          }

          // 收到授权码还不等于登录成功。和 Antigravity 的 AuthResult 流程一样，
          // 必须先让 Google 验证 access token、客户端归属、scope 和账号身份。
          try {
            final credential = await _exchange(
              code: code,
              verifier: verifier,
              redirectUri: redirectUri,
            );
            request.response
              ..statusCode = HttpStatus.ok
              ..headers.contentType = ContentType.html
              ..write(_resultPage('登录成功', '身份已经验证，可以回到 Burrow 了'));
            await request.response.close();
            completer.complete(credential);
          } catch (e) {
            final failure =
                e is OAuthException ? e : OAuthException('验证登录失败：$e');
            request.response
              ..statusCode = HttpStatus.unauthorized
              ..headers.contentType = ContentType.html
              ..write(_resultPage('登录验证失败', failure.message));
            await request.response.close();
            completer.completeError(failure);
          }
          await shutdown();
        }
      } catch (e) {
        if (!completer.isCompleted) {
          completer.completeError(OAuthException('本地回环服务器出错：$e'));
        }
      }
    }());

    final authUrl = Uri.parse(_authEndpoint).replace(queryParameters: {
      'client_id': client.id,
      'redirect_uri': redirectUri,
      'response_type': 'code',
      'scope': _scopes.join(' '),
      'code_challenge': challenge,
      'code_challenge_method': 'S256',
      'state': state,
      // 不写 offline 就拿不到 refresh_token，于是一小时后用户要重登一次。
      'access_type': 'offline',
      // 已经授权过的账号再登，Google 默认不再下发 refresh_token。
      // 强制同意屏保证每次登录都拿得到，否则"重新登录一次修好过期问题"
      // 这个最自然的自救动作会失效。
      'prompt': 'consent',
    });

    return RedirectAuthSession(
      authorizationUrl: authUrl.toString(),
      result: completer.future,
      cancel: () async {
        if (!completer.isCompleted) {
          completer.completeError(const OAuthException('已取消登录'));
        }
        await shutdown();
      },
    );
  }

  Future<OAuthCredential> _exchange({
    required String code,
    required String verifier,
    required String redirectUri,
  }) async {
    final response = await _describeNetworkFailure(() => _http.post(
          Uri.parse(_tokenEndpoint),
          headers: const {
            'Content-Type': 'application/x-www-form-urlencoded',
            'User-Agent': _userAgent,
          },
          body: {
            'code': code,
            'client_id': client.id,
            // Google 的「桌面应用」客户端仍然要求带 secret，哪怕用了 PKCE。
            // 这不符合 OAuth 对公共客户端的建议，但服务端就是这么校验的。
            if (client.secret.isNotEmpty) 'client_secret': client.secret,
            'code_verifier': verifier,
            'grant_type': 'authorization_code',
            'redirect_uri': redirectUri,
          },
        ));
    if (response.statusCode != 200) {
      throw OAuthException(
          '换取 token 失败：HTTP ${response.statusCode} ${_brief(response.body)}');
    }
    return _validateCredential(
      _decode(response),
      previousRefresh: null,
    );
  }

  /// 问一次 Code Assist 的档位。
  ///
  /// 失败**不抛**：查额度是个附加信息，查不到不该让调用方（渠道列表）
  /// 变成一个错误页。返回一个说明了原因的结果，让用户知道是没查到而不是
  /// 没有额度。
  Future<AccountQuota?> loadTier(
    OAuthCredential credential, {
    required String baseUrl,
  }) async {
    try {
      final response = await _http.post(
        Uri.parse('$baseUrl:loadCodeAssist'),
        headers: <String, String>{
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${credential.accessToken}',
          'User-Agent': _userAgent,
        },
        // 不再自称 `pluginType: GEMINI`。
        //
        // 那是 gemini-cli 的身份，而 Burrow 不是 gemini-cli —— 这个字段在
        // Antigravity 的 proto 里也已经标了 `[deprecated = true]`，正是
        // 「This client is no longer supported」指的那一个。填一个不属于自己的
        // 身份既不诚实，也没让闸放行。
        body: jsonEncode(<String, Object?>{
          'metadata': <String, Object?>{
            'ideType': 'ANTIGRAVITY',
            'pluginType': 'PLUGIN_UNSPECIFIED',
          },
          'mode': 'FULL_ELIGIBILITY_CHECK',
        }),
      );
      if (response.statusCode != 200) {
        return AccountQuota(
          plan: '档位未知',
          detail: '查询失败：HTTP ${response.statusCode}',
        );
      }
      // 把原始返回打出来（仅 debug 构建）。
      //
      // 这不是临时调试代码：`v1internal` 是个未公开接口，它的返回形状**已经
      // 变过一次**（原来按 currentTier 解析，实测发现根本没有这个字段）。
      // 下次再变时，有这一行就能一眼看出新形状，没有就得先加一行再复现一次。
      if (kDebugMode) {
        debugPrint('burrow: loadCodeAssist -> ${response.body}');
      }
      return parseCodeAssistTier(_decode(response));
    } catch (e) {
      return AccountQuota(plan: '档位未知', detail: '查询失败：$e');
    }
  }

  Future<OAuthCredential> refresh(OAuthCredential expired) async {
    final token = expired.refreshToken;
    if (token == null) {
      throw const OAuthException('没有 refresh_token，需要重新登录');
    }
    final response = await _describeNetworkFailure(() => _http.post(
          Uri.parse(_tokenEndpoint),
          headers: const {
            'Content-Type': 'application/x-www-form-urlencoded',
            'User-Agent': _userAgent,
          },
          body: {
            'client_id': client.id,
            if (client.secret.isNotEmpty) 'client_secret': client.secret,
            'refresh_token': token,
            'grant_type': 'refresh_token',
          },
        ));
    if (response.statusCode != 200) {
      throw OAuthException(
          '刷新失败，需要重新登录：HTTP ${response.statusCode} ${_brief(response.body)}');
    }
    // 刷新响应里**没有** refresh_token，要把旧的接着用。不接的话下一次
    // 刷新就没有凭据了，表现成"登录一小时后必掉线"。
    return _validateCredential(
      _decode(response),
      previousRefresh: token,
    );
  }

  /// 验证 token 端点返回的凭据。
  ///
  /// 不能只检查 JSON 里有没有 access_token：任何成功返回 JSON 的中间层都能
  /// 塞进一个别的客户端、scope 不足或已经临近过期的 token。Antigravity 的
  /// 后端同样会调用 tokeninfo/userinfo，再以 AuthResult.has_valid_auth 告诉 UI
  /// 是否真的登录成功。
  Future<OAuthCredential> _validateCredential(
    Map<String, Object?> tokenJson, {
    required String? previousRefresh,
  }) async {
    final accessToken = _nonEmptyString(tokenJson['access_token']);
    if (accessToken == null) {
      throw const OAuthException('响应缺少 access_token');
    }

    final tokenInfoResponse = await _describeNetworkFailure(() => _http.get(
          Uri.parse(_tokenInfoEndpoint).replace(
            queryParameters: <String, String>{'access_token': accessToken},
          ),
          headers: const {'User-Agent': _userAgent},
        ));
    if (tokenInfoResponse.statusCode != 200) {
      throw OAuthException(
        'Google 未接受 access token：HTTP ${tokenInfoResponse.statusCode} '
        '${_brief(tokenInfoResponse.body)}',
      );
    }
    final tokenInfo = _decode(tokenInfoResponse);

    // tokeninfo 的新格式用 azp，旧格式用 issued_to。它们表示拿到这个 token 的
    // OAuth 客户端；不核对就可能把签给另一个应用的 token 当成 Burrow 登录。
    final authorizedParty = _nonEmptyString(tokenInfo['azp']) ??
        _nonEmptyString(tokenInfo['issued_to']);
    if (authorizedParty == null) {
      throw const OAuthException('Google tokeninfo 没有返回客户端标识');
    }
    if (authorizedParty != client.id) {
      throw const OAuthException('access token 不是签发给当前 OAuth 客户端的');
    }

    final grantedScopes = _scopeSet(tokenInfo['scope']);
    final missingScopes = _scopes
        .where((scope) => !grantedScopes.contains(scope))
        .toList(growable: false);
    if (missingScopes.isNotEmpty) {
      throw OAuthException('Google 授权缺少必要 scope：${missingScopes.join(', ')}');
    }

    final expiresIn = _int(
      tokenInfo['expires_in'],
      _int(tokenJson['expires_in'], 0),
    );
    if (expiresIn <= 0) {
      throw const OAuthException('access token 已过期或没有有效期');
    }

    // 不再从未验证签名的 id_token payload 读取邮箱。userinfo 使用刚刚经过
    // tokeninfo 验证的 access token，账号身份和实际授权令牌保持一致。
    final userInfoResponse = await _describeNetworkFailure(() => _http.get(
          Uri.parse(_userInfoEndpoint),
          headers: <String, String>{
            'Authorization': 'Bearer $accessToken',
            'User-Agent': _userAgent,
          },
        ));
    if (userInfoResponse.statusCode != 200) {
      throw OAuthException(
        '读取 Google 账号信息失败：HTTP ${userInfoResponse.statusCode} '
        '${_brief(userInfoResponse.body)}',
      );
    }
    final userInfo = _decode(userInfoResponse);
    final email = _nonEmptyString(userInfo['email']);
    if (email == null) {
      throw const OAuthException('Google userinfo 没有返回邮箱');
    }
    final verified = userInfo['verified_email'] ?? userInfo['email_verified'];
    if (verified == false || verified == 'false') {
      throw const OAuthException('Google 账号邮箱尚未验证');
    }

    return OAuthCredential(
      accessToken: accessToken,
      refreshToken:
          _nonEmptyString(tokenJson['refresh_token']) ?? previousRefresh,
      expiresAt: DateTime.now().add(Duration(seconds: expiresIn)),
      email: email,
    );
  }

  static String? _nonEmptyString(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static Set<String> _scopeSet(Object? value) {
    if (value is String) {
      return value
          .split(RegExp(r'\s+'))
          .where((scope) => scope.isNotEmpty)
          .toSet();
    }
    if (value is List) {
      return value
          .whereType<String>()
          .map((scope) => scope.trim())
          .where((scope) => scope.isNotEmpty)
          .toSet();
    }
    return const <String>{};
  }

  static Map<String, Object?> _decode(http.Response response) {
    if (response.body.isEmpty) return const {};
    final value = jsonDecode(response.body);
    return value is Map<String, Object?> ? value : const {};
  }

  static int _int(Object? value, int fallback) {
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? fallback;
    return fallback;
  }

  static String _brief(String body) =>
      body.length <= 300 ? body : '${body.substring(0, 300)}…';
}

/// 把 `:loadCodeAssist` 的返回读成一个可显示的档位。
///
/// ## 为什么不能只看 currentTier
///
/// 实测（2026-09，Google AI Pro 账号）这个接口**根本没返回 currentTier**：
///
/// ```json
/// {
///   "allowedTiers": [{ "id": "standard-tier", "name": "Gemini Code Assist",
///                      "userDefinedCloudaicompanionProject": true }],
///   "ineligibleTiers": [{ "tierId": "free-tier",
///                         "reasonCode": "UNSUPPORTED_CLIENT",
///                         "reasonMessage": "This client is no longer supported…" }]
/// }
/// ```
///
/// 原来的实现在拿不到 currentTier 时回落成写死的「Gemini 免费额度」——
/// 那是**编的**：真相是这个账号在这个客户端下**根本不能用免费额度**。
/// 一个编出来的档位比"未知"糟得多，因为用户会据此以为自己有额度可用。
///
/// 所以顺序是：currentTier（真在用的）→ allowedTiers（能用的）→
/// ineligibleTiers（不能用，把 Google 自己的原因原样带出来）→ 未知。
AccountQuota parseCodeAssistTier(Map<String, Object?> json) {
  String? nameOf(Object? tier) {
    if (tier is! Map) return null;
    final value =
        (tier['name'] ?? tier['tierName'] ?? tier['id'] ?? tier['tierId'])
            ?.toString();
    return value == null || value.isEmpty ? null : value;
  }

  const noUsage = 'Code Assist 不返回用量，余量查不到';

  final current = nameOf(json['currentTier']);
  if (current != null) {
    return AccountQuota(plan: current, detail: noUsage);
  }

  final allowed = json['allowedTiers'];
  if (allowed is List && allowed.isNotEmpty) {
    final first = allowed.first;
    final name = nameOf(first) ?? '可用档位';
    // `userDefinedCloudaicompanionProject` 是关键：为 true 表示这个档位要用
    // **你自己的 GCP 项目**，而这条路的卖点本来是"不需要 GCP 项目"。
    // 不说出来的话，用户会以为登录完就能聊，然后撞上一个语焉不详的 400。
    final needsProject =
        first is Map && first['userDefinedCloudaicompanionProject'] == true;
    return AccountQuota(
      plan: name,
      detail: needsProject ? '这个档位要绑定你自己的 GCP 项目才能用；$noUsage' : noUsage,
    );
  }

  final ineligible = json['ineligibleTiers'];
  if (ineligible is List && ineligible.isNotEmpty) {
    final first = ineligible.first;
    final name = nameOf(first) ?? '免费额度';
    // 把 Google 自己的话原样带出来。我们复述一遍只会丢信息，而这条消息里
    // 往往有唯一可操作的线索（比如"迁到 Antigravity"）。
    final reason = first is Map
        ? (first['reasonMessage'] ?? first['reasonCode'])?.toString()
        : null;
    return AccountQuota(
      plan: '不可用',
      detail: reason == null || reason.isEmpty
          ? '$name 对这个账号不可用'
          : '$name 不可用：$reason',
    );
  }

  return const AccountQuota(
    plan: '档位未知',
    detail: 'loadCodeAssist 没有返回任何档位信息',
  );
}

/// 回跳之后浏览器里显示的那一页。
///
/// 必须有：不给页面的话浏览器会停在一个空白或报错的标签上，用户不知道该不该
/// 切回 app。内联样式而不是外链，因为这一页是从回环服务器上发出来的，
/// 拉不到任何外部资源。
/// 把网络层那些异常翻成一句用户能照着做的话。
///
/// 原样抛出去的是
/// `ClientException with SocketException: Failed host lookup:
/// 'oauth2.googleapis.com' (OS Error: No address associated with hostname,
/// errno = 7)` —— 里面每个字都对，但它没告诉用户下一步该干什么。
///
/// 而这一类失败**几乎只有一个原因**：授权页是交给系统浏览器打开的（浏览器
/// 可能挂着 VPN、走着自己的 DNS），而换 token 这一步是 **app 自己发的请求**，
/// 走的是另一条路。浏览器打得开、这里连不上，是这两条路不一样造成的，
/// 而修法就一个：把登录代理配上。
Future<T> _describeNetworkFailure<T>(Future<T> Function() request) async {
  try {
    return await request();
  } on OAuthException {
    rethrow;
  } on SocketException catch (e) {
    throw OAuthException(_networkHint(e.osError?.message ?? e.message));
  } on http.ClientException catch (e) {
    throw OAuthException(_networkHint(e.message));
  } on HandshakeException catch (e) {
    throw OAuthException(_networkHint(e.message));
  }
}

String _networkHint(String detail) => '连不上 Google 的认证服务器。\n\n'
    '换 token 这一步是 Burrow 自己发的请求，不经过刚才那个浏览器 —— '
    '所以浏览器能打开、这里却连不上，通常是没配登录代理。\n'
    '到「渠道管理 → Google → 登录代理」填一个（比如 127.0.0.1:7890），'
    '再登一次。\n\n'
    '原始错误：$detail';

String _resultPage(String title, String detail) {
  final safeTitle = const HtmlEscape().convert(title);
  final safeDetail = const HtmlEscape().convert(detail);
  return '''
<!doctype html><html lang="zh"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Burrow</title></head>
<body style="margin:0;display:flex;align-items:center;justify-content:center;
height:100vh;font-family:system-ui,-apple-system,sans-serif;background:#17212b;color:#fff">
<div style="text-align:center;padding:24px">
<div style="font-size:20px;font-weight:600;margin-bottom:8px">$safeTitle</div>
<div style="font-size:14px;opacity:.7">$safeDetail</div>
</div></body></html>''';
}

String _randomUrlSafe(int bytes) {
  final random = Random.secure();
  final values = List<int>.generate(bytes, (_) => random.nextInt(256));
  return base64Url.encode(values).replaceAll('=', '');
}

/// 一个极小的 SHA-256。
///
/// 直接用 `package:crypto` —— 它已经在依赖里（SnapshotStore 和发行版校验都用
/// 它），不必为 PKCE 再引一个。
List<int> _sha256(List<int> data) => crypto.sha256.convert(data).bytes;

/// Google 账号 + Antigravity / Code Assist。
///
/// 这条路不需要用户有 GCP 项目：`:loadCodeAssist` 会返回一个 Google 替这个
/// 账号托管的项目号，之后所有请求都用它。**代价是它是个未公开接口** ——
/// 路径里那个 `v1internal` 就是在说这件事。
class GoogleCodeAssistFlow implements RedirectFlowProvider {
  GoogleCodeAssistFlow({
    GoogleOAuthClient client = GoogleOAuthClient.bundled,
    http.Client? httpClient,
  }) : _core = _GoogleAuthCore(
          client: client,
          scopes: _antigravityScopes,
          httpClient: httpClient,
        );

  final _GoogleAuthCore _core;

  static const providerId = 'google_code_assist';

  @override
  String get id => providerId;

  @override
  String get displayName => 'Google 账号（Antigravity）';

  @override
  String get hint => '使用 Antigravity OAuth 登录；账号资格和可用档位由 Google 返回';

  @override
  String get family => googleFamily;

  @override
  String get familyName => 'Google 账号';

  @override
  String get modeName => 'Antigravity / Code Assist';

  /// 问一次 `:loadCodeAssist` 拿档位。
  ///
  /// 能问出"免费版 / Pro"，**问不出余量** —— 这个接口不返回用量。所以
  /// [AccountQuota.usedPercent] 留空，界面会显示"未知"而不是编一个数。
  @override
  Future<AccountQuota?> fetchQuota(OAuthCredential credential) async =>
      _core.loadTier(credential, baseUrl: apiBaseUrl);

  @override
  String get apiBaseUrl => 'https://cloudcode-pa.googleapis.com/v1internal';

  @override
  String get apiFormat => 'gemini';

  @override
  Future<RedirectAuthSession> start() => _core.start();

  @override
  Future<OAuthCredential> refresh(OAuthCredential expired) =>
      _core.refresh(expired);
}

/// Google 账号 + 自己的 GCP 项目上的 Vertex AI。
///
/// baseUrl 依赖项目和区域，登录时还不知道，所以这里给空串 —— 由渠道设置里
/// 那两个字段拼出来（见 [vertexBaseUrl]）。
///
/// 走的是 Vertex 的 **OpenAI 兼容端点**，所以 apiFormat 是 `openAI`：请求体、
/// 流式解析、工具调用全部复用现有那条路径，一行新协议代码都不用写。
class GoogleVertexFlow implements RedirectFlowProvider {
  GoogleVertexFlow({
    GoogleOAuthClient client = GoogleOAuthClient.bundled,
    http.Client? httpClient,
  }) : _core = _GoogleAuthCore(
          client: client,
          scopes: _vertexScopes,
          httpClient: httpClient,
        );

  final _GoogleAuthCore _core;

  static const providerId = 'google_vertex';

  @override
  String get id => providerId;

  @override
  String get displayName => 'Google 账号（Vertex AI）';

  @override
  String get hint => '用自己的 GCP 项目，需要填项目 ID 和区域并开通计费';

  @override
  String get family => googleFamily;

  @override
  String get familyName => 'Google 账号';

  @override
  String get modeName => 'Vertex AI（自己的项目）';

  /// Vertex 是按量计费，没有"余量"这个概念 —— 账单在 GCP 那边。
  /// 说清楚比返回 null（界面上是"这一家不支持"）准确。
  @override
  Future<AccountQuota?> fetchQuota(OAuthCredential credential) async =>
      const AccountQuota(
        plan: '按量计费',
        detail: 'Vertex 按调用计费，没有配额余量。用量和账单在 GCP 控制台看',
      );

  @override
  String get apiBaseUrl => '';

  @override
  String get apiFormat => 'openAI';

  @override
  Future<RedirectAuthSession> start() => _core.start();

  @override
  Future<OAuthCredential> refresh(OAuthCredential expired) =>
      _core.refresh(expired);

  /// 拼出 Vertex 的 OpenAI 兼容基地址。
  ///
  /// 现有的端点解析器会在后面接 `/chat/completions`，所以这里只到
  /// `endpoints/openapi` 为止。
  ///
  /// `global` 区域的主机名没有区域前缀，是个特例；照通用规则拼会得到
  /// `global-aiplatform.googleapis.com`，那个域名不存在。
  static String vertexBaseUrl({
    required String project,
    required String location,
  }) {
    final loc = location.trim().isEmpty ? 'global' : location.trim();
    final host = loc == 'global'
        ? 'aiplatform.googleapis.com'
        : '$loc-aiplatform.googleapis.com';
    return 'https://$host/v1/projects/${project.trim()}'
        '/locations/$loc/endpoints/openapi';
  }
}
