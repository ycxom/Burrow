/// OpenAI 兼容的流式客户端。
///
/// 只实现 OpenAI 的 `/chat/completions` 形状：Ollama、llama.cpp、LM Studio、
/// vLLM、以及绝大多数国内网关都兼容它。真要接 Anthropic / Gemini 的原生
/// 协议，再加一个 [LlmClient] 实现即可 —— `AgentLoop` 只依赖那个窄接口。
///
/// 这里有两处是为本项目专门做的，通用 SDK 不会管：
///
/// 1. **超长错误要抛 [ContextOverflowException] 而不是普通 HttpException。**
///    `ContextLimitGuard` 靠它拿到响应体去学真实 n_ctx（见 CONTEXT.md §1）。
///    包装成通用异常就把那个数字丢了。
///
/// 2. **工具调用 JSON 的修复。** 小模型（尤其是量化过的 7B）经常吐出
///    截断或多余逗号的 arguments。直接 jsonDecode 失败就等于整轮白跑，
///    而修一下往往就能用 —— 思路取自 chatbox 的 `tool-call-json-repair`。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../agent/agent_loop.dart';
import '../agent/tools.dart';
import '../context/overflow_manager.dart';

class LlmConfig {
  final String baseUrl; // 例如 https://api.openai.com/v1
  final String apiKey;
  final String model;

  /// 摘要用的模型。可以指定一个更小更便宜的 —— 摘要任务不需要旗舰模型，
  /// 而它的调用频率随对话长度线性增长。
  final String? summaryModel;

  final double temperature;

  const LlmConfig({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    this.summaryModel,
    this.temperature = 0.3,
  });

  static const empty = LlmConfig(baseUrl: '', apiKey: '', model: '');

  bool get isConfigured => baseUrl.isNotEmpty && model.isNotEmpty;
}

class ConfigurableLlmClient implements LlmClient {
  LlmConfig config;
  final http.Client _http;

  ConfigurableLlmClient({LlmConfig? config, http.Client? httpClient})
      : config = config ?? LlmConfig.empty,
        _http = httpClient ?? http.Client();

  @override
  String get limitKey => ContextLimitKey.of(config.baseUrl, config.model);

  @override
  Future<LlmTurn> complete({
    required List<ChatMessage> messages,
    required List<ToolSpec> tools,
    required void Function(String delta) onDelta,
  }) async {
    if (!config.isConfigured) {
      throw StateError('尚未配置模型服务，请先在设置里填 baseUrl 和 model');
    }

    final request = http.Request(
      'POST',
      Uri.parse('${config.baseUrl.replaceAll(RegExp(r'/$'), '')}'
          '/chat/completions'),
    )
      ..headers.addAll({
        'Content-Type': 'application/json',
        if (config.apiKey.isNotEmpty)
          'Authorization': 'Bearer ${config.apiKey}',
      })
      ..body = jsonEncode({
        'model': config.model,
        'temperature': config.temperature,
        'stream': true,
        'messages': messages.map(_toWire).toList(),
        if (tools.isNotEmpty) 'tools': tools.map((t) => t.toOpenAiJson()).toList(),
      });

    final response = await _http.send(request);

    if (response.statusCode >= 400) {
      final body = await response.stream.bytesToString();
      // 这一步是 ContextLimitGuard 的入口。判断放在这里而不是 AgentLoop：
      // 只有这一层同时拿得到状态码和原始响应体。
      if (_guard.isContextLimitError(response.statusCode, body)) {
        throw ContextOverflowException(response.statusCode, body);
      }
      throw http.ClientException(
          'LLM 返回 ${response.statusCode}: ${_brief(body)}');
    }

    return _readStream(response.stream, onDelta);
  }

  /// 需要一个 guard 实例来做错误识别。它和 AgentLoop 持有的那个是两份 ——
  /// 这份只用 `isContextLimitError`（无状态判断），学习和预算都在那份上，
  /// 所以不会分裂。
  final _guard = _ErrorSniffer();

  Future<LlmTurn> _readStream(
    http.ByteStream stream,
    void Function(String) onDelta,
  ) async {
    final text = StringBuffer();

    // 工具调用是**分片到达**的：id 和 name 在第一片，arguments 逐字符累加。
    // 必须按 index 攒起来，不能收到一片就当一次调用。
    final partial = <int, _PartialToolCall>{};

    await for (final line in stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      if (!line.startsWith('data:')) continue;
      final payload = line.substring(5).trim();
      if (payload.isEmpty || payload == '[DONE]') continue;

      Map<String, Object?> chunk;
      try {
        chunk = jsonDecode(payload) as Map<String, Object?>;
      } catch (_) {
        continue; // 心跳或注释行，跳过
      }

      final choices = chunk['choices'] as List?;
      if (choices == null || choices.isEmpty) continue;
      final delta =
          (choices.first as Map)['delta'] as Map<String, Object?>? ?? {};

      final content = delta['content'] as String?;
      if (content != null && content.isNotEmpty) {
        text.write(content);
        onDelta(content);
      }

      final calls = delta['tool_calls'] as List?;
      if (calls == null) continue;
      for (final raw in calls.cast<Map<String, Object?>>()) {
        final index = (raw['index'] as num?)?.toInt() ?? 0;
        final slot = partial.putIfAbsent(index, _PartialToolCall.new);
        if (raw['id'] != null) slot.id = raw['id'] as String;
        final fn = raw['function'] as Map<String, Object?>?;
        if (fn == null) continue;
        if (fn['name'] != null) slot.name = fn['name'] as String;
        if (fn['arguments'] != null) slot.args.write(fn['arguments'] as String);
      }
    }

    final toolCalls = <ToolCall>[];
    for (final entry in partial.entries) {
      final p = entry.value;
      if (p.name.isEmpty) continue;
      toolCalls.add(ToolCall(
        id: p.id.isEmpty ? 'call_${entry.key}' : p.id,
        name: p.name,
        args: repairAndDecode(p.args.toString()),
      ));
    }

    return LlmTurn(text: text.toString(), toolCalls: toolCalls);
  }

  /// [Summarizer] 的实现，交给 [OverflowManager]。
  ///
  /// 非流式、低温度、不带工具 —— 摘要不该调用工具，带上 tools 只会诱导
  /// 某些模型在摘要任务里发起工具调用，产出一坨没法用的东西。
  Future<String> summarize(String systemPrompt, String payload) async {
    if (!config.isConfigured) return '';
    final response = await _http.post(
      Uri.parse('${config.baseUrl.replaceAll(RegExp(r'/$'), '')}'
          '/chat/completions'),
      headers: {
        'Content-Type': 'application/json',
        if (config.apiKey.isNotEmpty)
          'Authorization': 'Bearer ${config.apiKey}',
      },
      body: jsonEncode({
        'model': config.summaryModel ?? config.model,
        'temperature': 0.1,
        'messages': [
          {'role': 'system', 'content': systemPrompt},
          {'role': 'user', 'content': payload},
        ],
      }),
    );
    if (response.statusCode >= 400) return '';
    final body = jsonDecode(utf8.decode(response.bodyBytes))
        as Map<String, Object?>;
    final choices = body['choices'] as List?;
    if (choices == null || choices.isEmpty) return '';
    final msg = (choices.first as Map)['message'] as Map<String, Object?>?;
    return (msg?['content'] as String?)?.trim() ?? '';
  }

  static Map<String, Object?> _toWire(ChatMessage m) => {
        // tool 角色的消息在 OpenAI 协议里需要 tool_call_id 配对。为简化，
        // 这里统一降级成 user 消息并加前缀 —— 兼容性远好于严格配对，
        // 而且本地模型对严格的 tool 消息格式支持普遍很差。
        'role': m.role == 'tool' ? 'user' : m.role,
        'content': m.role == 'tool' ? '[工具结果]\n${m.content}' : m.content,
      };

  static String _brief(String s) =>
      s.length > 300 ? '${s.substring(0, 300)}…' : s;
}

class _PartialToolCall {
  String id = '';
  String name = '';
  final StringBuffer args = StringBuffer();
}

/// 修复并解析工具调用参数。
///
/// 小模型（尤其量化过的）常见三种坏法，都试着救一下 ——
/// 救回来一次就省掉一整轮重试。救不回来返回空 map，让工具自己报参数缺失，
/// 那个错误信息比 "JSON 解析失败" 对模型有用得多。
Map<String, Object?> repairAndDecode(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return {};

  for (final candidate in [
    text,
    // 1. 尾部多余逗号: {"a":1,}
    text.replaceAll(RegExp(r',\s*([}\]])'), r'$1'),
    // 2. 被截断: {"a":1  →  补上缺的右括号
    _closeBrackets(text),
    // 3. 前后有 markdown 围栏或解释文字
    _extractBraced(text),
  ]) {
    if (candidate == null || candidate.isEmpty) continue;
    try {
      final decoded = jsonDecode(candidate);
      if (decoded is Map<String, Object?>) return decoded;
    } catch (_) {
      continue;
    }
  }
  return {};
}

String _closeBrackets(String s) {
  var depth = 0;
  var inString = false;
  var escaped = false;
  for (final c in s.split('')) {
    if (escaped) {
      escaped = false;
      continue;
    }
    if (c == r'\') {
      escaped = true;
    } else if (c == '"') {
      inString = !inString;
    } else if (!inString && (c == '{' || c == '[')) {
      depth++;
    } else if (!inString && (c == '}' || c == ']')) {
      depth--;
    }
  }
  final buf = StringBuffer(s);
  if (inString) buf.write('"');
  for (var i = 0; i < depth; i++) {
    buf.write('}');
  }
  return buf.toString();
}

String? _extractBraced(String s) {
  final start = s.indexOf('{');
  final end = s.lastIndexOf('}');
  if (start < 0 || end <= start) return null;
  return s.substring(start, end + 1);
}

/// `ContextLimitGuard.makeKey` 的便利包装：从 baseUrl 里取主机名做分桶。
class ContextLimitKey {
  static String of(String baseUrl, String model) {
    final host = Uri.tryParse(baseUrl)?.host ?? 'unknown';
    return 'openai|$host|$model';
  }
}

/// 只做无状态的错误识别。真正的学习在 AgentLoop 持有的那个 guard 上。
class _ErrorSniffer {
  bool isContextLimitError(int status, String? body) {
    if (body == null || body.isEmpty) return false;
    if (status != 400 && status != 413 && status != 422) return false;
    const markers = [
      'exceed_context_size_error',
      'context_length_exceeded',
      'context size',
      'context length',
      'context window',
      'reduce the length of the messages',
      'input token count exceeds',
      'prompt is too long',
      'too many tokens',
      'too long for model',
    ];
    final lower = body.toLowerCase();
    return markers.any(lower.contains);
  }
}
