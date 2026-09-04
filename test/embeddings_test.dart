/// 嵌入后端和向量索引。
///
/// 这条链路上最危险的两件事都不会报错，只会给出错误的结果：
///
///   1. **服务端乱序返回**。`/embeddings` 的 data 数组带 index 字段，
///      规范允许不按输入顺序返回。按数组下标取的话，每条记忆配上别人的向量，
///      检索照常工作，只是永远给出莫名其妙的结果。
///   2. **数量对不上**。少返回一条，后面全体错位，同样不会抛。
///
/// 两种都不可能靠"跑一下看看"发现，所以在这里钉死。
library;

import 'dart:convert';

import 'package:burrow/src/context/memory_retrieval.dart';
import 'package:burrow/src/llm/llm_client.dart';
import 'package:burrow/src/llm/embeddings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;

OpenAiEmbedder embedderWith(
  MockClient client, {
  String model = 'text-embedding-3-small',
  String baseUrl = 'http://gw:3000',
}) =>
    OpenAiEmbedder(
      baseUrl: () => baseUrl,
      apiKey: () => 'sk-test',
      model: () => model,
      client: client,
    );

String embeddingsBody(List<List<double>> vectors, {bool reversed = false}) {
  final rows = <Map<String, Object?>>[
    for (var i = 0; i < vectors.length; i++)
      {'index': i, 'embedding': vectors[i], 'object': 'embedding'},
  ];
  return jsonEncode({'data': reversed ? rows.reversed.toList() : rows});
}

void main() {
  group('嵌入后端', () {
    test('没配模型时返回空列表，不发请求', () async {
      var called = false;
      final embedder = embedderWith(
        MockClient((_) async {
          called = true;
          return http.Response('{}', 200);
        }),
        model: '',
      );
      expect(await embedder(['a', 'b']), isEmpty);
      expect(called, isFalse);
      expect(embedder.enabled, isFalse);
    });

    test('端点自动补 /v1', () async {
      late Uri seen;
      final embedder = embedderWith(MockClient((req) async {
        seen = req.url;
        return http.Response(
            embeddingsBody([
              [1, 0]
            ]),
            200);
      }));
      await embedder(['x']);
      expect(seen.toString(), 'http://gw:3000/v1/embeddings');
    });

    test('乱序返回也能按输入顺序对上', () async {
      final embedder = embedderWith(MockClient((_) async {
        // 服务端把 data 倒着给回来，但每行都带正确的 index。
        return http.Response(
          embeddingsBody([
            [1, 0],
            [0, 1],
            [1, 1],
          ], reversed: true),
          200,
        );
      }));
      final vectors = await embedder(['a', 'b', 'c']);
      expect(vectors, [
        [1.0, 0.0],
        [0.0, 1.0],
        [1.0, 1.0],
      ]);
    });

    test('数量对不上就抛，不返回错位的结果', () async {
      final embedder = embedderWith(MockClient((_) async {
        return http.Response(
            embeddingsBody([
              [1, 0],
            ]),
            200);
      }));
      await expectLater(
        embedder(['a', 'b']),
        throwsA(isA<EmbeddingException>()),
      );
    });

    test('超过一批时分批发，结果按顺序拼接', () async {
      var requests = 0;
      final embedder = embedderWith(MockClient((req) async {
        requests++;
        final input = (jsonDecode(req.body) as Map)['input'] as List<dynamic>;
        // 每条文本回一个只有它自己序号的向量，方便断言顺序。
        return http.Response(
          embeddingsBody([
            for (final t in input) [double.parse(t as String)],
          ]),
          200,
        );
      }));

      final texts = [for (var i = 0; i < 70; i++) '$i'];
      final vectors = await embedder(texts);

      expect(requests, 3); // 32 + 32 + 6
      expect(vectors.length, 70);
      expect(vectors.first, [0.0]);
      expect(vectors[40], [40.0]);
      expect(vectors.last, [69.0]);
    });

    test('服务端说批次太大就自动降批，并记住学到的值', () async {
      // 实测：某个聚合网关的 input 上限是 5 条，超了直接
      // 422 `input最多支持 5 条`。上限各家差得很远（OpenAI 官方 2048），
      // 写死一个数就是在赌，赌错的表现是整个嵌入功能悄悄用不了。
      const serverLimit = 5;
      var rejected = 0;
      final embedder = embedderWith(MockClient((req) async {
        final input = (jsonDecode(req.body) as Map)['input'] as List<dynamic>;
        if (input.length > serverLimit) {
          rejected++;
          // 用 bytes 而不是 String：http.Response 的 String 构造默认按
          // latin1 编码，中文直接抛。真实服务端返回的也是 UTF-8 字节。
          return http.Response.bytes(
            utf8.encode(jsonEncode({
              'error': {'message': 'input最多支持 $serverLimit 条'}
            })),
            422,
          );
        }
        return http.Response(
          embeddingsBody([
            for (final t in input) [double.parse(t as String)],
          ]),
          200,
        );
      }));

      final texts = [for (var i = 0; i < 13; i++) '$i'];
      final vectors = await embedder(texts);

      expect(rejected, greaterThan(0), reason: '得先撞上限才谈得上学习');
      expect(embedder.batchSize, lessThanOrEqualTo(serverLimit));
      expect(vectors.length, 13);
      // 顺序仍然要对 —— 降批重试最容易把对应关系搞乱。
      expect(vectors.first, [0.0]);
      expect(vectors.last, [12.0]);
      expect(embedder.lastError, isNull);

      // 学到之后不再重复撞墙。
      final before = rejected;
      await embedder(texts);
      expect(rejected, before);
    });

    test('401 这类不因为降批而好转的错误不重试', () async {
      var calls = 0;
      final embedder = embedderWith(MockClient((_) async {
        calls++;
        return http.Response('unauthorized', 401);
      }));
      await expectLater(
          embedder(['a', 'b']), throwsA(isA<EmbeddingException>()));
      expect(calls, 1, reason: '批次再小也还是没权限，重试纯属浪费');
    });

    test('返回 HTML 时说清楚多半是地址不对', () async {
      final embedder = embedderWith(MockClient((_) async {
        // /v1 那次事故的同款：200 + 前端页面。
        return http.Response('<!doctype html><html></html>', 200);
      }));
      await expectLater(
        embedder(['a']),
        throwsA(predicate((e) => '$e'.contains('接口地址不对'))),
      );
    });

    test('失败原因留在 lastError 上，成功后清掉', () async {
      var fail = true;
      final embedder = embedderWith(MockClient((_) async {
        if (fail) return http.Response('nope', 500);
        return http.Response(
            embeddingsBody([
              [1, 0]
            ]),
            200);
      }));

      await expectLater(embedder(['a']), throwsA(isA<EmbeddingException>()));
      expect(embedder.lastError, contains('500'));

      fail = false;
      await embedder(['a']);
      expect(embedder.lastError, isNull);
    });
  });

  group('摘要模型的取值', () {
    // 这一组钉的是一个实测踩到的静默失败：设置页把"摘要模型"留空时，
    // 存进 prefs 的是空字符串而不是 null，读回来 `summaryModel ?? model`
    // 求值成 ''，摘要请求带着 "model": "" 发出去必然 400。
    // 而 summarize() 是永不抛的，于是表现成「滚动摘要一次都不生效」，
    // 上下文只增不减，界面上毫无迹象。
    const base =
        LlmConfig(baseUrl: 'http://gw:3000', apiKey: 'k', model: 'glm-5');

    test('没填时用对话模型', () {
      expect(base.summaryModelOrDefault, 'glm-5');
    });

    test('空字符串也算没填', () {
      expect(base.copyWith(summaryModel: '').summaryModelOrDefault, 'glm-5');
    });

    test('只有空格也算没填', () {
      expect(base.copyWith(summaryModel: '   ').summaryModelOrDefault, 'glm-5');
    });

    test('填了就用填的那个', () {
      expect(
        base.copyWith(summaryModel: 'glm-4-flash').summaryModelOrDefault,
        'glm-4-flash',
      );
    });
  });

  group('向量索引', () {
    MemoryDoc doc(String source, String text) => MemoryDoc(
          text: text,
          at: DateTime.now(),
          importance: 0.5,
          source: source,
        );

    test('只嵌入还没有向量的文档', () async {
      final embedded = <List<String>>[];
      final retrieval = MemoryRetrieval(embedder: (texts) async {
        embedded.add(texts);
        return [
          for (final _ in texts) [1.0, 0.0]
        ];
      });

      await retrieval.index([doc('h:0', 'a'), doc('h:1', 'b')]);
      expect(embedded, [
        ['a', 'b']
      ]);

      // 第二轮多了一条：只有新的那条会被送去嵌入。
      await retrieval
          .index([doc('h:0', 'a'), doc('h:1', 'b'), doc('h:2', 'c')]);
      expect(embedded.last, ['c']);
      expect(retrieval.vectorIndex.keys, containsAll(['h:0', 'h:1', 'h:2']));
    });

    test('数量对不上时一条都不存', () async {
      final retrieval = MemoryRetrieval(embedder: (texts) async {
        return [
          [1.0, 0.0]
        ]; // 要两条，只给一条
      });
      await retrieval.index([doc('h:0', 'a'), doc('h:1', 'b')]);
      // 宁可没有向量，也不能让记忆配上别人的向量。
      expect(retrieval.vectorIndex, isEmpty);
    });

    test('后端抛异常时降级，并把原因留下', () async {
      final retrieval = MemoryRetrieval(embedder: (_) async {
        throw const EmbeddingException('连不上');
      });
      await retrieval.index([doc('h:0', 'a')]);
      expect(retrieval.vectorIndex, isEmpty);
      expect(retrieval.lastEmbeddingError, contains('连不上'));
    });

    test('没配嵌入后端时 index 是空操作，检索照常两路', () async {
      final retrieval = MemoryRetrieval();
      await retrieval.index([doc('h:0', '安装 torch')]);
      expect(retrieval.vectorIndex, isEmpty);

      final hits = await retrieval.search('torch', [
        doc('h:0', '我们安装了 torch 这个包'),
        doc('h:1', '今天天气不错'),
      ]);
      expect(hits, isNotEmpty);
      expect(hits.first.doc.source, 'h:0');
    });

    test('换了嵌入后端就把旧向量全丢掉', () async {
      // 不同模型的向量不在同一个空间里，混着算余弦得到的是无意义的数 ——
      // 而且**不会报错**，只会一直召回莫名其妙的东西。
      var backend = 'c1::bge-m3';
      final retrieval = MemoryRetrieval(
        embedder: (texts) async => [
          for (final _ in texts) [1.0, 0.0]
        ],
        fingerprint: () => backend,
      );

      await retrieval.index([doc('h:0', 'a')]);
      expect(retrieval.vectorIndex.keys, ['h:0']);

      // 同名模型换了个渠道也算换 —— 那同样是两个空间。
      backend = 'c2::bge-m3';
      await retrieval.index([doc('h:0', 'a')]);
      expect(retrieval.vectorIndex.keys, ['h:0']);
      // 旧的那条是被重嵌过的，不是留下来的：清干净了才会再嵌一次。
      expect(retrieval.lastEmbeddingError, isNull);
    });

    test('后端没变时不重嵌', () async {
      var calls = 0;
      final retrieval = MemoryRetrieval(
        embedder: (texts) async {
          calls++;
          return [
            for (final _ in texts) [1.0, 0.0]
          ];
        },
        fingerprint: () => 'c1::bge-m3',
      );
      await retrieval.index([doc('h:0', 'a')]);
      await retrieval.index([doc('h:0', 'a')]);
      // 每轮全量重嵌等于每轮多付一次全量的钱。
      expect(calls, 1);
    });

    test('嵌入后端返回空列表（未配置）时不加向量路，也不报错', () async {
      final retrieval = MemoryRetrieval(embedder: (_) async => const []);
      await retrieval.index([doc('h:0', '安装 torch')]);
      expect(retrieval.vectorIndex, isEmpty);
      expect(retrieval.lastEmbeddingError, isNull);
    });
  });
}
