/// 从服务商拉可用模型列表。
///
/// 移植自 cc-switch 的 `services/model_fetch.rs`。核心不是"发个 GET"，
/// 而是**猜对端点**：用户填进来的 baseUrl 五花八门，
///
///   `https://api.deepseek.com`              → `/v1/models`
///   `https://api.siliconflow.cn/v1`         → `/models`（已经带版本段了）
///   `https://open.bigmodel.cn/api/paas/v4`  → `/models`（v4，不是 v1）
///   `https://xxx.com/api/anthropic`         → 剥掉兼容后缀再拼
///
/// 一律拼 `/v1/models` 的话，上面第二三种会得到 `.../v4/v1/models` → 404，
/// 而用户看到的是"获取模型失败"，完全无从下手。所以按候选列表依次试，
/// 第一个成功的就用它。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

class FetchedModel {
  final String id;
  final String? ownedBy;
  const FetchedModel(this.id, {this.ownedBy});
}

class ModelFetchException implements Exception {
  final String message;
  const ModelFetchException(this.message);
  @override
  String toString() => message;
}

const _codexOAuthModelsUrl = 'https://chatgpt.com/backend-api/codex/models';
const _codexClientVersion = '0.144.1';

/// ChatGPT 订阅 OAuth 的模型目录不是 OpenAI API 的 `/v1/models`。
/// 它属于 Codex 后端，并按账号工作区与客户端版本返回可用模型。
Future<List<FetchedModel>> fetchChatGptOAuthModels({
  required String accessToken,
  required String accountId,
  http.Client? client,
  Duration timeout = const Duration(seconds: 15),
}) async {
  if (accessToken.trim().isEmpty) {
    throw const ModelFetchException('ChatGPT OAuth token 为空，请重新登录');
  }
  if (accountId.trim().isEmpty) {
    throw const ModelFetchException('登录凭据缺少 ChatGPT Account ID，请退出该账号后重新登录');
  }
  final httpClient = client ?? http.Client();
  final uri = Uri.parse(_codexOAuthModelsUrl).replace(
    queryParameters: const {'client_version': _codexClientVersion},
  );
  http.Response response;
  try {
    response = await httpClient.get(uri, headers: {
      'Authorization': 'Bearer $accessToken',
      'Accept': 'application/json',
      'chatgpt-account-id': accountId,
      'originator': 'codex_cli_rs',
      'version': _codexClientVersion,
      'User-Agent': 'codex_cli_rs/$_codexClientVersion',
    }).timeout(timeout);
  } catch (error) {
    throw ModelFetchException('获取 ChatGPT 可用模型失败：$error');
  }
  if (response.statusCode < 200 || response.statusCode >= 300) {
    final body = response.body.length > 400
        ? '${response.body.substring(0, 400)}…'
        : response.body;
    throw ModelFetchException(
        '获取 ChatGPT 可用模型失败：HTTP ${response.statusCode} $body');
  }
  try {
    final models = parseModelsResponse(response.body);
    if (models.isEmpty) {
      throw const ModelFetchException('ChatGPT 返回了空模型列表，请确认订阅包含 Codex 权限');
    }
    return models;
  } on ModelFetchException {
    rethrow;
  } catch (error) {
    throw ModelFetchException('无法解析 ChatGPT 模型列表：$error');
  }
}

/// 已知的「Anthropic 协议兼容子路径」后缀。
///
/// 有些聚合站把 Anthropic 协议挂在这些子路径上，但模型列表在站点根上。
/// 按长度降序排，最长前缀优先匹配 —— 否则 `/api/anthropic` 会先被
/// `/anthropic` 匹配掉，剥出来的根就少剥了一段。
const _compatSuffixes = <String>[
  '/api/claudecode',
  '/api/anthropic',
  '/apps/anthropic',
  '/claudecode',
  '/anthropic',
  '/claude',
];

/// baseUrl 是不是以版本段结尾（`/v1`、`/v4`、`/v1beta`…）。
///
/// **必须认带后缀的版本号。** Google 的 Gemini 用的是 `v1beta`，只认
/// `v` + 纯数字的话，`.../v1beta` 会被判成"没有版本段"，于是再补一个 `/v1`，
/// 拼出 `.../v1beta/v1/models` —— 404。
///
/// 后缀只允许字母：`v1beta` / `v2alpha` 认，`video` 不认（`v` 后面第一个
/// 字符必须是数字），`v1.2` 也不认（点号不是字母）。
final _versionSegment = RegExp(r'^v\d+[a-z]*$');

bool endsWithVersionSegment(String url) {
  final idx = url.lastIndexOf('/');
  if (idx < 0 || idx == url.length - 1) return false;
  return _versionSegment.hasMatch(url.substring(idx + 1));
}

/// 这些子路径本身**就是**一个完整的 API 根，后面直接接 `/chat/completions`。
///
/// Gemini 的 OpenAI 兼容层挂在 `.../v1beta/openai` 上 —— 它以 `openai` 结尾，
/// 不是版本段，但再补一个 `/v1` 就错了。
const _apiRootSuffixes = <String>['/openai'];

/// baseUrl 已经是一个可以直接接接口路径的根。
bool looksLikeApiRoot(String url) {
  if (endsWithVersionSegment(url)) return true;
  final lower = url.toLowerCase();
  return _apiRootSuffixes.any(lower.endsWith);
}

/// Gemini 原生 REST 层的根地址（`geminiNative` 协议）。
///
/// 这一层认 `x-goog-api-key`，请求打到
/// `{root}/models/{model}:streamGenerateContent`。
const geminiNativeBaseUrl = 'https://generativelanguage.googleapis.com/v1beta';

/// Gemini 的 OpenAI 兼容层（`openAI` 协议）。
///
/// 这一层认 `Authorization: Bearer`，接口路径和 OpenAI 一模一样，所以接进来
/// 不用写任何新协议代码。
///
/// **代价是拿不到联网搜索。** grounding 在兼容层只对图片端点开放，
/// chat/completions 里塞 `{"google_search":{}}` 会被当成 OpenAI 的函数声明去
/// 校验，直接 `Unknown name 'google_search' at 'tools[0]'`。要搜索就得走
/// [geminiNativeBaseUrl]。
const geminiOpenAiBaseUrl = '$geminiNativeBaseUrl/openai';

const _geminiHost = 'generativelanguage.googleapis.com';

/// 这个 baseUrl 指向 Gemini，但**不是** [apiFormat] 这条协议该用的那个根。
///
/// 返回该改成什么；已经对了、或者根本不是 Gemini，就返回 null。
///
/// ## 为什么值得单独做一个函数
///
/// 这个主机上有几种写法会让人踩坑，而且它们的失败方式各不相同：
///
///   - `.../v1beta/models/<model>:generateContent`（从 Google 文档复制的完整
///     端点）→ 后面再拼任何路径都不存在 → **404**
///   - 裸主机名 `https://generativelanguage.googleapis.com` → 补成
///     `/v1/models`；`v1` 下没有这些模型，而且**兼容层的 Bearer 头原生层不认**
///     （原生层要 `x-goog-api-key`）→ **401**
///   - 协议选了原生却填着 `/v1beta/openai`（或反过来）→ 同样是 401 / 404
///
/// 症状（404 / 401）指向的直觉方向完全不同 —— 401 会让人去查密钥，而密钥是
/// 好的。实测有人在这个主机上连撞两次。**给定协议之后这个主机只有一个正确
/// 答案**，所以与其报错让人猜，不如直接说出该填什么。
String? geminiBaseUrlFix(String raw, {String apiFormat = 'openAI'}) {
  var trimmed = raw.trim();
  while (trimmed.endsWith('/')) {
    trimmed = trimmed.substring(0, trimmed.length - 1);
  }
  if (trimmed.isEmpty) return null;
  final host = Uri.tryParse(trimmed)?.host.toLowerCase() ?? '';
  if (host != _geminiHost) return null;
  // Code Assist（`gemini`）在另一个主机上，走不到这里。
  final want =
      apiFormat == 'geminiNative' ? geminiNativeBaseUrl : geminiOpenAiBaseUrl;
  if (trimmed.toLowerCase() == want) return null;
  return want;
}

/// 认证头。**原生层和兼容层不是同一个头。**
///
/// 原生层要 `x-goog-api-key`，兼容层要 `Authorization: Bearer`。拿错了返回
/// 401，而 401 看起来就是"密钥不对" —— 于是人会去换密钥，换多少个都没用。
Map<String, String> geminiAuthHeaders(String apiKey,
    {String apiFormat = 'openAI'}) {
  if (apiKey.isEmpty) return <String, String>{};
  if (apiFormat == 'geminiNative') {
    return <String, String>{'x-goog-api-key': apiKey};
  }
  return <String, String>{'Authorization': 'Bearer $apiKey'};
}

/// 协议在界面上的名字。报错信息要跟界面上的按钮对得上，否则用户不知道该点哪。
/// Code Assist 能用的模型。**写死的，不是拉回来的。**
///
/// 那个接口没有列表端点（见 [fetchModels] 里的说明），所以只能给一份已知
/// 可用的。列少了不影响使用：选择器允许手填，填什么就发什么 —— 而列一堆
/// 猜出来的名字才是真麻烦，用户挑中一个不存在的，得到的是一次莫名其妙的
/// 400，还看不出是自己挑错了。
const codeAssistModels = <String>[
  'gemini-2.5-pro',
  'gemini-2.5-flash',
];

String geminiProtocolLabel(String apiFormat) => switch (apiFormat) {
      'geminiNative' => 'Gemini 原生',
      'gemini' => 'Code Assist',
      'anthropic' => 'Anthropic',
      _ => 'OpenAI 兼容',
    };

/// 把 baseUrl 和一个**不带版本段**的接口路径拼成完整地址。
///
/// [suffix] 传 `/chat/completions` 这种，函数负责判断要不要补 `/v1`：
///
///   `https://api.openai.com/v1`  + `/chat/completions` → `.../v1/chat/completions`
///   `https://api.deepseek.com`   + `/chat/completions` → `.../v1/chat/completions`
///   `http://gateway:3000`        + `/chat/completions` → `.../v1/chat/completions`
///   `https://x.com/api/paas/v4`  + `/chat/completions` → `.../v4/chat/completions`
///
/// **这个函数存在的理由是一次实测事故**：baseUrl 填服务根地址（聚合网关的
/// 常见填法）时，直接拼 `/chat/completions` 会打到网关的前端页面上 ——
/// 那个路径返回 **HTTP 200 + 一坨 HTML**，不是 4xx。于是流里一条
/// `data:` 都没有，解析出空字符串，界面上表现为「发出去了，没有任何回应，
/// 也没有报错」。这是最难查的一类失败，因为每一层看起来都成功了。
///
/// 已经带完整路径的（用户直接粘贴接口地址）原样返回，避免拼出
/// `/v1/chat/completions/chat/completions`。
Uri resolveApiEndpoint(String baseUrl, String suffix) {
  var base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
  if (base.isEmpty) return Uri.parse(suffix);

  // 用户粘的就是完整接口地址。
  if (base.endsWith(suffix)) return Uri.parse(base);

  // 已经是完整的 API 根（有版本段，或是 /openai 这种兼容层）就直接拼，
  // 不再补 /v1。
  if (looksLikeApiRoot(base)) return Uri.parse('$base$suffix');

  return Uri.parse('$base/v1$suffix');
}

String? _stripCompatSuffix(String url) {
  final lower = url.toLowerCase();
  for (final suffix in _compatSuffixes) {
    if (lower.endsWith(suffix)) {
      return url.substring(0, url.length - suffix.length);
    }
  }
  return null;
}

/// 按优先级列出要试的模型列表端点。
///
/// 抽成纯函数是为了能单测 —— 这段逻辑全是各家服务商的历史包袱，
/// 靠"改一下、连一次真站点看看"来验证太慢，而且改坏了不会立刻发现。
List<String> buildModelsUrlCandidates(
  String baseUrl, {
  String? override,
  String apiFormat = 'openAI',
}) {
  final overridden = override?.trim() ?? '';
  if (overridden.isNotEmpty) return [overridden];

  var trimmed = baseUrl.trim();
  while (trimmed.endsWith('/')) {
    trimmed = trimmed.substring(0, trimmed.length - 1);
  }
  if (trimmed.isEmpty) {
    throw const ModelFetchException('baseUrl 是空的');
  }

  // Gemini 主机上猜路径没有意义 —— 猜错的表现是 404 或 401，而 401 会把人
  // 引到"是不是密钥不对"上去，那是条死路。直接给出正确答案。
  final geminiFix = geminiBaseUrlFix(trimmed, apiFormat: apiFormat);
  if (geminiFix != null) {
    throw ModelFetchException(
      '这个 Base URL 和「${geminiProtocolLabel(apiFormat)}」协议对不上。\n'
      '请改成：$geminiFix',
    );
  }

  // 原生层只有一个列表端点，没有第二个可猜。
  if (apiFormat == 'geminiNative') return <String>['$trimmed/models'];

  final candidates = <String>[];
  if (looksLikeApiRoot(trimmed)) {
    candidates.add('$trimmed/models');
    // 版本段不是 /v1 时（智谱的 /v4 之类），把 /v1/models 留作兜底 ——
    // 少数站点确实两个都通，正确的那个已经排在前面了。
    if (!trimmed.endsWith('/v1')) candidates.add('$trimmed/v1/models');
  } else {
    candidates.add('$trimmed/v1/models');
  }

  final stripped = _stripCompatSuffix(trimmed);
  if (stripped != null && stripped.contains('://')) {
    var root = stripped;
    while (root.endsWith('/')) {
      root = root.substring(0, root.length - 1);
    }
    if (root.isNotEmpty) {
      candidates.add('$root/v1/models');
      candidates.add('$root/models');
    }
  }

  // 候选最多四条，线性去重就够，不值得上 Set 再排序。
  final unique = <String>[];
  for (final url in candidates) {
    if (!unique.contains(url)) unique.add(url);
  }
  return unique;
}

/// 解析 `/v1/models` 的响应。
///
/// 三种形状都见过：`{data:[...]}`（OpenAI 标准）、裸数组、`{models:[...]}`。
/// 条目可能是对象也可能直接是字符串。宽松解析是有意的 —— 这里严格没有收益，
/// 少认一种形状就等于某家服务商用不了模型列表。
List<FetchedModel> parseModelsResponse(String body) {
  final decoded = jsonDecode(body);
  final List<Object?> entries;
  if (decoded is List) {
    entries = decoded;
  } else if (decoded is Map<String, Object?>) {
    final data = decoded['data'] ?? decoded['models'] ?? decoded['items'];
    if (data is List) {
      entries = data;
    } else if (data is Map) {
      entries = data.entries
          .map<Object?>((entry) => entry.value is Map
              ? <String, Object?>{
                  'fallback_id': entry.key.toString(),
                  ...Map<String, Object?>.from(entry.value as Map),
                }
              : entry.key.toString())
          .toList();
    } else {
      return const [];
    }
  } else {
    return const [];
  }

  final seen = <String>{};
  final out = <FetchedModel>[];
  for (final entry in entries) {
    String? id;
    String? ownedBy;
    if (entry is String) {
      id = entry;
    } else if (entry is Map<String, Object?>) {
      final raw = entry['slug'] ??
          entry['id'] ??
          entry['model'] ??
          entry['name'] ??
          entry['fallback_id'];
      if (raw is String) id = raw;
      final owner = entry['owned_by'] ?? entry['ownedBy'];
      if (owner is String && owner.isNotEmpty) ownedBy = owner;
    }
    if (id == null || id.isEmpty) continue;
    // 原生层的列表把 id 写成 `models/gemini-2.5-pro`，而请求里要填的是去掉
    // 前缀的那个。带着前缀发出去会拼成 `/models/models/xxx:streamGenerate…`
    // —— 又是一个 404。
    if (id.startsWith('models/')) id = id.substring('models/'.length);
    if (!seen.add(id)) continue;
    out.add(FetchedModel(id, ownedBy: ownedBy));
  }
  out.sort((a, b) => a.id.compareTo(b.id));
  return out;
}

/// 依次试候选端点，返回第一个成功的结果。
///
/// 全部失败时把**每个候选各自的失败原因**一起抛出去。只报最后一个的话，
/// 用户看到的是「404」，而真正有用的信息是「第一个 401、第二个 404」——
/// 前者说明 key 不对，后者说明路径不对，处理方式完全相反。
Future<List<FetchedModel>> fetchModels({
  required String baseUrl,
  required String apiKey,
  String? override,
  String apiFormat = 'openAI',
  http.Client? client,
  Duration timeout = const Duration(seconds: 15),
}) async {
  // Code Assist 没有列模型这个接口。
  //
  // `v1internal` 是个 RPC 面：只有 `:loadCodeAssist`、`:generateContent`
  // 这种带冒号的方法，没有 REST 的 `/models` 集合。照 OpenAI 那套去猜路径，
  // 结果只能是两条 404 —— 而用户看到的是"获取模型列表失败"，会以为登录或者
  // 地址配错了，跑去反复重登。
  //
  // 所以这一档直接给一份内置清单，不发请求。清单不全没关系：选择器允许
  // 手填，填的名字会原样发给服务端。
  if (apiFormat == 'gemini') {
    return <FetchedModel>[
      for (final id in codeAssistModels) FetchedModel(id, ownedBy: 'google'),
    ];
  }

  final candidates = buildModelsUrlCandidates(
    baseUrl,
    override: override,
    apiFormat: apiFormat,
  );
  final httpClient = client ?? http.Client();
  final failures = <String>[];

  // 端点对了、认证也过了，只是这个 key 下一个模型都没有。
  // 这和「路径猜错」是完全不同的两回事，处理方式也相反（一个去服务端配渠道，
  // 一个去改 baseUrl），所以分开记，给出的提示也不一样。
  var sawEmptyOk = false;

  for (final url in candidates) {
    try {
      final response = await httpClient
          .get(
            Uri.parse(url),
            headers: geminiAuthHeaders(apiKey, apiFormat: apiFormat)
              ..['Accept'] = 'application/json',
          )
          .timeout(timeout);

      if (response.statusCode == 200) {
        final models = parseModelsResponse(response.body);
        if (models.isNotEmpty) return models;
        // 200 但没模型有两种可能：打到了一个返回 HTML 的页面，
        // 或者这真的是一个空列表（聚合网关没配渠道）。能解析成 JSON 的
        // 按后者算 —— 前者 jsonDecode 会抛，走到下面的 catch。
        sawEmptyOk = true;
        failures.add('$url → 200，但列表是空的');
        continue;
      }
      failures.add('$url → HTTP ${response.statusCode}');
    } catch (e) {
      failures.add('$url → $e');
    }
  }

  if (sawEmptyOk) {
    throw ModelFetchException(
      '接口通了，但这个 key 下没有可用模型。\n'
      '如果用的是 one-api / new-api 这类聚合网关，'
      '多半是服务端还没给对应分组配置渠道。\n\n'
      '${failures.join('\n')}',
    );
  }
  throw ModelFetchException('获取模型列表失败：\n${failures.join('\n')}');
}
