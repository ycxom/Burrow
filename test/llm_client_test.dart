import 'dart:async';
import 'dart:convert';

import 'package:burrow/src/agent/tools.dart';
import 'package:burrow/src/context/overflow_manager.dart';
import 'package:burrow/src/llm/llm_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
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
