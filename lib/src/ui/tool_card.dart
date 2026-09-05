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

/// 连着好几步命令时，把它们收成一行。
///
/// ## 为什么要收
///
/// 单张卡片已经压得很扁了（见上面那段注释），但一个回合跑七八条命令时，
/// 七八行加起来照样占掉大半屏 —— 而用户真正要读的是那几行命令**之后**
/// 模型说了什么。翻过去要滑好几下，而中间那些行绝大多数时候不需要看。
///
/// 收起来之后默认只剩一行「执行了 7 步」，展开才是原来那几张卡片，
/// 每张仍然能各自再展开看输出。
///
/// ## 失败的那几步不藏
///
/// 标题里带上「2 步失败」并且用错误色 —— 收起来的价值是省地方，
/// 不是把出错这件事一起藏掉。一个人翻回来看这一段，多半就是因为出了错。
class ToolCallGroup extends StatefulWidget {
  const ToolCallGroup({
    super.key,
    required this.count,
    required this.failed,
    required this.elapsedMs,
    required this.lastTitle,
    required this.cards,
    required this.expanded,
    required this.onToggle,
  });

  final int count;
  final int failed;

  /// 这一组总共跑了多久。
  final int elapsedMs;

  /// 最后一步的命令行。收起来时它是唯一的线索。
  final String lastTitle;

  /// 展开之后的那几张卡片，顺序和跑的顺序一致。
  final List<Widget> cards;

  /// 展开着没有。
  ///
  /// **状态不放在这个 widget 里。** `ListView.builder` 会把滚出缓存范围的
  /// 行整个丢掉，State 跟着没 —— 用户展开过的一组，滑远一点再滑回来就
  /// 自己收上了。而且这一行会因为别的原因（流式输出、忙碌状态）反复重建，
  /// 内部状态和外部意图两份东西迟早对不上。所以由聊天页统一记着
  /// （`_HomeShellState._expandedToolGroups`），这里只负责画和报告点击。
  final bool expanded;

  final VoidCallback onToggle;

  @override
  State<ToolCallGroup> createState() => _ToolCallGroupState();
}

class _ToolCallGroupState extends State<ToolCallGroup>
    with SingleTickerProviderStateMixin {
  /// 展开/收起那一下。
  ///
  /// **它不是状态，是动画进度。** 真正的"展开着没有"仍然只有
  /// [ToolCallGroup.expanded] 一份，在聊天页那边（见它的注释）。这里只是
  /// 把那个布尔的变化画成一段过程 —— 初值直接取当前值，所以被回收之后
  /// 滑回来不会重放一遍动画。
  late final AnimationController _anim = AnimationController(
    vsync: this,
    // 190ms：比展开箭头那种小动画长一点（内容多得多），
    // 又短到不会让人等。
    duration: const Duration(milliseconds: 190),
    value: widget.expanded ? 1 : 0,
  );

  late final Animation<double> _curve = CurvedAnimation(
    parent: _anim,
    curve: Curves.easeOutCubic,
    // 收起来用另一条曲线：展开要"甩出来"，收起要"抽回去"，
    // 两头用同一条的话收起会在最后拖一下，像是卡了。
    reverseCurve: Curves.easeInCubic,
  );

  @override
  void initState() {
    super.initState();
    // 彻底收拢的那一刻要重建一次，把那几张卡片从树上摘掉（见 build）。
    _anim.addStatusListener((status) {
      if (status == AnimationStatus.dismissed && mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(ToolCallGroup old) {
    super.didUpdateWidget(old);
    if (widget.expanded == old.expanded) return;
    if (widget.expanded) {
      _anim.forward();
    } else {
      _anim.reverse();
    }
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.chat;
    final count = widget.count;
    final failed = widget.failed;
    final elapsedMs = widget.elapsedMs;
    final lastTitle = widget.lastTitle;
    final expanded = widget.expanded;
    final anyFailed = failed > 0;
    final accent = anyFailed ? t.tintError : t.tintSuccess;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Align(
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
                onTap: widget.onToggle,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(
                        anyFailed ? Icons.error_outline : Icons.done_all,
                        size: 13,
                        color: accent,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        anyFailed ? '$count 步 · $failed 步失败' : '执行了 $count 步',
                        style: TextStyle(
                          fontSize: 11,
                          height: 1.2,
                          fontWeight: FontWeight.w600,
                          color: accent,
                        ),
                      ),
                      if (elapsedMs >= 1000) ...<Widget>[
                        const SizedBox(width: 5),
                        Text(
                          _formatElapsed(elapsedMs),
                          style: TextStyle(
                            fontSize: 10.5,
                            height: 1.2,
                            color: t.tintTertiary,
                            fontFeatures: const <FontFeature>[
                              FontFeature.tabularFigures(),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(width: 8),
                      // 收起来时给最后一步的命令行当线索。展开之后就没必要了
                      // —— 那时候每一步各自都写着自己的命令。
                      if (!expanded)
                        Flexible(
                          child: Text(
                            lastTitle,
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
                      Padding(
                        padding: const EdgeInsets.only(left: 2),
                        // 箭头跟着同一条动画转，不另开一个 AnimatedRotation
                        // —— 两个时长稍有出入的动画并排跑，会让人觉得
                        // 哪里不对但说不出是哪里。
                        child: RotationTransition(
                          turns:
                              Tween<double>(begin: 0, end: 0.5).animate(_curve),
                          child: Icon(
                            Icons.expand_more,
                            size: 14,
                            color: t.tintTertiary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        // 收拢**之后**才真的不建那几张卡片。
        //
        // 藏起来的卡片照样要布局、照样占着 State：一段跑了几十条命令的
        // 历史，光是那些看不见的输出就够拖慢滑动了 —— 而这一组存在的理由
        // 就是它们太多。所以不用 AnimatedCrossFade（它两边都建），
        // 而是自己盯着动画：收拢的那一刻把它们从树上摘掉。
        if (expanded || _anim.value > 0)
          SizeTransition(
            sizeFactor: _curve,
            // 从上边缘长出来。倒序列表里这一行本来就是"下边钉住、向上长"，
            // 内部再从上边展开，看起来才是同一个动作。
            alignment: Alignment.topLeft,
            child: FadeTransition(
              // 淡入比长开慢半拍：先有地方，再有东西 ——
              // 同时来的话文字会在挤压中抖。
              opacity: CurvedAnimation(
                parent: _anim,
                curve: const Interval(0.35, 1),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: widget.cards,
              ),
            ),
          ),
      ],
    );
  }
}
