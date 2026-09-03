import 'dart:convert';
import 'dart:io';

import 'package:burrow/src/llm/model_registry.dart';
import 'package:flutter_test/flutter_test.dart';

/// 造一份 models.dev 形状的响应。
Map<String, Object?> source(Map<String, Map<String, Object?>> byProvider) =>
    <String, Object?>{
      for (final entry in byProvider.entries)
        entry.key: <String, Object?>{'models': entry.value},
    };

Map<String, Object?> model({
  required String id,
  bool vision = false,
  bool tools = false,
  bool reasoning = false,
  int context = 0,
  int output = 0,
}) =>
    <String, Object?>{
      'id': id,
      'tool_call': tools,
      'reasoning': reasoning,
      'modalities': <String, Object?>{
        'input': <String>['text', if (vision) 'image'],
        'output': <String>['text'],
      },
      if (context > 0 || output > 0)
        'limit': <String, Object?>{'context': context, 'output': output},
    };

void main() {
  group('模型 id 归一化', () {
    test('各家网关的写法都能归到同一个 id', () {
      // OpenRouter 带厂商前缀，Gemini 的列表接口带 models/，
      // 硅基流动那边大小写还不统一 —— 不归一化的话一个都查不到。
      expect(normalizeModelId('anthropic/claude-opus-4.7'), 'claude-opus-4.7');
      expect(normalizeModelId('models/gemini-2.5-flash'), 'gemini-2.5-flash');
      expect(normalizeModelId('deepseek-ai/DeepSeek-V3'), 'deepseek-v3');
      expect(normalizeModelId('  GPT-4o  '), 'gpt-4o');
    });

    test('没有前缀的不动它', () {
      expect(normalizeModelId('gpt-4o'), 'gpt-4o');
      expect(normalizeModelId(''), '');
    });

    test('变体后缀砍掉 —— 能力和本体一样', () {
      expect(normalizeModelId('meta/llama-3:free'), 'llama-3');
    });
  });

  group('压平 models.dev', () {
    test('两级结构压成 id → 能力', () {
      final flat = flattenModelsDev(source(<String, Map<String, Object?>>{
        'openai': <String, Object?>{
          'gpt-4o':
              model(id: 'gpt-4o', vision: true, tools: true, context: 128000),
        },
      }));
      expect(flat['gpt-4o']!.vision, isTrue);
      expect(flat['gpt-4o']!.tools, isTrue);
      expect(flat['gpt-4o']!.reasoning, isFalse);
      expect(flat['gpt-4o']!.contextWindow, 128000);
    });

    test('多数说支持就是支持 —— 少数二手转售方漏标不算数', () {
      // 实测形状：三四家标了支持，一两家转售方漏标。
      final flat = flattenModelsDev(source(<String, Map<String, Object?>>{
        'openrouter': <String, Object?>{'a/m': model(id: 'a/m', vision: true)},
        'orcarouter': <String, Object?>{'a/m': model(id: 'a/m', vision: true)},
        'novita': <String, Object?>{'a/m': model(id: 'a/m', vision: true)},
        'mixlayer': <String, Object?>{'a/m': model(id: 'a/m')},
      }));
      expect(flat['m']!.vision, isTrue);
    });

    test('平票取否 —— 少报只是走降级，多报是直接 400', () {
      final flat = flattenModelsDev(source(<String, Map<String, Object?>>{
        'x': <String, Object?>{'m': model(id: 'm', vision: true)},
        'y': <String, Object?>{'m': model(id: 'm')},
      }));
      expect(flat['m']!.vision, isFalse);
    });

    test('窗口取见过的最大值', () {
      // 转售方常把窗口调小，那是它自己的限制，不是模型的能力。
      final flat = flattenModelsDev(source(<String, Map<String, Object?>>{
        'official': <String, Object?>{'m': model(id: 'm', context: 200000)},
        'reseller': <String, Object?>{'m': model(id: 'm', context: 32000)},
      }));
      expect(flat['m']!.contextWindow, 200000);
    });

    test('上游结构变了不崩，只是返回空', () {
      expect(flattenModelsDev(null), isEmpty);
      expect(flattenModelsDev('不是对象'), isEmpty);
      expect(flattenModelsDev(<String, Object?>{'x': '不是对象'}), isEmpty);
      expect(flattenModelsDev(<String, Object?>{'x': <String, Object?>{}}),
          isEmpty);
    });
  });

  group('序列化', () {
    test('存下来再读回去是同一份', () {
      final original = <String, ModelMeta>{
        'gpt-4o': const ModelMeta(
            vision: true, tools: true, contextWindow: 128000, maxOutput: 16384),
        'deepseek-v3': const ModelMeta(tools: true),
      };
      final back = decodeRegistry(encodeRegistry(original));
      expect(back, original);
    });

    test('缓存文件坏了当空的处理，不许抛', () {
      // 缓存写到一半断电是真会发生的。它坏掉的后果应该是「这次没有能力
      // 提示」，不该是启动时崩一次。
      expect(decodeRegistry('这不是 json'), isEmpty);
      expect(decodeRegistry(''), isEmpty);
      expect(decodeRegistry('[]'), isEmpty);
      expect(decodeRegistry('{"m": 3}'), isEmpty);
    });
  });

  group('查表', () {
    test('查得到 / 查不到', () {
      final registry = ModelRegistry(<String, ModelMeta>{
        'gpt-4o': const ModelMeta(vision: true, tools: true),
      });
      // 用户填的是带前缀的写法，也要查得到。
      expect(registry.lookup('openai/GPT-4o')!.vision, isTrue);
      expect(registry.lookup('gpt-4o')!.tools, isTrue);
      // 查不到就是查不到，让调用方退回渠道默认值，而不是瞎猜一个。
      expect(registry.lookup('某个内网自研模型'), isNull);
      expect(ModelRegistry.empty().lookup('gpt-4o'), isNull);
    });
  });

  group('随包快照', () {
    test('快照是有效的、覆盖到常用模型', () {
      final file = File('assets/model_registry.json');
      expect(file.existsSync(), isTrue,
          reason: '快照没生成，跑 dart run tool/generate_model_snapshot.dart');

      final registry = ModelRegistry(decodeRegistry(file.readAsStringSync()));
      expect(registry.size, greaterThan(1000));

      // 这几个是预设渠道里就有的，快照必须覆盖到，否则新用户第一次配渠道
      // 还是拿不到能力提示 —— 那就等于白带了这个文件。
      expect(registry.lookup('gpt-4o')!.vision, isTrue);
      expect(registry.lookup('gemini-2.5-flash')!.vision, isTrue);
      expect(registry.lookup('claude-sonnet-4-5')!.tools, isTrue);
      // 纯文本模型不能被标成能看图。
      expect(registry.lookup('deepseek-v3')!.vision, isFalse);
    });

    test('快照按 id 排过序 —— 否则内容没变也会产生一大坨 diff', () {
      final raw = File('assets/model_registry.json').readAsStringSync();
      final keys =
          (jsonDecode(raw) as Map).keys.map((k) => k.toString()).toList();
      expect(keys, orderedEquals(List<String>.from(keys)..sort()));
    });
  });
}
