/// 摘要分隔线：把「模型只通过摘要知道这一段」画在它真正发生的位置上。
///
/// 在它之前滚动摘要是完全看不见的 —— 模型收到的上下文里少了一大截原文、
/// 多了一段摘要，而界面上一切照旧。于是「它怎么忘了我十分钟前说的话」
/// 在界面上找不到任何线索。
library;

import 'package:burrow/src/ui/chat_theme.dart';
import 'package:burrow/src/ui/chat_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget host(Widget child) => MaterialApp(
      theme: ThemeData(extensions: const <ThemeExtension<dynamic>>[
        ChatTokens.dark,
      ]),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  testWidgets('默认收起，只说有多少条被压掉了', (tester) async {
    await tester.pumpWidget(host(const SummaryDivider(
      covered: 12,
      summary: '用户在装 torch，装到一半发现 pip 源不通。',
    )));

    expect(find.text('以上 12 条已压缩成摘要'), findsOneWidget);
    // 绝大多数时候用户只需要知道「这里有一道线」。摘要原文动辄几百字，
    // 默认摊开会把一屏占满，用户滚半天找不到自己那句话。
    expect(find.textContaining('pip 源不通'), findsNothing);
  });

  testWidgets('点一下摊开摘要原文', (tester) async {
    await tester.pumpWidget(host(const SummaryDivider(
      covered: 12,
      summary: '用户在装 torch，装到一半发现 pip 源不通。',
    )));

    await tester.tap(find.text('以上 12 条已压缩成摘要'));
    await tester.pumpAndSettle();

    // 「模型现在到底记得什么」的准确答案，比任何解释都直接。
    expect(find.textContaining('pip 源不通'), findsOneWidget);
    // 不说这一句的话，看到"已压缩"三个字的第一反应是"我的记录被删了"。
    expect(find.textContaining('原文都还在'), findsOneWidget);
  });

  testWidgets('再点一下收回去', (tester) async {
    await tester.pumpWidget(host(const SummaryDivider(
      covered: 3,
      summary: '之前聊过的东西',
    )));

    await tester.tap(find.text('以上 3 条已压缩成摘要'));
    await tester.pumpAndSettle();
    expect(find.textContaining('之前聊过的东西'), findsOneWidget);

    await tester.tap(find.text('以上 3 条已压缩成摘要'));
    await tester.pumpAndSettle();
    expect(find.textContaining('之前聊过的东西'), findsNothing);
  });
}
