/// L0 沙箱：命令在**执行之前**的准入判断。
///
/// 结构照搬 codex `execpolicy` 的 `Decision{Allow, Prompt, Forbidden}` +
/// 前缀规则（`prefix_rule(pattern=["git","reset","--hard"], decision="forbidden")`），
/// 但补了两件 codex 不需要、手机端必须的东西：
///
///   1. **mutating 判定** —— 决定要不要在执行前打检查点（见 SnapshotStore）。
///      codex 靠平台沙箱兜底，我们靠回滚兜底，所以必须知道哪条命令会写盘。
///   2. **shell 结构解析** —— LLM 极爱写 `a && b | c > d`。只看第一个词
///      会把 `ls && rm -rf /` 判成 `ls`。所以先按 `;`/`&&`/`||`/`|` 拆段，
///      每段独立判定，取**最严**的结果。
library;

/// 单条命令的准入结论。严重程度递增，`Decision.max` 靠这个序。
enum Decision {
  allow,
  prompt,
  forbidden;

  static Decision max(Decision a, Decision b) => a.index >= b.index ? a : b;
}

/// 一条命令在文件系统上的影响面。
enum WriteScope {
  /// 不写盘。只读工具和 `ls`/`cat`/`grep` 这类。
  none,

  /// 只写 workspace。反向增量快照能完整覆盖。
  workspace,

  /// 会改 `$PREFIX`（装包/卸包）。需要走「代目录 + 原子 rename」那条路。
  prefix,
}

class PolicyVerdict {
  final Decision decision;
  final WriteScope scope;

  /// 给用户看的一句话：为什么是这个结论。审批弹窗直接显示它。
  final String reason;

  /// 命中的规则，便于用户在设置里定位并改掉。
  final String? matchedRule;

  const PolicyVerdict({
    required this.decision,
    required this.scope,
    required this.reason,
    this.matchedRule,
  });

  bool get isMutating => scope != WriteScope.none;

  PolicyVerdict merge(PolicyVerdict other) => PolicyVerdict(
        decision: Decision.max(decision, other.decision),
        scope: scope.index >= other.scope.index ? scope : other.scope,
        reason: decision.index >= other.decision.index ? reason : other.reason,
        matchedRule: decision.index >= other.decision.index
            ? matchedRule
            : other.matchedRule,
      );
}

/// 一条前缀规则。`pattern` 是**逐 token 前缀匹配**，不是正则 ——
/// 正则在这里是负债：写错一个 `.` 就把整类命令放行了，而且没法体检。
class PrefixRule {
  final List<String> pattern;
  final Decision decision;
  final WriteScope scope;
  final String justification;

  /// 命中 pattern 之后的**豁免前缀**。用来表达
  /// 「`git reset --hard` 禁止，但 `git reset --keep` 放行」这种。
  final List<List<String>> exceptions;

  const PrefixRule(
    this.pattern, {
    this.decision = Decision.allow,
    this.scope = WriteScope.none,
    this.justification = '',
    this.exceptions = const [],
  });

  bool matches(List<String> argv) {
    if (argv.length < pattern.length) return false;
    for (var i = 0; i < pattern.length; i++) {
      if (argv[i] != pattern[i]) return false;
    }
    for (final ex in exceptions) {
      if (argv.length >= ex.length) {
        var hit = true;
        for (var i = 0; i < ex.length; i++) {
          if (argv[i] != ex[i]) {
            hit = false;
            break;
          }
        }
        if (hit) return false;
      }
    }
    return true;
  }
}

class ExecPolicy {
  final List<PrefixRule> rules;

  /// 没有任何规则命中时的兜底。默认 `prompt` 而不是 `allow` ——
  /// 规则表天然不可能穷尽，未知命令让用户看一眼比默默放行安全。
  final Decision fallback;

  /// 用户自己点「以后允许」攒下来的命令前缀。可以在设置里删。
  ///
  /// **是个闭包而不是一份快照。** 策略对象是建会话时造的，而用户随时可能
  /// 在弹窗里放行一条、或者进设置删掉一条；存快照的话，改动要等下次新建
  /// 会话才生效 —— 那种"设置了但没反应"是最难自证的一类。
  final List<String> Function() allowed;

  ExecPolicy({
    List<PrefixRule>? rules,
    this.fallback = Decision.prompt,
    List<String> Function()? allowed,
  })  : rules = rules ?? defaultRules,
        allowed = allowed ?? _noAllowances;

  static List<String> _noAllowances() => const <String>[];

  /// 对一整条 shell 命令行判定。内部拆段后取最严结果。
  ///
  /// [sandboxed] 是这里最重要的一个参数，它决定了整套判定的性质：
  ///
  ///   - **沙箱开着**：命令跑在 proot 里，够不着实体机。这一层就不再替
  ///     用户否决任何东西了 —— 装包要 root、拉代码要联网，把这些拦下来
  ///     只会让 Agent 什么都干不成（实测："禁止 sudo — 无法安装
  ///     openssh-client"）。规则表仍然照跑，但只用来算 [WriteScope]：
  ///     检查点和 `$PREFIX` 事务靠它，那才是真正的兜底。
  ///   - **沙箱关了**：命令直接落在设备上，这时**每一条都要问**。
  ///     用户点过"以后允许"的除外，那份名单在 [allowed] 里，随时可删。
  PolicyVerdict evaluate(String commandLine, {bool sandboxed = true}) {
    final segments = _splitShell(commandLine);
    if (segments.isEmpty) {
      return const PolicyVerdict(
        decision: Decision.allow,
        scope: WriteScope.none,
        reason: '空命令',
      );
    }

    var verdict = _evaluateSegment(segments.first);
    for (final seg in segments.skip(1)) {
      verdict = verdict.merge(_evaluateSegment(seg));
    }

    if (sandboxed) {
      // 沙箱是边界，这一层不再拦。scope 原样留着 —— 检查点靠它。
      return PolicyVerdict(
        decision: Decision.allow,
        scope: verdict.scope,
        reason: verdict.reason,
        matchedRule: verdict.matchedRule,
      );
    }

    // 沙箱关了：默认全问，除非用户自己放行过。
    if (segments.every(_isAllowedByUser)) {
      return PolicyVerdict(
        decision: Decision.allow,
        scope: verdict.scope,
        reason: '你已允许这条命令',
        matchedRule: verdict.matchedRule,
      );
    }
    return PolicyVerdict(
      decision: Decision.max(verdict.decision, Decision.prompt),
      scope: verdict.scope,
      reason: verdict.decision == Decision.allow
          ? '沙箱已关闭，命令直接在设备上执行'
          : verdict.reason,
      matchedRule: verdict.matchedRule,
    );
  }

  bool _isAllowedByUser(List<String> argv) {
    if (argv.isEmpty) return true;
    for (final entry in allowed()) {
      final pattern = entry.trim().split(RegExp(r'\s+'));
      if (pattern.isEmpty || pattern.first.isEmpty) continue;
      if (pattern.length > argv.length) continue;
      var hit = true;
      for (var i = 0; i < pattern.length; i++) {
        if (pattern[i] != argv[i]) {
          hit = false;
          break;
        }
      }
      if (hit) return true;
    }
    return false;
  }

  /// 把一条命令行折成可以存进放行名单的样子。
  ///
  /// 只取第一段的前两个词：`git push origin main` 存成 `git push`。
  /// 存整行的话，参数换一个就再问一遍，"以后允许"等于没用；只存首词又
  /// 太宽（允许了 `git status` 等于允许 `git push --force`）。
  static String allowKeyFor(String commandLine) {
    final segments = _splitShell(commandLine);
    if (segments.isEmpty || segments.first.isEmpty) return commandLine.trim();
    final argv = segments.first;
    final words = argv.first.startsWith('-') ? argv.take(1) : argv.take(2);
    return words.where((w) => !w.startsWith('-')).join(' ').trim();
  }

  PolicyVerdict _evaluateSegment(List<String> argv) {
    if (argv.isEmpty) {
      return const PolicyVerdict(
          decision: Decision.allow, scope: WriteScope.none, reason: '空段');
    }

    // 重定向就是写盘，哪怕命令本身是只读的：`cat a > b` 里的 cat 无辜，
    // `> b` 不无辜。规则表是按命令组织的，覆盖不到这一层，单独判。
    final redirects =
        argv.any((t) => t == '>' || t == '>>' || t.startsWith('>'));

    PolicyVerdict? best;
    for (final rule in rules) {
      if (!rule.matches(argv)) continue;
      final v = PolicyVerdict(
        decision: rule.decision,
        scope: rule.scope,
        reason: rule.justification.isEmpty
            ? '命中规则 ${rule.pattern.join(' ')}'
            : rule.justification,
        matchedRule: rule.pattern.join(' '),
      );
      // 更长的 pattern 更具体，优先；同长度取更严的。
      if (best == null ||
          rule.pattern.length > (best.matchedRule?.split(' ').length ?? 0) ||
          v.decision.index > best.decision.index) {
        best = v;
      }
    }

    best ??= PolicyVerdict(
      decision: fallback,
      scope: WriteScope.workspace, // 未知命令保守假设会写盘 → 会打检查点
      reason: '未知命令 ${argv.first}，按未知处理',
    );

    if (redirects && best.scope == WriteScope.none) {
      return PolicyVerdict(
        decision: Decision.max(best.decision, Decision.allow),
        scope: WriteScope.workspace,
        reason: '${best.reason}；含输出重定向，按写盘处理',
        matchedRule: best.matchedRule,
      );
    }
    return best;
  }

  /// 按 shell 控制符拆段。**不是**完整的 shell 解析器，
  /// 只做到「不会把 `ls && rm -rf /` 误判成 `ls`」这个程度。
  ///
  /// 真正的严防靠 L1/L2（proot + seccomp）—— 一个字符串解析器永远赢不了
  /// `eval "$(printf '\\x72\\x6d')"` 这种，别假装它能。
  static List<List<String>> _splitShell(String line) {
    final segments = <List<String>>[];
    var current = <String>[];
    final buf = StringBuffer();
    String? quote;

    void flushToken() {
      if (buf.isNotEmpty) {
        current.add(buf.toString());
        buf.clear();
      }
    }

    void flushSegment() {
      flushToken();
      if (current.isNotEmpty) segments.add(current);
      current = <String>[];
    }

    for (var i = 0; i < line.length; i++) {
      final c = line[i];

      if (quote != null) {
        if (c == quote) {
          quote = null;
        } else {
          buf.write(c);
        }
        continue;
      }

      switch (c) {
        case '"':
        case "'":
          quote = c;
        case ' ':
        case '\t':
        case '\n':
          flushToken();
        case ';':
          flushSegment();
        case '&':
        case '|':
          // `&&` / `||` / `|` 都是段边界；单个 `&` 是后台执行，也是边界。
          flushSegment();
          if (i + 1 < line.length && line[i + 1] == c) i++;
        case '\\':
          if (i + 1 < line.length) {
            i++;
            buf.write(line[i]);
          }
        default:
          buf.write(c);
      }
    }
    flushSegment();
    return segments;
  }

  /// 默认规则表。刻意保持短 —— 长规则表给人「已经防住了」的错觉，
  /// 而真正的防线在 L1/L2。这里只挡「一眼就知道不该跑」和
  /// 「跑之前该问一句」这两类。
  static final List<PrefixRule> defaultRules = [
    // ---- 只读，放行且不打检查点 ----
    for (final cmd in const [
      'ls',
      'cat',
      'head',
      'tail',
      'grep',
      'rg',
      'find',
      'file',
      'stat',
      'wc',
      'diff',
      'which',
      'pwd',
      'echo',
      'date',
      'env',
      'uname',
      'df',
      'du',
      'ps',
      'top',
      'tree',
      'sort',
      'uniq',
      'awk',
      'sed',
    ])
      PrefixRule([cmd], decision: Decision.allow, scope: WriteScope.none),

    // sed -i 是 in-place，是写盘 —— 上面那条 sed 会被这条更长的 pattern 覆盖。
    const PrefixRule(['sed', '-i'],
        decision: Decision.allow,
        scope: WriteScope.workspace,
        justification: 'sed -i 原地改文件'),

    // ---- git：读放行，写打点，破坏性的问 ----
    for (final sub in const ['status', 'log', 'diff', 'show', 'branch'])
      PrefixRule(['git', sub],
          decision: Decision.allow, scope: WriteScope.none),
    const PrefixRule(['git', 'add'],
        decision: Decision.allow, scope: WriteScope.workspace),
    const PrefixRule(['git', 'commit'],
        decision: Decision.allow, scope: WriteScope.workspace),
    const PrefixRule(['git', 'checkout'],
        decision: Decision.prompt,
        scope: WriteScope.workspace,
        justification: 'checkout 会覆盖未提交的改动'),
    const PrefixRule(['git', 'reset', '--hard'],
        decision: Decision.prompt,
        scope: WriteScope.workspace,
        justification: 'reset --hard 丢弃工作区改动',
        exceptions: [
          ['git', 'reset', '--keep'],
          ['git', 'reset', '--merge'],
        ]),
    const PrefixRule(['git', 'clean'],
        decision: Decision.prompt,
        scope: WriteScope.workspace,
        justification: 'git clean 删除未跟踪文件'),
    const PrefixRule(['git', 'push'],
        decision: Decision.prompt,
        scope: WriteScope.none,
        justification: 'push 是对外操作，改动会离开本机'),

    // ---- 包管理：走 prefix 那条快照路 ----
    for (final mgr in const [
      'pkg',
      'apt',
      'apt-get',
      'dpkg',
      'pip',
      'pip3',
      'npm'
    ])
      PrefixRule([mgr],
          decision: Decision.prompt,
          scope: WriteScope.prefix,
          justification: '$mgr 会改动 \$PREFIX 环境'),

    // ---- 删除：一律问 ----
    const PrefixRule(['rm'],
        decision: Decision.prompt,
        scope: WriteScope.workspace,
        justification: 'rm 删除文件'),
    const PrefixRule(['rm', '-rf', '/'],
        decision: Decision.prompt,
        scope: WriteScope.prefix,
        justification: 'rm -rf / 摧毁整个 rootfs'),
    const PrefixRule(['rm', '-rf', '/*'],
        decision: Decision.prompt,
        scope: WriteScope.prefix,
        justification: 'rm -rf /* 摧毁整个 rootfs'),

    // ---- 危险但**不禁**的 ----
    //
    // 这几条以前是 `forbidden`，写死在代码里，用户删不掉。取消掉了，
    // 理由有两条：
    //
    //   1. **沙箱里禁它们没有意义，只有代价。** 装包要 root，`sudo` 被
    //      写死禁掉之后 Agent 在 Ubuntu 里连 openssh-client 都装不上，
    //      而它伤不到实体机 —— 那正是沙箱存在的理由。
    //   2. **沙箱关了的时候，该问的是用户，不是代码替他决定。** 现在关了
    //      沙箱一律弹窗（见 evaluate），用户自己点允许或拒绝。
    //
    // 保留成 prompt 而不是 allow：它们确实值得多看一眼，`scope` 也还要
    // 用来触发执行前检查点。
    const PrefixRule(['mkfs'],
        decision: Decision.prompt,
        scope: WriteScope.prefix,
        justification: '格式化设备'),
    const PrefixRule(['dd'],
        decision: Decision.prompt,
        scope: WriteScope.prefix,
        justification: 'dd 可绕过一切路径检查直写块设备'),
    const PrefixRule(['su'],
        decision: Decision.prompt,
        scope: WriteScope.prefix,
        justification: '提权'),
    const PrefixRule(['sudo'],
        decision: Decision.prompt,
        scope: WriteScope.prefix,
        justification: '提权'),
    const PrefixRule(['chmod', '-R', '777', '/'],
        decision: Decision.prompt,
        scope: WriteScope.prefix,
        justification: '递归放开根目录权限'),

    // ---- 网络：问，因为可能把 workspace 内容传出去 ----
    for (final cmd in const ['curl', 'wget', 'nc', 'ssh', 'scp', 'rsync'])
      PrefixRule([cmd],
          decision: Decision.prompt,
          scope: WriteScope.workspace,
          justification: '$cmd 涉及网络，内容可能离开本机'),
  ];
}
