/// 会话锁：进这个会话要先输一次密码。
///
/// ## 先说清楚它**不是**加密
///
/// 消息在数据库里仍然是明文。这道锁挡的是"别人拿起你的手机点进来"，挡不住
/// 任何一个能读到 `burrow.db` 的人（adb、root、备份、把手机交给修理店）。
///
/// 为什么不做成真加密：**找回方式决定了这件事做不到**。真加密要求密钥只能
/// 从密码推出来，忘了就是永久打不开；而这里要求"忘了密码可以靠安全问题找
/// 回来"，还要求那些答案是**模糊匹配**的。模糊匹配的输入推不出稳定的密钥
/// —— 差一个字就是完全不同的密钥。两个要求不可能同时满足。
///
/// 所以界面上一律叫「私密对话」「锁」，不叫加密。一个用户以为自己加密了、
/// 实际只是加了道锁，会往里面放本来不该放的东西 —— 那比没有这道锁更糟。
library;

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

/// 安全问题。
///
/// ## 答案不问用户，从会话里取
///
/// 让用户在设锁时填一遍答案，是在**要求他记住一个刚编出来的东西** ——
/// 而找回这件事发生在几个月后，那时他早忘了自己当初写的是"聊了 rust"
/// 还是"Rust 所有权"。真正忘不掉的是**这个会话本身**：用的哪个模型、
/// 聊过什么、给它设过什么人格。
///
/// 所以内置题**一个输入框都没有**：勾上就行，答案在找回的时候现从会话里取
/// （见 [ThreadFacts]）。这样还顺带去掉了一个泄露面 —— 答案不落盘。
///
/// 只有事实**确实存在**的题才给选（没设过人格就不提供那道题）。否则会出现
/// 一道"标准答案是空"的题，而那种题任何人留空都能过。
enum LockQuestion {
  /// 这个会话里常用哪个对话模型。找回时是**选择题**：正确答案混在几个
  /// 别的模型里。模型名没人背得出来，让人默写只会把主人自己挡在外面。
  model,

  /// 在这儿聊过什么。答案对着整段对话模糊匹配 —— 说中任意一句就算。
  topic,

  /// 给这个会话设的 AI 人格。
  persona,

  /// 第一句话大概说了什么。
  opening,

  /// 你给这个会话起的名字。
  title;

  String get label => switch (this) {
        LockQuestion.model => '这个会话常用哪个对话模型？',
        LockQuestion.topic => '在这儿聊过什么？说一句就行',
        LockQuestion.persona => '给它设过什么 AI 人格？',
        LockQuestion.opening => '第一句话大概说了什么？',
        LockQuestion.title => '你给这个会话起的名字是？',
      };

  String get hint => switch (this) {
        LockQuestion.model => '从下面几个里挑',
        LockQuestion.topic => '模糊匹配，说中一句就行',
        LockQuestion.persona => '模糊匹配，记个大意',
        LockQuestion.opening => '模糊匹配，记个大意',
        LockQuestion.title => '会话列表里显示的那个标题',
      };

  /// 找回时给选项，而不是让人打字。
  bool get isMultipleChoice => this == LockQuestion.model;

  String get storage => name;

  static LockQuestion? fromStorage(String? raw) {
    for (final q in LockQuestion.values) {
      if (q.name == raw) return q;
    }
    return null;
  }
}

/// 这个会话里那些能当答案的事实。
///
/// **不落盘**，找回的时候现从库里取。存一份的话就有两处真相，而消息被删过
/// 之后那份快照会变成一个谁也答不上的答案。
@immutable
class ThreadFacts {
  const ThreadFacts({
    this.model = '',
    this.title = '',
    this.persona = '',
    this.opening = '',
    this.spoken = const <String>[],
  });

  /// 最近一条助手消息署的模型名。
  final String model;
  final String title;

  /// 会话级系统提示词。
  final String persona;

  /// 第一条用户消息。
  final String opening;

  /// 所有说过的话。「聊过什么」对着它逐条模糊匹配。
  final List<String> spoken;

  /// 这道题有没有标准答案。没有就不该提供 ——
  /// 一道"标准答案是空"的题，任何人留空都能过。
  bool has(LockQuestion question) => switch (question) {
        LockQuestion.model => model.trim().isNotEmpty,
        LockQuestion.title => title.trim().isNotEmpty,
        LockQuestion.persona => persona.trim().isNotEmpty,
        LockQuestion.opening => opening.trim().isNotEmpty,
        LockQuestion.topic => spoken.any((line) => line.trim().isNotEmpty),
      };

  /// 现在还答得上的题。
  List<LockQuestion> get available =>
      <LockQuestion>[for (final q in LockQuestion.values) if (has(q)) q];
}

/// 一道题。内置的，或者用户自己写的。
@immutable
class LockChallenge {
  /// 内置题。答案不存，找回时从 [ThreadFacts] 取。
  const LockChallenge.builtIn(LockQuestion this.question)
      : prompt = '',
        answer = '';

  /// 自定义题。题面和答案都是用户写的，所以都得存。
  const LockChallenge.custom({required this.prompt, required this.answer})
      : question = null;

  final LockQuestion? question;
  final String prompt;
  final String answer;

  bool get isCustom => question == null;

  String get label => question?.label ?? prompt;

  String get hint => question?.hint ?? '模糊匹配，记个大意';

  bool get isMultipleChoice => question?.isMultipleChoice ?? false;

  Map<String, Object?> toJson() => isCustom
      ? <String, Object?>{'prompt': prompt, 'answer': answer}
      : <String, Object?>{'q': question!.storage};

  static LockChallenge? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final builtIn = LockQuestion.fromStorage(raw['q'] as String?);
    if (builtIn != null) return LockChallenge.builtIn(builtIn);
    final prompt = raw['prompt'];
    final answer = raw['answer'];
    if (prompt is! String || answer is! String || prompt.trim().isEmpty) {
      return null;
    }
    return LockChallenge.custom(prompt: prompt, answer: answer);
  }

  @override
  bool operator ==(Object other) =>
      other is LockChallenge &&
      other.question == question &&
      other.prompt == prompt &&
      other.answer == answer;

  @override
  int get hashCode => Object.hash(question, prompt, answer);
}

/// 必须选够几道。
///
/// 三道是「一道答错就进不去太脆」和「问得越多越像盘问」之间的折中。
const lockQuestionCount = 3;

/// 一个会话的锁。
@immutable
class ThreadLock {
  const ThreadLock({
    required this.salt,
    required this.hash,
    required this.challenges,
  });

  /// 每个会话一份随机盐。共用一份的话，两个会话设了同样的密码在库里长得
  /// 一模一样 —— 光看数据库就能看出"这两个是同一个密码"。
  final String salt;

  /// PBKDF2(密码, salt) 的十六进制。**密码本身不存。**
  final String hash;

  /// 选中的那几道题。
  ///
  /// 内置题只存"选了哪道"，答案不落盘 —— 它现从会话里取。自定义题没办法，
  /// 题面和答案都得存，而答案还得是明文（模糊匹配要拿原文来比）。
  final List<LockChallenge> challenges;

  Map<String, Object?> toJson() => <String, Object?>{
        'salt': salt,
        'hash': hash,
        'challenges': <Object?>[for (final c in challenges) c.toJson()],
      };

  static ThreadLock? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final salt = raw['salt'];
    final hash = raw['hash'];
    if (salt is! String || hash is! String || salt.isEmpty || hash.isEmpty) {
      return null;
    }
    final challenges = <LockChallenge>[];
    final stored = raw['challenges'];
    if (stored is List) {
      for (final entry in stored) {
        final challenge = LockChallenge.fromJson(entry);
        if (challenge != null) challenges.add(challenge);
      }
    }
    return ThreadLock(salt: salt, hash: hash, challenges: challenges);
  }
}

/// 派生密钥的迭代次数。
///
/// 挡的是"把库拖走之后离线撞密码"。手机上纯 Dart 跑一遍大约几百毫秒 ——
/// 开锁时等这一下是可以接受的，而它让每次撞库尝试也要付同样的代价。
const _iterations = 60000;

/// PBKDF2-HMAC-SHA256。
///
/// 手写而不是加个依赖：`crypto` 已经在依赖里，而 PBKDF2 本身就是"HMAC 套
/// 一个循环"，抄一个包进来换不到任何东西。
String derivePasscode(String password, String salt) {
  final hmac = Hmac(sha256, utf8.encode(password));
  // dkLen 等于一个块，所以只要第一块：INT(1) 大端拼在盐后面。
  var block = hmac
      .convert(<int>[...utf8.encode(salt), 0, 0, 0, 1])
      .bytes;
  final result = List<int>.from(block);
  for (var i = 1; i < _iterations; i++) {
    block = hmac.convert(block).bytes;
    for (var j = 0; j < result.length; j++) {
      result[j] ^= block[j];
    }
  }
  return result.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

String newSalt([Random? random]) {
  final rng = random ?? Random.secure();
  return List<int>.generate(16, (_) => rng.nextInt(256))
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
}

/// 密码对不对。
///
/// **逐字节等时比较。** 早退比较会把"前几位对了"泄露成时间差 ——
/// 在本地这算不上现实威胁，但写对它不花什么力气。
bool checkPasscode(ThreadLock lock, String password) {
  final candidate = derivePasscode(password, lock.salt);
  if (candidate.length != lock.hash.length) return false;
  var diff = 0;
  for (var i = 0; i < candidate.length; i++) {
    diff |= candidate.codeUnitAt(i) ^ lock.hash.codeUnitAt(i);
  }
  return diff == 0;
}

/// 归一化一条答案：大小写、空白、标点全抹掉。
///
/// 用户不会记得自己当初有没有打句号，也不会记得中英文标点用的是哪个。
/// 因为一个逗号被挡在外面，是这类找回问题最常见的失败方式。
String normalizeAnswer(String raw) {
  final buffer = StringBuffer();
  for (final rune in raw.toLowerCase().runes) {
    // 只留字母、数字和汉字。
    final isAscii = (rune >= 0x30 && rune <= 0x39) ||
        (rune >= 0x61 && rune <= 0x7a);
    final isCjk = rune >= 0x4e00 && rune <= 0x9fff;
    // 别的语言的字母（西里尔、假名等）也留着。
    final isOtherLetter = rune > 0x7f && !_isPunctuation(rune);
    if (isAscii || isCjk || isOtherLetter) buffer.writeCharCode(rune);
  }
  return buffer.toString();
}

bool _isPunctuation(int rune) =>
    (rune >= 0x2000 && rune <= 0x206f) || // 通用标点
    (rune >= 0x3000 && rune <= 0x303f) || // 中日韩标点
    (rune >= 0xff00 && rune <= 0xff20) || // 全角标点/符号
    (rune >= 0xff3b && rune <= 0xff40) ||
    (rune >= 0xff5b && rune <= 0xff65);

/// 答案算不算对。**模糊**。
///
/// 四档，命中任意一档就算过：
///   1. 归一化之后完全一样；
///   2. 一个包含另一个（"gpt-5" vs "用的 gpt5"）；
///   3. **说的每个字都在原文里、顺序也对**（见下）；
///   4. 编辑距离相似度 ≥ 0.62。
///
/// 第三档是给"记个大意"用的：用户记得的是「看看机器负载」，而原话是
/// 「帮我看看这台机器的负载」。编辑距离把中间多出来的四个字全算成错，
/// 相似度掉到 0.55 就被挡了 —— 而那恰恰是这道题最典型的正确答案。
///
/// 但它不能松到"沾点边就算"：`rack-02` 和 `rack-01` 也有五个字符对得上。
/// 所以要求**用户说的话几乎整个被覆盖**（≥ 0.9），而不是"覆盖了原文的多少"
/// —— 前者惩罚打错的字，后者不惩罚。再加一条最短长度：太短的输入随便
/// 几个字都能在长句里找到。
///
/// 门槛整体比一般的"找回"宽松，因为这道题不是唯一的关卡 —— 找回还要先过
/// 手机锁屏。宽松换来的是"我明明记得，就是打不对那几个字"这种失败少发生。
bool answerMatches(String stored, String given) {
  final a = normalizeAnswer(stored);
  final b = normalizeAnswer(given);
  if (a.isEmpty) return b.isEmpty;
  if (b.isEmpty) return false;
  if (a == b) return true;
  if (a.contains(b) || b.contains(a)) return true;
  if (b.length >= _minSubsequenceLength &&
      _longestCommonSubsequence(a, b) / b.length >= 0.9) {
    return true;
  }
  return _similarity(a, b) >= 0.62;
}

/// 用"说的每个字都在原文里"这条规则时，输入至少要这么长。
///
/// 太短的话随便几个字都能在一段长对话里找到 —— 那条规则就成了"只要
/// 打两个常用字就算答对"。
const _minSubsequenceLength = 5;

/// 短于这个长度就不用编辑距离判定。见 [_similarity]。
const _minEditDistanceLength = 8;

int _longestCommonSubsequence(String a, String b) {
  var previous = List<int>.filled(b.length + 1, 0);
  final current = List<int>.filled(b.length + 1, 0);
  for (var i = 1; i <= a.length; i++) {
    current[0] = 0;
    for (var j = 1; j <= b.length; j++) {
      current[j] = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1)
          ? previous[j - 1] + 1
          : max(previous[j], current[j - 1]);
    }
    previous = List<int>.from(current);
  }
  return previous[b.length];
}

/// 1 - 归一化编辑距离。
///
/// **短答案不走这条规则。** 一个 6 字的答案改一个字，相似度还有 0.83 ——
/// 而 `rack-01` 和 `rack-02` 之间那一个字正是全部的信息量。长答案反过来：
/// 打错一两个字不该把人挡在外面。所以只对够长的串用编辑距离，短的交给
/// 前面那两条（完全相等 / 包含），而归一化已经把标点和大小写的差异抹平了。
double _similarity(String a, String b) {
  final longer = a.length >= b.length ? a : b;
  if (longer.length < _minEditDistanceLength) return 0;
  if (longer.isEmpty) return 1;
  // 长度差太多直接算不像。省掉一次没有意义的 O(mn)：一个两字的答案和一段
  // 三十字的话，编辑距离再怎么算也不该判成"像"。
  final shorter = identical(longer, a) ? b : a;
  if (shorter.length * 2 < longer.length) return 0;
  return 1 - _levenshtein(a, b) / longer.length;
}

int _levenshtein(String a, String b) {
  var previous = List<int>.generate(b.length + 1, (i) => i);
  final current = List<int>.filled(b.length + 1, 0);
  for (var i = 1; i <= a.length; i++) {
    current[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      current[j] = [
        current[j - 1] + 1,
        previous[j] + 1,
        previous[j - 1] + cost,
      ].reduce(min);
    }
    previous = List<int>.from(current);
  }
  return previous[b.length];
}

/// 一道题的标准答案。内置题现从会话里取，自定义题用存下来的那个。
String expectedAnswer(LockChallenge challenge, ThreadFacts facts) {
  final question = challenge.question;
  if (question == null) return challenge.answer;
  return switch (question) {
    LockQuestion.model => facts.model,
    LockQuestion.title => facts.title,
    LockQuestion.persona => facts.persona,
    LockQuestion.opening => facts.opening,
    // 「聊过什么」没有单一标准答案，走 [challengeMatches] 里的逐条匹配。
    LockQuestion.topic => '',
  };
}

/// 一道题答对了没有。
bool challengeMatches(
  LockChallenge challenge,
  ThreadFacts facts,
  String given,
) {
  // 「聊过什么」对着整段对话逐条比：说中任意一句就算。要求复述某一句特定的
  // 话是做不到的 —— 用户记得的是"我在这儿聊过 nginx"，不是第几条消息。
  if (challenge.question == LockQuestion.topic) {
    if (normalizeAnswer(given).isEmpty) return false;
    return facts.spoken.any((line) => answerMatches(line, given));
  }
  final expected = expectedAnswer(challenge, facts);
  // 标准答案是空的题不该被提供（见 ThreadFacts.has）。真出现了就一律不放行
  // —— 那种题任何人留空都能过。
  if (normalizeAnswer(expected).isEmpty) return false;
  return answerMatches(expected, given);
}

/// 安全问题全答对了。
///
/// **必须每一道都对。** 三道里对两道就放行，等于把门槛降到两道 ——
/// 而选三道的理由就是要三道。
bool challengesMatch(
  ThreadLock lock,
  ThreadFacts facts,
  Map<int, String> given,
) {
  if (lock.challenges.isEmpty) return false;
  for (var i = 0; i < lock.challenges.length; i++) {
    if (!challengeMatches(lock.challenges[i], facts, given[i] ?? '')) {
      return false;
    }
  }
  return true;
}

/// 模型那道选择题的选项：正确答案 + 几个别的模型，打乱。
///
/// 让人默写模型名是把主人自己挡在外面 —— `deepseek-ai/DeepSeek-V3.2` 这种
/// 名字没人背得出来。给选项就没这个问题，而混进来的假选项让蒙对的概率
/// 降到 1/6。
///
/// [pool] 是拿来当干扰项的模型名（用户其它渠道上的那些）。不够就用内置的
/// 常见名字补上 —— 选项只有两三个的话，蒙对太容易。
List<String> modelChoices(
  String correct,
  Iterable<String> pool, {
  int total = 6,
  Random? random,
}) {
  final rng = random ?? Random();
  final target = normalizeAnswer(correct);
  final decoys = <String>[];
  void take(Iterable<String> source) {
    for (final name in source) {
      final trimmed = name.trim();
      if (trimmed.isEmpty) continue;
      if (normalizeAnswer(trimmed) == target) continue;
      if (decoys.any((d) => normalizeAnswer(d) == normalizeAnswer(trimmed))) {
        continue;
      }
      decoys.add(trimmed);
    }
  }

  take(pool);
  decoys.shuffle(rng);
  if (decoys.length < total - 1) take(_fallbackModels);

  final choices = <String>[
    correct.trim(),
    ...decoys.take(total - 1),
  ]..shuffle(rng);
  return choices;
}

/// 干扰项不够时的备胎。
///
/// 挑的是各家都眼熟的名字：干扰项要看起来**同样可信**，一眼假的选项等于
/// 没有这个选项。
const _fallbackModels = <String>[
  'gpt-5',
  'claude-sonnet-4-6',
  'gemini-2.5-pro',
  'deepseek-chat',
  'glm-4.6',
  'kimi-k2.5',
  'qwen3-coder',
  'llama-4-scout',
];

/// 这次运行里哪些会话已经开过锁了。
///
/// **只活在内存里。** 落盘的话，"开过一次就一直开着"，那这道锁只在第一次
/// 有用。回到后台就全部重新锁上 —— 把手机递给别人之前，用户唯一会做的动作
/// 就是切出去或者息屏。
class ThreadUnlockSession extends ChangeNotifier {
  final Set<String> _open = <String>{};

  bool isUnlocked(String threadId) => _open.contains(threadId);

  void unlock(String threadId) {
    if (_open.add(threadId)) notifyListeners();
  }

  void lock(String threadId) {
    if (_open.remove(threadId)) notifyListeners();
  }

  /// 全部重新锁上。回到后台时调。
  void lockAll() {
    if (_open.isEmpty) return;
    _open.clear();
    notifyListeners();
  }
}
