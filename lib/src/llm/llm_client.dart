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

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../net/proxy_client.dart';
import 'model_catalog.dart';

import '../agent/agent_loop.dart';
import 'image_parts.dart';
import 'system_prompt.dart';
import '../agent/tools.dart';
import 'gemini_protocol.dart';
import 'reasoning.dart';
import 'thinking_effort.dart';
import 'oauth.dart';
import '../context/overflow_manager.dart';

class LlmConfig {
  final String apiFormat;
  final String baseUrl; // 例如 https://api.openai.com/v1
  final String apiKey;
  final String model;
  final String? googleProject;

  /// 摘要用的模型。可以指定一个更小更便宜的 —— 摘要任务不需要旗舰模型，
  /// 而它的调用频率随对话长度线性增长。
  ///
  /// null **和空字符串都表示「用对话模型」**。设置页的输入框留空时存下来的是
  /// `''` 而不是 null，只判 null 的话会把空串当成一个真实的模型名发出去
  /// —— 见 [summaryModelOrDefault]。
  final String? summaryModel;

  /// 实际用于摘要的模型 id。
  ///
  /// 存在的理由是一个实测踩到的 bug：`summaryModel ?? model` 对空字符串不成立，
  /// 于是摘要请求带着 `"model": ""` 发出去，服务端 400。而 [summarize] 是
  /// **永不抛**的（它不该让用户这句话失败），所以它静默返回空 ——
  /// 表现为「滚动摘要一次都不会生效」，上下文只增不减，而且毫无迹象。
  String get summaryModelOrDefault {
    final s = summaryModel?.trim() ?? '';
    return s.isEmpty ? model : s;
  }

  /// HTTP 代理，`host:port`。空 = 直连。
  ///
  /// 跟着渠道走而不是全局：一个渠道走内网直连、另一个走梯子是很常见的组合。
  final String? proxy;

  final double temperature;
  final bool streamOutput;

  /// 允不允许把图片直接塞进请求。
  ///
  /// 这是**一个开关管两件事**：对话模型认不认图（渠道上勾的），以及用户
  /// 有没有强制走前置多模态（省钱）。两种情况下都不该发原图 —— 前者会
  /// 400 或者更糟（模型收到图却当没看见），后者是白花一次图片的钱。
  ///
  /// 放在配置里而不是每条消息上：它是"当前这个接入点怎么用"的属性，
  /// 换渠道就跟着换，不需要给每条历史消息都记一份。
  final bool sendImagesInline;

  /// 系统提示词怎么送。不认 `role: system` 的服务改成拼进第一条用户消息。
  final SystemPromptStyle systemPromptStyle;

  /// 让模型自己联网搜索（Gemini 的 `google_search` 内置工具）。
  ///
  /// **只有 Gemini 原生层有这个东西。** OpenAI 兼容层不提供 —— 在那边把
  /// `{"google_search":{}}` 塞进 `tools` 会被当成函数声明去校验，直接
  /// `Unknown name 'google_search'`。所以这个开关在别的协议上是死的，
  /// 界面上也只在原生协议下才显示。
  final bool webSearch;

  /// 让模型想多久。默认 [ThinkingEffort.auto] —— 一个字段都不发。
  ///
  /// 不做成"哪些模型支持"的判断表：能思考的模型每周都在变，而判错的代价是
  /// 整轮请求 400。默认不发，用户主动调了才发，撞上不支持的模型时报错里会
  /// 直接说是这个旋钮的事。
  final ThinkingEffort thinkingEffort;

  const LlmConfig({
    this.apiFormat = 'openAI',
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    this.googleProject,
    this.summaryModel,
    this.proxy,
    this.temperature = 0.3,
    this.streamOutput = true,
    this.sendImagesInline = false,
    this.systemPromptStyle = SystemPromptStyle.systemRole,
    this.webSearch = false,
    this.thinkingEffort = ThinkingEffort.auto,
  });

  static const empty = LlmConfig(baseUrl: '', apiKey: '', model: '');

  bool get isConfigured => baseUrl.isNotEmpty && model.isNotEmpty;

  bool get isChatGptOAuth => apiFormat == 'chatgptOAuth';

  LlmConfig copyWith({
    String? apiFormat,
    String? baseUrl,
    String? apiKey,
    String? model,
    String? googleProject,
    String? summaryModel,
    String? proxy,
    double? temperature,
    bool? streamOutput,
    bool? sendImagesInline,
    SystemPromptStyle? systemPromptStyle,
    bool? webSearch,
    ThinkingEffort? thinkingEffort,
  }) =>
      LlmConfig(
        apiFormat: apiFormat ?? this.apiFormat,
        baseUrl: baseUrl ?? this.baseUrl,
        apiKey: apiKey ?? this.apiKey,
        model: model ?? this.model,
        googleProject: googleProject ?? this.googleProject,
        summaryModel: summaryModel ?? this.summaryModel,
        proxy: proxy ?? this.proxy,
        temperature: temperature ?? this.temperature,
        streamOutput: streamOutput ?? this.streamOutput,
        sendImagesInline: sendImagesInline ?? this.sendImagesInline,
        systemPromptStyle: systemPromptStyle ?? this.systemPromptStyle,
        webSearch: webSearch ?? this.webSearch,
        thinkingEffort: thinkingEffort ?? this.thinkingEffort,
      );
}

class ConfigurableLlmClient
    implements LlmClient, CancellableLlmClient, ImageDescriber {
  LlmConfig _config;
  http.Client _http;
  final bool _ownsClient;
  final Duration connectionTimeout;

  /// OAuth 渠道的 access_token 提供者。null 表示用 [LlmConfig.apiKey]。
  ///
  /// 不把 token 塞进 config：它会过期，而 config 是被到处传的快照，
  /// 存进去就等于存了一份马上失效的副本。每次请求前现取才是对的。
  Future<String> Function()? bearerProvider;

  /// ChatGPT Codex 后端还要求 workspace account id；它与登录账号的本地 id
  /// 不是一回事，所以和 token 一样从凭据仓库现取。
  Future<String?> Function()? chatGptAccountIdProvider;

  ConfigurableLlmClient({
    LlmConfig? config,
    http.Client? httpClient,
    this.connectionTimeout = const Duration(seconds: 45),
  })  : _config = config ?? LlmConfig.empty,
        _http = httpClient ?? buildHttpClient(proxy: config?.proxy),
        _ownsClient = httpClient == null;

  LlmConfig get config => _config;

  /// 换配置。**代理变了要重建底层客户端** —— 代理是在 HttpClient 上设的，
  /// 不是每个请求的参数，光换 config 不会有任何效果，而表现是
  /// 「改了代理没反应」这种最难查的一类。
  set config(LlmConfig value) {
    final proxyChanged = value.proxy != _config.proxy;
    _config = value;
    if (proxyChanged && _ownsClient) {
      _http.close();
      _http = buildHttpClient(proxy: value.proxy);
    }
  }

  /// 这次请求该用的密钥。OAuth 渠道现取 token，普通渠道用配置里的 key。
  Future<String> _authValue() async {
    final provider = bearerProvider;
    if (provider == null) return _config.apiKey;
    return provider();
  }

  Future<String> _chatGptAccountId() async {
    final value = (await chatGptAccountIdProvider?.call())?.trim() ?? '';
    if (value.isEmpty) {
      throw const LlmConnectionException(
          '登录凭据缺少 ChatGPT Account ID，请退出该账号后重新登录');
    }
    return value;
  }

  static const _codexEndpoint =
      'https://chatgpt.com/backend-api/codex/responses';
  static const _codexVersion = '0.144.1';

  Future<Map<String, String>> _chatGptHeaders(String token) async => {
        'Content-Type': 'application/json',
        'Accept': 'text/event-stream',
        'Authorization': 'Bearer $token',
        'chatgpt-account-id': await _chatGptAccountId(),
        'originator': 'codex_cli_rs',
        'version': _codexVersion,
        'User-Agent': 'codex_cli_rs/$_codexVersion',
      };

  @override
  void cancel() {
    _http.close();
    // 重建时必须**带上代理**：cancel 之后代理静默消失是一个很隐蔽的
    // "只在取消过一次之后才出现"的 bug。
    if (_ownsClient) _http = buildHttpClient(proxy: _config.proxy);
  }

  Future<void> testConnection([LlmConfig? draft]) async {
    final value = draft ?? config;
    if (!value.isConfigured) {
      throw StateError('请先填写 Base URL 和模型');
    }
    final anthropic = value.apiFormat == 'anthropic';
    final chatGpt = value.isChatGptOAuth;
    final uri = chatGpt
        ? Uri.parse(_codexEndpoint)
        : _endpoint(
            value.baseUrl, anthropic ? '/messages' : '/chat/completions');
    http.Response response;
    try {
      final headers = chatGpt
          ? await _chatGptHeaders(value.apiKey)
          : <String, String>{
              'Content-Type': 'application/json',
              if (anthropic) 'anthropic-version': '2023-06-01',
              if (anthropic && value.apiKey.isNotEmpty)
                'x-api-key': value.apiKey,
              if (!anthropic && value.apiKey.isNotEmpty)
                'Authorization': 'Bearer ${value.apiKey}',
            };
      response = await _http
          .post(
            uri,
            headers: headers,
            body: jsonEncode(chatGpt
                ? <String, Object?>{
                    'model': value.model,
                    'instructions': 'You are a helpful assistant.',
                    'input': <Map<String, String>>[
                      {'role': 'user', 'content': 'Hi'},
                    ],
                    'stream': true,
                    'store': false,
                  }
                : <String, Object?>{
                    'model': value.model,
                    if (uri.host == 'api.openai.com')
                      'max_completion_tokens': 1
                    else
                      'max_tokens': 1,
                    'stream': false,
                    'messages': <Map<String, String>>[
                      <String, String>{'role': 'user', 'content': 'Hi'},
                    ],
                  }),
          )
          .timeout(connectionTimeout);
    } on TimeoutException {
      throw LlmConnectionException(
        '连接超时（${connectionTimeout.inSeconds} 秒）。请检查 Base URL、手机网络、代理设置，'
        '以及本地 Gateway 是否已启动。',
      );
    } on FormatException {
      throw const LlmConnectionException('Base URL 格式不正确，请填写完整的 http(s) 地址');
    } on http.ClientException catch (error) {
      throw LlmConnectionException('无法连接模型服务：${error.message}');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw LlmConnectionException(
        '连接失败 HTTP ${response.statusCode}: ${_brief(response.body)}',
      );
    }
  }

  /// 见 [resolveApiEndpoint]：同时接受服务根地址、带版本段的地址，
  /// 和用户直接粘贴的完整接口地址。
  static Uri _endpoint(String baseUrl, String suffix) =>
      resolveApiEndpoint(baseUrl, suffix);

  @override
  String get limitKey => ContextLimitKey.of(config.baseUrl, config.model);

  @override
  Future<LlmTurn> complete({
    required List<ChatMessage> messages,
    required List<ToolSpec> tools,
    required void Function(String delta) onDelta,
    void Function(String delta)? onReasoning,
  }) async {
    // 可选参数在这里收成一个必定存在的函数，下面五条协议路径就不用各写一遍
    // 空判断 —— 漏写一处的表现是"某个渠道的思考不显示"，很难被注意到。
    final reason = onReasoning ?? (_) {};
    if (!config.isConfigured) {
      throw StateError('尚未配置模型服务，请先在设置里填 baseUrl 和 model');
    }

    // 系统提示词先按渠道的写法重排。放在最前面：后面三条协议路径各有各的
    // system 处理（Anthropic 提到顶层 `system` 字段、Responses 提到
    // `instructions`），重排完再进去，那三处就都不用各写一遍降级逻辑。
    final prepared = applySystemPromptStyle(messages, config.systemPromptStyle);

    // 图先读出来再分派：三条协议路径都要用，而读盘是异步的 ——
    // 放到各自的 body 拼装里就得把整条链路改成异步 map，很难看。
    final images = await _loadImages(prepared);

    if (config.apiFormat == 'gemini') {
      return _completeCodeAssist(
        messages: prepared,
        tools: tools,
        onDelta: onDelta,
        onReasoning: reason,
        images: images,
      );
    }
    if (config.apiFormat == 'geminiNative') {
      return _completeGeminiNative(
        messages: prepared,
        tools: tools,
        onDelta: onDelta,
        onReasoning: reason,
        images: images,
      );
    }
    if (config.apiFormat == 'anthropic') {
      return _completeAnthropic(
        messages: prepared,
        tools: tools,
        onDelta: onDelta,
        onReasoning: reason,
        images: images,
      );
    }
    if (config.isChatGptOAuth) {
      return _completeChatGpt(
        messages: prepared,
        tools: tools,
        onDelta: onDelta,
        onReasoning: reason,
        images: images,
      );
    }
    return _completeOpenAi(
      messages: prepared,
      tools: tools,
      onDelta: onDelta,
      onReasoning: reason,
      images: images,
    );
  }

  /// 读出这批消息里引用到的所有图。
  ///
  /// 读不出来的那张不会让整条消息发不出去，而是**在正文里留一句话** ——
  /// 静默丢掉的话，模型会对着一条提到"这张图"却没有图的消息硬答，
  /// 而用户完全看不出图没发出去。
  Future<Map<String, InlineImage>> _loadImages(
      List<ChatMessage> messages) async {
    // 不发图的渠道连读都不用读。几张图就是几 MB 的盘 IO，
    // 读出来只为了在下一步扔掉，纯浪费。
    if (!config.sendImagesInline) return const <String, InlineImage>{};
    final paths = <String>[
      for (final message in messages) ...message.images,
    ];
    if (paths.isEmpty) return const <String, InlineImage>{};
    final (loaded, failures) = await loadInlineImages(paths);
    _imageWarnings.addAll(failures);
    return loaded;
  }

  /// 上一次请求里读图失败的原因。UI 拿去提示用户。
  final List<String> _imageWarnings = <String>[];
  List<String> takeImageWarnings() {
    final out = List<String>.from(_imageWarnings);
    _imageWarnings.clear();
    return out;
  }

  Future<LlmTurn> _completeChatGpt({
    required List<ChatMessage> messages,
    required List<ToolSpec> tools,
    required void Function(String delta) onDelta,
    required void Function(String delta) onReasoning,
    String? model,
    Map<String, InlineImage> images = const <String, InlineImage>{},
  }) async {
    final auth = await _authValue();
    final system = messages
        .where((message) => message.role == 'system')
        .map((message) => message.content)
        .join('\n\n');
    final request = http.Request('POST', Uri.parse(_codexEndpoint))
      ..headers.addAll(await _chatGptHeaders(auth))
      ..body = jsonEncode(<String, Object?>{
        'model': model ?? config.model,
        'instructions':
            system.isEmpty ? 'You are a helpful assistant.' : system,
        'input': messages
            .where((message) => message.role != 'system')
            .map((message) {
          final attached = _attached(message, images);
          return <String, Object?>{
            'role': message.role == 'assistant' ? 'assistant' : 'user',
            'content': attached.isEmpty
                ? (message.role == 'tool'
                    ? '[工具结果]\n${message.content}'
                    : withImagePlaceholder(
                        message.content, message.images.length))
                : responsesContentParts(message.content, attached),
          };
        }).toList(),
        'stream': true,
        'store': false,
        if (config.thinkingEffort.openAiEffort != null)
          'reasoning': <String, Object?>{
            'effort': config.thinkingEffort.openAiEffort,
          },
        if (tools.isNotEmpty)
          'tools': tools
              .map((tool) => <String, Object?>{
                    'type': 'function',
                    'name': tool.name,
                    'description': tool.description,
                    'parameters': tool.parameters,
                  })
              .toList(),
      });
    final response = await _http.send(request);
    if (response.statusCode >= 400) {
      final body = await response.stream.bytesToString();
      if (_guard.isContextLimitError(response.statusCode, body)) {
        throw ContextOverflowException(response.statusCode, body);
      }
      throw http.ClientException(
          'LLM 返回 ${response.statusCode}: ${_brief(body)}');
    }
    // ChatGPT 唯一能拿到**真实余量**的地方就是这里的响应头 —— 没有独立的
    // 查询接口。所以余量是"聊过一句之后才知道"，而不是登录完就有。
    _reportRateLimit(response.headers);
    return _readResponsesStream(response.stream, onDelta, onReasoning);
  }

  /// 从响应头里读到用量时回调出去。由 main.dart 接到 AccountStore 上。
  ///
  /// 用回调而不是让客户端直接写 AccountStore：这一层不该认识账号存储，
  /// 它只知道"刚才那次请求的响应头长这样"。
  void Function(AccountQuota quota)? onRateLimit;

  void _reportRateLimit(Map<String, String> headers) {
    final sink = onRateLimit;
    if (sink == null) return;
    final quota = parseCodexRateLimit(headers, plan: 'ChatGPT');
    if (quota != null) sink(quota);
  }

  Future<LlmTurn> _readResponsesStream(
    http.ByteStream stream,
    void Function(String) onDelta,
    void Function(String) onReasoning,
  ) async {
    final text = StringBuffer();
    final reasoning = StringBuffer();
    final clock = _ThinkClock();
    final calls = <String, _PartialToolCall>{};
    TokenUsage? usage;
    await for (final line
        in stream.transform(utf8.decoder).transform(const LineSplitter())) {
      if (!line.startsWith('data:')) continue;
      final payload = line.substring(5).trim();
      if (payload.isEmpty || payload == '[DONE]') continue;
      Map<String, Object?> event;
      try {
        event = jsonDecode(payload) as Map<String, Object?>;
      } catch (_) {
        continue;
      }
      final type = event['type'];
      if (type == 'response.completed' || type == 'response.incomplete') {
        // 用量挂在 response 对象上，只有收尾事件里有。
        final response = event['response'] as Map<String, Object?>?;
        final reported = TokenUsage.fromResponses(response?['usage']);
        if (reported != null) usage = reported;
      }
      if (type == 'response.output_text.delta') {
        final delta = event['delta']?.toString() ?? '';
        if (delta.isNotEmpty) {
          clock.answer();
          text.write(delta);
          onDelta(delta);
        }
      } else if (type == 'response.reasoning_summary_text.delta') {
        // 推理模型只肯给**摘要**，原始思维链拿不到（服务端策略）。
        // 摘要要在请求里显式要（`reasoning.summary`），有些接入点默认就给，
        // 所以这里照收不误 —— 收到了就显示，收不到也不算错。
        final delta = event['delta']?.toString() ?? '';
        if (delta.isNotEmpty) {
          clock.think();
          reasoning.write(delta);
          onReasoning(delta);
        }
      } else if (type == 'response.reasoning_summary_part.added' &&
          reasoning.isNotEmpty) {
        // 多段摘要之间空一行，否则两段会黏成一句读不断的话。
        reasoning.write('\n\n');
        onReasoning('\n\n');
      } else if (type == 'response.output_item.added' ||
          type == 'response.output_item.done') {
        final item = event['item'] as Map<String, Object?>?;
        if (item?['type'] != 'function_call') continue;
        final key = item?['id']?.toString() ??
            item?['call_id']?.toString() ??
            'call_${calls.length}';
        final call = calls.putIfAbsent(key, _PartialToolCall.new);
        call.id = item?['call_id']?.toString() ?? key;
        call.name = item?['name']?.toString() ?? call.name;
        final arguments = item?['arguments']?.toString() ?? '';
        if (arguments.isNotEmpty) {
          call.args.clear();
          call.args.write(arguments);
        }
      } else if (type == 'response.function_call_arguments.delta') {
        final key = event['item_id']?.toString() ??
            event['call_id']?.toString() ??
            'call_0';
        calls
            .putIfAbsent(key, _PartialToolCall.new)
            .args
            .write(event['delta']?.toString() ?? '');
      }
    }
    return LlmTurn(
      text: text.toString(),
      toolCalls: calls.values
          .where((call) => call.name.isNotEmpty)
          .map((call) => ToolCall(
                id: call.id.isEmpty ? 'call_0' : call.id,
                name: call.name,
                args: repairAndDecode(call.args.toString()),
              ))
          .toList(),
      usage: usage,
      reasoning: reasoning.toString(),
      reasoningMs: clock.ms,
    );
  }

  Future<LlmTurn> _completeOpenAi({
    required List<ChatMessage> messages,
    required List<ToolSpec> tools,
    required void Function(String delta) onDelta,
    required void Function(String delta) onReasoning,
    Map<String, InlineImage> images = const <String, InlineImage>{},
  }) async {
    final auth = await _authValue();
    final request = http.Request(
      'POST',
      _endpoint(config.baseUrl, '/chat/completions'),
    )
      ..headers.addAll({
        'Content-Type': 'application/json',
        if (auth.isNotEmpty) 'Authorization': 'Bearer $auth',
      })
      ..body = jsonEncode({
        'model': config.model,
        'temperature': config.temperature,
        'stream': config.streamOutput,
        if (config.thinkingEffort.openAiEffort != null)
          'reasoning_effort': config.thinkingEffort.openAiEffort,
        'messages': messages.map((m) => _toWire(m, images)).toList(),
        // 流式下服务端默认**不**回报用量，要显式要一次，它才会在最后补一个
        // choices 为空、只带 usage 的块。非流式无条件返回，不用要。
        //
        // 少数严格的网关会因为不认识这个字段直接 400 —— 那种情况下面会
        // 摘掉它重发一次（见 _retryWithoutStreamOptions）。
        if (config.streamOutput && !_streamUsageUnsupported)
          'stream_options': <String, Object?>{'include_usage': true},
        if (tools.isNotEmpty)
          'tools': tools.map((t) => t.toOpenAiJson()).toList(),
      });

    var response = await _http.send(request);

    // 只在"确实是因为 stream_options 被拒"时重试一次，然后记住这个渠道不支持，
    // 之后不再带它。宽泛地对所有 400 重试会把真正的错误（模型名不对、
    // 鉴权失败）也吞掉一次，让排查变慢一倍。
    if (response.statusCode == 400 && !_streamUsageUnsupported) {
      final body = await response.stream.bytesToString();
      if (body.contains('stream_options')) {
        _streamUsageUnsupported = true;
        return _completeOpenAi(
          messages: messages,
          tools: tools,
          onDelta: onDelta,
          onReasoning: onReasoning,
          images: images,
        );
      }
      if (_guard.isContextLimitError(400, body)) {
        throw ContextOverflowException(400, body);
      }
      _rejectIfThinkingEffort(body);
      throw http.ClientException('LLM 返回 400: ${_brief(body)}');
    }

    if (response.statusCode >= 400) {
      final body = await response.stream.bytesToString();
      // 这一步是 ContextLimitGuard 的入口。判断放在这里而不是 AgentLoop：
      // 只有这一层同时拿得到状态码和原始响应体。
      if (_guard.isContextLimitError(response.statusCode, body)) {
        throw ContextOverflowException(response.statusCode, body);
      }
      _rejectIfThinkingEffort(body);
      throw http.ClientException(
          'LLM 返回 ${response.statusCode}: ${_brief(body)}');
    }

    if (config.streamOutput) {
      return _readStream(response.stream, onDelta, onReasoning);
    }
    final body = jsonDecode(await response.stream.bytesToString())
        as Map<String, Object?>;
    final choices = body['choices'] as List?;
    final message = choices == null || choices.isEmpty
        ? null
        : (choices.first as Map)['message'] as Map?;
    final text = message?['content']?.toString() ?? '';
    final thought = openAiReasoningOf(message);
    if (thought.isNotEmpty) onReasoning(thought);
    if (text.isNotEmpty) onDelta(text);
    final rawCalls = message?['tool_calls'] as List? ?? const [];
    final calls = rawCalls
        .whereType<Map>()
        .map((raw) {
          final function = raw['function'] as Map? ?? const {};
          return ToolCall(
            id: raw['id']?.toString() ?? 'call_0',
            name: function['name']?.toString() ?? '',
            args: repairAndDecode(function['arguments']?.toString() ?? ''),
          );
        })
        .where((call) => call.name.isNotEmpty)
        .toList();
    return LlmTurn(
      text: text,
      toolCalls: calls,
      usage: TokenUsage.fromOpenAi(body['usage']),
      // 非流式量不出思考时长 —— 整个响应是一次性到的。留 0，UI 不显示，
      // 而不是拿整次请求的耗时冒充"想了多久"。
      reasoning: thought,
    );
  }

  // -------------------------------------------------------------------------
  // Google Code Assist（Gemini 原生格式 + v1internal 包装）
  // -------------------------------------------------------------------------

  /// Code Assist 替这个账号托管的项目号。
  ///
  /// 不是用户填的，是登录后用 `:loadCodeAssist` 问出来的 —— 那正是这条路
  /// "不需要 GCP 项目"的原因。问一次就缓存在这个客户端实例里：换渠道会新建
  /// 客户端，而项目号是跟着账号走的。
  String? _codeAssistProject;

  static const _codeAssistMetadata = <String, Object?>{
    'ideType': 'ANTIGRAVITY',
    'pluginType': 'PLUGIN_UNSPECIFIED',
  };

  static String? _projectValue(Object? value) {
    if (value is String) {
      final id = value.trim();
      return id.isEmpty ? null : id;
    }
    if (value is Map) {
      return _projectValue(value['id'] ?? value['projectNumber']);
    }
    return null;
  }

  static Map<String, Object?>? _preferredAllowedTier(Object? value) {
    if (value is! List) return null;
    Map<String, Object?>? first;
    for (final item in value) {
      if (item is! Map) continue;
      final id = item['id']?.toString().trim();
      if (id == null || id.isEmpty) continue;
      final tier = <String, Object?>{
        'id': id,
        if (item['userDefinedCloudaicompanionProject'] == true)
          'userDefinedCloudaicompanionProject': true,
      };
      if (id == 'standard-tier') return tier;
      first ??= tier;
    }
    return first;
  }

  Future<String> _ensureCodeAssistProject() async {
    final cached = _codeAssistProject;
    if (cached != null) return cached;

    // 这个协议只认 Code Assist 的内部接口。指向别处时**立刻说清楚** ——
    // 不拦的话会去打一个不存在的 `:loadCodeAssist`，拿到 404，而 404 只会让人
    // 以为是地址少了一段，接着去试各种路径。真正的问题是协议选错了。
    if (!config.baseUrl.contains('cloudcode-pa.googleapis.com')) {
      throw http.ClientException(
        '「Code Assist」协议只能连 cloudcode-pa.googleapis.com，'
        '当前地址是 ${config.baseUrl}。\n\n'
        '要用 Gemini API（API Key）的话，协议选「OpenAI 兼容」，'
        'Base URL 填：$geminiOpenAiBaseUrl',
      );
    }

    final auth = await _authValue();
    Map<String, String> headers() => <String, String>{
          'Content-Type': 'application/json',
          if (auth.isNotEmpty) 'Authorization': 'Bearer $auth',
        };

    final loaded = await _http.send(
      http.Request('POST', Uri.parse('${config.baseUrl}:loadCodeAssist'))
        ..headers.addAll(headers())
        ..body = jsonEncode(<String, Object?>{
          'metadata': _codeAssistMetadata,
          'mode': 'FULL_ELIGIBILITY_CHECK',
        }),
    );
    final loadedBody = await loaded.stream.bytesToString();
    if (loaded.statusCode >= 400) {
      throw http.ClientException(
        'Code Assist 初始化失败：HTTP ${loaded.statusCode} ${_brief(loadedBody)}\n'
        '这个接口要求账号已经接受过 Gemini Code Assist 的条款。'
        '可以先用 gemini-cli 或网页版登录一次再回来。',
      );
    }

    final json = jsonDecode(loadedBody);
    if (json is Map) {
      final project = _projectValue(json['cloudaicompanionProject']);
      if (project != null) {
        _codeAssistProject = project;
        return project;
      }

      final tier = _preferredAllowedTier(json['allowedTiers']);
      if (tier != null) {
        final userProject = config.googleProject?.trim();
        final needsUserProject =
            tier['userDefinedCloudaicompanionProject'] == true;
        if (needsUserProject && (userProject == null || userProject.isEmpty)) {
          throw http.ClientException(
            'Google 已允许这个账号使用 ${tier['id']}，但这个档位要绑定你自己的 GCP 项目。\n'
            '请在渠道设置的「GCP 项目 ID」里填入项目 ID 后重试。'
            '这不是项目编号，也不是 Vertex 区域；账号需要对这个项目有足够权限。',
          );
        }
        return _onboardCodeAssist(
          headers,
          tierId: tier['id']! as String,
          cloudProject: needsUserProject ? userProject : null,
        );
      }

      final ineligible = json['ineligibleTiers'];
      if (ineligible is List && ineligible.isNotEmpty) {
        final first = ineligible.first;
        final reason = first is Map
            ? (first['reasonMessage'] ?? first['reasonCode'])?.toString()
            : null;
        throw http.ClientException(
          'Google 没有返回这个账号可用的 Code Assist 档位：\n'
          '${reason ?? '未说明原因'}\n\n'
          '如果账号已订阅，请确认 Google 返回的可用档位要求都已满足；'
          '或者改用「Vertex AI（自己的项目）」。',
        );
      }
    }

    // 没有项目号、也没有档位信息 = 这个账号还没开通过。保留旧的免费档开通路径。
    return _onboardCodeAssist(headers, tierId: 'free-tier');
  }

  /// 首次使用时的开通。返回 Google 分配的项目号。
  ///
  /// 它是个长时操作（LRO）：第一次调用多半返回 `done: false`，要隔几秒再问。
  /// 不轮询的话表现是"第一次登录后必失败、第二次莫名其妙就好了"。
  Future<String> _onboardCodeAssist(
    Map<String, String> Function() headers, {
    required String tierId,
    String? cloudProject,
  }) async {
    const maxAttempts = 10;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      final response = await _http.send(
        http.Request('POST', Uri.parse('${config.baseUrl}:onboardUser'))
          ..headers.addAll(headers())
          ..body = jsonEncode(<String, Object?>{
            'tierId': tierId,
            if (cloudProject != null && cloudProject.isNotEmpty)
              'cloudaicompanionProject': cloudProject,
            'metadata': _codeAssistMetadata,
          }),
      );
      final body = await response.stream.bytesToString();
      if (response.statusCode >= 400) {
        throw http.ClientException(
            '开通 Code Assist 失败：HTTP ${response.statusCode} ${_brief(body)}');
      }
      final json = jsonDecode(body);
      if (json is Map) {
        if (json['done'] == true) {
          final inner = json['response'];
          final project =
              inner is Map ? inner['cloudaicompanionProject'] : null;
          final id = project is Map ? project['id'] : project;
          if (id is String && id.isNotEmpty) {
            _codeAssistProject = id;
            return id;
          }
        }
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    throw http.ClientException('开通 Code Assist 超时，请稍后重试');
  }

  /// Gemini 的请求体。原生层直接发它，Code Assist 再包一层。
  Map<String, Object?> _geminiRequestBody({
    required List<ChatMessage> messages,
    required List<ToolSpec> tools,
    required Map<String, InlineImage> images,
  }) {
    final wire = geminiTools(tools, webSearch: config.webSearch);
    // 思考摘要要**主动要**才给，强度也一样。整块只发给认得它的那几代模型 ——
    // 2.0 和更老收到 thinkingConfig 会直接 400，把整轮对话弄失败。
    final thoughts = geminiSupportsThoughts(config.model);
    return <String, Object?>{
      'contents': geminiContents(messages, images),
      if (geminiSystemInstruction(messages) != null)
        'systemInstruction': geminiSystemInstruction(messages),
      if (wire.isNotEmpty) 'tools': wire,
      'generationConfig': <String, Object?>{
        'temperature': config.temperature,
        if (thoughts)
          'thinkingConfig':
              geminiThinkingConfig(config.model, config.thinkingEffort),
      },
    };
  }

  /// Gemini 原生 REST（API Key）。
  ///
  /// 和 Code Assist 走的是同一套线格式，差别只有三处：请求体不包
  /// `{model, project, request}`、认证头是 `x-goog-api-key` 而不是 Bearer、
  /// 模型名在 URL 里而不在 body 里。
  ///
  /// **这条路存在的理由是联网搜索。** 兼容层（`openAI` 协议）连 Gemini 更省事，
  /// 但它拿不到 `google_search` —— 见 [LlmConfig.webSearch]。
  Future<LlmTurn> _completeGeminiNative({
    required List<ChatMessage> messages,
    required List<ToolSpec> tools,
    required void Function(String delta) onDelta,
    required void Function(String delta) onReasoning,
    Map<String, InlineImage> images = const <String, InlineImage>{},
  }) async {
    final key = await _authValue();
    var root = config.baseUrl.trim();
    while (root.endsWith('/')) {
      root = root.substring(0, root.length - 1);
    }

    final endpoint =
        Uri.parse('$root/models/${config.model}:streamGenerateContent?alt=sse');
    final httpRequest = http.Request('POST', endpoint)
      ..headers.addAll(<String, String>{
        'Content-Type': 'application/json',
        // 原生层**不认 Bearer**。用错的表现是 401，而 401 看起来就是密钥不对。
        ...geminiAuthHeaders(key, apiFormat: 'geminiNative'),
      })
      ..body = jsonEncode(_geminiRequestBody(
        messages: messages,
        tools: tools,
        images: images,
      ));

    final response = await _http.send(httpRequest);
    if (response.statusCode >= 400) {
      final body = await response.stream.bytesToString();
      if (_guard.isContextLimitError(response.statusCode, body)) {
        throw ContextOverflowException(response.statusCode, body);
      }
      if (config.webSearch && isGeminiToolMixError(body)) {
        throw http.ClientException(
          '这个模型不允许「联网搜索」和「工具调用」同时开。\n\n'
          'Gemini 3 之前的模型（2.5 及更老）只能二选一。要么换成 Gemini 3 '
          '系列，要么在渠道里关掉这个模型的联网搜索、或者关掉终端模式。',
        );
      }
      _rejectIfThinkingEffort(body);
      // 配额说明放在**截断之前**。Google 把套话写在前面、把"哪个配额满了"
      // 写在最后，照原样截断的话留下的全是套话。
      final quota = describeGoogleQuota(body);
      throw http.ClientException(
        'LLM 返回 ${response.statusCode}: '
        '${quota.isEmpty ? '' : '$quota\n\n'}${_brief(body)}',
      );
    }

    return _readGeminiStream(
      response,
      onDelta: onDelta,
      onReasoning: onReasoning,
      codeAssist: false,
    );
  }

  Future<LlmTurn> _completeCodeAssist({
    required List<ChatMessage> messages,
    required List<ToolSpec> tools,
    required void Function(String delta) onDelta,
    required void Function(String delta) onReasoning,
    Map<String, InlineImage> images = const <String, InlineImage>{},
  }) async {
    final project = await _ensureCodeAssistProject();
    final auth = await _authValue();

    // 非流式也走 streamGenerateContent：这个内部接口的非流式端点行为和文档
    // 对不上（有时返回数组、有时返回单对象），而流式那条是 gemini-cli 天天在
    // 跑的路径。统一走它，非流式只是不往 onDelta 里喂增量。
    final endpoint =
        Uri.parse('${config.baseUrl}:streamGenerateContent?alt=sse');
    final httpRequest = http.Request('POST', endpoint)
      ..headers.addAll(<String, String>{
        'Content-Type': 'application/json',
        if (auth.isNotEmpty) 'Authorization': 'Bearer $auth',
      })
      ..body = jsonEncode(wrapCodeAssistRequest(
        model: config.model,
        project: project,
        request: _geminiRequestBody(
          messages: messages,
          tools: tools,
          images: images,
        ),
      ));

    final response = await _http.send(httpRequest);
    if (response.statusCode >= 400) {
      final body = await response.stream.bytesToString();
      if (_guard.isContextLimitError(response.statusCode, body)) {
        throw ContextOverflowException(response.statusCode, body);
      }
      throw http.ClientException(
          'LLM 返回 ${response.statusCode}: ${_brief(body)}');
    }

    return _readGeminiStream(
      response,
      onDelta: onDelta,
      onReasoning: onReasoning,
      codeAssist: true,
    );
  }

  /// 读一条 Gemini 的 SSE 流。两条路径唯一的差别是要不要剥 `response` 壳。
  Future<LlmTurn> _readGeminiStream(
    http.StreamedResponse response, {
    required void Function(String delta) onDelta,
    required void Function(String delta) onReasoning,
    required bool codeAssist,
  }) async {
    final text = StringBuffer();
    final reasoning = StringBuffer();
    final clock = _ThinkClock();
    final calls = <ToolCall>[];
    TokenUsage? usage;
    final queries = <String>[];
    final sources = <GroundingSource>[];

    await for (final line in response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      final event = decodeSseData(line);
      if (event == null) continue;
      final chunk = parseGeminiResponse(
          codeAssist ? unwrapCodeAssistResponse(event) : event);
      if (chunk.text.isNotEmpty) {
        clock.answer();
        text.write(chunk.text);
        if (config.streamOutput) onDelta(chunk.text);
      }
      if (chunk.reasoning.isNotEmpty) {
        clock.think();
        reasoning.write(chunk.reasoning);
        if (config.streamOutput) onReasoning(chunk.reasoning);
      }
      calls.addAll(chunk.calls);
      // 用量是**累计值**（每个块报的都是到目前为止的总数），所以覆盖而不是累加。
      if (chunk.usage != null) usage = chunk.usage;
      // 来源在流里是**逐块累积**的，后面的块会把前面报过的再报一遍 —— 去重。
      for (final q in chunk.queries) {
        if (!queries.contains(q)) queries.add(q);
      }
      for (final source in chunk.sources) {
        if (!sources.contains(source)) sources.add(source);
      }
    }

    // 来源附在正文末尾，**只在流结束后追加一次**。边收边追加的话，后面的块
    // 还会带来新的来源，界面上就会看到来源列表反复重画、越长越多。
    final citations = formatGroundingSources(sources, queries);
    if (citations.isNotEmpty) {
      text.write(citations);
      if (config.streamOutput) onDelta(citations);
    }

    // 非流式时一次性把正文喂过去，保持和另外几条路径一样的回调契约。
    if (!config.streamOutput) {
      if (reasoning.isNotEmpty) onReasoning(reasoning.toString());
      if (text.isNotEmpty) onDelta(text.toString());
    }

    return LlmTurn(
      text: text.toString(),
      toolCalls: calls,
      usage: usage,
      reasoning: reasoning.toString(),
      reasoningMs: clock.ms,
    );
  }

  Future<LlmTurn> _completeAnthropic({
    required List<ChatMessage> messages,
    required List<ToolSpec> tools,
    required void Function(String delta) onDelta,
    required void Function(String delta) onReasoning,
    Map<String, InlineImage> images = const <String, InlineImage>{},
  }) async {
    final system = messages
        .where((message) => message.role == 'system')
        .map((message) => message.content)
        .join('\n\n');
    final thinking = anthropicThinking(config.thinkingEffort);
    final auth = await _authValue();
    final request = http.Request(
      'POST',
      _endpoint(config.baseUrl, '/messages'),
    )
      ..headers.addAll(<String, String>{
        'Content-Type': 'application/json',
        'anthropic-version': '2023-06-01',
        if (auth.isNotEmpty) 'x-api-key': auth,
      })
      ..body = jsonEncode(<String, Object?>{
        'model': config.model,
        'max_tokens': thinking?.maxTokens ?? 4096,
        // 开了扩展思考就**不能再送 temperature** —— Anthropic 要求它必须是 1，
        // 送别的值会 400。这里整个省掉，让服务端用它自己那份。
        if (thinking == null) 'temperature': config.temperature.clamp(0, 1),
        if (thinking != null)
          'thinking': <String, Object?>{
            'type': 'enabled',
            'budget_tokens': thinking.budget,
          },
        'stream': config.streamOutput,
        if (system.isNotEmpty) 'system': system,
        'messages': messages
            .where((message) => message.role != 'system')
            .map((message) {
          final attached = _attached(message, images);
          return <String, Object?>{
            'role': message.role == 'assistant' ? 'assistant' : 'user',
            'content': attached.isEmpty
                ? (message.role == 'tool'
                    ? '[工具结果]\n${message.content}'
                    : withImagePlaceholder(
                        message.content, message.images.length))
                : anthropicContentParts(message.content, attached),
          };
        }).toList(),
        if (tools.isNotEmpty)
          'tools': tools
              .map((tool) => <String, Object?>{
                    'name': tool.name,
                    'description': tool.description,
                    'input_schema': tool.parameters,
                  })
              .toList(),
      });
    final response = await _http.send(request);
    if (response.statusCode >= 400) {
      final body = await response.stream.bytesToString();
      if (_guard.isContextLimitError(response.statusCode, body)) {
        throw ContextOverflowException(response.statusCode, body);
      }
      _rejectIfThinkingEffort(body);
      throw http.ClientException(
          'LLM 返回 ${response.statusCode}: ${_brief(body)}');
    }
    if (config.streamOutput) {
      return _readAnthropicStream(response.stream, onDelta, onReasoning);
    }
    final body = jsonDecode(await response.stream.bytesToString())
        as Map<String, Object?>;
    final content = body['content'] as List? ?? const [];
    final text = content
        .whereType<Map>()
        .where((block) => block['type'] == 'text')
        .map((block) => block['text']?.toString() ?? '')
        .join();
    final thought = content
        .whereType<Map>()
        .where((block) => block['type'] == 'thinking')
        .map((block) => block['thinking']?.toString() ?? '')
        .join();
    if (thought.isNotEmpty) onReasoning(thought);
    if (text.isNotEmpty) onDelta(text);
    final calls = content
        .whereType<Map>()
        .where((block) => block['type'] == 'tool_use')
        .map((block) => ToolCall(
              id: block['id']?.toString() ?? 'call_0',
              name: block['name']?.toString() ?? '',
              args: (block['input'] as Map?)
                      ?.map((key, value) => MapEntry(key.toString(), value)) ??
                  const {},
            ))
        .where((call) => call.name.isNotEmpty)
        .toList();
    return LlmTurn(
      text: text,
      toolCalls: calls,
      usage: TokenUsage.fromAnthropic(body['usage']),
      reasoning: thought,
    );
  }

  Future<LlmTurn> _readAnthropicStream(
    http.ByteStream stream,
    void Function(String) onDelta,
    void Function(String) onReasoning,
  ) async {
    final text = StringBuffer();
    final reasoning = StringBuffer();
    final clock = _ThinkClock();
    final partial = <int, _PartialToolCall>{};
    // Anthropic 把用量拆成两半送：input 在 message_start，output 在
    // message_delta。所以要边收边并，不能等某一个事件一次读全。
    var usage = const TokenUsage();
    await for (final line
        in stream.transform(utf8.decoder).transform(const LineSplitter())) {
      if (!line.startsWith('data:')) continue;
      final payload = line.substring(5).trim();
      if (payload.isEmpty) continue;
      Map<String, Object?> event;
      try {
        event = jsonDecode(payload) as Map<String, Object?>;
      } catch (_) {
        continue;
      }
      final type = event['type'];
      final index = (event['index'] as num?)?.toInt() ?? 0;
      if (type == 'message_start') {
        final message = event['message'] as Map<String, Object?>?;
        final reported = TokenUsage.fromAnthropic(message?['usage']);
        if (reported != null) usage = usage + reported;
      } else if (type == 'message_delta') {
        final reported = TokenUsage.fromAnthropic(event['usage']);
        if (reported != null) usage = usage + reported;
      } else if (type == 'content_block_start') {
        final block = event['content_block'] as Map<String, Object?>?;
        if (block?['type'] == 'tool_use') {
          final slot = partial.putIfAbsent(index, _PartialToolCall.new);
          slot.id = block?['id']?.toString() ?? 'call_$index';
          slot.name = block?['name']?.toString() ?? '';
          final input = block?['input'];
          if (input is Map && input.isNotEmpty) {
            slot.args.write(jsonEncode(input));
          }
        }
      } else if (type == 'content_block_delta') {
        final delta = event['delta'] as Map<String, Object?>?;
        if (delta?['type'] == 'text_delta') {
          final value = delta?['text']?.toString() ?? '';
          clock.answer();
          text.write(value);
          onDelta(value);
        } else if (delta?['type'] == 'thinking_delta') {
          // 只**收**不**开**：扩展思考要在请求里显式声明预算，而那个开关
          // 还会强制 temperature=1。这里照单全收，是为了让已经在网关那侧
          // 开了思考的渠道也能把内容显示出来。
          final value = delta?['thinking']?.toString() ?? '';
          clock.think();
          reasoning.write(value);
          onReasoning(value);
        } else if (delta?['type'] == 'input_json_delta') {
          partial.putIfAbsent(index, _PartialToolCall.new).args.write(
                delta?['partial_json']?.toString() ?? '',
              );
        }
      }
    }
    return LlmTurn(
      text: text.toString(),
      toolCalls: partial.entries
          .where((entry) => entry.value.name.isNotEmpty)
          .map((entry) => ToolCall(
                id: entry.value.id.isEmpty
                    ? 'call_${entry.key}'
                    : entry.value.id,
                name: entry.value.name,
                args: repairAndDecode(entry.value.args.toString()),
              ))
          .toList(),
      usage: usage.isEmpty ? null : usage,
      reasoning: reasoning.toString(),
      reasoningMs: clock.ms,
    );
  }

  /// 这一轮的失败是不是"思考强度这个旋钮惹的"。是的话换一句人话抛出去。
  ///
  /// 检查放在**抛错之前**而不是让原始报错直出：原始那句只提到一个字段名，
  /// 而用户看不到请求体，没法把它和自己在设置页调过的档位对上。
  void _rejectIfThinkingEffort(String body) {
    if (config.thinkingEffort == ThinkingEffort.auto) return;
    if (!isThinkingEffortRejected(body)) return;
    throw http.ClientException(
      '这个模型不支持「思考强度」（当前设为「${config.thinkingEffort.label}」）。\n\n'
      '把设置里的思考强度调回「自动」，或者换一个会思考的模型。',
    );
  }

  /// 需要一个 guard 实例来做错误识别。它和 AgentLoop 持有的那个是两份 ——
  /// 这份只用 `isContextLimitError`（无状态判断），学习和预算都在那份上，
  /// 所以不会分裂。
  final _guard = _ErrorSniffer();

  /// 这个接入点不认 `stream_options`。撞过一次就记住，别每轮都去撞。
  ///
  /// 只活在本实例内：换渠道会新建客户端，而"这个网关支不支持"是接入点的属性，
  /// 持久化下来在用户换了后端之后反而是错的。
  bool _streamUsageUnsupported = false;

  Future<LlmTurn> _readStream(
    http.ByteStream stream,
    void Function(String) onDelta,
    void Function(String) onReasoning,
  ) async {
    final text = StringBuffer();
    final reasoning = StringBuffer();
    final clock = _ThinkClock();
    TokenUsage? usage;

    // 工具调用是**分片到达**的：id 和 name 在第一片，arguments 逐字符累加。
    // 必须按 index 攒起来，不能收到一片就当一次调用。
    final partial = <int, _PartialToolCall>{};

    await for (final line
        in stream.transform(utf8.decoder).transform(const LineSplitter())) {
      if (!line.startsWith('data:')) continue;
      final payload = line.substring(5).trim();
      if (payload.isEmpty || payload == '[DONE]') continue;

      Map<String, Object?> chunk;
      try {
        chunk = jsonDecode(payload) as Map<String, Object?>;
      } catch (_) {
        continue; // 心跳或注释行，跳过
      }

      // 用量在**最后一个块**里，而那个块的 choices 是空的 —— 先读它，
      // 否则下面那句 continue 会把它整个跳过。
      final reported = TokenUsage.fromOpenAi(chunk['usage']);
      if (reported != null) usage = reported;

      final choices = chunk['choices'] as List?;
      if (choices == null || choices.isEmpty) continue;
      final delta =
          (choices.first as Map)['delta'] as Map<String, Object?>? ?? {};

      final thought = openAiReasoningOf(delta);
      if (thought.isNotEmpty) {
        clock.think();
        reasoning.write(thought);
        onReasoning(thought);
      }

      final content = delta['content'] as String?;
      if (content != null && content.isNotEmpty) {
        clock.answer();
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

    return LlmTurn(
      text: text.toString(),
      toolCalls: toolCalls,
      usage: usage,
      reasoning: reasoning.toString(),
      reasoningMs: clock.ms,
    );
  }

  /// 让**这个客户端配的模型**描述几张图，返回一段纯文本。
  ///
  /// 前置多模态的那一次调用（见 vision.dart）。三个刻意的选择：
  ///   - **不带历史**：它自带一句"请描述这张图"，那句话不该混进用户的对话。
  ///   - **不带工具**：描述任务里给工具，某些模型会转头去调 exec。
  ///   - **不流式**：调用方要的是完整的一段描述，中间态没有用处。
  ///
  /// 和 [summarize] 相反，这里**会抛**：摘要失败无非上下文长一点，
  /// 而描述失败意味着"这张图模型根本没看到"—— 静默吞掉的话，
  /// 模型会对着一条提到图却没有图的消息硬答。
  @override
  Future<String> describeImages({
    required List<String> imagePaths,
    required String prompt,
  }) async {
    if (!config.isConfigured) {
      throw StateError('视觉渠道没有配置完整（缺 baseUrl 或模型）');
    }
    final (images, failures) = await loadInlineImages(imagePaths);
    if (images.isEmpty) {
      throw ImageLoadException(
          failures.isEmpty ? '没有可用的图片' : failures.join('\n'));
    }
    final attached = images.values.toList();
    final auth = await _authValue();

    if (config.apiFormat == 'anthropic') {
      final response = await _http.post(
        _endpoint(config.baseUrl, '/messages'),
        headers: <String, String>{
          'Content-Type': 'application/json',
          'anthropic-version': '2023-06-01',
          if (auth.isNotEmpty) 'x-api-key': auth,
        },
        body: jsonEncode(<String, Object?>{
          'model': config.model,
          'max_tokens': 1024,
          'messages': <Map<String, Object?>>[
            <String, Object?>{
              'role': 'user',
              'content': anthropicContentParts(prompt, attached),
            },
          ],
        }),
      );
      _throwForStatus(response);
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      if (body is! Map<String, Object?>) return '';
      final content = body['content'] as List? ?? const [];
      return content
          .whereType<Map<String, Object?>>()
          .where((block) => block['type'] == 'text')
          .map((block) => block['text']?.toString() ?? '')
          .join()
          .trim();
    }

    final response = await _http.post(
      _endpoint(config.baseUrl, '/chat/completions'),
      headers: <String, String>{
        'Content-Type': 'application/json',
        if (auth.isNotEmpty) 'Authorization': 'Bearer $auth',
      },
      body: jsonEncode(<String, Object?>{
        'model': config.model,
        'messages': <Map<String, Object?>>[
          <String, Object?>{
            'role': 'user',
            'content': openAiContentParts(prompt, attached),
          },
        ],
      }),
    );
    _throwForStatus(response);
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map<String, Object?>) return '';
    final choices = decoded['choices'] as List?;
    if (choices == null || choices.isEmpty) return '';
    final message = (choices.first as Map)['message'] as Map<String, Object?>?;
    return (message?['content'] as String?)?.trim() ?? '';
  }

  /// 把非 2xx 变成一句能读的错误。
  ///
  /// 正文原样带上（截断）—— 视觉模型最常见的失败是「这个模型不支持图片」，
  /// 而那句话只在正文里，状态码全都是 400。
  void _throwForStatus(http.Response response) {
    if (response.statusCode < 400) return;
    final body = utf8.decode(response.bodyBytes, allowMalformed: true);
    throw LlmConnectionException(
        'HTTP ${response.statusCode} ${_brief(body.trim())}');
  }

  /// [Summarizer] 的实现，交给 [OverflowManager]。
  ///
  /// 非流式、低温度、不带工具 —— 摘要不该调用工具，带上 tools 只会诱导
  /// 某些模型在摘要任务里发起工具调用，产出一坨没法用的东西。
  /// 压缩历史用的一次性调用。
  ///
  /// **走 [complete] 那条已经分好协议的路，不自己再拼一遍请求体。**
  ///
  /// 原来这里是手写的 OpenAI 请求，只特判了 ChatGPT OAuth。于是 Anthropic、
  /// Gemini 原生、Vertex 三种渠道的摘要请求全打到了一个不存在的
  /// `/chat/completions` 上 —— 404，然后被 catch 掉返回空串。表现是
  /// 「滚动摘要一次都不生效」，而界面上没有任何迹象。
  ///
  /// 一份协议分派就够了。第二份迟早会跟不上，而它已经漏了三种。
  ///
  /// **失败会抛**（这一点也是改过的）。静默返回空串的话，[OverflowManager]
  /// 分不清「摘出来是空的」和「根本没摘成」，而它对这两件事的处置完全不同：
  /// 后者绝不能推进 checkpoint，否则那批消息被踢出窗口而没有摘要顶上 ——
  /// 上下文凭空少一截，界面上还写着"还没有触发过摘要"。
  ///
  /// 降级仍然发生，只是挪了地方：由 [OverflowManager] 接住并保留原文。
  /// 那里才分得清该怎么降级，这里只知道"请求没成功"。
  Future<String> summarize(String systemPrompt, String payload) async {
    if (!config.isConfigured) {
      throw const SummarizeException('尚未配置模型服务');
    }

    // 同一个接入点、另一个模型。**共用底层 http 客户端** —— 连接和代理都是
    // 现成的，另起一个只会多一次 TLS 握手；而且 _ownsClient 为假，
    // 这个临时客户端不会去关掉别人的连接。
    final aide = ConfigurableLlmClient(
      config: config.copyWith(
        model: config.summaryModelOrDefault,
        // 摘要要的是稳定复述，不是发挥。
        temperature: 0.1,
        streamOutput: false,
        // 载荷是纯文本。历史里的图片路径不该在这里被重新读一遍盘 ——
        // 几张手机照片就是几 MB 的 IO，读出来只为了在下一步扔掉。
        sendImagesInline: false,
        // 联网搜索会让它跑去查资料而不是复述；思考会让它为一次压缩额外
        // 烧一大截 token。两者都不该跟着主对话的设置走。
        webSearch: false,
        thinkingEffort: ThinkingEffort.auto,
      ),
      httpClient: _http,
    )
      ..bearerProvider = bearerProvider
      ..chatGptAccountIdProvider = chatGptAccountIdProvider;

    final now = DateTime.now();
    try {
      final turn = await aide.complete(
        messages: <ChatMessage>[
          ChatMessage(role: 'system', content: systemPrompt, at: now),
          ChatMessage(role: 'user', content: payload, at: now),
        ],
        tools: const <ToolSpec>[],
        onDelta: (_) {},
        // 摘要只要正文。思考丢掉 —— 它是给用户看的过程，不是摘要的素材。
        onReasoning: (_) {},
      );
      return turn.text.trim();
    } on SummarizeException {
      rethrow;
    } catch (e) {
      // 原样带上原因。这一条最终会显示给用户，而「404」和「密钥过期」
      // 要做的事完全不同 —— 换成一句"摘要失败"就等于把唯一的线索丢了。
      throw SummarizeException('$e');
    }
  }

  static Map<String, Object?> _toWire(
      ChatMessage m, Map<String, InlineImage> images) {
    final attached = _attached(m, images);
    return <String, Object?>{
      // tool 角色的消息在 OpenAI 协议里需要 tool_call_id 配对。为简化，
      // 这里统一降级成 user 消息并加前缀 —— 兼容性远好于严格配对，
      // 而且本地模型对严格的 tool 消息格式支持普遍很差。
      'role': m.role == 'tool' ? 'user' : m.role,
      // 没有图时仍然发**字符串**而不是单元素数组：不少本地推理服务
      // （llama.cpp、部分 vLLM 版本）只认字符串形式的 content，
      // 一律改成数组会把它们全打挂。
      'content': attached.isEmpty
          ? (m.role == 'tool'
              ? '[工具结果]\n${m.content}'
              : withImagePlaceholder(m.content, m.images.length))
          : openAiContentParts(m.content, attached),
    };
  }

  /// 这条消息实际带上的图。读失败的那张不在 [images] 里，自然就被跳过。
  static List<InlineImage> _attached(
          ChatMessage m, Map<String, InlineImage> images) =>
      <InlineImage>[
        for (final path in m.images)
          if (images[path] case final image?) image,
      ];

  static String _brief(String s) =>
      s.length > 300 ? '${s.substring(0, 300)}…' : s;
}

/// 压缩历史那次调用失败了。
///
/// 单独一个类型而不是复用 [LlmConnectionException]：调用方
/// （[OverflowManager]）要按"摘要没成"来降级，而不是按"网络坏了"——
/// 后者还包括地址填错、模型不认、密钥过期这些。
class SummarizeException implements Exception {
  final String message;

  const SummarizeException(this.message);

  @override
  String toString() => message;
}

class LlmConnectionException implements Exception {
  final String message;
  const LlmConnectionException(this.message);

  @override
  String toString() => message;
}

class _PartialToolCall {
  String id = '';
  String name = '';
  final StringBuffer args = StringBuffer();
}

/// 「想了多久」的秒表。
///
/// 量的是**第一段思考到第一段正文**之间的墙上时间，不是整轮耗时 ——
/// 后者还含着答案本身的生成时间和工具往返，而用户看这个数字时想知道的
/// 只有一件事：它在开口之前琢磨了多久。
///
/// 没有思考就一直是 0，UI 据此不显示。
class _ThinkClock {
  DateTime? _start;
  int _ms = 0;

  /// 收到一段思考。只有第一次有效。
  void think() => _start ??= DateTime.now();

  /// 收到一段正文 —— 思考到此为止。
  void answer() {
    final start = _start;
    if (start != null && _ms == 0) {
      _ms = DateTime.now().difference(start).inMilliseconds;
    }
  }

  /// 有的回合想完就结束了（只有工具调用、没有正文），这时收尾即结算。
  int get ms {
    answer();
    return _ms;
  }
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
