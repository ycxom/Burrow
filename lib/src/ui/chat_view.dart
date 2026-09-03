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

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../agent/agent_loop.dart' show TokenUsage;
import '../context/token_counter.dart';
import '../settings/settings_store.dart';
import 'chat_theme.dart';
import 'image_attachments.dart';
import 'liquid_glass.dart';
import 'skin_parts.dart';
import 'skin_style.dart';
import 'thinking.dart';

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
    final style = context.parts.shellBackground;
    final brightness = Theme.of(context).brightness;
    final palette = colors(preset, t, brightness);
    final customFile = imagePath.isEmpty ? null : File(imagePath);
    final hasCustomImage = customFile?.existsSync() ?? false;
    final overlay = dim.clamp(0.0, 0.6).toDouble();

    // **用户的选择压皮肤。** 自己选过图或换过预设的人，装一个新皮肤时不该
    // 发现背景被悄悄换掉了 —— 那是他明确设过的东西。皮肤只接管"还没人动过"
    // 的那种情况（classic 预设 + 没有自定义图）。
    final skinOwns = preset == ChatWallpaperPreset.classic && !hasCustomImage;
    final skinGradient = skinOwns ? style.gradient : null;
    final skinImage = skinOwns ? style.image : null;
    final skinFile = skinImage == null ? null : File(skinImage);
    final hasSkinImage = skinFile?.existsSync() ?? false;

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        DecoratedBox(
          decoration: BoxDecoration(
            color: skinGradient == null ? style.fillColor() : null,
            gradient: skinGradient ??
                LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: palette,
                ),
          ),
        ),
        // 涂鸦纹理是内置壁纸的一部分。皮肤自己铺了渐变或图片时就不叠 ——
        // 叠上去会在一张精心挑过的背景图上糊一层不属于它的花纹。
        if (skinGradient == null && !hasSkinImage)
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
        if (hasSkinImage)
          Image.file(
            skinFile!,
            fit: style.background?.fit ?? BoxFit.cover,
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
            errorBuilder: (_, __, ___) => const SizedBox.shrink(),
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

  /// 圆角。皮肤可以改，但只有一个值 —— 带尾巴的形状分四角没有意义，
  /// 尾巴那个角本来就是被尾巴占掉的。
  final double radius;

  /// 尾巴伸出去的宽度。
  final double tailWidth;

  const BubbleShape({
    required this.outgoing,
    required this.tail,
    this.radius = ChatShape.bubbleRadius,
    this.tailWidth = ChatShape.tailWidth,
  });

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
    // 圆角不能超过气泡高度的一半，否则 arcToPoint 画出来的路径会自交，
    // 表现是气泡边缘出现一个尖角 —— 皮肤把 radius 写成 999 时就会这样。
    final r = radius.clamp(0.0, rect.shortestSide / 2);
    final tw = tailWidth;
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
    p.arcToPoint(Offset(body.right, body.top + r), radius: Radius.circular(r));

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
          radius: Radius.circular(r));
    }

    p.lineTo(body.left + r, body.bottom);
    p.arcToPoint(Offset(body.left, body.bottom - r),
        radius: Radius.circular(r));
    p.lineTo(body.left, body.top + r);
    p.arcToPoint(Offset(body.left + r, body.top), radius: Radius.circular(r));
    return p..close();
  }

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {}

  @override
  bool operator ==(Object other) =>
      other is BubbleShape &&
      other.outgoing == outgoing &&
      other.tail == tail &&
      other.radius == radius &&
      other.tailWidth == tailWidth;

  @override
  int get hashCode => Object.hash(outgoing, tail, radius, tailWidth);
}

// ---------------------------------------------------------------------------
// 头像
// ---------------------------------------------------------------------------

/// 32px 圆形头像。只有收到的消息带 —— 自己发的不需要头像提醒是谁说的。
class ChatAvatar extends StatelessWidget {
  final String role;
  final String imagePath;
  final double diameter;

  /// 皮肤给的样式。形状、描边、投影走它 —— 尺寸由 [diameter] 决定，
  /// 因为调用方（气泡的占位列）需要先知道宽度才能布局。
  final PartStyle style;

  const ChatAvatar({
    super.key,
    required this.role,
    this.imagePath = '',
    this.diameter = size,
    this.style = PartStyle.empty,
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

    // 皮肤给了底色或渐变就用它，否则还是按角色分色 —— 角色配色是"这是谁说的"
    // 的次要线索，皮肤没表态时不该丢掉。
    final skinGradient = style.gradient;
    final skinColor = style.fillColor();
    final corners = style.rounded(BorderRadius.circular(diameter / 2));
    final fallback = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: corners,
        color: skinGradient == null ? skinColor : null,
        gradient: skinGradient ??
            (skinColor != null
                ? null
                : LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: colors,
                  )),
      ),
      child: Center(
        child: Icon(
          style.iconOr(icon),
          size: style.iconSizeOr(diameter * 0.53),
          color: style.iconColorOr(Colors.white),
        ),
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

    return style.decorate(Container(
      width: diameter,
      height: diameter,
      padding: style.padded(const EdgeInsets.all(1.5)),
      decoration: BoxDecoration(
        borderRadius: corners,
        color: t.headerBg,
        border: style.borderOr(null),
        boxShadow: style.shadowsOr(const <BoxShadow>[
          BoxShadow(
              color: Color(0x22000000), blurRadius: 3, offset: Offset(0, 1)),
        ]),
      ),
      child: ClipRRect(borderRadius: corners, child: content),
    ));
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
    final style = context.parts.datePill;
    final collapsible = widget.text.length > ServicePill._collapseAbove;
    final color =
        style.text?.color ?? (widget.isError ? t.tintError : t.tintOnService);
    final showFull = _expanded || !collapsible;

    // 报错胶囊不让皮肤隐藏。日期分隔藏了只是少个提示，报错藏了就是
    // "模型没反应"而用户看不到原因。
    if (style.hidden && !widget.isError) return const SizedBox.shrink();

    final corners = style.rounded(BorderRadius.circular(14));
    return Center(
      child: GestureDetector(
        onTap:
            collapsible ? () => setState(() => _expanded = !_expanded) : null,
        child: Container(
          margin: style.margined(
            const EdgeInsets.symmetric(vertical: 8, horizontal: 32),
          ),
          padding: style.padded(
            const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          ),
          decoration: BoxDecoration(
            color: style.gradient == null
                ? style.fillColor(
                    widget.isError ? t.bgErrorSecondary : t.servicePill)
                : null,
            gradient: style.gradient,
            border: style.borderOr(null),
            borderRadius: corners,
            boxShadow: style.shadowsOr(null),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                widget.text,
                textAlign: showFull ? TextAlign.start : TextAlign.center,
                maxLines: showFull ? null : 2,
                overflow: showFull ? null : TextOverflow.ellipsis,
                style: style.styled(TextStyle(
                  fontSize: 12,
                  height: 1.4,
                  fontWeight: FontWeight.w500,
                  color: color,
                )),
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

  /// 这条助手消息的服务端 token 用量。null = 服务端没回报，或这是用户消息。
  final TokenUsage? usage;

  /// 显示 token 用量。关掉时连估算也不显示。
  final bool showTokens;

  /// 随这条消息发出去的图片，绝对路径。
  final List<String> images;

  /// 这条是报错。
  final bool isError;

  /// 正在流式输出。此时不显示时间，也不响应长按 ——
  /// 半截内容上的"复制"和"重新生成"都没有意义。
  final bool generating;

  /// 模型给出这条回答之前的思考过程。空 = 不画那一块。
  final String reasoning;

  /// 思考还没结束。为真时那一块自己在走秒、点在跳。
  final bool reasoningActive;

  /// 开始思考的时刻，只有正在生成的那条有。
  final DateTime? reasoningStartedAt;

  /// 思考一共花了多久，毫秒。历史消息从库里读出来。
  final int reasoningMs;

  /// 这条消息所在分支点一共有几个版本。1 或 0 = 没得选，不画切换器。
  final int variantCount;

  /// 正在看第几个版本，从 0 数。
  final int variantIndex;

  /// 切到第 n 个版本。null = 不可切换。
  final ValueChanged<int>? onSwitchVariant;

  /// 这条是一组连续消息里的最后一条：画尾巴、显示头像。
  final bool lastInGroup;

  /// 这条是一组连续消息里的第一条。只用于皮肤的 `:first` 状态 ——
  /// 内置外观不区分它，但"组内第一条的上圆角大一点"是很常见的皮肤做法。
  final bool firstInGroup;

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
    this.usage,
    this.showTokens = true,
    this.images = const <String>[],
    this.isError = false,
    this.generating = false,
    this.reasoning = '',
    this.reasoningActive = false,
    this.reasoningStartedAt,
    this.reasoningMs = 0,
    this.variantCount = 0,
    this.variantIndex = 0,
    this.onSwitchVariant,
    this.lastInGroup = true,
    this.firstInGroup = true,
    this.avatarPath = '',
    this.showAvatar = true,
    this.onRetry,
    this.onEdit,
    this.onRewind,
    this.onDelete,
  });

  bool get _outgoing => role == 'user';

  /// 当前这条消息该用哪一份样式。
  ///
  /// 优先级：流式中 > 组内末条 > 组内首条 > 无条件。generating 排最前是因为
  /// 它是**临时**状态，用户看到的应该是"这条正在写"，而不是"这条在组里的
  /// 位置"。
  PartStyle _pick(PartStyle base) {
    if (generating) {
      final style = base.on(SkinState.generating);
      if (style != null) return style;
    }
    if (lastInGroup) {
      final style = base.on(SkinState.last);
      if (style != null) return style;
    }
    if (firstInGroup) {
      final style = base.on(SkinState.first);
      if (style != null) return style;
    }
    return base;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.chat;
    final parts = context.parts;
    final layout = parts.bubbleLayout;
    final style = _pick(parts.bubbleFor(outgoing: _outgoing, isError: isError));

    final bg = style.fillColor(isError
        ? t.bgErrorSecondary
        : _outgoing
            ? t.bubbleOut
            : t.bubbleIn)!;
    final fg = style.text?.color ??
        (isError
            ? t.tintPrimary
            : _outgoing
                ? t.tintOnOut
                : t.tintOnIn);
    final timeColor =
        parts.bubbleTime.text?.color ?? (_outgoing ? t.timeOut : t.timeIn);

    // 头像位置是版式开关，但用户在外观页关掉头像的优先级更高 ——
    // 那是他显式关的。
    final withAvatar =
        showAvatar && parts.avatarPosition == SkinAvatarPosition.side;

    // 尾巴只在 tail 版式下存在。plain/card 本来就是"没有尾巴"的意思，
    // 这时再读 bubble.tail 会让两个开关互相打架。
    final withTail = layout == SkinBubbleLayout.tail &&
        lastInGroup &&
        !parts.bubbleTail.hidden;
    final tailWidth =
        withTail ? (parts.bubbleTail.size ?? ChatShape.tailWidth) : 0.0;

    final maxFactor = style.maxWidthFactor ??
        (layout == SkinBubbleLayout.card
            ? 0.92
            : withAvatar
                ? 0.76
                : 0.84);
    final maxWidth = MediaQuery.of(context).size.width * maxFactor;

    final showTime =
        time != null && parts.timePosition != SkinTimePosition.hidden;
    final inline = showTime && parts.timePosition == SkinTimePosition.inside;
    final footer = showTime
        ? _BubbleFooter(
            meta: meta,
            time: time!,
            color: timeColor,
            style: parts.bubbleTime,
            tokens: showTokens ? _tokenLabel() : null,
          )
        : null;

    final defaultRadius = BorderRadius.circular(
      layout == SkinBubbleLayout.card ? 10 : ChatShape.bubbleRadius,
    );
    final border = style.borderOr(null);
    // 带尾巴的气泡是一条自定义路径，描边要沿着尾巴走 —— 那需要 BubbleShape
    // 自己会画边框。它不会，所以 tail 版式下忽略 border，而不是画一个和尾巴
    // 对不上的矩形框。
    final ShapeBorder shape = layout == SkinBubbleLayout.tail
        ? BubbleShape(
            outgoing: _outgoing,
            tail: withTail,
            radius: style.radius?.maxRadius ?? ChatShape.bubbleRadius,
            tailWidth: tailWidth,
          )
        : RoundedRectangleBorder(
            borderRadius: style.rounded(defaultRadius),
            side: border?.top ?? BorderSide.none,
          );

    final bubble = Container(
      constraints: BoxConstraints(maxWidth: maxWidth),
      decoration: ShapeDecoration(
        color: style.gradient == null ? bg : null,
        gradient: style.gradient,
        shape: shape,
        shadows: style.shadowsOr(
          layout == SkinBubbleLayout.card
              ? const <BoxShadow>[
                  BoxShadow(
                    color: Color(0x1F000000),
                    blurRadius: 8,
                    offset: Offset(0, 3),
                  ),
                ]
              : const <BoxShadow>[
                  BoxShadow(
                    color: Color(0x14000000),
                    blurRadius: 1,
                    offset: Offset(0, 1),
                  ),
                ],
        ),
      ),
      padding: style.padded(EdgeInsets.fromLTRB(
        // 带尾巴那侧要多让出尾巴的宽度，否则正文会压到钩子上。
        _outgoing || !withTail ? 11 : 11 + tailWidth,
        6,
        _outgoing && withTail ? 11 + tailWidth : 11,
        6,
      )),
      child: _buildBody(context, fg, inline ? footer : null, style),
    );

    // 版本切换器挂在气泡**外面**：用户气泡的时间戳是压在正文里的
    // （见 _InlineTimeText），塞进去会把那套排版顶乱。
    final switcher = variantCount > 1 && onSwitchVariant != null
        ? _VariantSwitcher(
            index: variantIndex,
            total: variantCount,
            color: timeColor,
            onSwitch: onSwitchVariant!,
          )
        : null;

    final Widget body = (footer != null && !inline) || switcher != null
        ? Column(
            crossAxisAlignment:
                _outgoing ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              bubble,
              if (footer != null && !inline)
                Padding(
                  padding: const EdgeInsets.only(top: 2, left: 6, right: 6),
                  child: footer,
                ),
              if (switcher != null)
                Padding(
                  padding: const EdgeInsets.only(top: 1, left: 4, right: 4),
                  child: switcher,
                ),
            ],
          )
        : bubble;

    return style.decorate(Padding(
      // 组内 2px、组间 8px。这个节奏是 Telegram 最直观的部分。
      padding: style.margined(EdgeInsets.only(
        left: 8,
        right: 8,
        top: 1,
        bottom: lastInGroup ? 7 : 1,
      )),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisAlignment:
            _outgoing ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: <Widget>[
          if (!_outgoing && withAvatar) ...<Widget>[
            // 组内非末条也要占住头像的位置，否则气泡会左右跳。
            SizedBox(
              width: _avatarSize(parts),
              child: lastInGroup ? _avatar(parts) : null,
            ),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: GestureDetector(
              onLongPressStart: generating
                  ? null
                  : (d) => _showMenu(context, d.globalPosition),
              child: body,
            ),
          ),
          if (_outgoing && withAvatar) ...<Widget>[
            const SizedBox(width: 6),
            SizedBox(
              width: _avatarSize(parts),
              child: lastInGroup ? _avatar(parts) : null,
            ),
          ],
        ],
      ),
    ));
  }

  /// 气泡上那一小撮 token 数。
  ///
  /// 助手消息用**服务端回报的真实值**：`↑` 是这次请求的整个上下文，`↓` 是生成
  /// 的部分。上行数会随对话变长一直涨 —— 那正是它值得显示的原因，用户能直接
  /// 看到"这一句为什么突然变贵了"。
  ///
  /// 用户消息没有服务端口径可言（它的开销含在下一条助手消息的上行里），显示的
  /// 是本地估算。服务端不回报用量的网关（实测不少）下，助手消息也会是估算值。
  /// 两种情况都用 `~` 打头 —— **不把估算和真值混成一个看起来一样的数**，
  /// 一个能拿来对账的数字里混进估算，比不显示更糟。
  String? _tokenLabel() {
    final real = usage;
    if (real != null && !real.isEmpty) {
      final mark = real.estimated ? '~' : '';
      return '$mark↑${_compact(real.input)} ↓${_compact(real.output)}';
    }
    if (_outgoing && text.isNotEmpty) {
      return '~${_compact(TokenCounter.estimate(text))}';
    }
    return null;
  }

  /// 一万以下给准确值，以上折成 `12.8k`。
  ///
  /// 长对话的上行动辄六位数，全写出来会把气泡的一行挤没；而一万以下的数正是
  /// 用户会拿去和账单核对的那些，不能糊。
  static String _compact(int value) {
    if (value < 10000) return '$value';
    final k = value / 1000;
    return k < 100 ? '${k.toStringAsFixed(1)}k' : '${k.round()}k';
  }

  PartStyle _avatarStyle(ChatSkinParts parts) =>
      _outgoing ? parts.avatarUser : parts.avatarAssistant;

  double _avatarSize(ChatSkinParts parts) =>
      _avatarStyle(parts).size ?? ChatAvatar.size;

  Widget _avatar(ChatSkinParts parts) => ChatAvatar(
        role: role,
        imagePath: avatarPath,
        diameter: _avatarSize(parts),
        style: _avatarStyle(parts),
      );

  Widget _buildBody(
    BuildContext context,
    Color fg,
    Widget? footer,
    PartStyle style,
  ) {
    // 带图时先画图。图和文字之间不留边距是刻意的 —— Telegram 的图是
    // "贴着气泡内沿"的，留白会让它看起来像一张插在文字里的附件。
    final gallery = images.isEmpty
        ? null
        : BubbleImages(
            paths: images,
            maxWidth: MediaQuery.of(context).size.width *
                    (style.maxWidthFactor ?? (showAvatar ? 0.76 : 0.84)) -
                // 减掉气泡自己的左右内边距，否则图会顶出圆角。
                (22 + ChatShape.tailWidth),
          );

    // 用户消息是纯文本，走内联时间戳那条路 —— 短消息的时间跟在同一行，
    // 这是 Telegram 气泡最容易认出来的形状。
    if (_outgoing) {
      final body = _InlineTimeText(
        text: text,
        style: style.styled(TextStyle(fontSize: 15.5, height: 1.35, color: fg)),
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

    final thinking = reasoning.trim().isEmpty
        ? null
        : ThinkingBlock(
            text: reasoning,
            active: reasoningActive,
            foreground: fg,
            startedAt: reasoningStartedAt,
            elapsedMs: reasoningMs,
          );

    // 还一个字都没吐出来。这一刻**必须有东西在动** —— 推理模型开口前
    // 沉默十几秒是常事，静止的空气泡和卡死了长得一模一样。
    if (generating && text.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (thinking != null) thinking,
            // 思考已经在跳点了，再来一组是两处动画抢注意力。
            if (thinking == null) TypingDots(color: fg.withValues(alpha: 0.5)),
          ],
        ),
      );
    }

    final Widget body;
    if (isError) {
      // 报错不走 markdown：异常信息里的 `*`、`_`、`#` 会被解析成格式，
      // 结果是错误内容被悄悄改写 —— 这恰恰是最不该被改写的一类文本。
      body = Text(
        text,
        style: style.styled(TextStyle(fontSize: 14.5, height: 1.45, color: fg)),
      );
    } else {
      body = MarkdownBody(
        data: text,
        selectable: false,
        styleSheet: _markdownStyle(context, fg, style),
      );
    }

    // 助手消息是 markdown，块级元素没法和一行文字共处，
    // 时间只能另起一行 —— Telegram 对长消息也是这么排的。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        // 思考排在正文**上面**：它发生在回答之前，排在下面会读成
        // "答完了又补了一段"。
        if (thinking != null) thinking,
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
              // 具体是"保存"还是"保存并重发"由编辑框里再选 ——
              // 助手消息没有"重发"，那个按钮压根不会出现。
              title: Text('编辑'),
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

  MarkdownStyleSheet _markdownStyle(
    BuildContext context,
    Color fg,
    PartStyle style,
  ) {
    final t = context.chat;
    final base = MarkdownStyleSheet.fromTheme(Theme.of(context));
    final codeBg = t.tintPrimary.withValues(alpha: 0.06);
    // 正文字号跟着皮肤走，标题按比例缩放 —— 皮肤把正文调到 18 之后，
    // 标题还停在 20 会让层级看起来是平的。
    final body =
        style.styled(TextStyle(fontSize: 15.5, height: 1.45, color: fg));
    final scale = (body.fontSize ?? 15.5) / 15.5;
    return base.copyWith(
      p: body,
      listBullet: body,
      a: TextStyle(color: t.brand),
      strong: TextStyle(fontWeight: FontWeight.w600, color: fg),
      em: TextStyle(fontStyle: FontStyle.italic, color: fg),
      h1: TextStyle(
          fontSize: 20 * scale, fontWeight: FontWeight.w600, color: fg),
      h2: TextStyle(
          fontSize: 18 * scale, fontWeight: FontWeight.w600, color: fg),
      h3: TextStyle(
          fontSize: 16 * scale, fontWeight: FontWeight.w600, color: fg),
      code: TextStyle(
        fontFamily: 'monospace',
        fontSize: 13 * scale,
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
  final PartStyle style;

  /// 已经排好版的 token 串，例如 `↑1.2k ↓340`。null = 不显示。
  final String? tokens;

  const _BubbleFooter({
    this.meta,
    required this.time,
    required this.color,
    this.style = PartStyle.empty,
    this.tokens,
  });

  @override
  Widget build(BuildContext context) {
    final hhmm = '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}';
    // 顺序是「模型 · 用量　时间」：时间永远在最右，位置固定；用量插在它左边，
    // 因为它和模型名是一组（都在说"这一句是怎么来的"）。
    final label = <String>[
      if (meta != null && meta!.isNotEmpty) meta!,
      if (tokens != null) tokens!,
    ].join(' · ');

    return Padding(
      // 左边留一点，免得贴着正文最后一个字。
      padding: style.padded(const EdgeInsets.only(left: 8, top: 2)),
      child: Text(
        label.isEmpty ? hhmm : '$label  $hhmm',
        style: style.styled(TextStyle(fontSize: 11.5, height: 1, color: color)),
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
class ComposerIconButton extends StatefulWidget {
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
  State<ComposerIconButton> createState() => _ComposerIconButtonState();
}

class _ComposerIconButtonState extends State<ComposerIconButton> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.chat;
    final style = context.parts.composerIcon;
    final fg = !widget.enabled
        ? t.tintTertiary.withValues(alpha: 0.5)
        : widget.color ??
            (widget.active ? t.brand : style.icon?.color ?? t.tintTertiary);
    final dimension = style.size ?? 40;

    final child = AnimatedScale(
      duration: Duration(milliseconds: _pressed ? 90 : 180),
      curve: _pressed ? Curves.easeOutCubic : Curves.easeOutBack,
      scale: _pressed && widget.enabled ? 0.88 : 1,
      child: SizedBox.square(
        dimension: dimension,
        child: Material(
          color: widget.active
              ? t.brand.withValues(alpha: 0.12)
              : style.fillColor(Colors.transparent),
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            customBorder: const CircleBorder(),
            onHighlightChanged: widget.enabled ? _setPressed : null,
            onTap: widget.enabled ? widget.onTap : null,
            child: Center(
              child: Icon(
                widget.icon,
                size: style.iconSizeOr(21),
                color: fg,
              ),
            ),
          ),
        ),
      ),
    );
    return widget.tooltip == null
        ? child
        : Tooltip(message: widget.tooltip!, child: child);
  }
}

/// Telegram 的输入区：一颗药丸 + 外面一个圆形发送键。
///
/// ```
/// [ ( 图标 [ 多行输入框 ] 图标 ) ( ● ) ]
/// ```
class ChatComposer extends StatefulWidget {
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
  final bool hasExternalContent;

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
    this.hasExternalContent = false,
    this.leading = const [],
    this.trailing = const [],
  });

  @override
  State<ChatComposer> createState() => _ChatComposerState();
}

/// 有状态只为了一件事：把焦点变化告诉皮肤的 `:focused`。
///
/// 用 FocusNode 而不是 `Focus` 包一层：输入框本来就要一个 node，包一层的话
/// 焦点会先落到外层再传进去，中间那一帧样式是错的。
class _ChatComposerState extends State<ChatComposer> {
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChanged);
    _focus.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (mounted) {
      setState(() {});
      if (_focus.hasFocus) {
        HapticFeedback.selectionClick();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.chat;
    final parts = context.parts;
    final field =
        (_focus.hasFocus ? parts.composerField.on(SkinState.focused) : null) ??
            parts.composerField;
    final docked = parts.composerMode == SkinComposerMode.docked;
    final content = Padding(
      // 贴底模式去掉外边距，输入区就从"浮在壁纸上的一滴"变成"钉在底边的一条"。
      padding: parts.composerDock.margined(
        docked ? EdgeInsets.zero : const EdgeInsets.fromLTRB(10, 5, 10, 9),
      ),
      child: _ComposerDock(
        docked: docked,
        focused: _focus.hasFocus,
        // 液态档下底座自己不上色 —— 见 _ComposerDock.glass。
        glass: widget.effect == ChatComposerEffect.liquid,
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              Expanded(
                child: AnimatedSize(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.bottomCenter,
                  clipBehavior: Clip.none,
                  child: _ComposerSurface(
                    effect: widget.effect,
                    blur: widget.blur,
                    opacity: widget.opacity,
                    style: field,
                    focused: _focus.hasFocus,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 42),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: <Widget>[
                            ...widget.leading,
                            Expanded(
                              child: TextField(
                                controller: widget.controller,
                                focusNode: _focus,
                                enabled: widget.enabled,
                                minLines: 1,
                                maxLines: 6,
                                // 输入框是**必留部件**：皮肤能改字号和颜色，
                                // 但这里从不读它的 visible —— 一个没有输入框的
                                // 聊天页不是皮肤，是坏了。
                                style: field.styled(
                                  TextStyle(
                                    fontSize: 16,
                                    height: 1.32,
                                    color: t.tintPrimary,
                                  ),
                                ),
                                cursorColor: t.brand,
                                cursorRadius: const Radius.circular(1),
                                cursorWidth: 1.8,
                                decoration: InputDecoration(
                                  hintText: widget.hintText,
                                  hintStyle: field
                                      .styled(
                                        TextStyle(
                                          fontSize: 16,
                                          height: 1.32,
                                          color: t.tintTertiary,
                                        ),
                                      )
                                      .copyWith(color: t.tintTertiary),
                                  // 药丸本身就是输入框的边界。
                                  border: InputBorder.none,
                                  enabledBorder: InputBorder.none,
                                  focusedBorder: InputBorder.none,
                                  disabledBorder: InputBorder.none,
                                  isDense: true,
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 5,
                                    vertical: 10,
                                  ),
                                ),
                                textInputAction: TextInputAction.newline,
                                keyboardType: TextInputType.multiline,
                              ),
                            ),
                            ...widget.trailing,
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: widget.controller,
                builder: (context, value, _) => _SendButton(
                  generating: widget.generating,
                  enabled: widget.enabled,
                  hasContent:
                      widget.hasExternalContent || value.text.trim().isNotEmpty,
                  onSend: widget.onSend,
                  onStop: widget.onStop,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return widget.safeAreaBottom
        ? SafeArea(top: false, child: content)
        : content;
  }
}

/// 把输入药丸和发送键收进同一个立体底座。底座只负责层次和对齐，玻璃材质
/// 仍由 [_ComposerSurface] 负责，两层的职责不会在未来皮肤包里互相覆盖。
class _ComposerDock extends StatelessWidget {
  const _ComposerDock({
    required this.child,
    this.docked = false,
    this.focused = false,
    this.glass = false,
  });

  final Widget child;
  final bool docked;
  final bool focused;

  /// 里面那块是液态玻璃，底座就不要再画自己的边框和底色了。
  ///
  /// 底座和输入药丸是两个同心圆角矩形，各画各的描边。以前药丸糊得很重、
  /// 边界模糊，两圈叠在一起看不太出来；换上折射之后药丸边缘一下子变得很
  /// 清晰，于是**两圈描边就成了肉眼可见的「套了两层」**。
  ///
  /// 玻璃本身已经足够立体（折射 + 内阴影 + 高光），底座这时只留布局和外边距。
  /// 皮肤如果自己指定了底色/描边，仍然照画 —— 那是皮肤作者的明确意图。
  final bool glass;

  @override
  Widget build(BuildContext context) {
    final t = context.chat;
    final style = context.parts.composerDock;
    final radius = style.rounded(
      docked ? BorderRadius.zero : BorderRadius.circular(29),
    );
    final gradient = style.gradient;

    final defaultShadows = <BoxShadow>[
      BoxShadow(
        color: t.composerDockShadow,
        blurRadius: 20,
        spreadRadius: -2,
        offset: const Offset(0, 9),
      ),
      BoxShadow(
        color: t.brand.withValues(alpha: focused ? 0.24 : 0.12),
        blurRadius: focused ? 20 : 16,
        spreadRadius: focused ? -2 : -5,
        offset: const Offset(0, 2),
      ),
    ];

    // 皮肤有没有自己指定过**底色或描边**。指定过就一律照画，玻璃与否都不插手。
    //
    // 阴影不算数：内置皮肤好几个都写着 `shadows: []`（意思是「这一档不要
    // 投影」），把它当成「皮肤自己画了底座」的话，底座会继续画出那圈描边，
    // 于是玻璃药丸外面又套了一层框 —— 正是要修掉的那个「两层」。
    final skinned =
        style.fillColor() != null || gradient != null || style.border != null;
    final bare = glass && !skinned;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        borderRadius: radius,
        color: bare || gradient != null ? null : style.fillColor(),
        gradient: bare
            ? null
            : gradient ??
                (style.fillColor() != null
                    ? null
                    : LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: <Color>[
                          t.composerDockTop,
                          t.composerDockBottom,
                        ],
                      )),
        border: bare
            ? null
            : style.borderOr(
                Border.all(
                  color: focused
                      ? t.brand.withValues(alpha: 0.6)
                      : t.composerDockRim,
                  width: focused ? 1.2 : 0.8,
                ),
              ),
        boxShadow: bare ? null : style.shadowsOr(defaultShadows),
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Stack(
          children: <Widget>[
            child,
            // 顶边那道高光只属于立体底座。皮肤把底座改成扁平（去掉阴影）之后
            // 还留着它，会变成一条没有来由的白线；底座整个隐身时同理。
            if (style.shadows == null && !bare)
              Positioned(
                left: 18,
                right: 18,
                top: 1,
                child: IgnorePointer(
                  child: Container(
                    height: 1,
                    color: Colors.white.withValues(alpha: 0.28),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 输入药丸的材质层。模糊只裁在药丸内部，阴影留在裁剪外；否则玻璃会把整块
/// 底栏都糊掉，看起来像半透明面板而不是悬浮在壁纸上的一滴液体。
class _ComposerSurface extends StatelessWidget {
  const _ComposerSurface({
    required this.effect,
    required this.blur,
    required this.opacity,
    required this.style,
    required this.child,
    this.focused = false,
  });

  final ChatComposerEffect effect;
  final double blur;
  final double opacity;

  /// 已经按焦点状态解析过的 `composer.field` 样式。由 ChatComposer 传进来而不是
  /// 在这里查 context.parts —— 焦点只有它知道。
  final PartStyle style;
  final Widget child;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    final t = context.chat;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final alpha = opacity.clamp(0.25, 1.0).toDouble();
    final requestedBlur = blur.clamp(0.0, 30.0).toDouble();
    final radius =
        style.rounded(BorderRadius.circular(ChatShape.composerRadius + 2));

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
        // KernelSU 在折射后的表面统一画 surfaceContainer(40%)。这里用主题的
        // composer 底色承担同一职责，上面的渐变只保留玻璃的方向性高光。
        color = t.composerBg.withValues(alpha: alpha * 0.38);
        gradient = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: dark
              ? <Color>[
                  Colors.white.withValues(alpha: alpha * 0.10),
                  t.bgSecondary.withValues(alpha: alpha * 0.30),
                  t.brand.withValues(alpha: alpha * 0.08),
                ]
              : <Color>[
                  Colors.white.withValues(alpha: alpha * 0.46),
                  t.bgBrandSecondary.withValues(alpha: alpha * 0.30),
                  Colors.white.withValues(alpha: alpha * 0.26),
                ],
        );
        // 描边交给 _GlassEdge 那圈**带角度的**渐变，这里给一条透明的占位。
        // 一圈均匀的白边是「描过边的方块」，不是玻璃 —— 真玻璃的亮边跟着
        // 光源走：左上最亮、两侧几乎没有、右下有一点反射。
        border = Border.all(color: Colors.transparent, width: 0);
        // KernelSU 的主玻璃用 4dp。把用户设置映射到同一档：默认 20 落到 4，
        // 最大也只到 6dp，避免把折射环完全抹平。
        sigma = (requestedBlur * 0.20).clamp(2.0, 6.0).toDouble();
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

    final skinGradient = style.gradient;
    final skinColor = style.fillColor();
    final skinBlur = style.blur;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: style.shadowsOr(shadows),
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: LiquidGlass(
          blurSigma: skinBlur ?? sigma,
          // 折射只给「液态」这一档。毛玻璃档要的就是一块糊掉的板子，
          // 给它加折射等于把两档做成同一个东西。
          refract: effect == ChatComposerEffect.liquid && skinBlur == null,
          // 和外面那个 ClipRRect 用同一个半径，否则折射环会和真正的边缘错开。
          cornerRadius: radius,
          // 原版是 24dp/24dp 配 56dp 高的药丸（约 0.43 个高度）。
          // 这里药丸约 48 高，按同样的比例给 —— 之前 16/12 太保守，
          // 边上那点弯几乎看不出来，整块还是像毛玻璃。
          refractionHeight: 20,
          refractionAmount: 20,
          // KernelSU 的主玻璃层不做色散；色散只在按压指示器里短暂出现。
          // 输入框常驻彩边会显脏，也会让小字号文字边缘显得发虚。
          chromaticAberration: 0,
          saturation: 1.5,
          brightness: 0,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
            decoration: BoxDecoration(
              color: skinGradient != null ? null : (skinColor ?? color),
              gradient: skinGradient ?? (skinColor != null ? null : gradient),
              // 液态档的边缘完全交给 _GlassEdge。这里再补一圈焦点白边，
              // 会和镜面描边叠成肉眼可见的双框。
              border: style.borderOr(
                effect == ChatComposerEffect.liquid
                    ? Border.all(color: Colors.transparent, width: 0)
                    : Border.all(
                        color: focused
                            ? t.brand.withValues(alpha: dark ? 0.72 : 0.62)
                            : border.top.color,
                        width: focused ? 1.2 : border.top.width,
                      ),
              ),
              borderRadius: radius,
            ),
            child: Stack(
              children: <Widget>[
                child,
                if (effect == ChatComposerEffect.liquid &&
                    skinGradient == null &&
                    skinColor == null)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: _GlassEdge(
                          radius: radius,
                          dark: dark,
                          focused: focused,
                          brand: t.brand,
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

/// 玻璃的**边**：一圈真内阴影 + 一圈带角度的镜面描边。
///
/// KernelSU 那套里这是两个独立的效果（`innerShadow` 和 `highlight`），
/// 也正是折射之外最像玻璃的两样东西：
///
///   - **内阴影**给厚度。少了它，药丸是贴在屏幕上的一张纸；有了它，
///     是一块压在壁纸上的料。之前用「顶部往下的线性渐变」凑，
///     只有上边有厚度，转过圆角就露馅。
///   - **镜面描边**给光。一圈均匀的白边是「描过边的方块」；真玻璃的亮边
///     跟着光源走 —— 左上最亮，两侧几乎没有，右下有一点点反射。
///
/// 两样都画在内容**上面**：它们是玻璃表面的性质，不是背景的。
class _GlassEdge extends CustomPainter {
  const _GlassEdge({
    required this.radius,
    required this.dark,
    required this.focused,
    required this.brand,
  });

  final BorderRadius radius;
  final bool dark;
  final bool focused;
  final Color brand;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rrect = radius.toRRect(Offset.zero & size);

    // ---- 内阴影 ----
    // 描一圈很粗的模糊黑边，再裁掉形状外面的部分，留下的就是内阴影。
    // Flutter 没有现成的 inner shadow；`BlurStyle.inner` 画的是「阴影」
    // 而不是「描边的内半边」，在半透明填充上会整块发灰。
    canvas.save();
    canvas.clipRRect(rrect);
    canvas.drawRRect(
      rrect.deflate(3),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..color = Colors.black.withValues(alpha: dark ? 0.22 : 0.10)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    canvas.restore();

    // ---- 镜面描边 ----
    final rim = rrect.deflate(0.6);
    final white = dark ? 0.52 : 0.84;
    canvas.drawRRect(
      rim,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = focused ? 1.4 : 1.1
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            Colors.white.withValues(alpha: white),
            Colors.white.withValues(alpha: white * 0.18),
            Colors.white.withValues(alpha: white * 0.10),
            Colors.white.withValues(alpha: white * 0.34),
          ],
          stops: const <double>[0, 0.32, 0.62, 1],
        ).createShader(Offset.zero & size),
    );

    // 聚焦时沿边压一层品牌色。比整圈换成蓝色克制 ——
    // 玻璃还是玻璃，只是被点亮了一点。
    if (focused) {
      canvas.drawRRect(
        rim,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..color = brand.withValues(alpha: dark ? 0.26 : 0.22),
      );
    }
  }

  @override
  bool shouldRepaint(_GlassEdge old) =>
      old.radius != radius ||
      old.dark != dark ||
      old.focused != focused ||
      old.brand != brand;
}

/// 44px 圆形发送键。生成中变成停止键 ——
/// 换图标不换颜色的话，两个状态在余光里是一样的。
class _SendButton extends StatefulWidget {
  final bool generating;
  final bool enabled;
  final bool hasContent;
  final VoidCallback onSend;
  final VoidCallback onStop;

  const _SendButton({
    required this.generating,
    required this.enabled,
    required this.hasContent,
    required this.onSend,
    required this.onStop,
  });

  @override
  State<_SendButton> createState() => _SendButtonState();
}

class _SendButtonState extends State<_SendButton> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.chat;
    final style = context.parts.composerSend;
    final canSend = widget.generating || (widget.enabled && widget.hasContent);
    final bg = widget.generating
        ? t.tintSecondary
        : canSend
            ? style.fillColor(t.brand)!
            // 禁用态仍保留一个实体轮廓，但不再像可点击的主操作。
            : Color.lerp(t.composerField, t.tintTertiary, 0.16)!;

    final top = Color.lerp(bg, Colors.white, 0.12)!;
    final bottom = Color.lerp(bg, Colors.black, 0.08)!;
    final dimension = style.size ?? 42;
    final corners = style.shape == SkinShape.rounded
        ? style.rounded(BorderRadius.circular(12))
        : BorderRadius.circular(dimension / 2);
    // 皮肤给了纯色就用纯色，不再套那层上下渐变 —— 一个想做扁平发送键的皮肤
    // 写了 background 之后还看到高光渐变，会以为自己的值没生效。
    final flat = style.background?.color != null;

    final action = widget.generating
        ? widget.onStop
        : canSend
            ? widget.onSend
            : null;
    final tooltip = widget.generating
        ? '停止生成'
        : canSend
            ? '发送'
            : '输入内容后发送';

    return Tooltip(
      message: tooltip,
      child: AnimatedScale(
        duration: Duration(milliseconds: _pressed ? 90 : 190),
        scale: !canSend
            ? 0.88
            : _pressed
                ? 0.91
                : 1,
        curve: _pressed ? Curves.easeOutCubic : Curves.easeOutBack,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 190),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            borderRadius: corners,
            color: flat || !canSend ? bg : null,
            gradient: !canSend
                ? null
                : style.gradient ??
                    (flat
                        ? null
                        : LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: <Color>[top, bg, bottom],
                          )),
            border: style.borderOr(Border.all(
              color: Colors.white.withValues(alpha: canSend ? 0.20 : 0.08),
              width: 0.8,
            )),
            boxShadow: style.shadowsOr(<BoxShadow>[
              BoxShadow(
                color: Colors.black.withValues(alpha: canSend ? 0.26 : 0.12),
                blurRadius: canSend ? 8 : 4,
                offset: Offset(0, canSend ? 3 : 2),
              ),
              if (canSend)
                BoxShadow(
                  color: bg.withValues(alpha: 0.24),
                  blurRadius: 12,
                  spreadRadius: -3,
                ),
            ]),
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: corners,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              borderRadius: corners,
              onHighlightChanged: action == null ? null : _setPressed,
              onTap: action,
              child: SizedBox(
                width: dimension,
                height: dimension,
                child: Center(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 160),
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: ScaleTransition(
                        scale: Tween<double>(begin: 0.72, end: 1).animate(
                          CurvedAnimation(
                            parent: animation,
                            curve: Curves.easeOutBack,
                          ),
                        ),
                        child: child,
                      ),
                    ),
                    child: Icon(
                      widget.generating
                          ? Icons.stop_rounded
                          : style.iconOr(Icons.send_rounded),
                      key: ValueKey<String>(widget.generating
                          ? 'stop'
                          : canSend
                              ? 'send-enabled'
                              : 'send-disabled'),
                      size: style.iconSizeOr(21),
                      color: canSend
                          ? style.iconColorOr(Colors.white)
                          : t.tintTertiary.withValues(alpha: 0.72),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 「‹ 2/3 ›」——在同一个分支点的几个版本之间切换。
///
/// 重新生成和编辑重发都不会把旧的那份删掉，而是并排存着；这一小条就是
/// 回到旧版本的入口。没有它的话，旧回复存了也等于没存。
class _VariantSwitcher extends StatelessWidget {
  const _VariantSwitcher({
    required this.index,
    required this.total,
    required this.color,
    required this.onSwitch,
  });

  final int index;
  final int total;
  final Color color;
  final ValueChanged<int> onSwitch;

  @override
  Widget build(BuildContext context) {
    final enabled = color.withValues(alpha: 0.75);
    final disabled = color.withValues(alpha: 0.25);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _Arrow(
          icon: Icons.chevron_left,
          // 到头了就不给点。做成循环的话，用户分不清自己是往回翻了一版
          // 还是绕了一圈回到最新的那版。
          onTap: index > 0 ? () => onSwitch(index - 1) : null,
          enabled: enabled,
          disabled: disabled,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Text(
            '${index + 1}/$total',
            style: TextStyle(
              fontSize: 11,
              height: 1.2,
              color: enabled,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ),
        _Arrow(
          icon: Icons.chevron_right,
          onTap: index < total - 1 ? () => onSwitch(index + 1) : null,
          enabled: enabled,
          disabled: disabled,
        ),
      ],
    );
  }
}

class _Arrow extends StatelessWidget {
  const _Arrow({
    required this.icon,
    required this.onTap,
    required this.enabled,
    required this.disabled,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final Color enabled;
  final Color disabled;

  @override
  Widget build(BuildContext context) {
    return InkResponse(
      onTap: onTap,
      radius: 14,
      child: Padding(
        // 图标只有 16，但手指要的是 40 左右。上下留白同时也把这一条和
        // 气泡拉开一点距离。
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
        child: Icon(icon, size: 16, color: onTap == null ? disabled : enabled),
      ),
    );
  }
}
