/// 必留操作入口。
///
/// 「支持自定义样式，但不支持不显示」这条约束就落在这个文件里。
///
/// ## 为什么不能靠校验
///
/// 直觉做法是在导入时检查 manifest 有没有把抽屉按钮写成 `visible: false`。
/// 那是拦不住的 —— 让一个按钮事实上消失至少有六条路：
///
///   1. `opacity: 0`
///   2. 尺寸或 padding 归零
///   3. `transform` 把它推出屏幕
///   4. `visible: false`
///   5. 颜色写成和背景一样
///   6. 用别的图层盖住它
///
/// 前五条在 [PartStyle.clampAsRequired] 和这里逐条钳死。**第六条靠结构**：
/// 必留入口由骨架自己 compose 在 `AppBar.leading` 上，而 AppBar 在 Scaffold 的
/// 绘制顺序里永远在 body 之上；皮肤能控制的图层（壁纸、气泡、输入区）全都在
/// body 里，拿不到能盖住它的那一层。就算 `layout.header` 设成 transparent，
/// 变的也只是 AppBar 自己的底色，层序不变。
///
/// ## 逃生舱
///
/// 钳制不需要做到滴水不漏，因为还有三条与皮肤完全无关的退路：
///
///   1. **从屏幕边缘右滑**唤出抽屉 —— Flutter 的 Drawer 自带，皮肤碰不到。
///   2. **长按这个按钮**弹出用内置样式渲染的菜单，里面有"临时停用皮肤"。
///   3. **外观页永远用内置主题渲染**，见 ChatAppearancePage。
///
/// 这三条一上，软砖在结构上就不可能发生。
library;

import 'package:flutter/material.dart';

import 'skin_style.dart';

class SkinAffordance extends StatelessWidget {
  const SkinAffordance({
    super.key,
    required this.style,
    required this.icon,
    required this.foreground,
    required this.behind,
    required this.onTap,
    required this.onLongPress,
    this.tooltip,
  });

  /// 皮肤给的样式。已经过 [PartStyle.clampAsRequired]，这里再兜一次底 ——
  /// 钳制的入口有两个（解析时、渲染时），少一个都可能被将来的调用方绕过。
  final PartStyle style;

  /// 骨架给的默认图标。皮肤可以换，不能去掉。
  final IconData icon;

  /// 骨架给的默认前景色。
  final Color foreground;

  /// 这个按钮实际压在什么颜色上。用来判断皮肤给的图标色会不会隐形。
  final Color behind;

  final VoidCallback onTap;

  /// 逃生舱。**不是可选的** —— 做成必填参数是为了让"忘了接安全菜单"
  /// 变成一个编译错误，而不是一个只有在皮肤坏掉时才会发现的疏漏。
  final VoidCallback onLongPress;

  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final size = (style.size ?? PartStyle.minTapTarget)
        .clamp(PartStyle.minTapTarget, 96.0)
        .toDouble();

    final fill = style.fillColor();
    final gradient = style.gradient;

    // 图标色：皮肤给的先和"它压在什么上"比一次对比度。压不住就丢掉皮肤那个值
    // 回落骨架色 —— 只丢这一个属性，皮肤给的形状、底色、圆角都还在。
    var iconColor = style.icon?.color;
    if (iconColor != null) {
      final under = fill ?? gradient?.colors.first ?? behind;
      if (skinContrast(iconColor, under) < _minIconContrast) {
        iconColor = null;
      }
    }

    final shape = style.shape ?? SkinShape.circle;
    final radius = switch (shape) {
      SkinShape.circle => BorderRadius.circular(size / 2),
      SkinShape.stadium => BorderRadius.circular(size / 2),
      SkinShape.rounded => style.rounded(BorderRadius.circular(10)),
    };

    final Widget button = SizedBox.square(
      dimension: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: gradient == null ? fill : null,
          gradient: gradient,
          border: style.borderOr(null),
          borderRadius: radius,
          boxShadow: style.shadowsOr(null),
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: radius,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            borderRadius: radius,
            onTap: onTap,
            onLongPress: onLongPress,
            child: Center(
              child: Icon(
                style.iconOr(icon),
                size: style.iconSizeOr(24).clamp(14.0, size * 0.8),
                color: iconColor ?? foreground,
              ),
            ),
          ),
        ),
      ),
    );

    // decorate 会套上不透明度和变换，两者都已经被钳到"仍然看得见、
    // 仍然在原位附近"的范围内。
    final decorated = style.decorate(button);
    return tooltip == null
        ? decorated
        : Tooltip(message: tooltip!, child: decorated);
  }

  /// 图标和它底下那层的最低对比度。比包级闸门（1.6）严一点：一个看不见的
  /// 按钮比一段看不清的文字后果重得多。
  static const _minIconContrast = 2.0;
}
