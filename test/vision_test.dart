/// 图片：认类型、拼协议块、前置多模态的挑选与容灾。
///
/// 这一块的失败方式大多**不是异常**：类型认错了模型看到花屏、
/// 挑候选挑错了钱花在别人身上、图没送到模型却照常答一段。
/// 全都得在这里钉死。
library;

import 'dart:convert';
import 'dart:io';

import 'package:burrow/src/llm/image_parts.dart';
import 'package:burrow/src/llm/llm_client.dart';
import 'package:burrow/src/llm/vision.dart';
import 'package:flutter_test/flutter_test.dart';

/// 四种格式各自最小的合法文件头。后面接什么无所谓 —— 我们只认头。
final _jpeg = <int>[0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10];
final _png = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00];
final _gif = <int>[0x47, 0x49, 0x46, 0x38, 0x39, 0x61];
final _webp = <int>[
  0x52, 0x49, 0x46, 0x46, // RIFF
  0x00, 0x00, 0x00, 0x00, // size
  0x57, 0x45, 0x42, 0x50, // WEBP
];

class _FakeDescriber implements ImageDescriber {
  _FakeDescriber(this.label, this.behaviour);

  final String label;

  /// 返回描述，或者抛。
  final Future<String> Function() behaviour;

  static final List<String> used = <String>[];
  static final List<String> cancelled = <String>[];

  @override
  Future<String> describeImages({
    required List<String> imagePaths,
    required String prompt,
  }) {
    used.add(label);
    return behaviour();
  }

  @override
  void cancel() => cancelled.add(label);
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('burrow_vision');
    _FakeDescriber.used.clear();
    _FakeDescriber.cancelled.clear();
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<String> write(String name, List<int> bytes) async {
    final file = File('${tmp.path}/$name');
    await file.writeAsBytes(bytes);
    return file.path;
  }

  group('认图片类型', () {
    test('四种都认得出', () {
      expect(sniffMediaType(_jpeg), 'image/jpeg');
      expect(sniffMediaType(_png), 'image/png');
      expect(sniffMediaType(_gif), 'image/gif');
      expect(sniffMediaType(_webp), 'image/webp');
    });

    test('看文件头不看扩展名', () async {
      // 截图工具存出来的 `.jpg` 其实是 PNG，非常常见。跟着扩展名走的话
      // media_type 会填错 —— Anthropic 直接 400，而有的网关照单全收，
      // 模型看到的是一张花屏，然后一本正经地描述它。
      final path = await write('screenshot.jpg', _png);
      final image = await loadInlineImage(path);
      expect(image.mediaType, 'image/png');
    });

    test('RIFF 但不是 WEBP 不算', () {
      final wav = <int>[
        0x52, 0x49, 0x46, 0x46, //
        0x00, 0x00, 0x00, 0x00,
        0x57, 0x41, 0x56, 0x45, // WAVE
      ];
      expect(sniffMediaType(wav), isNull);
    });

    test('太短的头不会越界', () {
      expect(sniffMediaType(const <int>[]), isNull);
      expect(sniffMediaType(const <int>[0xFF]), isNull);
      expect(sniffMediaType(const <int>[0x52, 0x49, 0x46, 0x46]), isNull);
    });
  });

  group('读图', () {
    test('文件不在时说清是哪张', () async {
      await expectLater(
        loadInlineImage('${tmp.path}/nope.jpg'),
        throwsA(isA<ImageLoadException>()),
      );
    });

    test('空文件不当成有效图', () async {
      final path = await write('empty.jpg', const <int>[]);
      await expectLater(
        loadInlineImage(path),
        throwsA(isA<ImageLoadException>()),
      );
    });

    test('认不出的格式直接拒，不瞎填一个 jpeg', () async {
      final path = await write('doc.jpg', utf8.encode('这其实是一段文本'));
      await expectLater(
        loadInlineImage(path),
        throwsA(isA<ImageLoadException>()),
      );
    });

    test('一张坏的不连累其它张', () async {
      // 一张图坏了就整条消息发不出去是不合理的：用户只会看到"发送失败"，
      // 而他压根不知道是哪张图的问题。
      final good = await write('a.png', _png);
      final bad = await write('b.jpg', utf8.encode('nope'));
      final (loaded, failures) = await loadInlineImages(<String>[good, bad]);
      expect(loaded.keys, <String>[good]);
      expect(failures, hasLength(1));
      expect(failures.single, contains('b.jpg'));
    });

    test('重复路径只读一次', () async {
      final path = await write('a.png', _png);
      final (loaded, _) = await loadInlineImages(<String>[path, path, path]);
      expect(loaded, hasLength(1));
    });
  });

  group('协议块', () {
    const image = InlineImage(
      path: 'x.png',
      mediaType: 'image/png',
      base64Data: 'QUJD',
      bytes: 3,
    );

    test('OpenAI：image_url 里是 data URI', () {
      final parts = openAiContentParts('这是什么', <InlineImage>[image]);
      expect(parts.first['type'], 'image_url');
      expect(
        (parts.first['image_url']! as Map)['url'],
        'data:image/png;base64,QUJD',
      );
      expect(parts.last, <String, Object?>{'type': 'text', 'text': '这是什么'});
    });

    test('Anthropic：source 里分开放 media_type 和 data', () {
      final parts = anthropicContentParts('这是什么', <InlineImage>[image]);
      final source = parts.first['source']! as Map;
      expect(parts.first['type'], 'image');
      expect(source['type'], 'base64');
      expect(source['media_type'], 'image/png');
      expect(source['data'], 'QUJD');
    });

    test('Responses API 的块名不一样', () {
      // input_text / input_image，而且 image_url 是平铺的字符串。
      // 照搬 /chat/completions 的形状会被直接拒。
      final parts = responsesContentParts('这是什么', <InlineImage>[image]);
      expect(parts.first['type'], 'input_image');
      expect(parts.first['image_url'], 'data:image/png;base64,QUJD');
      expect(parts.last['type'], 'input_text');
    });

    test('没有文字时不塞一个空文本块', () {
      // 只发一张图不带话是合理的用法，而空的 text 块有的服务端会拒。
      expect(openAiContentParts('', <InlineImage>[image]), hasLength(1));
      expect(anthropicContentParts('', <InlineImage>[image]), hasLength(1));
      expect(responsesContentParts('', <InlineImage>[image]), hasLength(1));
    });

    test('图排在文字前面', () {
      final parts = openAiContentParts('这是什么', <InlineImage>[image, image]);
      expect(parts.map((p) => p['type']),
          <String>['image_url', 'image_url', 'text']);
    });
  });

  group('描述和原话的拼接', () {
    test('两段都有时各自打标签', () {
      // 混在一段里的话，模型会把描述里的句子当成用户的要求。
      final combined = combineVision('一只猫', '这是什么品种');
      expect(combined, contains('[图片内容]'));
      expect(combined, contains('[用户问题]'));
      expect(combined.indexOf('一只猫'), lessThan(combined.indexOf('这是什么品种')));
    });

    test('只有图时不留一个空的问题段', () {
      expect(combineVision('一只猫', ''), '[图片内容]\n一只猫');
    });

    test('没有描述时原话原样返回', () {
      expect(combineVision('', '你好'), '你好');
      expect(combineVision('   ', '你好'), '你好');
    });
  });

  group('前置多模态的挑选与容灾', () {
    VisionCandidate candidate(String label) => VisionCandidate(
          label: label,
          config: LlmConfig(baseUrl: 'http://x', apiKey: 'k', model: label),
          auth: () async => 'k',
        );

    VisionPreprocessor build(
      List<String> labels,
      Future<String> Function(String label) behaviour,
    ) =>
        VisionPreprocessor(
          candidates: () => labels.map(candidate).toList(),
          createClient: (config, _) =>
              _FakeDescriber(config.model, () => behaviour(config.model)),
        );

    test('一个都没有时的提示要说清怎么办', () async {
      final result = await build(const <String>[], (_) async => '').describe(
        const <String>['a.png'],
      );
      expect(result.ok, isFalse);
      expect(result.error, contains('渠道管理'));
    });

    test('成功时带回用的是哪个来源', () async {
      final result =
          await build(<String>['v1'], (_) async => '  一只猫  ').describe(
        const <String>['a.png'],
      );
      expect(result.ok, isTrue);
      expect(result.description, '一只猫');
      expect(result.usedLabel, 'v1');
    });

    test('挂了就换下一个，直到有一个成功', () async {
      // 视觉这一步是可选增强，不该因为某个网关抽风就让整条消息发不出去。
      final result = await build(<String>['bad1', 'bad2', 'good'], (m) async {
        if (m == 'good') return '一只猫';
        throw StateError('$m 挂了');
      }).describe(const <String>['a.png']);

      expect(result.ok, isTrue);
      expect(result.usedLabel, 'good');
      // 挑选是随机的，所以 good 可能第一个就被挑中；能断言的是**它一定是
      // 最后一个被试的**，前面试过的都失败了。
      expect(_FakeDescriber.used.last, 'good');
    });

    test('空描述算失败，会继续换下一个', () async {
      // 当成功的话，拼出来的是一条只有 `[图片内容]` 四个字没有内容的消息，
      // 模型会对着那四个字发挥。
      final result = await build(<String>['empty', 'good'], (m) async {
        return m == 'empty' ? '   ' : '一只猫';
      }).describe(const <String>['a.png']);

      expect(result.ok, isTrue);
      expect(result.usedLabel, 'good');
    });

    test('全挂了时每个候选各报各的原因', () async {
      // 只报最后一个的话，用户看到的是一句和真正原因无关的错误。
      final result = await build(<String>['v1', 'v2'], (m) async {
        throw StateError(m == 'v1' ? '401 没权限' : '连不上');
      }).describe(const <String>['a.png']);

      expect(result.ok, isFalse);
      expect(result.error, contains('401 没权限'));
      expect(result.error, contains('连不上'));
    });

    test('每个用过的客户端都收掉了', () async {
      await build(<String>['v1', 'v2'], (_) async {
        throw StateError('x');
      }).describe(const <String>['a.png']);
      expect(_FakeDescriber.cancelled.toSet(), <String>{'v1', 'v2'});
    });

    test('同一批图交给同一个候选', () async {
      // 多张图往往是同一件事的几个侧面，分开描述会丢掉它们之间的关系。
      var calls = 0;
      final result = await VisionPreprocessor(
        candidates: () => <VisionCandidate>[candidate('v1')],
        createClient: (config, _) => _FakeDescriber(config.model, () async {
          calls++;
          return '两张图';
        }),
      ).describe(const <String>['a.png', 'b.png']);
      expect(result.ok, isTrue);
      expect(calls, 1);
    });
  });
}
