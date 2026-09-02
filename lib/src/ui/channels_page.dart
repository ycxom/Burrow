/// 渠道管理。
///
/// 一个渠道 = 一个可用的接入点：协议 + 地址 + 认证 + 模型 + 代理。
/// 原来这些散在设置页的几个输入框里，只存一份，换服务商要手动改三处，
/// 改漏一个就是一串对不上号的报错。
///
/// **OAuth 登录也在这里**，而不是单独一页「模型账号」。理由是：一个 OAuth
/// 账号本身没有用处，它只有作为某个渠道的认证方式才有意义。分成两页的话，
/// 用户登录完会停在一个"然后呢"的界面上。同一个服务商可以登录多个账号，
/// 每个账号可以绑到不同的渠道上，切渠道就等于切账号。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../llm/llm_client.dart';
import '../llm/model_catalog.dart';
import '../llm/oauth.dart';
import '../net/proxy_client.dart';
import '../settings/account_store.dart';
import '../llm/system_prompt.dart';
import '../llm/google_oauth.dart';
import '../net/system_browser.dart';
import '../settings/channel_store.dart';
import 'chat_theme.dart';

class ChannelsPage extends StatefulWidget {
  const ChannelsPage({
    required this.channels,
    required this.accounts,
    super.key,
  });

  final ChannelStore channels;
  final AccountStore accounts;

  @override
  State<ChannelsPage> createState() => _ChannelsPageState();
}

class _ChannelsPageState extends State<ChannelsPage> {
  @override
  void initState() {
    super.initState();
    widget.channels.addListener(_refresh);
    widget.accounts.addListener(_refresh);
  }

  @override
  void dispose() {
    widget.channels.removeListener(_refresh);
    widget.accounts.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final t = context.chat;
    final channels = widget.channels.channels;
    final activeId = widget.channels.activeId;

    return Scaffold(
      appBar: AppBar(title: const Text('渠道管理')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
        children: <Widget>[
          if (channels.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('还没有渠道',
                        style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 6),
                    Text(
                      '渠道决定「这次对话发给谁」：协议、地址、认证、模型、代理。'
                      '可以建多个随时切换。',
                      style: TextStyle(fontSize: 12, color: t.tintSecondary),
                    ),
                  ],
                ),
              ),
            )
          else
            Card(
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: <Widget>[
                  for (var i = 0; i < channels.length; i++) ...<Widget>[
                    if (i > 0) const Divider(height: 1),
                    _channelTile(channels[i], channels[i].id == activeId),
                  ],
                ],
              ),
            ),
          const SizedBox(height: 16),
          FilledButton.tonalIcon(
            onPressed: () => _edit(null),
            icon: const Icon(Icons.add),
            label: const Text('新建渠道'),
          ),
          const SizedBox(height: 24),
          const _SectionTitle(
            'OAuth 账号',
            subtitle: '登录后会自动建一个绑好的渠道。点进去可以设登录代理、'
                '换登录方式',
          ),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: <Widget>[
                for (final family in widget.accounts.families)
                  _familyTile(family),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _channelTile(Channel channel, bool active) {
    final t = context.chat;
    final bound = channel.usesOAuth
        ? widget.accounts
            .account(channel.oauthProviderId!, channel.oauthAccountId!)
        : null;
    final quota = channel.usesOAuth ? widget.accounts.quotaFor(channel) : null;
    final bits = <String>[
      geminiProtocolLabel(channel.apiFormat),
      if (channel.model.isNotEmpty) channel.model,
      if (channel.usesOAuth)
        // 邮箱比 accountId 有用得多 —— 后者在没有邮箱声明时是一串数字。
        bound?.label ?? '账号已失效'
      else if (widget.channels.apiKeyOf(channel).isEmpty)
        '未填密钥'
      else
        '密钥已保存',
      // 套餐余量摆在这一行：用户决定"这次用哪个渠道"的时候，
      // 想知道的正是"哪个还有额度"。
      if (quota != null) quota.summary,
      if ((channel.proxy?.isNotEmpty ?? false)) '代理 ${channel.proxy}',
    ];
    return ListTile(
      leading: Icon(
        active ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        color: active ? t.brand : t.tintTertiary,
      ),
      title: Text(channel.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${channel.baseUrl}\n${bits.join(' · ')}',
        style: TextStyle(fontSize: 11, color: t.tintTertiary),
      ),
      isThreeLine: true,
      trailing: IconButton(
        tooltip: '编辑',
        icon: const Icon(Icons.tune),
        onPressed: () => _edit(channel),
      ),
      onTap: () => widget.channels.setActive(channel.id),
    );
  }

  Widget _familyTile(OAuthFamily family) {
    final t = context.chat;
    final bits = <String>[
      family.accounts.isEmpty ? '未登录' : '${family.accounts.length} 个账号',
      if (family.isMultiMode) '${family.modes.length} 种登录方式',
      if (family.proxy != null) '代理 ${family.proxy}',
    ];
    return ListTile(
      leading: const Icon(Icons.account_circle_outlined),
      title: Text(family.name),
      subtitle: Text(
        <String>[
          bits.join(' · '),
          // 已登录的账号直接把邮箱摆在这一行 —— 进子页才看得到的话，
          // "我到底登的是哪个号"就得点两下才知道。
          ...family.accounts.map((a) {
            final quota = widget.accounts.quotaOf(a);
            return quota == null ? a.label : '${a.label} · ${quota.summary}';
          }),
        ].join('\n'),
        style: TextStyle(fontSize: 11, color: t.tintTertiary),
      ),
      isThreeLine: family.accounts.isNotEmpty,
      trailing: const Icon(Icons.chevron_right),
      onTap: () async {
        await Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) => OAuthFamilyPage(
              familyId: family.id,
              accounts: widget.accounts,
              channels: widget.channels,
            ),
          ),
        );
        if (mounted) setState(() {});
      },
    );
  }

  Future<void> _edit(Channel? channel) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ChannelEditPage(
          channels: widget.channels,
          accounts: widget.accounts,
          channel: channel,
        ),
      ),
    );
    if (mounted) setState(() {});
  }
}

// ---------------------------------------------------------------------------
// 编辑一个渠道
// ---------------------------------------------------------------------------

class ChannelEditPage extends StatefulWidget {
  const ChannelEditPage({
    required this.channels,
    required this.accounts,
    this.channel,
    super.key,
  });

  final ChannelStore channels;
  final AccountStore accounts;

  /// null = 新建。
  final Channel? channel;

  @override
  State<ChannelEditPage> createState() => _ChannelEditPageState();
}

class _ChannelEditPageState extends State<ChannelEditPage> {
  late final TextEditingController _name;
  late final TextEditingController _url;
  late final TextEditingController _key;
  late final TextEditingController _model;
  late final TextEditingController _summaryModel;
  late final TextEditingController _visionModel;
  late final TextEditingController _googleProject;
  late final TextEditingController _googleLocation;
  late final TextEditingController _proxy;

  late String _apiFormat;
  late bool _visionCapable;
  late bool _toolsCapable;
  late bool _searchCapable;

  /// 被单独标过能力的模型。没进这个表的模型吃渠道默认值。
  late Map<String, ModelCapability> _modelCapabilities;

  late SystemPromptStyle _systemPromptStyle;
  String? _oauthProviderId;
  String? _oauthAccountId;

  bool _testing = false;
  bool _fetching = false;
  String? _message;
  bool _messageIsError = false;
  List<String> _models = const [];

  bool get _isNew => widget.channel == null;

  @override
  void initState() {
    super.initState();
    final c = widget.channel;
    _name = TextEditingController(text: c?.name ?? '');
    _url = TextEditingController(text: c?.baseUrl ?? '');
    _key = TextEditingController(
        text: c == null ? '' : widget.channels.apiKeyOf(c));
    _model = TextEditingController(text: c?.model ?? '');
    _summaryModel = TextEditingController(text: c?.summaryModel ?? '');
    _visionModel = TextEditingController(text: c?.visionModel ?? '');
    _googleProject = TextEditingController(text: c?.googleProject ?? '');
    _googleLocation =
        TextEditingController(text: c?.googleLocation ?? 'us-central1');
    _proxy = TextEditingController(text: c?.proxy ?? '');
    _apiFormat = c?.apiFormat ?? 'openAI';
    _visionCapable = c?.visionCapable ?? false;
    _toolsCapable = c?.toolsCapable ?? true;
    _searchCapable = c?.searchCapable ?? false;
    _modelCapabilities = Map<String, ModelCapability>.of(
      c?.modelCapabilities ?? const <String, ModelCapability>{},
    );
    _systemPromptStyle = c?.systemPromptStyle ?? SystemPromptStyle.systemRole;
    _oauthProviderId = c?.oauthProviderId;
    _oauthAccountId = c?.oauthAccountId;
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _key.dispose();
    _model.dispose();
    _summaryModel.dispose();
    _visionModel.dispose();
    _googleProject.dispose();
    _googleLocation.dispose();
    _proxy.dispose();
    super.dispose();
  }

  bool get _usesOAuth =>
      (_oauthProviderId?.isNotEmpty ?? false) &&
      (_oauthAccountId?.isNotEmpty ?? false);

  Channel _draft() => Channel(
        id: widget.channel?.id ?? ChannelStore.newId(),
        name: _name.text.trim().isEmpty
            ? (_url.text.trim().isEmpty ? '新渠道' : _url.text.trim())
            : _name.text.trim(),
        apiFormat: _apiFormat,
        baseUrl: _url.text.trim(),
        model: _model.text.trim(),
        summaryModel: _summaryModel.text.trim().isEmpty
            ? null
            : _summaryModel.text.trim(),
        googleProject: _googleProject.text.trim().isEmpty
            ? null
            : _googleProject.text.trim(),
        googleLocation: _googleLocation.text.trim().isEmpty
            ? null
            : _googleLocation.text.trim(),
        visionCapable: _visionCapable,
        toolsCapable: _toolsCapable,
        searchCapable: _searchCapable,
        modelCapabilities: _modelCapabilities,
        systemPromptStyle: _systemPromptStyle,
        visionModel:
            _visionModel.text.trim().isEmpty ? null : _visionModel.text.trim(),
        proxy: normalizeProxy(_proxy.text),
        oauthProviderId: _usesOAuth ? _oauthProviderId : null,
        oauthAccountId: _usesOAuth ? _oauthAccountId : null,
      );

  /// 这次要用的密钥。OAuth 渠道现取 token。
  Future<String> _authFor(Channel draft) =>
      widget.accounts.authFor(draft, apiKey: _key.text.trim());

  void _say(String message, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _message = message;
      _messageIsError = error;
    });
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _message = null;
    });
    final draft = _draft();
    // 用 draft 自己的代理造一个临时客户端 —— 拿当前渠道的客户端去测另一个
    // 渠道的代理，测的就不是用户正在填的那份配置。
    final client = ConfigurableLlmClient(
      httpClient: buildHttpClient(proxy: draft.proxy),
    );
    try {
      final auth = await _authFor(draft);
      client.chatGptAccountIdProvider =
          () async => widget.accounts.credentialFor(draft)?.accountId;
      await client.testConnection(
        widget.channels.configFor(draft).copyWith(apiKey: auth),
      );
      _say('连接正常');
    } catch (e) {
      _say('$e', error: true);
    } finally {
      client.cancel();
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _fetchModels() async {
    setState(() {
      _fetching = true;
      _message = null;
    });
    final draft = _draft();
    final client = buildHttpClient(proxy: draft.proxy);
    try {
      final auth = await _authFor(draft);
      final models = draft.oauthProviderId == 'openai_oauth'
          ? await fetchChatGptOAuthModels(
              accessToken: auth,
              accountId: widget.accounts.credentialFor(draft)?.accountId ?? '',
              client: client,
            )
          : await fetchModels(
              baseUrl: draft.baseUrl,
              apiKey: auth,
              apiFormat: draft.apiFormat,
              client: client,
            );
      if (mounted) setState(() => _models = models.map((m) => m.id).toList());
      _say('拿到 ${_models.length} 个模型');
    } catch (e) {
      _say('$e', error: true);
    } finally {
      client.close();
      if (mounted) setState(() => _fetching = false);
    }
  }

  /// 「按模型覆盖」列表。
  ///
  /// 列的是**当前模型 + 已经标过的 + 拉回来的列表**这三者的并集：
  ///
  ///   - 当前模型永远在，因为它是马上要用的那个，也是最可能需要改的那个；
  ///   - 已标过的永远在，否则用户标完一个冷门模型、下次进来发现它不见了，
  ///     会以为设置没保存（其实只是模型列表还没拉）；
  ///   - 拉回来的那些让用户不用手打模型名。
  Widget _buildModelCapabilities(ChatTokens t) {
    final current = _model.text.trim();
    final names = <String>{
      if (current.isNotEmpty) current,
      ..._modelCapabilities.keys,
      ..._models,
    }.toList()
      ..sort();

    if (names.isEmpty) {
      return Text(
        '还没有模型。先在上面填一个，或者点「拉取模型」。',
        style: TextStyle(fontSize: 11, color: t.tintTertiary),
      );
    }

    final fallback = ModelCapability(
      vision: _visionCapable,
      tools: _toolsCapable,
      search: _searchCapable,
    );

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: t.borderPrimary),
        borderRadius: BorderRadius.circular(ChatShape.radiusLg),
      ),
      child: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    '按模型覆盖',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: t.tintSecondary,
                    ),
                  ),
                ),
                Text(
                    _apiFormat == 'geminiNative' ? '看图 / 工具 / 搜索' : '看图 / 工具',
                    style: TextStyle(fontSize: 11, color: t.tintTertiary)),
              ],
            ),
          ),
          // 模型多的时候（聚合网关能有几百个）不铺开，否则这一页就没法用了。
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 260),
            child: ListView.separated(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: names.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final name = names[i];
                final explicit = _modelCapabilities.containsKey(name);
                final cap = _modelCapabilities[name] ?? fallback;
                final isCurrent = name == current;
                return Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 6, 4),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: isCurrent
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                                color: isCurrent ? t.brand : t.tintPrimary,
                              ),
                            ),
                            // 说清它现在是"跟着默认值"还是"单独标过"——
                            // 两者看起来一样，但改默认值时只有前者会跟着变。
                            Text(
                              explicit
                                  ? (isCurrent ? '当前模型 · 已单独设置' : '已单独设置')
                                  : (isCurrent ? '当前模型 · 跟随默认' : '跟随默认'),
                              style: TextStyle(
                                fontSize: 10.5,
                                color: t.tintTertiary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      _CapabilityToggle(
                        icon: Icons.visibility_outlined,
                        tooltip: '能直接看图',
                        value: cap.vision,
                        dimmed: !explicit,
                        onChanged: (v) => _setCapability(
                          name,
                          cap.copyWith(vision: v),
                          fallback,
                        ),
                      ),
                      _CapabilityToggle(
                        icon: Icons.build_outlined,
                        tooltip: '支持工具调用',
                        value: cap.tools,
                        dimmed: !explicit,
                        onChanged: (v) => _setCapability(
                          name,
                          cap.copyWith(tools: v),
                          fallback,
                        ),
                      ),
                      if (_apiFormat == 'geminiNative')
                        _CapabilityToggle(
                          icon: Icons.travel_explore_outlined,
                          tooltip: '可以联网搜索',
                          value: cap.search,
                          dimmed: !explicit,
                          onChanged: (v) => _setCapability(
                            name,
                            cap.copyWith(search: v),
                            fallback,
                          ),
                        ),
                      IconButton(
                        tooltip: explicit ? '改回跟随默认' : '当前就是跟随默认',
                        visualDensity: VisualDensity.compact,
                        icon: Icon(
                          Icons.settings_backup_restore,
                          size: 18,
                          color: explicit ? t.tintSecondary : t.tintTertiary,
                        ),
                        onPressed: explicit
                            ? () => setState(
                                  () => _modelCapabilities.remove(name),
                                )
                            : null,
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 改一个模型的能力。和默认值一致时**移除**这条记录而不是存一份相同的值 ——
  /// 存下来的话，以后改渠道默认值这个模型不会跟着变，而用户并没有表达过
  /// "这个模型要钉死在这个值上"的意思。
  void _setCapability(
    String model,
    ModelCapability next,
    ModelCapability fallback,
  ) {
    setState(() {
      if (next == fallback) {
        _modelCapabilities.remove(model);
      } else {
        _modelCapabilities[model] = next;
      }
    });
  }

  Future<void> _pickVisionModel() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SizedBox(
        height: MediaQuery.of(ctx).size.height * 0.6,
        child: ListView(
          children: <Widget>[
            for (final m in _models)
              ListTile(
                dense: true,
                title: Text(m, style: const TextStyle(fontSize: 14)),
                onTap: () => Navigator.pop(ctx, m),
              ),
          ],
        ),
      ),
    );
    if (picked != null) setState(() => _visionModel.text = picked);
  }

  Future<void> _save() async {
    // Gemini 那个主机上，给定协议之后只有一个正确路径，而错的写法有好几种、
    // 失败方式还各不相同（404 / 401）。与其保存一个必然连不上的地址，
    // 不如当场改对 —— 并且**说出来**，不做无声修改。
    final geminiFix = geminiBaseUrlFix(_url.text, apiFormat: _apiFormat);
    if (geminiFix != null) {
      setState(() => _url.text = geminiFix);
      _say('Base URL 已自动改成「${geminiProtocolLabel(_apiFormat)}」的地址：'
          '$geminiFix');
    }

    final draft = _draft();
    if (draft.baseUrl.isEmpty) {
      _say('Base URL 不能为空', error: true);
      return;
    }
    // 填了代理但格式不对时明确拦下来。静默当成"没配代理"的话，
    // 用户会以为代理生效了，然后对着一堆超时找原因。
    if (_proxy.text.trim().isNotEmpty && draft.proxy == null) {
      _say('代理地址要写成 host:port，例如 127.0.0.1:7890', error: true);
      return;
    }
    await widget.channels.upsert(
      draft,
      apiKey: draft.usesOAuth ? '' : _key.text.trim(),
    );
    if (_isNew) await widget.channels.setActive(draft.id);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final channel = widget.channel;
    if (channel == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除渠道「${channel.name}」？'),
        content: const Text('保存的密钥会一起删除。OAuth 账号本身不受影响。'),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
                foregroundColor: Theme.of(ctx).colorScheme.error),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.channels.remove(channel.id);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.chat;
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? '新建渠道' : '编辑渠道'),
        actions: <Widget>[
          if (!_isNew)
            IconButton(
              tooltip: '删除',
              onPressed: _delete,
              icon: const Icon(Icons.delete_outline),
            ),
          TextButton(onPressed: _save, child: const Text('保存')),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: <Widget>[
          TextField(
            controller: _name,
            decoration: const InputDecoration(
              labelText: '名称',
              helperText: '只是给你自己看的，例如「公司网关」「我的 ChatGPT」',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          // 四段在窄屏上排不下，SegmentedButton 自己不会滚 —— 不套一层的话
          // 是一条 RenderFlex overflow 的黄条，而不是"挤一挤"。
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SegmentedButton<String>(
              segments: const <ButtonSegment<String>>[
                ButtonSegment(value: 'openAI', label: Text('OpenAI 兼容')),
                ButtonSegment(value: 'anthropic', label: Text('Anthropic')),
                // 想用 Gemini API 的人会来点这一个 —— 所以它必须是**原生层**。
                // 原生层比兼容层多一样东西：`google_search` 联网搜索。
                ButtonSegment(value: 'geminiNative', label: Text('Gemini')),
                // 这个协议只服务 Code Assist 那个内部接口（请求体带
                // `{model, project, request}` 包装、要先打 `:loadCodeAssist`），
                // 拿它连 Gemini API 一定不通。**所以它不能也叫「Gemini」** ——
                // 曾经就是这么被点错的。
                //
                // 摆出来也不是让人手选的：绑定 Code Assist 账号时会自动切过去，
                // 而 SegmentedButton 的选中值不在 segments 里会直接抛。
                ButtonSegment(value: 'gemini', label: Text('Code Assist')),
              ],
              selected: {_apiFormat},
              onSelectionChanged: (v) => setState(() {
                _apiFormat = v.first;
                // 两层 Gemini 的地址不一样，切协议时顺手改对。留着旧地址的话
                // 下一步一定是 401 或 404，而那两个都指不向"协议换了"。
                final fix = geminiBaseUrlFix(_url.text, apiFormat: _apiFormat);
                if (fix != null) {
                  _url.text = fix;
                  _say('Base URL 已跟着协议改成：$fix');
                }
              }),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _url,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Base URL',
              helperText: '填到服务根地址即可，/v1 会自动补',
              prefixIcon: Icon(Icons.link),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 20),
          const _SectionTitle('认证'),
          _authSection(),
          if (_isVertex) _vertexSection(),
          const SizedBox(height: 20),
          const _SectionTitle('代理', subtitle: '只对这个渠道生效。留空 = 直连'),
          TextField(
            controller: _proxy,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'HTTP 代理',
              hintText: '127.0.0.1:7890',
              helperText: '只支持 HTTP CONNECT 代理；带不带 http:// 都行',
              prefixIcon: Icon(Icons.vpn_lock_outlined),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 20),
          const _SectionTitle('模型'),
          TextField(
            controller: _model,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: '对话模型',
              prefixIcon: Icon(Icons.auto_awesome_outlined),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              OutlinedButton.icon(
                onPressed: _fetching ? null : _fetchModels,
                icon: _fetching
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.cloud_download_outlined, size: 18),
                label: Text(_fetching ? '获取中…' : '从服务端获取'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _testing ? null : _test,
                icon: _testing
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.wifi_tethering, size: 18),
                label: Text(_testing ? '测试中…' : '测试连接'),
              ),
            ],
          ),
          if (_models.isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                for (final m in _models.take(40))
                  ActionChip(
                    label: Text(m, style: const TextStyle(fontSize: 12)),
                    onPressed: () => setState(() => _model.text = m),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          TextField(
            controller: _summaryModel,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: '摘要模型（可选）',
              helperText: '留空 = 用对话模型。长对话压缩可以换个更便宜的',
              prefixIcon: Icon(Icons.compress),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 24),
          const _SectionTitle(
            '系统提示词',
            subtitle: '不认 role: system 的服务改用下面两种写法',
          ),
          RadioGroup<SystemPromptStyle>(
            groupValue: _systemPromptStyle,
            onChanged: (v) {
              if (v != null) setState(() => _systemPromptStyle = v);
            },
            child: Column(
              children: <Widget>[
                for (final entry in _promptStyleLabels.entries)
                  RadioListTile<SystemPromptStyle>(
                    contentPadding: EdgeInsets.zero,
                    value: entry.key,
                    title: Text(entry.value.label,
                        style: const TextStyle(fontSize: 14)),
                    subtitle: Text(
                      entry.value.hint,
                      style: TextStyle(fontSize: 11, color: t.tintTertiary),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          const _SectionTitle(
            '模型能力',
            subtitle: '这个渠道下的模型各自认不认图、认不认工具',
          ),
          Text(
            // 这是纯文本控件，写 markdown 的星号会原样显示出来。
            '下面两个是默认值，适用于没有单独标过的模型。'
            '一个渠道下模型能力不一致时（聚合网关基本都是这样），'
            '在「按模型覆盖」里单独标。',
            style: TextStyle(fontSize: 11, color: t.tintTertiary),
          ),
          const SizedBox(height: 4),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _visionCapable,
            onChanged: (v) => setState(() => _visionCapable = v),
            title: const Text('默认能直接看图'),
            // 手动勾而不是自动判断：聚合网关返回的模型 id 五花八门，
            // 靠名字猜"是不是视觉模型"猜错的代价是一次 400，或者更糟 ——
            // 模型收到图却当没看见，照常答一段，而用户以为它看过了。
            subtitle: Text(
              '勾上之后图会直接进请求体。不确定就别勾，'
              '让它走下面的视觉模型更稳',
              style: TextStyle(fontSize: 11, color: t.tintTertiary),
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _toolsCapable,
            onChanged: (v) => setState(() => _toolsCapable = v),
            title: const Text('默认支持工具调用'),
            subtitle: Text(
              '终端模式要靠它。关掉之后这个渠道的模型开不了终端模式 —— '
              '不支持工具的模型收到 tools 会 400，或者装作执行了命令',
              style: TextStyle(fontSize: 11, color: t.tintTertiary),
            ),
          ),
          // 只在原生协议下出现。别处显示它就是在骗人：兼容层根本没有这个能力，
          // 打开了也只会让请求 400。
          if (_apiFormat == 'geminiNative')
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _searchCapable,
              onChanged: (v) => setState(() => _searchCapable = v),
              title: const Text('默认可以联网搜索'),
              subtitle: Text(
                '模型自己决定搜什么、自己读结果，回答末尾会附上来源。'
                '按次计费。Gemini 3 之前的模型开了它就不能同时用工具调用',
                style: TextStyle(fontSize: 11, color: t.tintTertiary),
              ),
            ),
          const SizedBox(height: 12),
          _buildModelCapabilities(t),
          const SizedBox(height: 24),
          const _SectionTitle(
            '图片',
            subtitle: '不认图的模型也能收到图 —— 先让视觉模型描述一遍',
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _visionModel,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: '视觉模型（可选）',
              helperText: '填了之后，这个渠道就能被拿来把图描述成文字，'
                  '给任何不认图的模型用',
              prefixIcon: const Icon(Icons.visibility_outlined),
              border: const OutlineInputBorder(),
              // 模型列表已经拉过的话，直接从里面挑，省得手打。
              suffixIcon: _models.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '从已获取的列表里选',
                      icon: const Icon(Icons.list),
                      onPressed: _pickVisionModel,
                    ),
            ),
          ),
          if (_message != null) ...<Widget>[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _messageIsError ? t.bgErrorSecondary : t.bgSecondary,
                borderRadius: BorderRadius.circular(ChatShape.radiusLg),
                border: _messageIsError ? Border.all(color: t.tintError) : null,
              ),
              child: SelectableText(
                _message!,
                style: TextStyle(fontSize: 12, color: t.tintPrimary),
              ),
            ),
          ],
        ],
      ),
    );
  }

  bool get _isVertex => _oauthProviderId == GoogleVertexFlow.providerId;

  String _vertexUrl() {
    final project = _googleProject.text.trim();
    if (project.isEmpty) return '';
    return GoogleVertexFlow.vertexBaseUrl(
      project: project,
      location: _googleLocation.text.trim(),
    );
  }

  /// Vertex 专属的两个字段。只在绑了 Vertex 账号时出现 —— 对别的渠道它们
  /// 没有意义，摆出来只会让人以为哪里没填完。
  Widget _vertexSection() {
    final t = context.chat;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SizedBox(height: 16),
        const _SectionTitle(
          'Vertex AI',
          subtitle: '接口地址由项目和区域拼出来，不用自己写',
        ),
        TextField(
          controller: _googleProject,
          autocorrect: false,
          onChanged: (_) => setState(() => _url.text = _vertexUrl()),
          decoration: const InputDecoration(
            labelText: '项目 ID',
            helperText: 'GCP 项目 ID（不是项目编号），要开通计费和 Vertex AI API',
            prefixIcon: Icon(Icons.cloud_outlined),
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _googleLocation,
          autocorrect: false,
          onChanged: (_) => setState(() => _url.text = _vertexUrl()),
          decoration: const InputDecoration(
            labelText: '区域',
            helperText: '例如 us-central1、asia-northeast1；填 global 走全局端点',
            prefixIcon: Icon(Icons.public),
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _vertexUrl().isEmpty
              ? '填了项目 ID 之后这里会显示算出来的接口地址。'
              : '接口地址：${_vertexUrl()}',
          style: TextStyle(fontSize: 11, color: t.tintTertiary),
        ),
        const SizedBox(height: 8),
        Text(
          '模型名要带 google/ 前缀，例如 google/gemini-2.5-flash。'
          'Vertex 的 OpenAI 兼容端点就是这么认模型的。',
          style: TextStyle(fontSize: 11, color: t.tintTertiary),
        ),
      ],
    );
  }

  Widget _authSection() {
    final t = context.chat;
    final accounts = widget.accounts.accounts;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (accounts.isNotEmpty) ...<Widget>[
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              ChoiceChip(
                label: const Text('用 API Key'),
                selected: !_usesOAuth,
                onSelected: (_) => setState(() {
                  _oauthProviderId = null;
                  _oauthAccountId = null;
                }),
              ),
              for (final a in accounts)
                ChoiceChip(
                  avatar: const Icon(Icons.account_circle, size: 16),
                  label: Text(a.label, style: const TextStyle(fontSize: 12)),
                  selected: _usesOAuth &&
                      _oauthProviderId == a.providerId &&
                      _oauthAccountId == a.id,
                  onSelected: (_) => setState(() {
                    _oauthProviderId = a.providerId;
                    _oauthAccountId = a.id;
                    // 顺手把地址填成这个服务商的。用户绑了账号却还指着
                    // 上一家的地址，是最容易犯又最难看出来的错。
                    final provider = widget.accounts.providerById(a.providerId);
                    if (provider != null) {
                      _apiFormat = provider.apiFormat;
                      // Vertex 的地址依赖项目和区域，登录时还不知道，
                      // provider 给的是空串 —— 由下面那两个字段算。
                      _url.text = provider.apiBaseUrl.isNotEmpty
                          ? provider.apiBaseUrl
                          : _vertexUrl();
                    }
                  }),
                ),
            ],
          ),
          const SizedBox(height: 12),
        ],
        if (_usesOAuth)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: t.bgBrandSecondary,
              borderRadius: BorderRadius.circular(ChatShape.radiusLg),
            ),
            child: Text(
              '这个渠道用 OAuth 账号 $_oauthAccountId 认证。'
              '令牌会在过期前自动刷新，不需要填密钥。',
              style: TextStyle(fontSize: 12, color: t.tintSecondary),
            ),
          )
        else
          TextField(
            controller: _key,
            autocorrect: false,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'API Key',
              helperText: '保存在设备安全存储里，不进明文配置',
              prefixIcon: Icon(Icons.key),
              border: OutlineInputBorder(),
            ),
          ),
        if (accounts.isEmpty) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            '也可以在渠道列表底部登录 OAuth 账号，然后回来绑定。',
            style: TextStyle(fontSize: 11, color: t.tintTertiary),
          ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 设备码登录
// ---------------------------------------------------------------------------

class DeviceLoginPage extends StatefulWidget {
  final DeviceFlowProvider provider;
  const DeviceLoginPage({required this.provider, super.key});

  @override
  State<DeviceLoginPage> createState() => _DeviceLoginPageState();
}

class _DeviceLoginPageState extends State<DeviceLoginPage> {
  DeviceCodeGrant? _grant;
  String _status = '正在获取登录码…';
  Object? _error;
  StreamSubscription<PollResult>? _polling;
  final _cancel = Completer<void>();

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    // 页面关掉就停止轮询。不停的话它会一直打服务端，直到码过期 ——
    // 用户已经离开这个界面了，那些请求没有任何人在等。
    if (!_cancel.isCompleted) _cancel.complete();
    _polling?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final grant = await widget.provider.start();
      if (!mounted) return;
      setState(() {
        _grant = grant;
        _status = '等待在浏览器里确认…';
      });
      _polling = pollUntilDone(widget.provider, grant, cancel: _cancel.future)
          .listen(_onPoll, onError: (Object e) {
        if (mounted) setState(() => _error = e);
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  void _onPoll(PollResult result) {
    if (!mounted) return;
    switch (result.status) {
      case PollStatus.pending:
        break;
      case PollStatus.authorized:
        Navigator.of(context).pop(result.credential);
      case PollStatus.denied:
        setState(() => _status = '授权被拒绝');
      case PollStatus.expired:
        setState(() => _status = '登录码已过期，请重新开始');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.chat;
    final grant = _grant;

    return Scaffold(
      appBar: AppBar(title: Text('登录 ${widget.provider.displayName}')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: t.bgErrorSecondary,
                  borderRadius: BorderRadius.circular(ChatShape.radiusLg),
                  border: Border.all(color: t.tintError),
                ),
                child: Text('$_error',
                    style: TextStyle(fontSize: 12, color: t.tintPrimary)),
              ),
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: () {
                  setState(() {
                    _error = null;
                    _status = '正在获取登录码…';
                  });
                  _start();
                },
                child: const Text('重试'),
              ),
            ] else if (grant == null) ...[
              const Center(child: CircularProgressIndicator()),
              const SizedBox(height: 16),
              Text(_status,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: t.tintTertiary)),
            ] else ...[
              Text('1. 在浏览器里打开',
                  style: TextStyle(fontSize: 13, color: t.tintSecondary)),
              const SizedBox(height: 6),
              SelectableText(
                grant.verificationUri,
                style: TextStyle(
                    fontSize: 13, color: t.brand, fontFamily: 'monospace'),
              ),
              const SizedBox(height: 24),
              Text('2. 输入这个登录码',
                  style: TextStyle(fontSize: 13, color: t.tintSecondary)),
              const SizedBox(height: 10),
              // 码要足够大。用户是抄到另一台设备上的，字小一步就会抄错，
              // 而错了的反馈要隔十几秒才从网页那边回来。
              InkWell(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: grant.userCode));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text('登录码已复制'),
                        duration: Duration(milliseconds: 900)),
                  );
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  decoration: BoxDecoration(
                    color: t.bgSecondary,
                    borderRadius: BorderRadius.circular(ChatShape.radiusLg),
                    border: Border.all(color: t.borderPrimary),
                  ),
                  child: Column(
                    children: [
                      Text(
                        grant.userCode,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 30,
                          fontFamily: 'monospace',
                          letterSpacing: 4,
                          fontWeight: FontWeight.w600,
                          color: t.tintPrimary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text('点击复制',
                          style:
                              TextStyle(fontSize: 11, color: t.tintTertiary)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 28),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: t.tintTertiary),
                  ),
                  const SizedBox(width: 10),
                  Text(_status,
                      style: TextStyle(fontSize: 13, color: t.tintTertiary)),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

/// 一个能力开关。跟随默认值时画得淡一点 —— 它显示的是继承来的值，
/// 和用户亲手标过的不该长得一模一样。
class _CapabilityToggle extends StatelessWidget {
  const _CapabilityToggle({
    required this.icon,
    required this.tooltip,
    required this.value,
    required this.dimmed,
    required this.onChanged,
  });

  final IconData icon;
  final String tooltip;
  final bool value;
  final bool dimmed;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = context.chat;
    final color = value
        ? (dimmed ? t.brand.withValues(alpha: 0.45) : t.brand)
        : t.tintTertiary.withValues(alpha: dimmed ? 0.4 : 0.8);
    return Tooltip(
      message: '$tooltip（${value ? '开' : '关'}）',
      child: IconButton(
        visualDensity: VisualDensity.compact,
        icon: Icon(icon, size: 20, color: color),
        onPressed: () => onChanged(!value),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title, {this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final t = context.chat;
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 8, 2, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(title,
              style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600, color: t.brand)),
          if (subtitle != null) ...<Widget>[
            const SizedBox(height: 2),
            Text(subtitle!,
                style: TextStyle(fontSize: 11, color: t.tintTertiary)),
          ],
        ],
      ),
    );
  }
}

/// 三种写法的说明。
///
/// 「完全不发」的说明里明说**会丢内容** —— 另外两种都只是换个位置，
/// 只有这一种是真的把提示词扔了，用户得知道自己在选什么。
const _promptStyleLabels = <SystemPromptStyle, ({String label, String hint})>{
  SystemPromptStyle.systemRole: (
    label: '正常发 system 消息',
    hint: '绝大多数服务都这样，先试这个',
  ),
  SystemPromptStyle.firstUserMessage: (
    label: '拼进第一条用户消息',
    hint: '给不认 system 角色的服务用。内容一个字不少，只是换了位置',
  ),
  SystemPromptStyle.omit: (
    label: '完全不发',
    hint: '给明确要求不带 system 的模型用。这一项会真的丢掉提示词',
  ),
};


/// 回跳登录页。
///
/// 和 [DeviceLoginPage] 的形状完全不同：那边是"显示一串码、轮询等结果"，
/// 这边是"把浏览器拉起来、本地端口等回跳"。用户在这一页几乎不用做任何事 ——
/// 页面存在的意义是**在浏览器没起来时给出退路**，以及让用户看得见"还在等"。
class RedirectLoginPage extends StatefulWidget {
  const RedirectLoginPage({required this.provider, super.key});

  final RedirectFlowProvider provider;

  @override
  State<RedirectLoginPage> createState() => _RedirectLoginPageState();
}

class _RedirectLoginPageState extends State<RedirectLoginPage> {
  RedirectAuthSession? _session;
  Object? _error;
  String _status = '正在准备登录…';

  /// 浏览器有没有成功拉起来。没起来时页面要把网址亮出来让用户自己复制 ——
  /// 回跳目标是本机回环地址，用户在**这台设备**上用任何浏览器打开都能回来。
  bool _browserOpened = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    // 页面关掉就必须收掉那个监听端口。留着的话，一个谁都能连的本机端口会
    // 一直挂到进程退出，而它本来只该活到这一次回跳为止。
    unawaited(_session?.cancel());
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final session = await widget.provider.start();
      if (!mounted) {
        await session.cancel();
        return;
      }
      setState(() {
        _session = session;
        _status = '正在打开浏览器…';
      });

      // 先接结果再开浏览器：反过来的话，一个极快的回跳可能在监听建立之前
      // 就到了。
      unawaited(session.result.then((credential) {
        if (mounted) Navigator.of(context).pop(credential);
      }).catchError((Object e) {
        if (mounted) setState(() => _error = e);
      }));

      final opened = await SystemBrowser.open(session.authorizationUrl);
      if (!mounted) return;
      setState(() {
        _browserOpened = opened;
        _status = opened
            ? '已在浏览器里打开，授权完成后会自动回到这里'
            : '没能自动打开浏览器，请手动复制下面的地址';
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _retry() async {
    await _session?.cancel();
    if (!mounted) return;
    setState(() {
      _session = null;
      _error = null;
      _browserOpened = false;
      _status = '正在准备登录…';
    });
    await _start();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.chat;
    final session = _session;

    return Scaffold(
      appBar: AppBar(title: Text('登录 ${widget.provider.displayName}')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (_error != null) ...<Widget>[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: t.bgErrorSecondary,
                  borderRadius: BorderRadius.circular(ChatShape.radiusLg),
                  border: Border.all(color: t.tintError),
                ),
                child: Text('$_error',
                    style: TextStyle(fontSize: 12, color: t.tintPrimary)),
              ),
              const SizedBox(height: 16),
              OutlinedButton(onPressed: _retry, child: const Text('重试')),
            ] else if (session == null) ...<Widget>[
              const Center(child: CircularProgressIndicator()),
              const SizedBox(height: 16),
              Text(_status,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: t.tintTertiary)),
            ] else ...<Widget>[
              Row(
                children: <Widget>[
                  const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(_status,
                        style:
                            TextStyle(fontSize: 13, color: t.tintSecondary)),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              // 浏览器起来了就不摆这一大段地址 —— 正常路径上用户不需要看它。
              // 没起来才是它的用武之地。
              if (!_browserOpened) ...<Widget>[
                Text('在这台设备的浏览器里打开：',
                    style: TextStyle(fontSize: 13, color: t.tintSecondary)),
                const SizedBox(height: 6),
                SelectableText(
                  session.authorizationUrl,
                  style: TextStyle(fontSize: 11, color: t.brand),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('复制地址'),
                  onPressed: () async {
                    await Clipboard.setData(
                      ClipboardData(text: session.authorizationUrl),
                    );
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('地址已复制')),
                      );
                    }
                  },
                ),
                const SizedBox(height: 8),
                Text(
                  '必须用这台设备上的浏览器 —— 授权完成后要回跳到本机的一个'
                  '临时端口，换设备回不来。',
                  style: TextStyle(fontSize: 11, color: t.tintTertiary),
                ),
              ] else
                OutlinedButton.icon(
                  icon: const Icon(Icons.open_in_browser, size: 18),
                  label: const Text('重新打开浏览器'),
                  onPressed: () =>
                      SystemBrowser.open(session.authorizationUrl),
                ),
              const Spacer(),
              Text(
                '授权完成后浏览器会显示一句"登录成功"，这一页会自动关掉。'
                '五分钟内没完成的话本地端口会自动收掉，需要重新开始。',
                style: TextStyle(fontSize: 11, color: t.tintTertiary),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 一个登录方式家族的子页
// ---------------------------------------------------------------------------

/// 一家服务商的登录页：账号、登录方式、代理，都在这里。
///
/// ## 为什么要有这一页
///
/// 原来每家在渠道页上占一行，行里只有一个「登录」按钮。加上代理、多登录方式
/// 和自定义客户端之后，那一行装不下了 —— 而把它们全摊在渠道页上，会让一个
/// 本来是"看看我有哪些渠道"的页面变成一张表单墙。
///
/// Google 尤其明显：它有两种登录方式，并排摆两条「Google 账号」会让人以为
/// 要登两次。收进来之后外面只有一行，进来再选。
class OAuthFamilyPage extends StatefulWidget {
  const OAuthFamilyPage({
    required this.familyId,
    required this.accounts,
    required this.channels,
    super.key,
  });

  final String familyId;
  final AccountStore accounts;
  final ChannelStore channels;

  @override
  State<OAuthFamilyPage> createState() => _OAuthFamilyPageState();
}

class _OAuthFamilyPageState extends State<OAuthFamilyPage> {
  late final TextEditingController _proxy;

  /// 正在查额度的账号。查询要发网络请求，不给反馈的话用户会以为点了没用。
  final Set<String> _refreshing = <String>{};

  @override
  void initState() {
    super.initState();
    _proxy = TextEditingController(
      text: widget.accounts.proxyOf(widget.familyId) ?? '',
    );
    widget.accounts.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.accounts.removeListener(_onChanged);
    _proxy.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  OAuthFamily? get _family {
    for (final family in widget.accounts.families) {
      if (family.id == widget.familyId) return family;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.chat;
    final family = _family;
    if (family == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('登录')),
        body: const Center(child: Text('这个服务商已经不存在了')),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(family.name)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
        children: <Widget>[
          const _SectionTitle('已登录的账号', subtitle: '登录后会自动建一个绑好的渠道'),
          Card(
            clipBehavior: Clip.antiAlias,
            child: family.accounts.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      '还没有登录。用下面任一种方式登录一次即可。',
                      style: TextStyle(fontSize: 12, color: t.tintSecondary),
                    ),
                  )
                : Column(
                    children: <Widget>[
                      for (var i = 0; i < family.accounts.length; i++) ...<Widget>[
                        if (i > 0) const Divider(height: 1),
                        _accountTile(family, family.accounts[i]),
                      ],
                    ],
                  ),
          ),
          const SizedBox(height: 24),
          _SectionTitle(
            family.isMultiMode ? '登录方式' : '登录',
            subtitle: family.isMultiMode
                ? '同一个 Google 账号，登完之后打的是两个不同的后端'
                : null,
          ),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: <Widget>[
                for (var i = 0; i < family.modes.length; i++) ...<Widget>[
                  if (i > 0) const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.login),
                    title: Text(family.modes[i].modeName),
                    subtitle: Text(
                      family.modes[i].hint,
                      style: TextStyle(fontSize: 11, color: t.tintTertiary),
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _login(family.modes[i]),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 24),
          const _SectionTitle(
            '登录代理',
            subtitle: '只作用于登录本身，和渠道上那个代理是两条独立的路',
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  TextField(
                    controller: _proxy,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: '代理地址',
                      hintText: '127.0.0.1:7890',
                      helperText: '留空 = 直连。只支持 HTTP CONNECT 代理',
                      prefixIcon: Icon(Icons.vpn_lock_outlined),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    // 这一段是这个功能存在的全部理由，值得写清楚。
                    '登录要打的是认证域名（accounts.google.com、auth.openai.com），'
                    '它们和模型接口经常不在同一张网里 —— 自建网关在内网直连，'
                    '但认证域名要翻出去。所以这里单独配。',
                    style: TextStyle(fontSize: 11, color: t.tintTertiary),
                  ),
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.tonal(
                      onPressed: _saveProxy,
                      child: const Text('保存代理'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (family.id == googleFamily) ...<Widget>[
            const SizedBox(height: 24),
            const _SectionTitle(
              'OAuth 客户端',
              subtitle: 'Google 不发公共客户端，默认借用 gemini-cli 的公开凭据',
            ),
            Card(child: _googleClientTile()),
          ],
        ],
      ),
    );
  }

  Widget _accountTile(OAuthFamily family, OAuthAccount account) {
    final t = context.chat;
    final quota = widget.accounts.quotaOf(account);
    final mode = widget.accounts.providerById(account.providerId);
    final busy = _refreshing.contains(account.storageKey);

    return ListTile(
      leading: const Icon(Icons.check_circle, size: 20),
      title: Text(account.label, style: const TextStyle(fontSize: 14)),
      subtitle: Text(
        <String>[
          // 档位名和模式名撞车时只留一个 —— 两行一模一样的字看起来像渲染坏了。
          if (family.isMultiMode &&
              mode != null &&
              mode.modeName != quota?.plan)
            mode.modeName,
          if (quota == null)
            '套餐未知，点右边刷新'
          else ...<String>[
            quota.summary,
            if (quota.detail != null) quota.detail!,
            // 新鲜度必须说出来：一个三天前的余量显示得像实时的，
            // 比不显示更误导。
            if (quota.fetchedAt != null) '更新于 ${_ago(quota.fetchedAt!)}',
          ],
        ].join('\n'),
        style: TextStyle(fontSize: 11, color: t.tintTertiary),
      ),
      isThreeLine: true,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          IconButton(
            tooltip: '刷新套餐余量',
            icon: busy
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh, size: 18),
            onPressed: busy ? null : () => _refreshQuota(account),
          ),
          IconButton(
            tooltip: '退出这个账号',
            icon: const Icon(Icons.logout, size: 18),
            onPressed: () => _logout(account),
          ),
        ],
      ),
    );
  }

  static String _ago(DateTime at) {
    final delta = DateTime.now().difference(at);
    if (delta.inMinutes < 1) return '刚刚';
    if (delta.inHours < 1) return '${delta.inMinutes} 分钟前';
    if (delta.inDays < 1) return '${delta.inHours} 小时前';
    return '${delta.inDays} 天前';
  }

  Future<void> _refreshQuota(OAuthAccount account) async {
    setState(() => _refreshing.add(account.storageKey));
    try {
      final quota = await widget.accounts.refreshQuota(account);
      if (!mounted) return;
      if (quota == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('这家没有可查的额度接口')),
        );
      }
    } finally {
      if (mounted) setState(() => _refreshing.remove(account.storageKey));
    }
  }

  Future<void> _saveProxy() async {
    final raw = _proxy.text.trim();
    if (raw.isNotEmpty && normalizeProxy(raw) == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('代理地址要写成 host:port，例如 127.0.0.1:7890')),
      );
      return;
    }
    await widget.accounts.setProxy(widget.familyId, raw.isEmpty ? null : raw);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(raw.isEmpty ? '登录已改为直连' : '登录将走 $raw')),
    );
  }

  Future<void> _login(OAuthProvider provider) async {
    final credential = await Navigator.of(context).push<OAuthCredential>(
      MaterialPageRoute(
        builder: (_) => provider is RedirectFlowProvider
            ? RedirectLoginPage(provider: provider)
            : DeviceLoginPage(provider: provider as DeviceFlowProvider),
      ),
    );
    if (credential == null || !mounted) return;

    final account = await widget.accounts.save(provider.id, credential);
    final channel = await _ensureChannel(provider, account);
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已登录 ${account.label}，渠道「${channel.name}」已就绪'),
      ),
    );
    // 额度是附加信息，登录不该等它。在后台查，回来自己刷新界面。
    unawaited(widget.accounts.refreshQuota(account));
  }

  /// 登录完自动准备好一个绑着这个账号的渠道。
  ///
  /// 不建的话，用户登录成功后会停在一个"然后呢"的界面上 —— 他还得自己去
  /// 新建渠道、挑协议、填地址、再回来绑账号，而这四步的答案全都是登录时
  /// 就已经知道的。
  ///
  /// 已经有绑着同一个账号的渠道就不重复建，只把它设为当前 —— 重复登录
  /// （比如为了刷新过期的令牌）不该每次多出一个渠道。
  Future<Channel> _ensureChannel(
    OAuthProvider provider,
    OAuthAccount account,
  ) async {
    for (final existing in widget.channels.channels) {
      if (existing.oauthProviderId == provider.id &&
          existing.oauthAccountId == account.id) {
        await widget.channels.setActive(existing.id);
        return existing;
      }
    }

    final channel = Channel(
      id: ChannelStore.newId(),
      name: provider.familyName == provider.modeName
          ? '${provider.familyName} · ${account.label}'
          : '${provider.modeName} · ${account.label}',
      apiFormat: provider.apiFormat,
      baseUrl: provider.apiBaseUrl,
      model: '',
      // 登录走了代理，模型接口多半也要走 —— 它们通常是同一家的域名。
      // 猜错的代价只是用户去渠道里改一行，而猜对省掉的是一次"为什么登录
      // 成功了却连不上模型"的排查。
      proxy: widget.accounts.proxyOf(provider.family),
      oauthProviderId: provider.id,
      oauthAccountId: account.id,
    );
    await widget.channels.upsert(channel, apiKey: '');
    await widget.channels.setActive(channel.id);
    return channel;
  }

  Future<void> _logout(OAuthAccount account) async {
    // 绑着这个账号的渠道会失去认证。先说清楚是哪几个，
    // 而不是让用户之后对着一串 401 猜。
    final bound = widget.channels.channels
        .where((c) =>
            c.oauthProviderId == account.providerId &&
            c.oauthAccountId == account.id)
        .toList();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('退出 ${account.label}？'),
        content: Text(
          bound.isEmpty
              ? '本地保存的令牌会被删除。'
              : '本地保存的令牌会被删除。\n\n'
                  '这些渠道正在用它，退出后会没有认证：\n'
                  '${bound.map((c) => '· ${c.name}').join('\n')}',
        ),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
                foregroundColor: Theme.of(ctx).colorScheme.error),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (ok == true) await widget.accounts.remove(account);
  }

  /// Google 的 OAuth 客户端凭据入口。
  ///
  /// 默认用的是随 gemini-cli 一起公开分发的那份。这件事必须写在界面上 ——
  /// 它不是实现细节：Google 随时可以吊销它，届时所有人的 Google 登录同时失效，
  /// 而用户需要知道该去哪儿自救。
  Widget _googleClientTile() {
    final t = context.chat;
    final custom = widget.accounts.googleClient;
    return ListTile(
      leading: const Icon(Icons.vpn_key_outlined),
      title: const Text('客户端凭据'),
      subtitle: Text(
        custom == null
            ? '正在用内嵌的 gemini-cli 公开凭据。Google 若吊销它，登录会失效'
            : '自定义：${_maskClientId(custom.id)}',
        style: TextStyle(fontSize: 11, color: t.tintTertiary),
      ),
      trailing: TextButton(
        onPressed: _editGoogleClient,
        child: Text(custom == null ? '换成自己的' : '修改'),
      ),
    );
  }

  static String _maskClientId(String id) {
    final head = id.split('-').first;
    return head.length >= 6 ? '$head-…' : '$id…';
  }

  Future<void> _editGoogleClient() async {
    final current = widget.accounts.googleClient;
    final idController = TextEditingController(text: current?.id ?? '');
    final secretController = TextEditingController(text: current?.secret ?? '');

    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Google OAuth 客户端'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const Text(
                '在 Google Cloud Console → API 和服务 → 凭据里新建一个'
                '「桌面应用」类型的 OAuth 客户端，把两个串填进来。\n\n'
                '留空并保存 = 恢复使用内嵌凭据。',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: idController,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Client ID',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: secretController,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Client secret',
                  helperText: '桌面应用类型即使用了 PKCE 也仍然要带 secret',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'cancel'),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'save'),
            child: const Text('保存'),
          ),
        ],
      ),
    );

    final id = idController.text.trim();
    final secret = secretController.text.trim();
    idController.dispose();
    secretController.dispose();
    if (action != 'save' || !mounted) return;

    final affected = await widget.accounts.setGoogleClient(
      id.isEmpty ? null : GoogleOAuthClient(id: id, secret: secret),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          affected == 0
              ? (id.isEmpty ? '已恢复内嵌凭据' : '已保存自定义客户端')
              // 换客户端不会让现有 access_token 立刻失效，但下一次刷新会拿
              // 新客户端去刷一个旧客户端签发的 refresh_token —— 那必然失败。
              : '已保存。已登录的 $affected 个 Google 账号需要重新登录一次，'
                  '否则令牌过期后刷新会失败',
        ),
        duration: const Duration(seconds: 6),
      ),
    );
  }
}
