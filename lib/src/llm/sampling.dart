/// 采样参数里那几个"知道自己在干什么才该动"的旋钮。
///
/// ## 为什么每一项都是可空的
///
/// **null = 这一项一个字段都不发**，让服务端用它自己的默认值。
///
/// 这不是省事，是唯一安全的做法。这些字段各家支持得参差不齐：`top_k` 在
/// OpenAI 兼容层根本不存在，`seed` 只有一部分网关认，`frequency_penalty`
/// 送给 Anthropic 会直接 400。挑一个"合理默认值"无条件发出去，等于把每个
/// 用户的每一轮对话都押在"这个网关恰好认识这个字段"上 —— 而它不认识的
/// 表现是整轮请求失败，不是悄悄忽略。
///
/// 反过来，只发用户主动设过的：没碰过极客设置的人，请求体和加这个功能之前
/// 一模一样；碰过的人撞上 400 时，他知道自己刚动了什么。
///
/// ## 各协议认哪些
///
/// 这张表是这个文件存在的全部理由 —— 界面上要照它标出"这个渠道不认"，
/// 不然用户设了 `top_k` 却发现毫无变化，只会以为是坏了。
///
/// | 旋钮       | openAI | anthropic | gemini | responses |
/// |------------|--------|-----------|--------|-----------|
/// | top_p      | ✓      | ✓         | ✓      | ✓         |
/// | top_k      | ✗      | ✓         | ✓      | ✗         |
/// | 输出上限   | ✓      | ✓         | ✓      | ✓         |
/// | 频率惩罚   | ✓      | ✗         | ✓      | ✗         |
/// | 存在惩罚   | ✓      | ✗         | ✓      | ✗         |
/// | seed       | ✓      | ✗         | ✓      | ✗         |
/// | 停止词     | ✓      | ✓         | ✓      | ✗         |
library;

import 'package:flutter/foundation.dart';

/// 一个协议认得哪些旋钮。
enum SamplingKnob {
  topP('top_p', 'Top P'),
  topK('top_k', 'Top K'),
  maxTokens('max_tokens', '输出上限'),
  frequencyPenalty('frequency_penalty', '频率惩罚'),
  presencePenalty('presence_penalty', '存在惩罚'),
  seed('seed', '随机种子'),
  stopSequences('stop', '停止词');

  const SamplingKnob(this.wire, this.label);

  /// 存进 JSON 用的名字。**不用 `name`** —— 枚举改名不该让老数据读不出来。
  final String wire;
  final String label;
}

/// [apiFormat] 这个协议真的会发出去的那些旋钮。
///
/// 认不出来的协议按 openAI 兼容算：绝大多数网关都是那一套，而这个函数只
/// 决定界面上标不标"不认"，猜错的代价是一句多余的提示。
Set<SamplingKnob> knobsFor(String apiFormat) => switch (apiFormat) {
      'anthropic' => const <SamplingKnob>{
          SamplingKnob.topP,
          SamplingKnob.topK,
          SamplingKnob.maxTokens,
          SamplingKnob.stopSequences,
        },
      'gemini' || 'geminiNative' => SamplingKnob.values.toSet(),
      // ChatGPT 的 Codex 后端对请求体极其挑剔，多一个字段就 400。
      // 只放它文档里写明的那两个。
      'chatgptOAuth' => const <SamplingKnob>{
          SamplingKnob.topP,
          SamplingKnob.maxTokens,
        },
      _ => const <SamplingKnob>{
          SamplingKnob.topP,
          SamplingKnob.maxTokens,
          SamplingKnob.frequencyPenalty,
          SamplingKnob.presencePenalty,
          SamplingKnob.seed,
          SamplingKnob.stopSequences,
        },
    };

@immutable
class SamplingParams {
  const SamplingParams({
    this.topP,
    this.topK,
    this.maxTokens,
    this.frequencyPenalty,
    this.presencePenalty,
    this.seed,
    this.stopSequences = const <String>[],
  });

  /// 核采样。0–1，越小越保守。
  final double? topP;

  /// 每一步只在概率最高的 K 个词里挑。OpenAI 兼容层没有这个字段。
  final int? topK;

  /// 一轮最多生成多少 token。
  final int? maxTokens;

  /// −2–2。越高越不爱重复用过的词。
  final double? frequencyPenalty;

  /// −2–2。越高越不爱重复已经出现过的话题。
  final double? presencePenalty;

  /// 固定随机种子。同样的输入 + 同样的种子 ≈ 同样的输出。
  ///
  /// "≈"是认真的：没有哪家保证过它，浮点累加顺序和后端调度都会让它偏。
  final int? seed;

  /// 撞上其中任何一条就停。空 = 不发这个字段。
  final List<String> stopSequences;

  static const none = SamplingParams();

  bool get isEmpty =>
      topP == null &&
      topK == null &&
      maxTokens == null &&
      frequencyPenalty == null &&
      presencePenalty == null &&
      seed == null &&
      stopSequences.isEmpty;

  /// 用户设过的那些旋钮。界面上用来数"改了几项"。
  Set<SamplingKnob> get touched => <SamplingKnob>{
        if (topP != null) SamplingKnob.topP,
        if (topK != null) SamplingKnob.topK,
        if (maxTokens != null) SamplingKnob.maxTokens,
        if (frequencyPenalty != null) SamplingKnob.frequencyPenalty,
        if (presencePenalty != null) SamplingKnob.presencePenalty,
        if (seed != null) SamplingKnob.seed,
        if (stopSequences.isNotEmpty) SamplingKnob.stopSequences,
      };

  /// 设过、但 [apiFormat] 这个协议根本不会发的那些。
  ///
  /// 界面拿它提示"这几项在当前渠道上不起作用"。设了却没反应而没人说一声，
  /// 是这类高级设置最常见的坑。
  Set<SamplingKnob> ignoredBy(String apiFormat) =>
      touched.difference(knobsFor(apiFormat));

  SamplingParams copyWith({
    double? topP,
    int? topK,
    int? maxTokens,
    double? frequencyPenalty,
    double? presencePenalty,
    int? seed,
    List<String>? stopSequences,
  }) =>
      SamplingParams(
        topP: topP ?? this.topP,
        topK: topK ?? this.topK,
        maxTokens: maxTokens ?? this.maxTokens,
        frequencyPenalty: frequencyPenalty ?? this.frequencyPenalty,
        presencePenalty: presencePenalty ?? this.presencePenalty,
        seed: seed ?? this.seed,
        stopSequences: stopSequences ?? this.stopSequences,
      );

  /// 把某一项**清回"不发"**。
  ///
  /// [copyWith] 做不到这件事：它的 `??` 把"传了 null"和"没传"当成同一回事，
  /// 而这里恰恰要区分 —— 用户点"恢复默认"要的就是把那一项设成 null。
  SamplingParams clear(SamplingKnob knob) => SamplingParams(
        topP: knob == SamplingKnob.topP ? null : topP,
        topK: knob == SamplingKnob.topK ? null : topK,
        maxTokens: knob == SamplingKnob.maxTokens ? null : maxTokens,
        frequencyPenalty:
            knob == SamplingKnob.frequencyPenalty ? null : frequencyPenalty,
        presencePenalty:
            knob == SamplingKnob.presencePenalty ? null : presencePenalty,
        seed: knob == SamplingKnob.seed ? null : seed,
        stopSequences: knob == SamplingKnob.stopSequences
            ? const <String>[]
            : stopSequences,
      );

  // ---- 线格式 ----
  //
  // 每一个都返回"要并进请求体的那几个键"，一项都没设时返回空 Map ——
  // 调用方 `...params.openAiFields()` 展开，请求体和没有这个功能时逐字相同。

  Map<String, Object?> openAiFields() => <String, Object?>{
        if (topP != null) 'top_p': topP,
        // 用 `max_tokens` 而不是新的 `max_completion_tokens`：这一项主要是
        // 给 Ollama / llama.cpp / vLLM / 各家网关用的，它们认的是老名字。
        // OpenAI 官方最新那几个推理模型只认新名字 —— 那种情况下设了会 400，
        // 而错误信息里会直接点出这个字段名。
        if (maxTokens != null) 'max_tokens': maxTokens,
        if (frequencyPenalty != null) 'frequency_penalty': frequencyPenalty,
        if (presencePenalty != null) 'presence_penalty': presencePenalty,
        if (seed != null) 'seed': seed,
        if (stopSequences.isNotEmpty) 'stop': stopSequences,
      };

  /// Anthropic。**不含 `max_tokens`** —— 那一项在那边是必填的，
  /// 而且开了扩展思考之后要和思考预算一起算，交给 [anthropicMaxTokens]。
  Map<String, Object?> anthropicFields() => <String, Object?>{
        if (topP != null) 'top_p': topP,
        if (topK != null) 'top_k': topK,
        if (stopSequences.isNotEmpty) 'stop_sequences': stopSequences,
      };

  /// Anthropic 的 `max_tokens`。它是必填的，所以这里总要给出一个数。
  ///
  /// [thinkingMaxTokens] 是开了扩展思考时算出来的下限（思考预算 + 答案余量）。
  /// 用户设的上限比它还小的话得让位：max_tokens 不大于 budget_tokens 会被
  /// 直接 400，而那个错的字面意思和用户刚才调的那一项对不上。
  int anthropicMaxTokens({int? thinkingMaxTokens, int fallback = 4096}) {
    final wanted = maxTokens ?? fallback;
    if (thinkingMaxTokens == null) return wanted;
    return wanted > thinkingMaxTokens ? wanted : thinkingMaxTokens;
  }

  /// Gemini 的 `generationConfig` 里那几项。
  Map<String, Object?> geminiFields() => <String, Object?>{
        if (topP != null) 'topP': topP,
        if (topK != null) 'topK': topK,
        if (maxTokens != null) 'maxOutputTokens': maxTokens,
        if (frequencyPenalty != null) 'frequencyPenalty': frequencyPenalty,
        if (presencePenalty != null) 'presencePenalty': presencePenalty,
        if (seed != null) 'seed': seed,
        if (stopSequences.isNotEmpty) 'stopSequences': stopSequences,
      };

  /// OpenAI Responses（ChatGPT Codex 后端）。
  Map<String, Object?> responsesFields() => <String, Object?>{
        if (topP != null) 'top_p': topP,
        if (maxTokens != null) 'max_output_tokens': maxTokens,
      };

  // ---- 存盘 ----

  Map<String, Object?> toJson() => <String, Object?>{
        for (final entry in <SamplingKnob, Object?>{
          SamplingKnob.topP: topP,
          SamplingKnob.topK: topK,
          SamplingKnob.maxTokens: maxTokens,
          SamplingKnob.frequencyPenalty: frequencyPenalty,
          SamplingKnob.presencePenalty: presencePenalty,
          SamplingKnob.seed: seed,
        }.entries)
          if (entry.value != null) entry.key.wire: entry.value,
        if (stopSequences.isNotEmpty)
          SamplingKnob.stopSequences.wire: stopSequences,
      };

  static SamplingParams fromJson(Object? raw) {
    if (raw is! Map) return none;
    double? real(SamplingKnob knob) {
      final value = raw[knob.wire];
      return value is num ? value.toDouble() : null;
    }

    int? whole(SamplingKnob knob) {
      final value = raw[knob.wire];
      // 存的时候是 int，但经过 JSON 之后 1.0 也可能变回 double。
      return value is num ? value.round() : null;
    }

    final stop = raw[SamplingKnob.stopSequences.wire];
    return SamplingParams(
      topP: real(SamplingKnob.topP),
      topK: whole(SamplingKnob.topK),
      maxTokens: whole(SamplingKnob.maxTokens),
      frequencyPenalty: real(SamplingKnob.frequencyPenalty),
      presencePenalty: real(SamplingKnob.presencePenalty),
      seed: whole(SamplingKnob.seed),
      stopSequences: stop is List
          ? stop.whereType<String>().where((s) => s.isNotEmpty).toList()
          : const <String>[],
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SamplingParams &&
      other.topP == topP &&
      other.topK == topK &&
      other.maxTokens == maxTokens &&
      other.frequencyPenalty == frequencyPenalty &&
      other.presencePenalty == presencePenalty &&
      other.seed == seed &&
      listEquals(other.stopSequences, stopSequences);

  @override
  int get hashCode => Object.hash(
        topP,
        topK,
        maxTokens,
        frequencyPenalty,
        presencePenalty,
        seed,
        Object.hashAll(stopSequences),
      );
}
