/// 极客设置：那几个采样参数到底发没发出去、发成什么样。
///
/// 这一组钉的核心是一条**否定**的性质：**没设过的项，请求体里一个字段都
/// 不该多**。这些字段各家支持得参差不齐 —— `top_k` 在 OpenAI 兼容层不存在，
/// `frequency_penalty` 送给 Anthropic 会 400 —— 而多发一个字段的后果不是
/// 被忽略，是整轮请求失败。所以"空配置的请求体和加这个功能之前逐字相同"
/// 得有测试盯着，光靠读代码看不出来漏没漏。
library;

import 'dart:convert';

import 'package:burrow/src/agent/tools.dart';
import 'package:burrow/src/context/overflow_manager.dart';
import 'package:burrow/src/llm/llm_client.dart';
import 'package:burrow/src/llm/sampling.dart';
import 'package:burrow/src/llm/thinking_effort.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _full = SamplingParams(
  topP: 0.85,
  topK: 40,
  maxTokens: 2048,
  frequencyPenalty: 0.4,
  presencePenalty: -0.2,
  seed: 42,
  stopSequences: <String>['\n\n', 'END'],
);

/// 把一轮请求发出去，把请求体接下来。
Future<Map<String, Object?>> bodyOf(LlmConfig config) async {
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
          'candidates': <Object?>[
            <String, Object?>{
              'content': <String, Object?>{
                'parts': <Object?>[
                  <String, Object?>{'text': '好'},
                ],
              },
            },
          ],
        })),
        200,
      );
    }),
  );
  await client.complete(
    messages: <ChatMessage>[
      ChatMessage(role: 'user', content: '在吗', at: DateTime(2026)),
    ],
    tools: const <ToolSpec>[],
    onDelta: (_) {},
  );
  return jsonDecode(captured.body) as Map<String, Object?>;
}

void main() {
  group('线格式', () {
    test('一项都没设时，四种协议的字段全是空的', () {
      const none = SamplingParams.none;
      expect(none.openAiFields(), isEmpty);
      expect(none.anthropicFields(), isEmpty);
      expect(none.geminiFields(), isEmpty);
      expect(none.responsesFields(), isEmpty);
    });

    test('OpenAI：没有 top_k', () {
      // 那个字段在 /chat/completions 上根本不存在，严格的网关会因此 400。
      expect(_full.openAiFields(), <String, Object?>{
        'top_p': 0.85,
        'max_tokens': 2048,
        'frequency_penalty': 0.4,
        'presence_penalty': -0.2,
        'seed': 42,
        'stop': <String>['\n\n', 'END'],
      });
    });

    test('Anthropic：只有它认的那三项，而且不含 max_tokens', () {
      // max_tokens 在那边是必填的，还要和思考预算一起算 —— 由
      // anthropicMaxTokens 单独管，混进这里会被算两次。
      expect(_full.anthropicFields(), <String, Object?>{
        'top_p': 0.85,
        'top_k': 40,
        'stop_sequences': <String>['\n\n', 'END'],
      });
    });

    test('Gemini：驼峰命名，且都在 generationConfig 里那一层', () {
      expect(_full.geminiFields(), <String, Object?>{
        'topP': 0.85,
        'topK': 40,
        'maxOutputTokens': 2048,
        'frequencyPenalty': 0.4,
        'presencePenalty': -0.2,
        'seed': 42,
        'stopSequences': <String>['\n\n', 'END'],
      });
    });

    test('Responses：Codex 后端只收这两个', () {
      expect(_full.responsesFields(), <String, Object?>{
        'top_p': 0.85,
        'max_output_tokens': 2048,
      });
    });
  });

  group('Anthropic 的 max_tokens', () {
    test('没开思考时就是用户设的那个数', () {
      expect(
        const SamplingParams(maxTokens: 1000).anthropicMaxTokens(),
        1000,
      );
    });

    test('没设过时给一个能用的兜底 —— 那边这一项是必填的', () {
      expect(SamplingParams.none.anthropicMaxTokens(), 4096);
    });

    test('开了思考时不能小于「思考预算 + 答案余量」', () {
      // max_tokens ≤ budget_tokens 会被直接 400，而那句报错的字面意思
      // 和用户刚调的「输出上限」对不上，没人猜得到是这里。
      expect(
        const SamplingParams(maxTokens: 500)
            .anthropicMaxTokens(thinkingMaxTokens: 9216),
        9216,
      );
    });

    test('用户要得比思考那份还多时，听用户的', () {
      expect(
        const SamplingParams(maxTokens: 60000)
            .anthropicMaxTokens(thinkingMaxTokens: 9216),
        60000,
      );
    });
  });

  group('哪个协议认哪些', () {
    test('OpenAI 兼容层不认 top_k', () {
      expect(knobsFor('openAI'), isNot(contains(SamplingKnob.topK)));
    });

    test('Anthropic 不认惩罚和 seed', () {
      final knobs = knobsFor('anthropic');
      expect(knobs, contains(SamplingKnob.topK));
      expect(knobs, isNot(contains(SamplingKnob.frequencyPenalty)));
      expect(knobs, isNot(contains(SamplingKnob.seed)));
    });

    test('Gemini 全认', () {
      expect(knobsFor('gemini'), SamplingKnob.values.toSet());
    });

    test('认不出来的协议按 OpenAI 兼容算', () {
      expect(knobsFor('某个自建网关'), knobsFor('openAI'));
    });

    test('设了但发不出去的那几项报得出来 —— 界面靠它提示', () {
      // 静默忽略是最糟的：用户会以为自己调了，然后把后面所有变化都归到
      // 这一项头上。
      expect(_full.ignoredBy('openAI'), <SamplingKnob>{SamplingKnob.topK});
      expect(
        _full.ignoredBy('anthropic'),
        <SamplingKnob>{
          SamplingKnob.frequencyPenalty,
          SamplingKnob.presencePenalty,
          SamplingKnob.seed,
        },
      );
      expect(_full.ignoredBy('gemini'), isEmpty);
    });

    test('没设过的项不算"被忽略"', () {
      expect(SamplingParams.none.ignoredBy('anthropic'), isEmpty);
    });
  });

  group('清回默认', () {
    test('clear 能把一项设回 null，copyWith 做不到', () {
      // copyWith 的 `??` 把"传了 null"和"没传"当成一回事，
      // 而"恢复默认"要的恰恰是前者。
      const params = SamplingParams(topP: 0.5, seed: 7);
      expect(params.copyWith(topP: null).topP, 0.5);
      expect(params.clear(SamplingKnob.topP).topP, isNull);
      expect(params.clear(SamplingKnob.topP).seed, 7);
    });

    test('清停止词清成空表', () {
      const params = SamplingParams(stopSequences: <String>['x']);
      expect(params.clear(SamplingKnob.stopSequences).stopSequences, isEmpty);
      expect(params.clear(SamplingKnob.stopSequences).isEmpty, isTrue);
    });
  });

  group('存盘', () {
    test('设过的原样回来', () {
      expect(SamplingParams.fromJson(_full.toJson()), _full);
    });

    test('没设过的字段不写进 JSON', () {
      expect(SamplingParams.none.toJson(), isEmpty);
      expect(const SamplingParams(seed: 1).toJson().keys, <String>['seed']);
    });

    test('整数经过 JSON 变成 double 也认得回来', () {
      // jsonEncode/decode 之后 2048 有可能回来是 2048.0，按 num 收。
      final params = SamplingParams.fromJson(<String, Object?>{
        'max_tokens': 2048.0,
        'top_k': 40.0,
      });
      expect(params.maxTokens, 2048);
      expect(params.topK, 40);
    });

    test('坏掉的值当成没设过', () {
      final params = SamplingParams.fromJson(<String, Object?>{
        'top_p': '高一点',
        'stop': 'END',
      });
      expect(params.isEmpty, isTrue);
    });

    test('停止词里的空串会被扔掉', () {
      // 空串当停止词会让模型第一个 token 就停 —— 表现为"回答永远是空的"。
      final params = SamplingParams.fromJson(<String, Object?>{
        'stop': <Object?>['', 'END', 3],
      });
      expect(params.stopSequences, <String>['END']);
    });

    test('整个字段不是 Map 时给一份空的', () {
      expect(SamplingParams.fromJson(null), SamplingParams.none);
      expect(SamplingParams.fromJson('坏了'), SamplingParams.none);
    });
  });

  group('真的发出去了', () {
    test('OpenAI 请求体里带上了这几项', () async {
      final body = await bodyOf(const LlmConfig(
        baseUrl: 'https://example.com/v1',
        apiKey: 'k',
        model: 'gpt-4o',
        streamOutput: false,
        sampling: _full,
      ));
      expect(body['top_p'], 0.85);
      expect(body['max_tokens'], 2048);
      expect(body['seed'], 42);
      expect(body['stop'], <String>['\n\n', 'END']);
      // 这一项发过去会被严格的网关拒掉。
      expect(body.containsKey('top_k'), isFalse);
    });

    test('一项都没设时，请求体和以前逐字相同', () async {
      final before = await bodyOf(const LlmConfig(
        baseUrl: 'https://example.com/v1',
        apiKey: 'k',
        model: 'gpt-4o',
        streamOutput: false,
      ));
      for (final knob in SamplingKnob.values) {
        expect(before.containsKey(knob.wire), isFalse,
            reason: '没设过却发了 ${knob.wire}');
      }
      expect(before.containsKey('max_completion_tokens'), isFalse);
    });

    test('Anthropic 请求体：max_tokens 用用户那个数，惩罚一项都不带', () async {
      final body = await bodyOf(const LlmConfig(
        apiFormat: 'anthropic',
        baseUrl: 'https://example.com/v1',
        apiKey: 'k',
        model: 'claude-sonnet-4',
        streamOutput: false,
        sampling: _full,
      ));
      expect(body['max_tokens'], 2048);
      expect(body['top_p'], 0.85);
      expect(body['top_k'], 40);
      expect(body['stop_sequences'], <String>['\n\n', 'END']);
      expect(body.containsKey('frequency_penalty'), isFalse);
      expect(body.containsKey('seed'), isFalse);
    });

    test('Anthropic 开了思考：输出上限只管答案，思考预算另加', () async {
      final body = await bodyOf(const LlmConfig(
        apiFormat: 'anthropic',
        baseUrl: 'https://example.com/v1',
        apiKey: 'k',
        model: 'claude-sonnet-4',
        streamOutput: false,
        thinkingEffort: ThinkingEffort.high,
        sampling: SamplingParams(maxTokens: 2048),
      ));
      final budget =
          (body['thinking'] as Map<String, Object?>)['budget_tokens'] as int;
      // 直接拿 2048 去填的话，模型会把额度全烧在思考上，答案被截在半句。
      expect(body['max_tokens'], budget + 2048);
    });

    test('Anthropic 没设输出上限时还是老样子', () async {
      final body = await bodyOf(const LlmConfig(
        apiFormat: 'anthropic',
        baseUrl: 'https://example.com/v1',
        apiKey: 'k',
        model: 'claude-sonnet-4',
        streamOutput: false,
      ));
      expect(body['max_tokens'], 4096);
    });

    test('Gemini 原生：这几项在 generationConfig 里', () async {
      final body = await bodyOf(const LlmConfig(
        apiFormat: 'geminiNative',
        baseUrl: 'https://example.com/v1beta',
        apiKey: 'k',
        model: 'gemini-2.5-flash',
        streamOutput: false,
        sampling: _full,
      ));
      final generation = body['generationConfig'] as Map<String, Object?>;
      expect(generation['topP'], 0.85);
      expect(generation['topK'], 40);
      expect(generation['maxOutputTokens'], 2048);
      expect(generation['stopSequences'], <String>['\n\n', 'END']);
      // temperature 还在原地，没被挤掉。
      expect(generation.containsKey('temperature'), isTrue);
    });
  });
}
