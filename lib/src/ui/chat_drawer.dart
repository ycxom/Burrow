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

import 'dart:async';

import 'package:flutter/material.dart';

import '../data/chat_store.dart';
import 'chat_theme.dart';

enum _SearchScope { threads, current, global }

class ChatDrawer extends StatefulWidget {
  final ChatStore store;

  /// 当前打开的会话；null = 还没存盘的新会话。
  final String? currentThreadId;

  /// 选中一个会话。传 null 表示「开一个新的」。
  final ValueChanged<String?> onSelect;

  /// 打开消息搜索结果。跨会话时由聊天外壳先换会话，再定位消息。
  final void Function(String threadId, int messageId) onOpenMessage;

  /// 抽屉底部的入口。
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenSkills;
  final VoidCallback onOpenChannels;

  const ChatDrawer({
    super.key,
    required this.store,
    required this.currentThreadId,
    required this.onSelect,
    required this.onOpenMessage,
    required this.onOpenSettings,
    required this.onOpenSkills,
    required this.onOpenChannels,
  });

  @override
  State<ChatDrawer> createState() => _ChatDrawerState();
}

class _ChatDrawerState extends State<ChatDrawer> {
  static const _searchDebounce = Duration(milliseconds: 180);

  late Future<List<ChatThread>> _threads;
  final _searchController = TextEditingController();
  String _query = '';
  _SearchScope _scope = _SearchScope.threads;
  Future<List<ChatMessageSearchHit>>? _messageHits;
  int _searchRevision = 0;
  Timer? _searchTimer;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    _searchController.dispose();
    super.dispose();
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
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        child: Column(
          children: [
            SizedBox(
              height: 36,
              child: TextField(
                controller: _searchController,
                style: TextStyle(fontSize: 14, color: t.tintPrimary),
                decoration: InputDecoration(
                  hintText: switch (_scope) {
                    _SearchScope.threads => '搜索会话',
                    _SearchScope.current => '搜索当前会话',
                    _SearchScope.global => '搜索全部消息',
                  },
                  hintStyle: TextStyle(fontSize: 14, color: t.tintTertiary),
                  prefixIcon:
                      Icon(Icons.search, size: 18, color: t.tintTertiary),
                  prefixIconConstraints: const BoxConstraints(
                    minWidth: 36,
                    minHeight: 36,
                  ),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: '清除',
                          iconSize: 18,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 36,
                            minHeight: 36,
                          ),
                          onPressed: () {
                            _searchController.clear();
                            _setQuery('');
                          },
                          icon: Icon(Icons.close, color: t.tintTertiary),
                        ),
                  filled: true,
                  fillColor: t.bgSecondary,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 0),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(ChatShape.radiusLg),
                    borderSide: BorderSide.none,
                  ),
                ),
                onChanged: _setQuery,
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.center,
              child: SizedBox(
                height: 28,
                child: SegmentedButton<_SearchScope>(
                  selected: {_scope},
                  showSelectedIcon: false,
                  onSelectionChanged: (selection) => _setScope(selection.first),
                  style: ButtonStyle(
                    visualDensity: const VisualDensity(
                      horizontal: -3,
                      vertical: -3,
                    ),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    minimumSize: const WidgetStatePropertyAll(Size(0, 28)),
                    padding: const WidgetStatePropertyAll(
                      EdgeInsets.symmetric(horizontal: 12),
                    ),
                    textStyle: WidgetStatePropertyAll(
                      TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: t.tintSecondary),
                    ),
                  ),
                  segments: const [
                    ButtonSegment(
                        value: _SearchScope.threads, label: Text('会话')),
                    ButtonSegment(
                        value: _SearchScope.current, label: Text('当前')),
                    ButtonSegment(
                        value: _SearchScope.global, label: Text('全局')),
                  ],
                ),
              ),
            ),
          ],
        ),
      );

  void _setQuery(String value) {
    setState(() {
      _query = value.trim().toLowerCase();
      _searchTimer?.cancel();
      if (_scope == _SearchScope.threads || _query.isEmpty) {
        _messageHits = null;
        return;
      }
      _searchTimer = Timer(_searchDebounce, _searchMessages);
    });
  }

  void _setScope(_SearchScope scope) {
    setState(() {
      _scope = scope;
      _searchTimer?.cancel();
      if (scope == _SearchScope.threads || _query.isEmpty) {
        _messageHits = null;
      } else {
        _searchMessages();
      }
    });
  }

  Future<void> _searchMessages() async {
    final keyword = _query.trim();
    if (keyword.isEmpty) return;
    final revision = ++_searchRevision;
    final threadId =
        _scope == _SearchScope.current ? widget.currentThreadId : null;
    if (threadId == null && _scope == _SearchScope.current) {
      setState(() => _messageHits = Future.value(const []));
      return;
    }
    final future = widget.store.searchMessages(keyword, threadId: threadId);
    setState(() => _messageHits = future);
    await future;
    if (mounted && revision == _searchRevision) setState(() {});
  }

  Widget _messageList(ChatTokens t) =>
      FutureBuilder<List<ChatMessageSearchHit>>(
        future: _messageHits,
        builder: (context, snapshot) {
          if (_query.isNotEmpty && _messageHits == null) {
            return Center(
              child: Text('正在搜索…',
                  style: TextStyle(fontSize: 13, color: t.tintTertiary)),
            );
          }
          if (snapshot.connectionState != ConnectionState.done &&
              !snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Text(
                '搜索失败',
                style: TextStyle(fontSize: 13, color: t.tintError),
              ),
            );
          }
          final hits = snapshot.data ?? const <ChatMessageSearchHit>[];
          if (hits.isEmpty) {
            final empty =
                _scope == _SearchScope.current && widget.currentThreadId == null
                    ? '当前会话还没有保存的消息'
                    : '没有匹配的消息';
            return Center(
              child: Text(empty,
                  style: TextStyle(fontSize: 13, color: t.tintTertiary)),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            itemCount: hits.length,
            itemBuilder: (context, index) {
              final hit = hits[index];
              return ListTile(
                dense: true,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(ChatShape.radiusLg),
                ),
                leading: Icon(
                  switch (hit.role) {
                    'user' => Icons.person_outline,
                    'assistant' => Icons.smart_toy_outlined,
                    'tool' => Icons.build_outlined,
                    _ => Icons.info_outline,
                  },
                  size: 18,
                  color: t.tintTertiary,
                ),
                title: Text(
                  _snippet(hit.message),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: t.tintPrimary),
                ),
                subtitle: Text(
                  _hitSubtitle(hit),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: t.tintTertiary),
                ),
                onTap: () {
                  Navigator.of(context).pop();
                  widget.onOpenMessage(hit.threadId, hit.messageId);
                },
              );
            },
          );
        },
      );

  String _snippet(String text) {
    final compact = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (compact.length <= 100) return compact;
    final query = _query.trim();
    final offset = compact.toLowerCase().indexOf(query);
    if (offset < 0) return '${compact.substring(0, 100)}…';
    final start = (offset - 32).clamp(0, compact.length);
    final end = (start + 100).clamp(0, compact.length);
    return '${start == 0 ? '' : '…'}${compact.substring(start, end)}'
        '${end == compact.length ? '' : '…'}';
  }

  String _hitSubtitle(ChatMessageSearchHit hit) {
    final role = switch (hit.role) {
      'user' => '我',
      'assistant' => '助手',
      'tool' => '工具',
      _ => '系统',
    };
    final time =
        '${hit.createdAt.year}/${hit.createdAt.month}/${hit.createdAt.day}';
    return _scope == _SearchScope.global
        ? '$role · ${hit.threadTitle} · $time'
        : '$role · $time';
  }

  Widget _list(ChatTokens t) {
    if (_scope != _SearchScope.threads && _query.isNotEmpty) {
      return _messageList(t);
    }
    return FutureBuilder<List<ChatThread>>(
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
  }

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
