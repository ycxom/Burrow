/// 渠道：一个可用的模型接入点。
///
/// 「渠道」把原来散在设置页里的 baseUrl / key / 协议 / 模型收成一个对象，
/// 并且允许存**多个**。理由是这三件事本来就是绑在一起变的 —— 换服务商时
/// 不可能只换 baseUrl 而留着上一家的 key，而原来的单份配置逼着用户每次
/// 手动改三个输入框，改错一个就是一串莫名其妙的报错。
///
/// 认证有两种，二选一：
///   - **API key**：手填的密钥，存在 secure storage 里。
///   - **OAuth 账号**：指向 [AccountStore] 里的某个账号。token 会过期，
///     所以这里只存"用哪个账号"，真正的 access_token 每次请求前现取。
///
/// 代理是**每个渠道各自的**：一个渠道走内网直连、另一个走梯子，是很常见的
/// 组合，全局代理会把前者也拖进去。
///
/// 这里还存着**模型分工表**（见 [ModelRole]）：哪件事用哪个渠道的哪个模型。
/// 放在这里而不是单独一个 store，是因为它的每一条都得先能解析成一个渠道 ——
/// 而"这个渠道还在不在"只有这里知道，删渠道时顺手把指向它的指派一起清掉，
/// 是唯一不会留下悬空指向的地方。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../llm/llm_client.dart';
import '../llm/model_registry.dart';
import '../llm/system_prompt.dart';
import '../llm/thinking_effort.dart';
import 'model_roles.dart';

@immutable

/// 一个**具体模型**的能力。
///
/// ## 为什么挂在模型上而不是渠道上
///
/// 一个渠道（一个接入点 + 一个 key）下面往往有几十个模型：聚合网关尤其如此，
/// 同一个 key 后面既有能看图能调工具的旗舰，也有纯文本的小模型。而
/// [SettingsStore.setModel] 换模型改的就是 `channel.model` —— 能力标记留在渠道上
/// 的话，换一个模型之后标记不跟着换，于是：
///
///   - 视觉标记错了 → 图直接塞进请求体，模型要么 400，要么**收下当没看见**，
///     照常答一段，用户以为它看过了；
///   - 工具标记错了 → 终端模式下发过去一堆 tools，不支持的模型直接 400，
///     而错误信息通常只说"参数不对"，看不出是哪个参数。
///
/// 所以能力是模型的属性，不是渠道的属性。
///
/// ## 为什么是手动勾，不自动探测
///
/// 和视觉标记原本的理由一样：聚合网关返回的模型 id 五花八门（`gpt-4o` 的
/// 转售名可能叫 `azure-4o-0806-hk`），靠名字猜必然会猜错，而猜错的代价上面
/// 已经列过了。真要探测只能发一次真实请求去试，那要花用户的钱。
class ModelCapability {
  /// 三个字段都是**三态**：true / false / null。
  ///
  /// **null 是「用户没表过态」，不是 false。** 少了这个区分，用户为某个模型
  /// 打开一次「能看图」，就等于把同一条记录里的「支持工具」也按当时的渠道
  /// 默认值冻住了 —— 之后自动探测再也纠正不了它，而用户压根不知道自己
  /// 顺手关掉了什么。
  const ModelCapability({this.vision, this.tools, this.search});

  /// 能直接接收图片。null = 跟着自动探测 / 渠道默认走。
  final bool? vision;

  /// 支持 function calling / tool use。
  final bool? tools;

  /// 让模型自己联网搜索。**只有 Gemini 原生协议有这个东西**，别的协议上它是
  /// 死的（界面上也不显示）。models.dev 也没有这个标注 —— 它不是模型的属性，
  /// 是 Gemini 那套协议的内置工具，所以这一项永远没有自动值。
  final bool? search;

  bool get isEmpty => vision == null && tools == null && search == null;

  ModelCapability copyWith({bool? vision, bool? tools, bool? search}) =>
      ModelCapability(
        vision: vision ?? this.vision,
        tools: tools ?? this.tools,
        search: search ?? this.search,
      );

  /// 只写用户真正表过态的字段。null 的不落盘 —— 落了就分不清
  /// 「显式设成 false」和「没设过」了。
  Map<String, Object?> toJson() => <String, Object?>{
        if (vision != null) 'vision': vision,
        if (tools != null) 'tools': tools,
        if (search != null) 'search': search,
      };

  /// 老版本存下来的记录三个字段都有值，读出来就是三个显式选择 ——
  /// 那是对的：用户当初确实在那个界面上把它们都定过一遍。
  static ModelCapability fromJson(Map<String, Object?> j) => ModelCapability(
        vision: j['vision'] as bool?,
        tools: j['tools'] as bool?,
        search: j['search'] as bool?,
      );

  @override
  bool operator ==(Object other) =>
      other is ModelCapability &&
      other.vision == vision &&
      other.tools == tools &&
      other.search == search;

  @override
  int get hashCode => Object.hash(vision, tools, search);
}

/// 最终生效的能力，以及每一项是**从哪来的**。
///
/// 来源要带出来，界面才能把"官方标注"和"你自己勾的"显示成两回事 ——
/// 一个自动来的开关和一个用户亲手打开的开关长得一样时，用户不敢动它。
class ResolvedCapability {
  const ResolvedCapability({
    required this.vision,
    required this.tools,
    required this.search,
    this.visionFromRegistry = false,
    this.toolsFromRegistry = false,
  });

  final bool vision;
  final bool tools;
  final bool search;

  /// 这一项是自动探测来的（而不是用户勾的、也不是渠道默认值）。
  final bool visionFromRegistry;
  final bool toolsFromRegistry;
}

/// 一个角色最终落到哪儿：**哪个渠道**、**哪个模型**。
///
/// 渠道整个带出来而不是只带 id：调用方要的是地址、密钥、代理、协议这一整套，
/// 只给 id 的话每个调用方都得自己再查一次，而查漏了的表现是"用 A 的地址发
/// B 的模型名"—— 正是这张表要根治的那个毛病。
class ResolvedRole {
  const ResolvedRole({
    required this.role,
    required this.channel,
    required this.model,
    required this.inherited,
  });

  final ModelRole role;
  final Channel channel;
  final String model;

  /// 用户没在表里指派，这是回退来的。
  ///
  /// 界面要把"你指的"和"回退来的"显示成两回事：一条回退来的指派会随着
  /// 当前渠道变来变去，而用户看到一个具体的模型名时不会想到这一点。
  final bool inherited;

  /// 这一条的身份。嵌入用它判断"向量还是不是同一个空间里的"。
  ///
  /// 渠道 id 一起进指纹：同名模型在两家服务商那里是两个空间，只比模型名的话
  /// 换个渠道之后旧向量会被当成还能用，而余弦算出来的是无意义的数。
  String get fingerprint => '${channel.id}::$model';

  @override
  String toString() => '${channel.name} · $model';
}

class Channel {
  /// 稳定 id。改名字不影响它，所以「当前渠道」的指向不会因为改名而丢。
  final String id;
  final String name;

  /// `openAI` 或 `anthropic`。
  final String apiFormat;
  final String baseUrl;
  final String model;
  final String? summaryModel;

  /// 渠道级的视觉默认值。
  ///
  /// 新模型（还没在 [modelCapabilities] 里单独标过的）继承它。留着这个字段而不是
  /// 全面改成按模型：一个渠道下所有模型都能看图是很常见的情况，让用户为每个
  /// 模型各勾一次是没必要的重复劳动。
  final bool visionCapable;

  /// 渠道级的工具默认值。同上。
  final bool toolsCapable;

  /// 渠道级的联网搜索默认值。同上。只对 Gemini 原生协议有意义。
  final bool searchCapable;

  /// 被标星的模型 id。
  ///
  /// 聚合网关一个 key 后面挂着几十上百个模型，而任何一个人真正会用的就那
  /// 三五个。每次换模型都要在一个长列表里滚半天找它，是这个界面最烦人的地方
  /// —— 标星把它们提到最前面。
  ///
  /// **跟着渠道存，不是全局。** 同一个模型名在不同渠道上是不同的东西
  /// （一个免费网关和一个计费官方接口），而"我在这个渠道上常用哪几个"
  /// 恰恰是按渠道分的。
  final Set<String> starredModels;

  /// 模型 id → 能力。只放**被单独标过**的那些，没标的走上面两个默认值。
  ///
  /// 稀疏存而不是把拉回来的模型列表全存一遍：模型列表动辄几十上百条，全存下来
  /// 之后网关下架一个模型，这里就永远留着一条指向不存在模型的记录。
  final Map<String, ModelCapability> modelCapabilities;

  /// 前置多模态用的视觉模型（可选）。
  ///
  /// 对话模型不认图时，先让它把图描述成文字，再把文字交给对话模型。
  /// 和 [summaryModel] 是同一个套路：同一个接入点上换一个更便宜、
  /// 更专门的模型干一件配角的活。空 = 这个渠道不提供视觉。
  final String? visionModel;

  /// 系统提示词怎么送。
  ///
  /// 默认 `role: system`，但**不是所有服务都认**：一批本地推理服务只认
  /// user/assistant 交替，收到 system 直接 400；更糟的一类是收下但完全
  /// 无视 —— 用户看到的是"提示词写了没用"，没有任何错误可查。
  final SystemPromptStyle systemPromptStyle;

  /// Vertex AI 的 GCP 项目 ID 和区域。
  ///
  /// 只有绑了 Google Vertex 账号的渠道用得上。**存下来而不是只存拼好的
  /// baseUrl**：地址是这两个值拼出来的，只存结果的话用户下次进来想改区域，
  /// 就得从一条长 URL 里把它抠出来 —— 而抠错一个字的表现是 404。
  final String? googleProject;
  final String? googleLocation;

  /// `host:port`。空 = 直连。
  final String? proxy;

  /// OAuth 账号绑定。两个都非空时走 OAuth，否则用 API key。
  final String? oauthProviderId;
  final String? oauthAccountId;

  const Channel({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.model,
    this.apiFormat = 'openAI',
    this.summaryModel,
    this.visionCapable = false,
    this.searchCapable = false,
    this.toolsCapable = true,
    this.modelCapabilities = const <String, ModelCapability>{},
    this.starredModels = const <String>{},
    this.visionModel,
    this.systemPromptStyle = SystemPromptStyle.systemRole,
    this.googleProject,
    this.googleLocation,
    this.proxy,
    this.oauthProviderId,
    this.oauthAccountId,
  });

  /// 地址里的 `host[:port]`，认不出来时退回原串。
  ///
  /// 界面上光有渠道名是不够的：名字是用户自己起的，「测试」「新渠道2」
  /// 之类重名或含糊的叫法很常见，而**花的是谁的额度由地址决定**。
  /// 所以凡是要让用户确认"发给谁"的地方，都把 host 一起摆出来。
  String get host {
    final uri = Uri.tryParse(baseUrl);
    if (uri == null || uri.host.isEmpty) return baseUrl;
    return uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
  }

  /// 渠道默认能力。没被单独标过、自动也查不到的模型用它。
  ModelCapability get defaultCapability => ModelCapability(
        vision: visionCapable,
        tools: toolsCapable,
        search: searchCapable,
      );

  /// 用户为某个模型单独设过的那部分。没设过返回空。
  ModelCapability overrideOf(String? model) =>
      modelCapabilities[model?.trim() ?? ''] ?? const ModelCapability();

  /// 某个模型最终生效的能力。
  ///
  /// 优先级：**用户手动设的 > models.dev 的官方标注 > 渠道默认值**。
  ///
  /// 手动排第一是刻意的：自动那份覆盖不全（实测 gemini-2.0-flash 和
  /// gemini-3 都不在表里），而且转售网关的标注时有出入。用户为了让某个
  /// 模型能用而亲手调过的开关，不该被一次后台刷新悄悄改回去。
  ResolvedCapability capabilityOf(String? model, [ModelRegistry? registry]) {
    final manual = overrideOf(model);
    final auto = registry?.lookup(model?.trim() ?? '');

    bool pick(bool? manualValue, bool? autoValue, bool fallback) =>
        manualValue ?? autoValue ?? fallback;

    return ResolvedCapability(
      vision: pick(manual.vision, auto?.vision, visionCapable),
      tools: pick(manual.tools, auto?.tools, toolsCapable),
      // 搜索没有自动值：它不是模型属性，是 Gemini 协议的内置工具。
      search: manual.search ?? searchCapable,
      visionFromRegistry: manual.vision == null && auto?.vision != null,
      toolsFromRegistry: manual.tools == null && auto?.tools != null,
    );
  }

  /// 当前选中模型的能力，**不含自动探测**。
  ///
  /// 带自动值的那份在 [ChannelStore.activeCapability] —— 只有它拿得到
  /// models.dev 那张表。这里留一个是因为「能力跟着模型走、不是跟着渠道走」
  /// 本身就是个需要单独说清楚的性质。
  ResolvedCapability get activeCapability => capabilityOf(model);

  /// 这个模型被单独标过（而不是在吃渠道默认值）。UI 用它区分显示。
  bool hasExplicitCapability(String model) =>
      modelCapabilities.containsKey(model.trim());

  bool isStarred(String model) => starredModels.contains(model.trim());

  /// 能不能拿来做前置多模态。
  ///
  /// 看的是 [visionModel] 而不是对话模型的能力：这个渠道是被**别的**渠道借去
  /// 描述图片的，用的是这里指定的那个专用视觉模型。
  bool get canDescribeImages => (visionModel?.trim().isNotEmpty ?? false);

  bool get usesOAuth =>
      (oauthProviderId?.isNotEmpty ?? false) &&
      (oauthAccountId?.isNotEmpty ?? false);

  /// 只用于聊天界面署名，不暴露 Base URL。
  String get providerLabel {
    switch (oauthProviderId) {
      case 'openai_oauth':
        return 'ChatGPT';
      case 'xai_oauth':
        return 'xAI';
    }
    final inferred = providerLabelForBaseUrl(baseUrl);
    if (inferred != '自定义 API') return inferred;
    final trimmed = name.trim();
    return trimmed.isEmpty || Uri.tryParse(trimmed)?.hasScheme == true
        ? '自定义 API'
        : trimmed;
  }

  static String providerLabelForBaseUrl(String value) {
    final host = Uri.tryParse(value.trim())?.host.toLowerCase() ?? '';
    if (host == 'chatgpt.com') return 'ChatGPT';
    if (host == 'api.openai.com') return 'OpenAI';
    if (host == 'api.anthropic.com') return 'Anthropic';
    if (host.contains('deepseek.com')) return 'DeepSeek';
    if (host.contains('bigmodel.cn')) return 'GLM';
    if (host.contains('moonshot.cn') || host.contains('moonshot.ai')) {
      return 'Kimi';
    }
    if (host.contains('siliconflow')) return '硅基流动';
    if (host == 'api.x.ai') return 'xAI';
    if (host == 'localhost' || host == '127.0.0.1') return '本地模型';
    return '自定义 API';
  }

  /// secure storage 里放这个渠道 API key 的键。
  String get apiKeyStorageKey => '${ChannelStore.keyPrefix}$id';

  Channel copyWith({
    String? name,
    String? apiFormat,
    String? baseUrl,
    String? model,
    String? summaryModel,
    bool? visionCapable,
    bool? searchCapable,
    bool? toolsCapable,
    Map<String, ModelCapability>? modelCapabilities,
    Set<String>? starredModels,
    String? visionModel,
    bool clearVisionModel = false,
    SystemPromptStyle? systemPromptStyle,
    String? googleProject,
    String? googleLocation,
    String? proxy,
    String? oauthProviderId,
    String? oauthAccountId,
    bool clearOAuth = false,
  }) =>
      Channel(
        id: id,
        name: name ?? this.name,
        apiFormat: apiFormat ?? this.apiFormat,
        baseUrl: baseUrl ?? this.baseUrl,
        model: model ?? this.model,
        summaryModel: summaryModel ?? this.summaryModel,
        visionCapable: visionCapable ?? this.visionCapable,
        searchCapable: searchCapable ?? this.searchCapable,
        toolsCapable: toolsCapable ?? this.toolsCapable,
        modelCapabilities: modelCapabilities ?? this.modelCapabilities,
        starredModels: starredModels ?? this.starredModels,
        visionModel:
            clearVisionModel ? null : (visionModel ?? this.visionModel),
        systemPromptStyle: systemPromptStyle ?? this.systemPromptStyle,
        googleProject: googleProject ?? this.googleProject,
        googleLocation: googleLocation ?? this.googleLocation,
        proxy: proxy ?? this.proxy,
        oauthProviderId:
            clearOAuth ? null : (oauthProviderId ?? this.oauthProviderId),
        oauthAccountId:
            clearOAuth ? null : (oauthAccountId ?? this.oauthAccountId),
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'api_format': apiFormat,
        'base_url': baseUrl,
        'model': model,
        'summary_model': summaryModel,
        'vision_capable': visionCapable,
        'search_capable': searchCapable,
        'tools_capable': toolsCapable,
        'model_capabilities': <String, Object?>{
          for (final entry in modelCapabilities.entries)
            entry.key: entry.value.toJson(),
        },
        // 排序后再存：JSON 里的顺序不该跟着 Set 的内部顺序变，
        // 否则每次保存都会产生一份"内容一样但字节不同"的记录。
        'starred_models': starredModels.toList()..sort(),
        'vision_model': visionModel,
        'system_prompt_style': systemPromptStyle.name,
        'google_project': googleProject,
        'google_location': googleLocation,
        'proxy': proxy,
        'oauth_provider': oauthProviderId,
        'oauth_account': oauthAccountId,
      };

  static Channel fromJson(Map<String, Object?> j) => Channel(
        id: j['id']! as String,
        name: (j['name'] as String?) ?? '未命名渠道',
        apiFormat: (j['api_format'] as String?) ?? 'openAI',
        baseUrl: (j['base_url'] as String?) ?? '',
        model: (j['model'] as String?) ?? '',
        summaryModel: j['summary_model'] as String?,
        visionCapable: j['vision_capable'] as bool? ?? false,
        searchCapable: j['search_capable'] as bool? ?? false,
        // 老配置没有这个字段。默认 true 而不是 false —— 升级上来的用户
        // 的终端模式本来是能用的，不该因为加了个开关就集体失效。
        toolsCapable: j['tools_capable'] as bool? ?? true,
        modelCapabilities: _capabilitiesFromJson(j['model_capabilities']),
        starredModels: _starredFromJson(j['starred_models']),
        visionModel: j['vision_model'] as String?,
        systemPromptStyle: SystemPromptStyle.values
                .where((v) => v.name == j['system_prompt_style'])
                .firstOrNull ??
            SystemPromptStyle.systemRole,
        googleProject: j['google_project'] as String?,
        googleLocation: j['google_location'] as String?,
        proxy: j['proxy'] as String?,
        oauthProviderId: j['oauth_provider'] as String?,
        oauthAccountId: j['oauth_account'] as String?,
      );

  /// 老配置没有这个字段，读出来就是空集 —— 一个星都没标过，和以前一样。
  static Set<String> _starredFromJson(Object? raw) {
    if (raw is! List) return const <String>{};
    return <String>{
      for (final entry in raw)
        if (entry is String && entry.trim().isNotEmpty) entry.trim(),
    };
  }

  static Map<String, ModelCapability> _capabilitiesFromJson(Object? raw) {
    if (raw is! Map) return const <String, ModelCapability>{};
    final result = <String, ModelCapability>{};
    for (final entry in raw.entries) {
      final value = entry.value;
      if (value is! Map) continue;
      result[entry.key.toString()] =
          ModelCapability.fromJson(value.cast<String, Object?>());
    }
    return result;
  }
}

class ChannelStore extends ChangeNotifier {
  ChannelStore._(this._channels, this._activeId, this._keys, this._roles,
      this._prefs, this._secure);

  static const keyPrefix = 'burrow.channel.key.';
  static const _listKey = 'burrow.channels';
  static const _activeKey = 'burrow.channels.active';
  static const _rolesKey = 'burrow.llm.modelRoles';

  /// 旧版那份全局嵌入模型：只有模型名，没有渠道。见 [_claimLegacyEmbedding]。
  static const legacyEmbeddingKey = 'burrow.llm.embeddingModel';

  final List<Channel> _channels;
  String? _activeId;

  /// 模型分工表。只放**用户显式指派过**的角色 —— 没指派的走各自的回退
  /// （见 [resolveRole]），存一份"等于回退值"的记录只会让回退跟着旧值冻住。
  final Map<ModelRole, ModelRef> _roles;

  /// 还没认领的旧版嵌入模型。见 [_claimLegacyEmbedding]。
  String? _legacyEmbedding;

  /// models.dev 的能力表。默认空 —— 拉不到 / 还没加载时一切照旧，
  /// 全部退回渠道默认值，和加这个功能之前的行为完全一样。
  ModelRegistry _registry = ModelRegistry.empty();

  set registry(ModelRegistry value) {
    _registry = value;
    // 能力提示变了，界面上那些图标要跟着刷。
    notifyListeners();
  }

  ModelRegistry get registry => _registry;

  /// 某个渠道下某个模型最终生效的能力。
  ResolvedCapability capabilityOf(Channel? channel, String? model) =>
      channel?.capabilityOf(model, _registry) ??
      // 没有渠道时给一份保守默认：不认图（图走前置多模态，最坏多花一次
      // 调用），但认工具 —— 否则终端模式在还没配渠道时就显示成不可用，
      // 那是个会让人以为功能坏了的假象。
      const ResolvedCapability(vision: false, tools: true, search: false);

  /// 当前渠道 + 当前模型的能力。绝大多数调用方要的是这个。
  ResolvedCapability get activeCapability =>
      capabilityOf(active, active?.model);

  /// 渠道 id → API key。启动时一次性读出来，之后在内存里用 ——
  /// 每次请求都去 secure storage 取会明显拖慢首字延迟。
  final Map<String, String> _keys;

  final SharedPreferences? _prefs;
  final FlutterSecureStorage? _secure;

  List<Channel> get channels => List.unmodifiable(_channels);

  Channel? get active {
    for (final c in _channels) {
      if (c.id == _activeId) return c;
    }
    return _channels.isEmpty ? null : _channels.first;
  }

  String? get activeId => active?.id;

  String apiKeyOf(Channel channel) => _keys[channel.id] ?? '';

  Channel? byId(String id) {
    for (final c in _channels) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// 不落盘的实例，只给单测用。
  ///
  /// prefs / secure storage 在单测环境里没有平台通道，而投影和增删改的
  /// 逻辑本身不依赖它们 —— 两个存储字段都是可空的，就是为了这个。
  @visibleForTesting
  factory ChannelStore.forTest({
    List<Channel> channels = const [],
    Map<String, String> keys = const {},
    String? activeId,
    Map<ModelRole, ModelRef> roles = const {},
  }) =>
      ChannelStore._(
        List<Channel>.from(channels),
        activeId,
        Map<String, String>.from(keys),
        Map<ModelRole, ModelRef>.from(roles),
        null,
        null,
      );

  /// 单调递增的后缀。
  ///
  /// 只用时间戳是**会撞的**：`microsecondsSinceEpoch` 的实际精度取决于平台，
  /// Windows 上是毫秒级，同一毫秒内连着生成就是同一个数。撞了的后果是
  /// [upsert] 把前一个渠道整个覆盖掉 —— 不报错，只是少了一个渠道。
  /// 单测里连生成 200 个只得到 3 个不同值，就是这么发现的。
  static int _seq = 0;

  static String newId() {
    _seq++;
    final now = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    return 'ch-$now-${_seq.toRadixString(36)}';
  }

  static Future<ChannelStore> load({
    SharedPreferences? prefs,
    FlutterSecureStorage? secure,
  }) async {
    final p = prefs ?? await SharedPreferences.getInstance();
    final s = secure ?? const FlutterSecureStorage();

    final channels = <Channel>[];
    try {
      final raw = p.getString(_listKey);
      if (raw != null && raw.isNotEmpty) {
        for (final entry in jsonDecode(raw) as List) {
          channels.add(Channel.fromJson(entry as Map<String, Object?>));
        }
      }
    } catch (_) {
      // 列表坏了当成没有渠道。抛出去会让 app 起不来。
    }

    final keys = <String, String>{};
    for (final c in channels) {
      try {
        final k = await s.read(key: c.apiKeyStorageKey);
        if (k != null && k.isNotEmpty) keys[c.id] = k;
      } catch (_) {
        // 单个 key 读不出来只影响那一个渠道。
      }
    }

    final store = ChannelStore._(
      channels,
      p.getString(_activeKey),
      keys,
      _rolesFromJson(p.getString(_rolesKey)),
      p,
      s,
    );
    store._legacyEmbedding = p.getString(legacyEmbeddingKey);
    await store._claimLegacyEmbedding();
    return store;
  }

  static Map<ModelRole, ModelRef> _rolesFromJson(String? raw) {
    if (raw == null || raw.isEmpty) return <ModelRole, ModelRef>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <ModelRole, ModelRef>{};
      final out = <ModelRole, ModelRef>{};
      for (final entry in decoded.entries) {
        final role = ModelRole.fromStorage(entry.key.toString());
        final ref = ModelRef.fromJson(entry.value);
        // 对话模型没有独立存储（它就是当前渠道），读到也丢掉 ——
        // 留着的话表里会有两份"当前用哪个模型"，迟早对不上。
        if (role == null || role == ModelRole.chat || ref == null) continue;
        out[role] = ref;
      }
      return out;
    } catch (_) {
      // 表坏了当成没指派过。全部回退到当前渠道，和加这张表之前的行为一样。
      return <ModelRole, ModelRef>{};
    }
  }

  /// 把旧版那份「只有模型名」的嵌入模型认领成一条完整指派。
  ///
  /// 当初它就是配给当时那个渠道的（请求本来就发往当前渠道），所以认领给
  /// 当前渠道是对的。不认领的话，升级后用户会发现自己配过的嵌入模型不见了
  /// —— 而记忆检索会安静地退回两路词法，没有任何提示。
  ///
  /// 可能这一刻一个渠道都还没有（旧版单份配置要等 [migrateFrom] 才变成渠道），
  /// 那就留着下次再认领，别在这里丢掉。
  Future<void> _claimLegacyEmbedding() async {
    final model = _legacyEmbedding?.trim();
    if (model == null) return;
    final id = active?.id;
    if (id == null) return;
    _legacyEmbedding = null;
    if (model.isNotEmpty && !_roles.containsKey(ModelRole.embedding)) {
      _roles[ModelRole.embedding] = ModelRef(channelId: id, model: model);
      await _persist();
    }
    await _prefs?.remove(legacyEmbeddingKey);
  }

  /// 把旧版的单份配置搬成第一个渠道。
  ///
  /// 不迁的话，升级后用户会看到一个空的渠道列表，而设置其实都还在 prefs 里
  /// —— 那看起来就是"我的配置丢了"。
  Future<void> migrateFrom({
    required LlmConfig config,
    required String providerName,
  }) async {
    if (_channels.isNotEmpty) return;
    if (config.baseUrl.trim().isEmpty && config.model.trim().isEmpty) return;

    final channel = Channel(
      id: newId(),
      name: providerName.isEmpty ? '默认渠道' : providerName,
      apiFormat: config.apiFormat,
      baseUrl: config.baseUrl,
      model: config.model,
      // 空串归一成 null。旧 prefs 里"没填摘要模型"存的是 ''，
      // 带着它迁过来的话，空串就会在新结构里继续传播 ——
      // 而 `?? model` 对空串不成立，那正是之前踩过的坑。
      summaryModel: (config.summaryModel?.trim().isEmpty ?? true)
          ? null
          : config.summaryModel,
    );
    await upsert(channel, apiKey: config.apiKey);
    await setActive(channel.id);
    // 现在才有了第一个渠道，[load] 那次认领没赶上。
    await _claimLegacyEmbedding();
  }

  Future<void> upsert(Channel channel, {String? apiKey}) async {
    final i = _channels.indexWhere((c) => c.id == channel.id);
    if (i < 0) {
      _channels.add(channel);
    } else {
      _channels[i] = channel;
    }
    if (apiKey != null) {
      if (apiKey.isEmpty) {
        _keys.remove(channel.id);
        await _secure?.delete(key: channel.apiKeyStorageKey);
      } else {
        _keys[channel.id] = apiKey;
        await _secure?.write(key: channel.apiKeyStorageKey, value: apiKey);
      }
    }
    _activeId ??= channel.id;
    notifyListeners();
    await _persist();
  }

  Future<void> remove(String id) async {
    _channels.removeWhere((c) => c.id == id);
    _keys.remove(id);
    // 指向它的分工一起清掉。留着的话表里会显示一个存在过的模型名，
    // 而实际上那一路已经不工作了 —— 又是一次"配了但没生效"。
    _roles.removeWhere((_, ref) => ref.channelId == id);
    // 删掉的渠道正好是当前渠道时，落到第一个上而不是留一个悬空指向 ——
    // 悬空的话 active 会静默回退到 first，用户看不出发生了什么。
    if (_activeId == id) {
      _activeId = _channels.isEmpty ? null : _channels.first.id;
    }
    notifyListeners();
    await _secure?.delete(key: '$keyPrefix$id');
    await _persist();
  }

  Future<void> setActive(String id) async {
    if (_activeId == id) return;
    if (byId(id) == null) return;
    _activeId = id;
    notifyListeners();
    await _prefs?.setString(_activeKey, id);
  }

  Future<void> _persist() async {
    final prefs = _prefs;
    if (prefs == null) return;
    await prefs.setString(
        _listKey, jsonEncode(_channels.map((c) => c.toJson()).toList()));
    await prefs.setString(
      _rolesKey,
      jsonEncode(<String, Object?>{
        for (final entry in _roles.entries)
          entry.key.storage: entry.value.toJson(),
      }),
    );
    final id = _activeId;
    if (id != null) await prefs.setString(_activeKey, id);
  }

  // -------------------------------------------------------------------------
  // 模型分工表
  // -------------------------------------------------------------------------

  /// 表里为某个角色写着的那一条。**指向已删渠道时返回 null** ——
  /// 悬空的指派和没指派的区别只在界面上，在运行时它俩都是"这一路不工作"，
  /// 让调用方去分辨只会多出一堆判空。
  ModelRef? refOf(ModelRole role) {
    if (role == ModelRole.chat) {
      final c = active;
      return c == null ? null : ModelRef(channelId: c.id, model: c.model);
    }
    final ref = _roles[role];
    if (ref == null) return null;
    return byId(ref.channelId) == null ? null : ref;
  }

  /// 某个角色最终落到哪个渠道的哪个模型上。null = 这一路现在不工作。
  ///
  /// 回退规则**每个角色不一样**，因为"没指派"对它们的含义本来就不一样：
  ///
  ///   - [ModelRole.chat]：它就是当前渠道，没有别的来源。
  ///   - [ModelRole.embedding]：没指派 = 不启用。向量路本来就是可选的第三路。
  ///   - [ModelRole.vision]：没指派 = 交回给「哪些渠道自己配了视觉模型」那套
  ///     多候选（见 vision.dart）。那套的价值是失败能换下一个，不该因为
  ///     多了一张表就没了。
  ///   - [ModelRole.summary]：没指派 = 当前渠道自己配的摘要模型，再没有就是
  ///     对话模型本身。和加这张表之前完全一样。
  ResolvedRole? resolveRole(ModelRole role) {
    if (role == ModelRole.chat) {
      final c = active;
      final model = c?.model.trim() ?? '';
      if (c == null || model.isEmpty) return null;
      return ResolvedRole(
          role: role, channel: c, model: model, inherited: true);
    }

    final ref = refOf(role);
    if (ref != null) {
      return ResolvedRole(
        role: role,
        channel: byId(ref.channelId)!,
        model: ref.model,
        inherited: false,
      );
    }

    if (role != ModelRole.summary) return null;

    final c = active;
    if (c == null) return null;
    final summary = c.summaryModel?.trim() ?? '';
    final model = summary.isNotEmpty ? summary : c.model.trim();
    if (model.isEmpty) return null;
    return ResolvedRole(role: role, channel: c, model: model, inherited: true);
  }

  /// 标星 / 取消标星。
  ///
  /// 写回渠道而不是另存一份"收藏夹"：星标是渠道的一个属性，删渠道时它跟着
  /// 一起走，不会留下一堆指向不存在渠道的收藏。
  Future<void> toggleStarred(String channelId, String model) async {
    final channel = byId(channelId);
    final id = model.trim();
    if (channel == null || id.isEmpty) return;
    final next = Set<String>.from(channel.starredModels);
    if (!next.remove(id)) next.add(id);
    await upsert(channel.copyWith(starredModels: next));
  }

  /// 指派一个角色。[ref] 为 null = 清掉这一条，回到该角色的回退。
  ///
  /// [ModelRole.chat] 走的是另一条路：它没有独立存储，指派它等于**换当前
  /// 渠道 + 改那个渠道的模型**。顺序不能反 —— 先改模型的话，那个模型会被
  /// 写到用户正想离开的那个渠道上。
  Future<void> assignRole(ModelRole role, ModelRef? ref) async {
    if (role == ModelRole.chat) {
      if (ref == null || byId(ref.channelId) == null) return;
      await setActive(ref.channelId);
      final channel = byId(ref.channelId)!;
      if (channel.model != ref.model) {
        await upsert(channel.copyWith(model: ref.model));
      }
      return;
    }

    final next = ref == null || ref.model.trim().isEmpty
        ? null
        : ModelRef(channelId: ref.channelId, model: ref.model.trim());
    if (next != null && byId(next.channelId) == null) return;
    if (_roles[role] == next) return;

    if (next == null) {
      _roles.remove(role);
    } else {
      _roles[role] = next;
    }
    notifyListeners();
    await _persist();
  }

  /// 当前渠道投影成 [LlmConfig]。
  ///
  /// OAuth 渠道的 apiKey 留空 —— access_token 会过期，抄进配置就等于抄了
  /// 一份马上失效的副本。真正的 token 由 [ConfigurableLlmClient.bearerProvider]
  /// 在每次请求前现取。
  LlmConfig configFor(Channel? channel,
      {double temperature = 0.3,
      bool streamOutput = true,
      bool sendImagesInline = false,
      ThinkingEffort thinkingEffort = ThinkingEffort.auto}) {
    if (channel == null) return LlmConfig.empty;
    return LlmConfig(
      apiFormat: channel.oauthProviderId == 'openai_oauth'
          ? 'chatgptOAuth'
          : channel.apiFormat,
      baseUrl: channel.baseUrl,
      apiKey: channel.usesOAuth ? '' : apiKeyOf(channel),
      model: channel.model,
      summaryModel: channel.summaryModel,
      googleProject: channel.googleProject,
      proxy: channel.proxy,
      systemPromptStyle: channel.systemPromptStyle,
      temperature: temperature,
      streamOutput: streamOutput,
      sendImagesInline: sendImagesInline,
      // 只在原生协议下打开。别的协议上服务端会把 `google_search` 当成一个
      // 未知的函数声明，整轮请求 400 —— 一个开着没用的开关不算无害。
      webSearch: channel.apiFormat == 'geminiNative' &&
          channel.capabilityOf(channel.model, _registry).search,
      thinkingEffort: thinkingEffort,
    );
  }

  /// 一个角色那次请求要用的配置：地址、密钥、代理、协议全跟着**它自己那个
  /// 渠道**走，只把模型换成它的。
  ///
  /// 这个方法就是这张表存在的全部意义 —— 在它之前，配角模型只有一个名字，
  /// 而地址和密钥现取当前渠道的。
  LlmConfig configForRole(ResolvedRole role, {bool sendImagesInline = false}) =>
      configFor(role.channel, sendImagesInline: sendImagesInline).copyWith(
        model: role.model,
        // 摘要请求读的是 summaryModel 那个字段，不一起换的话它会退回渠道
        // 自己配的摘要模型 —— 那就等于这条指派没生效。
        summaryModel: role.model,
      );
}
