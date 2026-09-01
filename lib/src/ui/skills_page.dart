/// 技能页：连接仓库、浏览、安装、开关。
///
/// 分成两段：上面是**已装的**（能直接开关、卸载），下面是**已连接的仓库**
/// （点进去浏览里面有什么）。这个顺序是有意的 —— 打开这一页最常见的目的是
/// 「把某个 skill 关掉」或者「看看现在开着哪些」，而不是装新的。
library;

import 'package:flutter/material.dart';

import '../skills/skill_store.dart';
import 'chat_theme.dart';

class SkillsPage extends StatefulWidget {
  final SkillStore store;
  const SkillsPage({super.key, required this.store});

  @override
  State<SkillsPage> createState() => _SkillsPageState();
}

class _SkillsPageState extends State<SkillsPage> {
  Object? _error;

  Future<void> _addRepo() async {
    final controller = TextEditingController();
    final input = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('连接技能仓库'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'owner/name 或 GitHub 网址',
              ),
              onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
            ),
            const SizedBox(height: 12),
            const Text(
              '仓库里每个带 SKILL.md 的子目录都是一个技能。\n'
              '要指定分支写成 owner/name@branch。',
              style: TextStyle(fontSize: 11),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('连接'),
          ),
        ],
      ),
    );
    if (input == null || input.isEmpty) return;

    final repo = SkillRepo.parse(input);
    if (repo == null) {
      if (mounted) {
        setState(() => _error = '看不懂「$input」。写成 owner/name，或者直接贴 GitHub 网址。');
      }
      return;
    }
    await widget.store.addRepo(repo);
    if (mounted) setState(() => _error = null);
    // 连上就直接进去看有什么 —— 连接本身不是目的，装 skill 才是。
    if (mounted) await _browse(repo);
  }

  Future<void> _browse(SkillRepo repo) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _RepoBrowserPage(store: widget.store, repo: repo),
      ),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final t = context.chat;
    final installed = widget.store.skills.where((s) => s.installed).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('技能'),
        actions: [
          IconButton(
            tooltip: '连接仓库',
            onPressed: _addRepo,
            icon: const Icon(Icons.add_link),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (!widget.store.ready)
            _banner(
              t,
              t.tintWarning,
              '还没有安装发行版基座。技能装在沙箱里，装了也没有地方运行 —— '
              '先在聊天页勾一次「终端模式」把基座装上。',
            ),
          if (_error != null) _banner(t, t.tintError, '$_error'),
          Text('工作方式',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: t.tintSecondary)),
          const SizedBox(height: 4),
          Text(
            '开着的技能只把名字和一句话描述放进系统提示，模型判断相关时'
            '才用 read_skill 读全文。所以开十个也不会把上下文吃光。',
            style: TextStyle(fontSize: 11, color: t.tintTertiary),
          ),
          const SizedBox(height: 20),
          Text('已安装（${installed.length}）',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: t.tintPrimary)),
          const SizedBox(height: 8),
          if (installed.isEmpty)
            Text('还没有安装技能。右上角连接一个仓库开始。',
                style: TextStyle(fontSize: 12, color: t.tintTertiary))
          else
            for (final skill in installed) _installedTile(t, skill),
          const SizedBox(height: 24),
          Text('已连接的仓库（${widget.store.repos.length}）',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: t.tintPrimary)),
          const SizedBox(height: 8),
          if (widget.store.repos.isEmpty)
            Text('还没有连接仓库。',
                style: TextStyle(fontSize: 12, color: t.tintTertiary))
          else
            for (final repo in widget.store.repos) _repoTile(t, repo),
        ],
      ),
    );
  }

  Widget _banner(ChatTokens t, Color tint, String text) => Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: tint.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(ChatShape.radiusLg),
          border: Border.all(color: tint.withValues(alpha: 0.5)),
        ),
        child: Text(text, style: TextStyle(fontSize: 12, color: t.tintPrimary)),
      );

  Widget _installedTile(ChatTokens t, Skill skill) => Card(
        elevation: 0,
        color: t.bgSecondary,
        margin: const EdgeInsets.only(bottom: 8),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ChatShape.radiusLg),
        ),
        child: SwitchListTile(
          value: skill.enabled,
          onChanged: (v) async {
            await widget.store.setEnabled(skill.key, v);
            if (mounted) setState(() {});
          },
          title: Text(skill.name,
              style: TextStyle(fontSize: 14, color: t.tintPrimary)),
          subtitle: Text(
            skill.description.isEmpty ? skill.directory : skill.description,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: t.tintTertiary),
          ),
          secondary: IconButton(
            tooltip: '卸载',
            icon: Icon(Icons.delete_outline, color: t.tintTertiary),
            onPressed: () async {
              await widget.store.uninstall(skill.key);
              if (mounted) setState(() {});
            },
          ),
        ),
      );

  Widget _repoTile(ChatTokens t, SkillRepo repo) => Card(
        elevation: 0,
        color: t.bgSecondary,
        margin: const EdgeInsets.only(bottom: 8),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ChatShape.radiusLg),
        ),
        child: ListTile(
          leading: Icon(Icons.folder_outlined, color: t.tintSecondary),
          title: Text(repo.slug,
              style: TextStyle(fontSize: 14, color: t.tintPrimary)),
          subtitle: Text(repo.branch,
              style: TextStyle(fontSize: 11, color: t.tintTertiary)),
          trailing: IconButton(
            tooltip: '断开',
            icon: Icon(Icons.link_off, color: t.tintTertiary),
            onPressed: () async {
              await widget.store.removeRepo(repo);
              if (mounted) setState(() {});
            },
          ),
          onTap: () => _browse(repo),
        ),
      );
}

// ---------------------------------------------------------------------------

class _RepoBrowserPage extends StatefulWidget {
  final SkillStore store;
  final SkillRepo repo;
  const _RepoBrowserPage({required this.store, required this.repo});

  @override
  State<_RepoBrowserPage> createState() => _RepoBrowserPageState();
}

class _RepoBrowserPageState extends State<_RepoBrowserPage> {
  List<Skill>? _skills;
  Object? _error;
  final _installing = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _skills = null;
      _error = null;
    });
    try {
      final found = await widget.store.discover(widget.repo);
      if (mounted) setState(() => _skills = found);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _install(Skill skill) async {
    setState(() => _installing.add(skill.key));
    try {
      await widget.store.install(skill);
      if (!mounted) return;
      // 重新读一遍列表而不是就地改一条：install 会把 enabled 也置上，
      // 而那个状态在 store 里，不在这份快照里。
      final found = await widget.store.discover(widget.repo);
      if (mounted) setState(() => _skills = found);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _installing.remove(skill.key));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.chat;
    final skills = _skills;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.repo.slug),
        actions: [
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: _error != null
          ? Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('$_error',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 13, color: t.tintPrimary)),
                  const SizedBox(height: 16),
                  OutlinedButton(onPressed: _load, child: const Text('重试')),
                ],
              ),
            )
          : skills == null
              ? const Center(child: CircularProgressIndicator())
              : skills.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          '这个仓库里没有找到 SKILL.md。\n'
                          '技能要放在子目录里，每个目录一个 SKILL.md。',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 13, color: t.tintTertiary),
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: skills.length,
                      itemBuilder: (_, i) {
                        final skill = skills[i];
                        final busy = _installing.contains(skill.key);
                        return Card(
                          elevation: 0,
                          color: t.bgSecondary,
                          margin: const EdgeInsets.only(bottom: 8),
                          shape: RoundedRectangleBorder(
                            borderRadius:
                                BorderRadius.circular(ChatShape.radiusLg),
                          ),
                          child: ListTile(
                            title: Text(skill.name,
                                style: TextStyle(
                                    fontSize: 14, color: t.tintPrimary)),
                            subtitle: Text(
                              skill.description.isEmpty
                                  ? skill.directory
                                  : skill.description,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 11, color: t.tintTertiary),
                            ),
                            trailing: busy
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  )
                                : skill.installed
                                    ? Icon(Icons.check_circle,
                                        color: t.tintSuccess)
                                    : TextButton(
                                        onPressed: () => _install(skill),
                                        child: const Text('安装'),
                                      ),
                          ),
                        );
                      },
                    ),
    );
  }
}
