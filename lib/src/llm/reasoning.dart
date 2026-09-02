/// 思考内容在 OpenAI 兼容层上的字段名。
///
/// OpenAI 自己的 `/chat/completions` **不返回思考** —— o 系列的推理摘要只在
/// Responses API 上有。但兼容层早就不只是 OpenAI 在用了：DeepSeek 起了个头
/// 叫 `reasoning_content`，深度求索系的模型（以及照抄它的国内网关）都跟着用；
/// OpenRouter 那边归一化成了 `reasoning`。两个名字都得认。
///
/// **不做"哪个渠道用哪个名字"的映射表。** 同一个 baseUrl 后面可能挂着好几家
/// 的模型（聚合网关就是干这个的），按渠道猜必然会猜错；而按字段取值天然
/// 只对得上真正给了那个字段的响应。
library;

/// 从一个 `delta` 或 `message` 对象里取思考文本。没有就返回空串。
///
/// [raw] 收 `Object?` 而不是 `Map`：调用点拿到的是 `jsonDecode` 的产物，
/// 那里什么都可能是 —— 在这里判一次，四个调用点就都不用各判一次。
String openAiReasoningOf(Object? raw) {
  if (raw is! Map) return '';
  for (final key in const <String>['reasoning_content', 'reasoning']) {
    final value = raw[key];
    if (value is String && value.isNotEmpty) return value;
    // OpenRouter 在**非流式**响应里把 reasoning 做成了对象（里面是分段的
    // 思考块）。取不出字符串就当没有，而不是把 `{...}` 的 toString 显示出去。
    if (value is Map) {
      final text = value['text'] ?? value['content'];
      if (text is String && text.isNotEmpty) return text;
    }
  }
  return '';
}
