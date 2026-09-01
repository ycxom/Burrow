/// 模型账号：用设备码登录 ChatGPT / Grok 订阅。
///
/// 登录界面就是一件事：**把码显示得足够大**。用户要把它抄到另一台设备
/// 或者另一个 app 里，字小一点这一步就会出错，而出错的反馈要等到
/// 网页那边报"码不对"，中间隔了十几秒。所以用等宽大字号 + 一键复制。
///
/// 轮询状态一直显示在下面。不显示的话，用户在网页点完确认回到这里，
/// 看到的是一个没有任何变化的界面，会以为流程断了 —— 实际上只是
/// 还没到下一次轮询。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../llm/oauth.dart';
import '../settings/account_store.dart';
import 'chat_theme.dart';

class AccountsPage extends StatefulWidget {
  final AccountStore store;
  const AccountsPage({super.key, required this.store});

  @override
  State<AccountsPage> createState() => _AccountsPageState();
}

class _AccountsPageState extends State<AccountsPage> {
  @override
  Widget build(BuildContext context) {
    final t = context.chat;
    return Scaffold(
      appBar: AppBar(title: const Text('模型账号')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            '用订阅账号登录，不需要 API key。登录后在设置里把服务商切到对应的一项即可。',
            style: TextStyle(fontSize: 12, color: t.tintTertiary),
          ),
          const SizedBox(height: 16),
          for (final provider in widget.store.providers)
            _AccountCard(
              provider: provider,
              credential: widget.store.credentialFor(provider.id),
              onLogin: () => _login(provider),
              onLogout: () async {
                await widget.store.remove(provider.id);
                if (mounted) setState(() {});
              },
            ),
        ],
      ),
    );
  }

  Future<void> _login(DeviceFlowProvider provider) async {
    final credential = await Navigator.of(context).push<OAuthCredential>(
      MaterialPageRoute<OAuthCredential>(
        builder: (_) => _DeviceLoginPage(provider: provider),
      ),
    );
    if (credential == null) return;
    await widget.store.save(provider.id, credential);
    if (mounted) setState(() {});
  }
}

class _AccountCard extends StatelessWidget {
  final DeviceFlowProvider provider;
  final OAuthCredential? credential;
  final VoidCallback onLogin;
  final VoidCallback onLogout;

  const _AccountCard({
    required this.provider,
    required this.credential,
    required this.onLogin,
    required this.onLogout,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.chat;
    final signedIn = credential != null;
    return Card(
      elevation: 0,
      color: t.bgSecondary,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(ChatShape.radiusLg),
      ),
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
        leading: Icon(
          signedIn ? Icons.check_circle : Icons.account_circle_outlined,
          color: signedIn ? t.tintSuccess : t.tintTertiary,
        ),
        title: Text(provider.displayName,
            style: TextStyle(fontSize: 15, color: t.tintPrimary)),
        subtitle: Text(
          signedIn
              // 显示邮箱而不是"已登录"：多账号切换时那是唯一能分辨的东西。
              ? (credential!.email ?? '已登录')
              : provider.apiBaseUrl,
          style: TextStyle(fontSize: 11, color: t.tintTertiary),
        ),
        trailing: TextButton(
          onPressed: signedIn ? onLogout : onLogin,
          child: Text(signedIn ? '退出' : '登录'),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _DeviceLoginPage extends StatefulWidget {
  final DeviceFlowProvider provider;
  const _DeviceLoginPage({required this.provider});

  @override
  State<_DeviceLoginPage> createState() => _DeviceLoginPageState();
}

class _DeviceLoginPageState extends State<_DeviceLoginPage> {
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
