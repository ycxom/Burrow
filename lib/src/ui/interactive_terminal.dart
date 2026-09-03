/// Touch-friendly terminal surface used by Burrow's manual shell.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import 'terminal_extra_keys.dart';

/// Keeps mobile-only terminal affordances next to the xterm view they control.
///
/// xterm's Flutter view can create a touch selection, but it intentionally does
/// not provide Android's contextual copy action. Termux supplies that action
/// from its native `ActionMode`; Burrow exposes the equivalent action here and
/// writes the exact selected buffer range to Flutter's clipboard.
class InteractiveTerminal extends StatelessWidget {
  const InteractiveTerminal({
    super.key,
    required this.terminal,
    required this.controller,
  });

  final Terminal terminal;
  final TerminalController controller;

  Future<void> _copySelection() async {
    final range = controller.selection;
    if (range == null) return;
    await Clipboard.setData(
      ClipboardData(text: terminal.buffer.getText(range)),
    );
    controller.clearSelection();
    await HapticFeedback.mediumImpact();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        Column(
          children: <Widget>[
            Expanded(
              child: TerminalView(
                terminal,
                controller: controller,
                backgroundOpacity: 0,
              ),
            ),
            // 按键行贴着底边：软键盘从下面弹上来，这一排就紧挨在它上方，
            // 拇指不用跨过大半个屏幕去够。放顶上时它离输入焦点最远，
            // 而这些键（Tab、方向键）恰恰是打字打到一半才要用的。
            TerminalExtraKeysBar(terminal: terminal),
          ],
        ),
        Positioned(
          right: 10,
          // 让开底部那条按键行，否则复制按钮会压在 Tab 上面。
          bottom: TerminalExtraKeysBar.height + 10,
          child: AnimatedBuilder(
            animation: controller,
            builder: (context, child) => controller.selection == null
                ? const SizedBox.shrink()
                : FloatingActionButton.small(
                    heroTag: null,
                    tooltip: '复制所选终端文本',
                    onPressed: _copySelection,
                    child: const Icon(Icons.copy_all_outlined),
                  ),
          ),
        ),
      ],
    );
  }
}
