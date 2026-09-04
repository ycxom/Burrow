/// 聊天皮肤包的唯一 seam。
///
/// 聊天页和 Material 主题只需要向 [ChatSkinCatalog] 要一个已解析的
/// [ChatSkinPack]；它们不知道皮肤来自内置列表、磁盘上的文件还是未来的仓库。
/// 外部加载器（[ChatSkinStore]）把 manifest 转成 [ChatSkinPack] 后作为
/// `installed` 传进来，现有调用方不需要增加分支。
///
/// 一个皮肤包由两层组成：
///
///   - **令牌**（[ChatTokens]）：30 个颜色。改它等于换配色。
///   - **部件**（[ChatSkinParts]）：每个可见元素的形状、间距、字体、版式。
///     改它等于换版式。
///
/// 两层分开是因为它们的失效方式不同：令牌写错顶多难看，部件写错可能让一个
/// 按钮点不到。必留部件的钳制只发生在部件层，见 [PartStyle.clampAsRequired]。
library;

import 'package:flutter/material.dart';

import '../settings/settings_store.dart';
import 'chat_theme.dart';
import 'skin_parts.dart';
import 'skin_style.dart';

@immutable
class ChatSkinPack {
  const ChatSkinPack({
    required this.id,
    required this.name,
    required this.description,
    required this.lightTokens,
    required this.darkTokens,
    required this.previewColors,
    this.author = '',
    this.schemaVersion = 2,
    this.lightParts = ChatSkinParts.fallback,
    this.darkParts = ChatSkinParts.fallback,
    this.builtIn = false,
    this.installPath,
    this.warnings = const <String>[],
  });

  /// 持久化标识；发布后不能因为显示名变化而修改。
  final String id;
  final String name;
  final String description;
  final String author;

  /// manifest 版本。加载器负责迁移或拒绝，UI 不处理。
  final int schemaVersion;

  final ChatTokens lightTokens;
  final ChatTokens darkTokens;
  final ChatSkinParts lightParts;
  final ChatSkinParts darkParts;
  final List<Color> previewColors;

  /// 内置皮肤不能被卸载，ID 也被保留（外部包不能冒充）。
  final bool builtIn;

  /// 外部皮肤在磁盘上的目录。卸载和资源解析都要它。
  final String? installPath;

  /// 加载时被修正掉的问题。外观页展示给作者看 —— 静默修正会让作者反复
  /// 怀疑是自己写的值没生效。
  final List<String> warnings;

  ChatTokens tokensFor(Brightness brightness) =>
      brightness == Brightness.dark ? darkTokens : lightTokens;

  ChatSkinParts partsFor(Brightness brightness) =>
      brightness == Brightness.dark ? darkParts : lightParts;
}

class ChatSkinCatalog {
  ChatSkinCatalog._();

  static const ChatSkinPack _nekogram = ChatSkinPack(
    id: SettingsStore.defaultChatSkinId,
    name: 'Nekogram 经典',
    description: '深蓝聊天底色、Telegram 气泡与清晰的蓝色强调',
    author: 'Burrow',
    builtIn: true,
    lightTokens: ChatTokens.light,
    darkTokens: ChatTokens.dark,
    previewColors: <Color>[
      Color(0xFF0E1621),
      Color(0xFF182533),
      Color(0xFF3390EC),
    ],
  );

  static final ChatSkinPack _amethyst = ChatSkinPack(
    id: 'amethyst_glass',
    name: '紫晶玻璃',
    description: '紫蓝高光、冷灰气泡与更明显的玻璃层次',
    author: 'Burrow',
    builtIn: true,
    lightTokens: ChatTokens.light.copyWith(
      brand: const Color(0xFF6C63E8),
      bgBrandSecondary: const Color(0xFFEDEBFF),
      wallpaperTop: const Color(0xFFF0EDFF),
      wallpaperBottom: const Color(0xFFDDEAF8),
      bubbleOut: const Color(0xFFE7E2FF),
      timeOut: const Color(0xFF766EC5),
      composerDockTop: const Color(0xFFFFFFFF),
      composerDockBottom: const Color(0xFFE2E0F6),
      composerDockRim: const Color(0xFFFFFFFF),
      composerDockShadow: const Color(0x5E221B51),
    ),
    darkTokens: ChatTokens.dark.copyWith(
      brand: const Color(0xFF8F83FF),
      bgPrimary: const Color(0xFF171521),
      bgSecondary: const Color(0xFF282536),
      bgTertiary: const Color(0xFF342F47),
      bgBrandSecondary: const Color(0xFF302B55),
      borderPrimary: const Color(0xFF3B3650),
      wallpaperTop: const Color(0xFF11101B),
      wallpaperBottom: const Color(0xFF211B35),
      bubbleIn: const Color(0xFF242131),
      bubbleOut: const Color(0xFF514787),
      timeOut: const Color(0xFFB4ACF6),
      headerBg: const Color(0xFF171521),
      composerBg: const Color(0xFF171521),
      composerField: const Color(0xFF282536),
      composerDockTop: const Color(0xFF393252),
      composerDockBottom: const Color(0xFF14101F),
      composerDockRim: const Color(0xFF766BA3),
      composerDockShadow: const Color(0xD0080611),
    ),
    previewColors: const <Color>[
      Color(0xFF11101B),
      Color(0xFF514787),
      Color(0xFF8F83FF),
    ],
  );

  /// 内置的"版式"示范：不改配色，只改形状。
  ///
  /// 它的作用一半是给用户一个选项，另一半是**证明部件层真的接通了** ——
  /// 一个只动令牌的皮肤包看不出 [ChatSkinParts] 有没有被渲染层读到。
  static final ChatSkinPack _slate = ChatSkinPack(
    id: 'slate_flat',
    name: '石板扁平',
    description: '无尾气泡、方正卡片与贴底输入区，去掉所有投影',
    author: 'Burrow',
    builtIn: true,
    lightTokens: ChatTokens.light.copyWith(
      brand: const Color(0xFF4B5563),
      wallpaperTop: const Color(0xFFF3F4F6),
      wallpaperBottom: const Color(0xFFE5E7EB),
      bubbleIn: const Color(0xFFFFFFFF),
      bubbleOut: const Color(0xFFDDE3EA),
      timeOut: const Color(0xFF6B7280),
    ),
    darkTokens: ChatTokens.dark.copyWith(
      brand: const Color(0xFF9CA3AF),
      bgPrimary: const Color(0xFF111315),
      bgSecondary: const Color(0xFF1C1F23),
      wallpaperTop: const Color(0xFF0B0D0F),
      wallpaperBottom: const Color(0xFF15181C),
      bubbleIn: const Color(0xFF1C1F23),
      bubbleOut: const Color(0xFF2F343B),
      headerBg: const Color(0xFF111315),
      composerBg: const Color(0xFF111315),
    ),
    lightParts: _slateParts,
    darkParts: _slateParts,
    previewColors: const <Color>[
      Color(0xFF0B0D0F),
      Color(0xFF2F343B),
      Color(0xFF9CA3AF),
    ],
  );

  static const _slateParts = ChatSkinParts(
    bubbleLayout: SkinBubbleLayout.plain,
    composerMode: SkinComposerMode.docked,
    bubbleIn: PartStyle(
      radius: SkinCorners(tl: 6, tr: 6, br: 6, bl: 6),
      shadows: <SkinShadowSpec>[],
    ),
    bubbleOut: PartStyle(
      radius: SkinCorners(tl: 6, tr: 6, br: 6, bl: 6),
      shadows: <SkinShadowSpec>[],
    ),
    composerDock: PartStyle(
      radius: SkinCorners(tl: 10, tr: 10, br: 10, bl: 10),
      shadows: <SkinShadowSpec>[],
    ),
    datePill: PartStyle(radius: SkinCorners(tl: 4, tr: 4, br: 4, bl: 4)),
  );

  static List<ChatSkinPack> get builtIns => List<ChatSkinPack>.unmodifiable(
        <ChatSkinPack>[_nekogram, _amethyst, _slate],
      );

  static ChatSkinPack get fallback => _nekogram;

  /// 内置 ID 被保留，避免外部包冒充默认皮肤。
  static bool isReservedId(String id) => builtIns.any((skin) => skin.id == id);

  /// 合并外部加载器提供的皮肤。
  static List<ChatSkinPack> available({
    Iterable<ChatSkinPack> installed = const <ChatSkinPack>[],
  }) {
    final byId = <String, ChatSkinPack>{
      for (final skin in builtIns) skin.id: skin,
    };
    for (final skin in installed) {
      if (skin.id.isNotEmpty) byId.putIfAbsent(skin.id, () => skin);
    }
    return List<ChatSkinPack>.unmodifiable(byId.values);
  }

  /// 未安装、已损坏或旧版本留下的 ID 都安全回退默认皮肤。
  static ChatSkinPack resolve(
    String? id, {
    Iterable<ChatSkinPack> installed = const <ChatSkinPack>[],
  }) {
    final skins = available(installed: installed);
    for (final skin in skins) {
      if (skin.id == id) return skin;
    }
    return _nekogram;
  }
}

/// 主题。种子色和各处底色见 chat_theme.dart，让 Material 组件（弹窗、按钮、
/// 进度条）和聊天区是同一套颜色 —— 只改聊天区的话，一点开设置页就会看出是
/// 两个 app 拼起来的。
///
/// 放在这里而不是 app.dart：外观页要用**内置皮肤**单独构一份主题给自己用
/// （见 ChatAppearancePage 的说明），那是逃生舱的一部分，不能依赖 app.dart。
ThemeData buildSkinTheme(Brightness brightness, ChatSkinPack skin) {
  final tokens = skin.tokensFor(brightness);
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: ColorScheme.fromSeed(
      seedColor: tokens.brand,
      brightness: brightness,
    ).copyWith(surface: tokens.bgPrimary),
    scaffoldBackgroundColor: tokens.bgPrimary,
    appBarTheme: AppBarTheme(
      backgroundColor: tokens.bgPrimary,
      foregroundColor: tokens.tintPrimary,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    extensions: <ThemeExtension<dynamic>>[
      tokens,
      skin.partsFor(brightness),
    ],
  );
}
