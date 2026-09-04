/// 「输入框那种质感」的那一层，以及它的边。
///
/// 单独一个文件是因为**两边都要用**：输入框自己，和贴着按钮弹出来的浮层菜单
/// （见 anchored_menu.dart）。放在 chat_view.dart 里的话，菜单要 import 它、
/// 它又要 import 菜单，绕成一个环 —— Dart 允许，但那说明这块东西压根不属于
/// 其中任何一边。
library;

import 'package:flutter/material.dart';

import '../settings/settings_store.dart';
import 'chat_theme.dart';
import 'liquid_glass.dart';
import 'skin_style.dart';

/// 「输入框那种质感」的那一层。模糊只裁在形状内部，阴影留在裁剪外；否则
/// 玻璃会把整块底栏都糊掉，看起来像半透明面板而不是悬浮在壁纸上的一滴液体。
///
/// 输入框自己在用，弹层菜单也在用（见 anchored_menu.dart）—— 同一套四档材质
/// （实心 / 毛玻璃 / 液态 / 描边）在整个聊天界面里只该有**一份实现**。抄一份
/// 到菜单里的话，用户调了输入框的模糊度，菜单不跟着变；而那两样东西在屏幕上
/// 只隔着几十像素，不一致一眼就看得出来。
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    required this.effect,
    required this.blur,
    required this.opacity,
    required this.child,
    this.style = PartStyle.empty,
    this.focused = false,
    this.cornerRadius,
    super.key,
  });

  final ChatComposerEffect effect;
  final double blur;
  final double opacity;

  /// 已经按焦点状态解析过的 `composer.field` 样式。由 ChatComposer 传进来而不是
  /// 在这里查 context.parts —— 焦点只有它知道。菜单没有对应的皮肤部件，
  /// 给一份空的。
  final PartStyle style;
  final Widget child;

  /// 输入框聚焦时那圈亮边。菜单永远是 false。
  final bool focused;

  /// 圆角。null = 用输入药丸那个值。菜单要的比药丸大得多。
  final BorderRadius? cornerRadius;

  @override
  Widget build(BuildContext context) {
    final t = context.chat;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final alpha = opacity.clamp(0.25, 1.0).toDouble();
    final requestedBlur = blur.clamp(0.0, 30.0).toDouble();
    final radius = style.rounded(
        cornerRadius ?? BorderRadius.circular(ChatShape.composerRadius + 2));

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
