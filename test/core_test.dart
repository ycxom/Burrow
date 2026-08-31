/// 核心逻辑的单测。这些都是纯 Dart，不需要设备 ——
/// 这正是把策略/上下文/回滚判断全留在 Dart 层的原因（见 ARCHITECTURE.md §1）。
library;

import 'dart:io';

import 'package:burrow/src/context/context_limit_guard.dart';
import 'package:burrow/src/context/memory_retrieval.dart';
import 'package:burrow/src/context/output_distiller.dart';
import 'package:burrow/src/sandbox/exec_policy.dart';
import 'package:burrow/src/sandbox/snapshot_store.dart';
// 用 flutter_test 而不是 package:test —— pubspec 依赖 Flutter SDK，
// 纯 dart test 跑不起来。被测的这几个文件本身都不 import flutter。
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ExecPolicy', () {
    final policy = ExecPolicy();

    test('只读命令放行且不打检查点', () {
      final v = policy.evaluate('ls -la src');
      expect(v.decision, Decision.allow);
      expect(v.isMutating, isFalse);
    });

    test('复合命令按最严的那一段判定', () {
      // 只看第一个词会判成 allow —— 这正是要拆段的理由
      final v = policy.evaluate('ls && rm -rf /');
      expect(v.decision, Decision.forbidden);
    });

    test('管道也是段边界', () {
      final v = policy.evaluate('cat x | sudo tee /etc/hosts');
      expect(v.decision, Decision.forbidden);
    });

    test('引号内的控制符不拆段', () {
      final v = policy.evaluate('echo "a && b"');
      expect(v.decision, Decision.allow);
    });

    test('输出重定向让只读命令变成写盘', () {
      final v = policy.evaluate('cat a > b');
      expect(v.isMutating, isTrue);
      expect(v.scope, WriteScope.workspace);
    });

    test('更长的 pattern 覆盖更短的', () {
      expect(policy.evaluate('sed s/a/b/ f').isMutating, isFalse);
      expect(policy.evaluate('sed -i s/a/b/ f').isMutating, isTrue);
    });

    test('豁免前缀生效', () {
      expect(policy.evaluate('git reset --hard').decision, Decision.prompt);
      expect(policy.evaluate('git reset --keep').decision, Decision.prompt,
          reason: '--keep 不该命中 --hard 规则，落到 fallback');
    });

    test('包管理器归到 prefix scope', () {
      expect(policy.evaluate('pkg install python').scope, WriteScope.prefix);
    });

    test('未知命令默认 prompt 且当作会写盘', () {
      final v = policy.evaluate('mycustomtool --do-something');
      expect(v.decision, Decision.prompt);
      expect(v.isMutating, isTrue, reason: '不确定时多存一次档');
    });
  });

  group('ContextLimitGuard', () {
    test('识别 llama.cpp 的超长错误', () {
      final g = ContextLimitGuard();
      const body = '{"error":{"code":400,"message":"request (13392 tokens) '
          'exceeds the available context size (8192 tokens)",'
          '"type":"exceed_context_size_error","n_prompt_tokens":13392,"n_ctx":8192}}';
      expect(g.isContextLimitError(400, body), isTrue);
      expect(g.isContextLimitError(500, body), isFalse, reason: '5xx 是服务端问题');
      expect(g.isContextLimitError(401, body), isFalse, reason: '401 是鉴权');
      expect(ContextLimitGuard.parseContextTokens(body), 8192);
      expect(ContextLimitGuard.parsePromptTokens(body), 13392);
    });

    test('用 n_prompt_tokens 校准估算器', () {
      final g = ContextLimitGuard();
      const body = '{"n_prompt_tokens":13392,"n_ctx":8192,'
          '"type":"exceed_context_size_error"}';
      // 我们估了 9500，服务端数出 13392 → ratio 1.41
      final budget = g.learn(key: 'k', body: body, ourEstimate: 9500);
      // 8192 / 1.41 * 0.90 ≈ 5229
      expect(budget, greaterThan(4800));
      expect(budget, lessThan(5600));
      expect(budget, lessThan(8192), reason: '必须比服务端窗口小，否则再撞一次');
    });

    test('重复撞同一个上限会继续收紧', () {
      final g = ContextLimitGuard();
      const body = '{"n_prompt_tokens":9000,"n_ctx":8192,'
          '"type":"exceed_context_size_error"}';
      final first = g.learn(key: 'k', body: body, ourEstimate: 9000);
      final second = g.learn(key: 'k', body: body, ourEstimate: 9000);
      expect(second, lessThan(first));
    });

    test('抠不到数字时返回 0，不瞎猜', () {
      final g = ContextLimitGuard();
      const body = '{"error":"prompt is too long"}';
      expect(g.isContextLimitError(400, body), isTrue);
      expect(g.learn(key: 'k', body: body, ourEstimate: 5000), 0);
    });

    test('不同节点分桶互不影响', () {
      final g = ContextLimitGuard();
      g.learn(
          key: ContextLimitGuard.makeKey('openai', 'local', 'qwen'),
          body: '{"n_ctx":4096,"n_prompt_tokens":5000,'
              '"type":"exceed_context_size_error"}',
          ourEstimate: 5000);
      expect(g.budgetFor(ContextLimitGuard.makeKey('openai', 'cloud', 'gpt')),
          0, reason: '另一个节点不该被裁短');
    });
  });

  group('OutputDistiller', () {
    final d = OutputDistiller();

    test('折叠 pip 噪声', () {
      final raw = [
        'Collecting torch',
        '  Downloading torch-2.1.0.whl (619.9 MB)',
        '     |████████████████| 619.9 MB 1.2 MB/s',
        'Collecting numpy',
        '  Downloading numpy-1.26.whl (18 MB)',
        'Successfully installed torch-2.1.0 numpy-1.26',
      ].join('\n');

      final out = d.distill(
        command: 'pip install torch',
        raw: raw,
        ref: 'out_1',
        exitCode: 0,
        elapsed: const Duration(seconds: 47),
      );

      expect(out.text, contains('Successfully installed'));
      expect(out.collapsed, isNotEmpty);
      expect(out.text, contains('grep_output'), reason: '必须告诉模型怎么拿全文');
    });

    test('中间的 error 不会被 head/tail 截断切掉', () {
      final lines = <String>[
        for (var i = 0; i < 60; i++) 'CC  src/file_$i.c',
        'src/broken.c:42: error: undefined reference to `foo`',
        for (var i = 0; i < 60; i++) 'CC  src/more_$i.c',
      ];
      final out = d.distill(
        command: 'make',
        raw: lines.join('\n'),
        ref: 'out_2',
        exitCode: 2,
        elapsed: const Duration(seconds: 12),
      );
      expect(out.text, contains('undefined reference'),
          reason: '这是整段输出里唯一有用的一行');
    });

    test('\\r 进度条合并成一行', () {
      const raw = 'downloading\r 10%\r 50%\r100% done\nfinished';
      final out = d.distill(
        command: 'wget x',
        raw: raw,
        ref: 'out_3',
        exitCode: 0,
        elapsed: Duration.zero,
      );
      expect(out.text, contains('finished'));
      expect(out.text.contains(' 10%'), isFalse);
    });

    test('沙箱拦截会被点破', () {
      final out = d.distill(
        command: 'curl https://example.com',
        raw: 'curl: (7) Couldn\'t connect: Operation not permitted',
        ref: 'out_4',
        exitCode: 7,
        elapsed: Duration.zero,
        sandboxDenials: const ['可能是沙箱断网拦截'],
      );
      expect(out.text, contains('这不是网络故障'));
    });

    test('超长单行被截断', () {
      final out = d.distill(
        command: 'cat blob',
        raw: 'x' * 5000,
        ref: 'out_5',
        exitCode: 0,
        elapsed: Duration.zero,
      );
      expect(out.text.length, lessThan(2000));
    });
  });

  group('检索排序', () {
    test('BM25 的 IDF 让罕见词命中胜出', () {
      final docs = [
        MemoryRetrieval.tokenize('我们安装了 torch 这个包'),
        MemoryRetrieval.tokenize('安装 numpy'),
        MemoryRetrieval.tokenize('安装 pandas'),
        MemoryRetrieval.tokenize('安装 requests'),
      ];
      final scores = Bm25.score(docs, ['安装', 'torch']);
      expect(scores[0], greaterThan(scores[1]),
          reason: 'torch 罕见，它的命中比到处都是的"安装"值钱');
    });

    test('RRF 融合两路分歧的排序', () {
      final fused = RrfFusion.fuse(RrfFusion.defaultK, [
        [3, 1, 2], // 路 1 认为 3 最相关
        [1, 3, 2], // 路 2 认为 1 最相关
      ]);
      // 两路都排前二的应该赢过只被一路看好的
      expect(fused[1]! + fused[3]!, greaterThan(fused[2]! * 2));
    });

    test('中文分词产出单字和 bigram', () {
      final t = MemoryRetrieval.tokenize('安装包');
      expect(t, contains('安'));
      expect(t, contains('安装'));
      expect(t, contains('装包'));
    });
  });

  group('SnapshotStore', () {
    late Directory tmp;
    late SnapshotStore store;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('pa_test_');
      store = SnapshotStore(
        workspace: Directory('${tmp.path}/ws'),
        metaRoot: Directory('${tmp.path}/meta'),
      );
      await store.open();
    });

    tearDown(() async => tmp.delete(recursive: true));

    test('无变更时不推进代号', () async {
      expect(await store.checkpoint(reason: 'noop'), isNull);
      expect(store.head, 0);
    });

    test('工具层路径能精确回滚一次修改', () async {
      final f = File('${store.workspace.path}/a.txt');
      await f.writeAsString('original');
      await store.checkpoint(reason: 'baseline');
      final gen = store.head;

      // 模拟 write_file：先记旧内容，再写
      store.stage(await store.recordIntentToWrite('a.txt'));
      await f.writeAsString('modified');
      await store.checkpoint(reason: '改了 a.txt');

      expect(await f.readAsString(), 'modified');

      final report = await store.rollbackTo(gen);
      expect(await f.readAsString(), 'original');
      expect(report.isClean, isTrue);
    });

    test('回滚会删掉新建的文件', () async {
      await store.checkpoint(reason: 'baseline');
      final gen = store.head;

      final f = File('${store.workspace.path}/new.txt');
      await f.writeAsString('hello');
      await store.checkpoint(reason: '新建');

      await store.rollbackTo(gen);
      expect(await f.exists(), isFalse);
    });

    test('in-place 追加也能被扫描捕获', () async {
      final f = File('${store.workspace.path}/log.txt');
      await f.writeAsString('line1\n');
      await store.checkpoint(reason: 'baseline');

      // 这正是 hardlink 快照会静默失真的场景
      await f.writeAsString('line2\n', mode: FileMode.append);
      final cp = await store.checkpoint(reason: '追加');
      expect(cp, isNotNull);
      expect(cp!.changes.single.op, 'modified');
    });

    test('不可恢复的文件必须被报告', () async {
      final store2 = SnapshotStore(
        workspace: Directory('${tmp.path}/ws2'),
        metaRoot: Directory('${tmp.path}/meta2'),
        maxBlobBytes: 10, // 极小，逼出"存不下"的分支
      );
      await store2.open();

      final f = File('${store2.workspace.path}/big.txt');
      await f.writeAsString('x' * 100);
      await store2.checkpoint(reason: 'baseline');
      final gen = store2.head;

      store2.stage(await store2.recordIntentToWrite('big.txt'));
      await f.writeAsString('y' * 100);
      await store2.checkpoint(reason: '改大文件');

      final report = await store2.rollbackTo(gen);
      expect(report.isClean, isFalse);
      expect(report.unrecoverable, contains('big.txt'));
    });

    test('gc 清掉不再被引用的 blob', () async {
      final f = File('${store.workspace.path}/a.txt');
      await f.writeAsString('v1');
      await store.checkpoint(reason: 'baseline');
      final gen = store.head;

      store.stage(await store.recordIntentToWrite('a.txt'));
      await f.writeAsString('v2');
      await store.checkpoint(reason: 'v2');

      await store.rollbackTo(gen);
      expect(await store.gc(), greaterThanOrEqualTo(0));
    });
  });
}
