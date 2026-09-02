/// 思考强度：让模型少想一点或者多想一点。
///
/// **四家服务表达这件事的方式完全不同**，而用户不该为了调一个旋钮先去读四份
/// 文档。这里把它统一成五档，各协议自己翻译：
///
///   - OpenAI 系（`/chat/completions` 和 Responses）：`reasoning_effort`
///     字符串档位。
///   - Gemini 2.5：`thinkingBudget`，一个**token 数**，而且各型号的上下界
///     还不一样（Pro 关不掉，最低 128）。
///   - Gemini 3：换成了 `thinkingLevel`，而且只有两档。
///   - Anthropic：`budget_tokens`，最低 1024，还要求 `max_tokens` 比它大、
///     `temperature` 必须是 1。
///
/// 默认是 [auto] —— **什么都不发**。这一条很重要：`reasoning_effort` 发给一个
/// 不会思考的模型，OpenAI 会直接 400 退回来。默认不发的话，没主动调过这个
/// 旋钮的用户永远不会撞上它。
library;

enum ThinkingEffort {
  /// 不发任何参数，服务端自己决定。
  auto,

  /// 尽量别想，直接答。
  off,
  low,
  medium,
  high;

  String get label => switch (this) {
        ThinkingEffort.auto => '自动',
        ThinkingEffort.off => '关闭',
        ThinkingEffort.low => '低',
        ThinkingEffort.medium => '中',
        ThinkingEffort.high => '高',
      };

  String get hint => switch (this) {
        ThinkingEffort.auto => '不干预，用服务端的默认档位',
        ThinkingEffort.off => '让模型少想，抢首字速度',
        ThinkingEffort.low => '简单问题够用，省时间也省钱',
        ThinkingEffort.medium => '大多数情况的平衡点',
        ThinkingEffort.high => '难题多想一会儿，慢且贵',
      };

  static ThinkingEffort fromStorage(String? raw) => switch (raw) {
        'off' => ThinkingEffort.off,
        'low' => ThinkingEffort.low,
        'medium' => ThinkingEffort.medium,
        'high' => ThinkingEffort.high,
        _ => ThinkingEffort.auto,
      };

  String get storage => name;

  /// OpenAI 兼容层和 Responses 的 `reasoning_effort`。null = 这一档不发。
  ///
  /// `minimal` 而不是 `none`：前者从 o 系列起就一直在，后者是较新的模型才
  /// 认得的写法，发给老模型会 400。
  String? get openAiEffort => switch (this) {
        ThinkingEffort.auto => null,
        ThinkingEffort.off => 'minimal',
        ThinkingEffort.low => 'low',
        ThinkingEffort.medium => 'medium',
        ThinkingEffort.high => 'high',
      };

  /// Anthropic 的思考预算，token 数。null = 不开扩展思考。
  ///
  /// 最低 1024 是硬性下界，低于它服务端直接拒。
  int? get anthropicBudget => switch (this) {
        ThinkingEffort.auto || ThinkingEffort.off => null,
        ThinkingEffort.low => 1024,
        ThinkingEffort.medium => 4096,
        // 不取更大的值：预算要整个塞进 `max_tokens`，而那也是一次请求真金
        // 白银的上限。再往上翻一倍，一次跑偏的推理就能烧掉一大截额度。
        ThinkingEffort.high => 12000,
      };
}

/// Anthropic 开思考时要一起改的两个字段。
///
/// `max_tokens` **必须大于** `budget_tokens`，否则 400；而思考本身也算在
/// max_tokens 里，所以要在预算之上再留出答案的位置。
({int budget, int maxTokens})? anthropicThinking(
  ThinkingEffort effort, {
  int answerRoom = 4096,
}) {
  final budget = effort.anthropicBudget;
  if (budget == null) return null;
  return (budget: budget, maxTokens: budget + answerRoom);
}

/// Gemini 的 `thinkingConfig`。
///
/// [includeThoughts] 是"把想的过程也发回来"，和强度是两件事 —— 前者决定
/// 界面上有没有思考那一块，后者决定它想多久。
///
/// 两代模型的字段完全不同，[model] 决定走哪一套。
Map<String, Object?> geminiThinkingConfig(
  String model,
  ThinkingEffort effort, {
  bool includeThoughts = true,
}) {
  final config = <String, Object?>{
    if (includeThoughts) 'includeThoughts': true,
  };
  if (effort == ThinkingEffort.auto) return config;

  if (_isGemini3OrNewer(model)) {
    // Gemini 3 只有两档，中间三档只能往两边归。往 high 归的是 medium ——
    // 用户特地从"自动"调到"中"，意思更接近"多想点"而不是"少想点"。
    config['thinkingLevel'] = switch (effort) {
      ThinkingEffort.off || ThinkingEffort.low => 'low',
      _ => 'high',
    };
    return config;
  }

  // 2.5 那代是 token 预算。上界取 24576：Pro 能到 32768，但 Flash 系列
  // 到此为止，取小的那个所有型号都发得出去。
  config['thinkingBudget'] = switch (effort) {
    // Pro **关不掉思考**，最低 128。给它发 0 会 400，所以这里落到下界，
    // 意思仍然是"尽量少想"。
    ThinkingEffort.off => model.toLowerCase().contains('pro') ? 128 : 0,
    ThinkingEffort.low => 2048,
    ThinkingEffort.medium => 8192,
    _ => 24576,
  };
  return config;
}

bool _isGemini3OrNewer(String model) {
  final match = RegExp(r'gemini-(\d+)').firstMatch(model.toLowerCase());
  if (match == null) return false;
  return (int.tryParse(match.group(1)!) ?? 0) >= 3;
}

/// 这条 400 是不是"这个模型不认思考强度"。
///
/// 存在的理由是这个旋钮**天生会撞上不支持它的模型**：能思考的模型每周都在
/// 变，聚合网关后面挂着几十家，没有任何一张表能一直是对的。撞上了要说人话
/// ——原始报错是一句 `Unsupported parameter: 'reasoning_effort'`，用户不会
/// 把它和自己两天前在设置页调过的一个滑块联系起来。
bool isThinkingEffortRejected(String body) {
  final lower = body.toLowerCase();
  const params = <String>[
    'reasoning_effort',
    'reasoning.effort',
    'budget_tokens',
    'thinkinglevel',
    'thinkingbudget',
    'thinking',
  ];
  if (!params.any(lower.contains)) return false;
  // 光提到字段名不够 —— 上下文超长的报错里也可能带上整个请求体。
  const rejections = <String>[
    'unsupported',
    'not supported',
    'unknown',
    'invalid',
    'unrecognized',
    'does not support',
  ];
  return rejections.any(lower.contains);
}
