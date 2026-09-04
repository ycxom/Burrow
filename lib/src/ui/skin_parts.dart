/// 聊天页的部件表：皮肤包能选中的每一个可见元素，以及它们的版式开关。
///
/// ## 部件名是公开 API
///
/// 一旦有人照着这张表写了皮肤包并发出去，这些名字就改不动了。所以它们对应的
/// 是**视觉概念**（气泡、顶栏、输入底座），不是当前的 widget 类名 —— 内部重构
/// 不该让别人的皮肤包失效。
///
/// ## 继承
///
/// 点号**不是**通用的层级继承，只有两个明确的抽象基：
///
///   - `bubble`   → `bubble.in` / `bubble.out` / `bubble.error`
///   - `avatar`   → `avatar.assistant` / `avatar.user`
///
/// 其余部件（`header` 和 `header.title`、`composer` 和 `composer.dock`）**互不
/// 继承**。让 `header.title` 继承 `header` 听起来更规整，实际后果是给顶栏加一层
/// 毛玻璃会把标题也变成毛玻璃 —— 规整的规则在这里给出的是错误答案。
///
/// ## 为什么是结构体不是 Map
///
/// 一屏消息会取几百次样式。`parts['bubble.out']` 意味着每次都做字符串哈希，
/// 滚动时会显形。所以 JSON 里的名字在**加载时**就被解析成下面这些字段，
/// 渲染路径上一个字符串都不剩。
library;

import 'package:flutter/material.dart';

import 'skin_style.dart';
import 'skin_vars.dart';

/// 气泡的整体形态。
enum SkinBubbleLayout {
  /// Telegram 那样带尾巴，一组消息只有最后一条画尾。
  tail,

  /// 无尾的圆角块，四角一致。
  plain,

  /// 卡片：无尾、更强的阴影和边框、更宽。
  card,
}

/// 时间戳的位置。
enum SkinTimePosition {
  /// 压在气泡右下角，正文绕着它排（默认）。
  inside,

  /// 气泡外面下方一行。
  outside,

  hidden,
}

/// 头像的位置。
enum SkinAvatarPosition {
  /// 气泡侧边（默认）。
  side,

  /// 不显示，气泡贴回屏幕两侧。
  none,
}

/// 输入区的贴附方式。
enum SkinComposerMode {
  /// 悬浮在壁纸上（默认）。
  floating,

  /// 贴着底边，无外边距。
  docked,
}

/// 顶栏的形态。
enum SkinHeaderStyle {
  /// 实心栏（默认）。
  bar,

  /// 透明，内容从它下面穿过去。
  transparent,
}

/// 一整套已解析好的部件样式。亮色和暗色各持有一份。
@immutable
class ChatSkinParts extends ThemeExtension<ChatSkinParts> {
  const ChatSkinParts({
    this.shellBackground = PartStyle.empty,
    this.header = PartStyle.empty,
    this.headerTitle = PartStyle.empty,
    this.headerSubtitle = PartStyle.empty,
    this.headerAvatar = PartStyle.empty,
    this.headerAction = PartStyle.empty,
    this.headerDrawer = PartStyle.empty,
    this.list = PartStyle.empty,
    this.bubbleIn = PartStyle.empty,
    this.bubbleOut = PartStyle.empty,
    this.bubbleError = PartStyle.empty,
    this.bubbleTime = PartStyle.empty,
    this.bubbleTail = PartStyle.empty,
    this.avatarAssistant = PartStyle.empty,
    this.avatarUser = PartStyle.empty,
    this.datePill = PartStyle.empty,
    this.composerDock = PartStyle.empty,
    this.composerField = PartStyle.empty,
    this.composerSend = PartStyle.empty,
    this.composerIcon = PartStyle.empty,
    this.bubbleLayout = SkinBubbleLayout.tail,
    this.timePosition = SkinTimePosition.inside,
    this.avatarPosition = SkinAvatarPosition.side,
    this.composerMode = SkinComposerMode.floating,
    this.headerStyle = SkinHeaderStyle.bar,
  });

  static const fallback = ChatSkinParts();

  final PartStyle shellBackground;
  final PartStyle header;
  final PartStyle headerTitle;
  final PartStyle headerSubtitle;
  final PartStyle headerAvatar;
  final PartStyle headerAction;

  /// 抽屉入口。**必留部件** —— 样式随便改，但不能不显示。
  final PartStyle headerDrawer;

  final PartStyle list;
  final PartStyle bubbleIn;
  final PartStyle bubbleOut;
  final PartStyle bubbleError;
  final PartStyle bubbleTime;

  /// 气泡尾巴。只认 `size`（尾巴宽度）和 `visible`。
  final PartStyle bubbleTail;

  final PartStyle avatarAssistant;
  final PartStyle avatarUser;
  final PartStyle datePill;
  final PartStyle composerDock;

  /// 输入框本体。**必留部件**。
  final PartStyle composerField;

  final PartStyle composerSend;
  final PartStyle composerIcon;

  final SkinBubbleLayout bubbleLayout;
  final SkinTimePosition timePosition;
  final SkinAvatarPosition avatarPosition;
  final SkinComposerMode composerMode;
  final SkinHeaderStyle headerStyle;

  PartStyle bubbleFor({required bool outgoing, required bool isError}) =>
      isError ? bubbleError : (outgoing ? bubbleOut : bubbleIn);

  @override
  ChatSkinParts copyWith() => this;

  /// 皮肤切换不做插值。
  ///
  /// 逐属性 lerp 两套**结构不同**的样式（一个带尾巴一个是卡片、一个有渐变一个
  /// 是纯色）中间帧会是两边都不像的第三种东西。直接在中点跳过去，比一段
  /// 半秒钟的"看起来像 bug"要好。
  @override
  ChatSkinParts lerp(ThemeExtension<ChatSkinParts>? other, double t) {
    if (other is! ChatSkinParts) return this;
    return t < 0.5 ? this : other;
  }
}

/// 部件名 → 结构体字段的写入器。这张表是格式和代码之间唯一的对照点。
typedef _PartSlot = ChatSkinParts Function(ChatSkinParts base, PartStyle style);

/// 抽象基。它们自己不被渲染，只把属性流给下面的叶子部件。
const _abstractBases = <String, List<String>>{
  'bubble': <String>['bubble.in', 'bubble.out', 'bubble.error'],
  'avatar': <String>['avatar.assistant', 'avatar.user'],
};

/// 必须存在、不能被隐藏的部件。见 [PartStyle.clampAsRequired]。
const skinRequiredParts = <String>{'header.drawer', 'composer.field'};

final Map<String, _PartSlot> _slots = <String, _PartSlot>{
  'shell.background': (b, s) => _copy(b, shellBackground: s),
  'header': (b, s) => _copy(b, header: s),
  'header.title': (b, s) => _copy(b, headerTitle: s),
  'header.subtitle': (b, s) => _copy(b, headerSubtitle: s),
  'header.avatar': (b, s) => _copy(b, headerAvatar: s),
  'header.action': (b, s) => _copy(b, headerAction: s),
  'header.drawer': (b, s) => _copy(b, headerDrawer: s),
  'list': (b, s) => _copy(b, list: s),
  'bubble.in': (b, s) => _copy(b, bubbleIn: s),
  'bubble.out': (b, s) => _copy(b, bubbleOut: s),
  'bubble.error': (b, s) => _copy(b, bubbleError: s),
  'bubble.time': (b, s) => _copy(b, bubbleTime: s),
  'bubble.tail': (b, s) => _copy(b, bubbleTail: s),
  'avatar.assistant': (b, s) => _copy(b, avatarAssistant: s),
  'avatar.user': (b, s) => _copy(b, avatarUser: s),
  'date.pill': (b, s) => _copy(b, datePill: s),
  'composer.dock': (b, s) => _copy(b, composerDock: s),
  'composer.field': (b, s) => _copy(b, composerField: s),
  'composer.send': (b, s) => _copy(b, composerSend: s),
  'composer.icon': (b, s) => _copy(b, composerIcon: s),
};

/// 皮肤包可以写的所有部件名，给外观页的报错提示用。
List<String> get skinPartNames =>
    <String>[..._abstractBases.keys, ..._slots.keys]..sort();

/// 把皮肤包的 `parts` 块解析成两套结构体（亮色一套、暗色一套）。
///
/// 状态和明暗都写成 `:` 修饰符：`bubble.out:first`、`header:dark`。明暗在这里
/// 就被摊平成两份结果，所以渲染时不需要再判断当前是什么模式。
class SkinPartsResolver {
  SkinPartsResolver({
    required this.raw,
    required this.vars,
    this.assetRoot,
  });

  final Map<String, Object?> raw;
  final SkinVars vars;
  final String? assetRoot;

  final List<String> warnings = <String>[];

  /// 已解析的 `名字:修饰符` → 样式。修饰符为空表示无条件那份。
  final Map<String, PartStyle> _declared = <String, PartStyle>{};

  ChatSkinParts resolve(Brightness brightness, ChatSkinParts base) {
    _declared.clear();
    final theme = brightness == Brightness.dark ? 'dark' : 'light';

    for (final entry in raw.entries) {
      final value = entry.value;
      if (value is! Map) {
        warnings.add('部件 ${entry.key} 的样式必须是一个对象');
        continue;
      }
      final selector = _Selector.parse(entry.key);
      if (selector == null) {
        warnings.add('无法解析的部件选择器：${entry.key}');
        continue;
      }
      if (!_slots.containsKey(selector.part) &&
          !_abstractBases.containsKey(selector.part)) {
        warnings.add('未知部件：${selector.part}');
        continue;
      }
      // 明暗修饰符在这一步就筛掉：`header:dark` 只参与暗色那一遍。
      if (selector.theme != null && selector.theme != theme) continue;

      final style = PartStyle.parse(
        value.cast<String, Object?>(),
        vars,
        assetRoot: assetRoot,
      );
      final key = '${selector.part}:${selector.state?.name ?? ''}';
      final existing = _declared[key];
      _declared[key] = existing == null ? style : existing.merge(style);
    }

    var result = base;
    for (final entry in _slots.entries) {
      final style = _compose(entry.key);
      if (style != null) result = entry.value(result, style);
    }
    return _applyLayout(result);
  }

  /// 合成一个叶子部件的最终样式：先沿继承链叠无条件样式，再为每个状态叠一遍。
  PartStyle? _compose(String part) {
    final chain = <String>[
      for (final base in _abstractBases.entries)
        if (base.value.contains(part)) base.key,
      part,
    ];

    PartStyle? plain;
    for (final name in chain) {
      final style = _declared['$name:'];
      if (style != null) plain = plain == null ? style : plain.merge(style);
    }

    List<PartStyle?>? states;
    for (final state in SkinState.values) {
      PartStyle? merged = plain;
      var touched = false;
      for (final name in chain) {
        final style = _declared['$name:${state.name}'];
        if (style == null) continue;
        touched = true;
        merged = merged == null ? style : merged.merge(style);
      }
      if (!touched) continue;
      states ??= List<PartStyle?>.filled(SkinState.values.length, null);
      states[state.index] = merged;
    }

    if (plain == null && states == null) return null;
    final result = plain ?? PartStyle.empty;
    final withStates = states == null ? result : result.withStates(states);
    // 必留部件在这里就被钳过一次。放在渲染层钳的话，每个用到它的地方都要
    // 记得钳一次，而"忘了钳"是没有任何征兆的。
    return skinRequiredParts.contains(part)
        ? withStates.clampAsRequired()
        : withStates;
  }

  ChatSkinParts _applyLayout(ChatSkinParts base) {
    final layout = raw['layout'];
    if (layout is! Map) return base;
    T pick<T>(String key, Map<String, T> table, T fallback) {
      final value = layout[key];
      if (value == null) return fallback;
      final result = table[value];
      if (result == null) {
        warnings.add('layout.$key 不认识的取值：$value');
        return fallback;
      }
      return result;
    }

    return _copy(
      base,
      bubbleLayout: pick(
          'bubble',
          const <String, SkinBubbleLayout>{
            'tail': SkinBubbleLayout.tail,
            'plain': SkinBubbleLayout.plain,
            'card': SkinBubbleLayout.card,
          },
          base.bubbleLayout),
      timePosition: pick(
          'time',
          const <String, SkinTimePosition>{
            'inside': SkinTimePosition.inside,
            'outside': SkinTimePosition.outside,
            'hidden': SkinTimePosition.hidden,
          },
          base.timePosition),
      avatarPosition: pick(
          'avatar',
          const <String, SkinAvatarPosition>{
            'side': SkinAvatarPosition.side,
            'none': SkinAvatarPosition.none,
          },
          base.avatarPosition),
      composerMode: pick(
          'composer',
          const <String, SkinComposerMode>{
            'floating': SkinComposerMode.floating,
            'docked': SkinComposerMode.docked,
          },
          base.composerMode),
      headerStyle: pick(
          'header',
          const <String, SkinHeaderStyle>{
            'bar': SkinHeaderStyle.bar,
            'transparent': SkinHeaderStyle.transparent,
          },
          base.headerStyle),
    );
  }
}

/// `bubble.out:first` 拆成部件名 + 状态（或明暗）。
class _Selector {
  const _Selector(this.part, this.state, this.theme);

  final String part;
  final SkinState? state;
  final String? theme;

  static _Selector? parse(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    final colon = text.indexOf(':');
    if (colon < 0) return _Selector(text, null, null);
    final part = text.substring(0, colon).trim();
    final modifier = text.substring(colon + 1).trim();
    if (part.isEmpty || modifier.isEmpty) return null;
    if (modifier == 'dark' || modifier == 'light') {
      return _Selector(part, null, modifier);
    }
    final state = skinStateFromName(modifier);
    return state == null ? null : _Selector(part, state, null);
  }
}

ChatSkinParts _copy(
  ChatSkinParts b, {
  PartStyle? shellBackground,
  PartStyle? header,
  PartStyle? headerTitle,
  PartStyle? headerSubtitle,
  PartStyle? headerAvatar,
  PartStyle? headerAction,
  PartStyle? headerDrawer,
  PartStyle? list,
  PartStyle? bubbleIn,
  PartStyle? bubbleOut,
  PartStyle? bubbleError,
  PartStyle? bubbleTime,
  PartStyle? bubbleTail,
  PartStyle? avatarAssistant,
  PartStyle? avatarUser,
  PartStyle? datePill,
  PartStyle? composerDock,
  PartStyle? composerField,
  PartStyle? composerSend,
  PartStyle? composerIcon,
  SkinBubbleLayout? bubbleLayout,
  SkinTimePosition? timePosition,
  SkinAvatarPosition? avatarPosition,
  SkinComposerMode? composerMode,
  SkinHeaderStyle? headerStyle,
}) =>
    ChatSkinParts(
      shellBackground: shellBackground ?? b.shellBackground,
      header: header ?? b.header,
      headerTitle: headerTitle ?? b.headerTitle,
      headerSubtitle: headerSubtitle ?? b.headerSubtitle,
      headerAvatar: headerAvatar ?? b.headerAvatar,
      headerAction: headerAction ?? b.headerAction,
      headerDrawer: headerDrawer ?? b.headerDrawer,
      list: list ?? b.list,
      bubbleIn: bubbleIn ?? b.bubbleIn,
      bubbleOut: bubbleOut ?? b.bubbleOut,
      bubbleError: bubbleError ?? b.bubbleError,
      bubbleTime: bubbleTime ?? b.bubbleTime,
      bubbleTail: bubbleTail ?? b.bubbleTail,
      avatarAssistant: avatarAssistant ?? b.avatarAssistant,
      avatarUser: avatarUser ?? b.avatarUser,
      datePill: datePill ?? b.datePill,
      composerDock: composerDock ?? b.composerDock,
      composerField: composerField ?? b.composerField,
      composerSend: composerSend ?? b.composerSend,
      composerIcon: composerIcon ?? b.composerIcon,
      bubbleLayout: bubbleLayout ?? b.bubbleLayout,
      timePosition: timePosition ?? b.timePosition,
      avatarPosition: avatarPosition ?? b.avatarPosition,
      composerMode: composerMode ?? b.composerMode,
      headerStyle: headerStyle ?? b.headerStyle,
    );

extension ChatSkinPartsX on BuildContext {
  /// 取当前主题下的部件样式。
  ///
  /// 和 `context.chat` 一样，没注册扩展时兜底到默认值而不是抛异常 ——
  /// 某个页面忘了套主题不该是崩溃。
  ChatSkinParts get parts =>
      Theme.of(this).extension<ChatSkinParts>() ?? ChatSkinParts.fallback;
}
