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

/// baseUrl 是不是以 `/v{数字}` 结尾。
bool endsWithVersionSegment(String url) {
  final idx = url.lastIndexOf('/');
  if (idx < 0 || idx == url.length - 1) return false;
  final last = url.substring(idx + 1);
  if (last.length < 2 || last[0] != 'v') return false;
  return int.tryParse(last.substring(1)) != null;
}

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

  // 已经有版本段（/v1、/v4 …）就直接拼，不再补 /v1。
  if (endsWithVersionSegment(base)) return Uri.parse('$base$suffix');

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
List<String> buildModelsUrlCandidates(String baseUrl, {String? override}) {
  final overridden = override?.trim() ?? '';
  if (overridden.isNotEmpty) return [overridden];

  var trimmed = baseUrl.trim();
  while (trimmed.endsWith('/')) {
    trimmed = trimmed.substring(0, trimmed.length - 1);
  }
  if (trimmed.isEmpty) {
    throw const ModelFetchException('baseUrl 是空的');
  }

  final candidates = <String>[];
  if (endsWithVersionSegment(trimmed)) {
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
  http.Client? client,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final candidates = buildModelsUrlCandidates(baseUrl, override: override);
  final httpClient = client ?? http.Client();
  final failures = <String>[];

  // 端点对了、认证也过了，只是这个 key 下一个模型都没有。
  // 这和「路径猜错」是完全不同的两回事，处理方式也相反（一个去服务端配渠道，
  // 一个去改 baseUrl），所以分开记，给出的提示也不一样。
  var sawEmptyOk = false;

  for (final url in candidates) {
    try {
      final response = await httpClient.get(
        Uri.parse(url),
        headers: {
          if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
          'Accept': 'application/json',
        },
      ).timeout(timeout);

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
