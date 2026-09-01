import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:burrow/src/agent/tools.dart';
import 'package:burrow/src/context/overflow_manager.dart';
import 'package:burrow/src/llm/llm_client.dart';
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

    test('渠道不认图时 content 退回字符串', () async {
      // 关键的一条：不认图的模型收到数组形式的 content 会 400，
      // 而更糟的是有的网关照单全收然后把图默默丢掉。
      // 这时图应该由前置多模态处理，请求体里一张图都不该有。
      final body = await sendWith(const LlmConfig(
        baseUrl: 'https://example.com/v1',
        apiKey: 'k',
        model: 'm',
        streamOutput: false,
      ));
      final message = (body['messages']! as List).first as Map<String, Object?>;
      expect(message['content'], '这是什么');
      // 整个请求体里不该出现 base64。
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
}
