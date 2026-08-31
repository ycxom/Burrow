/// 输出蒸馏：把终端输出压到能放进上下文的大小。
///
/// 这一层 VPetLLM 没有，因为它是聊天场景。终端场景不一样 ——
/// **终端输出是上下文杀手**：
///   - 一次 `pip install torch` 吐 ~15k token（全是进度条和 Collecting/Downloading）
///   - 一次 `npm install` 吐 ~30k token
///   - 一次 `find / -name '*.so'` 吐 ~100k token
///   - 一次失败的 `make` 吐几万 token，其中真正有用的是那 3 行 error
///
/// 不蒸馏的话，一个 8k 窗口的本地模型跑一条 `pkg install` 就直接爆了；
/// 就算窗口够大，把 15k token 的进度条塞进上下文也会让模型的注意力被噪声淹没。
///
/// ## 做法
///
/// 输出**全文落盘**（进 objects），上下文里只放：
/// ```
/// $ pip install torch
/// [exit 0, 耗时 47s, 输出 892 行 / 61KB, ref=out_7f3a]
/// ── 前 20 行 ──
/// Collecting torch
///   Downloading torch-2.1.0-cp311-...whl (619.9 MB)
/// ...
/// ── 省略 850 行（进度条 812 行已折叠）──
/// ── 后 20 行 ──
/// Successfully installed torch-2.1.0 ...
/// ```
/// 想看细节就调 `grep_output(ref, pattern)` 按需取。
///
/// 关键在于**折叠规则跑在截断之前**：先把进度条、重复行这些无信息量的
/// 内容清掉，剩下的往往就自然放得下了，根本不需要截断。
/// 直接 head/tail 截断会把中间那 3 行 error 恰好切掉 —— 那正是唯一有用的部分。
library;

import 'dart:math' as math;

class DistilledOutput {
  /// 放进上下文的文本。
  final String text;

  /// 全文的引用，供 `grep_output` 回查。
  final String ref;

  final int originalLines;
  final int originalBytes;
  final int keptLines;

  /// 各条折叠规则各清掉了多少行。展示在摘要里，让模型知道
  /// "被省掉的是噪声"而不是"被省掉的可能有我要的东西"。
  final Map<String, int> collapsed;

  const DistilledOutput({
    required this.text,
    required this.ref,
    required this.originalLines,
    required this.originalBytes,
    required this.keptLines,
    required this.collapsed,
  });
}

/// 一条折叠规则。
class CollapseRule {
  final String name;
  final bool Function(String line) matches;

  /// 命中的行是整段丢弃，还是保留最后一条作为代表。
  /// 进度条丢最后一条（有最终结果），重复的 warning 也丢最后一条。
  final bool keepLast;

  const CollapseRule(this.name, this.matches, {this.keepLast = true});
}

class OutputDistiller {
  /// 头尾各保留多少行。20/20 是经验值：足够看到命令启动时的参数回显
  /// 和结束时的成败结论，这两处是模型最需要的。
  final int headLines;
  final int tailLines;

  /// 蒸馏后仍超过这个字符数就再硬截。防止某个程序吐出单行 1MB 的 JSON。
  final int maxChars;

  /// 单行超长时截断到这个长度。base64、minified JS、十六进制 dump
  /// 都会产生极长的单行，它们对模型毫无价值却吃满 token。
  final int maxLineChars;

  final List<CollapseRule> rules;

  OutputDistiller({
    this.headLines = 20,
    this.tailLines = 20,
    this.maxChars = 4000,
    this.maxLineChars = 500,
    List<CollapseRule>? rules,
  }) : rules = rules ?? defaultRules;

  DistilledOutput distill({
    required String command,
    required String raw,
    required String ref,
    required int exitCode,
    required Duration elapsed,
    bool timedOut = false,
    List<String> sandboxDenials = const [],
  }) {
    final originalBytes = raw.length;

    // 第一步：把 \r 回车刷新的行合并。进度条是 `\r` 反复重写同一行，
    // 按 \n 切会得到几百个"同一行的不同瞬间"。只留最后一次刷新的状态。
    final lines = <String>[];
    for (final chunk in raw.split('\n')) {
      final r = chunk.split('\r');
      lines.add(r.last.isEmpty && r.length > 1 ? r[r.length - 2] : r.last);
    }
    final originalLines = lines.length;

    // 第二步：折叠规则。**在截断之前** —— 顺序是这个类的全部要点。
    final collapsed = <String, int>{};
    final kept = <String>[];
    CollapseRule? runRule;
    String? runLast;
    var runCount = 0;

    void flushRun() {
      if (runRule == null) return;
      if (runRule!.keepLast && runLast != null) kept.add(runLast!);
      if (runCount > (runRule!.keepLast ? 1 : 0)) {
        collapsed[runRule!.name] = (collapsed[runRule!.name] ?? 0) +
            runCount -
            (runRule!.keepLast ? 1 : 0);
      }
      runRule = null;
      runLast = null;
      runCount = 0;
    }

    for (final line in lines) {
      final rule = _firstMatch(line);
      if (rule != null) {
        // 同一条规则连续命中算一个 run；换规则或换到普通行就结算。
        if (runRule?.name != rule.name) flushRun();
        runRule = rule;
        runLast = line;
        runCount++;
      } else {
        flushRun();
        kept.add(line);
      }
    }
    flushRun();

    // 第三步：连续重复行折叠（规则没覆盖到的、程序自己刷屏的情况）。
    final deduped = <String>[];
    var dupRun = 0;
    for (var i = 0; i < kept.length; i++) {
      if (i > 0 && kept[i] == kept[i - 1] && kept[i].trim().isNotEmpty) {
        dupRun++;
        continue;
      }
      if (dupRun > 0) {
        deduped.add('  ⋯ 上一行重复 $dupRun 次');
        collapsed['重复行'] = (collapsed['重复行'] ?? 0) + dupRun;
        dupRun = 0;
      }
      deduped.add(_truncateLine(kept[i]));
    }
    if (dupRun > 0) {
      deduped.add('  ⋯ 上一行重复 $dupRun 次');
      collapsed['重复行'] = (collapsed['重复行'] ?? 0) + dupRun;
    }

    // 第四步：还是太长才 head/tail 截断。
    // 优先保留 error/warning 行 —— 它们通常在中间，正好是朴素截断会切掉的位置。
    final body = StringBuffer();
    if (deduped.length <= headLines + tailLines) {
      body.writeAll(deduped, '\n');
    } else {
      final head = deduped.take(headLines);
      final tail = deduped.skip(deduped.length - tailLines);
      final middle = deduped.sublist(headLines, deduped.length - tailLines);
      final salient = middle.where(_isSalient).take(15).toList();

      body.writeAll(head, '\n');
      body.write('\n── 省略 ${middle.length} 行 ──\n');
      if (salient.isNotEmpty) {
        body.write('── 其中的 error/warning ──\n');
        body.writeAll(salient, '\n');
        body.write('\n');
      }
      body.writeAll(tail, '\n');
    }

    var text = body.toString();
    if (text.length > maxChars) {
      text = '${text.substring(0, maxChars ~/ 2)}\n'
          '── 硬截断 ──\n'
          '${text.substring(text.length - maxChars ~/ 2)}';
    }

    final header = _header(
      command: command,
      exitCode: exitCode,
      elapsed: elapsed,
      lines: originalLines,
      bytes: originalBytes,
      ref: ref,
      collapsed: collapsed,
      timedOut: timedOut,
      denials: sandboxDenials,
    );

    return DistilledOutput(
      text: '$header\n$text',
      ref: ref,
      originalLines: originalLines,
      originalBytes: originalBytes,
      keptLines: deduped.length,
      collapsed: collapsed,
    );
  }

  CollapseRule? _firstMatch(String line) {
    for (final r in rules) {
      if (r.matches(line)) return r;
    }
    return null;
  }

  String _truncateLine(String line) => line.length <= maxLineChars
      ? line
      : '${line.substring(0, maxLineChars)}… (本行共 ${line.length} 字符，已截断)';

  static final _salientPattern = RegExp(
    r'\b(error|ERROR|Error|fatal|FAILED|failed|warning|Traceback|Exception|'
    r'undefined reference|cannot find|No such file|Permission denied)\b',
  );

  static bool _isSalient(String line) => _salientPattern.hasMatch(line);

  String _header({
    required String command,
    required int exitCode,
    required Duration elapsed,
    required int lines,
    required int bytes,
    required String ref,
    required Map<String, int> collapsed,
    required bool timedOut,
    required List<String> denials,
  }) {
    final b = StringBuffer('\$ $command\n[');
    b.write(timedOut ? '超时被终止' : 'exit $exitCode');
    b.write(', 耗时 ${elapsed.inMilliseconds}ms');
    b.write(', 输出 $lines 行 / ${_humanBytes(bytes)}');
    b.write(', ref=$ref]');
    if (collapsed.isNotEmpty) {
      final parts =
          collapsed.entries.map((e) => '${e.key} ${e.value} 行').join('、');
      b.write('\n[已折叠：$parts —— 均为无信息量内容；'
          '需要完整输出请调用 grep_output("$ref", <正则>)]');
    }
    if (denials.isNotEmpty) {
      // 这一句是给模型看的最重要的一行：让它别把沙箱拦截误诊成网络故障，
      // 然后陷入无意义的重试。
      b.write('\n[沙箱拦截：${denials.join('；')}。'
          '这不是网络故障，重试不会成功；需要网络请请求切换到联网档位]');
    }
    return b.toString();
  }

  static String _humanBytes(int n) {
    if (n < 1024) return '${n}B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)}KB';
    return '${(n / 1024 / 1024).toStringAsFixed(1)}MB';
  }

  /// 默认折叠规则。按「命中率 × 无信息量」排的：越靠前的越常见越没用。
  static final List<CollapseRule> defaultRules = [
    // pip：Collecting / Downloading / Using cached / Requirement already satisfied
    CollapseRule(
        'pip 进度',
        (l) => RegExp(r'^\s*(Collecting|Downloading|Using cached|'
                r'Requirement already satisfied|Installing collected|Preparing metadata|'
                r'Building wheel|Created wheel|Stored in directory|Saved )')
            .hasMatch(l)),

    // 进度条：多个连续的 # = - 或百分比
    CollapseRule(
        '进度条',
        (l) => RegExp(r'(\d+%\|[█▏▎▍▌▋▊▉ ]+\||^\s*[#=\-\.]{10,}\s*$|'
                r'\d+(\.\d+)?\s*[KMG]B/s|ETA \d)')
            .hasMatch(l)),

    // apt/dpkg 的逐包噪声
    CollapseRule(
        'apt 进度',
        (l) => RegExp(r'^\s*(Get:|Hit:|Ign:|Reading |Building dependency|'
                r'Unpacking |Preparing to unpack|Selecting previously|'
                r'Setting up |Processing triggers)')
            .hasMatch(l)),

    // npm/yarn
    CollapseRule(
        'npm 进度',
        (l) => RegExp(r'^\s*(npm (WARN|notice|http)|added \d+ packages|'
                r'⸨[\s#▓░]+⸩)')
            .hasMatch(l)),

    // 编译器逐文件回显（真正的 error/warning 不匹配这条，会被保留）
    CollapseRule(
        '编译回显',
        (l) => RegExp(r'^\s*(\[\s*\d+%\]|CC |CXX |LD |AR |gcc |g\+\+ |clang |'
                r'make\[\d+\]: (Entering|Leaving) directory)')
            .hasMatch(l)),

    // git clone / fetch
    CollapseRule(
        'git 进度',
        (l) => RegExp(r'(Receiving objects|Resolving deltas|Counting objects|'
                r'Compressing objects|remote: (Counting|Compressing|Total))')
            .hasMatch(l)),

    // 纯空白行连续出现
    CollapseRule('空行', (l) => l.trim().isEmpty, keepLast: false),
  ];
}

/// 从落盘的全文里按正则取行。对应 `grep_output` 工具。
///
/// 这是蒸馏能成立的前提：把细节挪出上下文之后，模型必须有办法主动拿回来。
/// 没有这个，蒸馏就是单纯的信息丢失。
class OutputArchive {
  final String Function(String ref) load;

  const OutputArchive(this.load);

  /// [contextLines] 前后各带几行 —— 一个 error 单独看往往没意义，
  /// 上一行的文件名和下一行的 note 才是关键。
  String grep(String ref, String pattern,
      {int maxMatches = 50, int contextLines = 2}) {
    final re = RegExp(pattern, caseSensitive: false);
    final lines = load(ref).split('\n');
    final out = StringBuffer();
    var matches = 0;
    var lastPrinted = -1;

    for (var i = 0; i < lines.length && matches < maxMatches; i++) {
      if (!re.hasMatch(lines[i])) continue;
      matches++;
      final from = math.max(0, i - contextLines);
      final to = math.min(lines.length - 1, i + contextLines);
      if (from > lastPrinted + 1) out.writeln('  ⋯');
      for (var j = math.max(from, lastPrinted + 1); j <= to; j++) {
        out.writeln('${j + 1}: ${lines[j]}');
        lastPrinted = j;
      }
    }

    if (matches == 0) {
      return '在 $ref 中未匹配到 /$pattern/（全文共 ${lines.length} 行）';
    }
    if (matches >= maxMatches) {
      out.writeln('  ⋯ 匹配数已达上限 $maxMatches，请用更具体的正则');
    }
    return out.toString();
  }
}
