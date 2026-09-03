/// 液态玻璃：边缘折射 + vibrancy，套在 BackdropFilter 上。
///
/// ## 为什么不是「再糊一点」
///
/// 之前的「液态」档只是 blur + 一层斜向渐变 + 一条白高光。糊得再狠也还是一块
/// 半透明面板 —— 真玻璃让人认出来的不是模糊，是**边缘那圈把背景拉弯的折射**。
///
/// 参照 KernelSU 悬浮底栏那套（它取自 Kyant0/AndroidLiquidGlass，经 miuix
/// 转了一道）：vibrancy → blur → lens 折射 → 内阴影 + 边缘高光。
///
/// ## 模糊必须是**真**高斯
///
/// 一开始想省一个 saveLayer，把模糊也塞进着色器里用一个 9 点方框做掉。
/// 那是错的：默认模糊 20dp、DPR 3，采样半径就是 60 个纹理像素 ——
/// **9 个点摊在 120 像素上不是模糊，是重影**，药丸里的背景字会糊成一层
/// 带鬼影的塑料膜。
///
/// 现在把 Impeller 自己的高斯作为 inner filter，折射 shader 作为 outer filter，
/// 合成进**同一次** backdrop 采样：lens(blur(backdrop))。不能叠两个重叠的
/// grouped filter —— 文档明确说它们共用 key 时结果可能只剩其中一个。
///
/// 着色器里仍留了一点采样柔化，但**只在折射带里、跟着衰减走**：
/// 折射把边缘那一圈压缩了，minification 会当场锯齿化，柔化一点就没了。
///
/// ## 为什么要自己量一遍尺寸
///
/// `ImageFilter.shader` 塞给着色器的是**整块背景纹理**（基本就是全屏），
/// 不是这个控件自己那一小块。着色器要算圆角矩形的 SDF，就必须知道药丸在
/// 那张大图里的位置 —— 拿不到就会把整个屏幕当成那个圆角矩形，位移量从
/// 十几像素变成近千像素，采样满屏乱飞，最后是一块彩色噪点（实测踩过）。
///
/// 所以这里挂一个 GlobalKey 量出全局矩形传进去。晚一帧也没关系：
/// 首帧量不到时着色器只糊不折射，看着就是普通毛玻璃。
///
/// ## 降级
///
/// `ImageFilter.shader` 只在 Impeller 上有；着色器还要异步编译。这两件事
/// **都可能不成立**，所以这里永远先画得出一个「只有模糊」的版本，
/// 着色器好了再无缝换上。看不到玻璃总比看到一个空白的输入框强。
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 着色器程序。全 App 一份，启动时预热。
class LiquidGlassProgram {
  LiquidGlassProgram._();

  static ui.FragmentProgram? _program;
  static bool _loading = false;

  /// 编好了没有。UI 监听它，好在编译完成的那一帧换上折射版本。
  static final ValueNotifier<bool> ready = ValueNotifier<bool>(false);

  static ui.FragmentProgram? get program => _program;

  /// 这台设备支不支持。GLES/软件渲染下 `ImageFilter.shader` 直接抛异常，
  /// 所以要先问一句而不是 try/catch —— 每帧抛一次异常的代价可不小。
  static bool get supported => ui.ImageFilter.isShaderFilterSupported;

  /// 预热。在 `main()` 里 fire-and-forget 地调一次即可。
  ///
  /// 失败不抛：着色器编不出来是「效果差一点」，不该让 App 起不来。
  static Future<void> warmUp() async {
    if (_program != null || _loading || !supported) return;
    _loading = true;
    try {
      _program =
          await ui.FragmentProgram.fromAsset('shaders/liquid_glass.frag');
      ready.value = true;
    } catch (e) {
      debugPrint('液态玻璃着色器没编出来，降级成普通模糊：$e');
    } finally {
      _loading = false;
    }
  }
}

/// 一块液态玻璃。[child] 画在玻璃上面，玻璃后面的东西被模糊 + 折射。
///
/// **自己不裁剪**：调用方已经有一个 ClipRRect（还要往上叠边框和阴影），
/// 在这里再裁一次等于多一个 saveLayer。
class LiquidGlass extends StatefulWidget {
  const LiquidGlass({
    super.key,
    required this.child,
    this.blurSigma = 8,
    this.edgeSoftness = 2,
    this.cornerRadius = const BorderRadius.all(Radius.circular(24)),
    this.refractionHeight = 16,
    this.refractionAmount = 12,
    this.chromaticAberration = 0,
    this.saturation = 1.4,
    this.brightness = 0,
    this.refract = true,
  });

  final Widget child;

  /// 折射之前先糊多少（逻辑像素）。走的是外面那层真高斯。
  /// 大了会盖过折射、变回一块毛玻璃；小了背景的字太清楚，不像隔着东西看。
  final double blurSigma;

  /// 折射带里的采样柔化半径（逻辑像素）。治的是边缘压缩处的锯齿，
  /// 不是用来当模糊使的 —— 它只在贴边处生效，往里迅速归零。
  final double edgeSoftness;

  /// 药丸的圆角，逻辑像素。要和外面那个 ClipRRect 用同一个值，否则折射环
  /// 会和真正的边缘错开。保留四个角而不是压成单一半径，皮肤的形状才不会
  /// 只改了轮廓、没改到折射。
  final BorderRadiusGeometry cornerRadius;

  /// 折射带有多宽（逻辑像素）。越大，被拉弯的范围越往里。
  final double refractionHeight;

  /// 折射有多强（逻辑像素）。
  final double refractionAmount;

  /// 色散（逻辑像素）。给一点点边缘就有极淡的彩虹口；0 = 关掉，省两次采样。
  /// 默认关闭，和 KernelSU 的主玻璃层一致；只适合在短暂按压态里少量开启。
  final double chromaticAberration;

  /// vibrancy 的饱和度。1 = 不动。
  final double saturation;

  /// 亮度补偿，0~1。深色底上给一点点，玻璃才不像一块脏布。
  final double brightness;

  /// 要不要折射。false = 只模糊，退回普通毛玻璃。
  ///
  /// 毛玻璃那一档要的就是一块糊掉的板子；给它也加上折射，两档就成了
  /// 同一个东西，用户在设置里切来切去看不出区别。
  final bool refract;

  @override
  State<LiquidGlass> createState() => _LiquidGlassState();
}

class _LiquidGlassState extends State<LiquidGlass> {
  final GlobalKey _boxKey = GlobalKey();
  ui.FragmentShader? _shader;

  /// 药丸在屏幕上的位置，逻辑像素。null = 还没量到。
  Rect? _rect;

  @override
  void initState() {
    super.initState();
    LiquidGlassProgram.ready.addListener(_onReady);
    _bind();
    _scheduleMeasure();
  }

  @override
  void didUpdateWidget(LiquidGlass old) {
    super.didUpdateWidget(old);
    _scheduleMeasure();
  }

  @override
  void dispose() {
    LiquidGlassProgram.ready.removeListener(_onReady);
    _shader?.dispose();
    super.dispose();
  }

  void _onReady() {
    if (!mounted) return;
    setState(_bind);
  }

  /// 着色器实例复用一个。每帧新建一个的话，输入框每敲一下就会多分配一次
  /// GPU 资源 —— uniform 是可以覆盖写的，没必要重建。
  void _bind() {
    if (_shader != null) return;
    final program = LiquidGlassProgram.program;
    if (program != null) _shader = program.fragmentShader();
  }

  /// 布局之后量一次全局矩形。
  ///
  /// **只在真的变了的时候 setState**，否则每帧量一次、每次都 setState，
  /// 就是一个永不停歇的重建循环。半像素以内当没变 —— 键盘弹出的动画里
  /// 位置每帧都在动，追到小数位没有意义。
  void _scheduleMeasure() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final box = _boxKey.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.hasSize) return;
      final rect = box.localToGlobal(Offset.zero) & box.size;
      final old = _rect;
      if (old != null &&
          (old.left - rect.left).abs() < 0.5 &&
          (old.top - rect.top).abs() < 0.5 &&
          (old.width - rect.width).abs() < 0.5 &&
          (old.height - rect.height).abs() < 0.5) {
        return;
      }
      setState(() => _rect = rect);
    });
  }

  @override
  Widget build(BuildContext context) {
    // 位置每帧都可能变（键盘、滚动），所以每帧都排一次测量。
    _scheduleMeasure();

    // 两样都不要就别插 BackdropFilter：它自带一次 saveLayer，
    // 而 sigma 为 0 的模糊照样要付这笔钱。
    if (widget.blurSigma <= 0 && !widget.refract) {
      return KeyedSubtree(key: _boxKey, child: widget.child);
    }

    final shader = _shader;
    final rect = _rect;
    ui.ImageFilter filter = const ui.ColorFilter.mode(
      Color(0x00000000),
      BlendMode.dst,
    );
    var refracting = false;

    if (widget.refract && shader != null && LiquidGlassProgram.supported) {
      final screen = MediaQuery.sizeOf(context);
      final corners = widget.cornerRadius.resolve(Directionality.of(context));
      // 前两个 float 是 uSize，引擎会覆盖它们；填 0 只是占位。
      shader
        ..setFloat(0, 0)
        ..setFloat(1, 0)
        ..setFloat(2, rect?.left ?? 0)
        ..setFloat(3, rect?.top ?? 0)
        ..setFloat(4, rect?.width ?? 0)
        ..setFloat(5, rect?.height ?? 0)
        ..setFloat(6, screen.width)
        ..setFloat(7, screen.height)
        ..setFloat(8, corners.topLeft.x)
        ..setFloat(9, corners.topRight.x)
        ..setFloat(10, corners.bottomRight.x)
        ..setFloat(11, corners.bottomLeft.x)
        ..setFloat(12, widget.refractionHeight)
        ..setFloat(13, widget.refractionAmount)
        ..setFloat(14, widget.chromaticAberration)
        ..setFloat(15, 0)
        ..setFloat(16, widget.saturation)
        ..setFloat(17, widget.brightness)
        ..setFloat(18, widget.edgeSoftness);
      filter = ui.ImageFilter.shader(shader);
      refracting = true;
    }

    if (refracting && widget.blurSigma > 0) {
      filter = ui.ImageFilter.compose(
        outer: filter,
        inner: ui.ImageFilter.blur(
          sigmaX: widget.blurSigma,
          sigmaY: widget.blurSigma,
          tileMode: TileMode.decal,
        ),
      );
    }

    Widget result = KeyedSubtree(key: _boxKey, child: widget.child);
    // 一个 compose filter 就是 KernelSU 的 effects 顺序：blur 先把高频细节
    // 压下去，lens 再对这份已经干净的输入做边缘折射。叠两个重叠的
    // BackdropFilter.grouped 反而共用同一个 backdrop key，可能只剩一个效果。
    if (refracting || widget.blurSigma > 0) {
      result = BackdropFilter.grouped(
        filter: refracting
            ? filter
            : ui.ImageFilter.blur(
                sigmaX: widget.blurSigma,
                sigmaY: widget.blurSigma,
                tileMode: TileMode.decal,
              ),
        child: result,
      );
    }

    // 两层共用一次背景快照。少了它，叠加的 BackdropFilter 会各自快照一遍。
    return BackdropGroup(child: result);
  }
}
