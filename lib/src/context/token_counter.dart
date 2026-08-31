/// 本地 token 估算。
///
/// 手机上不跑真分词器：tiktoken 的 BPE 表 ~2MB，Gemma/Qwen 的 SentencePiece
/// 模型更大，而且每换一个模型就要换一份 —— 为了一个「估算」值不值。
///
/// 估算器只需要**足够准到能做预算裁剪**，剩下的偏差交给 [ContextLimitGuard]
/// 用服务端回报的真实值反向校准。这两个类是配套的：这里故意做简单，
/// 那里负责把系统性偏差学回来。
library;

class TokenCounter {
  /// 各类字符的经验系数（一个 token 平均对应多少个该类字符）。
  ///
  /// 数值来源是对 cl100k / Qwen 分词器在中英混排 + 代码语料上的实测中位数。
  /// 不追求精确 —— 精确是 ContextLimitGuard 的活。
  static const _charsPerTokenAscii = 3.8; // 英文散文 ~4，代码 ~3.2
  static const _charsPerTokenCjk = 0.65; // 中文一字常常 1~2 token
  static const _charsPerTokenOther = 2.0; // 日韩、西里尔、emoji

  static int estimate(String text) {
    if (text.isEmpty) return 0;

    var ascii = 0, cjk = 0, other = 0;
    for (final rune in text.runes) {
      if (rune < 0x80) {
        ascii++;
      } else if (_isCjk(rune)) {
        cjk++;
      } else {
        other++;
      }
    }

    final t = ascii / _charsPerTokenAscii +
        cjk / _charsPerTokenCjk +
        other / _charsPerTokenOther;
    return t.ceil();
  }

  static bool _isCjk(int r) =>
      (r >= 0x4E00 && r <= 0x9FFF) || // 统一汉字
      (r >= 0x3400 && r <= 0x4DBF) || // 扩展 A
      (r >= 0x3000 && r <= 0x303F) || // 中日韩标点
      (r >= 0xFF00 && r <= 0xFFEF); // 全角

  /// 一条消息的开销。除了内容本身，每条消息在 chat 模板里都有
  /// role 标记和分隔符（`<|im_start|>user\n` 之类），大约 4 token。
  /// 消息一多这部分不可忽略：50 条消息就是 200 token。
  static const perMessageOverhead = 4;

  static int estimateMessages(Iterable<({String role, String content})> msgs) {
    var total = 0;
    for (final m in msgs) {
      total += estimate(m.content) + estimate(m.role) + perMessageOverhead;
    }
    // 每次请求结尾的 assistant 起始标记
    return total + 3;
  }

  /// 工具定义（JSON schema）也占上下文，而且占得不少 ——
  /// 十个工具的 schema 轻松上千 token。裁剪历史时如果不把这部分算进去，
  /// 会得出「还有余量」的错误结论。
  static int estimateTools(String toolsJson) => estimate(toolsJson);
}
