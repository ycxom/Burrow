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
            subtitle: '登录后可以绑到渠道上。同一个服务商能登多个账号，'
                '切渠道就等于切账号',
          ),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: <Widget>[
                for (final provider in widget.accounts.providers)
                  ..._providerBlock(provider),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _channelTile(Channel channel, bool active) {
    final t = context.chat;
    final bits = <String>[
      if (channel.apiFormat == 'anthropic') 'Anthropic' else 'OpenAI 兼容',
      if (channel.model.isNotEmpty) channel.model,
      if (channel.usesOAuth)
        'OAuth：${channel.oauthAccountId}'
      else if (widget.channels.apiKeyOf(channel).isEmpty)
        '未填密钥'
      else
        '密钥已保存',
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

  List<Widget> _providerBlock(DeviceFlowProvider provider) {
    final t = context.chat;
    final accounts = widget.accounts.accountsOf(provider.id);
    return <Widget>[
      ListTile(
        dense: true,
        leading: const Icon(Icons.account_circle_outlined),
        title: Text(provider.displayName),
        subtitle: Text(
          accounts.isEmpty ? '未登录' : '${accounts.length} 个账号',
          style: TextStyle(fontSize: 11, color: t.tintTertiary),
        ),
        trailing: TextButton(
          onPressed: () => _login(provider),
          child: Text(accounts.isEmpty ? '登录' : '添加账号'),
        ),
      ),
      for (final account in accounts)
        ListTile(
          dense: true,
          contentPadding: const EdgeInsets.only(left: 56, right: 8),
          leading: const Icon(Icons.check_circle, size: 18),
          title: Text(account.label, style: const TextStyle(fontSize: 13)),
          trailing: IconButton(
            tooltip: '退出这个账号',
            icon: const Icon(Icons.logout, size: 18),
            onPressed: () => _logout(account),
          ),
        ),
      const Divider(height: 1),
    ];
  }

  Future<void> _login(DeviceFlowProvider provider) async {
    final credential = await Navigator.of(context).push<OAuthCredential>(
      MaterialPageRoute(builder: (_) => DeviceLoginPage(provider: provider)),
    );
    if (credential == null || !mounted) return;
    final account = await widget.accounts.save(provider.id, credential);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已登录 ${account.label}')),
    );
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
  late final TextEditingController _proxy;

  late String _apiFormat;
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
    _proxy = TextEditingController(text: c?.proxy ?? '');
    _apiFormat = c?.apiFormat ?? 'openAI';
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
        proxy: normalizeProxy(_proxy.text),
        oauthProviderId: _usesOAuth ? _oauthProviderId : null,
        oauthAccountId: _usesOAuth ? _oauthAccountId : null,
      );

  /// 这次要用的密钥。OAuth 渠道现取 token。
  Future<String> _authFor(Channel draft) async {
    if (!draft.usesOAuth) return _key.text.trim();
    final account =
        widget.accounts.account(draft.oauthProviderId!, draft.oauthAccountId!);
    if (account == null) throw const OAuthException('绑定的账号已经不存在了');
    return widget.accounts.validToken(account);
  }

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
      final models = await fetchModels(
        baseUrl: draft.baseUrl,
        apiKey: auth,
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

  Future<void> _save() async {
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
          SegmentedButton<String>(
            segments: const <ButtonSegment<String>>[
              ButtonSegment(value: 'openAI', label: Text('OpenAI 兼容')),
              ButtonSegment(value: 'anthropic', label: Text('Anthropic')),
            ],
            selected: {_apiFormat},
            onSelectionChanged: (v) => setState(() => _apiFormat = v.first),
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
                      _url.text = provider.apiBaseUrl;
                      _apiFormat = provider.apiFormat;
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
