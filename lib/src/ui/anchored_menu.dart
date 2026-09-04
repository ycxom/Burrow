/// 贴着按钮弹出来的浮层菜单。
///
/// ## 为什么不用 bottom sheet
///
/// 两个入口（输入框的 `+`、顶栏的终端图标）分别在屏幕的左下角和右上角，而
/// bottom sheet 一律从底部整幅推上来。结果是**点右上角的图标，动的是屏幕
/// 最下面那一条** —— 用户的手指和视线在两个地方，每次都要重新找一遍
/// "我刚才点的是什么"。
///
/// 浮层从按钮所在的那个角展开，那条因果链就是自明的：点哪儿，哪儿长出来。
///
/// ## 尺寸取向
///
/// 每一项是「一个圆形图标 + 一行字」，行高约 48 —— **聊天软件里那种菜单的
/// 尺寸**。一开始照参考图做到了 68，装到机器上才发现问题：那种尺寸是给
/// 「一屏就三五项、每项都是一次大动作」的菜单用的，而这里的长按菜单有五项，
/// 撑起来快占半屏，弹出来的一瞬间像是换了个页面而不是弹了个菜单。
///
/// 菜单该显得**轻**。它是压在对话上面的一层临时东西，不是一个去处。
library;

import 'package:flutter/material.dart';

import '../settings/settings_store.dart';
import 'chat_theme.dart';
import 'glass_surface.dart';

/// 弹层用什么材质 —— 和输入框同一套（实心 / 毛玻璃 / 液态 / 描边）。
///
/// 放在 InheritedWidget 里而不是每个弹层各传三个参数：每加一个弹层就多三个
/// 参数要传，迟早有一个忘了传，而那一个会长得和别的都不一样 —— 用户调了
/// 输入框的质感，只有它没跟着变。
///
/// **必须在 [showAnchoredMenu] 里当场读**，不能等到弹层自己 build：弹层是
/// 一条 dialog route，挂在 Navigator 上，而这份配置在聊天页里 —— 那时候
/// 已经够不着了。
class MenuMaterial extends InheritedWidget {
  const MenuMaterial({
    required this.effect,
    required this.blur,
    required this.opacity,
    required super.child,
    super.key,
  });

  final ChatComposerEffect effect;
  final double blur;
  final double opacity;

  static MenuMaterial? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MenuMaterial>();

  @override
  bool updateShouldNotify(MenuMaterial old) =>
      old.effect != effect || old.blur != blur || old.opacity != opacity;
}

/// 菜单里的一项。
class MenuAction extends StatelessWidget {
  const MenuAction({
    required this.icon,
    required this.label,
    this.detail,
    this.trailing,
    this.onTap,
    this.tone,
    super.key,
  });

  final IconData icon;
  final String label;

  /// label 下面那行小字：**这一项现在是什么状态**。
  ///
  /// 参考的那个菜单没有这一行，但它那几项（相机、相册、文件）都没有状态可言。
  /// 这里的「对话模型」「思考强度」「审批档位」有 —— 而设置项的当前值应该在
  /// 列表里就看得见，点进去才知道等于没说。
  final String? detail;

  /// 右边那个东西（开关、箭头）。
  final Widget? trailing;

  final VoidCallback? onTap;

  /// 需要点名的颜色（关掉沙箱那种）。null = 常态。
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final t = context.chat;
    final enabled = onTap != null;
    final fg = tone ?? t.tintPrimary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Row(
          children: <Widget>[
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: t.bgTertiary,
                shape: BoxShape.circle,
              ),
              child: Icon(
                icon,
                size: 18,
                color: enabled ? fg : fg.withValues(alpha: 0.4),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 14.5,
                      color: enabled ? fg : fg.withValues(alpha: 0.4),
                    ),
                  ),
                  if (detail case final text? when text.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        text,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          height: 1.25,
                          color: tone ?? t.tintTertiary,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (trailing case final widget?) ...<Widget>[
              const SizedBox(width: 8),
              widget,
            ],
          ],
        ),
      ),
    );
  }
}

/// 菜单顶上那条提示。有东西配坏了的时候才出现。
class MenuNotice extends StatelessWidget {
  const MenuNotice({required this.text, super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final t = context.chat;
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 2, 10, 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: t.tintWarning.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.error_outline, size: 14, color: t.tintWarning),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 11, color: t.tintWarning),
            ),
          ),
        ],
      ),
    );
  }
}

/// 从 [anchor] 那个按钮的位置展开一张浮层菜单。
///
/// [builder] 每次重建都会被调用，所以菜单里的开关能当场看到自己变化 ——
/// 不用调用方自己套一层 StatefulBuilder。
Future<T?> showAnchoredMenu<T>({
  required BuildContext context,
  required List<Widget> Function(BuildContext context, VoidCallback refresh)
      builder,

  /// 触发它的那个按钮。和 [at] 二选一。
  GlobalKey? anchor,

  /// 触发它的那一下**触点**（全局坐标）。长按消息用这个 —— 那里没有按钮，
  /// 只有手指落下的位置。
  Offset? at,
  double maxWidth = 264,
}) {
  final box = anchor?.currentContext?.findRenderObject() as RenderBox?;
  final overlay =
      Navigator.of(context).overlay!.context.findRenderObject() as RenderBox;
  final screen = overlay.size;

  // 认不出锚点位置时落到屏幕正中。菜单弹不出来比位置不完美糟得多。
  final Rect anchorRect = box != null
      ? (box.localToGlobal(Offset.zero, ancestor: overlay) & box.size)
      : (at ?? Offset(screen.width / 2, screen.height / 2)) & Size.zero;

  // 在这里读，不是在弹层里 —— 见 [MenuMaterial]。
  final material = MenuMaterial.maybeOf(context);

  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    // 压得很淡：菜单是贴着按钮长出来的，背后那一屏仍然是上下文的一部分，
    // 盖死了反而看不出自己刚才点的是哪儿。
    barrierColor: Colors.black.withValues(alpha: 0.32),
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (dialogContext, _, __) => _AnchoredMenu(
      anchorRect: anchorRect,
      screen: screen,
      maxWidth: maxWidth,
      material: material,
      builder: builder,
    ),
    transitionBuilder: (dialogContext, animation, _, child) {
      final curved =
          CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.92, end: 1).animate(curved),
          // 从按钮所在的那个角长出来，而不是从菜单自己的中心 ——
          // 「点哪儿、哪儿长出来」这条因果链全靠这个 alignment。
          alignment: _originOf(anchorRect, screen),
          child: child,
        ),
      );
    },
  );
}

/// 缩放的原点：按钮在屏幕的哪个角，就从哪个角长。
Alignment _originOf(Rect anchor, Size screen) {
  final x = (anchor.center.dx / screen.width) * 2 - 1;
  final y = (anchor.center.dy / screen.height) * 2 - 1;
  return Alignment(x.clamp(-1.0, 1.0), y.clamp(-1.0, 1.0));
}

class _AnchoredMenu extends StatefulWidget {
  const _AnchoredMenu({
    required this.anchorRect,
    required this.screen,
    required this.maxWidth,
    required this.material,
    required this.builder,
  });

  final Rect anchorRect;
  final Size screen;
  final double maxWidth;

  /// 没配就退回一块实心卡片。菜单弹不出来比不好看糟得多。
  final MenuMaterial? material;
  final List<Widget> Function(BuildContext context, VoidCallback refresh)
      builder;

  @override
  State<_AnchoredMenu> createState() => _AnchoredMenuState();
}

class _AnchoredMenuState extends State<_AnchoredMenu> {
  static final _radius = BorderRadius.circular(18);

  void _refresh() {
    if (mounted) setState(() {});
  }

  /// 套上「输入框那种质感」。没配就退回一块实心卡片 —— 这一层是装饰，
  /// 缺了它菜单照样能用，而为了装饰让菜单弹不出来是本末倒置。
  Widget _surface(ChatTokens t, Widget child) {
    final material = widget.material;
    if (material == null) {
      return Material(
        color: t.bgSecondary,
        elevation: 8,
        shadowColor: Colors.black.withValues(alpha: 0.5),
        borderRadius: _radius,
        clipBehavior: Clip.antiAlias,
        child: child,
      );
    }
    return GlassSurface(
      effect: material.effect,
      blur: material.blur,
      opacity: material.opacity,
      cornerRadius: _radius,
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.chat;
    final padding = MediaQuery.paddingOf(context);
    const margin = 10.0;

    final width =
        widget.maxWidth.clamp(0.0, widget.screen.width - margin * 2).toDouble();

    // 按钮在上半屏就往下长，在下半屏就往上长。反过来的话菜单会盖住
    // 按钮自己，而用户正盯着那个按钮看。
    final below = widget.anchorRect.center.dy < widget.screen.height / 2;

    // 左右贴着按钮那一侧对齐，再夹回屏幕里。
    var left = widget.anchorRect.center.dx < widget.screen.width / 2
        ? widget.anchorRect.left - margin
        : widget.anchorRect.right + margin - width;
    left = left.clamp(margin, widget.screen.width - width - margin);

    return Stack(
      children: <Widget>[
        Positioned(
          left: left,
          top: below ? widget.anchorRect.bottom + 8 : null,
          bottom: below
              ? null
              : widget.screen.height - widget.anchorRect.top + 8,
          width: width,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: (below
                      ? widget.screen.height -
                          widget.anchorRect.bottom -
                          padding.bottom
                      : widget.anchorRect.top - padding.top) -
                  24,
            ),
            child: _surface(
              t,
              // Material 只为了 InkWell 的水波纹和文字默认样式，底色交给
              // 外面那层玻璃 —— 给它上色的话，玻璃后面就什么都透不过来了。
              Material(
                type: MaterialType.transparency,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: widget.builder(context, _refresh),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
