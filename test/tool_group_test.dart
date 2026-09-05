/// 连着好几步命令时把它们收成一行。
///
/// 单张卡片已经压得很扁了，但一个回合跑七八条命令时，七八行加起来照样占掉
/// 大半屏 —— 而用户真正要读的是那几行命令**之后**模型说了什么。
@TestOn('vm')
library;

import 'package:burrow/src/context/overflow_manager.dart';
import 'package:burrow/src/ui/chat_theme.dart';
import 'package:burrow/src/ui/message_index.dart';
import 'package:burrow/src/ui/tool_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ChatMessage msg(String role, [String content = 'x']) =>
    ChatMessage(role: role, content: content, at: DateTime(2026));

Widget host(Widget child) => MaterialApp(
      theme: ThemeData(extensions: const <ThemeExtension<dynamic>>[
        ChatTokens.dark,
      ]),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  group('哪几条算一串', () {
    test('连着的工具调用一直数到最后一条', () {
      final log = <ChatMessage>[
        msg('user'),
        msg('assistant'),
        msg('tool'),
        msg('tool'),
        msg('tool'),
        msg('assistant'),
      ];
      expect(toolRunEnd(log, 2), 4);
    });

    test('只有一条时返回它自己 —— 调用方据此不收', () {
      // 一步的摘要行和它自己那张卡片一样高，收起来纯粹是多让人点一下。
      final log = <ChatMessage>[msg('assistant'), msg('tool'), msg('user')];
      expect(toolRunEnd(log, 1), 1);
    });

    test('中间被模型说的一句话隔开就断开', () {
      // 那句话通常正是"我接下来要干嘛"，把它折进命令堆里等于把线索一起藏掉。
      final log = <ChatMessage>[
        msg('tool'),
        msg('tool'),
        msg('assistant', '接下来看看日志'),
        msg('tool'),
      ];
      expect(toolRunEnd(log, 0), 1);
      expect(toolRunEnd(log, 3), 3);
    });

    test('不是工具调用就原样返回', () {
      final log = <ChatMessage>[msg('user'), msg('tool'), msg('tool')];
      expect(toolRunEnd(log, 0), 0);
    });

    test('越界不会崩', () {
      expect(toolRunEnd(<ChatMessage>[], 0), 0);
      expect(toolRunEnd(<ChatMessage>[msg('tool')], 9), 9);
      expect(toolRunEnd(<ChatMessage>[msg('tool')], -1), -1);
    });

    test('一串一直排到列表末尾也不会越界', () {
      final log = <ChatMessage>[msg('tool'), msg('tool')];
      expect(toolRunEnd(log, 0), 1);
    });
  });

  group('收起来那一行', () {
    // 展开状态是**传进来的**，由聊天页记着（见 _HomeShellState
    // ._expandedToolGroups）。这一组测试连同这个契约一起钉：
    // 这一行自己不记状态，所以它被回收重建也丢不了东西。
    Widget group({
      int count = 3,
      int failed = 0,
      int elapsedMs = 0,
      required bool expanded,
      VoidCallback? onToggle,
    }) =>
        host(ToolCallGroup(
          count: count,
          failed: failed,
          elapsedMs: elapsedMs,
          lastTitle: 'tail -n 50 /var/log/nginx/error.log',
          expanded: expanded,
          onToggle: onToggle ?? () {},
          cards: <Widget>[
            for (var i = 0; i < count; i++) Text('第 $i 步'),
          ],
        ));

    testWidgets('收着时：只有摘要，那几张卡片根本没建出来', (tester) async {
      await tester.pumpWidget(group(expanded: false));
      expect(find.text('执行了 3 步'), findsOneWidget);
      // **不是藏起来，是没建。** 藏起来的卡片照样要布局、照样占着 State，
      // 一段跑了几十条命令的历史光是那些看不见的输出就够拖慢滑动了。
      expect(find.text('第 0 步'), findsNothing);
    });

    testWidgets('收着时给最后一步的命令行当线索', (tester) async {
      await tester.pumpWidget(group(expanded: false));
      expect(find.text('tail -n 50 /var/log/nginx/error.log'), findsOneWidget);
    });

    testWidgets('展开时那几步都出来，摘要行不再重复命令', (tester) async {
      await tester.pumpWidget(group(expanded: true));
      await tester.pumpAndSettle();
      expect(find.text('第 0 步'), findsOneWidget);
      expect(find.text('第 2 步'), findsOneWidget);
      // 展开之后每一步各自都写着自己的命令。
      expect(find.text('tail -n 50 /var/log/nginx/error.log'), findsNothing);
    });

    testWidgets('点一下只报告，不自己改状态', (tester) async {
      // 自己改的话就有两份状态了：这一行记一份、聊天页记一份。
      // 上一版正是这么写的，而两份对不上的表现是"收不回去"。
      var taps = 0;
      await tester.pumpWidget(group(expanded: false, onToggle: () => taps++));
      await tester.tap(find.text('执行了 3 步'));
      await tester.pump();
      expect(taps, 1);
      // 状态没变，所以画面也没变。
      expect(find.text('第 0 步'), findsNothing);
    });

    testWidgets('收起来之后再重建，还是收着的', (tester) async {
      // 流式输出期间这一行每 33ms 就重建一次。任何"重建时顺便展开一下"
      // 的逻辑都会让用户永远收不回去。
      await tester.pumpWidget(group(expanded: true));
      await tester.pumpAndSettle();
      expect(find.text('第 0 步'), findsOneWidget);
      await tester.pumpWidget(group(expanded: false));
      await tester.pumpAndSettle();
      await tester.pumpWidget(group(expanded: false));
      await tester.pumpAndSettle();
      expect(find.text('第 0 步'), findsNothing);
    });

    testWidgets('展开是一段动画，不是一帧跳过去', (tester) async {
      await tester.pumpWidget(group(expanded: false));
      await tester.pumpWidget(group(expanded: true));
      await tester.pump(const Duration(milliseconds: 60));
      // 动画进行中：卡片已经在树上，但那一块还没长到最终高度。
      final mid = tester.getSize(find.byType(ToolCallGroup)).height;
      await tester.pumpAndSettle();
      final end = tester.getSize(find.byType(ToolCallGroup)).height;
      expect(mid, lessThan(end));
    });

    testWidgets('收起来的动画走完之后，那几张卡片才真的从树上摘掉', (tester) async {
      // 收拢过程中它们必须还在，否则内容会先消失、框再慢慢缩 ——
      // 那看起来像是东西丢了。但走完就得摘掉：藏着的卡片照样要布局、
      // 照样占着 State。
      await tester.pumpWidget(group(expanded: true));
      await tester.pumpAndSettle();
      await tester.pumpWidget(group(expanded: false));
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.text('第 0 步'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('第 0 步'), findsNothing);
    });

    testWidgets('滑回来时不重放动画 —— 一进来就是它该有的样子', (tester) async {
      // 行被回收之后重建，State 是新的。初值取当前值，所以不该看到
      // 一段"又展开一次"的动画。
      await tester.pumpWidget(group(expanded: true));
      await tester.pump();
      expect(find.text('第 0 步'), findsOneWidget);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('失败的步数写在标题里，不跟着藏起来', (tester) async {
      // 收起来的价值是省地方，不是把出错这件事一起藏掉。一个人翻回来看
      // 这一段，多半就是因为出了错。
      await tester.pumpWidget(group(count: 5, failed: 2, expanded: false));
      expect(find.text('5 步 · 2 步失败'), findsOneWidget);
    });

    testWidgets('一秒以内不报时长', (tester) async {
      await tester.pumpWidget(group(elapsedMs: 300, expanded: false));
      expect(find.textContaining('s'), findsNothing);
    });

    testWidgets('总时长按整组算', (tester) async {
      await tester.pumpWidget(group(elapsedMs: 4200, expanded: false));
      expect(find.text('4.2s'), findsOneWidget);
    });
  });
}
