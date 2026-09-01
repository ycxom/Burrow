/// 嵌入式检索的后端：OpenAI 兼容的 `/embeddings`。
///
/// 这条路只服务一件事 —— [MemoryRetrieval] 的第三路（向量余弦）。它是可选的：
/// 没配嵌入模型时 RRF 只融合 BM25 和覆盖率两条词法路，检索照常工作，
/// 只是召回不了「零词法重叠的语义近邻」（用户问「那个画图的库」，
/// 记忆里写的是 matplotlib）。
///
/// **契约：未配置时返回空列表，配置了但失败时抛异常。** 两者调用方都会降级，
/// 但只有后者说明"用户以为开着、其实没工作"—— 那种情况必须能在界面上看见，
/// 否则就是又一次静默失败（见 README 里 `/v1` 那一节）。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../net/proxy_client.dart';
import 'model_catalog.dart';

/// 一批的**起始**条数。真正用多少是运行时学出来的，见 [OpenAiEmbedder._batch]。
///
/// 不是越大越好：一条超长记录就能把整批顶过服务端的输入上限，而失败是整批
/// 失败。32 条在"请求数"和"整批作废的代价"之间。
const _initialBatch = 32;

/// 服务端说"这一批太大了"的状态码。
///
/// 只对这几个降批重试。对 401/404 重试是纯浪费 —— 批次再小也还是没权限。
const _batchTooLarge = {400, 413, 422};

/// 单条文本截断长度。
///
/// 嵌入模型有硬性输入上限，超了整个请求 400。截断的向量仍然有用
/// （开头通常就包含主题词），整批失败则什么都没有。
const _maxChars = 4000;

class OpenAiEmbedder {
  /// 都用闭包现读，而不是构造时快照 —— 用户在底部那条切换器上换了嵌入模型，
  /// 下一次检索就该用新的，不该等重开会话。
  final String Function() baseUrl;
  final String Function() apiKey;

  /// 嵌入模型 id。空 = 没启用。
  final String Function() model;

  /// 代理。和 baseUrl 一样跟着当前渠道现读 —— 代理是在 HttpClient 上设的，
  /// 换渠道要重建客户端，不能只换 URL。
  final String Function()? proxy;

  http.Client _http;
  String? _proxyInUse;
  final bool _ownsClient;
  final Duration timeout;

  OpenAiEmbedder({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    this.proxy,
    http.Client? client,
    this.timeout = const Duration(seconds: 30),
  })  : _http = client ?? buildHttpClient(proxy: proxy?.call()),
        _proxyInUse = proxy?.call(),
        _ownsClient = client == null;

  /// 代理变了就重建底层客户端。不重建的话「换了渠道但嵌入还走老代理」，
  /// 而表现只是超时，看不出和代理有关。
  http.Client get _client {
    if (!_ownsClient) return _http;
    final want = proxy?.call();
    if (want != _proxyInUse) {
      _http.close();
      _http = buildHttpClient(proxy: want);
      _proxyInUse = want;
    }
    return _http;
  }

  /// 最近一次失败的原因。null = 没失败过。
  ///
  /// 留着是为了让界面能显示「嵌入模型配了但用不了」。检索本身降级得很安静，
  /// 安静到用户不会发现自己配的东西根本没生效。
  String? lastError;

  /// 当前每批发多少条。**运行时学出来的，不是配置项。**
  ///
  /// 各家网关对 `input` 数组的上限差得很远：OpenAI 官方 2048，
  /// 而实测某个聚合网关只给 5 条（超了直接 422 `input最多支持 5 条`）。
  /// 写死一个数就是在赌，赌错的表现是整个嵌入功能悄悄用不了。
  ///
  /// 所以碰到"这批太大"就对半砍再试，砍到能过为止，并把学到的值留着 ——
  /// 和沙箱能力探测同一个思路：**不在编译期假设服务端的限制**。
  int _batch = _initialBatch;

  /// 当前学到的批大小。给测试和排查用。
  int get batchSize => _batch;

  bool get enabled => model().trim().isNotEmpty;

  Future<List<List<double>>> call(List<String> texts) async {
    final modelId = model().trim();
    final base = baseUrl().trim();
    if (modelId.isEmpty || base.isEmpty || texts.isEmpty) return const [];

    try {
      while (true) {
        try {
          final out = <List<double>>[];
          for (var i = 0; i < texts.length; i += _batch) {
            final end = i + _batch > texts.length ? texts.length : i + _batch;
            final chunk = texts
                .sublist(i, end)
                .map(
                    (t) => t.length > _maxChars ? t.substring(0, _maxChars) : t)
                .toList();
            out.addAll(await _embedChunk(base, modelId, chunk));
          }
          lastError = null;
          return out;
        } on EmbeddingException catch (e) {
          final tooLarge = e.statusCode != null &&
              _batchTooLarge.contains(e.statusCode) &&
              _batch > 1;
          if (!tooLarge) rethrow;
          // 对半砍再来。注意是重头开始整轮 —— 已经成功的那几批会重发，
          // 但这只发生在学习批大小的头一两次，之后 _batch 就稳定了。
          _batch = _batch ~/ 2;
        }
      }
    } catch (e) {
      lastError = '$e';
      rethrow;
    }
  }

  Future<List<List<double>>> _embedChunk(
    String base,
    String modelId,
    List<String> chunk,
  ) async {
    final key = apiKey().trim();
    final response = await _client
        .post(
          resolveApiEndpoint(base, '/embeddings'),
          headers: {
            'Content-Type': 'application/json',
            if (key.isNotEmpty) 'Authorization': 'Bearer $key',
          },
          body: jsonEncode({'model': modelId, 'input': chunk}),
        )
        .timeout(timeout);

    if (response.statusCode >= 400) {
      // 用 bodyBytes 按 UTF-8 解，不用 response.body：后者在没有 charset
      // 时按 latin1 解，网关回的中文原因会变成一串乱码 ——
      // 而这条信息是要直接显示给用户看的。
      throw EmbeddingException(
        'HTTP ${response.statusCode}：'
        '${_brief(utf8.decode(response.bodyBytes, allowMalformed: true))}',
        statusCode: response.statusCode,
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      // 和 /v1 那次同一种病：地址打到了网页上，返回 200 + HTML。
      throw const EmbeddingException(
          '返回的不是 JSON。多半是接口地址不对 —— 有些网关的 /embeddings '
          '会返回前端页面，状态码仍然是 200。');
    }
    if (decoded is! Map<String, Object?>) {
      throw const EmbeddingException('返回的 JSON 不是对象');
    }

    final data = decoded['data'];
    if (data is! List) {
      throw EmbeddingException('返回里没有 data 数组：${_brief(jsonEncode(decoded))}');
    }

    // 按 index 排序再取。服务端**允许**乱序返回，而顺序错了的后果是
    // 每条记忆都配了别人的向量 —— 检索不会报错，只会一直给出莫名其妙的结果。
    final rows = <int, List<double>>{};
    for (var i = 0; i < data.length; i++) {
      final row = data[i];
      if (row is! Map) continue;
      final vector = row['embedding'];
      if (vector is! List) continue;
      final index = row['index'] is int ? row['index'] as int : i;
      rows[index] = <double>[
        for (final v in vector) (v as num).toDouble(),
      ];
    }

    if (rows.length != chunk.length) {
      throw EmbeddingException('要了 ${chunk.length} 条向量，只拿回 ${rows.length} 条');
    }
    return [
      for (var i = 0; i < chunk.length; i++) rows[i]!,
    ];
  }

  static String _brief(String body) {
    final one = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    return one.length > 160 ? '${one.substring(0, 160)}…' : one;
  }
}

class EmbeddingException implements Exception {
  final String message;

  /// HTTP 状态码。null 表示不是服务端拒绝（解析失败、条数对不上之类）。
  /// [OpenAiEmbedder] 靠它区分"这批太大"和"根本没权限"。
  final int? statusCode;

  const EmbeddingException(this.message, {this.statusCode});

  @override
  String toString() => message;
}
