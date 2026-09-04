/// 渠道、代理解析、多 OAuth 账号。
///
/// 这三块出错的表现都是**「看起来没配」**，而不是报错：代理格式认不出来就
/// 静默直连、渠道 id 撞了就互相覆盖、账号 id 撞了就后登录的顶掉先登录的。
/// 没有一个会抛异常，所以只能在这里钉死。
library;

import 'dart:convert';

import 'package:burrow/src/llm/llm_client.dart';
import 'package:burrow/src/net/proxy_client.dart';
import 'package:burrow/src/settings/channel_store.dart';
import 'package:burrow/src/settings/model_roles.dart';
import 'package:burrow/src/settings/settings_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('渠道地址', () {
    Channel at(String baseUrl) =>
        Channel(id: 'c', name: 'n', baseUrl: baseUrl, model: 'm');

    test('host 带端口', () {
      expect(at('http://192.168.31.228:3000/v1').host, '192.168.31.228:3000');
    });

    test('默认端口不显示', () {
      expect(at('https://api.openai.com/v1').host, 'api.openai.com');
    });

    test('认不出来就原样给出去', () {
      // 宁可显示一串怪东西，也不能显示空白 —— 这一行的作用就是让用户
      // 在点下去之前认出"这次发给谁"，空着等于没有这一行。
      expect(at('不是个地址').host, '不是个地址');
      expect(at('').host, '');
    });

    test('ChatGPT OAuth 显示提供商而不是 API 地址', () {
      const channel = Channel(
        id: 'c',
        name: 'https://chatgpt.com/backend-api/codex',
        baseUrl: 'https://chatgpt.com/backend-api/codex',
        model: 'gpt-5.4',
        oauthProviderId: 'openai_oauth',
        oauthAccountId: 'account',
      );
      expect(channel.providerLabel, 'ChatGPT');
    });

    test('OpenAI API Key 渠道显示 OpenAI', () {
      const channel = Channel(
        id: 'c',
        name: 'https://api.openai.com/v1',
        baseUrl: 'https://api.openai.com/v1',
        model: 'gpt-5.4',
      );
      expect(channel.providerLabel, 'OpenAI');
    });

    test('自定义网关保留用户起的提供商名', () {
      const channel = Channel(
        id: 'c',
        name: '公司网关',
        baseUrl: 'https://gateway.example/v1',
        model: 'model',
      );
      expect(channel.providerLabel, '公司网关');
    });
  });

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

    test('ChatGPT OAuth 投影成专用 Responses 协议', () {
      const c = Channel(
        id: 'c2',
        name: 'ChatGPT',
        baseUrl: 'https://chatgpt.com/backend-api/codex',
        model: 'gpt-codex-test',
        oauthProviderId: 'openai_oauth',
        oauthAccountId: 'a@b.com',
      );
      expect(store.configFor(c).apiFormat, 'chatgptOAuth');
    });
  });

  _modelCacheTests();
  _modelRoleTests();

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

/// 模型列表**跟着渠道走**。
///

/// 模型分工表：哪件事用哪个渠道的哪个模型。
///
/// 这一组钉的是和上面那份模型缓存同一个病根：配角模型曾经只有一个**名字**，
/// 地址和密钥现取当前渠道的。于是「聊天用 A、嵌入用 B」配出来的实际行为是
/// 拿 B 的模型名去 A 的地址上请求 —— 一路 404，或者更糟：A 上刚好有个同名
/// 模型，于是照常计费、照常返回一堆不在同一空间里的向量。
///
/// 全都不抛异常，所以只能在这里钉死。
void _modelRoleTests() {
  const a = Channel(
    id: 'c1',
    name: '本地网关',
    baseUrl: 'http://gw:3000',
    model: 'glm-5',
    proxy: '127.0.0.1:7890',
  );
  const b = Channel(
    id: 'c2',
    name: 'OpenAI',
    baseUrl: 'https://api.openai.com/v1',
    model: 'gpt-5',
  );

  group('模型分工表', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    test('配角模型发往它自己那个渠道，不是当前渠道', () async {
      final channels = ChannelStore.forTest(
        channels: [a, b],
        activeId: 'c1',
        keys: {'c2': 'sk-openai'},
      );
      await channels.assignRole(ModelRole.embedding,
          const ModelRef(channelId: 'c2', model: 'text-embedding-3-small'));

      final resolved = channels.resolveRole(ModelRole.embedding)!;
      expect(resolved.channel.id, 'c2');
      expect(resolved.channel.baseUrl, 'https://api.openai.com/v1');
      expect(resolved.model, 'text-embedding-3-small');
      // 当前对话渠道**没有**被拖着一起换。为了换个嵌入模型把整个对话搬走，
      // 正是这张表要根治的事。
      expect(channels.activeId, 'c1');
    });

    test('投影出来的配置带的是那个渠道的地址、密钥和代理', () async {
      final channels = ChannelStore.forTest(
        channels: [a, b],
        activeId: 'c1',
        keys: {'c1': 'sk-local', 'c2': 'sk-openai'},
      );
      await channels.assignRole(ModelRole.vision,
          const ModelRef(channelId: 'c2', model: 'gpt-5-vision'));

      final config =
          channels.configForRole(channels.resolveRole(ModelRole.vision)!);
      expect(config.baseUrl, 'https://api.openai.com/v1');
      expect(config.apiKey, 'sk-openai');
      expect(config.model, 'gpt-5-vision');
      // 代理跟着 c2（没配），不是当前渠道 c1 那个 —— 抄错的话表现只是超时，
      // 看不出和代理有关。
      expect(config.proxy, isNull);
    });

    test('对话模型的指派 = 换渠道 + 换那个渠道的模型', () async {
      final channels = ChannelStore.forTest(channels: [a, b], activeId: 'c1');
      await channels.assignRole(
          ModelRole.chat, const ModelRef(channelId: 'c2', model: 'gpt-5-mini'));

      expect(channels.activeId, 'c2');
      expect(channels.byId('c2')!.model, 'gpt-5-mini');
      // 顺序反了的话新模型会被写到用户正想离开的那个渠道上。
      expect(channels.byId('c1')!.model, 'glm-5');
    });

    test('删掉渠道会连指向它的分工一起清掉', () async {
      final channels = ChannelStore.forTest(channels: [a, b], activeId: 'c1');
      await channels.assignRole(ModelRole.embedding,
          const ModelRef(channelId: 'c2', model: 'text-embedding-3-small'));

      await channels.remove('c2');
      // 留着的话表里会显示一个存在过的模型名，而那一路其实已经不工作了。
      expect(channels.refOf(ModelRole.embedding), isNull);
      expect(channels.resolveRole(ModelRole.embedding), isNull);
    });

    test('摘要没指派时跟着当前渠道，指派后不再跟着', () async {
      const withSummary = Channel(
        id: 'c1',
        name: '本地网关',
        baseUrl: 'http://gw:3000',
        model: 'glm-5',
        summaryModel: 'glm-4.6-flash',
      );
      final channels =
          ChannelStore.forTest(channels: [withSummary, b], activeId: 'c1');

      final inherited = channels.resolveRole(ModelRole.summary)!;
      expect(inherited.model, 'glm-4.6-flash');
      expect(inherited.inherited, isTrue);

      await channels.assignRole(ModelRole.summary,
          const ModelRef(channelId: 'c2', model: 'gpt-5-mini'));
      final assigned = channels.resolveRole(ModelRole.summary)!;
      expect(assigned.channel.id, 'c2');
      expect(assigned.inherited, isFalse);
    });

    test('嵌入没指派 = 不启用，没有任何回退', () async {
      final channels = ChannelStore.forTest(channels: [a], activeId: 'c1');
      // 回退到对话模型的话，检索会拿一个聊天模型去打 /embeddings，
      // 而失败是安静的 —— 用户只会觉得"检索有时候不太准"。
      expect(channels.resolveRole(ModelRole.embedding), isNull);
    });

    test('指纹带上渠道：同名模型在两家服务商那里是两个空间', () async {
      final channels = ChannelStore.forTest(channels: [a, b], activeId: 'c1');
      await channels.assignRole(ModelRole.embedding,
          const ModelRef(channelId: 'c1', model: 'bge-m3'));
      final first = channels.resolveRole(ModelRole.embedding)!.fingerprint;

      await channels.assignRole(ModelRole.embedding,
          const ModelRef(channelId: 'c2', model: 'bge-m3'));
      final second = channels.resolveRole(ModelRole.embedding)!.fingerprint;

      expect(first, isNot(second));
    });

    test('落盘的是完整的一对，重开还在', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final prefs = await SharedPreferences.getInstance();
      final first = await ChannelStore.load(prefs: prefs, secure: null);
      await first.upsert(a);
      await first.upsert(b);
      await first.assignRole(ModelRole.embedding,
          const ModelRef(channelId: 'c2', model: 'text-embedding-3-small'));

      final second = await ChannelStore.load(prefs: prefs, secure: null);
      final ref = second.refOf(ModelRole.embedding)!;
      expect(ref.channelId, 'c2');
      expect(ref.model, 'text-embedding-3-small');
    });

    test('旧版那份只有模型名的嵌入配置，认领给当时那个渠道', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'burrow.channels': jsonEncode(<Object>[a.toJson(), b.toJson()]),
        'burrow.channels.active': 'c2',
        ChannelStore.legacyEmbeddingKey: 'text-embedding-3-small',
      });
      final prefs = await SharedPreferences.getInstance();
      final store = await ChannelStore.load(prefs: prefs, secure: null);

      // 当初请求就是发往当时那个渠道的，所以认领给它是对的。不认领的话，
      // 升级后用户配过的嵌入模型会安静地消失。
      final ref = store.refOf(ModelRole.embedding)!;
      expect(ref.channelId, 'c2');
      expect(ref.model, 'text-embedding-3-small');
      expect(prefs.getString(ChannelStore.legacyEmbeddingKey), isNull);
    });
  });
}

/// 这一组钉的是一个会让人花错钱的 bug：模型列表曾经是一份全局缓存，
/// 在 A 渠道拉一次、切到 B，选择器里列的还是 A 的模型。挑一个发出去，
/// 要么 404，要么更糟 —— B 那边刚好有个同名模型，于是照常计费。
void _modelCacheTests() {
  const a = Channel(
      id: 'c1', name: '本地网关', baseUrl: 'http://gw:3000', model: 'glm-5');
  const b = Channel(
      id: 'c2',
      name: 'OpenAI',
      baseUrl: 'https://api.openai.com/v1',
      model: 'gpt-5');

  /// bindChannels 里的认领和清理是 unawaited 的（它们不该拖慢启动），
  /// 所以断言前要让出一次事件循环。
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  group('模型缓存按渠道分开', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    test('切渠道不会串列表', () async {
      final channels = ChannelStore.forTest(channels: [a, b], activeId: 'c1');
      final settings = await SettingsStore.load();
      settings.bindChannels(channels);

      await settings.setModelsFor('c1', <String>['glm-5', 'glm-4.6']);
      expect(settings.cachedModels, <String>['glm-5', 'glm-4.6']);

      await channels.setActive('c2');
      // 空的，不是 c1 那份。选择器据此自动拉一次 —— 那正是想要的：
      // 宁可等一次网络往返，也不能列一份别人家的菜单。
      expect(settings.cachedModels, isEmpty);

      await channels.setActive('c1');
      expect(settings.cachedModels, <String>['glm-5', 'glm-4.6']);
    });

    test('拉取期间切走了，列表仍然记在拉的那个渠道上', () async {
      // 拉模型是异步的，回来时用户完全可能已经切走了。
      // 记到"当前渠道"上就会把 A 的列表安到 B 头上。
      final channels = ChannelStore.forTest(channels: [a, b], activeId: 'c1');
      final settings = await SettingsStore.load();
      settings.bindChannels(channels);

      await channels.setActive('c2');
      await settings.setModelsFor('c1', <String>['glm-5']);

      expect(settings.cachedModels, isEmpty);
      expect(settings.modelsOf('c1'), <String>['glm-5']);
    });

    test('删掉渠道会连它的模型列表一起清掉', () async {
      final channels = ChannelStore.forTest(channels: [a, b], activeId: 'c1');
      final settings = await SettingsStore.load();
      settings.bindChannels(channels);
      await settings.setModelsFor('c1', <String>['glm-5']);

      await channels.remove('c1');
      await settle();
      expect(settings.modelsOf('c1'), isEmpty);
    });

    test('落盘的是按渠道分的表，重开还在', () async {
      final channels = ChannelStore.forTest(channels: [a, b], activeId: 'c1');
      final settings = await SettingsStore.load();
      settings.bindChannels(channels);
      await settings.setModelsFor('c1', <String>['glm-5']);

      final reopened = await SettingsStore.load();
      reopened
          .bindChannels(ChannelStore.forTest(channels: [a, b], activeId: 'c1'));
      expect(reopened.cachedModels, <String>['glm-5']);
    });
  });

  group('旧版全局列表的迁移', () {
    test('认领给当前渠道，别的渠道仍然是空的', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'burrow.llm.cachedModels': <String>['glm-5', 'glm-4.6'],
      });
      final settings = await SettingsStore.load();
      settings
          .bindChannels(ChannelStore.forTest(channels: [a, b], activeId: 'c1'));
      await settle();

      expect(settings.modelsOf('c1'), <String>['glm-5', 'glm-4.6']);
      expect(settings.modelsOf('c2'), isEmpty);
    });

    test('bind 时还没有渠道，等迁移建出来再认领', () async {
      // main 里是先 bindChannels 再 migrateFrom，所以 bind 的那一刻
      // 一个渠道都没有。在那里直接丢掉的话，升级后第一次打开选择器是空的。
      SharedPreferences.setMockInitialValues(<String, Object>{
        'burrow.llm.cachedModels': <String>['glm-5'],
      });
      final channels = ChannelStore.forTest();
      final settings = await SettingsStore.load();
      settings.bindChannels(channels);
      await settle();
      expect(settings.cachedModels, isEmpty);

      await channels.upsert(a);
      await settle();
      expect(settings.modelsOf('c1'), <String>['glm-5']);
    });
  });

  group('来源署名', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    test('只有一个渠道也显示提供商和模型', () async {
      final settings = await SettingsStore.load();
      settings
          .bindChannels(ChannelStore.forTest(channels: [a], activeId: 'c1'));
      expect(settings.sourceLabel, '本地网关 · glm-5');
    });

    test('多渠道时显示提供商和模型', () async {
      // 同名模型挂在两个渠道上是常态（一个免费网关、一个计费官方），
      // 光看模型名分不出花的是谁的钱。
      final settings = await SettingsStore.load();
      settings
          .bindChannels(ChannelStore.forTest(channels: [a, b], activeId: 'c2'));
      expect(settings.sourceLabel, 'OpenAI · gpt-5');
    });

    test('没有渠道时是空的', () async {
      final settings = await SettingsStore.load();
      settings.bindChannels(ChannelStore.forTest());
      expect(settings.sourceLabel, isEmpty);
    });
  });

  group('标星模型', () {
    const a = Channel(
        id: 'c1', name: '本地网关', baseUrl: 'http://gw:3000', model: 'glm-5');
    const b = Channel(
        id: 'c2',
        name: 'OpenAI',
        baseUrl: 'https://api.openai.com/v1',
        model: 'gpt-5');

    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    test('标一次加上，再标一次去掉', () async {
      final channels = ChannelStore.forTest(channels: [a], activeId: 'c1');

      await channels.toggleStarred('c1', 'glm-4.6');
      expect(channels.byId('c1')!.isStarred('glm-4.6'), isTrue);

      await channels.toggleStarred('c1', 'glm-4.6');
      expect(channels.byId('c1')!.isStarred('glm-4.6'), isFalse);
    });

    test('星标跟着渠道，不是全局', () async {
      // 同一个模型名在两个渠道上是不同的东西（一个免费网关、一个计费官方），
      // 「我在这个渠道上常用哪几个」也就只能按渠道分。
      final channels = ChannelStore.forTest(channels: [a, b], activeId: 'c1');
      await channels.toggleStarred('c1', 'gpt-5');

      expect(channels.byId('c1')!.isStarred('gpt-5'), isTrue);
      expect(channels.byId('c2')!.isStarred('gpt-5'), isFalse);
    });

    test('删渠道时星标跟着一起走，不留悬空收藏', () async {
      final channels = ChannelStore.forTest(channels: [a, b], activeId: 'c1');
      await channels.toggleStarred('c2', 'gpt-5-mini');

      await channels.remove('c2');
      expect(channels.byId('c2'), isNull);
    });

    test('json 往返不丢', () {
      const channel = Channel(
        id: 'c1',
        name: '本地网关',
        baseUrl: 'http://gw:3000',
        model: 'glm-5',
        starredModels: <String>{'glm-4.6', 'glm-5'},
      );
      final back = Channel.fromJson(channel.toJson());
      expect(back.starredModels, <String>{'glm-4.6', 'glm-5'});
    });

    test('老配置没有这个字段，读出来是空集', () {
      final back = Channel.fromJson(<String, Object?>{
        'id': 'c1',
        'name': '老渠道',
        'base_url': 'http://gw:3000',
        'model': 'glm-5',
      });
      expect(back.starredModels, isEmpty);
    });

    test('落盘的是排好序的列表 —— 同样的内容不该产生不同的字节', () {
      const channel = Channel(
        id: 'c1',
        name: 'n',
        baseUrl: 'http://gw:3000',
        model: 'm',
        starredModels: <String>{'b', 'a', 'c'},
      );
      expect(channel.toJson()['starred_models'], <String>['a', 'b', 'c']);
    });

    test('不存在的渠道或空模型名都是空操作', () async {
      final channels = ChannelStore.forTest(channels: [a], activeId: 'c1');
      await channels.toggleStarred('没这个渠道', 'glm-5');
      await channels.toggleStarred('c1', '   ');
      expect(channels.byId('c1')!.starredModels, isEmpty);
    });
  });
}
