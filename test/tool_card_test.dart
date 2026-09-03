/// 工具卡片：跑命令那段时间里屏幕上唯一在动的东西。
///
/// 起因是一条 ssh 命令跑了 17 秒，那 17 秒里界面完全静止 —— 助手气泡已经
/// 画完、思考已经收起，用户能得到的唯一信息是输入框还灰着。分不清"在跑"
/// 和"卡死"。这些用例盯的就是那三件事：**说了在跑没有、说了成没成、
/// 那个动画是不是真的在动**。
library;

import 'package:burrow/src/ui/chat_theme.dart';
import 'package:burrow/src/ui/tool_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget host(Widget child) => MaterialApp(
      theme: ThemeData(extensions: const <ThemeExtension<dynamic>>[
        ChatTokens.dark,
      ]),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  testWidgets('跑着的时候说"执行中"，并且图标真的在转', (tester) async {
    await tester.pumpWidget(host(ToolCallCard(
      title: 'ssh hello@192.168.36.248',
      state: ToolCallState.running,
      startedAt: DateTime.now(),
    )));

    expect(find.text('执行中'), findsOneWidget);
    expect(find.text('ssh hello@192.168.36.248'), findsOneWidget);

    // 转圈是靠 RotationTransition 的 turns 走的。两帧之间的值必须不同 ——
    // 相等就说明控制器没跑起来，卡片会静静地待着，那和没加是一回事。
    //
    // 按 key 找而不是按类型：展开箭头那个 AnimatedRotation 内部也是一个
    // RotationTransition，按类型会一次捞到两个然后炸在"多个候选"上。
    const spin = ValueKey<String>('tool-spin');
    double turns() =>
        tester.widget<RotationTransition>(find.byKey(spin)).turns.value;

    final first = turns();
    await tester.pump(const Duration(milliseconds: 350));
    expect(turns(), isNot(first), reason: '图标不动的话，用户还是会以为它卡死了');

    // 别让计时器漏到用例外面。
    await tester.pumpWidget(host(const SizedBox()));
  });

  testWidgets('跑完了给结论，而不是继续转', (tester) async {
    await tester.pumpWidget(host(const ToolCallCard(
      title: 'apt install -y sshpass',
      state: ToolCallState.ok,
      output: 'Setting up sshpass ...',
      elapsedMs: 42000,
    )));

    expect(find.text('执行成功'), findsOneWidget);
    expect(find.text('42.0s'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('tool-spin')), findsNothing,
        reason: '跑完还在转的话，一屏历史就是一屏白烧的动画');
  });

  testWidgets('失败要看得出来，不能和成功长一样', (tester) async {
    await tester.pumpWidget(host(const ToolCallCard(
      title: 'rm /nope',
      state: ToolCallState.failed,
      output: 'No such file',
    )));

    expect(find.text('执行失败'), findsOneWidget);
    expect(find.text('执行成功'), findsNothing);
  });

  testWidgets('一秒以内不报时长', (tester) async {
    await tester.pumpWidget(host(const ToolCallCard(
      title: 'ls',
      state: ToolCallState.ok,
      output: 'a.txt',
      elapsedMs: 300,
    )));

    // 0.3s 这种数字报出来只是噪音，而且会在出现的同一帧消失。
    expect(find.text('0.3s'), findsNothing);
    expect(find.text('执行成功'), findsOneWidget, reason: '结论照常要有');
  });

  testWidgets('点一下能看到输出，默认是折叠的', (tester) async {
    await tester.pumpWidget(host(const ToolCallCard(
      title: 'uname -a',
      state: ToolCallState.ok,
      output: 'Linux localhost 6.1.0',
    )));

    // AnimatedCrossFade 两个孩子一直都挂在树上（收起来的那个高度是 0），
    // 所以"看不看得见"要问 crossFadeState，不能问文字在不在。
    CrossFadeState fade() => tester
        .widget<AnimatedCrossFade>(find.byType(AnimatedCrossFade))
        .crossFadeState;

    expect(fade(), CrossFadeState.showFirst, reason: '默认折叠');
    await tester.tap(find.text('uname -a'));
    await tester.pumpAndSettle();
    expect(fade(), CrossFadeState.showSecond);
  });

  testWidgets('没有输出的卡片不给展开箭头', (tester) async {
    await tester.pumpWidget(host(const ToolCallCard(
      title: 'checkpoint 存个档',
      state: ToolCallState.ok,
    )));

    expect(find.byIcon(Icons.expand_more), findsNothing,
        reason: '点了没反应的箭头比没有箭头更糟');
  });
}
