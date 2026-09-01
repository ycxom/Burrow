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

import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../settings/settings_store.dart';
import 'chat_theme.dart';
import 'image_attachments.dart';

// ---------------------------------------------------------------------------
// 壁纸
// ---------------------------------------------------------------------------

/// 聊天区的壁纸。消息列表铺在它上面。
class ChatWallpaper extends StatelessWidget {
  final Widget child;
  final ChatWallpaperPreset preset;
  final String imagePath;
  final double dim;

  const ChatWallpaper({
    super.key,
    required this.child,
    this.preset = ChatWallpaperPreset.classic,
    this.imagePath = '',
    this.dim = 0,
  });

  static List<Color> colors(
    ChatWallpaperPreset preset,
    ChatTokens tokens,
    Brightness brightness,
  ) {
    final dark = brightness == Brightness.dark;
    return switch (preset) {
      ChatWallpaperPreset.classic => <Color>[
          tokens.wallpaperTop,
          tokens.wallpaperBottom
        ],
      ChatWallpaperPreset.aurora => dark
          ? const <Color>[
              Color(0xFF102B32),
              Color(0xFF193246),
              Color(0xFF292743),
            ]
          : const <Color>[
              Color(0xFFDDF6ED),
              Color(0xFFDDEEFF),
              Color(0xFFEDE4FA),
            ],
      ChatWallpaperPreset.sunset => dark
          ? const <Color>[
              Color(0xFF35242A),
              Color(0xFF342D3D),
              Color(0xFF1E3042),
            ]
          : const <Color>[
              Color(0xFFFFE4D4),
              Color(0xFFF8E2ED),
              Color(0xFFE3EAFB),
            ],
      ChatWallpaperPreset.midnight => dark
          ? const <Color>[
              Color(0xFF08131F),
              Color(0xFF102437),
              Color(0xFF122D35),
            ]
          : const <Color>[
              Color(0xFFD8E5EF),
              Color(0xFFC9D9E5),
              Color(0xFFBFD4D5),
            ],
    };
  }

  @override
  Widget build(BuildContext context) {
    final t = context.chat;
    final brightness = Theme.of(context).brightness;
    final palette = colors(preset, t, brightness);
    final customFile = imagePath.isEmpty ? null : File(imagePath);
    final hasCustomImage = customFile?.existsSync() ?? false;
    final overlay = dim.clamp(0.0, 0.6).toDouble();

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: palette,
            ),
          ),
        ),
        IgnorePointer(
          child: CustomPaint(
            painter: _WallpaperPatternPainter(
              color: (brightness == Brightness.dark
                      ? Colors.white
                      : const Color(0xFF436579))
                  .withValues(alpha: 0.055),
            ),
          ),
        ),
        if (hasCustomImage)
          Image.file(
            customFile!,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
            // 文件损坏或 Android 解码器不支持时保留下面的内置壁纸，设置页
            // 仍然能打开并让用户换一张，而不是整块区域抛红屏。
            errorBuilder: (_, __, ___) => const SizedBox.shrink(),
          ),
        if (overlay > 0)
          ColoredBox(color: Colors.black.withValues(alpha: overlay)),
        child,
      ],
    );
  }
}

/// 很淡的涂鸦纹理。参考 Nekogram/Telegram 的聊天壁纸，用对话、纸飞机、
/// 星光、代码和机器人等小图案打散重复感；透明度很低，不和消息正文抢视觉。
class _WallpaperPatternPainter extends CustomPainter {
  const _WallpaperPatternPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.15
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    const step = 78.0;
    var row = 0;
    for (double y = -18; y < size.height + step; y += step, row++) {
      final shifted = row.isEven ? 0.0 : step / 2;
      var column = 0;
      for (double x = -18 + shifted;
          x < size.width + step;
          x += step, column++) {
        canvas.save();
        canvas.translate(x, y);
        switch ((row * 3 + column * 5).abs() % 6) {
          case 0:
            _drawChat(canvas, paint);
          case 1:
            _drawPlane(canvas, paint);
          case 2:
            _drawSparkles(canvas, paint);
          case 3:
            _drawCode(canvas, paint);
          case 4:
            _drawBot(canvas, paint);
          case 5:
            _drawHeart(canvas, paint);
        }
        canvas.restore();
      }
    }
  }

  static void _drawChat(Canvas canvas, Paint paint) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(-15, -11, 30, 21),
        const Radius.circular(7),
      ),
      paint,
    );
    canvas.drawPath(
      Path()
        ..moveTo(-7, 10)
        ..lineTo(-11, 16)
        ..lineTo(-1, 11),
      paint,
    );
    canvas.drawCircle(const Offset(-6, 0), 1.2, paint);
    canvas.drawCircle(Offset.zero, 1.2, paint);
    canvas.drawCircle(const Offset(6, 0), 1.2, paint);
  }

  static void _drawPlane(Canvas canvas, Paint paint) {
    canvas.drawPath(
      Path()
        ..moveTo(-16, -9)
        ..lineTo(17, -15)
        ..lineTo(7, 16)
        ..lineTo(0, 4)
        ..close()
        ..moveTo(0, 4)
        ..lineTo(17, -15),
      paint,
    );
  }

  static void _drawSparkles(Canvas canvas, Paint paint) {
    Path sparkle(double x, double y, double r) => Path()
      ..moveTo(x, y - r)
      ..quadraticBezierTo(x + 1, y - 1, x + r, y)
      ..quadraticBezierTo(x + 1, y + 1, x, y + r)
      ..quadraticBezierTo(x - 1, y + 1, x - r, y)
      ..quadraticBezierTo(x - 1, y - 1, x, y - r)
      ..close();

    canvas.drawPath(sparkle(-4, 1, 13), paint);
    canvas.drawPath(sparkle(12, -10, 6), paint);
    canvas.drawPath(sparkle(12, 12, 4), paint);
  }

  static void _drawCode(Canvas canvas, Paint paint) {
    canvas.drawPath(
      Path()
        ..moveTo(-5, -10)
        ..lineTo(-15, 0)
        ..lineTo(-5, 10)
        ..moveTo(5, -10)
        ..lineTo(15, 0)
        ..lineTo(5, 10),
      paint,
    );
    canvas.drawLine(const Offset(3, -14), const Offset(-3, 14), paint);
  }

  static void _drawBot(Canvas canvas, Paint paint) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(-15, -10, 30, 23),
        const Radius.circular(7),
      ),
      paint,
    );
    canvas.drawLine(const Offset(0, -10), const Offset(0, -16), paint);
    canvas.drawCircle(const Offset(0, -18), 2, paint);
    canvas.drawCircle(const Offset(-6, 0), 2, paint);
    canvas.drawCircle(const Offset(6, 0), 2, paint);
    canvas.drawArc(const Rect.fromLTWH(-7, 3, 14, 6), 0.2, 2.75, false, paint);
  }

  static void _drawHeart(Canvas canvas, Paint paint) {
    canvas.drawPath(
      Path()
        ..moveTo(0, 15)
        ..cubicTo(-4, 9, -16, 3, -16, -6)
        ..cubicTo(-16, -15, -5, -18, 0, -9)
        ..cubicTo(5, -18, 16, -15, 16, -6)
        ..cubicTo(16, 3, 4, 9, 0, 15)
        ..close(),
      paint,
    );
  }

  @override
  bool shouldRepaint(_WallpaperPatternPainter oldDelegate) =>
      oldDelegate.color != color;
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
  final String imagePath;
  final double diameter;

  const ChatAvatar({
    super.key,
    required this.role,
    this.imagePath = '',
    this.diameter = size,
  });

  static const double size = 32;

  @override
  Widget build(BuildContext context) {
    final t = context.chat;
    final (IconData icon, List<Color> colors) = switch (role) {
      'assistant' => (
          Icons.auto_awesome_rounded,
          <Color>[t.brand, Color.lerp(t.brand, Colors.purple, 0.35)!]
        ),
      'user' => (
          Icons.person_rounded,
          <Color>[const Color(0xFF26A69A), const Color(0xFF4DB6AC)]
        ),
      'tool' => (
          Icons.terminal_rounded,
          <Color>[t.tintSecondary, t.tintTertiary]
        ),
      _ => (
          Icons.info_outline_rounded,
          <Color>[t.tintTertiary, t.tintSecondary]
        ),
    };

    final fallback = DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ),
      ),
      child: Center(
        child: Icon(icon, size: diameter * 0.53, color: Colors.white),
      ),
    );
    final file = imagePath.isEmpty ? null : File(imagePath);
    final Widget content = file?.existsSync() == true
        ? Image.file(
            file!,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
            errorBuilder: (_, __, ___) => fallback,
          )
        : fallback;

    return Container(
      width: diameter,
      height: diameter,
      padding: const EdgeInsets.all(1.5),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: t.headerBg,
        boxShadow: const <BoxShadow>[
          BoxShadow(
              color: Color(0x22000000), blurRadius: 3, offset: Offset(0, 1)),
        ],
      ),
      child: ClipOval(child: content),
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
class ServicePill extends StatefulWidget {
  final String text;

  /// 报错。用红字，但仍然是胶囊 —— 它不是对话内容。
  final bool isError;

  const ServicePill({super.key, required this.text, this.isError = false});

  /// 超过这么多字就折起来。
  ///
  /// 胶囊本来是给「今天」「检查点 #3」这种一行字用的。而注进历史的东西
  /// （检索片段、图片描述）动辄几百字，铺开会把整屏占满 —— 用户滚半天
  /// 找不到自己那句话。折起来之后它仍然在那里，点一下就能核对。
  static const _collapseAbove = 90;

  @override
  State<ServicePill> createState() => _ServicePillState();
}

class _ServicePillState extends State<ServicePill> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final t = context.chat;
    final collapsible = widget.text.length > ServicePill._collapseAbove;
    final color = widget.isError ? t.tintError : t.tintOnService;
    final showFull = _expanded || !collapsible;

    return Center(
      child: GestureDetector(
        onTap:
            collapsible ? () => setState(() => _expanded = !_expanded) : null,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 32),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: widget.isError ? t.bgErrorSecondary : t.servicePill,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                widget.text,
                textAlign: showFull ? TextAlign.start : TextAlign.center,
                maxLines: showFull ? null : 2,
                overflow: showFull ? null : TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.4,
                  fontWeight: FontWeight.w500,
                  color: color,
                ),
              ),
              if (collapsible)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    _expanded ? '收起' : '展开',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: color.withValues(alpha: 0.75),
                    ),
                  ),
                ),
            ],
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

  /// 随这条消息发出去的图片，绝对路径。
  final List<String> images;

  /// 这条是报错。
  final bool isError;

  /// 正在流式输出。此时不显示时间，也不响应长按 ——
  /// 半截内容上的"复制"和"重新生成"都没有意义。
  final bool generating;

  /// 这条是一组连续消息里的最后一条：画尾巴、显示头像。
  final bool lastInGroup;

  /// 当前说话者的自定义头像。空字符串使用角色默认图标。
  final String avatarPath;

  /// 关闭时连占位都不保留，气泡会自然贴回屏幕两侧。
  final bool showAvatar;

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
    this.images = const <String>[],
    this.isError = false,
    this.generating = false,
    this.lastInGroup = true,
    this.avatarPath = '',
    this.showAvatar = true,
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

    final maxWidth =
        MediaQuery.of(context).size.width * (showAvatar ? 0.76 : 0.84);

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
          if (!_outgoing && showAvatar) ...<Widget>[
            // 组内非末条也要占住头像的位置，否则气泡会左右跳。
            SizedBox(
              width: ChatAvatar.size,
              child: lastInGroup
                  ? ChatAvatar(role: role, imagePath: avatarPath)
                  : null,
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
          if (_outgoing && showAvatar) ...<Widget>[
            const SizedBox(width: 6),
            SizedBox(
              width: ChatAvatar.size,
              child: lastInGroup
                  ? ChatAvatar(role: role, imagePath: avatarPath)
                  : null,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context, Color fg, Widget? footer) {
    // 带图时先画图。图和文字之间不留边距是刻意的 —— Telegram 的图是
    // "贴着气泡内沿"的，留白会让它看起来像一张插在文字里的附件。
    final gallery = images.isEmpty
        ? null
        : BubbleImages(
            paths: images,
            maxWidth:
                MediaQuery.of(context).size.width * (showAvatar ? 0.76 : 0.84) -
                    // 减掉气泡自己的左右内边距，否则图会顶出圆角。
                    (22 + ChatShape.tailWidth),
          );

    // 用户消息是纯文本，走内联时间戳那条路 —— 短消息的时间跟在同一行，
    // 这是 Telegram 气泡最容易认出来的形状。
    if (_outgoing) {
      final body = _InlineTimeText(
        text: text,
        style: TextStyle(fontSize: 15.5, height: 1.35, color: fg),
        footer: footer,
      );
      if (gallery == null) return body;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Padding(padding: const EdgeInsets.only(top: 2), child: gallery),
          // 只有图、没有文字时，时间戳还得有地方待 —— 让它单独占一行，
          // 不然一条纯图片消息看不出发送时间。
          if (text.isNotEmpty)
            Padding(padding: const EdgeInsets.only(top: 5), child: body)
          else if (footer != null)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Align(alignment: Alignment.centerRight, child: footer),
            ),
        ],
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
  final ChatComposerEffect effect;
  final double blur;
  final double opacity;
  final bool safeAreaBottom;

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
    this.effect = ChatComposerEffect.liquid,
    this.blur = 20,
    this.opacity = 0.68,
    this.safeAreaBottom = true,
    this.leading = const [],
    this.trailing = const [],
  });

  @override
  Widget build(BuildContext context) {
    final t = context.chat;
    final content = Padding(
      padding: const EdgeInsets.fromLTRB(10, 5, 10, 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          Expanded(
            child: _ComposerSurface(
              effect: effect,
              blur: blur,
              opacity: opacity,
              child: Padding(
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
                            horizontal: 6,
                            vertical: 12,
                          ),
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
          ),
          const SizedBox(width: 7),
          _SendButton(
            generating: generating,
            enabled: enabled,
            onSend: onSend,
            onStop: onStop,
          ),
        ],
      ),
    );
    return safeAreaBottom ? SafeArea(top: false, child: content) : content;
  }
}

/// 输入药丸的材质层。模糊只裁在药丸内部，阴影留在裁剪外；否则玻璃会把整块
/// 底栏都糊掉，看起来像半透明面板而不是悬浮在壁纸上的一滴液体。
class _ComposerSurface extends StatelessWidget {
  const _ComposerSurface({
    required this.effect,
    required this.blur,
    required this.opacity,
    required this.child,
  });

  final ChatComposerEffect effect;
  final double blur;
  final double opacity;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = context.chat;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final alpha = opacity.clamp(0.25, 1.0).toDouble();
    final requestedBlur = blur.clamp(0.0, 30.0).toDouble();
    final radius = BorderRadius.circular(ChatShape.composerRadius + 2);

    final Color? color;
    final Gradient? gradient;
    final Border border;
    final double sigma;
    final List<BoxShadow> shadows;

    switch (effect) {
      case ChatComposerEffect.solid:
        color = t.composerField.withValues(alpha: alpha);
        gradient = null;
        border = Border.all(
          color: t.borderPrimary.withValues(alpha: 0.8),
          width: 0.8,
        );
        sigma = 0;
        shadows = const <BoxShadow>[
          BoxShadow(
            color: Color(0x18000000),
            blurRadius: 10,
            offset: Offset(0, 4),
          ),
        ];
      case ChatComposerEffect.frosted:
        color = t.composerBg.withValues(alpha: alpha);
        gradient = null;
        border = Border.all(
          color: (dark ? Colors.white : Colors.white)
              .withValues(alpha: dark ? 0.18 : 0.72),
        );
        sigma = requestedBlur;
        shadows = const <BoxShadow>[
          BoxShadow(
            color: Color(0x26000000),
            blurRadius: 18,
            offset: Offset(0, 7),
          ),
        ];
      case ChatComposerEffect.liquid:
        color = null;
        gradient = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: dark
              ? <Color>[
                  Colors.white.withValues(alpha: alpha * 0.22),
                  t.bgSecondary.withValues(alpha: alpha * 0.86),
                  t.brand.withValues(alpha: alpha * 0.16),
                ]
              : <Color>[
                  Colors.white.withValues(alpha: alpha * 0.96),
                  t.bgBrandSecondary.withValues(alpha: alpha * 0.76),
                  Colors.white.withValues(alpha: alpha * 0.62),
                ],
        );
        border = Border.all(
          color: Colors.white.withValues(alpha: dark ? 0.24 : 0.82),
          width: 1.1,
        );
        sigma = requestedBlur * 1.1;
        shadows = <BoxShadow>[
          const BoxShadow(
            color: Color(0x26000000),
            blurRadius: 24,
            offset: Offset(0, 9),
          ),
          BoxShadow(
            color: t.brand.withValues(alpha: dark ? 0.09 : 0.12),
            blurRadius: 20,
            spreadRadius: -4,
          ),
        ];
      case ChatComposerEffect.outline:
        color = t.composerBg.withValues(alpha: alpha * 0.34);
        gradient = null;
        border = Border.all(
          color: t.brand.withValues(alpha: 0.52),
          width: 1.2,
        );
        sigma = requestedBlur * 0.25;
        shadows = const <BoxShadow>[
          BoxShadow(
            color: Color(0x12000000),
            blurRadius: 8,
            offset: Offset(0, 3),
          ),
        ];
    }

    return DecoratedBox(
      decoration: BoxDecoration(borderRadius: radius, boxShadow: shadows),
      child: ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: color,
              gradient: gradient,
              border: border,
              borderRadius: radius,
            ),
            child: Stack(
              children: <Widget>[
                child,
                if (effect == ChatComposerEffect.liquid)
                  Positioned(
                    left: 22,
                    right: 22,
                    top: 1,
                    child: IgnorePointer(
                      child: Container(
                        height: 1,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(
                            alpha: dark ? 0.22 : 0.76,
                          ),
                          borderRadius: BorderRadius.circular(1),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
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
