/// 聊天页的视觉层，Telegram 风格。
///
/// 几个换成"看起来差不多"的做法就会变味的细节：
///
///   - **气泡有尾巴，而且只有一组消息的最后一条才有。** 连续几条同一方的
///     消息是一个"组"，中间那些是无尾的圆角块、间距收到 2px。这是 Telegram
///     最认得出来的节奏，每条都加尾巴会变成一串独立的对话框。
///   - **时间戳在气泡里面，压在右下角，正文绕着它排。** 做法见
///     [_InlineTimeText]：在文本流末尾塞一个和时间戳等宽的透明占位，
///     再把真的时间戳绝对定位到右下。这样短消息的时间跟在同一行，
///     长消息才换行 —— 和 Telegram 一样。
///   - **收发两侧的时间戳颜色不同**（发出去偏绿、收到偏灰）。它压在气泡上，
///     对比度必须很低，用同一个灰在浅绿气泡上会脏。
///   - **消息操作走长按菜单**，气泡上不挂任何按钮。Telegram 的气泡是干净的，
///     挂一排图标就不是这个界面了。代价是「回到这里」不再一眼可见 ——
///     这是这次换皮肤真正丢掉的东西。
///   - **聊天区有壁纸**。气泡浮在渐变上，顶栏和输入区是实心的。
///     少了这一层就变成"卡片列表"，不是聊天。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import 'chat_theme.dart';

// ---------------------------------------------------------------------------
// 壁纸
// ---------------------------------------------------------------------------

/// 聊天区的壁纸。消息列表铺在它上面。
class ChatWallpaper extends StatelessWidget {
  final Widget child;
  const ChatWallpaper({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final t = context.chat;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [t.wallpaperTop, t.wallpaperBottom],
        ),
      ),
      child: child,
    );
  }
}

// ---------------------------------------------------------------------------
// 气泡形状
// ---------------------------------------------------------------------------

/// 带尾巴的气泡。
///
/// 尾巴画在 rect **内部**：内容区在带尾一侧让出 [ChatShape.tailWidth]，
/// 尾巴从那个底角长出去填满。画到 rect 外面的话，Material 的墨水效果和
/// 裁剪都会按 rect 走，尾巴会被切掉。
///
/// 只写了「发出方（尾巴在右下）」一套路径，收到方沿垂直中线镜像 ——
/// 两套分别手写迟早会不对称，而不对称在两条挨着的消息上一眼就看得出来。
class BubbleShape extends ShapeBorder {
  /// 尾巴在右下（发出方）还是左下（收到方）。
  final bool outgoing;

  /// 画不画尾巴。一组消息里只有最后一条画。
  final bool tail;

  const BubbleShape({required this.outgoing, required this.tail});

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.zero;

  @override
  ShapeBorder scale(double t) => this;

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      getOuterPath(rect, textDirection: textDirection);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    var path = _outgoingPath(rect);
    if (!outgoing) {
      final m = Matrix4.identity()
        ..translateByDouble(rect.center.dx, 0, 0, 1)
        ..scaleByDouble(-1, 1, 1, 1)
        ..translateByDouble(-rect.center.dx, 0, 0, 1);
      path = path.transform(m.storage);
    }
    return path;
  }

  Path _outgoingPath(Rect rect) {
    const r = ChatShape.bubbleRadius;
    const tw = ChatShape.tailWidth;
    const corner = ChatShape.bubbleTailCorner;

    // 气泡本体。带尾巴时右边留出尾巴的宽度。
    final body = Rect.fromLTRB(
      rect.left,
      rect.top,
      tail ? rect.right - tw : rect.right,
      rect.bottom,
    );

    final p = Path()..moveTo(body.left + r, body.top);
    p.lineTo(body.right - r, body.top);
    p.arcToPoint(Offset(body.right, body.top + r),
        radius: const Radius.circular(r));

    if (tail) {
      p.lineTo(body.right, body.bottom - corner);
      // 向外拐出一个小钩子，钩到 rect 的右边缘。
      p.cubicTo(
        body.right,
        body.bottom - 1,
        body.right + tw * 0.5,
        body.bottom,
        rect.right,
        body.bottom,
      );
      // 再从钩尖收回气泡底边。收回的落点比钩子根部靠左，
      // 钩子才是"翘"的而不是一个直角三角。
      p.cubicTo(
        body.right + tw * 0.2,
        body.bottom - 1.5,
        body.right - 1,
        body.bottom - 5,
        body.right - 9,
        body.bottom,
      );
    } else {
      p.lineTo(body.right, body.bottom - r);
      p.arcToPoint(Offset(body.right - r, body.bottom),
          radius: const Radius.circular(r));
    }

    p.lineTo(body.left + r, body.bottom);
    p.arcToPoint(Offset(body.left, body.bottom - r),
        radius: const Radius.circular(r));
    p.lineTo(body.left, body.top + r);
    p.arcToPoint(Offset(body.left + r, body.top),
        radius: const Radius.circular(r));
    return p..close();
  }

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {}

  @override
  bool operator ==(Object other) =>
      other is BubbleShape && other.outgoing == outgoing && other.tail == tail;

  @override
  int get hashCode => Object.hash(outgoing, tail);
}

// ---------------------------------------------------------------------------
// 头像
// ---------------------------------------------------------------------------

/// 32px 圆形头像。只有收到的消息带 —— 自己发的不需要头像提醒是谁说的。
class ChatAvatar extends StatelessWidget {
  final String role;
  const ChatAvatar({super.key, required this.role});

  static const double size = 32;

  @override
  Widget build(BuildContext context) {
    final t = context.chat;
    final (IconData icon, Color bg) = switch (role) {
      'assistant' => (Icons.smart_toy_outlined, t.brand),
      'tool' => (Icons.terminal, t.tintSecondary),
      _ => (Icons.info_outline, t.tintTertiary),
    };
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
      child: Icon(icon, size: 18, color: Colors.white),
    );
  }
}

// ---------------------------------------------------------------------------
// 居中胶囊：日期分隔 + 系统提示
// ---------------------------------------------------------------------------

/// 压在壁纸上的居中胶囊。日期分隔和系统提示都用它。
///
/// Telegram 把这类"不是谁说的话"的内容都做成这个样子，和左右两侧的气泡
/// 明确区分开 —— 系统提示长得像助手说的话，用户会以为模型在自言自语。
class ServicePill extends StatelessWidget {
  final String text;

  /// 报错。用红字，但仍然是胶囊 —— 它不是对话内容。
  final bool isError;

  const ServicePill({super.key, required this.text, this.isError = false});

  @override
  Widget build(BuildContext context) {
    final t = context.chat;
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 32),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: isError ? t.bgErrorSecondary : t.servicePill,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 12,
            height: 1.4,
            fontWeight: FontWeight.w500,
            color: isError ? t.tintError : t.tintOnService,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 气泡
// ---------------------------------------------------------------------------

/// 一条消息。
class ChatBubble extends StatelessWidget {
  final String role;
  final String text;

  /// 气泡右下角的时间。null 则不显示（流式输出中）。
  final DateTime? time;

  /// 时间前面的一小段附加信息，目前是模型名。
  final String? meta;

  /// 这条是报错。
  final bool isError;

  /// 正在流式输出。此时不显示时间，也不响应长按 ——
  /// 半截内容上的"复制"和"重新生成"都没有意义。
  final bool generating;

  /// 这条是一组连续消息里的最后一条：画尾巴、显示头像。
  final bool lastInGroup;

  final VoidCallback? onRetry;
  final VoidCallback? onEdit;
  final VoidCallback? onRewind;
  final VoidCallback? onDelete;

  const ChatBubble({
    super.key,
    required this.role,
    required this.text,
    this.time,
    this.meta,
    this.isError = false,
    this.generating = false,
    this.lastInGroup = true,
    this.onRetry,
    this.onEdit,
    this.onRewind,
    this.onDelete,
  });

  bool get _outgoing => role == 'user';

  @override
  Widget build(BuildContext context) {
    final t = context.chat;
    final bg = isError
        ? t.bgErrorSecondary
        : _outgoing
            ? t.bubbleOut
            : t.bubbleIn;
    final fg = isError
        ? t.tintPrimary
        : _outgoing
            ? t.tintOnOut
            : t.tintOnIn;
    final timeColor = _outgoing ? t.timeOut : t.timeIn;

    final maxWidth = MediaQuery.of(context).size.width * 0.8;

    final footer = time == null
        ? null
        : _BubbleFooter(
            meta: meta,
            time: time!,
            color: timeColor,
          );

    final bubble = Container(
      constraints: BoxConstraints(maxWidth: maxWidth),
      decoration: ShapeDecoration(
        color: bg,
        shape: BubbleShape(outgoing: _outgoing, tail: lastInGroup),
        shadows: const [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 1,
            offset: Offset(0, 1),
          ),
        ],
      ),
      padding: EdgeInsets.fromLTRB(
        // 带尾巴那侧要多让出尾巴的宽度，否则正文会压到钩子上。
        _outgoing || !lastInGroup ? 11 : 11 + ChatShape.tailWidth,
        6,
        _outgoing && lastInGroup ? 11 + ChatShape.tailWidth : 11,
        6,
      ),
      child: _buildBody(context, fg, footer),
    );

    return Padding(
      // 组内 2px、组间 8px。这个节奏是 Telegram 最直观的部分。
      padding: EdgeInsets.only(
        left: 8,
        right: 8,
        top: 1,
        bottom: lastInGroup ? 7 : 1,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisAlignment:
            _outgoing ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: <Widget>[
          if (!_outgoing) ...<Widget>[
            // 组内非末条也要占住头像的位置，否则气泡会左右跳。
            SizedBox(
              width: ChatAvatar.size,
              child: lastInGroup ? ChatAvatar(role: role) : null,
            ),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: GestureDetector(
              onLongPressStart: generating
                  ? null
                  : (d) => _showMenu(context, d.globalPosition),
              child: bubble,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context, Color fg, Widget? footer) {
    // 用户消息是纯文本，走内联时间戳那条路 —— 短消息的时间跟在同一行，
    // 这是 Telegram 气泡最容易认出来的形状。
    if (_outgoing) {
      return _InlineTimeText(
        text: text,
        style: TextStyle(fontSize: 15.5, height: 1.35, color: fg),
        footer: footer,
      );
    }

    final Widget body;
    if (isError) {
      // 报错不走 markdown：异常信息里的 `*`、`_`、`#` 会被解析成格式，
      // 结果是错误内容被悄悄改写 —— 这恰恰是最不该被改写的一类文本。
      body = Text(
        text,
        style: TextStyle(fontSize: 14.5, height: 1.45, color: fg),
      );
    } else {
      body = MarkdownBody(
        data: text,
        selectable: false,
        styleSheet: _markdownStyle(context, fg),
      );
    }

    // 助手消息是 markdown，块级元素没法和一行文字共处，
    // 时间只能另起一行 —— Telegram 对长消息也是这么排的。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        body,
        if (footer != null)
          Align(alignment: Alignment.centerRight, child: footer),
      ],
    );
  }

  /// 长按菜单。Telegram 的消息操作全在这里。
  Future<void> _showMenu(BuildContext context, Offset globalPos) async {
    if (text.trim().isEmpty) return;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;

    final t = context.chat;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        globalPos & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: <PopupMenuEntry<String>>[
        const PopupMenuItem(
          value: 'copy',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.copy_outlined, size: 20),
            title: Text('复制'),
          ),
        ),
        if (onRetry != null)
          const PopupMenuItem(
            value: 'retry',
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.refresh, size: 20),
              title: Text('重新生成'),
            ),
          ),
        if (onEdit != null)
          const PopupMenuItem(
            value: 'edit',
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.edit_outlined, size: 20),
              title: Text('编辑并重发'),
            ),
          ),
        if (onRewind != null)
          const PopupMenuItem(
            value: 'rewind',
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.history, size: 20),
              title: Text('回到这里'),
              subtitle: Text('对话和文件一起回退', style: TextStyle(fontSize: 11)),
            ),
          ),
        if (onDelete != null)
          PopupMenuItem(
            value: 'delete',
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.delete_outline, size: 20, color: t.tintError),
              title: Text('删除这条及之后', style: TextStyle(color: t.tintError)),
            ),
          ),
      ],
    );

    if (selected == null || !context.mounted) return;
    switch (selected) {
      case 'copy':
        await Clipboard.setData(ClipboardData(text: text));
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('已复制'),
              duration: Duration(milliseconds: 900),
            ),
          );
        }
      case 'retry':
        onRetry?.call();
      case 'edit':
        onEdit?.call();
      case 'rewind':
        onRewind?.call();
      case 'delete':
        onDelete?.call();
    }
  }

  MarkdownStyleSheet _markdownStyle(BuildContext context, Color fg) {
    final t = context.chat;
    final base = MarkdownStyleSheet.fromTheme(Theme.of(context));
    final codeBg = t.tintPrimary.withValues(alpha: 0.06);
    return base.copyWith(
      p: TextStyle(fontSize: 15.5, height: 1.45, color: fg),
      listBullet: TextStyle(fontSize: 15.5, height: 1.45, color: fg),
      a: TextStyle(color: t.brand),
      strong: TextStyle(fontWeight: FontWeight.w600, color: fg),
      em: TextStyle(fontStyle: FontStyle.italic, color: fg),
      h1: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: fg),
      h2: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: fg),
      h3: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: fg),
      code: TextStyle(
        fontFamily: 'monospace',
        fontSize: 13,
        backgroundColor: codeBg,
        color: fg,
      ),
      codeblockDecoration: BoxDecoration(
        color: codeBg,
        borderRadius: BorderRadius.circular(6),
      ),
      blockquoteDecoration: BoxDecoration(
        color: t.brand.withValues(alpha: 0.08),
        border: Border(left: BorderSide(color: t.brand, width: 2)),
      ),
    );
  }
}

/// 气泡右下角那一小撮：模型名 + 时间。
class _BubbleFooter extends StatelessWidget {
  final String? meta;
  final DateTime time;
  final Color color;

  const _BubbleFooter({this.meta, required this.time, required this.color});

  @override
  Widget build(BuildContext context) {
    final hhmm = '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}';
    return Padding(
      // 左边留一点，免得贴着正文最后一个字。
      padding: const EdgeInsets.only(left: 8, top: 2),
      child: Text(
        meta == null || meta!.isEmpty ? hhmm : '$meta  $hhmm',
        style: TextStyle(fontSize: 11.5, height: 1, color: color),
      ),
    );
  }
}

/// 正文 + 右下角内联时间戳。
///
/// 做法：在文本流的末尾塞一个**和时间戳等宽的透明占位**，再把真的时间戳
/// 绝对定位到 Stack 的右下角。于是排版引擎会自动为时间戳留出位置 ——
/// 最后一行放得下就跟在同一行，放不下才换行。
///
/// 用 `Opacity(0, child: footer)` 而不是手算宽度：时间戳的宽度取决于字体和
/// 模型名长度，手算迟早会差几个像素，而差几个像素的表现是最后一个字被压住。
class _InlineTimeText extends StatelessWidget {
  final String text;
  final TextStyle style;
  final Widget? footer;

  const _InlineTimeText({
    required this.text,
    required this.style,
    this.footer,
  });

  @override
  Widget build(BuildContext context) {
    if (footer == null) return Text(text, style: style);
    return Stack(
      children: <Widget>[
        Text.rich(
          TextSpan(
            text: text,
            children: <InlineSpan>[
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: Opacity(opacity: 0, child: footer),
              ),
            ],
          ),
          style: style,
        ),
        Positioned(right: 0, bottom: 0, child: footer!),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 输入区
// ---------------------------------------------------------------------------

/// 输入区药丸里的一个图标按钮。
///
/// Telegram 把附件、表情这些放在输入框**里面**，发送键在外面。这里放的是
/// 终端模式和审批档位 —— 它们决定「这一句话怎么被处理」，和附件一样属于
/// "这条消息的修饰"，位置是对的。
class ComposerIconButton extends StatelessWidget {
  final IconData icon;
  final String? tooltip;
  final bool active;
  final bool enabled;
  final VoidCallback? onTap;

  /// 覆盖前景色。给"未配置模型"这类既不是 active 也不是普通态的按钮用 ——
  /// 拿 active 去表示"有问题"会让品牌色同时意味着"开着"和"缺东西"。
  final Color? color;

  const ComposerIconButton({
    super.key,
    required this.icon,
    this.tooltip,
    this.active = false,
    this.enabled = true,
    this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.chat;
    final fg = !enabled
        ? t.tintTertiary.withValues(alpha: 0.5)
        : color ?? (active ? t.brand : t.tintTertiary);

    final child = InkResponse(
      onTap: enabled ? onTap : null,
      radius: 22,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Icon(icon, size: 22, color: fg),
      ),
    );
    return tooltip == null ? child : Tooltip(message: tooltip!, child: child);
  }
}

/// Telegram 的输入区：一颗药丸 + 外面一个圆形发送键。
///
/// ```
/// [ ( 图标 [ 多行输入框 ] 图标 ) ( ● ) ]
/// ```
class ChatComposer extends StatelessWidget {
  final TextEditingController controller;
  final bool generating;
  final bool enabled;
  final String hintText;
  final VoidCallback onSend;
  final VoidCallback onStop;

  /// 药丸里左边的图标。
  final List<Widget> leading;

  /// 药丸里右边的图标。
  final List<Widget> trailing;

  const ChatComposer({
    super.key,
    required this.controller,
    required this.generating,
    required this.enabled,
    required this.hintText,
    required this.onSend,
    required this.onStop,
    this.leading = const [],
    this.trailing = const [],
  });

  @override
  Widget build(BuildContext context) {
    final t = context.chat;
    return Container(
      color: t.composerBg,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: t.composerField,
                    borderRadius:
                        BorderRadius.circular(ChatShape.composerRadius),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: <Widget>[
                      ...leading,
                      Expanded(
                        child: TextField(
                          controller: controller,
                          enabled: enabled,
                          minLines: 1,
                          maxLines: 6,
                          style: TextStyle(fontSize: 16, color: t.tintPrimary),
                          cursorColor: t.brand,
                          decoration: InputDecoration(
                            hintText: hintText,
                            hintStyle:
                                TextStyle(fontSize: 16, color: t.tintTertiary),
                            // 药丸本身就是输入框的边界。
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            disabledBorder: InputBorder.none,
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 12),
                          ),
                          textInputAction: TextInputAction.newline,
                          keyboardType: TextInputType.multiline,
                        ),
                      ),
                      ...trailing,
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 6),
              _SendButton(
                generating: generating,
                enabled: enabled,
                onSend: onSend,
                onStop: onStop,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 44px 圆形发送键。生成中变成停止键 ——
/// 换图标不换颜色的话，两个状态在余光里是一样的。
class _SendButton extends StatelessWidget {
  final bool generating;
  final bool enabled;
  final VoidCallback onSend;
  final VoidCallback onStop;

  const _SendButton({
    required this.generating,
    required this.enabled,
    required this.onSend,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.chat;
    final canSend = enabled || generating;
    final bg = generating
        ? t.tintSecondary
        : canSend
            ? t.brand
            // 禁用时用一个实心的弱色而不是降透明度：降透明度的话，
            // 按钮在深色下会糊进底色里，看不出这里还有个按钮。
            : t.tintTertiary.withValues(alpha: 0.35);

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: bg,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: generating ? onStop : (canSend ? onSend : null),
          child: SizedBox(
            width: 44,
            height: 44,
            child: Icon(
              generating ? Icons.stop_rounded : Icons.send_rounded,
              size: 21,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}
