/// 系统提示词怎么送到模型手里，以及送不了的时候怎么办。
///
/// ## 为什么这不是"直接发 role: system"就完事
///
/// `system` 这个角色**不是所有服务都认**。实测和公开已知的几类：
///
///   - 一批本地推理服务（部分 llama.cpp server 的模板、老的 vLLM 版本）
///     只认 user/assistant 交替，收到 system 直接 400。
///   - 更糟的一类是**收下但不当回事**：请求成功，模型完全无视那段提示。
///     用户看到的是"系统提示词写了没用"，而没有任何错误可查。
///   - 少数推理模型（o1 早期、部分 R1 蒸馏版）明确要求不要发 system。
///
/// 所以这里给三种写法，按渠道选。降级用**拼进第一条用户消息**而不是丢掉：
/// 提示词被静默丢掉是最坏的结果 —— 用户以为设了人格，模型却完全没收到。
library;

import '../context/overflow_manager.dart';

/// 系统提示词的送达方式。
enum SystemPromptStyle {
  /// 正常发 `role: "system"`。绝大多数服务都这样。
  systemRole,

  /// 拼进第一条用户消息的开头。
  ///
  /// 给不认 system 角色的服务用。**不是丢掉**，内容一个字不少地送到了，
  /// 只是换了个位置 —— 模型对"用户第一句话里的要求"的服从度通常也够。
  firstUserMessage,

  /// 完全不发。
  ///
  /// 给明确要求不带 system 的模型（部分推理模型）用。这是唯一一种
  /// 会真的丢内容的选项，所以必须是用户显式选的。
  omit,
}

/// 把系统消息按 [style] 重排。
///
/// 输入输出都是完整的消息列表，**纯函数**：这段逻辑三条协议路径共用，
/// 而它出错的表现是"提示词没生效"，不是异常 —— 只能靠单测钉住。
List<ChatMessage> applySystemPromptStyle(
  List<ChatMessage> messages,
  SystemPromptStyle style,
) {
  if (style == SystemPromptStyle.systemRole) return messages;

  final systems = <String>[
    for (final m in messages)
      if (m.role == 'system' && m.content.trim().isNotEmpty) m.content,
  ];
  final rest = messages.where((m) => m.role != 'system').toList();

  if (style == SystemPromptStyle.omit || systems.isEmpty) return rest;

  final merged = systems.join('\n\n');
  final firstUser = rest.indexWhere((m) => m.role == 'user');
  if (firstUser < 0) {
    // 一条用户消息都没有（只有助手消息的历史，或者空列表）。
    // 造一条 user 出来，而不是把提示词丢掉。
    return <ChatMessage>[
      ChatMessage(role: 'user', content: merged, at: DateTime.now()),
      ...rest,
    ];
  }

  final target = rest[firstUser];
  return <ChatMessage>[
    ...rest.take(firstUser),
    ChatMessage(
      role: 'user',
      content: '$merged\n\n${target.content}',
      at: target.at,
      outputRef: target.outputRef,
      checkpoint: target.checkpoint,
      source: target.source,
      // 图片跟着这条消息走 —— 拼提示词不该让附件掉队。
      images: target.images,
    ),
    ...rest.skip(firstUser + 1),
  ];
}

/// 这条消息带了图、但这一路发不了图时，正文里补的那句话。
///
/// 抄自 AstrBot 的 `sanitize_contexts_by_modalities`：它把发不出去的图块
/// 换成 `[Image]` 占位而**不是删掉**。理由很实在 —— 历史里那句
/// 「这张图里写了什么」如果旁边什么都没有，模型只会开始编；
/// 留一个占位符，它至少知道"这里本来有张图，我没看到"。
const imageOmittedMarker = '[图片：当前模型看不了图，未随消息发送]';

/// 给发不出图的消息补上占位说明。
String withImagePlaceholder(String content, int imageCount) {
  if (imageCount <= 0) return content;
  final marker = imageCount == 1
      ? imageOmittedMarker
      : '[$imageCount 张图片：当前模型看不了图，未随消息发送]';
  return content.trim().isEmpty ? marker : '$content\n$marker';
}
