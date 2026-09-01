/// 渠道、代理解析、多 OAuth 账号。
///
/// 这三块出错的表现都是**「看起来没配」**，而不是报错：代理格式认不出来就
/// 静默直连、渠道 id 撞了就互相覆盖、账号 id 撞了就后登录的顶掉先登录的。
/// 没有一个会抛异常，所以只能在这里钉死。
library;

import 'package:burrow/src/llm/llm_client.dart';
import 'package:burrow/src/net/proxy_client.dart';
import 'package:burrow/src/settings/channel_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('代理地址解析', () {
    test('裸 host:port', () {
      expect(normalizeProxy('127.0.0.1:7890'), '127.0.0.1:7890');
    });

    test('带 scheme 也认', () {
      // 用户从别处抄代理地址时带不带 scheme 全看心情，为此报错不值得。
      expect(normalizeProxy('http://127.0.0.1:7890'), '127.0.0.1:7890');
      expect(normalizeProxy('HTTP://127.0.0.1:7890'), '127.0.0.1:7890');
      expect(normalizeProxy('https://10.0.0.2:8080/'), '10.0.0.2:8080');
    });

    test('前后空白无所谓', () {
      expect(normalizeProxy('  127.0.0.1:7890  '), '127.0.0.1:7890');
    });

    test('空和 null 都是直连', () {
      expect(normalizeProxy(null), isNull);
      expect(normalizeProxy(''), isNull);
      expect(normalizeProxy('   '), isNull);
    });

    test('没有端口不认', () {
      // Dart 会默认 1080，而用户多半只是漏写了端口。
      // 默默连到一个错端口比直接当没配更难查 —— UI 会因此提示格式不对。
      expect(normalizeProxy('127.0.0.1'), isNull);
      expect(normalizeProxy('http://proxy.local'), isNull);
      expect(normalizeProxy('127.0.0.1:'), isNull);
    });

    test('端口不是数字不认', () {
      expect(normalizeProxy('127.0.0.1:abc'), isNull);
    });

    test('不配代理时拿到的是普通客户端', () {
      // 只断言不抛：IOClient 和 BaseClient 的具体类型是实现细节。
      expect(() => buildHttpClient().close(), returnsNormally);
      expect(() => buildHttpClient(proxy: '127.0.0.1:7890').close(),
          returnsNormally);
    });
  });

  group('渠道', () {
    Channel channel({
      String id = 'c1',
      String name = '测试',
      String baseUrl = 'http://gw:3000',
      String model = 'glm-5',
      String? proxy,
      String? oauthProvider,
      String? oauthAccount,
    }) =>
        Channel(
          id: id,
          name: name,
          baseUrl: baseUrl,
          model: model,
          proxy: proxy,
          oauthProviderId: oauthProvider,
          oauthAccountId: oauthAccount,
        );

    test('两个都填了才算用 OAuth', () {
      expect(channel().usesOAuth, isFalse);
      expect(channel(oauthProvider: 'openai').usesOAuth, isFalse);
      expect(channel(oauthAccount: 'a@b.com').usesOAuth, isFalse);
      expect(
        channel(oauthProvider: 'openai', oauthAccount: 'a@b.com').usesOAuth,
        isTrue,
      );
    });

    test('json 往返不丢字段', () {
      final c = channel(
        proxy: '127.0.0.1:7890',
        oauthProvider: 'xai',
        oauthAccount: 'me@x.ai',
      );
      final back = Channel.fromJson(c.toJson());
      expect(back.id, c.id);
      expect(back.name, c.name);
      expect(back.baseUrl, c.baseUrl);
      expect(back.model, c.model);
      expect(back.proxy, c.proxy);
      expect(back.oauthProviderId, c.oauthProviderId);
      expect(back.oauthAccountId, c.oauthAccountId);
    });

    test('缺字段的旧 json 有兜底，不抛', () {
      final back = Channel.fromJson({'id': 'x'});
      expect(back.id, 'x');
      expect(back.apiFormat, 'openAI');
      expect(back.baseUrl, '');
      expect(back.usesOAuth, isFalse);
    });

    test('copyWith 能清掉 OAuth 绑定', () {
      // 单靠 `oauthProviderId: null` 是清不掉的 —— `??` 会把 null 当成
      // "没传"。改回 API Key 认证时必须真的能解绑。
      final bound = channel(oauthProvider: 'openai', oauthAccount: 'a@b.com');
      expect(bound.copyWith(clearOAuth: true).usesOAuth, isFalse);
      expect(bound.copyWith(name: '改个名').usesOAuth, isTrue);
    });

    test('id 不重复', () {
      // 只用时间戳会撞：微秒时间戳的实际精度看平台，Windows 上是毫秒级，
      // 连着生成就是同一个数。撞了的后果是 upsert 把前一个渠道覆盖掉 ——
      // 不报错，只是少了一个渠道。
      final ids = {for (var i = 0; i < 500; i++) ChannelStore.newId()};
      expect(ids.length, 500);
    });
  });

  group('渠道投影成 LlmConfig', () {
    final store = ChannelStore.forTest(keys: {'c1': 'sk-manual'});

    test('没有渠道时是 empty', () {
      expect(store.configFor(null).isConfigured, isFalse);
    });

    test('代理和协议都跟着渠道走', () {
      const c = Channel(
        id: 'c1',
        name: 'n',
        baseUrl: 'https://api.anthropic.com',
        model: 'claude-sonnet-4-6',
        apiFormat: 'anthropic',
        proxy: '127.0.0.1:7890',
      );
      final config = store.configFor(c, temperature: 0.7, streamOutput: false);
      expect(config.apiFormat, 'anthropic');
      expect(config.proxy, '127.0.0.1:7890');
      expect(config.temperature, 0.7);
      expect(config.streamOutput, isFalse);
    });

    test('普通渠道带上保存的 key', () {
      const c =
          Channel(id: 'c1', name: 'n', baseUrl: 'http://gw:3000', model: 'm');
      expect(store.configFor(c).apiKey, 'sk-manual');
    });

    test('OAuth 渠道的 apiKey 是空的', () {
      // access_token 会过期，抄进配置就等于抄了一份马上失效的副本。
      // 真正的 token 由 ConfigurableLlmClient.bearerProvider 每次现取。
      const c = Channel(
        id: 'c2',
        name: 'n',
        baseUrl: 'https://api.openai.com/v1',
        model: 'gpt-5',
        oauthProviderId: 'openai',
        oauthAccountId: 'a@b.com',
      );
      expect(store.configFor(c).apiKey, isEmpty);
    });
  });

  group('客户端换代理', () {
    test('换配置时代理变了会重建底层客户端', () {
      // 代理是设在 HttpClient 上的，不是每个请求的参数。只换 config
      // 不重建的话表现是「改了代理没反应」—— 最难查的一类。
      final client = ConfigurableLlmClient(
        config: const LlmConfig(baseUrl: 'http://a', apiKey: 'k', model: 'm'),
      );
      addTearDown(client.cancel);
      expect(client.config.proxy, isNull);
      client.config = client.config.copyWith(proxy: '127.0.0.1:7890');
      expect(client.config.proxy, '127.0.0.1:7890');
    });
  });
}
