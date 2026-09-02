/// 皮肤包 manifest 的解析器。**纯函数，不碰磁盘。**
///
/// 和 [SkillFrontmatter.parse] 一样的可测性考虑：解析一个皮肤包不该需要先造出
/// 一个文件系统。IO 全在 [ChatSkinStore] 那一层。
///
/// ## 格式
///
/// ```json
/// {
///   "schema": 2,
///   "id": "ycxom.glass",
///   "name": "暮色玻璃",
///   "description": "紫调夜间，压低的气泡对比",
///   "author": "ycxom",
///   "extends": "nekogram",
///   "preview": ["#11101B", "#514787", "#8F83FF"],
///
///   "vars": { "accent": "#8F83FF", "radius": 16 },
///
///   "tokens": {
///     "dark":  { "brand": "var(accent)", "bubbleOut": "#514787" },
///     "light": { "brand": "darken(var(accent), 0.2)" }
///   },
///
///   "parts": {
///     "bubble":            { "radius": "var(radius)", "padding": 11 },
///     "bubble.out":        { "background": { "gradient": ["var(accent)", "#514787"] } },
///     "bubble.out:first":  { "radius": { "tr": 4 } },
///     "header:dark":       { "background": { "color": "#1715217F", "blur": 24 } },
///     "header.drawer":     { "icon": "menu_open", "shape": "circle" },
///     "layout":            { "bubble": "tail", "time": "inside" }
///   }
/// }
/// ```
///
/// ## 三条兜底，逐层收窄
///
///   - **令牌级**：单个颜色写错 → 用基座那一个值，其余照常。
///   - **模式级**：缺 `light` 或 `dark` → 那一半用基座。
///   - **包级**：schema 太新、缺 id/name、对比度崩了 → 整包拒绝，
///     调用方回落默认皮肤。
///
/// 只有最后一档会让皮肤装不上。前两档都只在 [SkinManifestResult.warnings]
/// 里留一条 —— 一个拼错的键不该让别人辛苦调好的其余 29 个颜色一起作废。
library;

import 'package:flutter/material.dart';

import 'chat_skin.dart';
import 'chat_theme.dart';
import 'skin_parts.dart';
import 'skin_style.dart';
import 'skin_vars.dart';

class SkinManifestResult {
  const SkinManifestResult({
    this.pack,
    this.errors = const <String>[],
    this.warnings = const <String>[],
  });

  /// 解析失败时为 null。
  final ChatSkinPack? pack;

  /// 致命问题。非空即表示这个包装不上。
  final List<String> errors;

  /// 已经被修正掉的问题。装得上，但作者应该知道。
  final List<String> warnings;

  bool get ok => pack != null;
}

class SkinManifest {
  SkinManifest._();

  /// 当前支持的 manifest 版本。
  ///
  /// 比它**新**的整包拒绝：一个 v3 的包里可能有 v2 不认识的必留部件约束，
  /// 按 v2 的规则读出来的会是一个作者从没设计过的界面。
  /// 比它旧的照常读 —— 稀疏合并本来就向后兼容。
  static const currentSchema = 2;

  /// 外部皮肤 ID 的形状：至少两段，用 `.` 或 `/` 分隔。
  ///
  /// 强制命名空间是为了让"两个人各自做了个叫 dark 的皮肤"不会互相覆盖。
  static final _externalId = RegExp(r'^[a-z0-9_-]+[./][a-z0-9._/-]+$');

  /// 低于这个对比度就认为"字和背景一个色"。
  ///
  /// 不用 WCAG 的 4.5 —— 那是可读性标准，会把一大批合法的低对比设计判死。
  /// 这里要拦的只有一种情况：**皮肤把界面变成一片纯色，用户再也换不回来。**
  static const _minContrast = 1.6;

  /// 解析一份 manifest。
  ///
  /// [assetRoot] 是这个包在磁盘上的目录；为 null 时包里的图片引用全部被丢弃
  /// （剪贴板导入的纯 JSON 就是这种情况 —— 它没有随行资源）。
  static SkinManifestResult parse(
    Map<String, Object?> json, {
    String? assetRoot,
    bool builtInId = false,
  }) {
    final errors = <String>[];
    final warnings = <String>[];

    final schema = (json['schema'] as num?)?.toInt() ?? 1;
    if (schema > currentSchema) {
      return SkinManifestResult(errors: <String>[
        '这个皮肤包需要更新版本的 Burrow（manifest v$schema，当前支持 v$currentSchema）',
      ]);
    }

    final id = (json['id'] as String? ?? '').trim();
    if (id.isEmpty) {
      errors.add('皮肤包缺少 id');
    } else if (!builtInId) {
      if (ChatSkinCatalog.isReservedId(id)) {
        errors.add('id "$id" 是内置皮肤的保留名，请换一个');
      } else if (!_externalId.hasMatch(id)) {
        errors.add('id "$id" 需要带命名空间，例如 "作者名.皮肤名"');
      }
    }

    final name = (json['name'] as String? ?? '').trim();
    if (name.isEmpty) errors.add('皮肤包缺少 name');

    if (errors.isNotEmpty) {
      return SkinManifestResult(errors: errors, warnings: warnings);
    }

    // ---- 基座 ----
    final extendsId = (json['extends'] as String? ?? '').trim();
    ChatSkinPack base = ChatSkinCatalog.fallback;
    if (extendsId.isNotEmpty) {
      // **只允许继承内置皮肤，不允许链式继承。** 这一条限制直接消灭了环检测、
      // 深度限制和拓扑排序，而"基于另一个第三方皮肤改"这个需求在实践中
      // 等价于"把它下载下来改一份"。
      final found = ChatSkinCatalog.builtIns.where((s) => s.id == extendsId);
      if (found.isEmpty) {
        warnings.add('extends 指向的 "$extendsId" 不是内置皮肤，已改用默认皮肤作基座');
      } else {
        base = found.first;
      }
    }

    // ---- 变量 ----
    final varsRaw = json['vars'];
    final vars = SkinVars(
      varsRaw is Map ? varsRaw.cast<String, Object?>() : const {},
    );

    // ---- 令牌 ----
    final tokensRaw = json['tokens'];
    var lightTokens = base.lightTokens;
    var darkTokens = base.darkTokens;
    if (tokensRaw is Map) {
      final shared = tokensRaw['all'];
      Map<String, Object?> forMode(Object? mode) => <String, Object?>{
            if (shared is Map) ...shared.cast<String, Object?>(),
            if (mode is Map) ...mode.cast<String, Object?>(),
          };
      lightTokens = lightTokens.applyOverrides(
        forMode(tokensRaw['light']),
        vars.color,
        onWarning: (m) => warnings.add('亮色：$m'),
      );
      darkTokens = darkTokens.applyOverrides(
        forMode(tokensRaw['dark']),
        vars.color,
        onWarning: (m) => warnings.add('暗色：$m'),
      );
    } else if (tokensRaw != null) {
      warnings.add('tokens 必须是一个对象，已忽略');
    }

    // ---- 部件 ----
    final partsRaw = json['parts'];
    var lightParts = base.lightParts;
    var darkParts = base.darkParts;
    if (partsRaw is Map) {
      final map = partsRaw.cast<String, Object?>();
      final resolver = SkinPartsResolver(
        raw: map,
        vars: vars,
        assetRoot: assetRoot,
      );
      lightParts = resolver.resolve(Brightness.light, base.lightParts);
      darkParts = resolver.resolve(Brightness.dark, base.darkParts);
      warnings.addAll(resolver.warnings);
    } else if (partsRaw != null) {
      warnings.add('parts 必须是一个对象，已忽略');
    }

    warnings.addAll(vars.warnings);

    // ---- 对比度闸门 ----
    //
    // 放在最后：前面的兜底已经把能修的都修了，到这里还不达标的就是作者
    // **确实**把字和背景写成了一个色。导入是一次显式操作，在这里报错的
    // 代价最低 —— 等它成为活动主题再发现，用户就已经看不见界面了。
    for (final (label, tokens) in <(String, ChatTokens)>[
      ('亮色', lightTokens),
      ('暗色', darkTokens),
    ]) {
      final checks = <(String, Color, Color)>[
        ('正文与页面底色', tokens.tintPrimary, tokens.bgPrimary),
        ('收到消息的文字与气泡', tokens.tintOnIn, tokens.bubbleIn),
        ('发出消息的文字与气泡', tokens.tintOnOut, tokens.bubbleOut),
      ];
      for (final (what, fg, bg) in checks) {
        if (skinContrast(fg, bg) < _minContrast) {
          errors.add('$label的「$what」几乎没有对比度，这样界面会读不了');
        }
      }
    }

    if (errors.isNotEmpty) {
      return SkinManifestResult(errors: errors, warnings: warnings);
    }

    // ---- 预览色 ----
    //
    // 缺省时从令牌推导。让只想改几个颜色的作者不必再手挑三个代表色。
    final previewRaw = json['preview'];
    var preview = <Color>[];
    if (previewRaw is List) {
      for (final entry in previewRaw.take(3)) {
        final color = vars.color(entry);
        if (color != null) preview.add(color);
      }
    }
    if (preview.length < 3) {
      preview = <Color>[
        darkTokens.wallpaperTop,
        darkTokens.bubbleOut,
        darkTokens.brand,
      ];
    }

    return SkinManifestResult(
      warnings: warnings,
      pack: ChatSkinPack(
        id: id,
        name: name,
        description: (json['description'] as String? ?? '').trim(),
        author: (json['author'] as String? ?? '').trim(),
        schemaVersion: schema,
        lightTokens: lightTokens,
        darkTokens: darkTokens,
        lightParts: lightParts,
        darkParts: darkParts,
        previewColors: preview,
        installPath: assetRoot,
        warnings: warnings,
      ),
    );
  }

  /// 把一套令牌导出成 manifest 的 `tokens` 块。
  ///
  /// 「导出当前外观为皮肤包」用它。这个函数存在的一半理由是它让
  /// 导出 → 导入 → 令牌逐一相等 成为一条可写的端到端测试。
  static Map<String, Object?> exportTokens(ChatTokens tokens) =>
      <String, Object?>{
        for (final name in ChatTokens.tokenNames)
          name: _hex(tokens.named(name)!),
      };

  static String _hex(Color c) {
    final value = c.toARGB32();
    final rgb = (value & 0xFFFFFF).toRadixString(16).padLeft(6, '0');
    final alpha = (value >>> 24) & 0xFF;
    return alpha == 0xFF
        ? '#$rgb'
        : '#${alpha.toRadixString(16).padLeft(2, '0')}$rgb';
  }
}
