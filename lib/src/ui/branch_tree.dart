/// 把库里那一堆版本记录拼成一棵树。
///
/// ## 树是怎么长出来的
///
/// 库里存的是一张平表：每一行是「某个分支点的第几版 + 那一版从锚点起的
/// 全部内容」。层级关系不在表里，而在**内容里** —— 一个分支点的锚点消息
/// 要是出现在另一版的内容中，它就长在那一版下面。
///
/// ```
/// 会话开始
/// └─ 帮我配一下 nginx 反代          ← 分支点
///    ├─ 版本 1 · 3 条              ← 里面又分了一次
///    │  └─ 那用 caddy 呢            ← 分支点
///    │     ├─ 版本 1 · 2 条
///    │     └─ 版本 2 · 4 条  ← 你在这里
///    └─ 版本 2 · 5 条
/// ```
///
/// ## 「你在这里」不是 is_active
///
/// 每个分支点自己记着「现在选的是第几版」，但那**只是它自己的选择**：
/// 它整个可能长在另一个分支的某一版里，而那一版根本没被选中。所以
/// 「你在这里」要从根往下走一整条链 —— 链上每一环都得是选中的那一版，
/// 断在哪儿，哪儿之后就都不算。
///
/// 分不清这两件事的话，树上会同时出现好几个「你在这里」，而用户看到的是
/// 一棵自相矛盾的图。
library;

import '../context/overflow_manager.dart';
import '../data/chat_store.dart';

/// 树上的一个节点：某个分支点的某一版。
class BranchNode {
  BranchNode({
    required this.branchId,
    required this.index,
    required this.total,
    required this.active,
    required this.onActivePath,
    required this.anchorText,
    required this.summary,
    required this.messageCount,
    required this.createdAt,
    required this.children,
  });

  final String branchId;

  /// 这是第几版，从 0 数。
  final int index;

  /// 这个分支点一共几版。
  final int total;

  /// 这个分支点当前选的就是这一版。
  final bool active;

  /// 从根一路选下来正好走到这一版 —— 也就是「你在这里」那条链上。
  final bool onActivePath;

  /// 锚点那句话。同一个分支点的每一版都一样，是这个"岔路口"的名字。
  final String anchorText;

  /// 这一版之后说了什么。摘第一句非空的助手回复。
  final String summary;

  /// 这一版从锚点起有几条消息。
  final int messageCount;

  final DateTime createdAt;

  /// 套在这一版里的那些分支点。
  ///
  /// 存的是**分支点**而不是摊平的版本列表：一版里可能岔了两次，摊平之后
  /// 那两个岔路口的版本会混成一串，树上再也分不出谁是谁。
  final List<BranchPoint> children;
}

/// 一个分支点：它的全部版本。
class BranchPoint {
  BranchPoint({
    required this.branchId,
    required this.anchorText,
    required this.variants,
  });

  final String branchId;
  final String anchorText;
  final List<BranchNode> variants;

  bool get onActivePath => variants.any((v) => v.onActivePath);
}

/// 拼树。[history] 是当前活动路径，[variants] 是库里那一堆。
///
/// 返回**顶层**那几个分支点：锚点直接落在活动路径上、没有套在别人版本里的
/// 那些。顺序按锚点在活动路径上的先后 —— 树读起来要和对话读起来一个方向。
List<BranchPoint> buildBranchTree(
  List<ChatMessage> history,
  List<BranchVariant> variants,
) {
  if (variants.isEmpty) return const <BranchPoint>[];

  // 分支点 → 它的那几版。
  final byBranch = <String, List<BranchVariant>>{};
  for (final variant in variants) {
    byBranch
        .putIfAbsent(variant.branchId, () => <BranchVariant>[])
        .add(variant);
  }
  for (final list in byBranch.values) {
    list.sort((a, b) => a.index.compareTo(b.index));
  }

  // 每个分支点当前选的是第几版。链要顺着"选中的那一版"往下接。
  final activeIndexOf = <String, int>{};
  for (final entry in byBranch.entries) {
    final chosen = entry.value.where((v) => v.active);
    activeIndexOf[entry.key] =
        chosen.isEmpty ? entry.value.first.index : chosen.first.index;
  }

  // 谁长在谁的哪一版里。
  final parentOf = <String, ({String branchId, int index})>{};

  // ## 第一条路：顺着活动路径排成一条链
  //
  // **这一条不能靠翻存下来的内容找。** 一个版本存下来的是**那一刻**的一段
  // 快照 —— 后来才产生的岔口，它的锚点当时还没有 branchId，自然不在那份
  // 快照里。只翻内容的话，每一个后出现的岔口都会被当成顶层的，整棵树塌成
  // 一排平行的枝（实测就是这样）。
  //
  // 而活动路径上的先后是确定的：在第 3 条上岔过一次、又在第 20 条上岔一次，
  // 那第二个岔口就长在第一个岔口**当前选中的那一版**里 —— 它本来就是顺着
  // 那一版聊下去才出现的。
  final chain = <String>[];
  final seenInHistory = <String>{};
  for (final message in history) {
    final id = message.branchId;
    if (id == null || !byBranch.containsKey(id)) continue;
    if (seenInHistory.add(id)) chain.add(id);
  }
  for (var i = 1; i < chain.length; i++) {
    parentOf[chain[i]] = (
      branchId: chain[i - 1],
      index: activeIndexOf[chain[i - 1]]!,
    );
  }

  // ## 第二条路：不在活动路径上的，只能去内容里找
  //
  // 它们藏在某个**没被选中**的版本里 —— 那一版存下来的时候，它已经存在了，
  // 所以翻得到。父亲取**最贴身的那个**（tail 最短的那一版）：外层版本从更早
  // 的位置开始，自然把里层那一段整个包住，取错就会让层级和实际嵌套对不上。
  final lengthOf = <String, int>{};
  for (final variant in variants) {
    for (final message in variant.tail) {
      final id = message.branchId;
      if (id == null || id == variant.branchId) continue;
      if (seenInHistory.contains(id)) continue;
      final key = '${variant.branchId}#${variant.index}';
      final incumbent = parentOf[id];
      final incumbentKey =
          incumbent == null ? null : '${incumbent.branchId}#${incumbent.index}';
      if (incumbent == null ||
          variant.tail.length < (lengthOf[incumbentKey] ?? 1 << 30)) {
        parentOf[id] = (branchId: variant.branchId, index: variant.index);
        lengthOf[key] = variant.tail.length;
      }
    }
  }

  // 反过来：每一版下面挂着哪几个岔口。
  final childrenOf = <String, List<String>>{};
  for (final entry in parentOf.entries) {
    childrenOf
        .putIfAbsent(
            '${entry.value.branchId}#${entry.value.index}', () => <String>[])
        .add(entry.key);
  }

  // 顶层：链的第一个，加上那些谁也没装着的孤儿（回退删掉过一段的）。
  final topLevel = <String>[
    if (chain.isNotEmpty) chain.first,
    for (final id in byBranch.keys)
      if (!parentOf.containsKey(id) && !seenInHistory.contains(id)) id,
  ];

  BranchPoint build(String branchId, bool parentOnPath) {
    final list = byBranch[branchId]!;
    final anchorText = _firstNonEmpty(
      list.isEmpty ? const <ChatMessage>[] : list.first.tail,
      role: 'user',
    );
    return BranchPoint(
      branchId: branchId,
      anchorText: anchorText,
      variants: <BranchNode>[
        for (final variant in list)
          () {
            final onPath = parentOnPath && variant.active;
            final key = '$branchId#${variant.index}';
            return BranchNode(
              branchId: branchId,
              index: variant.index,
              total: list.length,
              active: variant.active,
              onActivePath: onPath,
              anchorText: anchorText,
              summary: _firstNonEmpty(variant.tail, role: 'assistant'),
              // 锚点那条不算 —— 它属于岔路口本身，不属于某一版。
              messageCount: variant.tail.isEmpty ? 0 : variant.tail.length - 1,
              createdAt: variant.createdAt,
              children: <BranchPoint>[
                for (final child in (childrenOf[key] ?? const <String>[]))
                  if (byBranch.containsKey(child)) build(child, onPath),
              ],
            );
          }(),
      ],
    );
  }

  return <BranchPoint>[for (final id in topLevel) build(id, true)];
}

/// 从这一段里摘一句给人看的话。
String _firstNonEmpty(List<ChatMessage> tail, {required String role}) {
  for (final message in tail) {
    if (message.role != role) continue;
    final line = message.content.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (line.isNotEmpty) return line;
  }
  // 那一版可能只有工具调用（模型一句话没说，全在跑命令）。
  for (final message in tail) {
    if (message.role != 'tool') continue;
    final title = message.toolTitle?.trim() ?? '';
    if (title.isNotEmpty) return title;
  }
  return '';
}

/// 从根走到 [target] 要依次把哪几个分支点切到第几版。
///
/// 「跳到这一版」不能只切它自己：它可能套在别人的某一版里，而那一版当前
/// 没被选中 —— 那时候它的锚点根本不在活动路径上，切都无从切起。所以要
/// **从外往里**一层层切过去，顺序就是这个列表。
///
/// 已经在路径上的那几环也会出现在列表里（切它们是空操作），这样调用方
/// 不用自己判断从哪一环开始。
List<({String branchId, int index})> pathTo(
  List<BranchPoint> tree,
  String branchId,
  int index,
) {
  List<({String branchId, int index})>? walk(
    List<BranchPoint> points,
    List<({String branchId, int index})> prefix,
  ) {
    for (final point in points) {
      for (final node in point.variants) {
        final here = <({String branchId, int index})>[
          ...prefix,
          (branchId: node.branchId, index: node.index),
        ];
        if (node.branchId == branchId && node.index == index) return here;
        final deeper = walk(node.children, here);
        if (deeper != null) return deeper;
      }
    }
    return null;
  }

  return walk(tree, const <({String branchId, int index})>[]) ??
      const <({String branchId, int index})>[];
}

// ---------------------------------------------------------------------------
// 画成图
// ---------------------------------------------------------------------------

enum GraphNodeKind {
  /// 会话开始那个小圆点。
  root,

  /// 一个岔路口 —— 也就是被重新生成/编辑过的那句问话。
  ///
  /// **必须画出来。** 只画版本的话，一屏「版本 1/3、版本 2/3、版本 1/2……」
  /// 之间看不出哪几个是同一次分岔的选择，也看不出这一岔是在问什么的时候岔的
  /// —— 而"在哪儿岔的"正是用户找那一版时唯一记得住的线索。
  fork,

  /// 一个版本。
  variant,

  /// 「当前位置」。
  ///
  /// 单独一个节点，而不是把活动那一版标亮 —— 这两件事在读图的人眼里是
  /// 不同的：一个是"存下来的某一版"，一个是"你现在正站在哪儿"。快照管理器
  /// 里也是这么分的，而那个分法之所以站得住，是因为它答的正是用户打开这张图
  /// 时想问的那句话。
  here,
}

/// 图上的一个节点，已经排好了行列。
class GraphNode {
  const GraphNode({
    required this.id,
    required this.kind,
    required this.col,
    required this.row,
    required this.parentId,
    required this.label,
    this.detail = '',
    this.branchId,
    this.index = 0,
    this.total = 0,
    this.onActivePath = false,
  });

  /// `b1#0` / `root` / `here`。连线按它找父亲。
  final String id;
  final GraphNodeKind kind;

  /// 第几列（从左往右）、第几行（从上往下）。
  final int col;
  final int row;

  final String? parentId;

  final String label;
  final String detail;

  final String? branchId;
  final int index;
  final int total;
  final bool onActivePath;

  bool get jumpable => kind == GraphNodeKind.variant && !onActivePath;
}

/// 把树排成快照管理器那种流程图：**第一个孩子接着父亲往右走，其余的各占一行
/// 往下掉**。
///
/// 这个排法不是为了好看。它让"一条没岔过的对话"画出来就是一条直线 ——
/// 而直线正是它本来的样子；只有真的岔了，才会往下掉出一支。用等距的树状缩进
/// 画的话，一条从来没分过支的对话也会缩进好几级，看着像岔了很多次。
///
/// 行号用一个全局计数器往下发，而且是深度优先：一支的子树全部排完，
/// 下一支才拿新的行 —— 所以两支永远不会叠在一起。
List<GraphNode> layoutBranchGraph(List<BranchPoint> tree) {
  final out = <GraphNode>[
    const GraphNode(
      id: 'root',
      kind: GraphNodeKind.root,
      col: 0,
      row: 0,
      parentId: null,
      label: '会话开始',
      onActivePath: true,
    ),
  ];
  var maxRow = 0;

  // 「你在这里」接在活动链的**最深处**。
  var deepestId = 'root';
  var deepestCol = 0;
  var deepestRow = 0;

  void place(
      List<BranchPoint> points, String parentId, int parentCol, int parentRow) {
    var firstPoint = true;
    for (final point in points) {
      // 岔路口自己占一格：它是"在这儿分的岔"，下面挂着几个选择。
      final forkRow = firstPoint ? parentRow : ++maxRow;
      firstPoint = false;
      final forkCol = parentCol + 1;
      final forkId = 'fork:${point.branchId}';
      out.add(GraphNode(
        id: forkId,
        kind: GraphNodeKind.fork,
        col: forkCol,
        row: forkRow,
        parentId: parentId,
        label: point.anchorText.isEmpty ? '（这一问没有文字）' : point.anchorText,
        branchId: point.branchId,
        onActivePath: point.onActivePath,
      ));

      var first = true;
      for (final node in point.variants) {
        final row = first ? forkRow : ++maxRow;
        first = false;
        final col = forkCol + 1;
        final id = '${node.branchId}#${node.index}';
        out.add(GraphNode(
          id: id,
          kind: GraphNodeKind.variant,
          col: col,
          row: row,
          parentId: forkId,
          label: '版本 ${node.index + 1}/${node.total}',
          detail: node.summary,
          branchId: node.branchId,
          index: node.index,
          total: node.total,
          onActivePath: node.onActivePath,
        ));
        if (node.onActivePath && col > deepestCol) {
          deepestCol = col;
          deepestId = id;
          deepestRow = row;
        }
        place(node.children, id, col, row);
      }
    }
  }

  place(tree, 'root', 0, 0);

  // 那一行要是已经被别人占了（活动那一版自己还有孩子），就另起一行 ——
  // 两个节点画在同一格上，看起来是一个节点带着别人的标题。
  final taken = out.any((n) => n.col == deepestCol + 1 && n.row == deepestRow);
  out.add(GraphNode(
    id: 'here',
    kind: GraphNodeKind.here,
    col: deepestCol + 1,
    row: taken ? ++maxRow : deepestRow,
    parentId: deepestId,
    label: '当前位置',
    onActivePath: true,
  ));
  return out;
}
