/// 一个会话自己的模型策略：用哪个渠道的哪个模型、想多久、温度多少。
///
/// ## 为什么要按会话存
///
/// 以前这几样全是全局的：所有会话共用「当前渠道 + 当前模型 + 一个思考强度
/// + 一个温度」。于是**换一次模型，所有会话跟着换** —— 而一个人手里的会话
/// 本来就不是同一类活：一个在写代码要低温度和高思考，一个在闲聊要高温度，
/// 一个连着本地小模型只为跑命令。每开一个就得把三个旋钮重调一遍，
/// 而且调完上一个会话也被改了。
///
/// 所以它们跟着会话走。设置页里那几项退化成**新会话的起点**。
///
/// ## null 是「跟着全局」，不是「没有」
///
/// 每个字段都可空，空 = 这一项没单独设过。区分得出来才能做到「新建会话
/// 沿用你惯用的那套，而改了全局不会把已有会话搅乱」—— 会话建出来的那一刻
/// 会把当时的全局值定下来（见 app.dart 的 `_pinPrefs`），之后各走各的。
library;

import 'package:flutter/foundation.dart';

import '../llm/sampling.dart';
import '../llm/thinking_effort.dart';

@immutable
class ThreadPrefs {
  const ThreadPrefs({
    this.channelId,
    this.model,
    this.thinkingEffort,
    this.temperature,
    this.sampling = SamplingParams.none,
  });

  /// 这个会话发往哪个渠道。null = 跟当前渠道。
  ///
  /// 存 id 不存名字：渠道随时会被改名，而"当初指的是哪个"不该跟着变。
  final String? channelId;

  /// 这个会话用哪个模型。null = 跟那个渠道自己配的。
  final String? model;

  final ThinkingEffort? thinkingEffort;

  /// 0–2。各协议上界不同，夹取交给调用方 —— 这里只负责存。
  final double? temperature;

  /// 极客设置。和上面几项不同，它**没有全局默认可跟** —— 空就是空，
  /// 一个字段都不发（见 llm/sampling.dart）。
  ///
  /// 不给它做全局默认是有意的：一个从没被设过的全局 top_p 只是负担，
  /// 而这几项本来就是"这一次要这样"的东西，跟着会话走正合适。
  final SamplingParams sampling;

  bool get isEmpty =>
      channelId == null &&
      model == null &&
      thinkingEffort == null &&
      temperature == null &&
      sampling.isEmpty;

  ThreadPrefs copyWith({
    String? channelId,
    String? model,
    ThinkingEffort? thinkingEffort,
    double? temperature,
    SamplingParams? sampling,
  }) =>
      ThreadPrefs(
        channelId: channelId ?? this.channelId,
        model: model ?? this.model,
        thinkingEffort: thinkingEffort ?? this.thinkingEffort,
        temperature: temperature ?? this.temperature,
        sampling: sampling ?? this.sampling,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        // 只写设过的。写 null 进去分不出"设成空"和"没设过"，
        // 而这两件事在这里是不同的意思。
        if (channelId != null) 'channel': channelId,
        if (model != null) 'model': model,
        if (thinkingEffort != null) 'thinking': thinkingEffort!.storage,
        if (temperature != null) 'temperature': temperature,
        if (!sampling.isEmpty) 'sampling': sampling.toJson(),
      };

  static ThreadPrefs fromJson(Object? raw) {
    if (raw is! Map) return const ThreadPrefs();
    final temperature = raw['temperature'];
    return ThreadPrefs(
      channelId: raw['channel'] as String?,
      model: raw['model'] as String?,
      // 认不出来的档位当成没设过，而不是落到「自动」。
      //
      // 不能借 [ThinkingEffort.fromStorage]：它对任何不认识的字符串都答
      // `auto`，而在这里 auto 是一个**有意义的档位**（"一个参数都不发"）。
      // 借了的话，一个打错的值会把用户明确调过的高思考悄悄关掉，
      // 而且看起来就像他自己选了自动。
      thinkingEffort: _thinkingFrom(raw['thinking']),
      temperature: temperature is num ? temperature.toDouble() : null,
      sampling: SamplingParams.fromJson(raw['sampling']),
    );
  }

  static ThinkingEffort? _thinkingFrom(Object? raw) {
    if (raw is! String) return null;
    for (final effort in ThinkingEffort.values) {
      if (effort.storage == raw) return effort;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is ThreadPrefs &&
      other.channelId == channelId &&
      other.model == model &&
      other.thinkingEffort == thinkingEffort &&
      other.temperature == temperature &&
      other.sampling == sampling;

  @override
  int get hashCode =>
      Object.hash(channelId, model, thinkingEffort, temperature, sampling);
}
