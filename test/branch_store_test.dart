@TestOn('vm')
library;

import 'dart:io';

import 'package:burrow/src/agent/agent_loop.dart' show TokenUsage;
import 'package:burrow/src/context/overflow_manager.dart';
import 'package:burrow/src/data/chat_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

ChatMessage user(String text, {String? branchId}) => ChatMessage(
      role: 'user',
      content: text,
      at: DateTime.fromMillisecondsSinceEpoch(1000),
      branchId: branchId,
    );

ChatMessage reply(String text, {int ms = 0}) => ChatMessage(
      role: 'assistant',
      content: text,
      at: DateTime.fromMillisecondsSinceEpoch(2000),
      source: '渠道 · 模型',
      reasoning: ms > 0 ? '想了想' : '',
      reasoningMs: ms,
      usage: const TokenUsage(input: 10, output: 20),
    );

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late ChatStore store;
  late String thread;
  late Directory tmp;

  setUp(() async {
    // 每个用例一个独立的库文件。不能用 `:memory:` —— sqflite 默认
    // singleInstance，同一个路径拿到的是同一个实例，所有用例会共用一个库，
    // 上一个用例的分支会算进下一个用例的计数里。
    tmp = await Directory.systemTemp.createTemp('burrow_branch');
    store = await ChatStore.openAt('${tmp.path}/test.db');
    thread = await store.createThread('第一句');
  });

  tearDown(() async {
    // 先关库再删目录：Windows 上文件还开着就删不掉。
    await store.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  group('分支存储', () {
    test('存一个版本之后能原样取回来', () async {
      final tail = <ChatMessage>[user('讲个笑话'), reply('从前有座山', ms: 1200)];
      final index = await store.saveVariant(
        threadId: thread,
        branchId: 'b1',
        tail: tail,
      );
      expect(index, 0);

      final back = await store.loadVariant('b1', 0);
      expect(back, isNotNull);
      expect(back!.length, 2);
      expect(back[0].role, 'user');
      expect(back[0].content, '讲个笑话');
      // 每个字段都要能过一遍来回 —— 少存一个，切回旧版本时那条消息就变了样。
      expect(back[1].content, '从前有座山');
      expect(back[1].source, '渠道 · 模型');
      expect(back[1].reasoning, '想了想');
      expect(back[1].reasoningMs, 1200);
      expect(back[1].usage?.input, 10);
      expect(back[1].usage?.output, 20);
      expect(back[1].at.millisecondsSinceEpoch, 2000);
    });

    test('同样的内容不会存第二份', () async {
      final tail = <ChatMessage>[user('你好'), reply('你好呀')];
      final first =
          await store.saveVariant(threadId: thread, branchId: 'b1', tail: tail);
      // 来回切换会反复存同一段内容，不去重的话库会一直长大。
      final again =
          await store.saveVariant(threadId: thread, branchId: 'b1', tail: tail);
      expect(again, first, reason: '同样的内容该复用同一个版本序号');

      final state = await store.branchStateOf('b1');
      expect(state!.total, 1, reason: '存了两次，但只该有一个版本');
    });

    test('内容不同就是不同的版本，序号往后排', () async {
      await store.saveVariant(
        threadId: thread,
        branchId: 'b1',
        tail: <ChatMessage>[user('你好'), reply('第一版')],
      );
      final second = await store.saveVariant(
        threadId: thread,
        branchId: 'b1',
        tail: <ChatMessage>[user('你好'), reply('第二版')],
      );
      expect(second, 1);

      final state = await store.branchStateOf('b1');
      expect(state!.total, 2);
      // 最后存的那个默认就是正在看的那个。
      expect(state.active, 1);
      expect(state.hasChoice, isTrue);

      expect((await store.loadVariant('b1', 0))![1].content, '第一版');
      expect((await store.loadVariant('b1', 1))![1].content, '第二版');
    });

    test('切回旧版本后，重开也还停在那个版本上', () async {
      await store.saveVariant(
          threadId: thread,
          branchId: 'b1',
          tail: <ChatMessage>[user('你好'), reply('第一版')]);
      await store.saveVariant(
          threadId: thread,
          branchId: 'b1',
          tail: <ChatMessage>[user('你好'), reply('第二版')]);

      await store.setActiveVariant('b1', 0);
      expect((await store.branchStateOf('b1'))!.active, 0);
    });

    test('没分过支的消息查不出分支状态', () async {
      expect(await store.branchStateOf('从没存过'), isNull);
      expect(await store.loadVariant('从没存过', 0), isNull);
    });

    test('删会话时把它的版本内容一起回收掉', () async {
      await store.saveVariant(
          threadId: thread,
          branchId: 'b1',
          tail: <ChatMessage>[user('你好'), reply('第一版')]);
      await store.saveVariant(
          threadId: thread,
          branchId: 'b1',
          tail: <ChatMessage>[user('你好'), reply('第二版')]);
      expect(await store.segmentCount(), 2);

      await store.deleteThread(thread);

      // 只删指针不减引用的话，这两段内容会永远留在库里，谁也看不到，
      // 只是慢慢把存储吃掉。
      expect(await store.segmentCount(), 0);
      expect(await store.branchStateOf('b1'), isNull);
    });

    test('两个会话引用同一段内容时，删掉一个不会连累另一个', () async {
      final other = await store.createThread('另一个会话');
      final shared = <ChatMessage>[user('同一段话'), reply('同一个回答')];
      await store.saveVariant(threadId: thread, branchId: 'b1', tail: shared);
      await store.saveVariant(threadId: other, branchId: 'b2', tail: shared);

      // 内容一样，只存一份 —— 这正是按内容寻址省空间的地方。
      expect(await store.segmentCount(), 1);

      await store.deleteThread(thread);
      // 还有人引用着，不能删。
      expect(await store.segmentCount(), 1);
      expect((await store.loadVariant('b2', 0))![1].content, '同一个回答');

      await store.deleteThread(other);
      expect(await store.segmentCount(), 0);
    });
  });

  group('从旧版本的库升上来', () {
    test('v9 的库升到 v10：老消息还在，分支功能能用', () async {
      final dir = await Directory.systemTemp.createTemp('burrow_migrate');
      final path = '${dir.path}/old.db';

      // 造一个 v9 的库：有 messages 表但没有 branch_id，也没有分支那两张表。
      final old = await databaseFactory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 9,
          onCreate: (db, _) async {
            await db.execute('''
              CREATE TABLE threads(
                id TEXT PRIMARY KEY, title TEXT NOT NULL, preview TEXT NOT NULL,
                updated_at INTEGER NOT NULL,
                terminal_mode INTEGER NOT NULL DEFAULT 0, system_prompt TEXT)
            ''');
            await db.execute('''
              CREATE TABLE messages(
                id INTEGER PRIMARY KEY AUTOINCREMENT, thread_id TEXT NOT NULL,
                role TEXT NOT NULL, content TEXT NOT NULL,
                created_at INTEGER NOT NULL, output_ref TEXT, checkpoint INTEGER,
                source TEXT, images TEXT, tokens_in INTEGER, tokens_out INTEGER,
                tokens_cached INTEGER, tokens_estimated INTEGER,
                reasoning TEXT, reasoning_ms INTEGER)
            ''');
            await db.insert('threads', <String, Object?>{
              'id': 't1',
              'title': '老会话',
              'preview': '老消息',
              'updated_at': 1000,
            });
            await db.insert('messages', <String, Object?>{
              'thread_id': 't1',
              'role': 'user',
              'content': '老消息',
              'created_at': 1000,
            });
          },
        ),
      );
      await old.close();

      // 升级发生在这一步。挂了的话用户的表现是"更新完 App 打不开了"。
      final upgraded = await ChatStore.openAt(path);
      final messages = await upgraded.messages('t1');
      expect(messages.single.content, '老消息', reason: '老对话不该被升级弄丢');
      expect(messages.single.branchId, isNull);

      // 新表也得真的建出来，否则第一次点"重新生成"才会炸。
      await upgraded.saveVariant(
        threadId: 't1',
        branchId: 'b1',
        tail: <ChatMessage>[user('老消息'), reply('新回答')],
      );
      expect((await upgraded.branchStateOf('b1'))!.total, 1);

      await upgraded.close();
      if (await dir.exists()) await dir.delete(recursive: true);
    });
  });

  group('branch_id 跟着消息一起持久化', () {
    test('存进 messages 表再读出来还在', () async {
      await store.replaceMessages(thread, <ChatMessage>[
        user('带锚点的', branchId: 'b1'),
        reply('回答'),
      ]);
      final back = await store.messages(thread);
      expect(back[0].branchId, 'b1');
      // 没分支的消息该是 null，不是空串 —— UI 靠这个判断要不要画切换器。
      expect(back[1].branchId, isNull);
    });
  });
}
