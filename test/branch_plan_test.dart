/// 分支：锚点选在哪、界面那一条怎么找回来、版本怎么删。
///
/// 这一组里最要紧的是「刚发完消息就重新生成」那一条。它钉的是一个查了很久的
/// bug：分支数据全都写进了库，界面上却一个版本切换器都不画，而**重开一次
/// 会话就好了** —— 于是它看起来像个随机故障，实际上是两个列表里同一条消息
/// 不是同一个对象。
@TestOn('vm')
library;

import 'package:burrow/src/context/overflow_manager.dart';
import 'package:burrow/src/data/chat_store.dart';
import 'package:burrow/src/ui/branch_plan.dart';
import 'package:burrow/src/ui/message_index.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

ChatMessage msg(String role, String content) =>
    ChatMessage(role: role, content: content, at: DateTime(2026));

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('分支锚点', () {
    test('一问一答：锚在那条问话上', () {
      final history = <ChatMessage>[msg('user', '你好'), msg('assistant', '你好呀')];
      expect(forkPivotIndex(history, 1), 0);
    });

    test('一轮说了好几段：重新生成第二段只换第二段', () {
      // 锚在用户那条的话，第一段也会被一起丢掉 —— 而用户只是想让
      // 后半段换个说法。
      final history = <ChatMessage>[
        msg('user', '讲讲'),
        msg('assistant', '先说结论'),
        msg('assistant', '再说细节'),
      ];
      expect(forkPivotIndex(history, 2), 1);
    });

    test('工具循环：锚在工具结果上，命令不用重跑', () {
      final history = <ChatMessage>[
        msg('user', '看看磁盘'),
        msg('assistant', '我执行一下 df'),
        msg('tool', 'Filesystem  Size'),
        msg('assistant', '还剩 12G'),
      ];
      expect(forkPivotIndex(history, 3), 2);
    });

    test('跳过只给模型看的注入内容', () {
      // 检索注入每轮现算，下一轮就换内容了。锚在上面的话，切回来的时候
      // 那条锚点已经不是同一句话。
      final history = <ChatMessage>[
        msg('user', '继续'),
        msg('system', '[检索] 之前提到过 nginx'),
        msg('assistant', '好的'),
      ];
      expect(forkPivotIndex(history, 2), 0);
    });

    test('对话的第一条没有可锚的位置', () {
      final history = <ChatMessage>[msg('user', '你好')];
      expect(forkPivotIndex(history, 0), -1);
    });

    test('前面全是注入内容时也算没有', () {
      final history = <ChatMessage>[
        msg('system', '你是一个助手'),
        msg('user', '你好'),
      ];
      expect(forkPivotIndex(history, 1), -1);
    });

    test('越界的下标不会崩', () {
      expect(forkPivotIndex(<ChatMessage>[], 0), -1);
      expect(forkPivotIndex(<ChatMessage>[msg('user', 'a')], 9), -1);
    });
  });

  group('history 下标对回界面', () {
    test('同一批实例时按身份精确命中', () {
      final user = msg('user', '你好');
      final tool = msg('tool', '[工具结果]');
      final reply = msg('assistant', '你好呀');
      final history = <ChatMessage>[user, tool, reply];
      final visible = <ChatMessage>[user, tool, reply];
      expect(visibleIndexOfHistory(visible, history, 2), 2);
    });

    test('刚发出去的用户消息：两边不是同一个对象，也要找得到', () {
      // **这就是"重新生成有时候不创建分支点"的现场。**
      // 界面在 _send 里 new 了一条，AgentLoop 在自己那边又 new 了一条。
      // 只用 identical 找的话这里返回 -1，分支 id 就只挂到了 history 那条
      // 上 —— 库里有分支，界面上什么都没有。
      final history = <ChatMessage>[
        msg('user', '你好'),
        msg('assistant', '你好呀'),
        msg('user', '再问一句'), // AgentLoop 那条
      ];
      final visible = <ChatMessage>[
        history[0],
        history[1],
        msg('user', '再问一句'), // 界面那条，内容一样但不是同一个对象
      ];
      expect(visibleIndexOfHistory(visible, history, 2), 2);
    });

    test('界面只装了尾巴时也要对得上 —— 从末尾数起', () {
      // 分页加载：history 是完整的，_visible 只有最后几条。从前往后数序号
      // 的话，前面缺了几条就整体偏移几位，挂到一条更早的消息上。
      final history = <ChatMessage>[
        msg('user', '第一问'),
        msg('assistant', '第一答'),
        msg('user', '第二问'),
        msg('assistant', '第二答'),
        msg('user', '第三问'), // AgentLoop 那条
      ];
      final visible = <ChatMessage>[
        history[3],
        msg('user', '第三问'), // 界面那条，另一个实例
      ];
      expect(visibleIndexOfHistory(visible, history, 4), 1);
    });

    test('长会话里刚发出去那条：分页 + 换了实例，两件事叠在一起', () {
      // 这是真实现场：几百条历史只显示最后几十条，而最后那条用户消息
      // 又是两个不同的对象。以前这两件事各自都能让分支 id 挂不上界面。
      final history = <ChatMessage>[
        for (var i = 0; i < 40; i++)
          msg(i.isEven ? 'user' : 'assistant', '第 $i 条'),
        msg('user', '最新一问'),
      ];
      final visible = <ChatMessage>[
        ...history.sublist(36, 40),
        msg('user', '最新一问'),
      ];
      expect(visibleIndexOfHistory(visible, history, 40), 4);
    });

    test('助手条数对不上时宁可放弃', () {
      // 一条气泡不一定对应 history 里的一条（工具循环里会合并）。
      // 猜错的后果是把分支 id 挂到别的消息上。
      final history = <ChatMessage>[
        msg('user', 'a'),
        msg('assistant', 'b1'),
        msg('assistant', 'b2'),
      ];
      final visible = <ChatMessage>[msg('user', 'a'), msg('assistant', 'b')];
      expect(visibleIndexOfHistory(visible, history, 2), -1);
    });

    test('工具消息没有兜底 —— 找不到就是找不到', () {
      final history = <ChatMessage>[msg('user', 'a'), msg('tool', 'out')];
      final visible = <ChatMessage>[msg('user', 'a'), msg('tool', 'out')];
      expect(visibleIndexOfHistory(visible, history, 1), -1);
    });

    test('越界的下标不会崩', () {
      expect(visibleIndexOfHistory(<ChatMessage>[], <ChatMessage>[], 0), -1);
    });
  });

  group('切走之前要把现在这一段写回去', () {
    // **这一组钉的是一次真实的数据丢失。**
    //
    // "正在看的那一版"的内容其实活在活动路径上，branches 里那一行只是它
    // 上次被换下去时的快照。切到版本 0、接着又聊了五轮、再切回版本 1 ——
    // 那五轮连同回复一起消失，而且没有任何提示。
    //
    // chatbox 那边是同一句话：切换时 `save currentTail to it`
    // （见 switchForkInMessages）。
    late ChatStore store;

    setUp(() async {
      store = await ChatStore.openAt(inMemoryDatabasePath);
    });

    tearDown(() => store.close());

    test('写回之后切回来还是最新的那一段', () async {
      final id = await store.createThread('甲', preferredId: 't1');
      // 版本 0：原来的回答。版本 1：重新生成的，当前活动。
      await store.saveVariant(
        threadId: id,
        branchId: 'b1',
        tail: <ChatMessage>[msg('user', '问'), msg('assistant', '第一版')],
      );
      await store.saveVariant(
        threadId: id,
        branchId: 'b1',
        tail: <ChatMessage>[msg('user', '问'), msg('assistant', '第二版')],
      );
      await store.setActiveVariant('b1', 0);

      // 用户在版本 0 上又聊了两轮。
      await store.updateVariant(
        threadId: id,
        branchId: 'b1',
        index: 0,
        tail: <ChatMessage>[
          msg('user', '问'),
          msg('assistant', '第一版'),
          msg('user', '追问'),
          msg('assistant', '追答'),
        ],
      );

      // 切到版本 1 再切回来 —— 那两轮必须还在。
      expect((await store.loadVariant('b1', 1))!.last.content, '第二版');
      final back = (await store.loadVariant('b1', 0))!;
      expect(back.length, 4);
      expect(back.last.content, '追答');
    });

    test('写回不动别的版本', () async {
      final id = await store.createThread('甲', preferredId: 't1');
      for (final text in <String>['第一版', '第二版', '第三版']) {
        await store.saveVariant(
          threadId: id,
          branchId: 'b1',
          tail: <ChatMessage>[msg('user', '问'), msg('assistant', text)],
        );
      }
      await store.updateVariant(
        threadId: id,
        branchId: 'b1',
        index: 1,
        tail: <ChatMessage>[msg('user', '问'), msg('assistant', '改过的')],
      );
      expect((await store.loadVariant('b1', 0))!.last.content, '第一版');
      expect((await store.loadVariant('b1', 1))!.last.content, '改过的');
      expect((await store.loadVariant('b1', 2))!.last.content, '第三版');
      // 总数不变 —— 写回是换内容，不是再开一个槽。开新槽的话，切回去看到的
      // 仍然是旧快照，那几轮照样丢。
      expect((await store.branchStateOf('b1'))!.total, 3);
    });

    test('内容没变时什么都不做', () async {
      // 先减后加会在中间那一瞬把 ref_count 打到 0，而那正好是删除条件 ——
      // 段被回收掉，而新指针马上又指向它。
      final id = await store.createThread('甲', preferredId: 't1');
      final tail = <ChatMessage>[msg('user', '问'), msg('assistant', '答')];
      await store.saveVariant(threadId: id, branchId: 'b1', tail: tail);
      await store.updateVariant(
        threadId: id,
        branchId: 'b1',
        index: 0,
        tail: tail,
      );
      expect((await store.loadVariant('b1', 0))!.last.content, '答');
      expect((await store.raw.query('segments')).length, 1);
    });

    test('换掉之后旧内容的引用计数跟着放', () async {
      final id = await store.createThread('甲', preferredId: 't1');
      await store.saveVariant(
        threadId: id,
        branchId: 'b1',
        tail: <ChatMessage>[msg('user', '问'), msg('assistant', '旧的')],
      );
      await store.updateVariant(
        threadId: id,
        branchId: 'b1',
        index: 0,
        tail: <ChatMessage>[msg('user', '问'), msg('assistant', '新的')],
      );
      // 旧那一段没人引用了就该没。留着的话它在任何界面上都看不见，
      // 只是慢慢把存储吃掉。
      final rows = await store.raw.query('segments');
      expect(rows.length, 1);
    });

    test('两个版本内容相同时，写回不会把共用的那一段回收掉', () async {
      final id = await store.createThread('甲', preferredId: 't1');
      final shared = <ChatMessage>[msg('user', '问'), msg('assistant', '一样的')];
      await store.saveVariant(threadId: id, branchId: 'b1', tail: shared);
      await store.saveVariant(
        threadId: id,
        branchId: 'b2',
        tail: shared,
      );
      await store.updateVariant(
        threadId: id,
        branchId: 'b1',
        index: 0,
        tail: <ChatMessage>[msg('user', '问'), msg('assistant', '换了')],
      );
      // b2 还指着那一段，不能因为 b1 放手就没了。
      expect((await store.loadVariant('b2', 0))!.last.content, '一样的');
    });

    test('槽不存在时安静地什么都不做', () async {
      final id = await store.createThread('甲', preferredId: 't1');
      await expectLater(
        store.updateVariant(
          threadId: id,
          branchId: 'b1',
          index: 7,
          tail: <ChatMessage>[msg('user', 'x')],
        ),
        completes,
      );
    });
  });

  group('删掉一个版本', () {
    late ChatStore store;

    setUp(() async {
      store = await ChatStore.openAt(inMemoryDatabasePath);
    });

    tearDown(() => store.close());

    Future<String> seed(int count) async {
      final id = await store.createThread('甲', preferredId: 't1');
      for (var i = 0; i < count; i++) {
        await store.saveVariant(
          threadId: id,
          branchId: 'b1',
          tail: <ChatMessage>[msg('user', '问'), msg('assistant', '第 $i 版')],
        );
      }
      return id;
    }

    test('删完之后总数少一个', () async {
      await seed(3);
      expect(await store.deleteVariant('b1', 1), 2);
      expect((await store.branchStateOf('b1'))!.total, 2);
    });

    test('剩下的重新编号成连续的 0..n-1', () async {
      // 留着洞的话，界面上那个「几/几」会出现 3/2 这种东西。
      await seed(3);
      await store.deleteVariant('b1', 0);
      expect((await store.loadVariant('b1', 0))!.last.content, '第 1 版');
      expect((await store.loadVariant('b1', 1))!.last.content, '第 2 版');
      expect(await store.loadVariant('b1', 2), isNull);
    });

    test('删掉正在看的那个：活动位往前退一个', () async {
      await seed(3); // 最后存的那个是活动版，序号 2
      expect((await store.branchStateOf('b1'))!.active, 2);
      await store.deleteVariant('b1', 2);
      expect((await store.branchStateOf('b1'))!.active, 1);
    });

    test('删掉第 0 个而它正在看：活动位停在新的第 0 个', () async {
      await seed(3);
      await store.setActiveVariant('b1', 0);
      await store.deleteVariant('b1', 0);
      expect((await store.branchStateOf('b1'))!.active, 0);
    });

    test('删掉别人时，正在看的那一版还是同一段内容', () async {
      await seed(3);
      await store.setActiveVariant('b1', 2);
      await store.deleteVariant('b1', 0);
      final state = (await store.branchStateOf('b1'))!;
      expect(state.total, 2);
      expect(
          (await store.loadVariant('b1', state.active))!.last.content, '第 2 版');
    });

    test('删光之后这个分支点就不存在了', () async {
      await seed(1);
      expect(await store.deleteVariant('b1', 0), 0);
      expect(await store.branchStateOf('b1'), isNull);
    });

    test('内容的引用计数跟着减，不留孤儿段', () async {
      // 只删指针不减计数的话，那一段永久占着空间，而且任何界面上都看不见。
      await seed(2);
      await store.deleteVariant('b1', 0);
      await store.deleteVariant('b1', 0);
      final rows = await store.raw.query('segments');
      expect(rows, isEmpty);
    });

    test('删一个不存在的序号：什么都不动', () async {
      await seed(2);
      expect(await store.deleteVariant('b1', 7), 2);
      expect((await store.branchStateOf('b1'))!.total, 2);
    });
  });
}
