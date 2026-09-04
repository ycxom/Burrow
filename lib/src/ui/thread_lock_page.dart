/// 会话锁的三个界面：设锁、开锁、找回。
///
/// 三个都在这一个文件里，因为它们共用同一套措辞和同一条底线 ——
/// **这道锁不另建一把钥匙**（见 thread_lock.dart 开头）。措辞散到三个文件
/// 里，迟早有一处会把它说成"这段对话被单独加密了"，而那正是最不该说错的
/// 地方：说错了，用户会按一个不存在的保证来决定往里面放什么。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../net/device_auth.dart';
import '../settings/thread_lock.dart';
import 'chat_theme.dart';

/// 给一个会话设锁：定密码 + 选三道安全问题。
///
/// **内置题一个输入框都没有**，勾上就行 —— 答案在找回时现从会话里取。
/// 让用户此刻编一个答案，是在要求他记住一个刚编出来的东西，而找回发生在
/// 几个月后。真正忘不掉的是这个会话本身。
class ThreadLockSetupPage extends StatefulWidget {
  const ThreadLockSetupPage({
    required this.threadTitle,
    required this.facts,
    super.key,
  });

  final String threadTitle;

  /// 这个会话里现成的事实。决定哪几道题**答得上**，答不上的不提供。
  final ThreadFacts facts;

  @override
  State<ThreadLockSetupPage> createState() => _ThreadLockSetupPageState();
}

class _ThreadLockSetupPageState extends State<ThreadLockSetupPage> {
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _customPrompt = TextEditingController();
  final _customAnswer = TextEditingController();

  final Set<LockQuestion> _picked = <LockQuestion>{};
  final List<LockChallenge> _custom = <LockChallenge>[];
  String? _error;
  bool _busy = false;

  int get _total => _picked.length + _custom.length;

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    _customPrompt.dispose();
    _customAnswer.dispose();
    super.dispose();
  }

  void _addCustom() {
    final prompt = _customPrompt.text.trim();
    final answer = _customAnswer.text.trim();
    if (prompt.isEmpty || answer.isEmpty) {
      setState(() => _error = '自定义问题的题面和答案都要填');
      return;
    }
    setState(() {
      _custom.add(LockChallenge.custom(prompt: prompt, answer: answer));
      _customPrompt.clear();
      _customAnswer.clear();
      _error = null;
    });
  }

  Future<void> _save() async {
    if (_password.text.length < 4) {
      setState(() => _error = '密码至少 4 位');
      return;
    }
    if (_password.text != _confirm.text) {
      setState(() => _error = '两次输入不一样');
      return;
    }
    if (_total != lockQuestionCount) {
      setState(() => _error = '要选够 $lockQuestionCount 道安全问题（现在 $_total 道）');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final salt = newSalt();
    final lock = ThreadLock(
      salt: salt,
      hash: derivePasscode(_password.text, salt),
      challenges: <LockChallenge>[
        for (final question in _picked) LockChallenge.builtIn(question),
        ..._custom,
      ],
    );
    if (mounted) Navigator.of(context).pop(lock);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.chat;
    final available = widget.facts.available;
    return Scaffold(
      appBar: AppBar(title: const Text('给这个会话加锁')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: <Widget>[
          _Disclaimer(),
          const SizedBox(height: 16),
          Text('「${widget.threadTitle}」',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            obscureText: true,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: '密码',
              helperText: '进这个会话要输它。和手机锁屏是两回事',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _confirm,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: '再输一次',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 24),
          Text('安全问题（$_total / $lockQuestionCount）',
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            '忘了密码时，验证手机锁屏 + 答对这几道就能重设。'
            '这些题的答案就在这段对话里，**不用你现在填** —— 勾上就行。',
            style: TextStyle(fontSize: 11.5, color: t.tintTertiary),
          ),
          const SizedBox(height: 8),
          for (final question in available)
            CheckboxListTile(
              value: _picked.contains(question),
              onChanged: (on) => setState(() {
                if (on ?? false) {
                  _picked.add(question);
                } else {
                  _picked.remove(question);
                }
              }),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              dense: true,
              title:
                  Text(question.label, style: const TextStyle(fontSize: 13.5)),
              subtitle:
                  Text(question.hint, style: const TextStyle(fontSize: 11)),
            ),
          if (available.length < LockQuestion.values.length)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 4),
              child: Text(
                // 答不上的题不提供 —— 一道"标准答案是空"的题，
                // 任何人留空都能过。
                '有几道题这个会话答不上（比如没设过 AI 人格），没有列出来。',
                style: TextStyle(fontSize: 11, color: t.tintTertiary),
              ),
            ),
          const Divider(height: 28),
          Text('自己出一道', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            '内置的几道不够用、或者你想问一件只有自己知道的事，就自己写。'
            '这一类的答案会**原样存下来**（模糊匹配要拿原文比）——'
            '跟着数据库一起加密，但知道 app 密码的人读得到，别拿它当保险箱。',
            style: TextStyle(fontSize: 11.5, color: t.tintTertiary),
          ),
          const SizedBox(height: 10),
          for (final challenge in _custom)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.help_outline, size: 18),
              title:
                  Text(challenge.prompt, style: const TextStyle(fontSize: 13)),
              subtitle: Text('答案：${challenge.answer}',
                  style: const TextStyle(fontSize: 11)),
              trailing: IconButton(
                icon: const Icon(Icons.close_rounded, size: 18),
                onPressed: () => setState(() => _custom.remove(challenge)),
              ),
            ),
          TextField(
            controller: _customPrompt,
            decoration: const InputDecoration(
              labelText: '问题',
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _customAnswer,
            decoration: const InputDecoration(
              labelText: '答案',
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _addCustom,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('加进去'),
            ),
          ),
          if (_error case final text?) ...<Widget>[
            const SizedBox(height: 8),
            Text(text, style: TextStyle(color: t.tintError, fontSize: 12.5)),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _save,
            child: Text(_busy ? '设置中…' : '加锁'),
          ),
        ],
      ),
    );
  }
}

/// 开锁。返回 true 表示放行。
class ThreadUnlockPage extends StatefulWidget {
  const ThreadUnlockPage({
    required this.threadTitle,
    required this.lock,
    required this.facts,
    required this.modelPool,
    required this.onPasswordReset,
    super.key,
  });

  final String threadTitle;
  final ThreadLock lock;

  /// 找回那一页要用：标准答案现从会话里取，不落盘。
  final ThreadFacts facts;

  /// 模型那道选择题的干扰项来源。
  final List<String> modelPool;

  /// 找回成功、用户重设了密码之后把新锁存回去。
  final Future<void> Function(ThreadLock lock) onPasswordReset;

  @override
  State<ThreadUnlockPage> createState() => _ThreadUnlockPageState();
}

class _ThreadUnlockPageState extends State<ThreadUnlockPage> {
  final _password = TextEditingController();
  String? _error;
  bool _busy = false;

  /// 连着输错几次。
  ///
  /// 不做锁定，只做**递增的等待**：锁定会把一个忘了密码的主人挡在门外，
  /// 而等待只让穷举变得不划算。
  int _failures = 0;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    if (_failures > 2) {
      await Future<void>.delayed(Duration(milliseconds: 300 * _failures));
    }
    final ok = checkPasscode(widget.lock, _password.text);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = false;
      _failures++;
      _error = '密码不对';
      _password.clear();
    });
    HapticFeedback.heavyImpact();
  }

  Future<void> _recover() async {
    final reset = await Navigator.of(context).push<ThreadLock>(
      MaterialPageRoute<ThreadLock>(
        builder: (_) => ThreadLockRecoveryPage(
          lock: widget.lock,
          facts: widget.facts,
          modelPool: widget.modelPool,
        ),
      ),
    );
    if (reset == null || !mounted) return;
    await widget.onPasswordReset(reset);
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.chat;
    return Scaffold(
      appBar: AppBar(title: const Text('私密对话')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.lock_outline_rounded, size: 44, color: t.brand),
              const SizedBox(height: 16),
              Text(
                widget.threadTitle,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 20),
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
              if (_error case final text?) ...<Widget>[
                const SizedBox(height: 10),
                Text(text,
                    style: TextStyle(color: t.tintError, fontSize: 12.5)),
              ],
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _busy ? null : _submit,
                  child: Text(_busy ? '校验中…' : '进入'),
                ),
              ),
              const SizedBox(height: 4),
              TextButton(onPressed: _recover, child: const Text('忘了密码')),
            ],
          ),
        ),
      ),
    );
  }
}

/// 找回：先过手机锁屏，再答对三道题，然后重设密码。
class ThreadLockRecoveryPage extends StatefulWidget {
  const ThreadLockRecoveryPage({
    required this.lock,
    required this.facts,
    required this.modelPool,
    super.key,
  });

  final ThreadLock lock;

  /// 标准答案现从会话里取，不落盘。见 [ThreadFacts]。
  final ThreadFacts facts;

  /// 拿来做干扰项的模型名（用户其它渠道上的那些）。
  final List<String> modelPool;

  @override
  State<ThreadLockRecoveryPage> createState() => _ThreadLockRecoveryPageState();
}

class _ThreadLockRecoveryPageState extends State<ThreadLockRecoveryPage> {
  /// 下标 → 选择题选中的那个选项。
  final Map<int, String> _picked = <int, String>{};

  /// 下标 → 填空题的输入框。
  final Map<int, TextEditingController> _fields =
      <int, TextEditingController>{};

  /// 选择题的选项。**只算一次** —— 每次 build 都重新洗牌的话，
  /// 选项会在用户眼皮底下跳来跳去。
  final Map<int, List<String>> _choices = <int, List<String>>{};

  final _password = TextEditingController();
  final _confirm = TextEditingController();

  /// 手机锁屏那一关过了没有。
  ///
  /// 摆在最前面：它是这条路上唯一一个**不靠记忆**的关卡，先过它能挡掉
  /// "捡到手机的人对着安全问题瞎猜"这一整类。
  bool _deviceOk = false;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    for (var i = 0; i < widget.lock.challenges.length; i++) {
      if (widget.lock.challenges[i].isMultipleChoice) {
        _choices[i] = modelChoices(widget.facts.model, widget.modelPool);
      } else {
        _fields[i] = TextEditingController();
      }
    }
  }

  @override
  void dispose() {
    for (final controller in _fields.values) {
      controller.dispose();
    }
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _verifyDevice() async {
    setState(() => _busy = true);
    final result = await DeviceAuth.confirm('验证身份以找回会话密码');
    if (!mounted) return;
    setState(() {
      _busy = false;
      _deviceOk = result == DeviceAuthResult.ok;
      _error = switch (result) {
        DeviceAuthResult.ok => null,
        DeviceAuthResult.refused => '没有通过验证',
        DeviceAuthResult.unavailable => '这台手机没有设锁屏。'
            '先到系统设置里加一个 PIN 或图案，才能用这条找回路径。',
      };
    });
  }

  Future<void> _reset() async {
    if (_password.text.length < 4) {
      setState(() => _error = '新密码至少 4 位');
      return;
    }
    if (_password.text != _confirm.text) {
      setState(() => _error = '两次输入不一样');
      return;
    }
    final given = <int, String>{
      for (final entry in _fields.entries) entry.key: entry.value.text,
      ..._picked,
    };
    if (!challengesMatch(widget.lock, widget.facts, given)) {
      setState(() => _error = '安全问题没答对');
      HapticFeedback.heavyImpact();
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final salt = newSalt();
    final reset = ThreadLock(
      salt: salt,
      hash: derivePasscode(_password.text, salt),
      // 题目原样留着：找回一次不该顺手把找回方式也换掉。
      challenges: widget.lock.challenges,
    );
    if (mounted) Navigator.of(context).pop(reset);
  }

  Widget _challengeField(int index, LockChallenge challenge) {
    final choices = _choices[index];
    if (choices == null) {
      return TextField(
        controller: _fields[index],
        enabled: _deviceOk,
        decoration: InputDecoration(
          isDense: true,
          hintText: challenge.hint,
          border: const OutlineInputBorder(),
        ),
      );
    }
    // 选择题。模型名没人背得出来（`deepseek-ai/DeepSeek-V3.2` 这种），
    // 让人默写只会把主人自己挡在外面。
    // RadioGroup 的 onChanged 不接受 null，"不让选"靠每个选项自己的 enabled。
    return RadioGroup<String>(
      groupValue: _picked[index],
      onChanged: (value) => setState(() => _picked[index] = value ?? ''),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (final option in choices)
            RadioListTile<String>(
              value: option,
              enabled: _deviceOk,
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(option, style: const TextStyle(fontSize: 13)),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.chat;
    return Scaffold(
      appBar: AppBar(title: const Text('找回会话密码')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: <Widget>[
          _Step(
            index: 1,
            title: '验证手机锁屏',
            done: _deviceOk,
            child: _deviceOk
                ? Text('已通过', style: TextStyle(color: t.tintSuccess))
                : OutlinedButton.icon(
                    onPressed: _busy ? null : _verifyDevice,
                    icon: const Icon(Icons.phonelink_lock_outlined),
                    label: const Text('验证'),
                  ),
          ),
          const SizedBox(height: 20),
          _Step(
            index: 2,
            title: '回答安全问题',
            done: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (var i = 0; i < widget.lock.challenges.length; i++) ...[
                  Text(widget.lock.challenges[i].label,
                      style: const TextStyle(fontSize: 12.5)),
                  const SizedBox(height: 4),
                  _challengeField(i, widget.lock.challenges[i]),
                  const SizedBox(height: 14),
                ],
              ],
            ),
          ),
          const SizedBox(height: 8),
          _Step(
            index: 3,
            title: '设一个新密码',
            done: false,
            child: Column(
              children: <Widget>[
                TextField(
                  controller: _password,
                  obscureText: true,
                  enabled: _deviceOk,
                  decoration: const InputDecoration(
                    labelText: '新密码',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _confirm,
                  obscureText: true,
                  enabled: _deviceOk,
                  decoration: const InputDecoration(
                    labelText: '再输一次',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          if (_error case final text?) ...<Widget>[
            const SizedBox(height: 14),
            Text(text, style: TextStyle(color: t.tintError, fontSize: 12.5)),
          ],
          const SizedBox(height: 20),
          FilledButton(
            onPressed: !_deviceOk || _busy ? null : _reset,
            child: const Text('重设密码并进入'),
          ),
        ],
      ),
    );
  }
}

/// 那句必须说的话。
///
/// 单独一个 widget，三个界面共用一份措辞 —— 抄三遍的话迟早有一处会写成
/// "已加密"，而那正是最不该说错的地方。
class _Disclaimer extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final t = context.chat;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: t.tintWarning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.info_outline, size: 16, color: t.tintWarning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '对话记录本来就是加密存的（用你的 app 密码），拿到手机文件的人'
              '读不到。这道锁多挡一层：手机已经解锁、app 已经打开的时候 —— '
              '比如把手机借出去的那几分钟。\n'
              '它不是第二把钥匙：知道 app 密码的人仍然读得到。',
              style: TextStyle(fontSize: 11.5, color: t.tintPrimary),
            ),
          ),
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({
    required this.index,
    required this.title,
    required this.done,
    required this.child,
  });

  final int index;
  final String title;
  final bool done;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = context.chat;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            CircleAvatar(
              radius: 11,
              backgroundColor: done ? t.tintSuccess : t.bgTertiary,
              child: done
                  ? const Icon(Icons.check, size: 13, color: Colors.white)
                  : Text('$index', style: const TextStyle(fontSize: 11)),
            ),
            const SizedBox(width: 8),
            Text(title, style: Theme.of(context).textTheme.titleSmall),
          ],
        ),
        const SizedBox(height: 10),
        Padding(padding: const EdgeInsets.only(left: 30), child: child),
      ],
    );
  }
}
