/// 一个「部件」的样式。皮肤包能改的东西全部在这里，这是白名单不是黑名单。
///
/// 对应 CSS 里的一条规则块：皮肤包按部件名给出一组属性，渲染层拿着它去覆盖
/// 内置外观。没给的属性保持 null，渲染层回落到自己的默认值 —— 所以皮肤包
/// 永远是**稀疏**的，一个只想改气泡圆角的皮肤包就真的只写一行。
///
/// ## 为什么属性是有界的
///
/// 这里没有「任意 CSS 属性」这种东西。每加一个属性都要在渲染层接一次，
/// 这个成本是特意保留的：它保证了皮肤包永远不可能表达出一个渲染层没预料到
/// 的状态。代价是皮肤作者不能为所欲为，收益是一个坏皮肤包最多不好看，
/// 不会让界面失效。
///
/// ## 状态
///
/// [SkinState] 是 CSS 伪类的对应物。状态样式在**加载时**就被合成为一个完整的
/// [PartStyle]（而不是差量），所以渲染层取状态样式是一次数组下标：
///
/// ```dart
/// final style = base.on(SkinState.first) ?? base;
/// ```
///
/// 这条很重要 —— 一屏消息会取几百次样式，任何 map 查找 + 字符串哈希都会
/// 在滚动时显形。部件名和状态名只存在于文件格式里，不存在于渲染路径上。
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import 'skin_vars.dart';

/// 部件的状态修饰符。对应皮肤包里的 `bubble.out:first` 这种写法。
enum SkinState {
  /// 一组连续消息里的第一条。
  first,

  /// 一组连续消息里的最后一条（带尾巴那条）。
  last,

  /// 输入框获得焦点。
  focused,

  /// 列表已经滚动离开顶部。
  scrolled,

  /// 正在流式输出。
  generating,
}

const _stateNames = <String, SkinState>{
  'first': SkinState.first,
  'last': SkinState.last,
  'focused': SkinState.focused,
  'scrolled': SkinState.scrolled,
  'generating': SkinState.generating,
};

SkinState? skinStateFromName(String name) => _stateNames[name];

/// 皮肤包可以指定的图标。
///
/// 白名单而不是「任意图标码点」：`IconData(0xe123)` 这种写法既没法 tree-shake
/// （构建时会警告并保留整个字体），又会因为 Material 图标码点在版本间变动而
/// 在某次升级后悄悄变成另一个图标。
const skinIcons = <String, IconData>{
  'menu': Icons.menu_rounded,
  'menu_open': Icons.menu_open_rounded,
  'dehaze': Icons.dehaze_rounded,
  'list': Icons.list_rounded,
  'apps': Icons.apps_rounded,
  'grid': Icons.grid_view_rounded,
  'chat': Icons.chat_bubble_outline_rounded,
  'forum': Icons.forum_outlined,
  'send': Icons.send_rounded,
  'arrow_up': Icons.arrow_upward_rounded,
  'stop': Icons.stop_rounded,
  'pause': Icons.pause_rounded,
  'add': Icons.add_rounded,
  'plus_circle': Icons.add_circle_outline_rounded,
  'attach': Icons.attach_file_rounded,
  'image': Icons.image_outlined,
  'camera': Icons.photo_camera_outlined,
  'mic': Icons.mic_none_rounded,
  'terminal': Icons.terminal_rounded,
  'code': Icons.code_rounded,
  'history': Icons.history_rounded,
  'settings': Icons.settings_outlined,
  'tune': Icons.tune_rounded,
  'psychology': Icons.psychology_outlined,
  'sparkle': Icons.auto_awesome_rounded,
  'bolt': Icons.bolt_rounded,
  'star': Icons.star_rounded,
  'heart': Icons.favorite_border_rounded,
  'person': Icons.person_rounded,
  'robot': Icons.smart_toy_outlined,
  'pets': Icons.pets_rounded,
  'more_vert': Icons.more_vert_rounded,
  'more_horiz': Icons.more_horiz_rounded,
  'close': Icons.close_rounded,
  'check': Icons.check_rounded,
  'search': Icons.search_rounded,
};

/// 圆角。可以整体给一个数，也可以分四角。
@immutable
class SkinCorners {
  const SkinCorners({this.tl, this.tr, this.br, this.bl});

  final double? tl;
  final double? tr;
  final double? br;
  final double? bl;

  bool get isEmpty => tl == null && tr == null && br == null && bl == null;

  SkinCorners merge(SkinCorners? other) => other == null
      ? this
      : SkinCorners(
          tl: other.tl ?? tl,
          tr: other.tr ?? tr,
          br: other.br ?? br,
          bl: other.bl ?? bl,
        );

  BorderRadius resolve(BorderRadius fallback) => BorderRadius.only(
        topLeft: Radius.circular(tl ?? fallback.topLeft.x),
        topRight: Radius.circular(tr ?? fallback.topRight.x),
        bottomRight: Radius.circular(br ?? fallback.bottomRight.x),
        bottomLeft: Radius.circular(bl ?? fallback.bottomLeft.x),
      );

  /// 四角里最大的那个。给只接受单一半径的地方（比如气泡形状）用。
  double? get maxRadius {
    final values = <double>[
      if (tl != null) tl!,
      if (tr != null) tr!,
      if (br != null) br!,
      if (bl != null) bl!,
    ];
    if (values.isEmpty) return null;
    return values.reduce((a, b) => a > b ? a : b);
  }

  static SkinCorners? parse(Object? raw, SkinVars vars) {
    if (raw == null) return null;
    if (raw is num || raw is String) {
      final all = vars.number(raw);
      return all == null
          ? null
          : SkinCorners(tl: all, tr: all, br: all, bl: all);
    }
    if (raw is! Map) return null;
    final all = vars.number(raw['all']);
    double? pick(String key) => vars.number(raw[key]) ?? all;
    return SkinCorners(
      tl: pick('tl'),
      tr: pick('tr'),
      br: pick('br'),
      bl: pick('bl'),
    );
  }
}

/// 内外边距。接受一个数、`[水平, 垂直]`，或四边分别给。
@immutable
class SkinEdge {
  const SkinEdge({this.l, this.t, this.r, this.b});

  final double? l;
  final double? t;
  final double? r;
  final double? b;

  SkinEdge merge(SkinEdge? other) => other == null
      ? this
      : SkinEdge(
          l: other.l ?? l,
          t: other.t ?? t,
          r: other.r ?? r,
          b: other.b ?? b,
        );

  EdgeInsets resolve(EdgeInsets fallback) => EdgeInsets.only(
        left: l ?? fallback.left,
        top: t ?? fallback.top,
        right: r ?? fallback.right,
        bottom: b ?? fallback.bottom,
      );

  static SkinEdge? parse(Object? raw, SkinVars vars) {
    if (raw == null) return null;
    if (raw is num || raw is String) {
      final all = vars.number(raw);
      return all == null ? null : SkinEdge(l: all, t: all, r: all, b: all);
    }
    if (raw is List && raw.length == 2) {
      final h = vars.number(raw[0]);
      final v = vars.number(raw[1]);
      return SkinEdge(l: h, r: h, t: v, b: v);
    }
    if (raw is! Map) return null;
    final h = vars.number(raw['h']);
    final v = vars.number(raw['v']);
    return SkinEdge(
      l: vars.number(raw['l']) ?? h,
      t: vars.number(raw['t']) ?? v,
      r: vars.number(raw['r']) ?? h,
      b: vars.number(raw['b']) ?? v,
    );
  }
}

/// 填充：纯色、渐变或图片。三者可以叠 —— 图片画在渐变上面。
@immutable
class SkinFill {
  const SkinFill({
    this.color,
    this.gradient,
    this.angle = 135,
    this.image,
    this.fit = BoxFit.cover,
    this.imageOpacity = 1,
    this.blur,
  });

  final Color? color;
  final List<Color>? gradient;

  /// 渐变角度，度。0 = 从上到下，90 = 从左到右。
  final double angle;

  /// 皮肤包自带图片的**绝对路径**（加载时由资源根解析好）。
  final String? image;
  final BoxFit fit;
  final double imageOpacity;

  /// 背景模糊（BackdropFilter 的 sigma）。糊的是这一层**背后**的内容。
  final double? blur;

  bool get isEmpty =>
      color == null && gradient == null && image == null && blur == null;

  SkinFill merge(SkinFill? other) => other == null
      ? this
      : SkinFill(
          color: other.color ?? color,
          gradient: other.gradient ?? gradient,
          angle: other.gradient != null ? other.angle : angle,
          image: other.image ?? image,
          fit: other.image != null ? other.fit : fit,
          imageOpacity: other.image != null ? other.imageOpacity : imageOpacity,
          blur: other.blur ?? blur,
        );

  /// 渐变角度换算成起止对齐点。用单位圆而不是 `Alignment.topLeft` 这类常量：
  /// 后者只能表达 8 个方向，而作者写 `"angle": 20` 时期望的是 20 度。
  Gradient? resolveGradient() {
    final colors = gradient;
    if (colors == null || colors.length < 2) return null;
    final radians = (angle - 90) * math.pi / 180;
    final dx = math.cos(radians);
    final dy = math.sin(radians);
    return LinearGradient(
      begin: Alignment(-dx, -dy),
      end: Alignment(dx, dy),
      colors: colors,
    );
  }

  static SkinFill? parse(Object? raw, SkinVars vars, String? assetRoot) {
    if (raw == null) return null;
    // 简写：`"background": "#112233"`
    if (raw is String) {
      final color = vars.color(raw);
      return color == null ? null : SkinFill(color: color);
    }
    if (raw is List) {
      final colors = _colorList(raw, vars);
      return colors == null ? null : SkinFill(gradient: colors);
    }
    if (raw is! Map) return null;

    final gradientRaw = raw['gradient'];
    return SkinFill(
      color: vars.color(raw['color']),
      gradient: gradientRaw is List ? _colorList(gradientRaw, vars) : null,
      angle: vars.number(raw['angle']) ?? 135,
      image: _asset(raw['image'], assetRoot),
      fit: _fits[raw['fit']] ?? BoxFit.cover,
      imageOpacity:
          (vars.number(raw['imageOpacity']) ?? 1).clamp(0.0, 1.0).toDouble(),
      // 模糊是最贵的一层，硬性封顶 40 —— 再高在移动端只会掉帧，
      // 视觉上和 40 已经分不出来。
      blur: vars.number(raw['blur'])?.clamp(0.0, 40.0).toDouble(),
    );
  }

  static List<Color>? _colorList(List<Object?> raw, SkinVars vars) {
    final colors = <Color>[];
    for (final entry in raw) {
      final color = vars.color(entry);
      if (color != null) colors.add(color);
    }
    return colors.length >= 2 ? colors : null;
  }

  /// 资源路径必须是包内相对路径。绝对路径和 `..` 一律拒绝 —— 皮肤包不该能
  /// 引用它自己目录以外的任何文件。
  static String? _asset(Object? raw, String? assetRoot) {
    if (raw is! String || raw.isEmpty || assetRoot == null) return null;
    final relative = raw.replaceAll('\\', '/');
    if (relative.startsWith('/') ||
        relative.contains('..') ||
        RegExp(r'^[A-Za-z]:').hasMatch(relative)) {
      return null;
    }
    return '$assetRoot/$relative';
  }

  static const _fits = <Object?, BoxFit>{
    'cover': BoxFit.cover,
    'contain': BoxFit.contain,
    'fill': BoxFit.fill,
    'none': BoxFit.none,
    'fitWidth': BoxFit.fitWidth,
    'fitHeight': BoxFit.fitHeight,
  };
}

@immutable
class SkinBorderSpec {
  const SkinBorderSpec({this.color, this.width});

  final Color? color;
  final double? width;

  SkinBorderSpec merge(SkinBorderSpec? other) => other == null
      ? this
      : SkinBorderSpec(
          color: other.color ?? color,
          width: other.width ?? width,
        );

  Border? resolve() {
    if (color == null && width == null) return null;
    return Border.all(
      color: color ?? const Color(0x00000000),
      width: (width ?? 1).clamp(0.0, 8.0).toDouble(),
    );
  }

  static SkinBorderSpec? parse(Object? raw, SkinVars vars) {
    if (raw == null) return null;
    if (raw is String) {
      final color = vars.color(raw);
      return color == null ? null : SkinBorderSpec(color: color, width: 1);
    }
    if (raw is! Map) return null;
    return SkinBorderSpec(
      color: vars.color(raw['color']),
      width: vars.number(raw['width']),
    );
  }
}

@immutable
class SkinShadowSpec {
  const SkinShadowSpec({
    required this.color,
    this.blur = 0,
    this.spread = 0,
    this.dx = 0,
    this.dy = 0,
  });

  final Color color;
  final double blur;
  final double spread;
  final double dx;
  final double dy;

  BoxShadow resolve() => BoxShadow(
        color: color,
        blurRadius: blur.clamp(0.0, 60.0).toDouble(),
        spreadRadius: spread.clamp(-20.0, 20.0).toDouble(),
        offset: Offset(
          dx.clamp(-40.0, 40.0).toDouble(),
          dy.clamp(-40.0, 40.0).toDouble(),
        ),
      );

  static List<SkinShadowSpec>? parseList(Object? raw, SkinVars vars) {
    if (raw == null) return null;
    // `"shadow": "none"` 显式去掉内置阴影。给"扁平风"皮肤用 ——
    // 否则作者没有任何办法把默认阴影去掉。
    if (raw == 'none') return const <SkinShadowSpec>[];
    final entries = raw is List ? raw : <Object?>[raw];
    final shadows = <SkinShadowSpec>[];
    // 封顶 4 层：再多在移动端就是纯粹的光栅化开销。
    for (final entry in entries.take(4)) {
      if (entry is! Map) continue;
      final color = vars.color(entry['color']);
      if (color == null) continue;
      shadows.add(SkinShadowSpec(
        color: color,
        blur: vars.number(entry['blur']) ?? 0,
        spread: vars.number(entry['spread']) ?? 0,
        dx: vars.number(entry['dx']) ?? 0,
        dy: vars.number(entry['dy']) ?? 0,
      ));
    }
    return shadows;
  }
}

@immutable
class SkinTextSpec {
  const SkinTextSpec({
    this.size,
    this.height,
    this.spacing,
    this.weight,
    this.color,
    this.monospace,
  });

  final double? size;
  final double? height;
  final double? spacing;
  final int? weight;
  final Color? color;

  /// 只给"要不要等宽"这一个开关，不给任意字体名：皮肤包不能带字体文件，
  /// 而设备上有哪些字体是不可知的 —— 写一个用户设备上没有的字体名，
  /// 结果是静默回落，作者会以为是自己写错了。
  final bool? monospace;

  SkinTextSpec merge(SkinTextSpec? other) => other == null
      ? this
      : SkinTextSpec(
          size: other.size ?? size,
          height: other.height ?? height,
          spacing: other.spacing ?? spacing,
          weight: other.weight ?? weight,
          color: other.color ?? color,
          monospace: other.monospace ?? monospace,
        );

  TextStyle apply(TextStyle base) => base.copyWith(
        fontSize: size?.clamp(8.0, 40.0).toDouble(),
        height: height?.clamp(0.8, 3.0).toDouble(),
        letterSpacing: spacing?.clamp(-2.0, 8.0).toDouble(),
        fontWeight: _weights[weight],
        color: color,
        fontFamily: monospace == true ? 'monospace' : null,
      );

  static const _weights = <int?, FontWeight>{
    100: FontWeight.w100,
    200: FontWeight.w200,
    300: FontWeight.w300,
    400: FontWeight.w400,
    500: FontWeight.w500,
    600: FontWeight.w600,
    700: FontWeight.w700,
    800: FontWeight.w800,
    900: FontWeight.w900,
  };

  static SkinTextSpec? parse(Object? raw, SkinVars vars) {
    if (raw == null) return null;
    if (raw is String) {
      final color = vars.color(raw);
      return color == null ? null : SkinTextSpec(color: color);
    }
    if (raw is! Map) return null;
    final weight = vars.number(raw['weight'])?.round();
    return SkinTextSpec(
      size: vars.number(raw['size']),
      height: vars.number(raw['height']),
      spacing: vars.number(raw['spacing']),
      weight: _weights.containsKey(weight) ? weight : null,
      color: vars.color(raw['color']),
      monospace: raw['monospace'] is bool ? raw['monospace'] as bool : null,
    );
  }
}

@immutable
class SkinIconSpec {
  const SkinIconSpec({this.icon, this.size, this.color});

  final IconData? icon;
  final double? size;
  final Color? color;

  SkinIconSpec merge(SkinIconSpec? other) => other == null
      ? this
      : SkinIconSpec(
          icon: other.icon ?? icon,
          size: other.size ?? size,
          color: other.color ?? color,
        );

  static SkinIconSpec? parse(Object? raw, SkinVars vars) {
    if (raw == null) return null;
    if (raw is String) {
      final icon = skinIcons[raw];
      return icon == null ? null : SkinIconSpec(icon: icon);
    }
    if (raw is! Map) return null;
    return SkinIconSpec(
      icon: skinIcons[raw['name']],
      size: vars.number(raw['size']),
      color: vars.color(raw['color']),
    );
  }
}

/// 位移 / 缩放 / 旋转。范围在这里就钳死 —— 见 [PartStyle.clampAsRequired]，
/// 必留部件用的是更严的一套。
@immutable
class SkinTransformSpec {
  const SkinTransformSpec({
    this.dx = 0,
    this.dy = 0,
    this.scale = 1,
    this.rotate = 0,
  });

  final double dx;
  final double dy;
  final double scale;

  /// 度。
  final double rotate;

  bool get isIdentity => dx == 0 && dy == 0 && scale == 1 && rotate == 0;

  Matrix4 resolve() => Matrix4.identity()
    ..translateByDouble(dx, dy, 0, 1)
    ..rotateZ(rotate * math.pi / 180)
    ..scaleByDouble(scale, scale, 1, 1);

  static SkinTransformSpec? parse(Object? raw, SkinVars vars) {
    if (raw is! Map) return null;
    return SkinTransformSpec(
      dx: (vars.number(raw['dx']) ?? 0).clamp(-200.0, 200.0).toDouble(),
      dy: (vars.number(raw['dy']) ?? 0).clamp(-200.0, 200.0).toDouble(),
      scale: (vars.number(raw['scale']) ?? 1).clamp(0.2, 4.0).toDouble(),
      rotate: (vars.number(raw['rotate']) ?? 0).clamp(-180.0, 180.0).toDouble(),
    );
  }
}

enum SkinShape { rounded, circle, stadium }

/// 一个部件的全部可皮肤化属性。
@immutable
class PartStyle {
  const PartStyle({
    this.background,
    this.border,
    this.radius,
    this.shadows,
    this.padding,
    this.margin,
    this.size,
    this.height,
    this.maxWidthFactor,
    this.text,
    this.icon,
    this.opacity,
    this.transform,
    this.visible,
    this.shape,
    List<PartStyle?>? states,
  }) : _states = states;

  static const empty = PartStyle();

  final SkinFill? background;
  final SkinBorderSpec? border;
  final SkinCorners? radius;
  final List<SkinShadowSpec>? shadows;
  final SkinEdge? padding;
  final SkinEdge? margin;

  /// 方形尺寸。头像、圆形按钮这类用它。
  final double? size;
  final double? height;

  /// 相对屏幕宽度的最大宽度系数。气泡用它。
  final double? maxWidthFactor;

  final SkinTextSpec? text;
  final SkinIconSpec? icon;
  final double? opacity;
  final SkinTransformSpec? transform;
  final bool? visible;
  final SkinShape? shape;

  /// 按 [SkinState.index] 下标的完整状态样式。渲染层取它是一次数组访问。
  final List<PartStyle?>? _states;

  PartStyle? on(SkinState state) {
    final states = _states;
    if (states == null || state.index >= states.length) return null;
    return states[state.index];
  }

  bool get hidden => visible == false;

  /// [other] 非 null 的属性覆盖本对象。状态表也逐位合并。
  PartStyle merge(PartStyle? other) {
    if (other == null) return this;
    List<PartStyle?>? states;
    if (_states != null || other._states != null) {
      states = List<PartStyle?>.filled(SkinState.values.length, null);
      for (final state in SkinState.values) {
        final mine = on(state);
        final theirs = other.on(state);
        states[state.index] =
            mine == null ? theirs : mine.merge(theirs);
      }
    }
    return PartStyle(
      background: background?.merge(other.background) ?? other.background,
      border: border?.merge(other.border) ?? other.border,
      radius: radius?.merge(other.radius) ?? other.radius,
      shadows: other.shadows ?? shadows,
      padding: padding?.merge(other.padding) ?? other.padding,
      margin: margin?.merge(other.margin) ?? other.margin,
      size: other.size ?? size,
      height: other.height ?? height,
      maxWidthFactor: other.maxWidthFactor ?? maxWidthFactor,
      text: text?.merge(other.text) ?? other.text,
      icon: icon?.merge(other.icon) ?? other.icon,
      opacity: other.opacity ?? opacity,
      transform: other.transform ?? transform,
      visible: other.visible ?? visible,
      shape: other.shape ?? shape,
      states: states,
    );
  }

  PartStyle withStates(List<PartStyle?> states) => PartStyle(
        background: background,
        border: border,
        radius: radius,
        shadows: shadows,
        padding: padding,
        margin: margin,
        size: size,
        height: height,
        maxWidthFactor: maxWidthFactor,
        text: text,
        icon: icon,
        opacity: opacity,
        transform: transform,
        visible: visible,
        shape: shape,
        states: states,
      );

  // ---- 取值：全部带 fallback，皮肤没写就用渲染层的默认值 ----

  Color? fillColor([Color? fallback]) => background?.color ?? fallback;
  Gradient? get gradient => background?.resolveGradient();
  String? get image => background?.image;
  double? get blur => background?.blur;

  EdgeInsets padded(EdgeInsets fallback) =>
      padding?.resolve(fallback) ?? fallback;

  EdgeInsets margined(EdgeInsets fallback) =>
      margin?.resolve(fallback) ?? fallback;

  BorderRadius rounded(BorderRadius fallback) =>
      radius?.resolve(fallback) ?? fallback;

  TextStyle styled(TextStyle base) => text?.apply(base) ?? base;

  IconData iconOr(IconData fallback) => icon?.icon ?? fallback;
  double iconSizeOr(double fallback) =>
      icon?.size?.clamp(10.0, 48.0).toDouble() ?? fallback;
  Color iconColorOr(Color fallback) => icon?.color ?? fallback;

  List<BoxShadow>? shadowsOr(List<BoxShadow>? fallback) {
    final specs = shadows;
    if (specs == null) return fallback;
    return specs.map((s) => s.resolve()).toList(growable: false);
  }

  Border? borderOr(Border? fallback) => border?.resolve() ?? fallback;

  /// 把不透明度和变换套到一个已经画好的部件上。
  Widget decorate(Widget child) {
    var result = child;
    final t = transform;
    if (t != null && !t.isIdentity) {
      result = Transform(
        alignment: Alignment.center,
        transform: t.resolve(),
        child: result,
      );
    }
    final o = opacity;
    if (o != null && o < 1) {
      result = Opacity(opacity: o.clamp(0.0, 1.0).toDouble(), child: result);
    }
    return result;
  }

  /// 必留部件的钳制。
  ///
  /// **这是"支持自定义样式，但不支持不显示"真正落地的地方。** 皮肤包想让一个
  /// 按钮消失有至少六条路，schema 校验一条都拦不住，所以在这里逐条堵死：
  ///
  ///   - `visible: false` → 直接丢掉
  ///   - `opacity: 0` → 钳到不低于 [_minOpacity]
  ///   - 尺寸归零 → 钳到不小于 [minTapTarget]
  ///   - `transform` 推出屏幕 → 位移钳到 ±[_maxRequiredShift]，缩放不低于 0.75
  ///   - 图标尺寸归零 → 钳到不小于 14
  ///
  /// 第六条（用别的图层盖住它）不在这里 —— 那要靠骨架固定 z 序，见
  /// `SkinAffordance` 的说明。
  PartStyle clampAsRequired() {
    final t = transform;
    return PartStyle(
      background: background,
      border: border,
      radius: radius,
      shadows: shadows,
      padding: padding,
      margin: margin,
      size: size?.clamp(minTapTarget, 96.0).toDouble(),
      height: height,
      maxWidthFactor: maxWidthFactor,
      text: text,
      icon: icon == null
          ? null
          : SkinIconSpec(
              icon: icon!.icon,
              size: icon!.size?.clamp(14.0, 40.0).toDouble(),
              color: icon!.color,
            ),
      opacity: opacity?.clamp(_minOpacity, 1.0).toDouble(),
      transform: t == null
          ? null
          : SkinTransformSpec(
              dx: t.dx.clamp(-_maxRequiredShift, _maxRequiredShift),
              dy: t.dy.clamp(-_maxRequiredShift, _maxRequiredShift),
              scale: t.scale.clamp(0.75, 1.6).toDouble(),
              rotate: t.rotate,
            ),
      // 必留就是必留。这里不报错、不拒绝整包 —— 作者多半只是想藏掉一个
      // 他觉得多余的按钮，为此让整个皮肤包装不上是不成比例的。
      visible: null,
      shape: shape,
      states: _states,
    );
  }

  /// Material 的最小可触达尺寸。
  static const double minTapTarget = 48;
  static const double _minOpacity = 0.55;
  static const double _maxRequiredShift = 12;

  static PartStyle parse(
    Map<String, Object?> raw,
    SkinVars vars, {
    String? assetRoot,
  }) =>
      PartStyle(
        background: SkinFill.parse(raw['background'], vars, assetRoot),
        border: SkinBorderSpec.parse(raw['border'], vars),
        radius: SkinCorners.parse(raw['radius'], vars),
        shadows: SkinShadowSpec.parseList(raw['shadow'], vars),
        padding: SkinEdge.parse(raw['padding'], vars),
        margin: SkinEdge.parse(raw['margin'], vars),
        size: vars.number(raw['size'])?.clamp(8.0, 160.0).toDouble(),
        height: vars.number(raw['height'])?.clamp(0.0, 240.0).toDouble(),
        maxWidthFactor:
            vars.number(raw['maxWidth'])?.clamp(0.3, 1.0).toDouble(),
        text: SkinTextSpec.parse(raw['text'], vars),
        icon: SkinIconSpec.parse(raw['icon'], vars),
        opacity: vars.number(raw['opacity'])?.clamp(0.0, 1.0).toDouble(),
        transform: SkinTransformSpec.parse(raw['transform'], vars),
        visible: raw['visible'] is bool ? raw['visible'] as bool : null,
        shape: _shapes[raw['shape']],
      );

  static const _shapes = <Object?, SkinShape>{
    'rounded': SkinShape.rounded,
    'circle': SkinShape.circle,
    'stadium': SkinShape.stadium,
  };
}

/// 把一个 [PartStyle] 落成一个实际的盒子。
///
/// 顶栏、日期胶囊、输入底座、卡片气泡都走这里，省得每处各写一遍
/// 「先 margin 再阴影再模糊再图片再 padding」的顺序 —— 顺序写错的表现是
/// 模糊把阴影也糊了，或者背景图盖住了边框，都属于看得见但很难归因的问题。
///
/// 层序是固定的，皮肤改不了：
///
///     margin → 阴影/边框/底色 → 背景模糊 → 背景图 → padding → child
class SkinBox extends StatelessWidget {
  const SkinBox({
    super.key,
    required this.style,
    required this.child,
    this.color,
    this.radius = BorderRadius.zero,
    this.padding = EdgeInsets.zero,
    this.margin = EdgeInsets.zero,
    this.border,
    this.shadows,
  });

  final PartStyle style;
  final Widget child;

  /// 骨架的默认值。皮肤没写就用它们。
  final Color? color;
  final BorderRadius radius;
  final EdgeInsets padding;
  final EdgeInsets margin;
  final Border? border;
  final List<BoxShadow>? shadows;

  @override
  Widget build(BuildContext context) {
    final corners = style.rounded(radius);
    final gradient = style.gradient;
    final fill = gradient == null ? style.fillColor(color) : null;
    final blur = style.blur;
    final image = style.image;

    Widget content = Padding(padding: style.padded(padding), child: child);

    if (image != null) {
      final file = File(image);
      if (file.existsSync()) {
        content = Stack(
          fit: StackFit.passthrough,
          children: <Widget>[
            Positioned.fill(
              child: Opacity(
                opacity: style.background?.imageOpacity ?? 1,
                child: Image.file(
                  file,
                  fit: style.background?.fit ?? BoxFit.cover,
                  gaplessPlayback: true,
                  filterQuality: FilterQuality.medium,
                  // 图挂了就露出底色，而不是整块区域抛红屏 —— 用户仍然能
                  // 打开外观页把这个皮肤换掉。
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
            ),
            content,
          ],
        );
      }
    }

    if (blur != null && blur > 0) {
      content = BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: content,
      );
    }

    Widget box = DecoratedBox(
      decoration: BoxDecoration(
        color: fill,
        gradient: gradient,
        border: style.borderOr(border),
        borderRadius: corners,
        boxShadow: style.shadowsOr(shadows),
      ),
      child: corners == BorderRadius.zero
          ? content
          : ClipRRect(borderRadius: corners, child: content),
    );

    final outer = style.margined(margin);
    if (outer != EdgeInsets.zero) box = Padding(padding: outer, child: box);
    return style.decorate(box);
  }
}

/// WCAG 的相对对比度。用来判断"这个皮肤是不是把字写成了背景色"。
double skinContrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}
