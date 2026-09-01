/// 侧边抽屉：会话列表 + 各个入口。
///
/// 从「会话列表是首页、点进去再 push 聊天页」改成「聊天页是首页、
/// 会话列表在抽屉里」。这不只是挪个位置：
///
///   - 聊天是用得最多的那一屏，它该在启动就到位，而不是隔一层导航。
///   - 换会话变成一次原地替换，不再是 pop 再 push。返回键因此
///     不会在会话之间穿梭 —— 那种历史栈很快就乱了。
///   - 设置、技能、账号这些低频入口收进抽屉底部，顶栏空出来。
///
/// 会话的重命名和删除放在长按菜单里而不是每行右边挂两个图标：
/// 那两个图标在手机上一定会被误触，而删除会话是不可逆的。
library;

import 'package:flutter/material.dart';

import '../data/chat_store.dart';
import 'chat_theme.dart';

class ChatDrawer extends StatefulWidget {
  final ChatStore store;

  /// 当前打开的会话；null = 还没存盘的新会话。
  final String? currentThreadId;

  /// 选中一个会话。传 null 表示「开一个新的」。
  final ValueChanged<String?> onSelect;

  /// 抽屉底部的入口。
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenSkills;
  final VoidCallback onOpenChannels;

  const ChatDrawer({
    super.key,
    required this.store,
    required this.currentThreadId,
    required this.onSelect,
    required this.onOpenSettings,
    required this.onOpenSkills,
    required this.onOpenChannels,
  });

  @override
  State<ChatDrawer> createState() => _ChatDrawerState();
}

class _ChatDrawerState extends State<ChatDrawer> {
  late Future<List<ChatThread>> _threads;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() => _threads = widget.store.threads();

  Future<void> _rename(ChatThread thread) async {
    final controller = TextEditingController(text: thread.title);
    final title = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名会话'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '会话名'),
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (title == null || title.isEmpty) return;
    await widget.store.renameThread(thread.id, title);
    if (mounted) setState(_reload);
  }

  Future<void> _delete(ChatThread thread) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除会话'),
        // 说清楚删的是什么、不删的是什么。用户最怕的是"我的文件也没了"，
        // 而实际上 workspace 是按任务留着的。
        content: Text('「${thread.title}」的全部消息会被删除，无法恢复。\n'
            '这个任务的 workspace 和检查点不受影响。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.store.deleteThread(thread.id);
    if (!mounted) return;
    setState(_reload);
    // 删的是当前正开着的那个，就退到一个新会话 ——
    // 否则界面还停在一个已经不存在的会话上。
    if (thread.id == widget.currentThreadId) widget.onSelect(null);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.chat;
    return Drawer(
      backgroundColor: t.bgPrimary,
      child: SafeArea(
        child: Column(
          children: [
            _header(t),
            _search(t),
            Expanded(child: _list(t)),
            Divider(height: 1, color: t.borderPrimary),
            _footer(t),
          ],
        ),
      ),
    );
  }

  Widget _header(ChatTokens t) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Burrow',
                      style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                          color: t.tintPrimary)),
                  Text('地洞里的 Linux Agent',
                      style: TextStyle(fontSize: 11, color: t.tintTertiary)),
                ],
              ),
            ),
            IconButton(
              tooltip: '新对话',
              onPressed: () {
                Navigator.of(context).pop();
                widget.onSelect(null);
              },
              icon: Icon(Icons.add_comment_outlined, color: t.brand),
            ),
          ],
        ),
      );

  Widget _search(ChatTokens t) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: TextField(
          style: TextStyle(fontSize: 14, color: t.tintPrimary),
          decoration: InputDecoration(
            hintText: '搜索会话',
            hintStyle: TextStyle(fontSize: 14, color: t.tintTertiary),
            prefixIcon: Icon(Icons.search, size: 18, color: t.tintTertiary),
            filled: true,
            fillColor: t.bgSecondary,
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(vertical: 10),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(ChatShape.radiusLg),
              borderSide: BorderSide.none,
            ),
          ),
          onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
        ),
      );

  Widget _list(ChatTokens t) => FutureBuilder<List<ChatThread>>(
        future: _threads,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          // 标题和预览都参与匹配：用户记得的往往是自己说过的那句话，
          // 而不是被截成 28 个字的标题。
          final threads = snapshot.data!.where((thread) {
            if (_query.isEmpty) return true;
            return thread.title.toLowerCase().contains(_query) ||
                thread.preview.toLowerCase().contains(_query);
          }).toList();

          if (threads.isEmpty) {
            return Center(
              child: Text(
                _query.isEmpty ? '还没有会话' : '没有匹配的会话',
                style: TextStyle(fontSize: 13, color: t.tintTertiary),
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            itemCount: threads.length,
            itemBuilder: (context, i) {
              final thread = threads[i];
              final active = thread.id == widget.currentThreadId;
              return Container(
                margin: const EdgeInsets.only(bottom: 2),
                decoration: BoxDecoration(
                  color: active ? t.bgBrandSecondary : null,
                  borderRadius: BorderRadius.circular(ChatShape.radiusLg),
                ),
                child: ListTile(
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(ChatShape.radiusLg),
                  ),
                  leading: Icon(
                    thread.terminalMode
                        ? Icons.terminal
                        : Icons.chat_bubble_outline,
                    size: 18,
                    color: active ? t.brand : t.tintTertiary,
                  ),
                  title: Text(
                    thread.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      color: active ? t.brand : t.tintPrimary,
                      fontWeight: active ? FontWeight.w500 : FontWeight.normal,
                    ),
                  ),
                  subtitle: Text(
                    thread.preview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: t.tintTertiary),
                  ),
                  onTap: () {
                    Navigator.of(context).pop();
                    if (thread.id != widget.currentThreadId) {
                      widget.onSelect(thread.id);
                    }
                  },
                  onLongPress: () => _showThreadMenu(thread),
                ),
              );
            },
          );
        },
      );

  Future<void> _showThreadMenu(ChatThread thread) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('重命名'),
              onTap: () {
                Navigator.of(ctx).pop();
                _rename(thread);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('删除'),
              onTap: () {
                Navigator.of(ctx).pop();
                _delete(thread);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _footer(ChatTokens t) {
    Widget entry(IconData icon, String label, VoidCallback onTap) => ListTile(
          dense: true,
          leading: Icon(icon, size: 20, color: t.tintSecondary),
          title:
              Text(label, style: TextStyle(fontSize: 14, color: t.tintPrimary)),
          onTap: () {
            Navigator.of(context).pop();
            onTap();
          },
        );

    return Column(
      children: [
        entry(Icons.extension_outlined, '技能', widget.onOpenSkills),
        entry(Icons.hub_outlined, '渠道管理', widget.onOpenChannels),
        entry(Icons.settings_outlined, '设置', widget.onOpenSettings),
        const SizedBox(height: 4),
      ],
    );
  }
}
