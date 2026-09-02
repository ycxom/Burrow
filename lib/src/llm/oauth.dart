/// OAuth 登录：设备码流程（Device Authorization Grant）。
///
/// ## 为什么是设备码而不是浏览器回跳
///
/// 移植自 cc-switch 的 `codex_oauth_auth.rs` / `xai_oauth_auth.rs`，它们两个
/// 用的都是设备码。在手机上这个选择更有理由：
///
///   - **不需要本地 HTTP 服务器。** 桌面端 PKCE 回跳要在 127.0.0.1 上开一个
///     端口收 `?code=`。Android 上开端口要么被系统回收，要么和别的 app 撞。
///   - **不需要注册自定义 URL scheme。** 用 `burrow://callback` 意味着任何
///     装了同名 scheme 的 app 都能抢到授权码 —— Android 不保证 scheme 唯一。
///   - **换手机/换浏览器都能用。** 用户可以在电脑上打开验证页面输码。
///
/// 代价是要轮询，以及用户得手抄一串码。对一个一次性的登录动作，这个代价可接受。
///
/// ## 两家的协议并不一样
///
/// xAI 走标准 RFC 8628：`POST device_authorization_endpoint` → 轮询
/// `token_endpoint`，错误码用 `authorization_pending` / `slow_down`。
/// 端点从 OIDC discovery 拉，不写死。
///
/// OpenAI **不是**标准设备码：它自己一套 `deviceauth/usercode` +
/// `deviceauth/token`，轮询成功返回的不是 token 而是
/// `{authorization_code, code_verifier}`，还要再拿去 `/oauth/token` 换一次。
/// 未授权时用 HTTP 403/404 表示（而不是 JSON 里的 error 字段），过期用 410。
/// 这些都不能想当然，是照着 cc-switch 的实现抄的。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// 一次设备码登录的起始信息，交给 UI 显示。
class DeviceCodeGrant {
  /// 轮询时用的凭据。OpenAI 这里放的是 `device_auth_id`。
  final String deviceCode;

  /// 给用户看、要手输到网页里的码。
  final String userCode;

  /// 用户要打开的网址。
  final String verificationUri;

  /// 有效期。
  final Duration expiresIn;

  /// 服务端要求的最小轮询间隔。
  final Duration interval;

  const DeviceCodeGrant({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.expiresIn,
    required this.interval,
  });
}

/// 登录成功后拿到的凭据。
class OAuthCredential {
  final String accessToken;
  final String? refreshToken;
  final DateTime expiresAt;

  /// 从 id_token 里解出来的邮箱，用于在 UI 上显示"登录为谁"。
  final String? email;

  /// OpenAI 特有：调 ChatGPT 后端要带的账号 id。
  final String? accountId;

  const OAuthCredential({
    required this.accessToken,
    this.refreshToken,
    required this.expiresAt,
    this.email,
    this.accountId,
  });

  /// 提前 60 秒算过期。刚好卡在边界上刷新会撞上时钟漂移，
  /// 而一次 401 要用户重登，代价远大于多刷一次。
  bool get isExpired =>
      DateTime.now().isAfter(expiresAt.subtract(const Duration(seconds: 60)));

  Map<String, Object?> toJson() => {
        'access_token': accessToken,
        'refresh_token': refreshToken,
        'expires_at': expiresAt.toIso8601String(),
        'email': email,
        'account_id': accountId,
      };

  static OAuthCredential fromJson(Map<String, Object?> j) => OAuthCredential(
        accessToken: j['access_token']! as String,
        refreshToken: j['refresh_token'] as String?,
        expiresAt: DateTime.parse(j['expires_at']! as String),
        email: j['email'] as String?,
        accountId: j['account_id'] as String?,
      );
}

/// 轮询的中间状态。用返回值而不是异常表示"还没授权"——
/// 那是流程的正常状态，一秒钟发生一次，不该走异常路径。
enum PollStatus { pending, authorized, denied, expired }

class PollResult {
  final PollStatus status;
  final OAuthCredential? credential;

  /// 服务端要求放慢时的新间隔。
  final Duration? slowDownTo;

  const PollResult(this.status, {this.credential, this.slowDownTo});
}

class OAuthException implements Exception {
  final String message;
  const OAuthException(this.message);
  @override
  String toString() => message;
}

/// 一个账号的套餐和余量。
///
/// ## 为什么字段这么松
///
/// 各家能查到的东西**完全不在一个层级上**，硬套一个统一的数值模型只会逼着
/// 实现方编数字：
///
///   - ChatGPT 的套餐名写在 access_token 的声明里，一次网络请求都不用发；
///     真正的"剩多少"只在**聊天响应头**里，要发过一次请求才知道。
///   - Google Code Assist 能问出档位（免费版 / Pro），但问不出余量。
///   - Vertex 是按量计费，根本没有"余量"这个概念。
///   - xAI 没有可查的额度接口。
///
/// 所以这里只有 [plan] 是必填的，余下的能拿到就填。UI 对 null 显示"未知"，
/// **不显示 0** —— "不知道"和"用完了"是两件不能混的事。
class AccountQuota {
  const AccountQuota({
    required this.plan,
    this.detail,
    this.usedPercent,
    this.resetsAt,
    this.fetchedAt,
  });

  /// 套餐名。"Plus" / "免费版" / "按量计费"。
  final String plan;

  /// 补充说明。查不到余量时用它讲清楚为什么。
  final String? detail;

  /// 已用比例，0~1。null = 查不到。
  final double? usedPercent;

  /// 配额窗口重置时间。
  final DateTime? resetsAt;

  /// 这份数据是什么时候拿到的。缓存展示时要说清新鲜度 ——
  /// 一个三天前的余量显示得像实时的，比不显示更误导。
  final DateTime? fetchedAt;

  AccountQuota withFetchedAt(DateTime at) => AccountQuota(
        plan: plan,
        detail: detail,
        usedPercent: usedPercent,
        resetsAt: resetsAt,
        fetchedAt: at,
      );

  /// 一行摘要，给渠道列表用。
  String get summary {
    final bits = <String>[plan];
    if (usedPercent != null) {
      final left = ((1 - usedPercent!) * 100).clamp(0, 100).round();
      bits.add('剩 $left%');
    }
    return bits.join(' · ');
  }

  Map<String, Object?> toJson() => {
        'plan': plan,
        'detail': detail,
        'used_percent': usedPercent,
        'resets_at': resetsAt?.toIso8601String(),
        'fetched_at': fetchedAt?.toIso8601String(),
      };

  static AccountQuota? fromJson(Map<String, Object?> j) {
    final plan = j['plan'] as String?;
    if (plan == null || plan.isEmpty) return null;
    DateTime? at(Object? raw) =>
        raw is String ? DateTime.tryParse(raw) : null;
    return AccountQuota(
      plan: plan,
      detail: j['detail'] as String?,
      usedPercent: (j['used_percent'] as num?)?.toDouble(),
      resetsAt: at(j['resets_at']),
      fetchedAt: at(j['fetched_at']),
    );
  }
}

/// 一家可登录的服务商。
///
/// 拆出这个父类是因为**不是所有服务商都能走设备码**：Google 的设备码流程把
/// scope 锁死在 email/openid/profile + Drive/YouTube，登录得了但调不了模型
/// （见 google_oauth.dart 的说明）。它必须走回跳，而账号存储、刷新、绑定渠道
/// 这些事对两种流程是一样的 —— 一样的部分放这里，不一样的放子类。
abstract class OAuthProvider {
  /// 存储用的稳定标识。
  String get id;

  String get displayName;

  /// 登录成功后应该用哪个 baseUrl 调模型接口。
  ///
  /// 有些服务商这个地址依赖登录后才知道的东西（Vertex 要项目和区域），
  /// 那种情况下这里给一个模板或空串，由渠道设置补齐。
  String get apiBaseUrl;

  /// 这家用的接口协议（对齐 LlmConfig.apiFormat）。
  String get apiFormat;

  /// 一句话说清这家登录之后能用什么、需要什么。显示在登录入口下面。
  String get hint => '';

  /// 分组标识。同一个 family 的 provider 在界面上收成一行。
  ///
  /// Google 有两种登录模式（免费额度 / 自己的 Vertex 项目），它们是两个
  /// provider —— apiBaseUrl 和 apiFormat 都不一样。但对用户来说那是**一家**，
  /// 在登录列表里并排摆两条"Google 账号"只会让人以为要登两次。
  String get family => id;

  /// 这一家的显示名。同 family 的 provider 要给同一个值。
  String get familyName => displayName;

  /// 这个模式在家族里的名字。单模式家族用不上。
  String get modeName => displayName;

  /// 查这个账号的套餐和余量。
  ///
  /// 返回 null = 这家没有可查的接口。**不要为了让界面好看而编一个** ——
  /// 用户看到"剩 100%"会据此决定要不要开始一个长任务。
  Future<AccountQuota?> fetchQuota(OAuthCredential credential) async => null;

  /// 用 refresh_token 换新的 access_token。
  /// 抛 [OAuthException] 表示 refresh_token 也废了，要重新登录。
  Future<OAuthCredential> refresh(OAuthCredential expired);
}

/// 一家服务商的设备码登录。
abstract class DeviceFlowProvider implements OAuthProvider {
  Future<DeviceCodeGrant> start();

  Future<PollResult> poll(DeviceCodeGrant grant);
}

/// 一次回跳登录的进行中会话。
///
/// 和设备码不同，回跳流程没有"轮询"这一步：本地回环服务器一直挂着，
/// 浏览器带着 `?code=` 回来的那一刻就结束了。所以它暴露的是一个 Future，
/// 而不是一个要 UI 自己驱动的轮询循环。
class RedirectAuthSession {
  /// 要在浏览器里打开的授权地址。
  final String authorizationUrl;

  /// 授权完成（或失败）时结束。
  final Future<OAuthCredential> result;

  /// 放弃登录：关掉本地服务器，让 [result] 以 [OAuthException] 结束。
  final Future<void> Function() cancel;

  const RedirectAuthSession({
    required this.authorizationUrl,
    required this.result,
    required this.cancel,
  });
}

/// 一家服务商的浏览器回跳登录（授权码 + PKCE）。
abstract class RedirectFlowProvider implements OAuthProvider {
  /// 起一个本地回环服务器并算出授权地址。调用方负责把地址交给浏览器。
  Future<RedirectAuthSession> start();
}

// ---------------------------------------------------------------------------
// 工具
// ---------------------------------------------------------------------------

/// 解 JWT 的 payload。**不验签** —— 这些 token 是我们刚从 TLS 连接上
/// 亲手拿到的，不是别人递过来的，验签防不住任何这里会出现的问题。
/// 解它只为读出 email / account_id 这类展示用的声明。
Map<String, Object?>? decodeJwtClaims(String jwt) {
  final parts = jwt.split('.');
  if (parts.length < 2) return null;
  try {
    var payload = parts[1].replaceAll('-', '+').replaceAll('_', '/');
    // base64url 去掉了填充，要补回来才能解。
    payload = payload.padRight((payload.length + 3) ~/ 4 * 4, '=');
    final decoded = utf8.decode(base64.decode(payload));
    final value = jsonDecode(decoded);
    return value is Map<String, Object?> ? value : null;
  } catch (_) {
    // 声明解不出来不该让登录失败 —— 那只影响 UI 上显示的邮箱。
    return null;
  }
}

/// 从一串 JSON 里按多个候选键找第一个非空字符串。
///
/// 单独抽出来是因为这些声明的位置不稳定：`chatgpt_account_id` 可能在
/// 顶层，也可能嵌在 `https://api.openai.com/auth` 这个带命名空间的键里面。
String? _firstString(Map<String, Object?> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value is String && value.isNotEmpty) return value;
  }
  return null;
}

int _asInt(Object? value, int fallback) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

Map<String, Object?> _decodeJson(http.Response response) {
  if (response.body.isEmpty) return const {};
  final value = jsonDecode(response.body);
  return value is Map<String, Object?> ? value : const {};
}

String _briefBody(String body) =>
    body.length <= 300 ? body : '${body.substring(0, 300)}…';

// ---------------------------------------------------------------------------
// OpenAI / ChatGPT（Codex）
// ---------------------------------------------------------------------------

/// OpenAI 的 ChatGPT 订阅登录。
///
/// 这套端点是 Codex CLI 用的那一套，**不是** OpenAI 的标准 OAuth ——
/// 常量和请求体形状都取自 cc-switch 的 `codex_oauth_auth.rs`。
class OpenAiDeviceFlow implements DeviceFlowProvider {
  final http.Client _http;
  OpenAiDeviceFlow({http.Client? client}) : _http = client ?? http.Client();

  static const _clientId = 'app_EMoamEEZ73f0CkXaXp7hrann';
  static const _usercodeUrl =
      'https://auth.openai.com/api/accounts/deviceauth/usercode';
  static const _deviceTokenUrl =
      'https://auth.openai.com/api/accounts/deviceauth/token';
  static const _tokenUrl = 'https://auth.openai.com/oauth/token';
  static const _verificationUrl = 'https://auth.openai.com/codex/device';

  /// 换 token 时要带的 redirect_uri。设备码流程里没有真正的回跳，
  /// 但服务端仍然按 OAuth 规范校验这个值必须和签发时一致。
  static const _redirectUri = 'https://auth.openai.com/deviceauth/callback';

  static const _userAgent = 'burrow-openai-oauth';

  @override
  String get id => 'openai_oauth';

  @override
  String get displayName => 'ChatGPT（OpenAI 订阅）';

  @override
  String get hint => '用 ChatGPT 订阅额度，不需要 API key';

  // 单模式家族：自成一家，三个名字都用同一个。
  @override
  String get family => id;

  @override
  String get familyName => displayName;

  @override
  String get modeName => displayName;

  /// 套餐名直接从 access_token 的声明里读 —— 一次网络请求都不用发。
  ///
  /// **余量不在这里。** ChatGPT 的用量只出现在聊天响应头上（见
  /// [parseCodexRateLimit]），也就是说必须先发过一次请求才知道。所以刚登录
  /// 完的账号只有套餐名，聊过一句之后才会有百分比。
  @override
  Future<AccountQuota?> fetchQuota(OAuthCredential credential) async {
    for (final jwt in <String?>[credential.accessToken]) {
      if (jwt == null) continue;
      final claims = decodeJwtClaims(jwt);
      if (claims == null) continue;
      final plan = _findPlan(claims);
      if (plan != null) {
        return AccountQuota(
          plan: _planLabel(plan),
          detail: '余量要发过一次请求之后才能读到',
        );
      }
    }
    return const AccountQuota(
      plan: 'ChatGPT 账号',
      detail: '令牌里没有套餐信息，余量要发过一次请求之后才能读到',
    );
  }

  /// `chatgpt_plan_type` 可能在顶层，也可能嵌在带命名空间的那一层里 ——
  /// 和 `chatgpt_account_id` 是同一个毛病。
  static String? _findPlan(Map<String, Object?> claims) {
    final direct = _firstString(claims, ['chatgpt_plan_type']);
    if (direct != null) return direct;
    for (final value in claims.values) {
      if (value is Map<String, Object?>) {
        final nested = _firstString(value, ['chatgpt_plan_type']);
        if (nested != null) return nested;
      }
    }
    return null;
  }

  static String _planLabel(String raw) => switch (raw.toLowerCase()) {
        'free' => '免费版',
        'plus' => 'ChatGPT Plus',
        'pro' => 'ChatGPT Pro',
        'team' => 'ChatGPT Team',
        'enterprise' => 'ChatGPT Enterprise',
        _ => raw,
      };

  /// 订阅登录走的是 Codex 后端，不是 `api.openai.com`。
  @override
  String get apiBaseUrl => 'https://chatgpt.com/backend-api/codex';

  @override
  String get apiFormat => 'openAI';

  @override
  Future<DeviceCodeGrant> start() async {
    final response = await _http.post(
      Uri.parse(_usercodeUrl),
      headers: const {
        'Content-Type': 'application/json',
        'User-Agent': _userAgent,
      },
      body: jsonEncode({'client_id': _clientId}),
    );
    if (response.statusCode != 200) {
      throw OAuthException(
          '获取设备码失败：HTTP ${response.statusCode} ${_briefBody(response.body)}');
    }
    final json = _decodeJson(response);
    final deviceAuthId = json['device_auth_id'] as String?;
    final userCode = json['user_code'] as String?;
    if (deviceAuthId == null || userCode == null) {
      throw const OAuthException('设备码响应缺少 device_auth_id 或 user_code');
    }
    return DeviceCodeGrant(
      deviceCode: deviceAuthId,
      userCode: userCode,
      verificationUri: _verificationUrl,
      expiresIn: Duration(seconds: _asInt(json['expires_in'], 900)),
      interval: Duration(seconds: _asInt(json['interval'], 5)),
    );
  }

  @override
  Future<PollResult> poll(DeviceCodeGrant grant) async {
    final response = await _http.post(
      Uri.parse(_deviceTokenUrl),
      headers: const {
        'Content-Type': 'application/json',
        'User-Agent': _userAgent,
      },
      body: jsonEncode({
        'device_auth_id': grant.deviceCode,
        'user_code': grant.userCode,
      }),
    );

    // 这里不是标准 OAuth：未授权用 HTTP 状态码表示，不是 JSON 里的 error。
    // 403/404 = 还没点确认；410 = 码过期了。
    if (response.statusCode == 403 || response.statusCode == 404) {
      return const PollResult(PollStatus.pending);
    }
    if (response.statusCode == 410) {
      return const PollResult(PollStatus.expired);
    }
    if (response.statusCode != 200) {
      throw OAuthException(
          '轮询失败：HTTP ${response.statusCode} ${_briefBody(response.body)}');
    }

    final json = _decodeJson(response);
    final code = json['authorization_code'] as String?;
    final verifier = json['code_verifier'] as String?;
    if (code == null || verifier == null) {
      throw const OAuthException('授权响应缺少 authorization_code / code_verifier');
    }
    final credential = await _exchange(code, verifier);
    return PollResult(PollStatus.authorized, credential: credential);
  }

  Future<OAuthCredential> _exchange(String code, String verifier) async {
    final response = await _http.post(
      Uri.parse(_tokenUrl),
      headers: const {
        'Content-Type': 'application/x-www-form-urlencoded',
        'User-Agent': _userAgent,
      },
      body: {
        'grant_type': 'authorization_code',
        'code': code,
        'redirect_uri': _redirectUri,
        'client_id': _clientId,
        'code_verifier': verifier,
      },
    );
    if (response.statusCode != 200) {
      throw OAuthException(
          '换取 token 失败：HTTP ${response.statusCode} ${_briefBody(response.body)}');
    }
    return _credentialFrom(_decodeJson(response), previousRefresh: null);
  }

  @override
  Future<OAuthCredential> refresh(OAuthCredential expired) async {
    final token = expired.refreshToken;
    if (token == null) {
      throw const OAuthException('没有 refresh_token，需要重新登录');
    }
    final response = await _http.post(
      Uri.parse(_tokenUrl),
      headers: const {
        'Content-Type': 'application/x-www-form-urlencoded',
        'User-Agent': _userAgent,
      },
      body: {
        'grant_type': 'refresh_token',
        'refresh_token': token,
        'client_id': _clientId,
        // 不带 openid scope 的话响应里不会有新的 id_token，
        // 账号信息就丢了（cc-switch 的注释里也记了这一条）。
        'scope': 'openid profile email',
      },
    );
    if (response.statusCode != 200) {
      throw OAuthException('刷新失败，需要重新登录：HTTP ${response.statusCode}');
    }
    return _credentialFrom(_decodeJson(response), previousRefresh: token);
  }

  OAuthCredential _credentialFrom(
    Map<String, Object?> json, {
    required String? previousRefresh,
  }) {
    final accessToken = json['access_token'] as String?;
    if (accessToken == null) {
      throw const OAuthException('响应缺少 access_token');
    }
    // 刷新响应有时不带新的 refresh_token，这时要继续用旧的 ——
    // 置空会让下一次刷新直接判定"需要重新登录"。
    final refreshToken = json['refresh_token'] as String? ?? previousRefresh;

    String? email;
    String? accountId;
    for (final jwt in [json['id_token'], accessToken]) {
      if (jwt is! String) continue;
      final claims = decodeJwtClaims(jwt);
      if (claims == null) continue;
      email ??= _firstString(claims, ['email']);
      accountId ??= _firstString(claims, ['chatgpt_account_id']);
      // 带命名空间的那一层：`https://api.openai.com/auth` → chatgpt_account_id
      if (accountId == null) {
        for (final value in claims.values) {
          if (value is Map<String, Object?>) {
            accountId = _firstString(value, ['chatgpt_account_id']);
            if (accountId != null) break;
          }
        }
      }
      if (email != null && accountId != null) break;
    }

    return OAuthCredential(
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiresAt: DateTime.now()
          .add(Duration(seconds: _asInt(json['expires_in'], 3600))),
      email: email,
      accountId: accountId,
    );
  }
}

// ---------------------------------------------------------------------------
// xAI / Grok
// ---------------------------------------------------------------------------

/// xAI 的设备码登录。标准 RFC 8628。
///
/// 端点从 OIDC discovery 拉而不是写死 —— cc-switch 特意这么做，理由是
/// 协议端点变了不用改代码。这里沿用：discovery 文档只在第一次登录时取一次。
class XaiDeviceFlow implements DeviceFlowProvider {
  final http.Client _http;
  XaiDeviceFlow({http.Client? client}) : _http = client ?? http.Client();

  static const _discoveryUrl =
      'https://auth.x.ai/.well-known/openid-configuration';
  static const _clientId = 'b1a00492-073a-47ea-816f-4c329264a828';
  static const _scope =
      'openid profile email offline_access grok-cli:access api:access';
  static const _userAgent = 'burrow-xai-oauth';

  String? _deviceEndpoint;
  String? _tokenEndpoint;

  @override
  String get id => 'xai_oauth';

  @override
  String get displayName => 'Grok（xAI 订阅）';

  @override
  String get hint => '用 xAI 订阅额度，不需要 API key';

  // 单模式家族：自成一家，三个名字都用同一个。
  @override
  String get family => id;

  @override
  String get familyName => displayName;

  @override
  String get modeName => displayName;

  /// xAI 没有公开的额度查询接口。
  ///
  /// 返回一个只有套餐名、明说余量查不到的结果，而不是 null —— null 在界面上
  /// 是"这一家不支持"，而这里的真相是"支持，但对面没提供接口"。两者对用户
  /// 该不该继续等一个数字是不同的答案。
  @override
  Future<AccountQuota?> fetchQuota(OAuthCredential credential) async =>
      const AccountQuota(
        plan: 'xAI 订阅',
        detail: 'xAI 没有公开的额度查询接口，余量只能去官网看',
      );

  @override
  String get apiBaseUrl => 'https://api.x.ai/v1';

  @override
  String get apiFormat => 'openAI';

  Future<void> _discover() async {
    if (_deviceEndpoint != null && _tokenEndpoint != null) return;
    final response = await _http.get(
      Uri.parse(_discoveryUrl),
      headers: const {'User-Agent': _userAgent},
    );
    if (response.statusCode != 200) {
      throw OAuthException('读取 xAI 端点配置失败：HTTP ${response.statusCode}');
    }
    final json = _decodeJson(response);
    _deviceEndpoint = json['device_authorization_endpoint'] as String?;
    _tokenEndpoint = json['token_endpoint'] as String?;
    if (_deviceEndpoint == null || _tokenEndpoint == null) {
      throw const OAuthException('xAI 端点配置里缺少设备码或 token 端点');
    }
  }

  @override
  Future<DeviceCodeGrant> start() async {
    await _discover();
    final response = await _http.post(
      Uri.parse(_deviceEndpoint!),
      headers: const {
        'Content-Type': 'application/x-www-form-urlencoded',
        'User-Agent': _userAgent,
      },
      body: {'client_id': _clientId, 'scope': _scope},
    );
    if (response.statusCode != 200) {
      throw OAuthException(
          '获取设备码失败：HTTP ${response.statusCode} ${_briefBody(response.body)}');
    }
    final json = _decodeJson(response);
    final deviceCode = json['device_code'] as String?;
    final userCode = json['user_code'] as String?;
    if (deviceCode == null || userCode == null) {
      throw const OAuthException('设备码响应缺少 device_code 或 user_code');
    }
    return DeviceCodeGrant(
      deviceCode: deviceCode,
      userCode: userCode,
      // verification_uri_complete 里已经带上了 user_code，用户点开就不用手输。
      // 优先用它，没有再退回裸地址。
      verificationUri: (json['verification_uri_complete'] as String?) ??
          (json['verification_uri'] as String? ?? 'https://auth.x.ai/device'),
      expiresIn: Duration(seconds: _asInt(json['expires_in'], 900)),
      interval: Duration(seconds: _asInt(json['interval'], 5)),
    );
  }

  @override
  Future<PollResult> poll(DeviceCodeGrant grant) async {
    await _discover();
    final response = await _http.post(
      Uri.parse(_tokenEndpoint!),
      headers: const {
        'Content-Type': 'application/x-www-form-urlencoded',
        'User-Agent': _userAgent,
      },
      body: {
        'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
        'client_id': _clientId,
        'device_code': grant.deviceCode,
      },
    );

    final json = _decodeJson(response);
    final error = json['error'] as String?;
    if (error != null) {
      switch (error) {
        case 'authorization_pending':
          return const PollResult(PollStatus.pending);
        case 'slow_down':
          // 服务端嫌快了。加 5 秒是 RFC 建议的做法。
          return PollResult(PollStatus.pending,
              slowDownTo: grant.interval + const Duration(seconds: 5));
        case 'access_denied':
          return const PollResult(PollStatus.denied);
        case 'expired_token':
          return const PollResult(PollStatus.expired);
        default:
          throw OAuthException('授权失败：$error');
      }
    }
    if (response.statusCode != 200) {
      throw OAuthException(
          '轮询失败：HTTP ${response.statusCode} ${_briefBody(response.body)}');
    }
    return PollResult(PollStatus.authorized,
        credential: _credentialFrom(json, previousRefresh: null));
  }

  @override
  Future<OAuthCredential> refresh(OAuthCredential expired) async {
    final token = expired.refreshToken;
    if (token == null) {
      throw const OAuthException('没有 refresh_token，需要重新登录');
    }
    await _discover();
    final response = await _http.post(
      Uri.parse(_tokenEndpoint!),
      headers: const {
        'Content-Type': 'application/x-www-form-urlencoded',
        'User-Agent': _userAgent,
      },
      body: {
        'grant_type': 'refresh_token',
        'client_id': _clientId,
        'refresh_token': token,
      },
    );
    if (response.statusCode != 200) {
      throw OAuthException('刷新失败，需要重新登录：HTTP ${response.statusCode}');
    }
    return _credentialFrom(_decodeJson(response), previousRefresh: token);
  }

  OAuthCredential _credentialFrom(
    Map<String, Object?> json, {
    required String? previousRefresh,
  }) {
    final accessToken = json['access_token'] as String?;
    if (accessToken == null) {
      throw const OAuthException('响应缺少 access_token');
    }
    String? email;
    final idToken = json['id_token'];
    if (idToken is String) {
      email = _firstString(decodeJwtClaims(idToken) ?? const {}, ['email']);
    }
    return OAuthCredential(
      accessToken: accessToken,
      refreshToken: json['refresh_token'] as String? ?? previousRefresh,
      expiresAt: DateTime.now()
          .add(Duration(seconds: _asInt(json['expires_in'], 3600))),
      email: email,
    );
  }
}

/// 从 Codex 后端的响应头里读出用量。
///
/// 这是 ChatGPT 唯一能拿到**真实余量**的地方 —— 没有独立的查询接口，
/// 数字只挂在聊天响应上。所以它是"聊过一句之后才知道"。
///
/// 头的名字是照 Codex CLI 的行为写的，不在任何公开文档里。所以这里**只读不
/// 校验**：认识哪个用哪个，一个都不认识就返回 null。名字将来变了，后果是
/// 余量不再显示，而不是登录或聊天出问题。
AccountQuota? parseCodexRateLimit(
  Map<String, String> headers, {
  required String plan,
}) {
  double? percent;
  for (final key in const <String>[
    'x-codex-primary-used-percent',
    'x-codex-used-percent',
  ]) {
    final raw = headers[key];
    final value = raw == null ? null : double.tryParse(raw);
    if (value != null) {
      percent = (value / 100).clamp(0.0, 1.0);
      break;
    }
  }
  if (percent == null) return null;

  DateTime? resetsAt;
  for (final key in const <String>[
    'x-codex-primary-reset-after-seconds',
    'x-codex-reset-after-seconds',
  ]) {
    final raw = headers[key];
    final seconds = raw == null ? null : int.tryParse(raw);
    if (seconds != null) {
      resetsAt = DateTime.now().add(Duration(seconds: seconds));
      break;
    }
  }

  return AccountQuota(
    plan: plan,
    usedPercent: percent,
    resetsAt: resetsAt,
    fetchedAt: DateTime.now(),
  );
}

// ---------------------------------------------------------------------------
// 轮询驱动
// ---------------------------------------------------------------------------

/// 按服务端给的节奏轮询，直到授权完成、被拒、过期或被取消。
///
/// 抽成一个函数而不是让 UI 自己写循环：间隔要能被 `slow_down` 改、
/// 超时要按 `expires_in` 算、取消要能立刻生效 —— 这几件事写错任何一件
/// 都会变成"一直转圈"或者"被服务端拉黑"，而它们和界面无关。
Stream<PollResult> pollUntilDone(
  DeviceFlowProvider provider,
  DeviceCodeGrant grant, {
  Future<void>? cancel,
}) async* {
  var interval = grant.interval;
  final deadline = DateTime.now().add(grant.expiresIn);
  var cancelled = false;
  unawaited(cancel?.then((_) => cancelled = true));

  while (!cancelled) {
    if (DateTime.now().isAfter(deadline)) {
      yield const PollResult(PollStatus.expired);
      return;
    }
    await Future<void>.delayed(interval);
    if (cancelled) return;

    final result = await provider.poll(grant);
    if (result.slowDownTo != null) interval = result.slowDownTo!;
    if (result.status != PollStatus.pending) {
      yield result;
      return;
    }
    yield result;
  }
}
