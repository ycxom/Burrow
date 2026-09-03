import 'package:burrow/src/agent/agent_loop.dart';
import 'package:burrow/src/llm/model_registry.dart';
import 'package:burrow/src/settings/channel_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TokenUsage 解析', () {
    test('OpenAI 口径，含缓存命中', () {
      final usage = TokenUsage.fromOpenAi(<String, Object?>{
        'prompt_tokens': 1240,
        'completion_tokens': 310,
        'prompt_tokens_details': <String, Object?>{'cached_tokens': 1024},
      });
      expect(usage!.input, 1240);
      expect(usage.output, 310);
      expect(usage.cached, 1024);
      expect(usage.total, 1550);
    });

    test('Anthropic 口径', () {
      final usage = TokenUsage.fromAnthropic(<String, Object?>{
        'input_tokens': 900,
        'output_tokens': 120,
        'cache_read_input_tokens': 700,
      });
      expect(usage!.input, 900);
      expect(usage.output, 120);
      expect(usage.cached, 700);
    });

    test('Responses 口径', () {
      final usage = TokenUsage.fromResponses(<String, Object?>{
        'input_tokens': 55,
        'output_tokens': 7,
        'input_tokens_details': <String, Object?>{'cached_tokens': 32},
      });
      expect(usage!.input, 55);
      expect(usage.cached, 32);
    });

    test('全零和非对象都返回 null，不返回一个 0 的 usage', () {
      // 这条很重要：返回 TokenUsage(0,0) 会在界面上显示成"这一轮没花 token"，
      // 而真相是"服务端没告诉我们"。两者必须能区分。
      expect(TokenUsage.fromOpenAi(null), isNull);
      expect(TokenUsage.fromOpenAi('nope'), isNull);
      expect(
        TokenUsage.fromOpenAi(
            <String, Object?>{'prompt_tokens': 0, 'completion_tokens': 0}),
        isNull,
      );
    });

    test('字符串数字也认', () {
      final usage = TokenUsage.fromOpenAi(
          <String, Object?>{'prompt_tokens': '42', 'completion_tokens': '8'});
      expect(usage!.input, 42);
      expect(usage.output, 8);
    });

    test('累加：工具循环里多次请求合成一轮的总账', () {
      const a = TokenUsage(input: 100, output: 20, cached: 10);
      const b = TokenUsage(input: 300, output: 45);
      final sum = a + b;
      expect(sum.input, 400);
      expect(sum.output, 65);
      expect(sum.cached, 10);
      // 加 null 是安全的 —— 有的服务只在部分请求里回报用量。
      expect((a + null).input, 100);
    });

    test('Anthropic 流式那两半能拼起来', () {
      // message_start 只给 input，message_delta 只给 output。
      final start =
          TokenUsage.fromAnthropic(<String, Object?>{'input_tokens': 800})!;
      final delta =
          TokenUsage.fromAnthropic(<String, Object?>{'output_tokens': 64})!;
      final merged = start + delta;
      expect(merged.input, 800);
      expect(merged.output, 64);
    });
  });

  group('模型能力', () {
    Channel channel({
      String model = 'gpt-4o',
      bool vision = false,
      bool tools = true,
      bool search = false,
      Map<String, ModelCapability> overrides = const {},
    }) =>
        Channel(
          id: 'c1',
          name: '测试',
          baseUrl: 'https://api.example.com/v1',
          model: model,
          visionCapable: vision,
          toolsCapable: tools,
          searchCapable: search,
          modelCapabilities: overrides,
        );

    test('没单独标过的模型吃渠道默认值', () {
      final c = channel(vision: true, tools: false);
      expect(c.capabilityOf('any-model').vision, isTrue);
      expect(c.capabilityOf('any-model').tools, isFalse);
      expect(c.hasExplicitCapability('any-model'), isFalse);
    });

    test('单独标过的模型压过默认值', () {
      final c = channel(
        vision: true,
        overrides: <String, ModelCapability>{
          'text-only': const ModelCapability(vision: false, tools: false),
        },
      );
      expect(c.capabilityOf('text-only').vision, isFalse);
      expect(c.capabilityOf('text-only').tools, isFalse);
      expect(c.hasExplicitCapability('text-only'), isTrue);
      // 别的模型不受影响。
      expect(c.capabilityOf('gpt-4o').vision, isTrue);
    });

    test('activeCapability 跟着当前模型走，不是跟着渠道', () {
      // 这条是整个改动的理由：换模型改的是 channel.model，能力必须跟着换。
      final c = channel(
        model: 'text-only',
        vision: true,
        overrides: <String, ModelCapability>{
          'text-only': const ModelCapability(vision: false),
        },
      );
      expect(c.activeCapability.vision, isFalse);
      expect(c.copyWith(model: 'gpt-4o').activeCapability.vision, isTrue);
    });

    test('老记录里缺的字段算"没表过态"，不是算 false', () {
      // 很老的版本存下来的逐模型记录只有 vision 一项（那时还没有 tools）。
      // 缺的那些应该让位给自动/默认值，而不是被当成用户显式关掉了。
      final partial =
          ModelCapability.fromJson(<String, Object?>{'vision': true});
      expect(partial.vision, isTrue);
      expect(partial.tools, isNull);
      expect(partial.search, isNull);

      // 存回去时也只写表过态的那一项，不补空值。
      expect(partial.toJson(), <String, Object?>{'vision': true});
    });

    test('优先级：手动 > 官方标注 > 渠道默认', () {
      final registry = ModelRegistry(<String, ModelMeta>{
        'gpt-4o': const ModelMeta(vision: true, tools: true),
      });
      // 渠道默认说不认图，但 models.dev 说认 —— 用户没表过态，听自动的。
      final c = channel(vision: false, tools: false);
      final auto = c.capabilityOf('gpt-4o', registry);
      expect(auto.vision, isTrue);
      expect(auto.tools, isTrue);
      expect(auto.visionFromRegistry, isTrue, reason: '要能告诉界面这一项是自动来的');

      // 用户亲手关掉之后，自动值不许再翻回去 —— 那是他为了让这个模型
      // 能用而调的，一次后台刷新不该悄悄改回来。
      final manual = channel(
        vision: false,
        tools: false,
        overrides: <String, ModelCapability>{
          'gpt-4o': const ModelCapability(vision: false),
        },
      ).capabilityOf('gpt-4o', registry);
      expect(manual.vision, isFalse);
      expect(manual.visionFromRegistry, isFalse);
      // 只手动设了 vision，tools 仍然吃自动值 —— 按单项算，不是整条冻住。
      expect(manual.tools, isTrue);
      expect(manual.toolsFromRegistry, isTrue);
    });

    test('表里没有的模型退回渠道默认值', () {
      // registry 的覆盖是有洞的（实测 gemini-2.0-flash 就不在里面），
      // 查不到必须老老实实退回默认，不能当成"不支持"。
      final c = channel(vision: true, tools: true);
      final r = c.capabilityOf('某个内网自研模型', ModelRegistry.empty());
      expect(r.vision, isTrue);
      expect(r.tools, isTrue);
      expect(r.visionFromRegistry, isFalse);
    });

    test('搜索没有自动值 —— 它不是模型属性', () {
      final registry = ModelRegistry(<String, ModelMeta>{
        'gpt-4o': const ModelMeta(vision: true, tools: true),
      });
      final c = channel(search: true);
      expect(c.capabilityOf('gpt-4o', registry).search, isTrue,
          reason: '只能来自手动或渠道默认');
    });

    test('空模型名回落默认值而不是崩', () {
      final c = channel(vision: true);
      expect(c.capabilityOf('').vision, isTrue);
      expect(c.capabilityOf(null).vision, isTrue);
    });

    test('JSON 往返', () {
      final c = channel(
        vision: true,
        tools: false,
        overrides: <String, ModelCapability>{
          'a': const ModelCapability(vision: false, tools: true),
          'b': const ModelCapability(vision: true, tools: false),
        },
      );
      final back = Channel.fromJson(c.toJson());
      expect(back.visionCapable, isTrue);
      expect(back.toolsCapable, isFalse);
      expect(back.modelCapabilities, hasLength(2));
      expect(back.capabilityOf('a').tools, isTrue);
      expect(back.capabilityOf('b').vision, isTrue);
    });

    test('老配置升级：没有 tools 字段时默认支持', () {
      // 默认 false 的话，升级上来的用户会发现终端模式集体失效，
      // 而他们什么都没改。
      final back = Channel.fromJson(<String, Object?>{
        'id': 'c1',
        'name': '旧渠道',
        'base_url': 'https://api.example.com/v1',
        'model': 'gpt-4o',
        'vision_capable': true,
      });
      expect(back.toolsCapable, isTrue);
      expect(back.visionCapable, isTrue);
      expect(back.modelCapabilities, isEmpty);
    });

    test('坏掉的 model_capabilities 被忽略而不是让渠道读不出来', () {
      final back = Channel.fromJson(<String, Object?>{
        'id': 'c1',
        'name': 'x',
        'base_url': 'u',
        'model': 'm',
        'model_capabilities': <String, Object?>{
          'good': <String, Object?>{'vision': true},
          'bad': 'not-an-object',
        },
      });
      expect(back.modelCapabilities, hasLength(1));
      expect(back.capabilityOf('good').vision, isTrue);
    });

    test('canDescribeImages 看的是专用视觉模型，不是对话模型的能力', () {
      expect(channel(vision: true).canDescribeImages, isFalse);
      expect(
        channel().copyWith(visionModel: 'qwen-vl').canDescribeImages,
        isTrue,
      );
    });
  });
}
