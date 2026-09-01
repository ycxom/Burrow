/// 终端模式（聊天 ↔ Agent 切换）与运行中挂载基座的测试。
///
/// 这两件事在真机上都很难复现：一个要有 LLM 服务，一个要下几十 MB rootfs。
/// 所以关键判断全部下沉到纯 Dart 层，在这里测。
library;

import 'dart:convert';
import 'dart:io';

import 'package:burrow/src/agent/agent_loop.dart';
import 'package:burrow/src/agent/tools.dart';
import 'package:burrow/src/context/context_limit_guard.dart';
import 'package:burrow/src/context/memory_retrieval.dart';
import 'package:burrow/src/context/output_distiller.dart';
import 'package:burrow/src/context/overflow_manager.dart';
import 'package:burrow/src/sandbox/exec_policy.dart';
import 'package:burrow/src/sandbox/prefix_generations.dart';
import 'package:burrow/src/sandbox/sandbox_session.dart';
import 'package:burrow/src/sandbox/snapshot_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// 记录每次请求收到的 tools 和 messages，并按脚本返回回合。
class _ScriptedLlm implements LlmClient {
  _ScriptedLlm(this._turns);

  final List<LlmTurn> _turns;
  final List<List<ToolSpec>> toolsSeen = <List<ToolSpec>>[];
  final List<List<ChatMessage>> messagesSeen = <List<ChatMessage>>[];
  int _next = 0;

  @override
  String get limitKey => 'test';

  @override
  Future<LlmTurn> complete({
    required List<ChatMessage> messages,
    required List<ToolSpec> tools,
    required void Function(String delta) onDelta,
  }) async {
    toolsSeen.add(tools);
    messagesSeen.add(messages);
    final turn =
        _next < _turns.length ? _turns[_next++] : const LlmTurn(text: '完');
    if (turn.text.isNotEmpty) onDelta(turn.text);
    return turn;
  }
}

class _RecordingHost implements AgentHost {
  final List<String> statuses = <String>[];
  int approvalsAsked = 0;

  @override
  Future<bool> requestApproval(ToolCall call, PolicyVerdict verdict) async {
    approvalsAsked++;
    return true;
  }

  @override
  void onAssistantDelta(String text) {}

  @override
  void onTerminalChunk(List<int> chunk) {}

  @override
  void onStatus(String message) => statuses.add(message);
}

class _NeverSpawns implements NativePtySpawner {
  @override
  Future<PtyHandle> spawn({
    required List<String> argv,
    required Map<String, String> env,
    required String cwd,
    int rows = 24,
    int cols = 80,
  }) =>
      throw StateError('聊天模式不该拉起任何进程');
}

const _noCaps = SandboxCapabilities(
  proot: false,
  seccomp: false,
  landlockAbi: 0,
  rlimit: false,
);

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('burrow_mode_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<(AgentLoop, _ScriptedLlm, _RecordingHost)> buildLoop(
    List<LlmTurn> turns, {
    OverflowManager? overflow,
  }) async {
    final workspace = Directory('${tmp.path}/workspace');
    await workspace.create(recursive: true);
    final snapshots = SnapshotStore(
      workspace: workspace,
      metaRoot: Directory('${tmp.path}/meta'),
    );
    await snapshots.open();
    final gens = PrefixGenerations(filesRoot: Directory('${tmp.path}/distro'));
    await gens.open();

    final llm = _ScriptedLlm(turns);
    final host = _RecordingHost();
    return (
      AgentLoop(
        llm: llm,
        host: host,
        policy: ExecPolicy(),
        sandbox: SandboxSession(
          rootfsPath: '',
          workspacePath: workspace.path,
          caps: _noCaps,
          spawner: _NeverSpawns(),
          distroReady: false,
          tmpPath: '${tmp.path}/tmp',
        ),
        snapshots: snapshots,
        prefixGens: gens,
        overflow: overflow ?? OverflowManager(summarize: (a, b) async => ''),
        retrieval: MemoryRetrieval(),
        distiller: OutputDistiller(),
        limitGuard: ContextLimitGuard(),
        outputArchiveDir: Directory('${tmp.path}/outputs'),
      ),
      llm,
      host,
    );
  }

  group('助手消息记下自己的来源', () {
    test('署名写进消息，不是显示时现取', () async {
      // 换个渠道就把满屏历史全部改署成新渠道的话，恰好会在用户回头查
      // 「刚才那次是谁花的额度」时给出错误答案。
      final (agent, _, _) = await buildLoop(<LlmTurn>[
        const LlmTurn(text: '第一次'),
      ]);
      agent.sourceLabel = '本地网关 · glm-5';
      await agent.send('你好');

      final first = agent.history.lastWhere((m) => m.role == 'assistant');
      expect(first.source, '本地网关 · glm-5');

      // 换渠道之后再发一条：旧的那条**不动**。
      agent.sourceLabel = 'OpenAI · gpt-5';
      await agent.send('再来');
      final all = agent.history.where((m) => m.role == 'assistant').toList();
      expect(all.first.source, '本地网关 · glm-5');
      expect(all.last.source, 'OpenAI · gpt-5');
    });

    test('没设来源时留空，而不是编一个', () async {
      // 空值的意思是"不知道"，UI 据此不署名。补一个当前渠道上去，
      // 就是给历史消息盖一个多半是错的章。
      final (agent, _, _) =
          await buildLoop(<LlmTurn>[const LlmTurn(text: '嗨')]);
      await agent.send('你好');
      expect(
        agent.history.lastWhere((m) => m.role == 'assistant').source,
        isNull,
      );
    });
  });

  group('滚动摘要的触发时机', () {
    test('纯聊天的回合也会触发摘要', () async {
      // 这条钉的是一个实测踩到的 bug：摘要检查原先写在工具轮循环的**末尾**，
      // 而没有工具调用时 `if (turn.toolCalls.isEmpty) break;` 会先跳出去，
      // 检查一次都执行不到。于是聊天模式下上下文只增不减 ——
      // 而那恰恰是最需要摘要的场景，它没有工具输出可蒸馏，全是原文。
      var summarizeCalls = 0;
      final overflow = OverflowManager(
        summarize: (a, b) async {
          summarizeCalls++;
          return '之前聊了一些东西';
        },
        messageThreshold: 2, // 攒够 2×2 = 4 条就摘要
        tokenThreshold: 1 << 30, // token 那条路让开，只测条数
      );
      final (agent, _, host) = await buildLoop(
        [for (var i = 0; i < 6; i++) const LlmTurn(text: '好的')],
        overflow: overflow,
      );
      agent.terminalMode = false;

      for (var i = 0; i < 3; i++) {
        await agent.send('第 $i 句');
      }

      expect(summarizeCalls, greaterThan(0), reason: '一次工具都没调用，但摘要必须照常触发');
      expect(overflow.checkpoint, greaterThan(0));
      expect(host.statuses.any((s) => s.contains('已整理长期记忆')), isTrue,
          reason: '触发了就要让用户知道');
    });
  });

  group('终端模式开关', () {
    test('关着时一个工具都不发给模型', () async {
      final (agent, llm, _) = await buildLoop([const LlmTurn(text: '你好')]);
      agent.terminalMode = false;

      await agent.send('讲讲 Rust 的所有权');

      expect(llm.toolsSeen.single, isEmpty,
          reason: '聊天模式还发 schema 的话，模型会为了用工具而用工具');
    });

    test('开着时发全套工具', () async {
      final (agent, llm, _) = await buildLoop([const LlmTurn(text: '好')]);
      agent.terminalMode = true;

      await agent.send('把仓库编出来');

      expect(llm.toolsSeen.single.length, allToolSpecs.length);
    });

    test('系统提示随模式切换，且不落进 history', () async {
      final (agent, llm, _) = await buildLoop([
        const LlmTurn(text: 'a'),
        const LlmTurn(text: 'b'),
      ]);

      agent.terminalMode = false;
      await agent.send('一');
      expect(llm.messagesSeen.first.first.role, 'system');
      expect(llm.messagesSeen.first.first.content, contains('聊天模式'));

      agent.terminalMode = true;
      await agent.send('二');
      expect(llm.messagesSeen.last.first.content, contains('/workspace'));

      // 人格是每次现拼的。落进 history 就会被一起持久化，
      // 下次打开这个会话会多出一条属于另一个模式的旧提示。
      expect(agent.history.where((m) => m.role == 'system'), isEmpty);
    });

    test('聊天模式下模型硬编出来的工具调用被拒，且不打扰用户', () async {
      final (agent, _, host) = await buildLoop([
        const LlmTurn(text: '我来看看', toolCalls: [
          ToolCall(id: '1', name: 'exec', args: {'command': 'ls'}),
        ]),
        const LlmTurn(text: '抱歉，我现在没有工具'),
      ]);
      agent.terminalMode = false;

      await agent.send('看看当前目录');

      expect(host.approvalsAsked, 0);
      final toolReply = agent.history.lastWhere((m) => m.role == 'tool');
      expect(toolReply.content, contains('终端模式'));
    });

    test('聊天模式不打检查点', () async {
      final (agent, _, host) = await buildLoop([const LlmTurn(text: '好')]);
      agent.terminalMode = false;

      await File('${tmp.path}/workspace/a.txt').writeAsString('x');
      await agent.send('随便聊聊');

      expect(agent.snapshots.checkpoints, isEmpty,
          reason: '这一轮里没有任何东西能改文件，扫一遍 workspace 是白付的钱');
      expect(host.statuses.where((s) => s.contains('检查点')), isEmpty);
    });

    test('终端模式照常打检查点', () async {
      final (agent, _, _) = await buildLoop([const LlmTurn(text: '好')]);
      agent.terminalMode = true;

      await File('${tmp.path}/workspace/a.txt').writeAsString('x');
      await agent.send('看看');

      expect(agent.snapshots.checkpoints, isNotEmpty);
    });
  });

  group('运行中挂载基座', () {
    test('attachDistro 之后命令落在新 rootfs 里', () {
      final session = SandboxSession(
        rootfsPath: '',
        workspacePath: '${tmp.path}/workspace',
        caps: const SandboxCapabilities(
          proot: true,
          seccomp: false,
          landlockAbi: 0,
          rlimit: false,
        ),
        spawner: _NeverSpawns(),
        distroReady: false,
        prootPath: '/fake/proot',
        tmpPath: '${tmp.path}/tmp',
      );

      // 装之前只能退回宿主 shell。
      expect(session.canIsolate, isFalse);
      expect(session.buildArgv('id', SandboxLevel.workspaceWrite),
          contains('/system/bin/sh'));

      final rootfs = '${tmp.path}/distros/alpine-3.21/rootfs';
      session.attachDistro(
        rootfsPath: rootfs,
        label: 'Alpine 3.21',
        packageManager: 'apk',
      );

      final argv = session.buildArgv('id', SandboxLevel.workspaceWrite);
      expect(session.canIsolate, isTrue);
      expect(argv, contains('/fake/proot'));
      expect(argv, contains(rootfs));
      // 环境也要跟着换成 rootfs 视角的 FHS 路径，否则命令找不到自己。
      expect(
          session.buildEnv(SandboxLevel.workspaceWrite)['HOME'], '/workspace');
    });

    test('rebind 换目录时重读代索引', () async {
      final a = Directory('${tmp.path}/distros/a');
      final b = Directory('${tmp.path}/distros/b');
      await a.create(recursive: true);
      await b.create(recursive: true);

      final gens = PrefixGenerations(filesRoot: a);
      await gens.open();

      // a 下面伪造一代。代号跟着 rootfs 目录走，不跟着 app 走。
      await File('${a.path}/rootfs.gen/index.json').writeAsString(jsonEncode([
        {
          'id': 7,
          'created_at': '2026-01-01T00:00:00.000',
          'reason': 'apk add git',
          'unique_bytes': 1024,
        }
      ]));
      await gens.open();
      expect(gens.generations.single.id, 7);

      await gens.rebind(b);

      expect(gens.filesRoot.path, b.path);
      expect(gens.generations, isEmpty,
          reason: '沿用旧列表会让时间线显示出另一个发行版的代，点回滚会 rename 到不存在的目录');
    });
  });
}
