import 'package:burrow/src/ui/interactive_terminal.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> platformCalls;

  setUp(() {
    platformCalls = <MethodCall>[];
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      platformCalls.add(call);
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('Android touch selection copies the selected terminal buffer',
      (tester) async {
    // 必须在测试体**结束前**还原，不能靠 addTearDown：框架的
    // debugAssertAllFoundationVarsUnset 检查跑在 tearDown 之前，
    // 留到 tearDown 还原会被判成"测试改了全局调试变量"而报错。
    debugDefaultTargetPlatformOverride = TargetPlatform.android;

    final terminal = Terminal(maxLines: 100);
    final controller = TerminalController();
    addTearDown(controller.dispose);
    terminal.write('COPYME');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 360,
            height: 240,
            child: InteractiveTerminal(
              terminal: terminal,
              controller: controller,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final terminalRect = tester.getRect(find.byType(TerminalView));
    await tester.longPressAt(terminalRect.topLeft + const Offset(28, 10));
    await tester.pump();

    final selection = controller.selection;
    expect(selection, isNotNull, reason: '长按应先生成真实终端选区');
    expect(terminal.buffer.getText(selection!), 'COPYME');

    final copyButton = find.byTooltip('复制所选终端文本');
    expect(copyButton, findsOneWidget,
        reason: 'Termux uses Android ActionMode; Burrow needs an equivalent '
            'touch copy action around its Flutter xterm view');

    await tester.tap(copyButton);
    await tester.pump();

    final clipboardCalls = platformCalls
        .where((call) => call.method == 'Clipboard.setData')
        .toList();
    expect(clipboardCalls, hasLength(1));
    expect(
      (clipboardCalls.single.arguments as Map<Object?, Object?>)['text'],
      'COPYME',
    );
    expect(controller.selection, isNull,
        reason: 'successful copy should leave the terminal ready for input');

    debugDefaultTargetPlatformOverride = null;
  });
}
