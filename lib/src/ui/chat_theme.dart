/// 聊天界面的设计令牌，Telegram 风格。
///
/// 整套色号写死在这里，**不用 Material 的 ColorScheme 近似**：让框架按种子色
/// 推导，每个色号都会差一点，叠起来就不是同一个界面了。
///
/// Telegram 的配色有几个和 Material 很不一样的地方，照抄 Material 会丢掉：
///
///   - **聊天区有壁纸**，气泡浮在上面。所以「页面底色」和「气泡底色」是
///     两套东西，不能共用一个 surface。
///   - **收发两侧的气泡颜色不对称**：发出去的是浅绿（暗色下是蓝），
///     收到的是白（暗色下是深蓝灰）。不是「主色 vs 次色」那种关系。
///   - **时间戳的颜色跟着气泡走**，发出去的偏绿、收到的偏灰。它压在气泡
///     里面，对比度要压得很低才不抢正文。
///
/// 为什么是 ThemeExtension 而不是一堆 const：亮/暗两套要跟着系统切，
/// 而 Flutter 里让一组颜色跟着 Theme 走的正经做法就是它。
library;

import 'package:flutter/material.dart';

@immutable
class ChatTokens extends ThemeExtension<ChatTokens> {
  // ---- 通用界面（设置页、抽屉、技能页都用这一组）----

  /// 页面底色。
  final Color bgPrimary;

  /// 卡片 / 输入框 / 次级填充的底色。
  final Color bgSecondary;

  /// 更深一层的填充（按下态、代码块）。
  final Color bgTertiary;

  /// 品牌色的浅底。
  final Color bgBrandSecondary;

  /// 报错块的浅底。
  final Color bgErrorSecondary;

  /// 正文。
  final Color tintPrimary;

  /// 次要文字。
  final Color tintSecondary;

  /// 更弱的文字（时间、占位符）。
  final Color tintTertiary;

  final Color tintError;
  final Color tintWarning;
  final Color tintSuccess;

  /// 分隔线。
  final Color borderPrimary;

  /// 强调色。发送键、开关、链接。
  final Color brand;

  // ---- 聊天区专属 ----

  /// 壁纸渐变的两端。Telegram 的聊天区永远有底纹，气泡浮在上面 ——
  /// 少了这一层，气泡就变成"卡片列表"，不是聊天。
  final Color wallpaperTop;
  final Color wallpaperBottom;

  /// 收到的气泡（助手、工具输出）。
  final Color bubbleIn;

  /// 发出的气泡（用户）。
  final Color bubbleOut;

  final Color tintOnIn;
  final Color tintOnOut;

  /// 气泡里那行时间戳。压得很低，不抢正文。
  final Color timeIn;
  final Color timeOut;

  /// 居中的胶囊：日期分隔、系统提示。半透明压在壁纸上。
  final Color servicePill;
  final Color tintOnService;

  /// 顶栏和输入区的底色。壁纸只铺在消息列表那一段，
  /// 上下两条是实心的 —— Telegram 就是这么分层的。
  final Color headerBg;
  final Color composerBg;

  /// 输入框那颗药丸的底色。
  final Color composerField;

  const ChatTokens({
    required this.bgPrimary,
    required this.bgSecondary,
    required this.bgTertiary,
    required this.bgBrandSecondary,
    required this.bgErrorSecondary,
    required this.tintPrimary,
    required this.tintSecondary,
    required this.tintTertiary,
    required this.tintError,
    required this.tintWarning,
    required this.tintSuccess,
    required this.borderPrimary,
    required this.brand,
    required this.wallpaperTop,
    required this.wallpaperBottom,
    required this.bubbleIn,
    required this.bubbleOut,
    required this.tintOnIn,
    required this.tintOnOut,
    required this.timeIn,
    required this.timeOut,
    required this.servicePill,
    required this.tintOnService,
    required this.headerBg,
    required this.composerBg,
    required this.composerField,
  });

  static const light = ChatTokens(
    bgPrimary: Color(0xFFFFFFFF),
    bgSecondary: Color(0xFFF1F3F5),
    bgTertiary: Color(0xFFE4E8EB),
    bgBrandSecondary: Color(0xFFE7F3FF),
    bgErrorSecondary: Color(0xFFFDEAEA),
    tintPrimary: Color(0xFF000000),
    tintSecondary: Color(0xFF707579),
    tintTertiary: Color(0xFFA2ACB4),
    tintError: Color(0xFFDF3F40),
    tintWarning: Color(0xFFE8A33D),
    tintSuccess: Color(0xFF4FAE4E),
    borderPrimary: Color(0xFFDFE1E5),
    brand: Color(0xFF3390EC),
    wallpaperTop: Color(0xFFE9EEF3),
    wallpaperBottom: Color(0xFFD6E2ED),
    bubbleIn: Color(0xFFFFFFFF),
    bubbleOut: Color(0xFFEFFDDE),
    tintOnIn: Color(0xFF000000),
    tintOnOut: Color(0xFF000000),
    timeIn: Color(0xFFA1AAB3),
    timeOut: Color(0xFF62AB59),
    servicePill: Color(0x4D000000),
    tintOnService: Color(0xFFFFFFFF),
    headerBg: Color(0xFFFFFFFF),
    composerBg: Color(0xFFFFFFFF),
    composerField: Color(0xFFF1F3F5),
  );

  static const dark = ChatTokens(
    bgPrimary: Color(0xFF17212B),
    bgSecondary: Color(0xFF232E3C),
    bgTertiary: Color(0xFF2B3847),
    bgBrandSecondary: Color(0xFF1E3A54),
    bgErrorSecondary: Color(0xFF3A2226),
    tintPrimary: Color(0xFFFFFFFF),
    tintSecondary: Color(0xFFB1C0CE),
    tintTertiary: Color(0xFF708499),
    tintError: Color(0xFFEC6759),
    tintWarning: Color(0xFFE8A33D),
    tintSuccess: Color(0xFF5FC26A),
    borderPrimary: Color(0xFF2B3847),
    brand: Color(0xFF3390EC),
    wallpaperTop: Color(0xFF0E1621),
    wallpaperBottom: Color(0xFF141E29),
    bubbleIn: Color(0xFF182533),
    bubbleOut: Color(0xFF2B5278),
    tintOnIn: Color(0xFFFFFFFF),
    tintOnOut: Color(0xFFFFFFFF),
    timeIn: Color(0xFF6D7F8F),
    timeOut: Color(0xFF79A7D4),
    // 暗色下胶囊要比壁纸**亮**。用半透明黑的话它会比背景还深，
    // 在深色壁纸上等于没有底 —— 实测就是这样，只看得见字。
    servicePill: Color(0x24FFFFFF),
    tintOnService: Color(0xFFD3DEE8),
    headerBg: Color(0xFF17212B),
    composerBg: Color(0xFF17212B),
    composerField: Color(0xFF232E3C),
  );

  @override
  ChatTokens copyWith({
    Color? bgPrimary,
    Color? bgSecondary,
    Color? bgTertiary,
    Color? bgBrandSecondary,
    Color? bgErrorSecondary,
    Color? tintPrimary,
    Color? tintSecondary,
    Color? tintTertiary,
    Color? tintError,
    Color? tintWarning,
    Color? tintSuccess,
    Color? borderPrimary,
    Color? brand,
    Color? wallpaperTop,
    Color? wallpaperBottom,
    Color? bubbleIn,
    Color? bubbleOut,
    Color? tintOnIn,
    Color? tintOnOut,
    Color? timeIn,
    Color? timeOut,
    Color? servicePill,
    Color? tintOnService,
    Color? headerBg,
    Color? composerBg,
    Color? composerField,
  }) =>
      ChatTokens(
        bgPrimary: bgPrimary ?? this.bgPrimary,
        bgSecondary: bgSecondary ?? this.bgSecondary,
        bgTertiary: bgTertiary ?? this.bgTertiary,
        bgBrandSecondary: bgBrandSecondary ?? this.bgBrandSecondary,
        bgErrorSecondary: bgErrorSecondary ?? this.bgErrorSecondary,
        tintPrimary: tintPrimary ?? this.tintPrimary,
        tintSecondary: tintSecondary ?? this.tintSecondary,
        tintTertiary: tintTertiary ?? this.tintTertiary,
        tintError: tintError ?? this.tintError,
        tintWarning: tintWarning ?? this.tintWarning,
        tintSuccess: tintSuccess ?? this.tintSuccess,
        borderPrimary: borderPrimary ?? this.borderPrimary,
        brand: brand ?? this.brand,
        wallpaperTop: wallpaperTop ?? this.wallpaperTop,
        wallpaperBottom: wallpaperBottom ?? this.wallpaperBottom,
        bubbleIn: bubbleIn ?? this.bubbleIn,
        bubbleOut: bubbleOut ?? this.bubbleOut,
        tintOnIn: tintOnIn ?? this.tintOnIn,
        tintOnOut: tintOnOut ?? this.tintOnOut,
        timeIn: timeIn ?? this.timeIn,
        timeOut: timeOut ?? this.timeOut,
        servicePill: servicePill ?? this.servicePill,
        tintOnService: tintOnService ?? this.tintOnService,
        headerBg: headerBg ?? this.headerBg,
        composerBg: composerBg ?? this.composerBg,
        composerField: composerField ?? this.composerField,
      );

  @override
  ChatTokens lerp(ThemeExtension<ChatTokens>? other, double t) {
    if (other is! ChatTokens) return this;
    Color c(Color a, Color b) => Color.lerp(a, b, t)!;
    return ChatTokens(
      bgPrimary: c(bgPrimary, other.bgPrimary),
      bgSecondary: c(bgSecondary, other.bgSecondary),
      bgTertiary: c(bgTertiary, other.bgTertiary),
      bgBrandSecondary: c(bgBrandSecondary, other.bgBrandSecondary),
      bgErrorSecondary: c(bgErrorSecondary, other.bgErrorSecondary),
      tintPrimary: c(tintPrimary, other.tintPrimary),
      tintSecondary: c(tintSecondary, other.tintSecondary),
      tintTertiary: c(tintTertiary, other.tintTertiary),
      tintError: c(tintError, other.tintError),
      tintWarning: c(tintWarning, other.tintWarning),
      tintSuccess: c(tintSuccess, other.tintSuccess),
      borderPrimary: c(borderPrimary, other.borderPrimary),
      brand: c(brand, other.brand),
      wallpaperTop: c(wallpaperTop, other.wallpaperTop),
      wallpaperBottom: c(wallpaperBottom, other.wallpaperBottom),
      bubbleIn: c(bubbleIn, other.bubbleIn),
      bubbleOut: c(bubbleOut, other.bubbleOut),
      tintOnIn: c(tintOnIn, other.tintOnIn),
      tintOnOut: c(tintOnOut, other.tintOnOut),
      timeIn: c(timeIn, other.timeIn),
      timeOut: c(timeOut, other.timeOut),
      servicePill: c(servicePill, other.servicePill),
      tintOnService: c(tintOnService, other.tintOnService),
      headerBg: c(headerBg, other.headerBg),
      composerBg: c(composerBg, other.composerBg),
      composerField: c(composerField, other.composerField),
    );
  }
}

extension ChatTokensX on BuildContext {
  /// 取当前主题下的聊天令牌。
  ///
  /// 没注册扩展时兜底到亮色而不是抛异常 —— 某个页面忘了套主题不该是崩溃，
  /// 顶多是颜色不对，而颜色不对一眼就能看出来。
  ChatTokens get chat =>
      Theme.of(this).extension<ChatTokens>() ?? ChatTokens.light;
}

/// 圆角尺寸。
class ChatShape {
  ChatShape._();

  /// 通用卡片圆角（设置页、抽屉这些非聊天界面）。
  static const radiusLg = 8.0;

  /// 气泡圆角。
  static const bubbleRadius = 14.0;

  /// 带尾巴那一侧的底角。Telegram 在这里几乎不倒角，
  /// 尾巴是从这个角上长出去的。
  static const bubbleTailCorner = 3.0;

  /// 尾巴伸出去的宽度。气泡的内容区会为它让出这么多。
  static const tailWidth = 7.0;

  /// 输入框那颗药丸。
  static const composerRadius = 22.0;
}
