import 'dart:convert';
import 'dart:io';

import 'package:burrow/src/llm/model_registry.dart';
import 'package:burrow/src/llm/model_registry_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 一份 models.dev 形状的最小响应。
String payload({bool vision = true}) => jsonEncode(<String, Object?>{
      'openai': <String, Object?>{
        'models': <String, Object?>{
          'gpt-4o': <String, Object?>{
            'id': 'gpt-4o',
            'tool_call': true,
            'modalities': <String, Object?>{
              'input': <String>['text', if (vision) 'image'],
            },
            'limit': <String, Object?>{'context': 128000},
          },
        },
      },
    });

void main() {
  late Directory tmp;
  late File cache;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('burrow_registry');
    cache = File('${tmp.path}/model_registry.json');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  group('双源兜底', () {
    test('第一个源就能拿到时不去打第二个', () async {
      final tried = <String>[];
      final store = ModelRegistryStore(
        cacheFile: cache,
        httpClient: MockClient((request) async {
          tried.add(request.url.toString());
          return http.Response(payload(), 200);
        }),
      );

      expect(await store.refresh(), isTrue);
      expect(tried, <String>[modelRegistrySources.first]);
      expect(store.registry.lookup('gpt-4o')!.vision, isTrue);
    });

    test('第一个源挂了就换第二个', () async {
      final tried = <String>[];
      final store = ModelRegistryStore(
        cacheFile: cache,
        httpClient: MockClient((request) async {
          tried.add(request.url.toString());
          // models.dev 在部分网络下是打不开的，这条路必须有备份。
          if (tried.length == 1) throw const SocketException('连不上');
          return http.Response(payload(), 200);
        }),
      );

      expect(await store.refresh(), isTrue);
      expect(tried, modelRegistrySources);
      expect(store.registry.lookup('gpt-4o')!.tools, isTrue);
    });

    test('两个都挂了不抛，保持原样', () async {
      final store = ModelRegistryStore(
        cacheFile: cache,
        httpClient: MockClient((_) async => http.Response('挂了', 500)),
      );

      // 拉不到能力表不是错误，只是这次没有提示。
      expect(await store.refresh(), isFalse);
      expect(store.registry.size, 0);
    });

    test('返回 200 但内容是垃圾时也算失败，不会把空表写进缓存', () async {
      final store = ModelRegistryStore(
        cacheFile: cache,
        httpClient:
            MockClient((_) async => http.Response('<html>登录页</html>', 200)),
      );
      expect(await store.refresh(), isFalse);
      expect(await cache.exists(), isFalse);
    });
  });

  group('缓存', () {
    test('拉到之后写缓存，下次直接读它', () async {
      var calls = 0;
      final store = ModelRegistryStore(
        cacheFile: cache,
        httpClient: MockClient((_) async {
          calls++;
          return http.Response(payload(), 200);
        }),
      );

      await store.refresh();
      expect(await cache.exists(), isTrue);
      // 缓存里存的是压平之后的表（130KB 量级），不是 4MB 的原始响应。
      expect(decodeRegistry(await cache.readAsString())['gpt-4o'], isNotNull);

      // 新鲜的缓存不该再打网络 —— 每次启动拉一遍纯属浪费流量。
      expect(await store.refresh(), isFalse);
      expect(calls, 1);

      // 但显式要求刷新时照打。
      await store.refresh(force: true);
      expect(calls, 2);
    });

    test('从缓存启动时不打网络', () async {
      await cache.writeAsString(encodeRegistry(<String, ModelMeta>{
        'gpt-4o': const ModelMeta(vision: true, tools: true),
      }));

      final store = ModelRegistryStore(
        cacheFile: cache,
        httpClient: MockClient((_) async => throw StateError('不该联网')),
      );
      await store.load();
      expect(store.registry.lookup('gpt-4o')!.vision, isTrue);
    });

    test('缓存坏了当没有，不崩', () async {
      await cache.writeAsString('写到一半断电了{{{');
      final store = ModelRegistryStore(
        cacheFile: cache,
        httpClient: MockClient((_) async => http.Response(payload(), 200)),
      );
      // load 读不出缓存会去读随包快照；测试环境里没有资源包，
      // 这里只要求它不抛。
      await store.load();
      expect(store.registry.size, 0);

      // 坏缓存不该挡住联网刷新。
      expect(await store.refresh(), isTrue);
      expect(store.registry.lookup('gpt-4o'), isNotNull);
    });
  });

  test('表变了会通知出去 —— 界面上的能力图标要跟着刷', () async {
    final store = ModelRegistryStore(
      cacheFile: cache,
      httpClient: MockClient((_) async => http.Response(payload(), 200)),
    );
    final seen = <int>[];
    store.changes.listen((_) => seen.add(store.registry.size));

    await store.refresh();
    await Future<void>.delayed(Duration.zero);
    expect(seen, <int>[1]);
  });
}
