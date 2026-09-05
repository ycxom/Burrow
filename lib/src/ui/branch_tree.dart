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

/// 图上一个节点是什么。
enum GraphNodeKind {
  /// 会话开始那个小圆点。
  root,

  /// 一条消息。
  ///
  /// **一句话一个节点。** 早先只画"岔路口 + 版本 N/M"，两个毛病：
  ///
  ///   - 看不出**是在哪一句上岔的** —— 而那正是用户回头找某一版时唯一
  ///     记得住的线索；
  ///   - 「版本 1/3」被读成"选了第 3 个"。这一版有几条消息、当前选的是
  ///     第几版，是两件事，挤在一个 `N/M` 里谁都分不清。
  ///
  /// 画成消息之后这两件事都不用解释了：链有多长就是有几条，岔在哪儿就画
  /// 在哪儿。
  message,

  /// 中间省掉的一段。**只省没有岔口的直路** —— 见 [_collapseRun]。
  more,

  /// 「当前位置」。
  ///
  /// 单独一个节点，而不是把最后一条标亮：一个是"说过的话"，一个是"你现在
  /// 站在哪儿"，在读图的人眼里是两件事。
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
    this.role = '',
    this.branchId,
    this.index = 0,
    this.total = 0,
    this.onActivePath = false,
    this.branchHead = false,
  });

  final String id;
  final GraphNodeKind kind;

  /// 第几列（从左往右）、第几行（从上往下）。
  final int col;
  final int row;

  final String? parentId;

  /// 节点下面那行小字。消息节点是角色，分支头是「版本 2」。
  final String label;

  /// 再下面那两行：这句话说了什么。
  final String detail;

  /// user / assistant / tool / system。决定画哪个图标。
  final String role;

  /// 这个节点属于哪个分支的哪一版。主干上的消息没有。
  final String? branchId;
  final int index;

  /// 那个分支点一共几版。界面上用来判断"删得删不得"。
  final int total;

  final bool onActivePath;

  /// 这是一支旁支的**第一个**节点。只有它挂「版本 N」那个标签 ——
  /// 每个节点都挂的话，一支上会重复十几遍同一句话。
  final bool branchHead;

  /// 点它能跳过去。主干上的消息不用跳，你已经在上面了。
  bool get jumpable => branchId != null && !onActivePath;
}

/// 一段**没有任何岔口**的直路超过这么长，中间就折起来。
///
/// ## 为什么按"直路"折，而不是按"前面多少条"折
///
/// 早先是掐头：只画最后 60 条，前面收成一个节点。那样长会话里**早期的
/// 岔口整个看不见** —— 而这一页存在的全部理由就是让人找到那些岔口。
/// 用户说"过长的聊天渲染不完全"，指的正是这个。
///
/// 现在只折"两个岔口之间那段没什么可看的直路"：岔口一个都不会少，而节点
/// 数不再随对话长度涨 —— 它只跟岔了几次有关，而那个数天然很小
/// （每一次都得用户亲手点一下才会出现）。
const int _collapseRun = 12;

/// 折起来的那一段，头尾各留几条 —— 留着才看得出这一段是从哪儿到哪儿。
const int _keepEnds = 3;

/// 两条消息算不算同一句。
///
/// 按内容比而不是按对象比：变体是从库里读回来的，和内存里那份 history
/// 天然是两批对象。
bool _sameMessage(ChatMessage a, ChatMessage b) =>
    a.role == b.role && a.content == b.content;

/// 把对话连同它的旁支排成一张图。
///
/// [history] 是当前走着的这条路，[variants] 是库里存着的那些版本。
///
/// ## 岔口处**所有版本都是兄弟**，谁也不占主干
///
/// 早先的排法是"当前走的那一版接着主干往右，其余的往下掉"。那样每切一次
/// 版本，整张图就重排一次：刚才还在下面第三行的那一支，被**提到**主干上，
/// 而原来在主干上的掉了下去。图上每个节点的位置都变了，而对话本身一个字
/// 没动 —— 看着就是一团理不清的东西。
///
/// 现在岔口一到，主干就在那儿结束，N 个版本按**版本号顺序**平铺成兄弟。
/// 位置只由"第几版"决定，和"现在选的是哪一版"无关，所以切来切去图是稳的；
/// 你在哪一支，只用颜色和末端那个「当前位置」表示。
///
/// ## 分岔点不一定是锚点那一条
///
/// 一个版本存的是"从锚点起的一整段"，而锚点那条本身各版本可能一样也可能不一样：
///
///   - 「重新生成」不动问话 —— 各版本的第一条完全相同，真正分岔的是它后面
///     那条回答。这时那句问话画在主干上，只画一遍，各版本从它下面分出去。
///   - 「编辑并重发」连问话一起改了 —— 第一条就不一样，那就得从问话
///     **前面**那一条分出去，每一版画自己那句问话。
///
/// 不区分的话，前一种情况会把同一句问话画两遍，看着像用户问了两次。
List<GraphNode> layoutBranchGraph(
  List<ChatMessage> history,
  List<BranchVariant> variants,
) {
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
  var uid = 0;

  final byBranch = <String, List<BranchVariant>>{};
  for (final variant in variants) {
    byBranch
        .putIfAbsent(variant.branchId, () => <BranchVariant>[])
        .add(variant);
  }
  for (final list in byBranch.values) {
    list.sort((a, b) => a.index.compareTo(b.index));
  }

  /// 铺一段消息。返回**活动那条链**的末端 —— 「当前位置」接在它后面。
  ({String id, int col, int row}) run(
    List<ChatMessage> messages,
    String parentId,
    int parentCol,
    int parentRow, {
    String? branchId,
    int index = 0,
    int total = 0,
    bool onPath = true,
    String? headLabel,
    Set<String> open = const <String>{},
  }) {
    var id = parentId;
    var col = parentCol;
    var row = parentRow;
    var first = true;
    var end = (id: id, col: col, row: row);

    void emit(ChatMessage message, {String? head}) {
      col += 1;
      final nodeId = 'n${uid++}';
      out.add(GraphNode(
        id: nodeId,
        kind: GraphNodeKind.message,
        col: col,
        row: row,
        parentId: id,
        label: head ?? _roleLabel(message),
        detail: _brief(message),
        role: message.role,
        branchId: branchId,
        index: index,
        total: total,
        onActivePath: onPath,
        branchHead: head != null,
      ));
      id = nodeId;
      end = (id: id, col: col, row: row);
    }

    /// 这一条是不是一个还没展开过的岔口。
    bool isFork(ChatMessage message) {
      final id = message.branchId;
      if (id == null || open.contains(id)) return false;
      return (byBranch[id]?.length ?? 0) > 1;
    }

    for (var mi = 0; mi < messages.length; mi++) {
      final message = messages[mi];
      final anchor = message.branchId;
      final siblings =
          anchor == null || open.contains(anchor) ? null : byBranch[anchor];

      // `open` 是这一路上已经展开过的那些岔口。
      //
      // **少了它会无限递归。** 各版本的第一条不一样时（编辑并重发），
      // 共享前缀是 0，于是每个版本要画的那一段**从锚点自己那条开始** ——
      // 而那条身上带着的正是这个岔口的 id。一进去又当成新岔口展开一次，
      // 转眼就爆栈。
      if (anchor != null && siblings != null && siblings.length > 1) {
        // 各版本一开头共有的那几条只画一遍，画在主干上。
        final common = _commonPrefix(siblings);
        for (var k = 0; k < common && mi + k < messages.length; k++) {
          emit(messages[mi + k], head: first && k == 0 ? headLabel : null);
          first = false;
        }
        // 挂点：有共享前缀就挂在最后一条共享的下面，没有就挂在岔口**前面**
        // 那一条下面。
        final hangId = id;
        final hangCol = col;

        ({String id, int col, int row})? activeEnd;
        for (var v = 0; v < siblings.length; v++) {
          final variant = siblings[v];
          final live = onPath && variant.active;

          // **正在走的那一支画的是活的对话，不是库里那份快照。**
          //
          // 活动那一版的快照只在切版本/重新生成时才重写一次；在那之后又聊
          // 的每一句都只在 history 上，快照里没有。照快照画的话，图会在
          // 最后一次分岔那里戛然而止 —— 后面聊了一百句一句都不显示，
          // 而那正是"过长的聊天渲染不完全"。
          //
          // 别的版本没有"活的"那一份，只能画快照 —— 它们本来也就到那儿为止。
          final rest = live
              ? messages.sublist(
                  mi + common < messages.length ? mi + common : messages.length)
              : (variant.tail.length > common
                  ? variant.tail.sublist(common)
                  : const <ChatMessage>[]);
          if (rest.isEmpty) {
            // 活动这一支正好停在岔口上（刚重新生成完还没说话）——
            // 「当前位置」就接在共享的最后一条后面。
            if (live) activeEnd = end;
            continue;
          }
          // 第一版接着挂点那一行，其余的各起一行。**按版本号排，
          // 不按谁是活动的** —— 这就是"不置顶"。
          final r = v == 0 ? row : ++maxRow;
          final tip = run(
            rest,
            hangId,
            hangCol,
            r,
            branchId: variant.branchId,
            index: variant.index,
            total: siblings.length,
            onPath: live,
            headLabel: '版本 ${variant.index + 1}',
            open: <String>{...open, anchor},
          );
          if (live) activeEnd = tip;
        }
        // 主干在岔口处结束：后面那些消息属于某一个版本，已经画在它那一支上了。
        return activeEnd ?? end;
      }

      // 接下来一段没有任何岔口的直路有多长。
      var j = mi;
      while (j < messages.length && !isFork(messages[j])) {
        j++;
      }
      final straight = j - mi;
      if (straight > _collapseRun) {
        for (var k = 0; k < _keepEnds; k++) {
          emit(messages[mi + k], head: first && k == 0 ? headLabel : null);
          first = false;
        }
        col += 1;
        final moreId = 'n${uid++}';
        out.add(GraphNode(
          id: moreId,
          kind: GraphNodeKind.more,
          col: col,
          row: row,
          parentId: id,
          label: '省略 ${straight - _keepEnds * 2} 条',
          role: 'more',
          branchId: branchId,
          index: index,
          total: total,
          onActivePath: onPath,
        ));
        id = moreId;
        end = (id: id, col: col, row: row);
        // 跳到这一段的最后几条上，接着一条一条画。
        mi = j - _keepEnds - 1;
        continue;
      }

      emit(message, head: first ? headLabel : null);
      first = false;
    }
    return end;
  }

  // ---- 主干 ----
  //
  // 整条铺开，一条都不掐掉。太长的直路由 run 自己折（见 _collapseRun）,
  // 而岔口一个都不会少。
  final tip = run(history, 'root', 0, 0);

  out.add(GraphNode(
    id: 'here',
    kind: GraphNodeKind.here,
    col: tip.col + 1,
    row: tip.row,
    parentId: tip.id,
    label: '当前位置',
    onActivePath: true,
  ));
  return out;
}

/// 这几个版本一开头共有多少条一模一样的消息。
int _commonPrefix(List<BranchVariant> siblings) {
  if (siblings.isEmpty) return 0;
  var common = 0;
  outer:
  while (true) {
    for (final variant in siblings) {
      if (common >= variant.tail.length) break outer;
      if (!_sameMessage(variant.tail[common], siblings.first.tail[common])) {
        break outer;
      }
    }
    common++;
  }
  return common;
}

String _roleLabel(ChatMessage message) => switch (message.role) {
      'user' => '你',
      'assistant' => '回复',
      'tool' => '命令',
      _ => '系统',
    };

/// 节点下面那两行。太长的截断 —— 图上一格就那么宽。
String _brief(ChatMessage message) {
  final raw = message.role == 'tool'
      ? (message.toolTitle ?? message.toolName ?? '')
      : message.content;
  final line = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
  return line.length > 28 ? '${line.substring(0, 28)}…' : line;
}
