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
  /// 数据库里的稳定行 id。内存里刚造出的消息还没有落库，值为 null。
  ///
  /// 搜索结果要用它定位回某一条历史消息；用内容或位置匹配都会在
  /// 编辑、分支切换和长对话里失准。
  final int? messageId;

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

  /// 这条用户消息是一个**分支锚点**，值是它的稳定 id。null = 从没在这里
  /// 分过支（绝大多数消息都是）。
  ///
  /// 「重新生成」和「编辑重发」都会在同一条用户消息下留下多个版本，这个 id
  /// 就是把那些版本挂起来的钩子。
  ///
  /// **为什么是随机 id 而不是"第几条消息"**：位置会变。编辑第 3 轮会把
  /// 第 4 轮往后整个换掉，如果之后又在新的第 4 轮上分支，按位置编号就会和
  /// 旧分支里那个已经不在活动路径上的第 4 轮撞车 —— 两条毫无关系的分支
  /// 共用一个编号，切换时会取到另一条分支的内容。随机 id 没有这个问题。
  final String? branchId;

  /// 这条 tool 消息是哪个工具产生的（`exec` / `read_file` …）。
  ///
  /// 存下来是为了**重开会话之后那张卡片还画得出来**。工具消息本身只装
  /// 结果正文，光靠正文认不出是谁跑的 —— 而界面上「刚才那一步做了什么」
  /// 恰恰是用户回头翻记录时最想看的东西。
  final String? toolName;

  /// 那一步的标题，通常就是命令行本身。见 `toolCallTitle`。
  final String? toolTitle;

  /// 那一步成没成。false = 被拒绝，或者退出码非 0。
  final bool toolOk;

  /// 那一步跑了多久，毫秒。0 = 没量到（老消息就是这样）。
  final int toolMs;

  const ChatMessage({
    this.messageId,
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
    this.branchId,
    this.toolName,
    this.toolTitle,
    this.toolOk = true,
    this.toolMs = 0,
  });

  bool get hasImages => images.isNotEmpty;

  ChatMessage copyWith({
    int? messageId,
    String? content,
    int? checkpoint,
    TokenUsage? usage,
    String? reasoning,
    int? reasoningMs,
    String? branchId,
  }) =>
      ChatMessage(
        messageId: messageId ?? this.messageId,
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
        branchId: branchId ?? this.branchId,
        toolName: toolName,
        toolTitle: toolTitle,
        toolOk: toolOk,
        toolMs: toolMs,
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

  /// 最近一次摘要失败的原因。null = 从没失败过，或者上一次成功了。
  ///
  /// 留着是为了让「压缩为什么没生效」在界面上答得出来。失败本身是安静的
  /// —— 上下文照样只增不减，用户唯一能察觉到的是"聊久了就变慢变贵"。
  String? _lastError;

  /// 这条失败还没报给用户看过。
  bool _errorUnreported = false;

  /// 上次失败时的历史长度。见 [_shouldSummarize] 里的退避。
  int _failedAt = -1;

  String? get summary => _summary;
  int get checkpoint => _checkpoint;
  bool get hasSummary => _summary != null && _summary!.isNotEmpty;
  String? get lastError => _lastError;

  /// 取一条还没报过的失败原因。**取一次就算报过了。**
  ///
  /// 摘要失败之后每加一条消息都会重新判定，把同一句话在状态条上刷十遍
  /// 只会把别的状态挤掉 —— 这件事说一次就够。
  String? takeUnreportedError() {
    if (!_errorUnreported) return null;
    _errorUnreported = false;
    return _lastError;
  }

  /// 从库里恢复上一次的摘要状态。
  ///
  /// 不恢复的话，重开 app 或者切走再切回会话，checkpoint 归 0、摘要归 null
  /// —— 长会话每次打开都要重新全量摘要一遍，而在那次摘要发生之前，
  /// **整段历史会原样发出去**，恰恰是最容易撞窗口上限的那一刻。
  ///
  /// checkpoint 是历史的下标，所以要按当前历史长度夹一次：编辑重发、
  /// 回到某条消息、切换分支都会把历史截短，而存下来的那个下标不知道。
  /// 越界的话 `history.skip()` 会安静地返回空窗口 —— 模型当场失忆。
  void restore({String? summary, required int checkpoint, required int historyLength}) {
    _summary = (summary?.trim().isEmpty ?? true) ? null : summary!.trim();
    _checkpoint = checkpoint.clamp(0, historyLength);
    _lastError = null;
    _errorUnreported = false;
    _failedAt = -1;
  }

  /// 历史**前面**插进来一段之后，把 checkpoint 往后挪。
  ///
  /// 打开会话时只先读最后一页，剩下的在后台补进历史开头（见 app.dart 的
  /// `_fillOlderHistory`）。checkpoint 是历史的下标 —— 前面多了 n 条，
  /// 它就得 +n，否则"摘要覆盖到第几条"会指到一段完全不相干的消息上：
  /// 窗口里会冒出一批本该被摘要盖住的原文，而真正该显示的那几条反而没了。
  void shiftBy(int count) {
    if (count <= 0 || _checkpoint <= 0) return;
    _checkpoint += count;
  }

  /// 历史被截短之后把 checkpoint 拉回来。
  ///
  /// 「回到这条消息」和分支切换都会砍掉一截历史。不跟着收的话，checkpoint
  /// 可能落在新历史的末尾之后，窗口里就一条消息都不剩了。
  void clampTo(int historyLength) {
    if (_checkpoint > historyLength) _checkpoint = historyLength;
  }

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

  /// 每次追加消息后调用。达到阈值就摘要一次。
  ///
  /// 返回 true 表示**真的摘出来了**，不是"试过了"。这两件事必须分开：
  /// 试过但失败时窗口一点都没变短，而调用方会照着返回值在界面上说
  /// 「已整理长期记忆」—— 那句话会把唯一一次能发现问题的机会盖掉。
  /// 失败的原因在 [takeUnreportedError]。
  Future<bool> onMessageAdded(List<ChatMessage> history) async {
    if (_summarizing) return false;
    if (!_shouldSummarize(history)) return false;
    return _summarizeUpTo(history);
  }

  bool _shouldSummarize(List<ChatMessage> history) {
    // 上次失败之后要再攒够一个阈值才重试。
    //
    // 不退避的话，一个配坏的摘要模型会让**之后每加一条消息都白打一次请求**
    // —— 又慢又花钱，而且每次都失败。而摘要失败通常是配置问题（地址、
    // 模型名、协议对不上），重试一百次也不会自己好。
    if (_failedAt >= 0 && history.length < _failedAt + messageThreshold) {
      return false;
    }

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
  Future<bool> _summarizeUpTo(List<ChatMessage> history) async {
    _summarizing = true;
    final myEpoch = _epoch;

    try {
      final newCheckpoint = _findCheckpoint(history);
      if (newCheckpoint <= _checkpoint) return false;

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

      final String result;
      try {
        result = await summarize(_summaryPrompt, payload.toString());
      } catch (e) {
        // **失败绝不推进 checkpoint。**
        //
        // 推进了就是：那批消息被踢出窗口，而没有任何摘要顶上 —— 上下文
        // 凭空少一截，而且 hasSummary 为假会让 AgentLoop 的主动检索一起
        // 跳过（见 `_retrieveInto`），被丢掉的内容连捞都捞不回来。
        // 宁可不压缩：窗口更满一点，至少内容还在。
        _fail(history, '$e');
        return false;
      }

      // 在途期间被 clear 了 —— 丢弃结果，不要复活旧状态。
      if (myEpoch != _epoch) return false;

      final next = result.trim();
      if (next.isEmpty) {
        // 请求成功但摘出来是空的，后果和失败一模一样：没有东西能替代那批
        // 原文。摘要模型名填错时就是这样 —— 服务端 200，正文是空的。
        _fail(history, '摘要模型返回了空结果');
        return false;
      }

      _lastError = null;
      _errorUnreported = false;
      _failedAt = -1;
      _summary = next;
      _checkpoint = newCheckpoint;
      return true;
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

  void _fail(List<ChatMessage> history, String reason) {
    _lastError = reason;
    _errorUnreported = true;
    _failedAt = history.length;
  }

  void clear() {
    _epoch++;
    _checkpoint = 0;
    _summary = null;
    _lastError = null;
    _errorUnreported = false;
    _failedAt = -1;
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
