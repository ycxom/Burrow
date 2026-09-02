/// Gemini 的线格式，以及 Code Assist 那层包装。
///
/// ## 为什么需要第四条协议路径
///
/// Vertex AI 有 OpenAI 兼容端点，所以走它的渠道直接复用现成的 `openAI` 路径，
/// 一行都不用新写（见 [GoogleVertexFlow.vertexBaseUrl]）。**Code Assist 没有** ——
/// `cloudcode-pa.googleapis.com/v1internal` 只认 Gemini 原生格式，所以这条路
/// 必须自己拼。
///
/// ## Gemini 格式和 OpenAI 格式的几处真差别
///
///   - **角色只有 `user` 和 `model`**，没有 `system` 和 `tool`。系统提示提到
///     顶层的 `systemInstruction`；工具结果作为一条 **user** 消息里的
///     `functionResponse` 部件回去。照着 OpenAI 的四种角色映射会直接 400。
///   - **工具调用没有 id。** OpenAI 用 `tool_call_id` 把请求和结果配对，
///     Gemini 靠**函数名**。所以多个同名并发调用在 Gemini 里是配不起来的，
///     我们按名字回，和它的模型行为一致。
///   - **相邻同角色消息要合并。** Gemini 要求 user/model 严格交替，两条连着的
///     user 消息会被拒。而我们的历史里这种情况很常见（检索注入的 system 片段
///     被映射成 user，紧跟着真的用户消息）。
///
/// ## Code Assist 的包装
///
/// 请求体是 `{"model":..., "project":..., "request": <Gemini 请求>}`，
/// 响应是 `{"response": <Gemini 响应>}`。项目号不是用户填的，是登录后用
/// `:loadCodeAssist` 问出来的 —— 那正是这条路"不需要 GCP 项目"的原因：
/// Google 替这个账号托管了一个。
library;

import 'dart:convert';

import '../agent/agent_loop.dart' show TokenUsage;
import '../agent/tools.dart';
import '../context/overflow_manager.dart';
import 'image_parts.dart';
import 'system_prompt.dart';

/// 一条 Gemini 消息。
typedef GeminiContent = Map<String, Object?>;

/// 把内部历史转成 Gemini 的 `contents`。
///
/// [images] 是已经读进内存的图，键是文件路径（和 llm_client 里那份一样）。
List<GeminiContent> geminiContents(
  List<ChatMessage> messages,
  Map<String, InlineImage> images,
) {
  final out = <GeminiContent>[];

  void push(String role, List<Object?> parts) {
    if (parts.isEmpty) return;
    // 相邻同角色合并。Gemini 要求两个角色严格交替，连着两条 user 会被拒 ——
    // 而"检索注入的片段 + 用户这句话"恰好就是连着两条 user。
    if (out.isNotEmpty && out.last['role'] == role) {
      (out.last['parts'] as List<Object?>).addAll(parts);
      return;
    }
    out.add(<String, Object?>{'role': role, 'parts': parts});
  }

  for (final message in messages) {
    // system 已经被提到顶层的 systemInstruction 了，这里跳过。
    if (message.role == 'system') continue;

    final parts = <Object?>[];
    if (message.role == 'tool') {
      // 工具结果按**名字**配对，不是 id —— Gemini 没有 tool_call_id 这个概念。
      // 我们的 ChatMessage 没存工具名，所以退回一条带标记的普通文本：
      // 模型看得懂"这是刚才那次调用的结果"，而伪造一个 functionResponse
      // 却配不上名字的话，Gemini 会直接 400。
      parts.add(<String, Object?>{'text': '[工具结果]\n${message.content}'});
      push('user', parts);
      continue;
    }

    final attached = <InlineImage>[
      for (final path in message.images)
        if (images[path] != null) images[path]!,
    ];

    final text = attached.isEmpty
        ? withImagePlaceholder(message.content, message.images.length)
        : message.content;
    if (text.isNotEmpty) {
      parts.add(<String, Object?>{'text': text});
    }
    for (final image in attached) {
      parts.add(<String, Object?>{
        'inlineData': <String, Object?>{
          'mimeType': image.mediaType,
          'data': image.base64Data,
        },
      });
    }
    // 一条什么都不剩的消息不能发（Gemini 拒收空 parts），但也不能整条丢掉 ——
    // 丢掉会让对话轮次错位。给一个空格占住这一轮。
    if (parts.isEmpty) parts.add(<String, Object?>{'text': ' '});

    push(message.role == 'assistant' ? 'model' : 'user', parts);
  }

  return out;
}

/// 系统提示。Gemini 把它放在顶层，不在 contents 里。
Map<String, Object?>? geminiSystemInstruction(List<ChatMessage> messages) {
  final text = messages
      .where((message) => message.role == 'system')
      .map((message) => message.content)
      .join('\n\n');
  if (text.isEmpty) return null;
  return <String, Object?>{
    'parts': <Object?>[
      <String, Object?>{'text': text},
    ],
  };
}

/// 工具声明。
///
/// Gemini 的 schema 方言比 JSON Schema 窄：不认 `$schema`、`additionalProperties`
/// 这些关键字，带上会 400。这里做一次保守清洗 —— 只留它认识的那些键。
List<Map<String, Object?>> geminiTools(
  List<ToolSpec> tools, {
  bool webSearch = false,
}) {
  final out = <Map<String, Object?>>[];
  if (tools.isNotEmpty) {
    out.add(<String, Object?>{
      'functionDeclarations': <Object?>[
        for (final tool in tools)
          <String, Object?>{
            'name': tool.name,
            'description': tool.description,
            'parameters': sanitizeGeminiSchema(tool.parameters),
          },
      ],
    });
  }
  // 搜索是 tools 数组里**另一个条目**，不是 functionDeclarations 里的一项。
  //
  // 它是内置工具：模型自己决定搜什么、自己发起、自己读结果，全程不经过我们的
  // 工具循环 —— 我们只在响应里收到 groundingMetadata。所以它没有 schema，
  // 值就是一个空对象。
  if (webSearch) {
    out.add(<String, Object?>{'google_search': <String, Object?>{}});
  }
  return out;
}

/// 这个 400 是"内置工具和函数声明不能同时用"。
///
/// Gemini 2.5 及更老的模型不允许 `google_search` 和 `functionDeclarations`
/// 出现在同一个请求里，Gemini 3 才放开。而这个 app 每一轮都在发工具声明，
/// 所以老模型上一开搜索就必定撞这条。
///
/// 服务端的原文是「Tool use with function calling is unsupported」之类，
/// 混在一大段 JSON 里 —— 不认出来的话用户看到的只是"HTTP 400"，而 400 在这个
/// app 里最常见的原因是别的（模型名写错、上下文超长），会把人带偏。
bool isGeminiToolMixError(String body) {
  // 只按措辞判断，不看状态码：同一条错误在流式和非流式下包在不同的壳里，
  // 状态码有时根本不在这段文本里。
  final lower = body.toLowerCase();
  const marks = <String>[
    'tool use with function calling is unsupported',
    'multiple tools are supported only when they are all search tools',
    'only when they are all search tools',
  ];
  return marks.any(lower.contains);
}

/// 把 JSON Schema 削成 Gemini 认识的子集。
///
/// 未知关键字**丢掉而不是保留**：Gemini 对多余的键是硬报错，不是忽略。
/// 一个 `additionalProperties: false` 就能让整轮请求 400，而错误信息只会说
/// "Invalid JSON payload"，不会告诉你是哪个键。
Object? sanitizeGeminiSchema(Object? schema) {
  if (schema is List) {
    return <Object?>[for (final item in schema) sanitizeGeminiSchema(item)];
  }
  if (schema is! Map) return schema;

  const allowed = <String>{
    'type',
    'format',
    'description',
    'nullable',
    'enum',
    'items',
    'properties',
    'required',
  };
  final out = <String, Object?>{};
  for (final entry in schema.entries) {
    final key = entry.key.toString();
    if (!allowed.contains(key)) continue;
    // Gemini 的 type 只认大写的 STRING / NUMBER / OBJECT…，而 JSON Schema
    // 写的是小写。不转的话它会当成未知类型。
    if (key == 'type' && entry.value is String) {
      out[key] = (entry.value as String).toUpperCase();
      continue;
    }
    // `properties` 下面一层的键是**属性名**，不是 schema 关键字。
    // 在那一层套白名单会把用户定义的每个字段都删光 —— 结果是一个
    // 「有 type: OBJECT 但没有任何属性」的工具，模型永远调不对参数。
    if (key == 'properties' && entry.value is Map) {
      out[key] = <String, Object?>{
        for (final property in (entry.value as Map).entries)
          property.key.toString(): sanitizeGeminiSchema(property.value),
      };
      continue;
    }
    out[key] = sanitizeGeminiSchema(entry.value);
  }
  return out;
}

/// 从 Google 的 429 里捞出"到底是哪个配额满了"。
///
/// **这个函数存在的理由是一次实测的诊断失败。** Google 的配额错误把 200 多字
/// 的套话（"You exceeded your current quota, please check your plan and
/// billing details…"）放在最前面，而唯一能定位问题的
/// `violations[].quotaId` 放在最后。错误体一截断，留下的全是套话 ——
/// 看一百遍也不知道是模型配额满了还是搜索配额满了，而这两者的处理完全不同
/// （一个等一天，一个关掉搜索就能继续用）。
///
/// 捞不到就返回空串，调用方照常显示原始错误。
String describeGoogleQuota(String body) {
  Object? decoded;
  try {
    decoded = jsonDecode(body);
  } catch (_) {
    return '';
  }
  if (decoded is! Map) return '';
  final error = decoded['error'];
  if (error is! Map) return '';
  final details = error['details'];
  if (details is! List) return '';

  final quotas = <String>[];
  String retryDelay = '';
  for (final detail in details) {
    if (detail is! Map) continue;
    final delay = detail['retryDelay'];
    if (delay is String && delay.isNotEmpty) retryDelay = delay;
    final violations = detail['violations'];
    if (violations is! List) continue;
    for (final violation in violations) {
      if (violation is! Map) continue;
      // quotaId 比 quotaMetric 好读（前者是
      // `GenerateRequestsPerDayPerProjectPerModel-FreeTier` 这种），
      // 但不是每次都给，所以两个都收。
      final id = violation['quotaId'] ?? violation['quotaMetric'];
      if (id is String && id.isNotEmpty && !quotas.contains(id)) {
        quotas.add(id);
      }
    }
  }

  if (quotas.isEmpty && retryDelay.isEmpty) return '';
  final buffer = StringBuffer();
  if (quotas.isNotEmpty) buffer.write('超出的配额：${quotas.join('、')}');
  if (retryDelay.isNotEmpty) {
    if (buffer.isNotEmpty) buffer.write('\n');
    buffer.write('建议 $retryDelay 后重试');
  }
  return buffer.toString();
}

/// 一条搜索来源。
class GroundingSource {
  const GroundingSource({required this.uri, required this.title});

  /// **这是一个会过期的跳转地址**，不是原始网址。
  ///
  /// Google 返回的是 `vertexaisearch.cloud.google.com/grounding-api-redirect/…`，
  /// 真实网址藏在跳转后面。所以来源只能当场点开看，存进历史里过一阵就打不开了
  /// —— 这也是为什么我们把它渲染进正文而不是单独存一份。
  final String uri;

  /// 站点名，例如 `uefa.com`。Google 给的就是域名，不是网页标题。
  final String title;

  @override
  bool operator ==(Object other) =>
      other is GroundingSource && other.uri == uri && other.title == title;

  @override
  int get hashCode => Object.hash(uri, title);
}

/// 这个模型认不认 `thinkingConfig`。
///
/// **必须先判再发。** 不支持的模型（2.0 和更老）收到这个字段会直接 400
/// 退回来，整轮对话失败 —— 为了一个"顺带显示思考"的功能把发消息弄坏，
/// 是明显不划算的交易。
///
/// 判据是模型名里的代次。按名字猜确实脆，但另外两条路更差：探测一次要多打
/// 一个来回，而维护一张模型白名单意味着 Google 每发一个新模型就得改代码，
/// 漏改的表现是"新模型没有思考"—— 那比误判更难被发现。
bool geminiSupportsThoughts(String model) {
  final name = model.toLowerCase();
  // 2.5 是第一代吐思考摘要的。3 及以后按代次号往上算，避免每出一个新版本
  // 就回来加一条。
  if (name.contains('gemini-2.5')) return true;
  final match = RegExp(r'gemini-(\d+)').firstMatch(name);
  if (match == null) return false;
  return (int.tryParse(match.group(1)!) ?? 0) >= 3;
}

/// 从一个 Gemini `GenerateContentResponse` 里取出文本、工具调用和用量。
class GeminiTurnChunk {
  const GeminiTurnChunk({
    this.text = '',
    this.calls = const <ToolCall>[],
    this.usage,
    this.queries = const <String>[],
    this.sources = const <GroundingSource>[],
    this.reasoning = '',
  });

  final String text;

  /// 带 `thought: true` 的那些分片拼起来 —— 模型的思考摘要。
  ///
  /// 和 [text] 分开是因为它们在同一个 `parts` 数组里混着来，只有这个布尔位
  /// 能区分。混进正文的话，用户会看到模型把自己的草稿当答案念出来。
  final String reasoning;
  final List<ToolCall> calls;
  final TokenUsage? usage;

  /// 模型实际搜了什么。展示它是有用的 —— 答得不对时，第一件要看的事就是
  /// 它到底搜了什么词。
  final List<String> queries;

  final List<GroundingSource> sources;
}

/// 从 `groundingMetadata` 里取出搜索词和来源。
///
/// 字段名是驼峰（`groundingChunks` / `webSearchQueries`），Vertex 上也一样。
({List<String> queries, List<GroundingSource> sources}) parseGroundingMetadata(
    Object? raw) {
  if (raw is! Map) {
    return (queries: const <String>[], sources: const <GroundingSource>[]);
  }
  final queries = <String>[];
  final rawQueries = raw['webSearchQueries'];
  if (rawQueries is List) {
    for (final q in rawQueries) {
      if (q is String && q.isNotEmpty) queries.add(q);
    }
  }

  final sources = <GroundingSource>[];
  final chunks = raw['groundingChunks'];
  if (chunks is List) {
    for (final chunk in chunks) {
      if (chunk is! Map) continue;
      final web = chunk['web'];
      if (web is! Map) continue;
      final uri = web['uri']?.toString() ?? '';
      if (uri.isEmpty) continue;
      final title = web['title']?.toString() ?? '';
      final source = GroundingSource(
        uri: uri,
        title: title.isEmpty ? uri : title,
      );
      // 同一个站点常常被引好几次，列表里去重。
      if (!sources.contains(source)) sources.add(source);
    }
  }
  return (queries: queries, sources: sources);
}

/// 把搜索来源拼成附在回答末尾的一段。
///
/// 拼进正文而不是另开一个 UI 区域：来源要跟着这条消息一起存、一起复制、
/// 一起导出，单独做一份就得在存储、渲染、导出三处都跟着改。
String formatGroundingSources(
  List<GroundingSource> sources,
  List<String> queries,
) {
  if (sources.isEmpty) return '';
  final buffer = StringBuffer('\n\n---\n');
  if (queries.isNotEmpty) {
    buffer.writeln('搜索：${queries.join(' · ')}');
    buffer.writeln();
  }
  for (var i = 0; i < sources.length; i++) {
    buffer.writeln('${i + 1}. [${sources[i].title}](${sources[i].uri})');
  }
  return buffer.toString();
}

GeminiTurnChunk parseGeminiResponse(Map<String, Object?> json) {
  final candidates = json['candidates'];
  final text = StringBuffer();
  final reasoning = StringBuffer();
  final calls = <ToolCall>[];
  var queries = const <String>[];
  var sources = const <GroundingSource>[];

  if (candidates is List && candidates.isNotEmpty) {
    final first = candidates.first;
    if (first is Map) {
      final grounding = parseGroundingMetadata(first['groundingMetadata']);
      queries = grounding.queries;
      sources = grounding.sources;
      final content = first['content'];
      if (content is Map) {
        final parts = content['parts'];
        if (parts is List) {
          for (final part in parts) {
            if (part is! Map) continue;
            final value = part['text'];
            // `thought: true` 标记这一片是思考而不是回答。判断要在写入之前 ——
            // Gemini 把两者塞在同一个 parts 数组里，顺序上也交错。
            if (value is String) {
              (part['thought'] == true ? reasoning : text).write(value);
            }

            final call = part['functionCall'];
            if (call is Map) {
              final name = call['name']?.toString() ?? '';
              if (name.isEmpty) continue;
              final args = call['args'];
              calls.add(ToolCall(
                // Gemini 不给 id，我们按名字造一个 —— 下游只用它做配对，
                // 而 Gemini 的配对本来就是按名字的。
                id: 'call_${name}_${calls.length}',
                name: name,
                args: args is Map
                    ? args.map((k, v) => MapEntry(k.toString(), v))
                    : const <String, Object?>{},
              ));
            }
          }
        }
      }
    }
  }

  return GeminiTurnChunk(
    text: text.toString(),
    calls: calls,
    usage: parseGeminiUsage(json['usageMetadata']),
    queries: queries,
    sources: sources,
    reasoning: reasoning.toString(),
  );
}

/// `usageMetadata` → [TokenUsage]。
TokenUsage? parseGeminiUsage(Object? raw) {
  if (raw is! Map) return null;
  int asInt(Object? value) =>
      value is num ? value.toInt() : int.tryParse('$value') ?? 0;
  final usage = TokenUsage(
    input: asInt(raw['promptTokenCount']),
    output: asInt(raw['candidatesTokenCount']),
    cached: asInt(raw['cachedContentTokenCount']),
  );
  return usage.isEmpty ? null : usage;
}

/// Code Assist 的请求包装。
Map<String, Object?> wrapCodeAssistRequest({
  required String model,
  required String project,
  required Map<String, Object?> request,
}) =>
    <String, Object?>{
      'model': model,
      'project': project,
      'request': request,
    };

/// 剥掉 Code Assist 的响应包装。
///
/// 有的事件带 `response`，有的（错误、心跳）不带 —— 不带的时候原样返回，
/// 让上层按 Gemini 响应去解，解不出来就是空块。
Map<String, Object?> unwrapCodeAssistResponse(Map<String, Object?> event) {
  final inner = event['response'];
  return inner is Map ? inner.cast<String, Object?>() : event;
}

/// 从 SSE 的一行里取出 JSON。不是数据行就返回 null。
Map<String, Object?>? decodeSseData(String line) {
  if (!line.startsWith('data:')) return null;
  final payload = line.substring(5).trim();
  if (payload.isEmpty || payload == '[DONE]') return null;
  try {
    final value = jsonDecode(payload);
    return value is Map<String, Object?> ? value : null;
  } catch (_) {
    return null;
  }
}
