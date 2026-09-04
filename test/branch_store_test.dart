@TestOn('vm')
library;

import 'dart:io';

import 'package:burrow/src/agent/agent_loop.dart' show TokenUsage;
import 'package:burrow/src/context/overflow_manager.dart';
import 'package:burrow/src/data/chat_store.dart';
import 'package:burrow/src/settings/thread_lock.dart';
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

ChatMessage toolStep(
  String title, {
  bool ok = true,
  int ms = 0,
  String name = 'exec',
}) =>
    ChatMessage(
      role: 'tool',
      content: '$title 的输出',
      at: DateTime.fromMillisecondsSinceEpoch(1500),
      toolName: name,
      toolTitle: title,
      toolOk: ok,
      toolMs: ms,
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

    test('v12 的库升到 v13：阅读位置从空开始，不影响老会话', () async {
      final dir = await Directory.systemTemp.createTemp('burrow_migrate13');
      final path = '${dir.path}/old.db';

      final old = await databaseFactory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 12,
          onCreate: (db, _) async {
            await db.execute('''
              CREATE TABLE threads(
                id TEXT PRIMARY KEY, title TEXT NOT NULL, preview TEXT NOT NULL,
                updated_at INTEGER NOT NULL,
                terminal_mode INTEGER NOT NULL DEFAULT 0, system_prompt TEXT,
                summary TEXT, summary_checkpoint INTEGER)
            ''');
            await db.execute('''
              CREATE TABLE messages(
                id INTEGER PRIMARY KEY AUTOINCREMENT, thread_id TEXT NOT NULL,
                role TEXT NOT NULL, content TEXT NOT NULL,
                created_at INTEGER NOT NULL, output_ref TEXT, checkpoint INTEGER,
                source TEXT, images TEXT, tokens_in INTEGER, tokens_out INTEGER,
                tokens_cached INTEGER, tokens_estimated INTEGER,
                reasoning TEXT, reasoning_ms INTEGER, branch_id TEXT,
                tool_name TEXT, tool_title TEXT, tool_ok INTEGER,
                tool_ms INTEGER)
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

      final upgraded = await ChatStore.openAt(path);
      expect((await upgraded.messages('t1')).single.content, '老消息');
      // 老会话没记过位置 —— 打开时直接到最新，和升级前一模一样。
      expect(await upgraded.lastReadOf('t1'), isNull);

      await upgraded.setLastRead('t1', 42);
      expect(await upgraded.lastReadOf('t1'), 42);
      // 回到底部时记回 null：null 和某个 id 是两种不同的意思，
      // 混起来的话"我明明拉到底了，下次打开还停在半路"。
      await upgraded.setLastRead('t1', null);
      expect(await upgraded.lastReadOf('t1'), isNull);

      await upgraded.close();
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('v11 的库升到 v12：老会话读得出来，摘要状态从空开始', () async {
      final dir = await Directory.systemTemp.createTemp('burrow_migrate12');
      final path = '${dir.path}/old.db';

      // v11：threads 还没有 summary / summary_checkpoint 两列。
      final old = await databaseFactory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 11,
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
                reasoning TEXT, reasoning_ms INTEGER, branch_id TEXT,
                tool_name TEXT, tool_title TEXT, tool_ok INTEGER,
                tool_ms INTEGER)
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

      final upgraded = await ChatStore.openAt(path);
      expect((await upgraded.messages('t1')).single.content, '老消息');
      // 老会话没摘过 —— 读回来就是"还没摘过"，和升级前的行为一模一样。
      expect(await upgraded.memoryOf('t1'), isNull);

      // 新列真的建出来了才写得进去。没建的话第一次发消息就炸。
      await upgraded.setMemory('t1', '一段摘要', 12);
      final memory = (await upgraded.memoryOf('t1'))!;
      expect(memory.summary, '一段摘要');
      expect(memory.checkpoint, 12);

      // 清掉之后 checkpoint 也得跟着没 —— 留着一个指向"没有摘要"的下标，
      // 恢复时会把一批消息踢出窗口而没有东西顶上。
      await upgraded.setMemory('t1', null, 12);
      expect(await upgraded.memoryOf('t1'), isNull);

      await upgraded.close();
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('v10 的库升到 v11：老的工具消息读得出来，且默认算成功', () async {
      final dir = await Directory.systemTemp.createTemp('burrow_migrate11');
      final path = '${dir.path}/old.db';

      // v10：有 branch_id，但还没有 tool_* 那四列。
      final old = await databaseFactory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 10,
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
                reasoning TEXT, reasoning_ms INTEGER, branch_id TEXT)
            ''');
            await db.insert('threads', <String, Object?>{
              'id': 't1',
              'title': '老会话',
              'preview': '结果',
              'updated_at': 1000,
            });
            await db.insert('messages', <String, Object?>{
              'thread_id': 't1',
              'role': 'tool',
              'content': '老命令的输出',
              'created_at': 1000,
            });
          },
        ),
      );
      await old.close();

      final upgraded = await ChatStore.openAt(path);
      final tool = (await upgraded.messages('t1')).single;
      expect(tool.content, '老命令的输出');
      expect(tool.toolOk, isTrue, reason: '没记过成败的老命令不该被画成失败');
      expect(tool.toolTitle, isNull);

      // 新列真的建出来了才写得进去。没建的话第一次跑命令就炸。
      await upgraded.append(
        't1',
        toolStep('echo hi', ms: 5),
      );
      final back = await upgraded.messages('t1');
      expect(back.last.toolTitle, 'echo hi');

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
  group('工具调用要能存回来', () {
    // 卡片上那三样东西（是谁跑的、成没成、跑了多久）只在内存里的话，
    // 重开会话就只剩一坨结果正文 —— 而助手气泡照样是断开的，
    // 中间那个"为什么断"就又没了。

    test('消息表存得下工具那几个字段', () async {
      await store.replaceMessages(thread, <ChatMessage>[
        user('装个 sshpass'),
        reply('这就装'),
        toolStep('apt install -y sshpass', ms: 42000),
        reply('装好了'),
      ]);

      final back = await store.messages(thread);
      final tool = back.firstWhere((m) => m.role == 'tool');
      expect(tool.toolName, 'exec');
      expect(tool.toolTitle, 'apt install -y sshpass');
      expect(tool.toolOk, isTrue);
      expect(tool.toolMs, 42000);
    });

    test('失败状态不会在存回来之后变成成功', () async {
      await store.replaceMessages(
          thread, <ChatMessage>[toolStep('rm -rf /nope', ok: false)]);

      final back = await store.messages(thread);
      expect(back.single.toolOk, isFalse);
    });

    test('老消息（这一列是 NULL）默认算成功', () async {
      // v11 之前存进去的 tool 消息没有这一列。给它画个红叉比不画更误导 ——
      // 那些命令当时多半是成功的，只是没人记下来。
      await store.append(
        thread,
        ChatMessage(
          role: 'tool',
          content: '很久以前的输出',
          at: DateTime.fromMillisecondsSinceEpoch(1),
        ),
      );

      final back = await store.messages(thread);
      final tool = back.firstWhere((m) => m.role == 'tool');
      expect(tool.toolOk, isTrue);
      expect(tool.toolTitle, isNull, reason: '没有标题就让界面退回工具名');
      expect(tool.toolMs, 0);
    });

    test('分支版本里的工具步骤也一起存', () async {
      // 分支走的是另一条序列化路径（JSON 段），漏一个字段的话
      // 切换版本之后卡片会突然变空。
      final tail = <ChatMessage>[
        user('试试看'),
        toolStep('ls -la', ms: 120),
        reply('好了'),
      ];
      await store.saveVariant(threadId: thread, branchId: 'b1', tail: tail);

      final back = (await store.loadVariant('b1', 0))!;
      final tool = back.firstWhere((m) => m.role == 'tool');
      expect(tool.toolTitle, 'ls -la');
      expect(tool.toolMs, 120);
      expect(tool.toolOk, isTrue);
    });
  });


  group('删会话之后库里还剩什么', () {
    late Directory tmp;
    late ChatStore store;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('burrow_gc');
      store = await ChatStore.openAt('${tmp.path}/gc.db');
    });

    tearDown(() async {
      await store.close();
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    /// 直接查表。回收干没干净只有这里看得见 —— 上层 API 一律返回"没有了"，
    /// 而孤儿行恰恰是那种"查询看不见、空间一直占着"的东西。
    Future<int> rows(String table) async {
      final r = await store.raw.rawQuery('SELECT COUNT(*) AS n FROM $table');
      return r.first['n']! as int;
    }

    test('消息、分支、分支内容都跟着走', () async {
      final id = await store.createThread('第一句');
      await store.append(id, user('第一句'));
      await store.append(id, reply('第一答'));
      await store.saveVariant(
        threadId: id,
        branchId: 'b1',
        tail: <ChatMessage>[user('第一句'), reply('另一个答法')],
      );
      expect(await rows('segments'), 1);

      await store.deleteThread(id);

      expect(await rows('threads'), 0);
      expect(await rows('messages'), 0);
      expect(await rows('branches'), 0);
      // 只删 branches 不减 segments 的话，那些段会变成谁也引用不到的孤儿，
      // 永久占着空间 —— 而且任何一个界面上都看不见。
      expect(await rows('segments'), 0);
    });

    test('两个会话共用同一段内容时，删一个不会连累另一个', () async {
      final a = await store.createThread('甲');
      final b = await store.createThread('乙');
      final tail = <ChatMessage>[user('一样的话'), reply('一样的答')];
      await store.saveVariant(threadId: a, branchId: 'ba', tail: tail);
      await store.saveVariant(threadId: b, branchId: 'bb', tail: tail);
      // 内容一样 → 同一个 hash → 只存一份，引用计数是 2。
      expect(await rows('segments'), 1);

      await store.deleteThread(a);
      expect(await rows('segments'), 1, reason: '乙还在用它');

      await store.deleteThread(b);
      expect(await rows('segments'), 0);
    });

    test('阅读位置和摘要跟着 threads 行一起没', () async {
      final id = await store.createThread('甲');
      await store.append(id, user('甲'));
      await store.setLastRead(id, 7);
      await store.setMemory(id, '一段摘要', 3);

      await store.deleteThread(id);
      expect(await rows('threads'), 0);
      // 行没了，这两列自然也没了。单独留一行"某个不存在会话的阅读位置"
      // 会在 id 撞上时把位置安到别人头上。
      expect(await store.lastReadOf(id), isNull);
      expect(await store.memoryOf(id), isNull);
    });
  });

  group('分页读取', () {
    late Directory tmp;
    late ChatStore store;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('burrow_paging');
      store = await ChatStore.openAt('${tmp.path}/paging.db');
    });

    tearDown(() async {
      await store.close();
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    /// 造一段有 [n] 条消息的历史，每条内容都能认出序号。
    Future<String> seed(int n, {int chars = 100}) async {
      final id = await store.createThread('第 0 条');
      for (var i = 0; i < n; i++) {
        await store.append(id, user('#$i ${'x' * chars}'));
      }
      return id;
    }

    test('只读最后一段，而且是升序', () async {
      final id = await seed(60, chars: 100);
      // 每条约 132 字符（含 32 的每条开销），预算 500 token
      // ≈ 325 字符 → 大概两三条。
      final tail = await store.tailMessages(id, tokenBudget: 500);

      expect(tail.length, lessThan(10), reason: '整段都读回来就等于没分页');
      expect(tail.isNotEmpty, isTrue);
      expect(tail.last.content, startsWith('#59'), reason: '最后一条必须是最新的');
      // 升序，和 messages() 一致 —— 顺序反了的话界面上整段对话是倒的。
      for (var i = 1; i < tail.length; i++) {
        expect(tail[i - 1].messageId! < tail[i].messageId!, isTrue);
      }
    });

    test('条数上限先到就按条数收', () async {
      final id = await seed(60, chars: 10);
      // 一屏也就放得下五六条，多读的每一条都是首屏之前的纯等待。
      final tail = await store.tailMessages(
        id,
        tokenBudget: 1000000,
        messageLimit: 20,
      );
      expect(tail, hasLength(20));
      expect(tail.last.content, startsWith('#59'));
    });

    test('一条超长消息时 token 预算先到，不被条数上限撑爆', () async {
      final id = await seed(30, chars: 20000);
      final tail = await store.tailMessages(
        id,
        tokenBudget: 2000,
        messageLimit: 40,
      );
      // 条数上限给了 40，但一条就顶穿了预算 —— 按条数切会让这一页大得离谱。
      expect(tail.length, lessThan(5));
    });

    test('预算再小也至少给一条', () async {
      final id = await seed(5, chars: 4000);
      // 返回空会被上层当成"没有更早的了"，于是那条超长消息之前的历史
      // 就再也翻不出来。
      final tail = await store.tailMessages(id, tokenBudget: 1);
      expect(tail, hasLength(1));
      expect(tail.single.content, startsWith('#4'));
    });

    test('before 往前翻，不会把同一条给两遍', () async {
      final id = await seed(40, chars: 100);
      final first = await store.tailMessages(id, tokenBudget: 500);
      final second = await store.tailMessages(
        id,
        tokenBudget: 500,
        before: first.first.messageId,
      );

      expect(second, isNotEmpty);
      expect(second.last.messageId! < first.first.messageId!, isTrue);
      final ids = <int>{
        for (final m in <ChatMessage>[...first, ...second]) m.messageId!,
      };
      expect(ids.length, first.length + second.length, reason: '有重复');
    });

    test('翻到头返回空', () async {
      final id = await seed(3, chars: 10);
      final all = await store.tailMessages(id, tokenBudget: 1000000);
      expect(all, hasLength(3));
      final more = await store.tailMessages(
        id,
        tokenBudget: 1000000,
        before: all.first.messageId,
      );
      expect(more, isEmpty);
    });

    test('分页读回来的字段和全量读一模一样', () async {
      // 两条路各写一遍 map 的话，以后加一列必然会漏掉其中一处，
      // 而漏掉的表现是「翻上去之后那几条消息少了点东西」。
      final id = await store.createThread('甲');
      await store.append(id, toolStep('echo hi', ms: 5));
      final full = (await store.messages(id)).last;
      final paged =
          (await store.tailMessages(id, tokenBudget: 1000000)).last;

      expect(paged.messageId, full.messageId);
      expect(paged.role, full.role);
      expect(paged.content, full.content);
      expect(paged.toolName, full.toolName);
      expect(paged.toolTitle, full.toolTitle);
      expect(paged.toolOk, full.toolOk);
      expect(paged.toolMs, full.toolMs);
    });

    test('数得清一共多少条', () async {
      final id = await seed(7, chars: 10);
      expect(await store.messageCountOf(id), 7);
      expect(await store.messageCountOf('没这个会话'), 0);
    });
  });

  group('会话锁的持久化', () {
    late Directory tmp;
    late ChatStore store;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('burrow_lock');
      store = await ChatStore.openAt('${tmp.path}/lock.db');
    });

    tearDown(() async {
      await store.close();
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    ThreadLock sample() {
      const salt = 'abc123';
      return ThreadLock(
        salt: salt,
        hash: derivePasscode('pw', salt),
        challenges: const <LockChallenge>[
          LockChallenge.builtIn(LockQuestion.model),
        ],
      );
    }

    test('存下来再读出来还开得了', () async {
      final id = await store.createThread('甲');
      expect(await store.lockOf(id), isNull);

      await store.setLock(id, sample());
      final back = (await store.lockOf(id))!;
      expect(checkPasscode(back, 'pw'), isTrue);
      expect(back.challenges.single.question, LockQuestion.model);
    });

    test('撤掉之后就没了', () async {
      final id = await store.createThread('甲');
      await store.setLock(id, sample());
      await store.setLock(id, null);
      expect(await store.lockOf(id), isNull);
    });

    test('一次问出哪些锁着', () async {
      final a = await store.createThread('甲');
      final b = await store.createThread('乙');
      await store.setLock(a, sample());
      // 抽屉里几十行，每行各问一次库的话，那把小锁会一个一个地冒出来。
      expect(await store.lockedThreadIds(), <String>{a});
      expect(await store.lockedThreadIds(), isNot(contains(b)));
    });

    test('这一列坏掉时当成没锁，而不是一把打不开的锁', () async {
      final id = await store.createThread('甲');
      await store.setLock(id, sample());
      await store.raw.update('threads', <String, Object?>{'lock_json': '坏了'});
      // 反过来（当成锁着但打不开）会把用户自己的对话变成谁也进不去的黑洞，
      // 而这道锁本来就只挡"别人拿起手机点进来"，不值得用永久锁死来兑现。
      expect(await store.lockOf(id), isNull);
    });

    test('删会话时锁跟着一起没', () async {
      final id = await store.createThread('甲');
      await store.setLock(id, sample());
      await store.deleteThread(id);
      expect(await store.lockedThreadIds(), isEmpty);
    });

    test('v13 的库升到 v14：老会话都是没锁的', () async {
      final dir = await Directory.systemTemp.createTemp('burrow_migrate14');
      final path = '${dir.path}/old.db';
      final old = await databaseFactory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 13,
          onCreate: (db, _) async {
            await db.execute('''
              CREATE TABLE threads(
                id TEXT PRIMARY KEY, title TEXT NOT NULL, preview TEXT NOT NULL,
                updated_at INTEGER NOT NULL,
                terminal_mode INTEGER NOT NULL DEFAULT 0, system_prompt TEXT,
                summary TEXT, summary_checkpoint INTEGER,
                last_read_message_id INTEGER)
            ''');
            await db.execute('''
              CREATE TABLE messages(
                id INTEGER PRIMARY KEY AUTOINCREMENT, thread_id TEXT NOT NULL,
                role TEXT NOT NULL, content TEXT NOT NULL,
                created_at INTEGER NOT NULL, output_ref TEXT, checkpoint INTEGER,
                source TEXT, images TEXT, tokens_in INTEGER, tokens_out INTEGER,
                tokens_cached INTEGER, tokens_estimated INTEGER,
                reasoning TEXT, reasoning_ms INTEGER, branch_id TEXT,
                tool_name TEXT, tool_title TEXT, tool_ok INTEGER,
                tool_ms INTEGER)
            ''');
            await db.insert('threads', <String, Object?>{
              'id': 't1',
              'title': '老会话',
              'preview': '老消息',
              'updated_at': 1000,
            });
          },
        ),
      );
      await old.close();

      final upgraded = await ChatStore.openAt(path);
      expect(await upgraded.lockOf('t1'), isNull);
      // 新列真的建出来了才写得进去。
      await upgraded.setLock('t1', sample());
      expect(await upgraded.lockOf('t1'), isNotNull);

      await upgraded.close();
      if (await dir.exists()) await dir.delete(recursive: true);
    });
  });
}
