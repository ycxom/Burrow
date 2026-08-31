/// 从「上下文超长」这一类 400 错误里，把服务端真实的上下文窗口读出来并记住，
/// 让后续请求自动按这个上限裁剪历史。
///
/// 移植自 `VPetLLM/Utils/Common/ContextLimitGuard.cs`。这是那个项目里最值钱的
/// 一段设计，而在手机场景下比桌面更重要：用户很可能连的是本机跑的
/// llama.cpp / MLC，`n_ctx` 常常只有 2048~4096，比任何默认值都小。
///
/// 问题长这样：
/// ```json
/// {"error":{"code":400,"message":"request (13392 tokens) exceeds the available
///  context size (8192 tokens), try increasing it","type":"exceed_context_size_error",
///  "n_prompt_tokens":13392,"n_ctx":8192}}
/// ```
/// 而且撞上之后**每一轮都会再撞一次** —— 历史只增不减，错误信息里明明写着 8192，
/// 却没有任何一处代码去读它。这个类就是去读它。
///
/// ## 两段式：读窗口 + 校准尺子
///
/// 光知道 `n_ctx = 8192` 不够用。我们自己的 [TokenCounter] 是估算的，
/// 对中文、对代码、对 base64 的偏差都不一样。按自己的尺子量出 5000 以为没超，
/// 照发不误，然后再挨一次 400。
///
/// 所以还要读 `n_prompt_tokens`（服务端数出来的、我们刚发过去那一坨的真实 token 数），
/// 和我们自己对同一份内容的估算一比，得出**倍率**：
/// ```
/// ratio = serverTokens / ourEstimate     // 例如 13392 / 9500 = 1.41
/// budget = n_ctx / ratio                 // 8192 / 1.41 = 5810（我们尺子下的预算）
/// ```
/// 这一步做完，裁剪才是准的。
library;

/// 按「渠道|主机|模型」记住的上下文预算。
///
/// 不能只按 provider 记：同一个 provider 下不同节点的窗口可以差一个数量级
/// （一个 8k 的本地节点和一个 200k 的云端节点），混着记会把大窗口的节点也裁短。
class _LearnedLimit {
  /// 服务端报的窗口大小（服务端 token 单位）。
  final int serverContextTokens;

  /// 我们的估算器相对服务端分词的倍率。1.0 表示完全准。
  final double ratio;

  /// 同一个上限撞过几次。撞第二次说明校准还不够，继续收紧。
  final int hits;

  const _LearnedLimit(this.serverContextTokens, this.ratio, this.hits);

  /// 换算成**我们估算器单位**下的预算，并留出余量。
  int budgetInOurUnits() {
    final base = serverContextTokens / ratio;
    // 每多撞一次收紧一档。收紧不是因为窗口变小了，是因为我们的 ratio 还不够准
    // （prompt 里不同部分的分词偏差不一样，一个全局倍率注定有残差）。
    final shrink = _shrinkFactor(hits);
    return (base * shrink).round().clamp(_minimumBudget, 1 << 30);
  }

  static double _shrinkFactor(int hits) {
    if (hits <= 1) return 0.90; // 首次就留 10% 余量：响应本身也占窗口
    if (hits == 2) return 0.75;
    if (hits == 3) return 0.60;
    return 0.50;
  }

  /// 再怎么收紧也不低于这个值，否则窗口小到连当前这轮提问都放不下，
  /// 变成「裁到空还是发不出去」的死循环。
  static const _minimumBudget = 512;
}

class ContextLimitGuard {
  /// 已探明的上限。只活在本进程内 —— 服务端换配置、用户换节点都会让它失效，
  /// 持久化下来弊大于利。
  final Map<String, _LearnedLimit> _learned = {};

  /// 判断「状态码 + 响应体」是不是上下文超长。
  ///
  /// 只认 4xx 里那几个语义明确的状态码：5xx 是服务端自己的问题，401/403 是鉴权，
  /// 把它们一并当成上下文超长会导致无谓的裁剪和重试。
  bool isContextLimitError(int status, String? body) {
    if (body == null || body.isEmpty) return false;
    if (status != 400 && status != 413 && status != 422) return false;
    final lower = body.toLowerCase();
    return _markers.any(lower.contains);
  }

  /// 各家对「上下文超长」的说法。命中任意一条即认定。
  static const _markers = <String>[
    'exceed_context_size_error', // llama.cpp / llama-server
    'context_length_exceeded', // OpenAI
    'context size', // "exceeds the available context size"
    'context length', // "maximum context length is 8192 tokens"
    'context window', // Anthropic 兼容网关
    'reduce the length of the messages',
    'input token count exceeds', // Gemini
    'prompt is too long',
    'too many tokens',
    'too long for model', // MLC / mlc-llm
  ];

  /// 从错误体里抠出上下文窗口大小。抠不到返回 0 ——
  /// 有些网关只说「太长了」却不给数字，那种情况没有可信的裁剪目标，宁可不动
  /// （盲目对折会把一个 200k 窗口的模型砍成 100k，白白浪费）。
  ///
  /// 顺序即优先级：结构化字段最可信，散在自然语言里的次之。
  static int parseContextTokens(String? body) {
    if (body == null || body.isEmpty) return 0;
    for (final p in _contextPatterns) {
      final m = p.firstMatch(body);
      final v = int.tryParse(m?.group(1) ?? '');
      if (v != null && v > 0) return v;
    }
    return 0;
  }

  static final _contextPatterns = <RegExp>[
    RegExp(r'"n_ctx"\s*:\s*(\d+)', caseSensitive: false),
    RegExp(r'"context_length"\s*:\s*(\d+)', caseSensitive: false),
    RegExp(r'context size\s*\(?\s*(\d+)', caseSensitive: false),
    RegExp(r'context length is\s*(\d+)', caseSensitive: false),
    RegExp(r'context (?:length|window) of (?:only )?(\d+)', caseSensitive: false),
    RegExp(r'maximum(?:\s+\w+)?\s+(\d+)\s+tokens', caseSensitive: false),
  ];

  /// 服务端数出来的「我们刚发过去那一坨」的 token 数。抠不到返回 0。
  static int parsePromptTokens(String? body) {
    if (body == null || body.isEmpty) return 0;
    for (final p in _promptPatterns) {
      final m = p.firstMatch(body);
      final v = int.tryParse(m?.group(1) ?? '');
      if (v != null && v > 0) return v;
    }
    return 0;
  }

  static final _promptPatterns = <RegExp>[
    RegExp(r'"n_prompt_tokens"\s*:\s*(\d+)', caseSensitive: false),
    RegExp(r'"prompt_tokens"\s*:\s*(\d+)', caseSensitive: false),
    RegExp(r'request\s*\(\s*(\d+)\s*tokens', caseSensitive: false),
    RegExp(r'your messages resulted in (\d+) tokens', caseSensitive: false),
    RegExp(r'\((\d+) in the messages', caseSensitive: false),
  ];

  static String makeKey(String channel, String host, String model) =>
      '$channel|$host|$model';

  /// 撞到一次上下文超长时调用。
  ///
  /// [ourEstimate] 是我们发出去之前自己算的 token 数 —— 校准全靠它。
  /// 返回「我们估算器单位下」的新预算；返回 0 表示这次错误信息里没有
  /// 可用数字，调用方应该退回到"直接对折"这种笨办法。
  int learn({
    required String key,
    required String? body,
    required int ourEstimate,
  }) {
    final serverContext = parseContextTokens(body);
    if (serverContext <= 0) return 0;

    final serverPrompt = parsePromptTokens(body);
    // 没有 n_prompt_tokens 时 ratio 只能取 1.0，但那样几乎必然再撞一次
    // （因为估算器通常偏低）。给一个经验性的保守倍率：中英混排 + 代码
    // 的场景下我们的估算器实测偏低 15%~40%，取中间值。
    final ratio = (serverPrompt > 0 && ourEstimate > 0)
        ? serverPrompt / ourEstimate
        : 1.25;

    final prev = _learned[key];
    final hits = (prev != null && prev.serverContextTokens == serverContext)
        ? prev.hits + 1
        : 1;

    // ratio 取历史最大值而不是最新值：估算器只会偏低不会偏高
    // （我们的估算对未知 token 是保守的），所以一旦观测到 1.41，
    // 下次观测到 1.10 更可能是那次 prompt 恰好好分词，而不是估算器变准了。
    final effectiveRatio =
        prev == null ? ratio : (ratio > prev.ratio ? ratio : prev.ratio);

    _learned[key] = _LearnedLimit(serverContext, effectiveRatio, hits);
    return _learned[key]!.budgetInOurUnits();
  }

  /// 当前该用多少预算。没学到过就返回 [fallback]（通常是用户配置的值，
  /// 或者 0 表示不限制）。
  int budgetFor(String key, {int fallback = 0}) {
    final learned = _learned[key];
    if (learned == null) return fallback;
    final b = learned.budgetInOurUnits();
    // 用户显式配了更小的值就听用户的 —— 他可能是想省钱，不是不知道窗口多大。
    if (fallback > 0 && fallback < b) return fallback;
    return b;
  }

  /// 用户换了模型/节点后调用，避免拿旧节点的窗口去裁新节点。
  void forget(String key) => _learned.remove(key);

  void reset() => _learned.clear();
}
