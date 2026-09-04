/// 「有哪些来源可挑」和「怎么从一个来源拉模型列表」。
///
/// 两个地方要它：输入框 `+` 菜单里的对话模型，和设置里那张模型分工表。
/// 抽出来而不是各写一份，是因为拉取那一步**必须走那个渠道自己的代理和
/// 认证**：抄一份到第二个页面里，迟早有一份会漏掉其中一样，而漏掉的表现是
/// 「聊天是通的，但选择器里拉不到模型」—— 那种不一致最难查。
library;

import '../llm/model_catalog.dart';
import '../net/proxy_client.dart';
import '../settings/account_store.dart';
import '../settings/channel_store.dart';
import '../settings/settings_store.dart';
import 'model_bar.dart';

class ModelSourceCatalog {
  const ModelSourceCatalog({
    required this.channels,
    required this.accounts,
    required this.settings,
  });

  final ChannelStore channels;
  final AccountStore accounts;
  final SettingsStore settings;

  /// 选择器里那一排来源 = 渠道列表，各自带着自己缓存的模型。
  List<ModelSource> sources() => <ModelSource>[
        for (final c in channels.channels)
          ModelSource(
            id: c.id,
            name: c.name,
            host: c.host,
            models: settings.modelsOf(c.id),
            configuredModel: c.model,
            // 带上能力表：手动没设过的那些项由它来填。
            capabilityOf: (model) => channels.capabilityOf(c, model),
          ),
      ];

  /// 从某个渠道拉一次模型列表，顺手缓存下来。
  ///
  /// 带渠道参数而不是用"当前渠道"：选择器里可以翻别的来源，翻的时候
  /// 当前渠道并没有变；按当前渠道拉的话，用户看到的会是 A 的地址配 B 的列表。
  Future<List<String>> refresh(String channelId) async {
    final channel = channels.byId(channelId);
    if (channel == null) throw StateError('这个渠道已经不存在了');
    // 走**这个渠道自己**的代理和认证。用默认客户端的话，配了代理的渠道
    // 在这里会超时，而聊天本身是通的 —— 那种不一致最难查。
    final auth =
        await accounts.authFor(channel, apiKey: channels.apiKeyOf(channel));
    final client = buildHttpClient(proxy: channel.proxy);
    final List<FetchedModel> models;
    try {
      models = channel.oauthProviderId == 'openai_oauth'
          ? await fetchChatGptOAuthModels(
              accessToken: auth,
              accountId: accounts.credentialFor(channel)?.accountId ?? '',
              client: client,
            )
          : await fetchModels(
              baseUrl: channel.baseUrl,
              apiKey: auth,
              apiFormat: channel.apiFormat,
              client: client,
            );
    } finally {
      client.close();
    }
    final ids = models.map((m) => m.id).toList();
    await settings.setModelsFor(channelId, ids);
    return ids;
  }
}
