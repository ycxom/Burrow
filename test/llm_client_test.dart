import 'dart:async';
import 'dart:convert';

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
}
