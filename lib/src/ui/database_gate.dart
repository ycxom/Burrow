/// 开库之前那道门：拿到数据库密钥。
///
/// ## 三种进来的方式
///
///   - **首次运行**：还没有密码，让用户定一个。
///   - **日常启动**：密钥缓存在系统安全存储里，这道门根本不出现。
///   - **换了手机**：备份把数据库和盐带过来了，但安全存储那份缓存**不跟着
///     备份走**（它由系统硬件保管）。所以新机器上会问一次密码 —— 输对了，
///     同样的密码 + 同样的盐派生出同一把钥匙，几个月的对话原封不动。
///
/// 最后一条就是选这套方案的全部理由：**备份里只有密文和盐**，谁拿到备份都
/// 打不开；而换手机只要记得那个密码，数据一条不少。
library;

import 'package:flutter/material.dart';

import '../data/db_cipher.dart';

/// 这道门是来干嘛的。
enum DatabaseGateMode {
  /// 第一次用，定一个密码。
  create,

  /// 已经有密码了，输一次。
  unlock,
}

class DatabaseGateApp extends StatelessWidget {
  const DatabaseGateApp({
    required this.mode,
    required this.salt,
    required this.check,
    required this.onUnlocked,
    required this.onReset,
    super.key,
  });

  final DatabaseGateMode mode;
  final String salt;

  /// 一小段已知明文的密文，用来判断密码对不对。create 模式下是 null。
  final String? check;

  /// 拿到钥匙了。参数是派生出来的那把。
  final void Function(DbCipher cipher) onUnlocked;

  /// 用户选择放弃数据、从空库重来。
  final Future<void> Function() onReset;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Burrow',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true),
        home: _GateScreen(
          mode: mode,
          salt: salt,
          check: check,
          onUnlocked: onUnlocked,
          onReset: onReset,
        ),
      );
}

class _GateScreen extends StatefulWidget {
  const _GateScreen({
    required this.mode,
    required this.salt,
    required this.check,
    required this.onUnlocked,
    required this.onReset,
  });

  final DatabaseGateMode mode;
  final String salt;
  final String? check;
  final void Function(DbCipher cipher) onUnlocked;
  final Future<void> Function() onReset;

  @override
  State<_GateScreen> createState() => _GateScreenState();
}

class _GateScreenState extends State<_GateScreen> {
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  String? _error;
  bool _busy = false;

  bool get _creating => widget.mode == DatabaseGateMode.create;

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final password = _password.text;
    if (password.length < 6) {
      setState(() => _error = '密码至少 6 位');
      return;
    }
    if (_creating && password != _confirm.text) {
      setState(() => _error = '两次输入不一样');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    // 派生要跑十二万轮 HMAC，几百毫秒。放在这里等是可以接受的 ——
    // 一天只碰到一次，而这几百毫秒同时也是别人离线撞密码的成本。
    await Future<void>.delayed(const Duration(milliseconds: 16));
    final cipher = DbCipher(DbCipher.deriveKey(password, widget.salt));
    if (!_creating && !DbKeyCheck.verify(cipher, widget.check)) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '密码不对';
        _password.clear();
      });
      return;
    }
    widget.onUnlocked(cipher);
  }

  /// 忘了密码 = 数据打不开了。
  ///
  /// 这条路必须存在，但要说得足够重：密钥只从密码来，这正是"拿到备份也打不开"
  /// 的代价。没有后门，也没有找回 —— 有的话备份就不安全了。
  Future<void> _reset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('忘了密码？'),
        content: const Text(
          '密钥只从这个密码派生，没有别的地方存着它 —— 这正是"拿到备份也打不开"'
          '的代价。忘了就没有找回的办法。\n\n'
          '继续的话会清空已有的对话记录，从一个空库重新开始。'
          '渠道、皮肤这些设置不受影响。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('再想想'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
                foregroundColor: Theme.of(ctx).colorScheme.error),
            child: const Text('清空并重来'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    await widget.onReset();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Icon(Icons.shield_outlined, size: 46, color: scheme.primary),
                const SizedBox(height: 18),
                Text(
                  _creating ? '给对话记录设个密码' : '输入数据库密码',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 10),
                Text(
                  _creating
                      ? '对话记录会用它加密。备份和换手机都带得走 —— '
                          '到了新机器上再输一次这个密码就能接着读，'
                          '而光有备份的人打不开。'
                      : '这台设备上没有缓存的密钥。换过手机、或者重装过，'
                          '都会走到这里。',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 22),
                TextField(
                  controller: _password,
                  obscureText: true,
                  autofocus: true,
                  onSubmitted: (_) => _busy ? null : _submit(),
                  decoration: const InputDecoration(
                    labelText: '密码',
                    border: OutlineInputBorder(),
                  ),
                ),
                if (_creating) ...<Widget>[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _confirm,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: '再输一次',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
                if (_error case final text?) ...<Widget>[
                  const SizedBox(height: 10),
                  Text(text,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.error, fontSize: 12.5)),
                ],
                const SizedBox(height: 18),
                FilledButton(
                  onPressed: _busy ? null : _submit,
                  child: Text(_busy
                      ? '正在派生密钥…'
                      : _creating
                          ? '设好了，进入'
                          : '解锁'),
                ),
                if (!_creating) ...<Widget>[
                  const SizedBox(height: 4),
                  TextButton(
                    onPressed: _busy ? null : _reset,
                    child: const Text('忘了密码'),
                  ),
                ],
                const SizedBox(height: 14),
                Text(
                  _creating
                      ? '记不住就写下来。没有后门，也没有找回 —— 有的话备份就不安全了。'
                      : '',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
