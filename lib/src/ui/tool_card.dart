/// 工具调用在聊天流里的那一行。
///
/// ## 为什么它必须存在
///
/// 以前 `role == 'tool'` 的消息在界面上是被整个过滤掉的，于是同一个回合里
/// 「说一句 → 跑命令 → 再说一句」会显示成**两个紧挨着的助手气泡，中间什么
/// 都没有** —— 看起来像一条消息莫名其妙断成了两半。
///
/// 更糟的是跑命令那几十秒：气泡已经画完了，思考也收起来了，屏幕上一个像素
/// 都不动。用户能得到的唯一信息是输入框还灰着 —— 分不清"在跑命令"和"卡死了"。
/// 实测一条 ssh 命令跑 17 秒，那 17 秒里界面完全静止。
///
/// 这张卡片同时解决这两件事：它给中断的气泡一个**看得见的理由**，
/// 并且在命令跑着的时候是屏幕上唯一在动的东西。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'chat_theme.dart';

/// 一次工具调用的状态。
enum ToolCallState { running, ok, failed }

class ToolCallCard extends StatefulWidget {
  const ToolCallCard({
    super.key,
    required this.title,
    required this.state,
    this.output = '',
    this.startedAt,
    this.elapsedMs = 0,
  });

  /// 这一步做了什么。exec 就是命令行本身，其余是 `工具名 参数`。
  final String title;

  final ToolCallState state;

  /// 跑完之后的结果正文。空 = 还没跑完，或者这条老消息没存下来。
  final String output;

  /// 开跑的时刻。只在 [ToolCallState.running] 时用来走秒。
  final DateTime? startedAt;

  /// 跑完之后的定值，毫秒。
  final int elapsedMs;

  @override
  State<ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<ToolCallCard>
    with SingleTickerProviderStateMixin {
  bool _expanded = false;
  Timer? _ticker;

  /// 转圈。1.4 秒一圈 —— 再快就有"要出事了"的紧张感，
  /// 再慢就看不出它在动，而它存在的全部意义就是让人看出在动。
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(ToolCallCard old) {
    super.didUpdateWidget(old);
    _sync();
  }

  /// 秒表和转圈都只在跑的时候开。跑完还留着的话，每一条历史里的工具卡片
  /// 都会在后台按 60fps 重画自己 —— 一屏十几张就是十几个白烧的动画。
  void _sync() {
    final running = widget.state == ToolCallState.running;
    if (running) {
      if (!_spin.isAnimating) _spin.repeat();
      _ticker ??= Timer.periodic(
        const Duration(milliseconds: 100),
        (_) => setState(() {}),
      );
    } else {
      if (_spin.isAnimating) _spin.stop();
      _ticker?.cancel();
      _ticker = null;
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _spin.dispose();
    super.dispose();
  }

  int get _ms {
    if (widget.state == ToolCallState.running && widget.startedAt != null) {
      return DateTime.now().difference(widget.startedAt!).inMilliseconds;
    }
    return widget.elapsedMs;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.chat;
    final (Color accent, String label) = switch (widget.state) {
      ToolCallState.running => (t.brand, '执行中'),
      ToolCallState.ok => (t.tintSuccess, '执行成功'),
      ToolCallState.failed => (t.tintError, '执行失败'),
    };
    final ms = _ms;
    final canExpand = widget.output.trim().isNotEmpty;

    // 一行。这里刻意压得很扁：它是**进度条**，不是消息 ——
    // 做成两行的卡片之后，一段跑了五六条命令的对话会被这些卡片占掉半屏，
    // 而真正要读的助手正文被挤到看不见。
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 2, 44, 2),
        decoration: BoxDecoration(
          color: t.bgSecondary,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: accent.withValues(alpha: 0.25)),
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap:
                canExpand ? () => setState(() => _expanded = !_expanded) : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      _StateIcon(
                          state: widget.state, color: accent, spin: _spin),
                      const SizedBox(width: 5),
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: 11,
                          height: 1.2,
                          fontWeight: FontWeight.w600,
                          color: accent,
                        ),
                      ),
                      // 一秒以内不报时长：那种长度的命令报出来只是噪音，
                      // 而且数字会在出现的同一帧消失，像是闪了一下。
                      if (ms >= 1000) ...<Widget>[
                        const SizedBox(width: 5),
                        Text(
                          _formatElapsed(ms),
                          style: TextStyle(
                            fontSize: 10.5,
                            height: 1.2,
                            color: t.tintTertiary,
                            // 等宽数字。不然秒表每跳一下整行都在左右抖。
                            fontFeatures: const <FontFeature>[
                              FontFeature.tabularFigures(),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(width: 8),
                      // 命令跟在同一行里。Flexible 而不是 Expanded：
                      // 短命令就该让卡片跟着变窄，撑满一整行的空壳比什么都不画更吵。
                      Flexible(
                        child: Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11,
                            height: 1.2,
                            color: t.tintSecondary,
                          ),
                        ),
                      ),
                      if (canExpand)
                        Padding(
                          padding: const EdgeInsets.only(left: 2),
                          child: AnimatedRotation(
                            turns: _expanded ? 0.5 : 0,
                            duration: const Duration(milliseconds: 160),
                            child: Icon(
                              Icons.expand_more,
                              size: 14,
                              color: t.tintTertiary,
                            ),
                          ),
                        ),
                    ],
                  ),
                  AnimatedCrossFade(
                    firstChild:
                        const SizedBox(width: double.infinity, height: 0),
                    secondChild: Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(top: 6),
                      padding: const EdgeInsets.only(left: 7),
                      constraints: const BoxConstraints(maxHeight: 240),
                      decoration: BoxDecoration(
                        border: Border(
                          left: BorderSide(color: t.borderPrimary, width: 2),
                        ),
                      ),
                      child: SingleChildScrollView(
                        child: Text(
                          // 展开时把命令原样再给一遍：上面那行被省略号截过，
                          // 而"到底跑的是哪条命令"正是点开要看的东西之一。
                          '${widget.title}\n\n${widget.output.trim()}',
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11,
                            height: 1.45,
                            color: t.tintTertiary,
                          ),
                        ),
                      ),
                    ),
                    crossFadeState: _expanded && canExpand
                        ? CrossFadeState.showSecond
                        : CrossFadeState.showFirst,
                    duration: const Duration(milliseconds: 180),
                    sizeCurve: Curves.easeOutCubic,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 左边那个图标。跑着的时候转，跑完了定住。
class _StateIcon extends StatelessWidget {
  const _StateIcon({
    required this.state,
    required this.color,
    required this.spin,
  });

  final ToolCallState state;
  final Color color;
  final AnimationController spin;

  @override
  Widget build(BuildContext context) {
    if (state != ToolCallState.running) {
      return Icon(
        state == ToolCallState.ok
            ? Icons.check_circle_outline
            : Icons.error_outline,
        size: 13,
        color: color,
      );
    }
    return RotationTransition(
      // 展开箭头那个 AnimatedRotation 内部也是一个 RotationTransition，
      // 测试里光按类型找会同时捞到两个。给这个转圈一个名字。
      key: const ValueKey('tool-spin'),
      turns: spin,
      child: Icon(Icons.autorenew, size: 13, color: color),
    );
  }
}

/// `4.2s` / `1m 5s`。和思考区那个是同一套读法，故意保持一致 ——
/// 同一个屏幕上两种时长写法会让人以为它们量的是不同的东西。
String _formatElapsed(int ms) {
  final seconds = ms / 1000;
  if (seconds < 60) return '${seconds.toStringAsFixed(1)}s';
  final minutes = seconds ~/ 60;
  final rest = (seconds % 60).floor();
  return rest == 0 ? '${minutes}m' : '${minutes}m ${rest}s';
}
