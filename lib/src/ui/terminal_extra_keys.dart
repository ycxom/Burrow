/// 终端页缺硬件键盘才有的那些键——Tab、Esc、方向键、常用 Ctrl 组合。
///
/// 安卓软键盘上没有这些键，不是终端不支持，是**发不出去**。Termux 的做法
/// 是在软键盘上方常驻一条按键行（`ExtraKeysView`），点一下发一个字节。
/// 这里抄的是这个思路，不是抄它的粘滞 Ctrl 实现——那一份是在 Android 原生
/// KeyEvent 层拦截的（`TerminalExtraKeys.java` 把下一个物理按键打上
/// `META_CTRL_ON` 再转发），而软键盘打字走的是 IME 的 commitText，根本
/// 不产生 KeyEvent，这一层拦不到。改成一排最常用的组合键直接发，
/// 没有"点 Ctrl 再点任意键"那一步，但覆盖的是终端里最高频的那几个操作。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

/// 一条按键的定义：显示什么、按下去发生什么。
class _ExtraKey {
  const _ExtraKey(this.label, this.action);
  final String label;
  final void Function(Terminal terminal) action;
}

final _keys = <_ExtraKey>[
  _ExtraKey('Esc', (t) => t.keyInput(TerminalKey.escape)),
  _ExtraKey('Tab', (t) => t.keyInput(TerminalKey.tab)),
  _ExtraKey('^C', (t) => t.keyInput(TerminalKey.keyC, ctrl: true)),
  _ExtraKey('^D', (t) => t.keyInput(TerminalKey.keyD, ctrl: true)),
  _ExtraKey('^L', (t) => t.keyInput(TerminalKey.keyL, ctrl: true)),
  _ExtraKey('^R', (t) => t.keyInput(TerminalKey.keyR, ctrl: true)),
  _ExtraKey('^U', (t) => t.keyInput(TerminalKey.keyU, ctrl: true)),
  _ExtraKey('^W', (t) => t.keyInput(TerminalKey.keyW, ctrl: true)),
];

final _arrows = <_ExtraKey>[
  _ExtraKey('←', (t) => t.keyInput(TerminalKey.arrowLeft)),
  _ExtraKey('↓', (t) => t.keyInput(TerminalKey.arrowDown)),
  _ExtraKey('↑', (t) => t.keyInput(TerminalKey.arrowUp)),
  _ExtraKey('→', (t) => t.keyInput(TerminalKey.arrowRight)),
];

/// 常驻在终端上方的一条按键行。
///
/// **用 `terminal.keyInput()` 而不是手拼转义序列。** 方向键在应用光标模式
/// 下（`\x1bOA`）和普通模式下（`\x1b[A`）发的字节不一样，vim/less 这类程序
/// 会切换这个模式；`keyInput` 内部走的是和真实键盘敲击完全相同的那条路径
/// （`Terminal.inputHandler`），这个判断它已经做过一遍，不用在这里重猜。
class TerminalExtraKeysBar extends StatelessWidget {
  const TerminalExtraKeysBar({super.key, required this.terminal});

  /// 这条的高度。放它在外面是因为复制按钮要按它避让 —— 两处各写一个
  /// 数字的话，改高度时必然漏掉一处，表现是按钮压在按键上。
  static const double height = 40;

  final Terminal terminal;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        // 分隔线在上边：这条现在贴着底，线要划在它和终端正文之间。
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        children: <Widget>[
          for (final key in _keys)
            _KeyButton(key.label, () => key.action(terminal)),
          Container(
            width: 1,
            height: 20,
            margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
            color: scheme.outlineVariant,
          ),
          for (final key in _arrows)
            _KeyButton(key.label, () => key.action(terminal)),
        ],
      ),
    );
  }
}

class _KeyButton extends StatelessWidget {
  const _KeyButton(this.label, this.onTap);
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () {
        // 每一下都是在替代一个真实按键，要有和敲键盘一样的即时反馈——
        // 终端本身的回显有网络/进程调度延迟，不能靠它来确认"按到了"。
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 13,
            fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }
}
