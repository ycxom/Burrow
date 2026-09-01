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

  /// 命令输出的实时字节流，喂给终端视图。
  void onTerminalChunk(List<int> chunk);

  /// 状态变化：打了检查点、触发了摘要、沙箱降级等。用于 UI 上的小提示。
  void onStatus(String message);
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
  const LlmTurn({required this.text, this.toolCalls = const []});
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

  /// 全量历史。**永不删除** —— overflow 只控制哪些进 prompt。
  final List<ChatMessage> history = [];

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
    this.mode = ApprovalMode.onRequest,
    this.sandboxLevel = SandboxLevel.workspaceWrite,
    this.terminalMode = false,
    this.maxToolRounds = 24,
  });

  Future<void> send(String userInput) async {
    final epoch = _cancelEpoch;
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

    history.add(ChatMessage(
      role: 'user',
      content: userInput,
      at: DateTime.now(),
      checkpoint: checkpoint,
    ));

    // 用户提问里如果指向了被摘要挤出去的内容，先把它捞回来。
    // 主动检索而不是等模型调 recall_memory：模型经常不知道自己忘了什么。
    if (overflow.hasSummary) {
      final corpus = _corpus();
      // 先给新进入语料的消息补上向量。没配嵌入模型时这是个空操作。
      await retrieval.index(corpus);
      // 失败了不影响这一轮（检索会降级成两路词法），但必须说出来 ——
      // 用户配了嵌入模型却一直没生效的话，界面上得看得见。
      final embedError = retrieval.lastEmbeddingError;
      if (embedError != null) host.onStatus('嵌入检索不可用：$embedError');
      final hits = await retrieval.search(userInput, corpus, topK: 6);
      if (hits.isNotEmpty) {
        final injected = retrieval.format(hits, tokenBudget: 600);
        if (injected.isNotEmpty) {
          history.add(ChatMessage(
              role: 'system', content: injected, at: DateTime.now()));
        }
      }
    }

    for (var round = 0; round < maxToolRounds; round++) {
      final turn = await _completeWithRetry();
      if (epoch != _cancelEpoch) throw const AgentCancelledException();

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
        history.add(ChatMessage(
            role: 'assistant', content: turn.text, at: DateTime.now()));
      }
      if (turn.toolCalls.isEmpty) break;

      for (final call in turn.toolCalls) {
        final result = await _dispatch(call);
        if (epoch != _cancelEpoch) throw const AgentCancelledException();
        history.add(ChatMessage(
          role: 'tool',
          content: result.content,
          at: DateTime.now(),
          outputRef: result.outputRef,
        ));
      }

      if (await overflow.onMessageAdded(history)) {
        host.onStatus('已整理长期记忆（摘要覆盖到第 ${overflow.checkpoint} 条）');
      }
    }

    // 循环里那次**只有调用了工具的回合才走得到** —— 没有工具调用时
    // `if (turn.toolCalls.isEmpty) break;` 会先跳出去，检查根本不执行。
    //
    // 结果是：纯聊天的会话一次摘要都不会触发，上下文只增不减，直到撞上
    // 模型的窗口上限由 ContextLimitGuard 兜底。而聊天模式恰恰是最需要摘要的
    // 场景 —— 它没有工具输出可蒸馏，全是原文。
    //
    // 实测发现的：终端模式关掉后连聊十几轮，`overflow.checkpoint` 一直是 0。
    if (await overflow.onMessageAdded(history)) {
      host.onStatus('已整理长期记忆（摘要覆盖到第 ${overflow.checkpoint} 条）');
    }
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
  Future<LlmTurn> _completeWithRetry() async {
    // 人格提示每次现拼，不进 history —— 进了就会被一起持久化，
    // 于是每次开线程都多出一条旧的、可能还是另一个模式下写的提示。
    var messages = <ChatMessage>[
      ChatMessage(role: 'system', content: _persona(), at: DateTime.now()),
      ...overflow.buildWindow(history),
    ];
    final tools = terminalMode ? allToolSpecs : const <ToolSpec>[];

    for (var attempt = 0; attempt < 2; attempt++) {
      final budget = limitGuard.budgetFor(llm.limitKey);
      if (budget > 0) messages = _trimTo(messages, budget);

      try {
        return await llm.complete(
          messages: messages,
          tools: tools,
          onDelta: host.onAssistantDelta,
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
    final verdict = policy.evaluate(commandLine);

    if (verdict.decision == Decision.forbidden) {
      return ToolResult.rejected('该命令被策略禁止：${verdict.reason}。'
          '请换一种做法，不要重试同一条命令。');
    }

    final needsApproval =
        verdict.decision == Decision.prompt && mode == ApprovalMode.onRequest;
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

    return ToolResult.ok(distilled.text, outputRef: ref);
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
          outputRef: ref);
    }

    await tx.abort();
    host.onStatus('装包失败，环境已回到操作前状态');
    return ToolResult.ok(
        '${distilled.text}\n'
        '[命令失败，环境暂存副本已丢弃，当前环境未发生任何变化]',
        outputRef: ref);
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
  String _persona() {
    if (!terminalMode) {
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
        '回答用中文，简洁、直接。$skillSection';
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

  List<MemoryDoc> _corpus() => [
        for (var i = 0; i < overflow.checkpoint && i < history.length; i++)
          MemoryDoc(
            text: '${history[i].role}: ${history[i].content}',
            at: history[i].at,
            importance: history[i].role == 'user' ? 0.6 : 0.5,
            source: 'history:$i',
          ),
      ];

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
