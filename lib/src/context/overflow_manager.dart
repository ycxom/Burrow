/// 滚动摘要 + 滑动窗口。移植自 `VPetLLM/Core/Data/Managers/OverflowManager.cs`。
///
/// ## 机制
///
/// 设阈值 T（默认按 token 算）：
///   - prompt 窗口永远只装 checkpoint 之后的消息
///   - 超出 checkpoint + T 的部分算「溢出」
///   - 溢出量本身达到 T 时（即累计 2T），触发一次增量摘要，checkpoint 前移
///
/// 摘要是**单份滚动文本**，不是摘要链：每次把当前摘要连同新溢出的消息一起
/// 喂回 LLM，产出一份完整的新版本，取代旧版本。
///
/// 为什么不做摘要链（把每段摘要拼起来）：链会无限增长，最终摘要本身就撑爆窗口，
/// 而且早期摘要的措辞会被反复重复。滚动版每次都有机会重新组织全局信息，
/// 让真正重要的东西沉淀下来、过时的东西自然脱落。
///
/// **历史永不删除** —— 只是不进 prompt。被挤出窗口的消息仍然完整存在数据库里，
/// 由 [MemoryRetrieval] 按需检索回来（见 memory_retrieval.dart）。
/// 这是滚动摘要唯一的安全网：摘要一定会丢细节，丢掉的细节必须能找回来。
library;

import 'token_counter.dart';

class ChatMessage {
  final String role; // user / assistant / tool / system
  final String content;
  final DateTime at;

  /// 工具调用产生的消息带这个引用，指向落盘的完整输出（见 OutputDistiller）。
  final String? outputRef;

  const ChatMessage({
    required this.role,
    required this.content,
    required this.at,
    this.outputRef,
  });
}

/// 触发摘要的口径。
enum OverflowTrigger { messageCount, tokenCount, either }

typedef Summarizer = Future<String> Function(
    String systemPrompt, String payload);

class OverflowManager {
  final Summarizer summarize;

  final OverflowTrigger trigger;
  final int messageThreshold;
  final int tokenThreshold;

  OverflowManager({
    required this.summarize,
    this.trigger = OverflowTrigger.either,
    this.messageThreshold = 40,
    this.tokenThreshold = 6000,
  });

  /// 已被摘要覆盖的消息数。history[0.._checkpoint) 不进 prompt。
  int _checkpoint = 0;

  String? _summary;

  /// ClearAll 时自增。在途的摘要任务发现 epoch 变了就丢弃自己的结果，
  /// 否则一次慢的摘要请求会在用户清空历史之后把旧状态复活回来。
  int _epoch = 0;

  bool _summarizing = false;

  String? get summary => _summary;
  int get checkpoint => _checkpoint;
  bool get hasSummary => _summary != null && _summary!.isNotEmpty;

  /// 构造要发给 LLM 的消息序列。
  ///
  /// 顺序有讲究：摘要放在 system 之后、窗口消息之前，并且明确标注它是
  /// 「更早对话的摘要」。不标注的话模型会把摘要里的内容当成刚刚说过的话，
  /// 时间感全乱 —— 表现为它会说「你刚才提到...」而那其实是半小时前的事。
  List<ChatMessage> buildWindow(List<ChatMessage> history) {
    final window = <ChatMessage>[];
    if (hasSummary) {
      window.add(ChatMessage(
        role: 'system',
        content: '[更早对话的摘要 —— 这些是已经过去的内容，不是刚刚发生的]\n$_summary\n'
            '[摘要结束。如需其中未涵盖的细节，调用 recall_memory 检索原始记录]',
        at: DateTime.now(),
      ));
    }
    window.addAll(history.skip(_checkpoint));
    return window;
  }

  /// 每次追加消息后调用。达到阈值就异步触发摘要。
  ///
  /// 返回 true 表示本次触发了摘要（调用方可据此在 UI 上显示"正在整理记忆"）。
  Future<bool> onMessageAdded(List<ChatMessage> history) async {
    if (_summarizing) return false;
    if (!_shouldSummarize(history)) return false;
    await _summarizeUpTo(history);
    return true;
  }

  bool _shouldSummarize(List<ChatMessage> history) {
    final pending = history.length - _checkpoint;
    final byCount = pending >= messageThreshold * 2;

    var byTokens = false;
    if (trigger != OverflowTrigger.messageCount) {
      final tokens = TokenCounter.estimateMessages(
        history
            .skip(_checkpoint)
            .map((m) => (role: m.role, content: m.content)),
      );
      byTokens = tokens >= tokenThreshold * 2;
    }

    return switch (trigger) {
      OverflowTrigger.messageCount => byCount,
      OverflowTrigger.tokenCount => byTokens,
      OverflowTrigger.either => byCount || byTokens,
    };
  }

  /// 把 checkpoint 推进到「保留最近一个阈值量」的位置。
  ///
  /// 注意保留的是**最近 T**，不是全部摘要完 —— 摘要完会导致模型丢失
  /// 刚刚几轮的原文，而那几轮往往正是当前任务的上下文。
  Future<void> _summarizeUpTo(List<ChatMessage> history) async {
    _summarizing = true;
    final myEpoch = _epoch;

    try {
      final newCheckpoint = _findCheckpoint(history);
      if (newCheckpoint <= _checkpoint) return;

      final batch = history.sublist(_checkpoint, newCheckpoint);
      final payload = StringBuffer();
      if (hasSummary) {
        payload.writeln('【已有摘要】');
        payload.writeln(_summary);
        payload.writeln();
      }
      payload.writeln('【新增对话】');
      for (final m in batch) {
        // 工具输出在这里用引用代替全文：它们已经被蒸馏过一次，
        // 再喂给摘要模型一遍纯属浪费，而且摘要模型很容易被大段日志带偏，
        // 产出一份「关于日志内容」而不是「关于任务进展」的摘要。
        final body = m.outputRef != null
            ? '[命令输出，已归档 ref=${m.outputRef}]${_firstLine(m.content)}'
            : m.content;
        payload.writeln('${m.role}: $body');
      }

      final result = await summarize(_summaryPrompt, payload.toString());

      // 在途期间被 clear 了 —— 丢弃结果，不要复活旧状态。
      if (myEpoch != _epoch) return;

      _summary = result.trim();
      _checkpoint = newCheckpoint;
    } finally {
      _summarizing = false;
    }
  }

  int _findCheckpoint(List<ChatMessage> history) {
    if (trigger == OverflowTrigger.messageCount) {
      return (history.length - messageThreshold)
          .clamp(_checkpoint, history.length);
    }
    // 从尾部往前累加 token，累到阈值为止 —— 那个位置就是新 checkpoint。
    var tokens = 0;
    for (var i = history.length - 1; i > _checkpoint; i--) {
      tokens += TokenCounter.estimate(history[i].content) +
          TokenCounter.perMessageOverhead;
      if (tokens >= tokenThreshold) return i;
    }
    return _checkpoint;
  }

  static String _firstLine(String s) {
    final i = s.indexOf('\n');
    final head = i < 0 ? s : s.substring(0, i);
    return head.length > 120 ? '${head.substring(0, 120)}…' : head;
  }

  void clear() {
    _epoch++;
    _checkpoint = 0;
    _summary = null;
  }

  /// 摘要提示词。为终端 Agent 场景专门写过 ——
  /// 通用的「总结以下对话」会产出一份对话流水账，而 Agent 需要的是**状态**：
  /// 现在在哪个目录、装了什么、改了哪些文件、哪条路走不通。
  static const _summaryPrompt = '''
你在为一个运行在手机上的终端 Agent 维护长期记忆。把下面的内容整理成一份
【完整的、可替代原文的】摘要。已有摘要的部分要融合进去，不要另起一段。

必须保留：
1. 用户的目标和明确约束（这是最重要的，永远不要压缩掉）
2. 环境状态：当前工作目录、已安装的包及版本、已创建/修改的文件路径
3. 已经验证有效的命令和配置
4. **失败过的尝试及其原因** —— 防止之后重蹈覆辙，这条经常被摘要丢掉
5. 尚未完成的待办

可以丢弃：寒暄、逐条命令的完整输出、中间探索过程中被推翻的假设。

用简洁的条目式中文，不要写成叙事。不要加任何前言或结语。
''';
}
