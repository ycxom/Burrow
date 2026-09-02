import 'dart:convert';

import 'package:burrow/src/agent/agent_loop.dart' show LlmTurn;
import 'package:burrow/src/agent/tools.dart';
import 'package:burrow/src/context/overflow_manager.dart';
import 'package:burrow/src/llm/gemini_protocol.dart';
import 'package:burrow/src/llm/llm_client.dart';
import 'package:burrow/src/llm/reasoning.dart';
import 'package:burrow/src/llm/thinking_effort.dart';
import 'package:burrow/src/ui/thinking.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 跑一次完整请求，把请求体和结果一起交回来。
Future<({Map<String, Object?> body, LlmTurn turn, String streamed})> run(
  LlmConfig config,
  String responseBody,
) async {
  late http.Request captured;
  final client = ConfigurableLlmClient(
    config: config,
    httpClient: MockClient((request) async {
      captured = request;
      return http.Response.bytes(utf8.encode(responseBody), 200);
    }),
  );
  final thoughts = StringBuffer();
  final turn = await client.complete(
    messages: <ChatMessage>[
      ChatMessage(role: 'user', content: '在吗', at: DateTime(2026)),
    ],
    tools: const <ToolSpec>[],
    onDelta: (_) {},
    onReasoning: thoughts.write,
  );
  return (
    body: jsonDecode(captured.body) as Map<String, Object?>,
    turn: turn,
    streamed: thoughts.toString(),
  );
}

void main() {
  group('思考从线上取出来', () {
    test('OpenAI 兼容层认 reasoning_content 和 reasoning 两个名字', () {
      expect(
          openAiReasoningOf(<String, Object?>{'reasoning_content': '甲'}), '甲');
      expect(openAiReasoningOf(<String, Object?>{'reasoning': '乙'}), '乙');
      // 两个都在时先认 reasoning_content —— 同时给的网关是把后者当兼容别名。
      expect(
        openAiReasoningOf(<String, Object?>{
          'reasoning': '乙',
          'reasoning_content': '甲',
        }),
        '甲',
      );
      // 对象形式（部分网关的非流式响应）取里面的文本，而不是把整个 Map
      // 的 toString 显示出去。
      expect(
        openAiReasoningOf(<String, Object?>{
          'reasoning': <String, Object?>{'text': '丙'},
        }),
        '丙',
      );
      // 没有就是没有。正文字段不能被当成思考。
      expect(openAiReasoningOf(<String, Object?>{'content': '答案'}), isEmpty);
      expect(openAiReasoningOf(null), isEmpty);
      expect(openAiReasoningOf('字符串'), isEmpty);
    });

    test('流式里思考和正文各归各的，不会混进对方', () async {
      const sse = 'data: {"choices":[{"delta":{"reasoning_content":"先"}}]}\n'
          '\n'
          'data: {"choices":[{"delta":{"reasoning_content":"想想"}}]}\n'
          '\n'
          'data: {"choices":[{"delta":{"content":"答案"}}]}\n'
          '\n'
          'data: [DONE]\n';
      final result = await run(
        const LlmConfig(baseUrl: 'https://x/v1', apiKey: 'k', model: 'm'),
        sse,
      );
      expect(result.turn.reasoning, '先想想');
      expect(result.turn.text, '答案');
      // 回调也要分开喂 —— UI 就是靠这两条流决定内容进哪一块的。
      expect(result.streamed, '先想想');
    });

    test('Gemini 的 thought 分片不算正文', () {
      final chunk = parseGeminiResponse(<String, Object?>{
        'candidates': <Object?>[
          <String, Object?>{
            'content': <String, Object?>{
              'parts': <Object?>[
                <String, Object?>{'text': '让我看看', 'thought': true},
                <String, Object?>{'text': '结论是 42'},
              ],
            },
          },
        ],
      });
      expect(chunk.reasoning, '让我看看');
      expect(chunk.text, '结论是 42');
    });

    test('Anthropic 的 thinking_delta 收得到', () async {
      const sse = 'data: {"type":"content_block_delta","index":0,'
          '"delta":{"type":"thinking_delta","thinking":"嗯"}}\n'
          '\n'
          'data: {"type":"content_block_delta","index":0,'
          '"delta":{"type":"text_delta","text":"好的"}}\n';
      final result = await run(
        const LlmConfig(
          apiFormat: 'anthropic',
          baseUrl: 'https://x',
          apiKey: 'k',
          model: 'm',
        ),
        sse,
      );
      expect(result.turn.reasoning, '嗯');
      expect(result.turn.text, '好的');
    });

    test('想了多久量的是"开口之前"，不含答案的生成时间', () async {
      // 思考和正文之间隔一拍，秒表应该只走这一段。
      const sse = 'data: {"choices":[{"delta":{"reasoning_content":"唔"}}]}\n'
          '\n'
          'data: {"choices":[{"delta":{"content":"答"}}]}\n';
      final result = await run(
        const LlmConfig(baseUrl: 'https://x/v1', apiKey: 'k', model: 'm'),
        sse,
      );
      expect(result.turn.reasoningMs, greaterThanOrEqualTo(0));

      // 完全没有思考时不能报一个时长出来 —— UI 会照着它画一块本不该有的区域。
      const plain = 'data: {"choices":[{"delta":{"content":"答"}}]}\n';
      final none = await run(
        const LlmConfig(baseUrl: 'https://x/v1', apiKey: 'k', model: 'm'),
        plain,
      );
      expect(none.turn.reasoning, isEmpty);
      expect(none.turn.reasoningMs, 0);
    });
  });

  group('thinkingConfig 只发给认得它的模型', () {
    test('按代次判断', () {
      expect(geminiSupportsThoughts('gemini-2.5-flash'), isTrue);
      expect(geminiSupportsThoughts('gemini-3-pro-preview'), isTrue);
      expect(geminiSupportsThoughts('gemini-4-whatever'), isTrue);
      // 2.0 和更老收到这个字段会 400，把整轮对话弄失败。
      expect(geminiSupportsThoughts('gemini-2.0-flash'), isFalse);
      expect(geminiSupportsThoughts('gemini-1.5-pro'), isFalse);
      expect(geminiSupportsThoughts(''), isFalse);
    });

    test('请求体里跟着这个判断走', () async {
      const empty = 'data: {"candidates":[]}\n';
      final newer = await run(
        const LlmConfig(
          apiFormat: 'geminiNative',
          baseUrl: 'https://x/v1beta',
          apiKey: 'k',
          model: 'gemini-2.5-flash',
        ),
        empty,
      );
      final config = newer.body['generationConfig']! as Map<String, Object?>;
      expect(config['thinkingConfig'], containsPair('includeThoughts', true));

      final older = await run(
        const LlmConfig(
          apiFormat: 'geminiNative',
          baseUrl: 'https://x/v1beta',
          apiKey: 'k',
          model: 'gemini-2.0-flash',
        ),
        empty,
      );
      final oldConfig = older.body['generationConfig']! as Map<String, Object?>;
      expect(oldConfig.containsKey('thinkingConfig'), isFalse);
    });
  });

  group('思考强度翻译成各家的写法', () {
    const empty = 'data: {"candidates":[]}\n';
    const plain = 'data: {"choices":[{"delta":{"content":"答"}}]}\n';

    test('自动档一个字段都不发', () async {
      final openAi = await run(
        const LlmConfig(baseUrl: 'https://x/v1', apiKey: 'k', model: 'm'),
        plain,
      );
      expect(openAi.body.containsKey('reasoning_effort'), isFalse);

      // Gemini 那边 includeThoughts 仍然要发 —— 那是"把想的发回来"，
      // 和"想多久"是两件事。
      final gemini = await run(
        const LlmConfig(
          apiFormat: 'geminiNative',
          baseUrl: 'https://x/v1beta',
          apiKey: 'k',
          model: 'gemini-2.5-flash',
        ),
        empty,
      );
      final config = (gemini.body['generationConfig']! as Map)['thinkingConfig']
          as Map<String, Object?>;
      expect(config['includeThoughts'], isTrue);
      expect(config.containsKey('thinkingBudget'), isFalse);

      final claude = await run(
        const LlmConfig(
          apiFormat: 'anthropic',
          baseUrl: 'https://x',
          apiKey: 'k',
          model: 'm',
        ),
        'data: {}\n',
      );
      expect(claude.body.containsKey('thinking'), isFalse);
      // 没开思考时 temperature 照常发。
      expect(claude.body.containsKey('temperature'), isTrue);
    });

    test('OpenAI 系是字符串档位', () async {
      final body = (await run(
        const LlmConfig(
          baseUrl: 'https://x/v1',
          apiKey: 'k',
          model: 'm',
          thinkingEffort: ThinkingEffort.high,
        ),
        plain,
      ))
          .body;
      expect(body['reasoning_effort'], 'high');
      // 「关闭」发 minimal 而不是 none —— 后者只有新模型认得。
      expect(ThinkingEffort.off.openAiEffort, 'minimal');
    });

    test('Gemini 2.5 是 token 预算，3 是两档的 level', () {
      final flash =
          geminiThinkingConfig('gemini-2.5-flash', ThinkingEffort.medium);
      expect(flash['thinkingBudget'], 8192);
      expect(flash.containsKey('thinkingLevel'), isFalse);

      // Pro 关不掉思考，最低 128 —— 发 0 会 400。
      expect(
        geminiThinkingConfig(
            'gemini-2.5-pro', ThinkingEffort.off)['thinkingBudget'],
        128,
      );
      expect(
        geminiThinkingConfig(
            'gemini-2.5-flash', ThinkingEffort.off)['thinkingBudget'],
        0,
      );

      final three =
          geminiThinkingConfig('gemini-3-pro-preview', ThinkingEffort.high);
      expect(three['thinkingLevel'], 'high');
      expect(three.containsKey('thinkingBudget'), isFalse);
      expect(
        geminiThinkingConfig(
            'gemini-3-pro-preview', ThinkingEffort.low)['thinkingLevel'],
        'low',
      );
    });

    test('Anthropic 开思考时要腾出 max_tokens，并且不能再送 temperature', () async {
      final body = (await run(
        const LlmConfig(
          apiFormat: 'anthropic',
          baseUrl: 'https://x',
          apiKey: 'k',
          model: 'm',
          thinkingEffort: ThinkingEffort.medium,
        ),
        'data: {}\n',
      ))
          .body;
      final thinking = body['thinking']! as Map<String, Object?>;
      expect(thinking['type'], 'enabled');
      expect(thinking['budget_tokens'], 4096);
      // max_tokens 必须比预算大，否则服务端直接拒。
      expect(body['max_tokens'] as int, greaterThan(4096));
      // temperature 必须是 1，送别的值会 400 —— 干脆整个不送。
      expect(body.containsKey('temperature'), isFalse);
    });

    test('"这个模型不认思考强度"要能认出来', () {
      expect(
        isThinkingEffortRejected(
            '{"error":{"message":"Unsupported parameter: reasoning_effort"}}'),
        isTrue,
      );
      expect(
        isThinkingEffortRejected('{"error":{"message":"thinking is not '
            'supported by this model"}}'),
        isTrue,
      );
      // 别的错误不能被当成这一类，否则真正的原因会被一句无关的提示盖掉。
      expect(isThinkingEffortRejected('{"error":{"code":429}}'), isFalse);
      expect(
        isThinkingEffortRejected('{"error":{"message":"invalid api key"}}'),
        isFalse,
      );
    });
  });

  group('折叠那一行显示什么', () {
    test('想的时候看最后一行，想完看第一行', () {
      const text = '第一步：读题\n第二步：算\n第三步：验算';
      expect(thinkingPreview(text, true), '第三步：验算');
      expect(thinkingPreview(text, false), '第一步：读题');
      // 只有一行时两种状态是同一句。
      expect(thinkingPreview('就一句', true), '就一句');
      expect(thinkingPreview('就一句', false), '就一句');
      expect(thinkingPreview('   \n  ', true), isEmpty);
      expect(thinkingPreview('', false), isEmpty);
    });

    test('时长的写法', () {
      expect(formatThinkDuration(3200), '3.2s');
      expect(formatThinkDuration(59900), '59.9s');
      expect(formatThinkDuration(60000), '1m');
      expect(formatThinkDuration(65000), '1m 5s');
      // 一秒以内的调用方本来就不显示，但它也不该崩。
      expect(formatThinkDuration(0), '0.0s');
    });
  });
}
