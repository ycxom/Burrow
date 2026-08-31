import 'package:flutter/material.dart';

import '../data/chat_store.dart';

class ThreadListPage extends StatefulWidget {
  const ThreadListPage({
    required this.store,
    required this.buildThread,
    super.key,
  });

  final ChatStore store;
  final Widget Function(String? threadId, String title) buildThread;

  @override
  State<ThreadListPage> createState() => _ThreadListPageState();
}

class _ThreadListPageState extends State<ThreadListPage> {
  late Future<List<ChatThread>> _threads;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() => _threads = widget.store.threads();

  Future<void> _open(String? id, String title) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => widget.buildThread(id, title)),
    );
    if (!mounted) return;
    setState(_reload);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Burrow'),
            Text('地洞里的 Linux Agent', style: TextStyle(fontSize: 11)),
          ],
        ),
      ),
      body: FutureBuilder<List<ChatThread>>(
        future: _threads,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final threads = snapshot.data!;
          if (threads.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(36),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(Icons.hive_outlined, size: 48),
                    SizedBox(height: 16),
                    Text('还没有任务', style: TextStyle(fontSize: 20)),
                    SizedBox(height: 8),
                    Text(
                        '新建对话可以直接聊天；勾上「终端模式」'
                        '模型就能在沙箱里跑命令，随时回滚。',
                        textAlign: TextAlign.center),
                  ],
                ),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: threads.length,
            separatorBuilder: (_, __) => const SizedBox(height: 6),
            itemBuilder: (context, index) {
              final thread = threads[index];
              // 头像分两种：开了终端模式的会话能动手改东西，普通聊天不能。
              // 这个区别值得在列表上一眼看出来 —— 翻旧会话时要先知道
              // 「这个对话里模型有没有跑过命令」。
              final scheme = Theme.of(context).colorScheme;
              return Card(
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: thread.terminalMode
                        ? scheme.primaryContainer
                        : scheme.surfaceContainerHighest,
                    foregroundColor: thread.terminalMode
                        ? scheme.onPrimaryContainer
                        : scheme.onSurfaceVariant,
                    child: Icon(thread.terminalMode
                        ? Icons.terminal
                        : Icons.chat_bubble_outline),
                  ),
                  title: Text(thread.title, maxLines: 1),
                  subtitle: Text(thread.preview, maxLines: 2),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _open(thread.id, thread.title),
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _open(null, '新任务'),
        icon: const Icon(Icons.add),
        label: const Text('新任务'),
      ),
    );
  }
}
