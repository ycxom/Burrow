/// 思考过程的展示，以及"正在生成"的那点动静。
///
/// 这里的东西都很小，但它们解决的是同一个问题：**发出消息之后到第一个字
/// 出现之前，界面上什么都没有。** 那段空白可能长达十几秒（推理模型尤其），
/// 而用户能得到的唯一反馈是输入框变灰了 —— 分不清"在想"和"卡死了"。
library;

import 'dart:async';

import 'package:flutter/material.dart';

/// 三个轮流亮起来的点。
///
/// 用透明度而不是位移：气泡在跟着流式文本一起长高，再让点上下跳，
/// 两种运动叠在一起会显得很躁。
class TypingDots extends StatefulWidget {
  const TypingDots({super.key, required this.color, this.size = 5});

  final Color color;
  final double size;

  @override
  State<TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (_, __) => Row(
        mainAxisSize: MainAxisSize.min,
        children: List<Widget>.generate(3, (i) {
          // 三个点各自错开三分之一个周期，看起来像一道波扫过去。
          final phase = (_controller.value - i * 0.18) % 1.0;
          // 前半程亮起、后半程暗下去，中间停一会儿 —— 一直在动的话
          // 余光里会一直被它勾着。
          final wave = phase < 0.5 ? phase * 2 : (1 - phase) * 2;
          return Padding(
            padding: EdgeInsets.only(right: i == 2 ? 0 : widget.size * 0.6),
            child: Container(
              width: widget.size,
              height: widget.size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.color
                    .withValues(alpha: 0.3 + 0.7 * wave.clamp(0.0, 1.0)),
              ),
            ),
          );
        }),
      ),
    );
  }
}

/// 一条助手消息的思考过程：折叠的一行，点开是全文。
///
/// **默认折叠。** 思考往往比答案还长，展开着的话答案会被推到屏幕外 ——
/// 而用户要的是答案，思考是"想看时才看"的东西。
class ThinkingBlock extends StatefulWidget {
  const ThinkingBlock({
    super.key,
    required this.text,
    required this.active,
    required this.foreground,
    this.startedAt,
    this.elapsedMs = 0,
  });

  final String text;

  /// 还在想。决定标题、动画和摘要取哪一行。
  final bool active;

  /// 所在气泡的正文色。这一块的颜色都从它推，而不是取主题色 ——
  /// 皮肤可以把气泡改成任意底色，主题色在深色底上会看不见。
  final Color foreground;

  /// 开始思考的时刻。只在 [active] 时用来走秒。
  final DateTime? startedAt;

  /// 想完之后的定值，毫秒。
  final int elapsedMs;

  @override
  State<ThinkingBlock> createState() => _ThinkingBlockState();
}

class _ThinkingBlockState extends State<ThinkingBlock> {
  bool _expanded = false;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(ThinkingBlock old) {
    super.didUpdateWidget(old);
    _syncTicker();
  }

  /// 秒数只在思考中走。想完了还留着定时器，等于让每一条历史消息
  /// 都在后台每 200ms 唤醒一次界面。
  void _syncTicker() {
    if (widget.active && widget.startedAt != null) {
      _ticker ??= Timer.periodic(
        const Duration(milliseconds: 200),
        (_) => setState(() {}),
      );
    } else {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  int get _ms {
    if (widget.active && widget.startedAt != null) {
      return DateTime.now().difference(widget.startedAt!).inMilliseconds;
    }
    return widget.elapsedMs;
  }

  @override
  Widget build(BuildContext context) {
    final fg = widget.foreground;
    final dim = fg.withValues(alpha: 0.55);
    final label = widget.active ? '思考中' : '已深度思考';
    final ms = _ms;
    final preview = thinkingPreview(widget.text, widget.active);
    final hasDetail = widget.text.trim().isNotEmpty;

    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          InkWell(
            onTap:
                hasDetail ? () => setState(() => _expanded = !_expanded) : null,
            borderRadius: BorderRadius.circular(6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(Icons.lightbulb_outline, size: 14, color: dim),
                const SizedBox(width: 5),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.2,
                    fontWeight: FontWeight.w500,
                    color: dim,
                  ),
                ),
                if (widget.active) ...<Widget>[
                  const SizedBox(width: 6),
                  TypingDots(color: fg.withValues(alpha: 0.7), size: 4),
                ],
                // 一秒以内不显示 —— 那种长度的"思考"报出来只是噪音。
                if (ms >= 1000) ...<Widget>[
                  const SizedBox(width: 6),
                  Text(
                    formatThinkDuration(ms),
                    style: TextStyle(
                      fontSize: 11.5,
                      height: 1.2,
                      color: fg.withValues(alpha: 0.4),
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  ),
                ],
                if (!_expanded && preview.isNotEmpty)
                  Flexible(
                    child: Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: _PreviewLine(
                        text: preview,
                        // 想的时候看最新一行的**结尾**（新字从右边冒出来），
                        // 想完了看第一行的**开头**（那句话通常是它的结论）。
                        tail: widget.active,
                        color: fg.withValues(alpha: 0.35),
                      ),
                    ),
                  ),
                if (hasDetail)
                  Padding(
                    padding: const EdgeInsets.only(left: 2),
                    child: AnimatedRotation(
                      turns: _expanded ? 0.5 : 0,
                      duration: const Duration(milliseconds: 160),
                      child: Icon(Icons.expand_more, size: 15, color: dim),
                    ),
                  ),
              ],
            ),
          ),
          AnimatedCrossFade(
            firstChild: const SizedBox(width: double.infinity, height: 0),
            secondChild: Container(
              width: double.infinity,
              margin: const EdgeInsets.only(top: 6),
              padding: const EdgeInsets.only(left: 9),
              constraints: const BoxConstraints(maxHeight: 320),
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(color: fg.withValues(alpha: 0.22), width: 2),
                ),
              ),
              child: SingleChildScrollView(
                child: Text(
                  widget.text.trim(),
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.45,
                    color: fg.withValues(alpha: 0.62),
                  ),
                ),
              ),
            ),
            crossFadeState: _expanded && hasDetail
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 180),
            sizeCurve: Curves.easeOutCubic,
          ),
        ],
      ),
    );
  }
}

/// 折叠状态下那一行摘要。
///
/// 思考中取**最后一行**：那是它此刻在想的东西，跟着一起动才有"在推进"的感觉。
/// 想完取**第一行**：一个固定不动的开头，比停在某句半截话上更像一个标题。
String thinkingPreview(String text, bool active) {
  final trimmed = text.trimRight();
  if (trimmed.isEmpty) return '';
  if (active) {
    final cut = trimmed.lastIndexOf('\n');
    return cut < 0 ? trimmed : trimmed.substring(cut + 1);
  }
  final cut = trimmed.indexOf('\n');
  return (cut < 0 ? trimmed : trimmed.substring(0, cut)).trim();
}

/// `3.2s` / `1m 5s`。
String formatThinkDuration(int ms) {
  if (ms < 1000) return '0.0s';
  final seconds = ms / 1000;
  if (seconds < 60) return '${seconds.toStringAsFixed(1)}s';
  final minutes = seconds ~/ 60;
  final rest = (seconds % 60).floor();
  return rest == 0 ? '${minutes}m' : '${minutes}m ${rest}s';
}

/// 一行不换行的摘要。[tail] 为真时贴着右边显示结尾。
class _PreviewLine extends StatelessWidget {
  const _PreviewLine({
    required this.text,
    required this.tail,
    required this.color,
  });

  final String text;
  final bool tail;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(fontSize: 11.5, height: 1.2, color: color);
    if (!tail) {
      return Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
    }
    // `reverse` 让视口停在内容末尾 —— 于是新写出来的字总在右边可见，
    // 而不需要每来一个字就自己算一次滚动距离。
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      reverse: true,
      physics: const NeverScrollableScrollPhysics(),
      child: Text(text, maxLines: 1, softWrap: false, style: style),
    );
  }
}
