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

import '../agent/agent_loop.dart' show TokenUsage;
import 'token_counter.dart';

class ChatMessage {
  final String role; // user / assistant / tool / system
  final String content;
  final DateTime at;

  /// 工具调用产生的消息带这个引用，指向落盘的完整输出（见 OutputDistiller）。
  final String? outputRef;

  /// 这条消息发出时 workspace 的检查点代号。
  ///
  /// 只有用户消息带它。「回到这条消息」要同时做两件事：把对话截断到这里，
  /// **以及**把文件回滚到那一刻 —— 只截对话的话，模型会对着一个它以为
  /// 还没改过、实际已经被改过的 workspace 重新推理，那种不一致比不回滚更糟。
  final int? checkpoint;

  /// 这条助手消息是**哪个来源**生成的，形如 `渠道名 · 模型名`。
  ///
  /// 存下来而不是显示时现取当前配置：换一次渠道，历史里每一条助手消息的
  /// 署名都会跟着变成新渠道 —— 那不只是不准，它恰好在用户想查
  /// 「刚才那次是谁花的额度」时给出错误答案。
  ///
  /// 存的是**标签而不是渠道 id**：渠道删掉之后 id 就成了悬空引用，
  /// 而这份记录的全部价值就在于渠道被删/改之后还读得懂。
  final String? source;

  /// 随这条消息一起发出去的图片，绝对路径。
  ///
  /// 存路径不存字节：一张手机照片压完也有几百 KB，base64 再涨三分之一，
  /// 而 `replaceMessages` 每轮都会把整个会话删了重插 —— 把图塞进 sqlite
  /// 等于每轮重写几 MB。落在会话自己的目录里，删会话时一起没。
  final List<String> images;

  /// 这条助手消息花掉的 token，**服务端口径**。
  ///
  /// 只有助手消息有，而且只有服务端回报了才有。用户消息不存 —— 它的开销
  /// 已经含在下一条助手消息的 input 里，单独再记一份等于把同一笔账算两遍。
  /// UI 想给用户消息显示体量时用本地估算，并且会标成估算值。
  ///
  /// 一个回合可能打多次请求（工具循环），存的是**整轮累加**后的量：用户问
  /// 「这一句花了多少」，想知道的是这一问一答的总账，不是其中某一次请求。
  final TokenUsage? usage;

  /// 模型在给出这条回答之前的思考过程。空 = 这个模型不吐思考，或没开。
  ///
  /// **和 [content] 分开存，而且永远不回传给模型。** 思考是一次性的草稿：
  /// 各家的文档都说得很明白，把上一轮的思考塞回下一轮的上下文会让模型
  /// 跟着自己的旧草稿走，而且那部分 token 要重新计费。分成两个字段之后
  /// 「发给模型的」和「给人看的」天然就是两回事，不需要在发送前再过滤一遍。
  final String reasoning;

  /// 思考花了多久，毫秒。0 = 没思考，或者这条是从旧版本的库里读出来的。
  ///
  /// 存下来而不是显示时现算：流式结束的那一刻这条消息就被换成了一条普通的
  /// 历史消息，现算的话那个数字会在回答写完的瞬间消失 —— 看起来像刚显示的
  /// 东西又坏掉了。
  final int reasoningMs;

  const ChatMessage({
    required this.role,
    required this.content,
    required this.at,
    this.outputRef,
    this.checkpoint,
    this.source,
    this.images = const <String>[],
    this.usage,
    this.reasoning = '',
    this.reasoningMs = 0,
  });

  bool get hasImages => images.isNotEmpty;

  ChatMessage copyWith({
    String? content,
    int? checkpoint,
    TokenUsage? usage,
    String? reasoning,
    int? reasoningMs,
  }) =>
      ChatMessage(
        role: role,
        content: content ?? this.content,
        at: at,
        outputRef: outputRef,
        checkpoint: checkpoint ?? this.checkpoint,
        source: source,
        images: images,
        usage: usage ?? this.usage,
        reasoning: reasoning ?? this.reasoning,
        reasoningMs: reasoningMs ?? this.reasoningMs,
      );
}

/// 触发摘要的口径。
enum OverflowTrigger { messageCount, tokenCount, either }

typedef Summarizer = Future<String> Function(
    String systemPrompt, String payload);

class OverflowManager {
  final Summarizer summarize;

  /// 这三项**可变**：设置页改完要当场生效。
  ///
  /// 做成 final 的话，用户改完阈值得新建一个会话才看得到效果 ——
  /// 而"改了没反应"是最容易被当成 bug 的一类体验。
  OverflowTrigger trigger;
  int messageThreshold;
  int tokenThreshold;

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

  /// 新 checkpoint 的位置：窗口里最多留 [messageThreshold] 条、
  /// 且最多留 [tokenThreshold] 个 token。
  ///
  /// **两条都要算，取更靠后的那个。** 原来这里在非 `messageCount` 模式下
  /// 只走 token 那条路，于是 `either` 模式有个静默空转的 bug：
  /// `_shouldSummarize` 按**条数**判定该摘要了，这里却按 **token** 找位置，
  /// 短消息攒再多也累不到 token 阈值，返回的还是老 checkpoint，
  /// `_summarizeUpTo` 直接 early return —— 摘要一次都不会真的发生，
  /// 而且此后每加一条消息都要重新白算一遍。
  ///
  /// 实测就是这样：聊天模式下连聊十几轮，`checkpoint` 一直是 0。
  int _findCheckpoint(List<ChatMessage> history) {
    var byCount = _checkpoint;
    if (trigger != OverflowTrigger.tokenCount) {
      byCount = (history.length - messageThreshold)
          .clamp(_checkpoint, history.length);
    }

    var byTokens = _checkpoint;
    if (trigger != OverflowTrigger.messageCount) {
      // 从尾部往前累加 token，累到阈值为止 —— 那个位置就是候选。
      var tokens = 0;
      for (var i = history.length - 1; i > _checkpoint; i--) {
        tokens += TokenCounter.estimate(history[i].content) +
            TokenCounter.perMessageOverhead;
        if (tokens >= tokenThreshold) {
          byTokens = i;
          break;
        }
      }
    }

    return byCount > byTokens ? byCount : byTokens;
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
