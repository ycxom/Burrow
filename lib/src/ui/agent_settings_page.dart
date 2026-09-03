import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../agent/agent_loop.dart';
import '../context/overflow_manager.dart';
import '../sandbox/sandbox_session.dart';
import '../sandbox/snapshot_store.dart';
import '../settings/settings_store.dart';

/// 设置页里「Agent 与终端」那三行的落地页。
///
/// 这三行原先是三个 `const ListTile` —— 有 `chevron_right` 却没有 `onTap`，
/// 点下去毫无反应。箭头是一个承诺，画了就得兑现，所以这里把它们背后
/// **本来就存在**的东西接了出来：`SandboxLevel` 真的会进 proot 的 argv 和
/// 环境变量，`OverflowManager` 的阈值真的在决定什么时候摘要，
/// 每个会话的 workspace 真的是磁盘上一个独立目录。

// ---------------------------------------------------------------------------
// 沙箱模式
// ---------------------------------------------------------------------------

class SandboxSettingsPage extends StatefulWidget {
  const SandboxSettingsPage({
    required this.store,
    required this.capabilities,
    super.key,
  });

  final SettingsStore store;
  final SandboxCapabilities capabilities;

  @override
  State<SandboxSettingsPage> createState() => _SandboxSettingsPageState();
}

const _levelLabels = <SandboxLevel, (String, String)>{
  SandboxLevel.readOnly: ('只读', '工作区也不可写，无网。适合"先让它看看"的阶段'),
  SandboxLevel.workspaceWrite: ('工作区可写', '只有当前会话的 workspace 可写，环境只读，无网'),
  SandboxLevel.workspaceWriteNetwork: (
    '工作区可写 + 联网',
    '默认。装包、拉仓库都要网；写入仍限制在 workspace，够不着实体机'
  ),
  SandboxLevel.dangerFullAccess: (
    '关闭沙箱',
    '不做任何路径和网络隔离，命令直接以 app 身份运行。此时每条命令都会问你'
  ),
};

const _approvalLabels = <ApprovalMode, (String, String)>{
  ApprovalMode.readOnly: ('只读', '只读工具可用，任何写入和命令执行一律拒绝'),
  ApprovalMode.onRequest: ('按需审批', '沙箱开着时放手让它跑，可疑的问你。推荐'),
  ApprovalMode.auto: ('自动执行', '沙箱开着时不打断，强制打检查点；关掉沙箱后仍然逐条问'),
  ApprovalMode.yolo: ('关闭沙箱', '不审批、不隔离。等同于把执行边界完全交给模型'),
};

class _SandboxSettingsPageState extends State<SandboxSettingsPage> {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final store = widget.store;
    final allowed = store.allowedCommands;

    return Scaffold(
      appBar: AppBar(title: const Text('沙箱模式')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        children: <Widget>[
          const _SectionTitle('执行边界', subtitle: '决定命令能碰到什么。改动立即对当前会话生效'),
          Card(
            clipBehavior: Clip.antiAlias,
            child: RadioGroup<SandboxLevel>(
              groupValue: store.sandboxLevel,
              onChanged: _pickLevel,
              child: Column(
                children: <Widget>[
                  for (final level in SandboxLevel.values)
                    RadioListTile<SandboxLevel>(
                      value: level,
                      title: Text(
                        _levelLabels[level]!.$1,
                        style: level == SandboxLevel.dangerFullAccess
                            ? TextStyle(color: scheme.error)
                            : null,
                      ),
                      subtitle: Text(_levelLabels[level]!.$2),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          const _SectionTitle('审批档位', subtitle: '新会话的默认值。聊天页顶部的按钮改的是同一个设置'),
          Card(
            clipBehavior: Clip.antiAlias,
            child: RadioGroup<ApprovalMode>(
              groupValue: store.approvalMode,
              onChanged: _pickMode,
              child: Column(
                children: <Widget>[
                  for (final mode in ApprovalMode.values)
                    RadioListTile<ApprovalMode>(
                      value: mode,
                      title: Text(
                        _approvalLabels[mode]!.$1,
                        style: mode == ApprovalMode.yolo
                            ? TextStyle(color: scheme.error)
                            : null,
                      ),
                      subtitle: Text(_approvalLabels[mode]!.$2),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          const _SectionTitle('本机实际可用的隔离层', subtitle: '开机时探测出来的，不是编译期假设'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      _CapChip('路径隔离 proot', widget.capabilities.proot),
                      _CapChip('断网 seccomp', widget.capabilities.seccomp),
                      _CapChip(
                        widget.capabilities.hasLandlock
                            ? 'Landlock v${widget.capabilities.landlockAbi}'
                            : 'Landlock',
                        widget.capabilities.hasLandlock,
                      ),
                      _CapChip('资源限制 rlimit', widget.capabilities.rlimit),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    widget.capabilities.describe(),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          _SectionTitle(
            '已允许的命令',
            subtitle: allowed.isEmpty
                ? '关闭沙箱后每条命令都会问。勾了「以后允许」的会记在这里'
                : '共 ${allowed.length} 条，关闭沙箱时不再询问。可以随时撤销',
          ),
          Card(
            clipBehavior: Clip.antiAlias,
            child: allowed.isEmpty
                ? const ListTile(
                    dense: true,
                    title: Text('还没有', style: TextStyle(fontSize: 13)),
                    subtitle: Text(
                      '沙箱开着时这一层不拦任何命令 —— 边界是 proot，'
                      '够不着实体机。这份名单只在关掉沙箱之后起作用。',
                      style: TextStyle(fontSize: 11),
                    ),
                  )
                : Column(
                    children: <Widget>[
                      for (var i = 0; i < allowed.length; i++) ...<Widget>[
                        if (i > 0) const Divider(height: 1),
                        ListTile(
                          dense: true,
                          leading: Icon(Icons.check_circle_outline,
                              size: 20, color: scheme.primary),
                          title: Text(
                            allowed[i],
                            style: const TextStyle(
                                fontFamily: 'monospace', fontSize: 13),
                          ),
                          trailing: IconButton(
                            tooltip: '撤销',
                            icon: const Icon(Icons.delete_outline, size: 20),
                            onPressed: () async {
                              await store.revokeCommand(allowed[i]);
                              if (mounted) setState(() {});
                            },
                          ),
                        ),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickLevel(SandboxLevel? v) async {
    if (v == null) return;
    if (v == SandboxLevel.dangerFullAccess && !await _confirmDanger()) return;
    await widget.store.setSandboxLevel(v);
    if (mounted) setState(() {});
  }

  Future<void> _pickMode(ApprovalMode? v) async {
    if (v == null) return;
    if (v == ApprovalMode.yolo && !await _confirmDanger()) return;
    await widget.store.setApprovalMode(v);
    if (mounted) setState(() {});
  }

  Future<bool> _confirmDanger() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认关闭沙箱？'),
        content: const Text(
          '关闭后，模型发起的命令不再有路径隔离和网络限制，'
          '可以读写 app 能访问的任何文件。\n\n'
          '检查点仍然会打，但它只覆盖 workspace —— '
          'workspace 以外被改动的东西回滚不了。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
                foregroundColor: Theme.of(ctx).colorScheme.error),
            child: const Text('仍然关闭'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }
}

class _CapChip extends StatelessWidget {
  const _CapChip(this.label, this.available);

  final String label;
  final bool available;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Chip(
      visualDensity: VisualDensity.compact,
      avatar: Icon(
        available ? Icons.check_circle : Icons.remove_circle_outline,
        size: 16,
        color: available ? scheme.primary : scheme.onSurfaceVariant,
      ),
      label: Text(label),
      labelStyle: TextStyle(
        fontSize: 12,
        color: available ? scheme.onSurface : scheme.onSurfaceVariant,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 默认工作目录
// ---------------------------------------------------------------------------

class WorkspaceSettingsPage extends StatefulWidget {
  const WorkspaceSettingsPage({
    required this.tasksRoot,
    required this.currentTaskId,
    super.key,
  });

  /// `<app 私有目录>/sandbox/tasks`。每个会话在这下面有一个自己的目录。
  final Directory tasksRoot;

  /// 当前会话的目录名。它不允许删 —— 删了这轮对话的检查点就断了。
  final String currentTaskId;

  @override
  State<WorkspaceSettingsPage> createState() => _WorkspaceSettingsPageState();
}

class _TaskDirInfo {
  _TaskDirInfo(this.dir, this.bytes, this.modified);

  final Directory dir;
  final int bytes;
  final DateTime modified;

  String get id => dir.path.split(RegExp(r'[/\\]')).last;
}

class _WorkspaceSettingsPageState extends State<WorkspaceSettingsPage> {
  List<_TaskDirInfo>? _tasks;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_scan());
  }

  Future<void> _scan() async {
    final result = <_TaskDirInfo>[];
    if (await widget.tasksRoot.exists()) {
      await for (final entity in widget.tasksRoot.list()) {
        if (entity is! Directory) continue;
        result.add(_TaskDirInfo(
          entity,
          await _sizeOf(entity),
          (await entity.stat()).modified,
        ));
      }
    }
    result.sort((a, b) => b.modified.compareTo(a.modified));
    if (mounted) setState(() => _tasks = result);
  }

  /// 递归求和。手机上一个会话目录通常只有几百个文件，直接走一遍够了；
  /// 统计的是文件长度而不是磁盘占用 —— 后者要按块对齐，这里不值得。
  static Future<int> _sizeOf(Directory dir) async {
    var total = 0;
    try {
      await for (final e in dir.list(recursive: true, followLinks: false)) {
        if (e is! File) continue;
        try {
          total += await e.length();
        } on FileSystemException {
          // 快照对象在 gc 的同时被删掉是正常的，跳过就行。
        }
      }
    } on FileSystemException {
      return total;
    }
    return total;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tasks = _tasks;
    final total = tasks?.fold<int>(0, (a, t) => a + t.bytes) ?? 0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('默认工作目录'),
        actions: <Widget>[
          IconButton(
            tooltip: '重新扫描',
            onPressed: _busy ? null : () => unawaited(_scan()),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        children: <Widget>[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('每个会话一个独立 workspace',
                      style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 6),
                  Text(
                    '不共用一个目录，是因为「回到这里」要把文件一起回滚。'
                    '共用的话，回滚 A 会话会连带毁掉 B 会话正在改的东西。',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
                  const SizedBox(height: 12),
                  SelectableText(
                    '${widget.tasksRoot.path}/<会话>/workspace',
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 12, height: 1.5),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          _SectionTitle(
            '磁盘占用',
            subtitle: tasks == null
                ? '正在统计…'
                : '${tasks.length} 个会话目录，合计 ${_human(total)}',
          ),
          if (tasks == null)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (tasks.isEmpty)
            Card(
              child: ListTile(
                leading: const Icon(Icons.folder_off_outlined),
                title: const Text('还没有会话目录'),
                subtitle: Text(
                  '第一次发消息时才会创建',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ),
            )
          else
            Card(
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: <Widget>[
                  for (var i = 0; i < tasks.length; i++) ...<Widget>[
                    if (i > 0) const Divider(height: 1),
                    _taskTile(tasks[i]),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _taskTile(_TaskDirInfo task) {
    final current = task.id == widget.currentTaskId;
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(current ? Icons.folder_open : Icons.folder_outlined,
          color: current ? scheme.primary : null),
      title: Text(
        task.id,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text('${_human(task.bytes)} · ${_stamp(task.modified)}'
          '${current ? ' · 当前会话' : ''}'),
      trailing: current
          ? null
          : IconButton(
              tooltip: '删除',
              onPressed: _busy ? null : () => unawaited(_delete(task)),
              icon: const Icon(Icons.delete_outline),
            ),
    );
  }

  Future<void> _delete(_TaskDirInfo task) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这个会话目录？'),
        content: Text(
          '${task.id}\n\n'
          '会删掉它的 workspace 文件和全部检查点，'
          '之后那个会话的「回到这里」就只能截断对话，文件回滚不了。\n\n'
          '对话记录本身不受影响。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
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
    setState(() => _busy = true);
    try {
      await task.dir.delete(recursive: true);
    } on FileSystemException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('删除失败：${e.message}')));
      }
    }
    if (mounted) setState(() => _busy = false);
    await _scan();
  }
}

// ---------------------------------------------------------------------------
// 上下文与检查点
// ---------------------------------------------------------------------------

class ContextSettingsPage extends StatefulWidget {
  const ContextSettingsPage({
    required this.store,
    required this.overflow,
    required this.snapshots,
    super.key,
  });

  final SettingsStore store;

  /// 当前会话的摘要状态。只读展示 —— 让「已经摘要到第几条」这件事可见。
  final OverflowManager overflow;
  final SnapshotStore snapshots;

  @override
  State<ContextSettingsPage> createState() => _ContextSettingsPageState();
}

const _triggerLabels = <OverflowTrigger, (String, String)>{
  OverflowTrigger.messageCount: ('按条数', '只看消息条数'),
  OverflowTrigger.tokenCount: ('按 token', '只看估算出来的 token 数'),
  OverflowTrigger.either: ('任一满足', '两个阈值哪个先到都触发。推荐'),
};

class _ContextSettingsPageState extends State<ContextSettingsPage> {
  late double _messages;
  late double _tokens;

  @override
  void initState() {
    super.initState();
    _messages = widget.store.messageThreshold.toDouble();
    _tokens = widget.store.tokenThreshold.toDouble();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final store = widget.store;
    final overflow = widget.overflow;
    final checkpoints = widget.snapshots.checkpoints;

    return Scaffold(
      appBar: AppBar(title: const Text('上下文与检查点')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        children: <Widget>[
          const _SectionTitle('什么时候自动摘要',
              subtitle: '超过阈值时把最早的对话压成一段摘要。'
                  '原始记录不删，模型可以用 recall_memory 查回来'),
          Card(
            clipBehavior: Clip.antiAlias,
            child: RadioGroup<OverflowTrigger>(
              groupValue: store.overflowTrigger,
              onChanged: (v) async {
                if (v == null) return;
                await store.setContextLimits(trigger: v);
                if (mounted) setState(() {});
              },
              child: Column(
                children: <Widget>[
                  for (final trigger in OverflowTrigger.values)
                    RadioListTile<OverflowTrigger>(
                      value: trigger,
                      title: Text(_triggerLabels[trigger]!.$1),
                      subtitle: Text(_triggerLabels[trigger]!.$2),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('消息条数阈值：${_messages.round()} 条',
                      style: Theme.of(context).textTheme.titleSmall),
                  Slider(
                    value: _messages,
                    min: SettingsStore.minMessageThreshold.toDouble(),
                    max: 200,
                    divisions: 97,
                    label: '${_messages.round()}',
                    onChanged: (v) => setState(() => _messages = v),
                    onChangeEnd: (v) =>
                        store.setContextLimits(messageThreshold: v.round()),
                  ),
                  const SizedBox(height: 4),
                  Text('token 阈值：${_tokens.round()}',
                      style: Theme.of(context).textTheme.titleSmall),
                  Slider(
                    value: _tokens,
                    min: SettingsStore.minTokenThreshold.toDouble(),
                    max: 60000,
                    divisions: 59,
                    label: '${_tokens.round()}',
                    onChanged: (v) => setState(() => _tokens = v),
                    onChangeEnd: (v) =>
                        store.setContextLimits(tokenThreshold: v.round()),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'token 是估算值，不是服务端的准确计数。真的超了上下文窗口时，'
                    'ContextLimitGuard 会另外兜一次底。',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          const _SectionTitle('当前会话'),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: <Widget>[
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.compress),
                  title: const Text('摘要覆盖'),
                  subtitle: Text(overflow.hasSummary
                      ? '已覆盖到第 ${overflow.checkpoint} 条'
                      : '还没有触发过摘要'),
                ),
                const Divider(height: 1),
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.history),
                  title: const Text('检查点'),
                  subtitle: Text(checkpoints.isEmpty
                      ? '还没有打过检查点（只有终端模式下改了文件才会打）'
                      : '${checkpoints.length} 个，当前代号 #${widget.snapshots.head}'),
                ),
              ],
            ),
          ),
          if (checkpoints.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            Card(
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: <Widget>[
                  for (final cp in checkpoints.reversed.take(20))
                    ListTile(
                      dense: true,
                      leading: Text('#${cp.generation}',
                          style: const TextStyle(
                              fontFamily: 'monospace', fontSize: 12)),
                      title: Text(cp.reason,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                          '${cp.changes.length} 处变更 · ${_stamp(cp.createdAt)}'),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => unawaited(_gc()),
              icon: const Icon(Icons.cleaning_services_outlined),
              label: const Text('清理没被引用的快照数据'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _gc() async {
    final freed = await widget.snapshots.gc();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(freed == 0 ? '没有可清理的数据' : '清理了 $freed 个快照对象'),
    ));
    setState(() {});
  }
}

// ---------------------------------------------------------------------------

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title, {this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(title,
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(color: scheme.primary)),
          if (subtitle != null) ...<Widget>[
            const SizedBox(height: 2),
            Text(subtitle!,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant)),
          ],
        ],
      ),
    );
  }
}

String _human(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

String _stamp(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} '
      '${two(t.hour)}:${two(t.minute)}';
}
