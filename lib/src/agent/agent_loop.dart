/// Agent 主循环。把沙箱、回滚、上下文三块缝在一起。
///
/// 循环本身很短 —— 复杂度都被推到了各个部件里，这是有意的：
/// 主循环是最难测也最难改的地方，它应该只负责编排，不负责任何判断。
library;

import 'dart:async';
import 'dart:io';

import '../context/context_limit_guard.dart';
import '../context/memory_retrieval.dart';
import '../context/output_distiller.dart';
import '../context/overflow_manager.dart';
import '../context/token_counter.dart';
import '../llm/vision.dart';
import '../sandbox/exec_policy.dart';
import '../sandbox/prefix_generations.dart';
import '../sandbox/sandbox_session.dart';
import '../sandbox/snapshot_store.dart';
import '../skills/skill_store.dart';
import 'tools.dart';

/// 审批档位。语义对齐 codex。
enum ApprovalMode {
  /// 只读工具可用，任何写/exec 一律拒。
  readOnly,

  /// 策略判 allow 的自动跑，prompt 的问用户，forbidden 的拒。默认。
  onRequest,

  /// allow + prompt 都自动跑，但强制开检查点。forbidden 仍拒。
  auto,

  /// 关沙箱关审批。UI 必须显示红条。
  yolo,
}

/// UI 需要实现的回调。抽成接口是为了让主循环能脱离 Flutter 单测。
abstract class AgentHost {
  /// 请求用户批准一次工具调用。返回 false = 拒绝。
  Future<bool> requestApproval(ToolCall call, PolicyVerdict verdict);

  /// 助手文本的流式增量。
  void onAssistantDelta(String text);

  /// 助手**思考过程**的流式增量。
  ///
  /// 和 [onAssistantDelta] 分成两条回调，是因为这两股流会交错到达（模型
  /// 边想边说），共用一条的话 UI 无从知道刚收到的这一段该进思考区还是正文区，
  /// 只能靠猜分隔符 —— 而那是各家都不保证的东西。
  void onAssistantReasoning(String text);

  /// 命令输出的实时字节流，喂给终端视图。
  void onTerminalChunk(List<int> chunk);

  /// 状态变化：打了检查点、触发了摘要、沙箱降级等。用于 UI 上的小提示。
  void onStatus(String message);

  /// 模型在这一回合里写完了一段正文，已经进 history。
  ///
  /// 一个回合可能产出好几段（说一句 → 跑命令 → 再说一句）。以前 UI 把它们
  /// 攒成一个气泡，于是**活着看到的**和**重开会话看到的**是两种排版；而且
  /// 中间跑命令的那几十秒里，界面上那一条气泡一个字都不变，看起来就是卡死。
  ///
  /// 现在每段落地就通知一次，UI 收口成一条消息，中间的工具调用画成自己的
  /// 一行 —— 两种视图从此一致。
  void onAssistantMessage(ChatMessage message);

  /// 要开始跑一个工具了。UI 拿它画「执行中」。
  ///
  /// 在**审批之前**发：等审批弹窗弹出来时，背景里已经能看到是哪条命令
  /// 在等确认了。
  void onToolStart(ToolCall call);

  /// 工具跑完了，[message] 就是刚进 history 的那条 tool 消息。
  void onToolEnd(ChatMessage message);

  /// 往历史里插了一条**不是用户也不是模型说的**消息：检索回来的片段、
  /// 图片的文字描述。
  ///
  /// 有这个回调是因为 UI 手工维护着一份 `_visible`，而这些消息是在
  /// AgentLoop 内部塞进 history 的 —— 不通知的话它们要等到下次重开会话
  /// 才出现，而"重开之后多出来几条消息"比一开始就看见更让人困惑。
  void onContextMessage(ChatMessage message);

  /// 摘要状态在**回合之外**变过了，去落一次盘。
  ///
  /// 回合结束之后那次压缩是不等的（见 [AgentLoop._compactLater]），它落地时
  /// 这一轮的落盘早就跑完了。不补这一下的话，摘要只活在内存里 —— 切走再
  /// 切回来就没了，而那正是"压缩好像从来没生效过"的一种。
  void onMemoryUpdated();
}

/// LLM 后端。用一个窄接口隔开，chatbox 那套 provider 抽象可以直接塞进来实现它。
abstract class LlmClient {
  /// 返回一次完整的助手回合（可能含多个 tool call）。
  /// 实现方负责流式解析并把文本增量喂给 [onDelta]。
  ///
  /// 抛 [ContextOverflowException] 表示服务端拒绝了这次请求且原因是超长 ——
  /// 主循环据此触发 ContextLimitGuard 的学习和重试。
  Future<LlmTurn> complete({
    required List<ChatMessage> messages,
    required List<ToolSpec> tools,
    required void Function(String delta) onDelta,
    void Function(String delta)? onReasoning,
  });

  /// 当前渠道标识，供 ContextLimitGuard 分桶。
  String get limitKey;
}

abstract interface class CancellableLlmClient {
  void cancel();
}

class AgentCancelledException implements Exception {
  const AgentCancelledException();
}

class LlmTurn {
  final String text;
  final List<ToolCall> toolCalls;

  /// 服务端回报的本次调用用量。null = 这个服务没回报。
  final TokenUsage? usage;

  /// 这次调用吐出的思考过程。空 = 这个模型/协议没有思考，或者没开。
  final String reasoning;

  /// 思考花掉的墙上时间，毫秒。0 = 没思考，或者没测出来。
  final int reasoningMs;

  const LlmTurn({
    required this.text,
    this.toolCalls = const [],
    this.usage,
    this.reasoning = '',
    this.reasoningMs = 0,
  });
}

/// 一次 LLM 调用的 token 用量，**服务端口径**。
///
/// 和 [TokenCounter] 的估算分开表示：估算是给裁剪历史用的，可以差 30%；
/// 这个是给用户看"这一轮花了多少"的，差一个 token 都不该编。所以拿不到就是
/// 拿不到（null），UI 自己决定要不要退回估算并标上 `~`。
class TokenUsage {
  /// 提示词 token。注意它是**整个上下文**的量，不是最后那条用户消息的量 ——
  /// 长对话里这个数会一直涨，那正是它值得显示的原因。
  final int input;

  /// 生成的 token。
  final int output;

  /// 命中提示词缓存的部分（OpenAI 的 cached_tokens / Anthropic 的
  /// cache_read_input_tokens）。已经含在 [input] 里，单独列出来是因为
  /// 它的计费价格不一样。拿不到就是 0。
  final int cached;

  /// 这是本地估算，不是服务端口径。
  ///
  /// 很多网关在流式下压根不回报用量（实测某些 new-api 部署就是这样），
  /// 那时退回 [TokenCounter] 的估算，但**必须标出来** —— 一个能拿去和账单
  /// 对账的数字里混进估算值，比不显示更糟。UI 见到它会加个 `~`。
  final bool estimated;

  const TokenUsage({
    this.input = 0,
    this.output = 0,
    this.cached = 0,
    this.estimated = false,
  });

  int get total => input + output;
  bool get isEmpty => input == 0 && output == 0;

  /// 工具循环里一个回合会打多次请求，用量要累加成"这一轮花了多少"。
  ///
  /// **只要有一次是估算的，合出来的就是估算的。** 一轮里有真有估时，
  /// 总数已经不能拿去对账了，标成精确值是在骗人。
  TokenUsage operator +(TokenUsage? other) => other == null
      ? this
      : TokenUsage(
          input: input + other.input,
          output: output + other.output,
          cached: cached + other.cached,
          estimated: estimated || other.estimated,
        );

  /// 从 OpenAI 兼容的 `usage` 对象读。
  static TokenUsage? fromOpenAi(Object? raw) {
    if (raw is! Map) return null;
    final details = raw['prompt_tokens_details'];
    final usage = TokenUsage(
      input: _int(raw['prompt_tokens']),
      output: _int(raw['completion_tokens']),
      cached: details is Map ? _int(details['cached_tokens']) : 0,
    );
    return usage.isEmpty ? null : usage;
  }

  /// 从 Anthropic 的 `usage` 对象读。流式下它分两次到（message_start 给
  /// input，message_delta 给 output），所以这里允许只有一半有值。
  static TokenUsage? fromAnthropic(Object? raw) {
    if (raw is! Map) return null;
    final usage = TokenUsage(
      input: _int(raw['input_tokens']),
      output: _int(raw['output_tokens']),
      cached: _int(raw['cache_read_input_tokens']),
    );
    return usage.isEmpty ? null : usage;
  }

  /// 从 Responses API 的 `usage` 对象读。
  static TokenUsage? fromResponses(Object? raw) {
    if (raw is! Map) return null;
    final details = raw['input_tokens_details'];
    final usage = TokenUsage(
      input: _int(raw['input_tokens']),
      output: _int(raw['output_tokens']),
      cached: details is Map ? _int(details['cached_tokens']) : 0,
    );
    return usage.isEmpty ? null : usage;
  }

  static int _int(Object? value) =>
      value is num ? value.toInt() : int.tryParse('$value') ?? 0;

  @override
  String toString() => 'TokenUsage(in: $input, out: $output, cached: $cached'
      '${estimated ? ', 估算' : ''})';
}

/// [AgentLoop.rewindTo] 的结果。
class RewindResult {
  /// 被截掉的消息，按原顺序。
  final List<ChatMessage> dropped;

  /// 实际回滚到的检查点；null 表示只截了对话、文件没动
  /// （那条消息是老版本存的，没有检查点记录）。
  final int? rolledBackTo;

  /// 旧内容没存下来、回滚不回去的文件。非空时 UI 必须显示。
  final List<String> unrecoverable;

  const RewindResult({
    required this.dropped,
    required this.rolledBackTo,
    this.unrecoverable = const [],
  });

  bool get filesRestored => rolledBackTo != null;
}

/// 服务端返回了 200，但里面既没有文本也没有工具调用。
///
/// 单独一个类型而不是 StateError：这个失败有非常具体的排查方向，
/// 消息里要把方向给出来，而不是让用户去猜。
class EmptyCompletionException implements Exception {
  final String endpoint;
  const EmptyCompletionException(this.endpoint);

  @override
  String toString() => '模型返回了空响应（$endpoint）。\n'
      '常见原因是接口地址不对：Base URL 填服务根地址时，'
      '有些网关的 /chat/completions 会返回前端页面而不是接口，'
      '状态码仍然是 200，所以看起来像"没反应"。\n'
      '可以在设置里点「测试连接」确认，或者把 Base URL 写到 /v1 那一层。';
}

/// 图片送不到模型手里。
class VisionUnavailableException implements Exception {
  final String message;
  const VisionUnavailableException(this.message);
  @override
  String toString() => message;
}

class ContextOverflowException implements Exception {
  final int status;
  final String body;
  const ContextOverflowException(this.status, this.body);
}

class AgentLoop {
  final LlmClient llm;
  final AgentHost host;
  final ExecPolicy policy;
  final SandboxSession sandbox;
  final SnapshotStore snapshots;
  final PrefixGenerations prefixGens;
  final OverflowManager overflow;
  final MemoryRetrieval retrieval;
  final OutputDistiller distiller;
  final ContextLimitGuard limitGuard;
  final Directory outputArchiveDir;

  /// 已连接的 skill。null 表示这个 app 没启用 skill 功能（单测里就是 null）。
  final SkillStore? skills;

  ApprovalMode mode;
  SandboxLevel sandboxLevel;

  /// 终端模式：给不给模型沙箱工具。
  ///
  /// 关着的时候这就是一个普通聊天 app —— 不发 tool schema、不打检查点、
  /// 不碰文件系统。这不只是省 token（一整套 schema 每轮上千）：
  /// 大量模型只要看见工具就倾向于调，用户问「Rust 的所有权是什么意思」
  /// 也会先 `ls` 一遍 workspace。把工具收走是唯一可靠的关法。
  ///
  /// 开启的前提是发行版基座已经装好 —— 没有 rootfs 时 exec 会落到
  /// Android 自带的 mksh 上，那里面没有包管理器也没有路径隔离，
  /// 模型会对着一堆「command not found」原地打转。UI 负责挡这一步。
  bool terminalMode;

  /// 当前模型认不认工具。由外部按渠道 + 模型算好后塞进来 ——
  /// AgentLoop 不认识 Channel，也不该认识。
  bool supportsTools = true;

  /// 当前来源的署名，形如 `渠道名 · 模型名`。写进每条助手消息里。
  ///
  /// 由 UI 推过来（和 [mode]、[sandboxLevel] 一样），而不是从 `llm.config`
  /// 现取：渠道名只有 UI 那层知道，而**只有模型名是不够的** —— 两个渠道
  /// 常常挂着同名的模型，一个免费一个计费，那正是要分清的情形。
  String? sourceLabel;

  /// 这一路能不能把图直接发给对话模型。
  ///
  /// 由 UI 推过来（和 [sourceLabel] 一样），和 `LlmConfig.sendImagesInline`
  /// 是同一个判断的两份拷贝 —— 这里要它是为了**在发请求之前**就决定走不走
  /// 前置多模态，那时还没到客户端那一层。
  bool sendImagesInline = false;

  /// 前置多模态。null = 没接（单测里就是 null）。
  final VisionPreprocessor? vision;

  /// 用户自己写的系统提示词。空 = 只用内置那份。
  ///
  /// 由 UI 推过来：它可能来自全局设置，也可能来自这个会话自己的一份，
  /// 「用哪个」是 UI 那层的事，这里只管拼。
  String userSystemPrompt = '';

  /// 全量历史。**永不删除** —— overflow 只控制哪些进 prompt。
  final List<ChatMessage> history = [];

  /// 走一次前置多模态，返回要插进历史的那段描述。
  ///
  /// **失败就抛**，不静默降级成"当没有图"：用户附了图就是要它起作用，
  /// 悄悄丢掉的话模型会对着一条提到图却没有图的消息硬答，
  /// 而用户完全看不出图没送到。
  Future<String> _describeImages(List<String> images) async {
    final preprocessor = vision;
    if (preprocessor == null) {
      throw const VisionUnavailableException('当前渠道的对话模型不认图，也没有配前置视觉模型。'
          '到「设置 → 模型分工」里指一个「图片转文字」模型，'
          '或者勾上「对话模型能直接看图」。');
    }
    host.onStatus('正在识别图片…');
    final result = await preprocessor.describe(images);
    if (!result.ok) throw VisionUnavailableException(result.error);
    host.onStatus('已由 ${result.usedLabel} 识别图片');
    return '[图片内容]\n${result.description}';
  }

  /// 单个 turn 内最多几轮工具调用。防止模型陷入
  /// 「跑命令 → 看输出 → 再跑同一条命令」的死循环。
  final int maxToolRounds;
  int _cancelEpoch = 0;

  AgentLoop({
    required this.llm,
    required this.host,
    required this.policy,
    required this.sandbox,
    required this.snapshots,
    required this.prefixGens,
    required this.overflow,
    required this.retrieval,
    required this.distiller,
    required this.limitGuard,
    required this.outputArchiveDir,
    this.skills,
    this.vision,
    this.mode = ApprovalMode.onRequest,
    this.sandboxLevel = SandboxLevel.workspaceWrite,
    this.terminalMode = false,
    this.sourceLabel,
    this.maxToolRounds = 24,
  });

  /// 发一条用户消息。[images] 是本地图片的绝对路径。
  ///
  /// 图片有两条路：
  ///   - **直发**（[sendImagesInline]）：图跟着这条消息进请求体，
  ///     由对话模型自己看。
  ///   - **前置多模态**：先让一个视觉模型把图描述成文字，描述作为一条
  ///     system 消息插在用户这句话前面。图仍然记在消息上 —— 界面要显示
  ///     它，历史里也该看得出"这轮是带图的"。
  Future<void> send(String userInput, {List<String> images = const []}) async {
    final epoch = _cancelEpoch;
    // 先把图处理掉再打检查点：前置多模态要发一次网络请求，可能失败，
    // 失败就整轮不发。放在检查点后面的话，会留下一个空转的检查点。
    final String? description = images.isEmpty || sendImagesInline
        ? null
        : await _describeImages(images);
    // 每个 turn 开头自动打检查点。绝大多数 turn 没改文件，diff 为空，
    // checkpoint() 直接返回 null 且不推进代号 —— 所以这是免费的。
    // 它换来的是「任何一轮都能整体撤销」这个非常好用的性质。
    //
    // 聊天模式下连扫描都省掉：那一轮里没有任何东西能改文件，
    // 而扫 workspace 是真的要走一遍磁盘的，手机上不该白付这个钱。
    int? checkpoint;
    if (terminalMode) {
      final cp = await snapshots.checkpoint(reason: _brief(userInput));
      if (cp != null) {
        host.onStatus('检查点 #${cp.generation}（${cp.changes.length} 处变更）');
      }
      // 记 HEAD 而不是 cp.generation：本轮没改动时 checkpoint() 返回 null，
      // 但「回到这条消息」要回到的仍然是当前这个状态，不是上一次有变更的状态。
      checkpoint = snapshots.head;
    }

    // 描述排在用户那句话**前面**：模型读到的顺序和人一样 ——
    // 先看见图里有什么，再看见问题。反过来的话，模型读到问题时
    // 还不知道图里是什么，某些模型会先反问一句"哪张图？"。
    if (description != null) {
      final note = ChatMessage(
        role: 'system',
        content: description,
        at: DateTime.now(),
      );
      history.add(note);
      host.onContextMessage(note);
    }

    history.add(ChatMessage(
      role: 'user',
      content: userInput,
      at: DateTime.now(),
      checkpoint: checkpoint,
      images: images,
    ));

    // 压缩排在检索**前面**：检索是把"被摘要挤出去的东西"捞回来，
    // 而这一刻可能刚好有一批消息被挤出去。顺序反了的话，那一批要等到
    // 下一轮才捞得到。
    await _compact();
    await _retrieveInto(userInput);
    await _runRounds(epoch);
  }

  /// 发请求**之前**先压一次。
  ///
  /// 只在回合结束后压是不够的：那样「该被压缩的那一次请求」恰恰是没被
  /// 压缩的那一次。任何一个刚从库里读回来的长会话都会撞上这个 ——
  /// 摘要状态是 v12 才开始存的，在那之前的会话读回来一律是"还没摘过"，
  /// 于是第一次发送就把整段历史原样发出去，而那正是最贵、也最容易直接
  /// 撞上窗口上限的一刻。
  ///
  /// 回合结束后那一次仍然留着：一轮工具循环能往历史里塞进几十条消息，
  /// 不在结束时压一次的话，它们要一直等到下一次发送。
  Future<void> _compact() async {
    _reportCompaction(await overflow.onMessageAdded(history));
  }

  /// 回合结束之后那一次压缩：**发起，但不等它**。
  ///
  /// ## 为什么不能等
  ///
  /// 那一刻回答已经写完、已经交付了，这次压缩只是在给**下一轮**做准备。
  /// 等它的话，用户看着答案已经出来了，输入框却还要再灰上一整个请求的时间
  /// —— 而那段时间里 `+` 里的东西一个都点不了（那个按钮是按"正在生成"
  /// 灰掉的）。看起来就是"回答完了但 app 还卡着"。
  ///
  /// ## 不等安全吗
  ///
  /// 安全，而且这几条是它成立的全部依据：
  ///
  ///   - [OverflowManager.onMessageAdded] 自己不抛，失败只会记下原因；
  ///   - 它一进去就把要摘的那一段同步切出来，之后 history 再怎么变都不影响
  ///     手里这批；
  ///   - 中途历史被砍（回退、切分支）时 `truncateTo` 会把 epoch 推掉，
  ///     在途的结果会被丢弃，不会把一份对不上的摘要写回去；
  ///   - 同一时刻只会有一次（`_summarizing` 挡着），下一轮发送撞上它就跳过。
  void _compactLater() {
    unawaited(_compact().then((_) => host.onMemoryUpdated()));
  }

  /// 重新生成最后一条回复。
  ///
  /// 和 [send] 的差别只有一处：**不追加新的用户消息**，那条问话原样留着。
  /// 之前的做法是把用户那条删掉、把原文重新发一遍，代价是每重新生成一次
  /// 时间戳就变一次，而且[send] 的签名只收文本 —— 带图的那条消息重新生成
  /// 之后图会**静默消失**。
  ///
  /// 调用前请先把历史截断到那条用户消息为止。截断意味着丢内容，而丢之前
  /// 要不要先存成一个可切回的版本，是上层的决定，不该埋在这里。
  ///
  /// **不重新打检查点。** 「回到这条消息」要回到的是那一轮**开始之前**的
  /// 状态，跟你重新生成过几次没有关系；重打一个只会让回滚点悄悄前移到
  /// 第一次尝试改完文件之后。
  Future<void> regenerate() async {
    final epoch = _cancelEpoch;
    final anchor = history.lastWhere(
      (message) => message.role == 'user',
      orElse: () => ChatMessage(role: 'user', content: '', at: DateTime.now()),
    );
    await _compact();
    await _retrieveInto(anchor.content);
    await _runRounds(epoch);
  }

  /// 把被摘要挤出去、但这次提问用得上的内容捞回来。
  ///
  /// 主动检索而不是等模型调 recall_memory：模型经常不知道自己忘了什么。
  Future<void> _retrieveInto(String query) async {
    if (!overflow.hasSummary) return;
    final corpus = _corpus();
    // 先给新进入语料的消息补上向量。没配嵌入模型时这是个空操作。
    await retrieval.index(corpus);
    // 失败了不影响这一轮（检索会降级成两路词法），但必须说出来 ——
    // 用户配了嵌入模型却一直没生效的话，界面上得看得见。
    final embedError = retrieval.lastEmbeddingError;
    if (embedError != null) host.onStatus('嵌入检索不可用：$embedError');
    final hits = await retrieval.search(query, corpus, topK: 6);
    if (hits.isEmpty) return;
    final injected = retrieval.format(hits, tokenBudget: 600);
    if (injected.isEmpty) return;
    final note =
        ChatMessage(role: 'system', content: injected, at: DateTime.now());
    history.add(note);
    host.onContextMessage(note);
  }

  /// 一个回合：反复请求模型，直到它不再要工具为止。
  Future<void> _runRounds(int epoch) async {
    // 整轮累加。工具循环里一个回合会打好几次请求，用户要看的是这一问一答的
    // 总账 —— 只记最后一次的话，一个跑了八轮工具的任务会显示成"几乎没花钱"。
    var spent = const TokenUsage();

    // 挂给 UI 的那份是**整轮**的，不随中间写出的助手消息清零。
    var turnTotal = const TokenUsage();
    lastTurnUsage = null;

    for (var round = 0; round < maxToolRounds; round++) {
      final turn = await _completeWithRetry();
      if (epoch != _cancelEpoch) throw const AgentCancelledException();
      // 服务端回报了就用真值；没回报（不少网关流式下就是不给）退回估算，
      // 并且标记成估算 —— 不标的话用户会拿一个估出来的数去对账单。
      final measured = turn.usage ?? _estimateUsage(turn.text);
      spent = spent + measured;
      turnTotal = turnTotal + measured;
      lastTurnUsage = turnTotal.isEmpty ? null : turnTotal;

      // 一次请求既没有文本也没有工具调用 —— 这不是"模型没话说"，
      // 是这一轮什么都没发生。**必须报出来。**
      //
      // 实测踩过一次：baseUrl 填服务根地址时接口路径少了 `/v1`，
      // 打到了聚合网关的前端页面上，那个路径返回 200 + 一坨 HTML。
      // 每一层看起来都成功了（状态码 200、解析没抛），最后表现成
      // 「消息发出去了，没有任何回应，也没有报错」—— 这是最难查的一类失败。
      // 现在它会变成一条明确的错误消息。
      if (round == 0 && turn.text.isEmpty && turn.toolCalls.isEmpty) {
        throw EmptyCompletionException(llm.limitKey);
      }

      if (turn.text.isNotEmpty) {
        final written = ChatMessage(
          role: 'assistant',
          content: turn.text,
          at: DateTime.now(),
          source: sourceLabel,
          // 思考跟着**产出它的那一条**走。整轮攒到最后再挂的话，一个跑了
          // 八轮工具的任务会把八段思考堆在最后一条上，而每一段实际对应的
          // 是它前面那次决策。
          reasoning: turn.reasoning,
          reasoningMs: turn.reasoningMs,
          // 挂在**这一条**上而不是等回合结束再回填：中间轮次也可能产出正文
          // （模型边说边调工具），那些消息同样是这一轮的一部分。累加值挂在
          // 最后写出的那条上，前面几条各自带自己那一段。
          usage: spent.isEmpty ? null : spent,
        );
        history.add(written);
        host.onAssistantMessage(written);
        spent = const TokenUsage();
      }
      if (turn.toolCalls.isEmpty) break;

      for (final call in turn.toolCalls) {
        host.onToolStart(call);
        final result = await _dispatch(call);
        if (epoch != _cancelEpoch) throw const AgentCancelledException();
        final done = ChatMessage(
          role: 'tool',
          content: result.content,
          at: DateTime.now(),
          outputRef: result.outputRef,
          toolName: call.name,
          toolTitle: toolCallTitle(call.name, call.args),
          toolOk: !result.failed,
          toolMs: result.elapsedMs,
        );
        history.add(done);
        host.onToolEnd(done);
      }

      await _compact();
    }

    // 循环里那次**只有调用了工具的回合才走得到** —— 没有工具调用时
    // `if (turn.toolCalls.isEmpty) break;` 会先跳出去，检查根本不执行。
    //
    // 结果是：纯聊天的会话一次摘要都不会触发，上下文只增不减，直到撞上
    // 模型的窗口上限由 ContextLimitGuard 兜底。而聊天模式恰恰是最需要摘要的
    // 场景 —— 它没有工具输出可蒸馏，全是原文。
    //
    // 实测发现的：终端模式关掉后连聊十几轮，`overflow.checkpoint` 一直是 0。
    //
    // **这一次不等。** 回答已经交付，它只是给下一轮做准备 —— 见 _compactLater。
    _compactLater();
  }

  /// 把压缩的结果说出来 —— **成功和失败都要说**。
  ///
  /// 失败原来是全静默的：摘要请求 404 了，用户看到的只是"聊久了越来越慢"，
  /// 而设置页里那一行还写着「还没有触发过摘要」。两句话都对，合起来却指不到
  /// 任何一个能查的方向。
  void _reportCompaction(bool summarized) {
    if (summarized) {
      host.onStatus('已整理长期记忆（摘要覆盖到第 ${overflow.checkpoint} 条）');
      return;
    }
    final why = overflow.takeUnreportedError();
    if (why != null) host.onStatus('长期记忆整理失败，已保留原文：$why');
  }

  void cancel() {
    _cancelEpoch++;
    final currentLlm = llm;
    if (currentLlm is CancellableLlmClient) {
      (currentLlm as CancellableLlmClient).cancel();
    }
    sandbox.cancelActive();
  }

  Future<void> retryLastUserTurn() async {
    final index = history.lastIndexWhere((message) => message.role == 'user');
    if (index < 0) return;
    final input = history[index].content;
    history.removeRange(index, history.length);
    // 历史短了，摘要状态要跟着收。砍进摘要覆盖的那一段时它会整份作废 ——
    // 见 [OverflowManager.truncateTo]。
    overflow.truncateTo(history.length);
    await send(input);
  }

  /// 回到 history 里第 [index] 条消息之前的状态。
  ///
  /// 两件事一起做：截断对话，**并且**把 workspace 回滚到那条消息记下的检查点。
  /// 只做前者的话，模型会对着一个它以为还没改过、实际已经被改过的 workspace
  /// 重新推理 —— 那种不一致比不回滚更难查。
  ///
  /// 返回被丢弃的消息，调用方可以拿它做「撤销回滚」或者填回输入框。
  Future<RewindResult> rewindTo(int index) async {
    if (index < 0 || index >= history.length) {
      return const RewindResult(dropped: [], rolledBackTo: null);
    }
    final target = history[index];
    final dropped = history.sublist(index).toList(growable: false);
    history.removeRange(index, history.length);
    overflow.truncateTo(history.length);

    // 老会话的消息没有检查点记录（v3 之前的库）。这时只截对话，
    // 并让调用方知道文件没回滚 —— 假装回滚过才是危险的。
    final generation = target.checkpoint;
    if (generation == null) {
      return RewindResult(dropped: dropped, rolledBackTo: null);
    }
    if (generation == snapshots.head) {
      // 已经在那个状态上，rollback 是空操作，但仍然算「回滚到了」。
      return RewindResult(dropped: dropped, rolledBackTo: generation);
    }
    final report = await snapshots.rollbackTo(generation);
    // 有存不回来的文件时必须说出来。一次"部分成功"的回滚被报告成成功，
    // 用户会基于错误的前提继续往下做。
    host.onStatus(report.unrecoverable.isEmpty
        ? '已回到检查点 #$generation（恢复 ${report.restored.length} 个文件）'
        : '已回到检查点 #$generation，但 ${report.unrecoverable.length} 个文件'
            '的旧内容没存下来，无法恢复');
    return RewindResult(
      dropped: dropped,
      rolledBackTo: generation,
      unrecoverable: report.unrecoverable,
    );
  }

  /// 撞到上下文超长时：学一次真实窗口，裁剪，重试一次。
  ///
  /// 只重试一次。裁完还超说明 ContextLimitGuard 学到的 ratio 仍然不准，
  /// 无限重试只会烧掉配额；报错让用户看见、让 guard 记下 hits+1，
  /// 下一轮的收紧系数会更狠。
  /// 最近一轮 [send] 的总用量。
  ///
  /// 正常收尾时用不到它 —— 每一段正文都由 [AgentHost.onAssistantMessage]
  /// 原样交给界面，用量就挂在那一条上。
  ///
  /// 它是给**没能正常收尾**的那一轮兜底的：用户按了停止、或者中途断线，
  /// 文字流出来了一半但没进 history，界面只能自己造一条气泡 —— 那条气泡
  /// 拿不到 history 里逐条挂着的用量，只能用这个整轮的数。
  TokenUsage? lastTurnUsage;

  /// 上一次实际发出去的那批消息估算出的 token 数。
  ///
  /// 在 [_completeWithRetry] 里现算而不是事后重建：重建要复现人格提示、摘要、
  /// 检索注入和窗口裁剪的全部结果，任何一处对不上，估出来的就是另一次请求的量。
  int _lastPromptEstimate = 0;

  /// 服务端没回报用量时的兜底。
  TokenUsage _estimateUsage(String reply) => TokenUsage(
        input: _lastPromptEstimate,
        output: TokenCounter.estimate(reply),
        estimated: true,
      );

  Future<LlmTurn> _completeWithRetry() async {
    // 人格提示每次现拼，不进 history —— 进了就会被一起持久化，
    // 于是每次开线程都多出一条旧的、可能还是另一个模式下写的提示。
    var messages = <ChatMessage>[
      ChatMessage(role: 'system', content: _persona(), at: DateTime.now()),
      ...overflow.buildWindow(history),
    ];
    _lastPromptEstimate = TokenCounter.estimateMessages(
      messages.map((m) => (role: m.role, content: m.content)),
    );
    // `supportsTools` 是最后一道闸。UI 那边已经拦过一次了，这里再拦是因为
    // 「终端模式开着」和「当前模型认工具」是两个独立变化的状态，中间任何一次
    // 时序意外（换模型和发送撞在一起）都会让 tools 发到一个不认它的模型手上。
    final tools =
        terminalMode && supportsTools ? allToolSpecs : const <ToolSpec>[];

    for (var attempt = 0; attempt < 2; attempt++) {
      final budget = limitGuard.budgetFor(llm.limitKey);
      if (budget > 0) messages = _trimTo(messages, budget);

      try {
        return await llm.complete(
          messages: messages,
          tools: tools,
          onDelta: host.onAssistantDelta,
          onReasoning: host.onAssistantReasoning,
        );
      } on ContextOverflowException catch (e) {
        final estimate = TokenCounter.estimateMessages(
            messages.map((m) => (role: m.role, content: m.content)));
        final newBudget = limitGuard.learn(
          key: llm.limitKey,
          body: e.body,
          ourEstimate: estimate,
        );
        if (newBudget <= 0 || attempt == 1) rethrow;
        host.onStatus('服务端上下文窗口比预期小，已按 $newBudget token 重新裁剪');
        messages = _trimTo([
          ChatMessage(role: 'system', content: _persona(), at: DateTime.now()),
          ...overflow.buildWindow(history),
        ], newBudget);
      }
    }
    throw StateError('unreachable');
  }

  /// 从尾部往前保留，直到预算用完。
  ///
  /// system 消息永远保留 —— 它装着人格、工具约定和摘要，裁掉它模型会当场失忆。
  /// 这个「从尾部保留」的方向也很关键：最近的消息是当前任务的上下文，
  /// 从头保留会得到一堆和当下无关的开场白。
  List<ChatMessage> _trimTo(List<ChatMessage> msgs, int budget) {
    final systems = msgs.where((m) => m.role == 'system').toList();
    final rest = msgs.where((m) => m.role != 'system').toList();

    var used = TokenCounter.estimateMessages(
        systems.map((m) => (role: m.role, content: m.content)));
    final kept = <ChatMessage>[];

    for (var i = rest.length - 1; i >= 0; i--) {
      final cost = TokenCounter.estimate(rest[i].content) +
          TokenCounter.perMessageOverhead;
      if (used + cost > budget) break;
      kept.insert(0, rest[i]);
      used += cost;
    }
    return [...systems, ...kept];
  }

  // -------------------------------------------------------------------------
  // 工具分发
  // -------------------------------------------------------------------------

  Future<ToolResult> _dispatch(ToolCall call) async {
    // 聊天模式下压根没发过 tool schema，能走到这里说明模型自己编了一个
    // 调用（本地小模型很常见）。当成普通拒绝返回，而不是抛异常 ——
    // 抛出去整个回合就废了，返回一句话模型下一轮就会改用文字回答。
    if (!terminalMode) {
      return const ToolResult.rejected('当前是聊天模式，没有任何工具可用。需要执行命令或读写文件的话，'
          '请让用户在输入框下方勾选「终端模式」。');
    }

    // read_skill 要拿到 SkillStore，而 runReadOnlyTool 是个纯函数、
    // 只认 workspace 路径。所以在进那条快路之前先截住它。
    if (call.name == 'read_skill') {
      return _readSkill(call);
    }

    // 只读工具走快路：不判策略、不打检查点。
    if (readOnlyTools.contains(call.name)) {
      return runReadOnlyTool(call, sandbox.workspacePath);
    }

    if (mode == ApprovalMode.readOnly) {
      return ToolResult.rejected('当前是只读模式，${call.name} 被拒绝。'
          '如需执行请让用户切换审批档位。');
    }

    // 回滚类工具自己就是安全阀，不需要再套一层审批 ——
    // 但 rollback 会丢弃改动，所以仍然要问一句。
    switch (call.name) {
      case 'checkpoint':
        final cp = await snapshots.checkpoint(
            reason: call.args['reason'] as String? ?? '模型主动存档');
        return ToolResult.ok(cp == null
            ? '当前无变更，未创建新检查点（HEAD 仍为 #${snapshots.head}）'
            : '已创建检查点 #${cp.generation}，记录了 ${cp.changes.length} 处变更');

      case 'list_checkpoints':
        return ToolResult.ok(_formatCheckpoints());

      case 'rollback':
        final target = (call.args['generation'] as num?)?.toInt();
        if (target == null) {
          return const ToolResult.rejected('rollback 缺少 generation 参数');
        }
        if (mode != ApprovalMode.yolo) {
          final ok = await host.requestApproval(
              call,
              PolicyVerdict(
                decision: Decision.prompt,
                scope: WriteScope.workspace,
                reason: '回滚到检查点 #$target，之后的所有改动会被撤销',
              ));
          if (!ok) return const ToolResult.rejected('用户拒绝了回滚');
        }
        final report = await snapshots.rollbackTo(target);
        await snapshots.gc();
        host.onStatus(report.toString());
        // 回滚报告要原样交给模型，尤其是 unrecoverable 那部分 ——
        // 让它以为回滚干净了然后基于错误前提继续，比回滚失败本身更糟。
        return ToolResult.ok(report.toString());
    }

    // 其余的走策略判定。
    final commandLine = call.name == 'exec'
        ? (call.args['command'] as String? ?? '')
        : '${call.name} ${call.args['path'] ?? ''}';
    // 沙箱开着时这一层不否决任何东西 —— 边界是 proot，不是这张规则表。
    // 关掉沙箱之后每条命令都要问，除非用户自己放行过。
    final verdict = policy.evaluate(
      commandLine,
      sandboxed: sandboxLevel != SandboxLevel.dangerFullAccess,
    );

    if (verdict.decision == Decision.forbidden) {
      return ToolResult.rejected('该命令被策略禁止：${verdict.reason}。'
          '请换一种做法，不要重试同一条命令。');
    }

    // 关了沙箱就一律要审批，连 `auto` 也不例外：那一档的前提是"沙箱兜底"，
    // 沙箱没了，前提也就没了。
    final needsApproval = verdict.decision == Decision.prompt &&
        (mode == ApprovalMode.onRequest ||
            sandboxLevel == SandboxLevel.dangerFullAccess);
    if (needsApproval && !await host.requestApproval(call, verdict)) {
      return ToolResult.rejected('用户拒绝了这次操作（${verdict.reason}）。'
          '请说明你为什么需要它，或换一种做法。');
    }

    // 会写盘就先存档。这一步在审批之后 —— 被拒的操作不该留下空检查点。
    if (verdict.isMutating) {
      final cp = await snapshots.checkpoint(reason: _brief(commandLine));
      if (cp != null) host.onStatus('执行前检查点 #${cp.generation}');
    }

    // 改 $PREFIX 的走事务，和普通命令完全不同的一条路。
    if (verdict.scope == WriteScope.prefix) {
      return _runInPrefixTransaction(commandLine);
    }

    return _runExec(call, commandLine);
  }

  Future<ToolResult> _runExec(ToolCall call, String commandLine) async {
    if (call.name != 'exec') {
      return runWriteTool(call, sandbox.workspacePath, snapshots);
    }

    final ref =
        'out_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
    final sinkFile = File('${outputArchiveDir.path}/$ref.log');
    await sinkFile.parent.create(recursive: true);

    final level = mode == ApprovalMode.yolo
        ? SandboxLevel.dangerFullAccess
        : sandboxLevel;

    final result = await sandbox.run(
      commandLine,
      level: level,
      outputSink: sinkFile,
      timeout:
          Duration(seconds: (call.args['timeout'] as num?)?.toInt() ?? 300),
      onChunk: host.onTerminalChunk,
    );

    final raw = await sinkFile.readAsString();
    final distilled = distiller.distill(
      command: commandLine,
      raw: raw,
      ref: ref,
      exitCode: result.exitCode,
      elapsed: result.elapsed,
      timedOut: result.timedOut,
      sandboxDenials: result.sandboxDenials,
    );

    return ToolResult.ok(
      distilled.text,
      outputRef: ref,
      exitCode: result.exitCode,
      elapsedMs: result.elapsed.inMilliseconds,
    );
  }

  /// `pkg install` 这类：在 `$PREFIX` 的暂存副本里跑，成功才原子切换。
  ///
  /// 装包失败在手机上很常见（源不通、依赖冲突、存储不足），
  /// 而失败的 apt 会留下一个半安装状态的 dpkg 数据库 —— 那才是真正难修的坏。
  /// 事务化之后失败就是「什么都没发生」。
  Future<ToolResult> _runInPrefixTransaction(String commandLine) async {
    final tx = await prefixGens.begin(reason: _brief(commandLine));
    host.onStatus('已创建环境暂存副本，改动不会直接落到当前环境');

    final ref =
        'out_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
    final sinkFile = File('${outputArchiveDir.path}/$ref.log');
    await sinkFile.parent.create(recursive: true);

    // 装包必须联网，所以这里强制用联网档位 —— 但也仅限这条命令。
    // 关键：rootfsPath 指向**暂存副本**而不是正在用的那份。
    // 装包过程中的一切写入都落在副本里，失败就整份丢掉。
    final txSandbox = SandboxSession(
      rootfsPath: tx.stagingPath,
      workspacePath: sandbox.workspacePath,
      caps: sandbox.caps,
      spawner: sandbox.spawner,
      distroReady: sandbox.distroReady,
      distroLabel: sandbox.distroLabel,
      packageManager: sandbox.packageManager,
      launcherPath: sandbox.launcherPath,
      prootPath: sandbox.prootPath,
      prootLoaderPath: sandbox.prootLoaderPath,
      prootLoader32Path: sandbox.prootLoader32Path,
      tmpPath: sandbox.tmpPath,
    );

    final result = await txSandbox.run(
      commandLine,
      level: SandboxLevel.workspaceWriteNetwork,
      outputSink: sinkFile,
      timeout: const Duration(minutes: 15), // 装包慢，给足时间
      onChunk: host.onTerminalChunk,
    );

    final raw = await sinkFile.readAsString();
    final distilled = distiller.distill(
      command: commandLine,
      raw: raw,
      ref: ref,
      exitCode: result.exitCode,
      elapsed: result.elapsed,
      timedOut: result.timedOut,
      sandboxDenials: result.sandboxDenials,
    );

    if (result.exitCode == 0 && !result.timedOut) {
      final gen = await tx.commit();
      // hardlink 穿透的兜底校验，见 PrefixGenerations.verifyEtc 的注释。
      final fixed = await prefixGens.verifyEtc(gen.id);
      host.onStatus('环境已更新（第 ${gen.id} 代）'
          '${fixed.isEmpty ? '' : '，修复 ${fixed.length} 处 hardlink 穿透'}');
      return ToolResult.ok(
          '${distilled.text}\n'
          '[环境变更已提交为第 ${gen.id} 代，可用 rollback_env 回退]',
          outputRef: ref,
          exitCode: result.exitCode,
          elapsedMs: result.elapsed.inMilliseconds);
    }

    await tx.abort();
    host.onStatus('装包失败，环境已回到操作前状态');
    return ToolResult.ok(
        '${distilled.text}\n'
        '[命令失败，环境暂存副本已丢弃，当前环境未发生任何变化]',
        outputRef: ref,
        // 超时没有退出码可言，给一个非 0 值，界面才画得出「失败」。
        exitCode: result.timedOut ? -1 : result.exitCode,
        elapsedMs: result.elapsed.inMilliseconds);
  }

  Future<ToolResult> _readSkill(ToolCall call) async {
    final name = (call.args['name'] as String?)?.trim() ?? '';
    if (name.isEmpty) return const ToolResult.rejected('read_skill 缺少 name');

    final store = skills;
    final text = store == null ? null : await store.readSkill(name);
    if (text == null) {
      // 把可用清单一起回给模型。只说"没找到"的话它会反复猜名字，
      // 而正确的名字就在系统提示里 —— 直接贴出来一轮就能纠正。
      final available = store?.enabled.map((s) => s.name).join('、') ?? '（无）';
      return ToolResult.rejected('没有名为 $name 的 skill。当前可用：$available');
    }
    return ToolResult.ok(text);
  }

  // -------------------------------------------------------------------------

  /// 系统提示。两个模式给两份，差别不只是措辞。
  ///
  /// 聊天模式那份要**明确说出「我现在没有工具」**。不说的话模型会按训练里
  /// 的习惯承诺「我来帮你跑一下」，然后什么都没发生 —— 用户看到的是一个
  /// 会撒谎的助手，而实际上只是没人告诉它手被绑着。顺带把开关在哪告诉它，
  /// 这样它能自己引导用户去勾。
  /// 内置那份和用户那份怎么拼，取决于内置那份的**性质**：
  ///
  ///   - **终端模式**下它装着工具契约和沙箱事实（用哪个工具改文件、默认
  ///     断网、输出会被压缩）。这些不是风格偏好，是**模型不知道就会干错事**
  ///     的硬信息，所以用户那份只能追加在后面，覆盖不掉。
  ///   - **聊天模式**下它只有一句人格加一句"你没有工具"。用户写了自己的
  ///     人格就该由用户那份说了算 —— 否则「系统提示词」这个功能等于只能给
  ///     内置人格打补丁，那不叫系统提示词。只保留"没有工具"那句，
  ///     它防的是模型假装自己执行了命令。
  String _persona() {
    final custom = userSystemPrompt.trim();

    if (!terminalMode) {
      if (custom.isNotEmpty) {
        return '$custom\n\n'
            '（另：你现在没有任何工具，不能执行命令、读写文件或联网。'
            '需要这些能力时告诉用户「在输入框下方勾选『终端模式』」，'
            '不要假装自己已经执行了什么。）';
      }
      return '你是 Burrow，一个装在手机上的助手。\n'
          '当前是**聊天模式**：你没有任何工具，不能执行命令、'
          '不能读写文件、不能联网。需要这些能力时，直接告诉用户'
          '「在输入框下方勾选『终端模式』」，不要假装自己已经执行了什么。\n'
          '回答用中文，简洁、直接，别铺排套话。';
    }

    final distro =
        sandbox.distroLabel.isEmpty ? '一个 Linux 发行版' : sandbox.distroLabel;
    final pm = sandbox.packageManager.isEmpty
        ? '见 /etc/os-release'
        : sandbox.packageManager;
    final env = sandbox.distroReady
        ? '$distro（包管理器 $pm）'
        : 'Android 自带的 mksh（**没有**包管理器，绝大多数命令不存在）';

    return '你是 Burrow，一个装在手机上的编程 Agent。\n'
        '你的命令跑在 $env 里，工作目录是 /workspace，'
        '和用户手机的其它部分隔离。\n'
        '\n'
        '几条硬规则：\n'
        '1. 改文件用 write_file / apply_patch，别用 `cat >` `sed -i` —— '
        '专用工具的改动能被精确回滚，shell 里的不能。\n'
        '2. 动手做有风险的改动前先 checkpoint。搞砸了直接 rollback，'
        '回滚很便宜，不要在坏状态上继续修补。\n'
        '3. 默认断网。命令报网络不通多半是沙箱拦的，不是网络故障，'
        '别反复重试 —— 装包这类需要联网的操作照常发起，外层会自动放行。\n'
        '4. 命令输出会被压缩后给你，需要细节用 grep_output 按 ref 查，'
        '别为了看全量输出重跑一遍命令。\n'
        '回答用中文，简洁、直接。$skillSection'
        // 用户那份放最后：同一个系统提示里靠后的指令通常更占上风，
        // 而上面那几条硬规则是靠"它们是唯一的事实来源"生效的，
        // 不靠位置 —— 用户没法把 write_file 说成不存在。
        '${custom.isEmpty ? '' : '\n\n$custom'}';
  }

  /// skill 清单，接在系统提示末尾。
  ///
  /// 只放名字和一句话描述（见 SkillStore 里关于渐进式披露的说明）。
  /// 关着的和没装的都不进来 —— 提到一个读不了的 skill，
  /// 模型会去调 read_skill 然后拿到一个失败，白白烧掉一轮。
  String get skillSection {
    final section = skills?.promptSection() ?? '';
    return section.isEmpty ? '' : '\n\n$section';
  }

  /// 被摘要挤出窗口、但还能被检索回来的那一段。
  ///
  /// ## 为什么条目的身份是内容，不是位置
  ///
  /// [MemoryDoc.source] 是向量缓存的键（见 `MemoryRetrieval.vectorIndex`），
  /// 而缓存只认"这个键有没有算过"。以前这里写的是 `history:$i` —— 一个**位置**。
  /// 而位置随时会整体错开：
  ///
  ///   - 打开长会话时先只读最后一页，更早的那些在后台补进历史**开头**，
  ///     一补就是几百条 —— 之后每一个下标指的都是别的消息了；
  ///   - 回退、删除、切分支都会把一段换掉，新消息接着占用同样的下标。
  ///
  /// 缓存不会因此重算（键还在），于是"第 12 条"的向量还是上一段内容的。
  /// 语义那一路从此一直给不相干的结果，**而且不报错**：检索照常返回，
  /// 只是返回的东西和问题没关系。
  ///
  /// 按内容取键就没有这个问题：内容变了键就变，键相同则内容一定相同
  /// （顺带把重复内容的嵌入费用也省了）。
  List<MemoryDoc> _corpus() {
    final docs = <MemoryDoc>[];
    for (var i = 0; i < overflow.checkpoint && i < history.length; i++) {
      final text = '${history[i].role}: ${history[i].content}';
      docs.add(MemoryDoc(
        text: text,
        at: history[i].at,
        importance: history[i].role == 'user' ? 0.6 : 0.5,
        source: memoryDocKey(text),
      ));
    }
    return docs;
  }

  String _formatCheckpoints() {
    if (snapshots.checkpoints.isEmpty) return '暂无检查点（HEAD = #0）';
    final b = StringBuffer('检查点列表（HEAD = #${snapshots.head}）：\n');
    for (final cp in snapshots.checkpoints.reversed.take(15)) {
      b.writeln('#${cp.generation}  ${cp.createdAt.toIso8601String()}  '
          '${cp.changes.length} 处变更  ${cp.reason}');
    }
    return b.toString();
  }

  static String _brief(String s) {
    final line = s.split('\n').first.trim();
    return line.length > 80 ? '${line.substring(0, 80)}…' : line;
  }
}
