import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:burrow/src/agent/tools.dart';
import 'package:burrow/src/context/overflow_manager.dart';
import 'package:burrow/src/llm/llm_client.dart';
import 'package:burrow/src/llm/model_catalog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 最小的合法 PNG 头。只用来让 sniffMediaType 认出类型。
final _png = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00];

void main() {
  group('图片进请求体', () {
    late Directory tmp;
    late String image;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('burrow_llm_img');
      final file = File('${tmp.path}/a.png');
      await file.writeAsBytes(_png);
      image = file.path;
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    Future<Map<String, Object?>> sendWith(LlmConfig config) async {
      late http.Request captured;
      final client = ConfigurableLlmClient(
        config: config,
        httpClient: MockClient((request) async {
          captured = request;
          return http.Response.bytes(
            utf8.encode(jsonEncode(<String, Object?>{
              'choices': <Object?>[
                <String, Object?>{
                  'message': <String, Object?>{'content': '好'},
                },
              ],
              'content': <Object?>[
                <String, Object?>{'type': 'text', 'text': '好'},
              ],
            })),
            200,
          );
        }),
      );
      await client.complete(
        messages: <ChatMessage>[
          ChatMessage(
            role: 'user',
            content: '这是什么',
            at: DateTime(2026),
            images: <String>[image],
          ),
        ],
        tools: const <ToolSpec>[],
        onDelta: (_) {},
      );
      return jsonDecode(captured.body) as Map<String, Object?>;
    }

    test('渠道认图时图片进 content 数组', () async {
      final body = await sendWith(const LlmConfig(
        baseUrl: 'https://example.com/v1',
        apiKey: 'k',
        model: 'm',
        streamOutput: false,
        sendImagesInline: true,
      ));
      final parts = (body['messages']! as List).first as Map<String, Object?>;
      final content = parts['content']! as List;
      expect(content.first, containsPair('type', 'image_url'));
      expect(content.last, containsPair('text', '这是什么'));
    });

    test('渠道不认图时退回字符串，并留一句占位说明', () async {
      // 不认图的模型收到数组形式的 content 会 400，所以必须退回字符串。
      // 但**不能什么都不留**：历史里那句「这张图里写了什么」旁边如果空无
      // 一物，模型只会开始编。留个占位它至少知道这里本来有张图。
      final body = await sendWith(const LlmConfig(
        baseUrl: 'https://example.com/v1',
        apiKey: 'k',
        model: 'm',
        streamOutput: false,
      ));
      final message = (body['messages']! as List).first as Map<String, Object?>;
      final content = message['content']! as String;
      expect(content, contains('这是什么'));
      expect(content, contains('图片'));
      // 图本身一个字节都不该发出去。
      expect(jsonEncode(body), isNot(contains('base64')));
    });

    test('Anthropic 用 source/base64 而不是 image_url', () async {
      final body = await sendWith(const LlmConfig(
        apiFormat: 'anthropic',
        baseUrl: 'https://example.com',
        apiKey: 'k',
        model: 'm',
        streamOutput: false,
        sendImagesInline: true,
      ));
      final message = (body['messages']! as List).first as Map<String, Object?>;
      final content = message['content']! as List;
      final first = content.first as Map<String, Object?>;
      expect(first['type'], 'image');
      expect((first['source']! as Map)['media_type'], 'image/png');
    });

    test('没有图的消息仍然发字符串 content', () async {
      // 不少本地推理服务只认字符串形式的 content，
      // 一律改成数组会把它们全打挂。
      late http.Request captured;
      final client = ConfigurableLlmClient(
        config: const LlmConfig(
          baseUrl: 'https://example.com/v1',
          apiKey: 'k',
          model: 'm',
          streamOutput: false,
          sendImagesInline: true,
        ),
        httpClient: MockClient((request) async {
          captured = request;
          return http.Response.bytes(
            utf8.encode('{"choices":[{"message":{"content":"好"}}]}'),
            200,
          );
        }),
      );
      await client.complete(
        messages: <ChatMessage>[
          ChatMessage(role: 'user', content: '你好', at: DateTime(2026)),
        ],
        tools: const <ToolSpec>[],
        onDelta: (_) {},
      );
      final body = jsonDecode(captured.body) as Map<String, Object?>;
      final message = (body['messages']! as List).first as Map<String, Object?>;
      expect(message['content'], '你好');
    });
  });

  test('连接测试接受完整接口地址且不重复追加路径', () async {
    late http.Request captured;
    final client = ConfigurableLlmClient(
      httpClient: MockClient((request) async {
        captured = request;
        return http.Response('{}', 200);
      }),
    );

    await client.testConnection(const LlmConfig(
      baseUrl: 'https://example.com/v1/chat/completions',
      apiKey: 'test',
      model: 'model',
    ));

    expect(captured.url.toString(), 'https://example.com/v1/chat/completions');
    final body = jsonDecode(captured.body) as Map<String, Object?>;
    expect(body['max_tokens'], 1);
    expect(body['stream'], false);
  });

  test('连接超时会转成可读提示', () async {
    final client = ConfigurableLlmClient(
      connectionTimeout: const Duration(milliseconds: 10),
      httpClient: MockClient((_) async {
        await Completer<void>().future;
        return http.Response('{}', 200);
      }),
    );

    await expectLater(
      client.testConnection(const LlmConfig(
        baseUrl: 'https://example.com/v1',
        apiKey: '',
        model: 'model',
      )),
      throwsA(isA<LlmConnectionException>()
          .having((error) => error.message, 'message', contains('连接超时'))),
    );
  });

  test('ChatGPT OAuth 连接测试走 Codex Responses 端点', () async {
    late http.Request captured;
    final client = ConfigurableLlmClient(
      httpClient: MockClient((request) async {
        captured = request;
        return http.Response('data: [DONE]\n\n', 200);
      }),
    )..chatGptAccountIdProvider = () async => 'acct_123';

    await client.testConnection(const LlmConfig(
      apiFormat: 'chatgptOAuth',
      baseUrl: 'https://chatgpt.com/backend-api/codex',
      apiKey: 'oauth-token',
      model: 'gpt-codex-test',
    ));

    expect(captured.url.toString(),
        'https://chatgpt.com/backend-api/codex/responses');
    expect(captured.headers['authorization'], 'Bearer oauth-token');
    expect(captured.headers['chatgpt-account-id'], 'acct_123');
    expect(captured.headers['originator'], 'codex_cli_rs');
    final body = jsonDecode(captured.body) as Map<String, Object?>;
    expect(body['input'], isA<List>());
    expect(body['messages'], isNull);
    expect(body['stream'], isTrue);
    expect(body['store'], isFalse);
  });

  test('ChatGPT OAuth 实际对话解析 Responses 文本和工具流', () async {
    late http.Request captured;
    final sse = [
      'data: {"type":"response.output_text.delta","delta":"你好"}',
      'data: {"type":"response.output_item.added","item":'
          '{"type":"function_call","id":"item_1","call_id":"call_1",'
          '"name":"read_file"}}',
      'data: {"type":"response.function_call_arguments.delta",'
          '"item_id":"item_1","delta":"{\\"path\\":\\"a.txt\\"}"}',
      'data: [DONE]',
      '',
    ].join('\n\n');
    final client = ConfigurableLlmClient(
      config: const LlmConfig(
        apiFormat: 'chatgptOAuth',
        baseUrl: 'https://chatgpt.com/backend-api/codex',
        apiKey: '',
        model: 'gpt-codex-test',
      ),
      httpClient: MockClient((request) async {
        captured = request;
        return http.Response.bytes(utf8.encode(sse), 200);
      }),
    );
    client.bearerProvider = () async => 'fresh-token';
    client.chatGptAccountIdProvider = () async => 'acct_123';
    final deltas = StringBuffer();

    final turn = await client.complete(
      messages: [
        ChatMessage(role: 'system', content: '指令', at: DateTime(2026)),
        ChatMessage(role: 'user', content: '开始', at: DateTime(2026)),
      ],
      tools: const [
        ToolSpec('read_file', '读文件', {
          'type': 'object',
          'properties': <String, Object?>{},
        }),
      ],
      onDelta: deltas.write,
    );

    expect(captured.url.path, '/backend-api/codex/responses');
    expect(captured.headers['authorization'], 'Bearer fresh-token');
    expect(deltas.toString(), '你好');
    expect(turn.text, '你好');
    expect(turn.toolCalls.single.name, 'read_file');
    expect(turn.toolCalls.single.args['path'], 'a.txt');
    final body = jsonDecode(captured.body) as Map<String, Object?>;
    expect(body['instructions'], '指令');
    expect((body['tools'] as List).first, containsPair('name', 'read_file'));
  });

  group('Gemini 地址拼装', () {
    test('v1beta 是版本段 —— 不能再补 /v1', () {
      // 只认 v+纯数字的话，.../v1beta 会被判成"没有版本段"，
      // 于是拼出 .../v1beta/v1/models，404。
      expect(endsWithVersionSegment('https://x.com/v1beta'), isTrue);
      expect(endsWithVersionSegment('https://x.com/v2alpha'), isTrue);
      expect(endsWithVersionSegment('https://x.com/v1'), isTrue);
      expect(endsWithVersionSegment('https://x.com/v4'), isTrue);
      // v 后面第一个字符必须是数字，否则 /video 这种会被误判。
      expect(endsWithVersionSegment('https://x.com/video'), isFalse);
      expect(endsWithVersionSegment('https://x.com/openai'), isFalse);
    });

    test('/openai 兼容层本身就是 API 根', () {
      expect(looksLikeApiRoot(geminiOpenAiBaseUrl), isTrue);
      expect(
        resolveApiEndpoint(geminiOpenAiBaseUrl, '/chat/completions').toString(),
        'https://generativelanguage.googleapis.com/v1beta/openai'
        '/chat/completions',
      );
      expect(
        buildModelsUrlCandidates(geminiOpenAiBaseUrl).first,
        'https://generativelanguage.googleapis.com/v1beta/openai/models',
      );
    });

    test('三种写错的 Gemini 地址都能被纠正', () {
      // 每一种的失败方式都不一样，而 401 会把人引到"是不是密钥不对"上去 ——
      // 那是条死路，密钥是好的。所以三种都要认出来。
      const wrong = <String>[
        // 从 Google 文档复制的原生端点 → 404
        'https://generativelanguage.googleapis.com'
            '/v1beta/models/gemini-flash-latest:generateContent',
        // 裸主机名 → 拼成 /v1/models，原生列表端点不认 Bearer → 401
        'https://generativelanguage.googleapis.com',
        // 只到 v1beta → 同上，401
        'https://generativelanguage.googleapis.com/v1beta',
        // 末尾带斜杠也要认
        'https://generativelanguage.googleapis.com/v1beta/',
      ];
      for (final url in wrong) {
        expect(geminiBaseUrlFix(url), geminiOpenAiBaseUrl, reason: url);
      }
    });

    test('已经对了的地址不再改', () {
      expect(geminiBaseUrlFix(geminiOpenAiBaseUrl), isNull);
      expect(geminiBaseUrlFix('$geminiOpenAiBaseUrl/'), isNull);
    });

    test('拉模型列表时直接说该填什么，不去猜路径', () {
      expect(
        () => buildModelsUrlCandidates(
            'https://generativelanguage.googleapis.com'),
        throwsA(
          isA<ModelFetchException>().having(
            (e) => e.toString(),
            'message',
            contains(geminiOpenAiBaseUrl),
          ),
        ),
      );
      // 地址对了就正常走，不该被拦。
      expect(
        buildModelsUrlCandidates(geminiOpenAiBaseUrl).first,
        '$geminiOpenAiBaseUrl/models',
      );
    });

    test('别家的地址不受影响', () {
      expect(geminiBaseUrlFix('https://api.openai.com/v1'), isNull);
      expect(geminiBaseUrlFix('http://192.168.1.2:3000'), isNull);
      expect(
        resolveApiEndpoint('https://api.deepseek.com', '/chat/completions')
            .toString(),
        'https://api.deepseek.com/v1/chat/completions',
      );
      expect(
        resolveApiEndpoint('https://open.bigmodel.cn/api/paas/v4',
                '/chat/completions')
            .toString(),
        'https://open.bigmodel.cn/api/paas/v4/chat/completions',
      );
    });

    test('两层 Gemini 各有各的根，切协议时跟着换', () {
      // 原生层：任何写法都收敛到 /v1beta。
      for (final url in <String>[
        'https://generativelanguage.googleapis.com',
        'https://generativelanguage.googleapis.com/v1beta/openai',
        'https://generativelanguage.googleapis.com'
            '/v1beta/models/gemini-flash-latest:generateContent',
      ]) {
        expect(
          geminiBaseUrlFix(url, apiFormat: 'geminiNative'),
          geminiNativeBaseUrl,
          reason: url,
        );
      }
      expect(
        geminiBaseUrlFix(geminiNativeBaseUrl, apiFormat: 'geminiNative'),
        isNull,
      );

      // 反过来：原生层的地址配上兼容层协议，也要被拨回去。
      expect(
        geminiBaseUrlFix(geminiNativeBaseUrl, apiFormat: 'openAI'),
        geminiOpenAiBaseUrl,
      );
    });

    test('原生层的认证头不是 Bearer', () {
      // 拿错头的表现是 401 —— 而 401 看起来就是"密钥不对"，会让人去换密钥。
      expect(
        geminiAuthHeaders('k', apiFormat: 'geminiNative'),
        <String, String>{'x-goog-api-key': 'k'},
      );
      expect(
        geminiAuthHeaders('k'),
        <String, String>{'Authorization': 'Bearer k'},
      );
      expect(geminiAuthHeaders('', apiFormat: 'geminiNative'), isEmpty);
    });

    test('原生层的模型列表只有一个端点，不去猜第二个', () {
      expect(
        buildModelsUrlCandidates(geminiNativeBaseUrl,
            apiFormat: 'geminiNative'),
        <String>['$geminiNativeBaseUrl/models'],
      );
    });

    test('原生层的模型 id 要去掉 models/ 前缀', () {
      // 带着前缀发出去会拼成 /models/models/xxx:streamGenerateContent → 404。
      final models = parseModelsResponse(
        '{"models":[{"name":"models/gemini-2.5-pro"},'
        '{"name":"models/gemini-flash-latest"}]}',
      );
      expect(models.map((m) => m.id).toList(),
          <String>['gemini-2.5-pro', 'gemini-flash-latest']);
    });
  });
}
