/// 记忆检索：BM25 + 覆盖率 + 向量三路 RRF 融合。
///
/// 移植自 `VPetLLM/Core/Services/MemoryRanking.cs` 和 `MemoryRetrievalService.cs`。
/// 它是 [OverflowManager] 的安全网：摘要一定会丢细节，丢掉的细节必须能找回来。
/// 用户说「你之前装的那个包叫什么来着」时，答案在两小时前被摘要掉的那条消息里。
///
/// ## 排序模型
///
/// ```
/// final = 0.5·rrf + 0.25·importance + 0.25·recency
/// ```
///
/// **三维求和而不是相乘**：任一维度低分不应该把整体清零。一条很久以前记下、
/// 但和当前问题高度相关的记忆，仍然应该被召回。相乘的话 recency 一衰减就废了。
///
/// **rrf 融合三路对同一批候选的排序**：
///   - 路 1 BM25：IDF 加权，罕见词命中更值钱
///   - 路 2 覆盖率：命中了查询里多少比例的不同词
///   - 路 3 向量余弦：语义相似，可选，后端不可用时自动退成两路
///
/// 三者量纲互不相同（BM25 无上界、覆盖率 [0,1]、余弦 [-1,1]），直接加权求和
/// 没有意义。RRF 只看排名，天然免疫量纲问题。三路也确实会分歧：BM25 偏爱
/// 罕见词的单点强命中，覆盖率偏爱广泛命中，向量能召回零词法重叠的语义近邻。
library;

import 'dart:math' as math;

// ---------------------------------------------------------------------------
// BM25
// ---------------------------------------------------------------------------

/// BM25 稀疏检索打分。
///
/// 相对「命中了几个词」的朴素计数，BM25 多出三件事：
///   1. **IDF** —— 罕见词权重高。"torch" 只出现在一条记忆里，"安装" 到处都是，
///      前者的命中远比后者有信息量。这是排序变准的主因。
///   2. **TF 饱和** —— 同一个词出现 10 次不等于比出现 1 次相关 10 倍。
///   3. **长度归一化** —— 长消息不因为词多就天然占优。
class Bm25 {
  static const _k1 = 1.2; // TF 饱和速度
  static const _b = 0.75; // 长度归一化强度

  /// 为每篇文档打分，返回数组与 [docTokens] 一一对应。
  /// 未命中任何查询词的文档得分 0。
  static List<double> score(
    List<List<String>> docTokens,
    List<String> queryTerms,
  ) {
    final n = docTokens.length;
    final scores = List<double>.filled(n, 0);
    if (n == 0 || queryTerms.isEmpty) return scores;

    final termFreqs = <Map<String, int>>[];
    var totalLength = 0.0;
    for (final tokens in docTokens) {
      final tf = <String, int>{};
      for (final t in tokens) {
        tf[t] = (tf[t] ?? 0) + 1;
      }
      termFreqs.add(tf);
      totalLength += tokens.length;
    }

    final avgLength = totalLength / n;
    if (avgLength <= 0) return scores;

    for (final term in queryTerms) {
      var df = 0;
      for (final tf in termFreqs) {
        if (tf.containsKey(term)) df++;
      }
      if (df == 0) continue;

      // Robertson-Sparck Jones IDF 的常用平滑形式，恒为正
      final idf = math.log(1.0 + (n - df + 0.5) / (df + 0.5));

      for (var i = 0; i < n; i++) {
        final tf = termFreqs[i][term];
        if (tf == null) continue;
        final docLen = docTokens[i].length;
        final denom = tf + _k1 * (1.0 - _b + _b * docLen / avgLength);
        scores[i] += idf * (tf * (_k1 + 1.0)) / denom;
      }
    }
    return scores;
  }
}

// ---------------------------------------------------------------------------
// RRF
// ---------------------------------------------------------------------------

/// Reciprocal Rank Fusion: `score(d) = Σᵢ 1 / (k + rankᵢ(d))`
///
/// 前提是各路排的是**同一批文档**。若各路来源互不相交，Σ 恒只有一项，
/// RRF 退化成纯粹的排名归一化，反而抹掉了原始分数的信息量。
///
/// Cormack, Clarke & Buettcher (2009).
class RrfFusion {
  /// 论文推荐值，控制排名靠后文档的分数衰减速度。
  static const defaultK = 60;

  /// [rankings] 每条是按相关性降序排列的文档下标。
  static Map<int, double> fuse(int k, List<List<int>> rankings) {
    final fused = <int, double>{};
    for (final ranking in rankings) {
      for (var rank = 0; rank < ranking.length; rank++) {
        final doc = ranking[rank];
        fused[doc] = (fused[doc] ?? 0) + 1.0 / (k + rank + 1);
      }
    }
    return fused;
  }
}

// ---------------------------------------------------------------------------
// 检索服务
// ---------------------------------------------------------------------------

/// 一个可被检索的条目。来源不同，固有重要性不同。
class MemoryDoc {
  final String text;
  final DateTime at;

  /// 0..1 的固有重要性。摘要 0.6、聊天 0.5、上下文邻居 0.25。
  /// 上下文邻居只是为了让读的人（或专家模型）读懂对话，本身没被命中，最低。
  final double importance;

  /// 用于回溯定位，例如 `history:1042` 或 `summary:3`。
  final String source;

  const MemoryDoc({
    required this.text,
    required this.at,
    required this.importance,
    required this.source,
  });
}

class RetrievalHit {
  final MemoryDoc doc;
  final double score;
  const RetrievalHit(this.doc, this.score);
}

typedef Embedder = Future<List<double>> Function(String text);

class MemoryRetrieval {
  static const _alphaRelevance = 0.5;
  static const _betaImportance = 0.25;
  static const _gammaRecency = 0.25;

  /// 每条词法路最多贡献多少候选进 RRF。
  static const _lexicalTopK = 50;
  static const _vectorTopK = 30;

  /// 余弦低于此值不进向量路。归一化向量的余弦对任意两段中文文本通常都是正数，
  /// 不设阈值的话全语料都会挤进候选，RRF 就没有区分度了。
  static const _minCosine = 0.35;

  /// 最终入选上限。这同时限制了喂给专家模型的载荷 ——
  /// 否则召回率一提高，那次 LLM 调用的输入 token 就跟着失控。
  static const _maxSelected = 20;

  /// 每天的新鲜度衰减率。100 天后约衰减到 0.37。
  static const _recencyDecayPerDay = 0.01;

  /// 向量后端。null 表示未配置，此时 RRF 只融合两条词法路。
  /// 手机上这很常见 —— 本地 embedding 模型要额外几十 MB。
  final Embedder? embedder;

  /// 已建好索引的文档向量。键是 [MemoryDoc.source]。
  final Map<String, List<double>> vectorIndex;

  MemoryRetrieval({this.embedder, Map<String, List<double>>? vectorIndex})
      : vectorIndex = vectorIndex ?? {};

  Future<List<RetrievalHit>> search(
    String query,
    List<MemoryDoc> corpus, {
    int topK = 10,
  }) async {
    if (corpus.isEmpty) return const [];

    final queryTerms = tokenize(query).toSet().toList();
    if (queryTerms.isEmpty) return const [];

    final docTokens = corpus.map((d) => tokenize(d.text)).toList();

    // 路 1：BM25
    final bm25 = Bm25.score(docTokens, queryTerms);
    final bm25Rank = _rankByScore(bm25, _lexicalTopK);

    // 路 2：覆盖率 —— 命中了查询里多少比例的不同词。
    // 和 BM25 互补：BM25 会让一个罕见词的强命中盖过一切，
    // 覆盖率则偏爱「把问题里的多个概念都提到了」的文档。
    final coverage = List<double>.generate(corpus.length, (i) {
      final set = docTokens[i].toSet();
      var hit = 0;
      for (final t in queryTerms) {
        if (set.contains(t)) hit++;
      }
      return hit / queryTerms.length;
    });
    final coverageRank = _rankByScore(coverage, _lexicalTopK);

    final rankings = <List<int>>[bm25Rank, coverageRank];

    // 路 3：向量（可选）
    if (embedder != null && vectorIndex.isNotEmpty) {
      try {
        final qv = await embedder!(query);
        final cos = List<double>.generate(corpus.length, (i) {
          final dv = vectorIndex[corpus[i].source];
          if (dv == null) return 0;
          final c = _cosine(qv, dv);
          return c >= _minCosine ? c : 0;
        });
        rankings.add(_rankByScore(cos, _vectorTopK));
      } catch (_) {
        // 向量后端挂了就退成两路。检索降级永远好过检索失败 ——
        // 用户问「之前那个包叫什么」，给个次优答案远好过报错。
      }
    }

    final fused = RrfFusion.fuse(RrfFusion.defaultK, rankings);
    if (fused.isEmpty) return const [];

    // 归一化 rrf 到 [0,1]，好和另外两维加权求和。
    final maxRrf = fused.values.reduce(math.max);
    final now = DateTime.now();

    final hits = fused.entries.map((e) {
      final doc = corpus[e.key];
      final rrf = maxRrf > 0 ? e.value / maxRrf : 0.0;
      final days = now.difference(doc.at).inHours / 24.0;
      final recency = math.exp(-_recencyDecayPerDay * days);
      final score = _alphaRelevance * rrf +
          _betaImportance * doc.importance +
          _gammaRecency * recency;
      return RetrievalHit(doc, score);
    }).toList()
      ..sort((a, b) => b.score.compareTo(a.score));

    return hits.take(math.min(topK, _maxSelected)).toList();
  }

  /// 把结果裁到 token 预算内，拼成注入 prompt 的文本。
  String format(List<RetrievalHit> hits, {int tokenBudget = 800}) {
    if (hits.isEmpty) return '';
    final b = StringBuffer('[检索到的历史记录]\n');
    var used = 0;
    for (final h in hits) {
      final line = '· (${_ago(h.doc.at)}) ${h.doc.text}\n';
      final cost = (line.length / 2.5).ceil();
      if (used + cost > tokenBudget) break;
      b.write(line);
      used += cost;
    }
    b.write('[检索结束]');
    return b.toString();
  }

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 60) return '${d.inMinutes} 分钟前';
    if (d.inHours < 24) return '${d.inHours} 小时前';
    return '${d.inDays} 天前';
  }

  static List<int> _rankByScore(List<double> scores, int topK) {
    final idx = <int>[];
    for (var i = 0; i < scores.length; i++) {
      if (scores[i] > 0) idx.add(i);
    }
    idx.sort((a, b) => scores[b].compareTo(scores[a]));
    return idx.take(topK).toList();
  }

  static double _cosine(List<double> a, List<double> b) {
    if (a.length != b.length) return 0;
    var dot = 0.0, na = 0.0, nb = 0.0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      na += a[i] * a[i];
      nb += b[i] * b[i];
    }
    if (na == 0 || nb == 0) return 0;
    return dot / (math.sqrt(na) * math.sqrt(nb));
  }

  /// 分词。中文按字切（bigram 也一并产出），英文按单词切并小写化。
  ///
  /// 中文不做真分词是有意的：手机上引 jieba 词典要几 MB，而 BM25 的
  /// IDF 机制对单字 + bigram 的组合已经工作得不错 —— 单字「装」到处都是
  /// IDF 极低，bigram「安装」「装包」区分度就够了。
  static List<String> tokenize(String text) {
    final out = <String>[];
    final buf = StringBuffer();
    String? prevCjk;

    void flushAscii() {
      if (buf.isNotEmpty) {
        out.add(buf.toString().toLowerCase());
        buf.clear();
      }
    }

    for (final rune in text.runes) {
      final ch = String.fromCharCode(rune);
      if (_isCjk(rune)) {
        flushAscii();
        out.add(ch);
        if (prevCjk != null) out.add('$prevCjk$ch'); // bigram
        prevCjk = ch;
      } else if (RegExp(r'[A-Za-z0-9_\-./]').hasMatch(ch)) {
        buf.write(ch);
        prevCjk = null;
      } else {
        flushAscii();
        prevCjk = null;
      }
    }
    flushAscii();
    return out;
  }

  static bool _isCjk(int r) =>
      (r >= 0x4E00 && r <= 0x9FFF) || (r >= 0x3400 && r <= 0x4DBF);
}
