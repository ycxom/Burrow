/// 分支树：这个会话岔过几次、每一岔有几版、你现在站在哪儿。
///
/// ## 为什么值得单独一页
///
/// 气泡下面那个「2/3」只能左右翻，而且只看得见**当前这一条链**上的岔口。
/// 岔套岔之后（在版本 2 里又重新生成了一次）那些分支在界面上根本无从抵达
/// —— 数据一直好好地在库里，只是没有入口。
///
/// ## 为什么画成流程图而不是缩进列表
///
/// 一条没岔过的对话画出来就该是一条直线。缩进列表做不到这件事：它把每一层
/// 都往右推一格，于是一条从来没分过支的对话看着像岔了很多次。排法见
/// [layoutBranchGraph] —— 第一个孩子接着父亲往右走，其余的往下掉，
/// 和虚拟机快照管理器那张图是同一个读法。
///
/// 点一个版本跳过去，长按它删掉。跳过去要把从根到它那一路依次切过来
/// （见 [pathTo]），只切它自己是不够的。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../context/overflow_manager.dart';
import '../data/chat_store.dart';
import 'branch_tree.dart';
import 'chat_theme.dart';

/// 一格多大。节点画在格子上部，名字挂在图标下面，连线走格子之间的空隙。
const double _cellWidth = 108;
const double _cellHeight = 88;
const double _nodeRadius = 15;

/// 缩放的上下界。
///
/// 下界 0.35：再小字就成了灰条，图还在但读不出东西 —— 那时候能看的只有
/// 形状，而形状本身也就到这个程度为止。上界 2.5：往上放大只是把同一块内容
/// 铺满屏幕，不会多出信息。
const double _minScale = 0.35;
const double _maxScale = 2.5;

/// 视口之外还建多远的节点。
///
/// 一屏多一点：手指划过去的时候下一批已经在了，不会看到节点一个个"长"
/// 出来；再大就白建了。
const double _preloadMargin = 600;

class BranchTreePage extends StatefulWidget {
  const BranchTreePage({
    required this.history,
    required this.variants,
    required this.onJump,
    required this.onDelete,
    required this.onDeleteMessage,
    super.key,
  });

  /// 当前走着的这条路。主干按它一条一条铺开。
  final List<ChatMessage> history;

  /// 库里存着的那些版本。旁支从它们来。
  final List<BranchVariant> variants;

  /// 跳到某一版。调用方负责把整条路径依次切过去。
  final Future<void> Function(String branchId, int index) onJump;

  /// 删掉某一版。**只从版头进** —— 见 [_NodeTile._menu]。
  final Future<void> Function(String branchId, int index) onDelete;

  /// 删掉单独一条消息。
  final Future<void> Function(GraphNode node) onDeleteMessage;

  @override
  State<BranchTreePage> createState() => _BranchTreePageState();
}

class _BranchTreePageState extends State<BranchTreePage> {
  final _transform = TransformationController();

  /// 已经摆过一次了。**只摆一次** —— 之后每次重建都强行摆正的话，
  /// 用户放大看某一支时会被反复推回原位。
  bool _placed = false;

  /// 视口大小。虚拟化要靠它算"现在看得见哪一块"。
  Size _viewport = Size.zero;

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  /// 一进来先落在「当前位置」上。
  ///
  /// 图是按对话顺序从左往右长的，而「当前位置」在最右端 —— 从起点开始看
  /// 等于每次打开都要先划过整条对话。用户打开这一页想问的是"我现在在
  /// 哪儿、旁边还有什么"，那就直接摆到那儿。
  void _centerOn(GraphNode node, Size viewport) {
    if (viewport.isEmpty) return;
    const scale = 1.0;
    final x = (node.col + 0.5) * _cellWidth + 16;
    final y = (node.row + 0.5) * _cellHeight + 12;
    _transform.value = Matrix4.identity()
      ..translateByDouble(
        viewport.width / 2 - x * scale,
        viewport.height / 2 - y * scale,
        0,
        1,
      )
      ..scaleByDouble(scale, scale, 1, 1);
  }

  /// 这一刻**画得出来**的那几格：视口范围往外放一圈。
  ///
  /// 视口是屏幕坐标，节点是图坐标，中间隔着 InteractiveViewer 那个矩阵 ——
  /// 所以要拿它的逆把视口映射回图上。视口还没量出来时全画（第一帧，
  /// 那时图往往也还小）。
  List<GraphNode> _visibleNodes(List<GraphNode> nodes) {
    if (_viewport.isEmpty) return nodes;
    final matrix = _transform.value;
    if (matrix.determinant() == 0) return nodes;
    final inverse = Matrix4.inverted(matrix);
    final topLeft = MatrixUtils.transformPoint(inverse, Offset.zero);
    final bottomRight = MatrixUtils.transformPoint(
        inverse, Offset(_viewport.width, _viewport.height));
    final view = Rect.fromPoints(topLeft, bottomRight).inflate(_preloadMargin);
    return <GraphNode>[
      for (final node in nodes)
        if (view.overlaps(Rect.fromLTWH(
          node.col * _cellWidth,
          node.row * _cellHeight,
          _cellWidth,
          _cellHeight,
        )))
          node,
    ];
  }

  /// 把整张图塞进屏幕。
  void _fit(Size viewport, Size content) {
    if (content.width <= 0 || content.height <= 0) return;
    final scale = math
        .min(viewport.width / content.width, viewport.height / content.height)
        // 不放大：一张本来就装得下的小图被拉到满屏，节点会大得可笑。
        .clamp(_minScale, 1.0);
    final dx = (viewport.width - content.width * scale) / 2;
    _transform.value = Matrix4.identity()
      ..translateByDouble(dx > 0 ? dx : 0.0, 0, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.chat;
    final nodes = layoutBranchGraph(widget.history, widget.variants);
    final hasBranches = nodes.any((n) => n.branchId != null);
    final cols = nodes.fold<int>(0, (m, n) => n.col > m ? n.col : m) + 1;
    final rows = nodes.fold<int>(0, (m, n) => n.row > m ? n.row : m) + 1;
    final content = Size(cols * _cellWidth + 48, rows * _cellHeight + 52);

    return Scaffold(
      backgroundColor: t.bgPrimary,
      appBar: AppBar(
        title: const Text('分支树'),
        actions: <Widget>[
          if (hasBranches)
            IconButton(
              tooltip: '适应屏幕',
              icon: const Icon(Icons.fit_screen_outlined),
              onPressed: () {
                final box = context.findRenderObject() as RenderBox?;
                if (box != null) _fit(box.size, content);
              },
            ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(22),
          child: Padding(
            padding: const EdgeInsets.only(left: 16, bottom: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                hasBranches
                    ? '双指缩放 · 点旁支上任意一处跳过去 · 长按可以删掉'
                    : '双指缩放 · 这条对话还没有岔过',
                style: TextStyle(fontSize: 11, color: t.tintTertiary),
              ),
            ),
          ),
        ),
      ),
      body: widget.history.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  '这个会话还没有分支。\n'
                  '在任意一条回复上点「重新生成」，或者编辑一条问话并重发，'
                  '旧的那一版就会留在这里。',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 12, height: 1.6, color: t.tintTertiary),
                ),
              ),
            )
          : LayoutBuilder(
              builder: (context, constraints) {
                // 图比屏幕宽的时候先自动缩一次，让人一进来看到的是全貌。
                // 排完版才知道有多宽，所以只能排到这一帧之后再摆。
                _viewport = Size(constraints.maxWidth, constraints.maxHeight);
                if (!_placed && constraints.hasBoundedWidth) {
                  _placed = true;
                  final viewport = _viewport;
                  final here = nodes.lastWhere(
                    (n) => n.kind == GraphNodeKind.here,
                    orElse: () => nodes.first,
                  );
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!mounted) return;
                    // 整张图本来就装得下就摆正中间，装不下就落在当前位置上。
                    if (content.width <= viewport.width &&
                        content.height <= viewport.height) {
                      _fit(viewport, content);
                    } else {
                      _centerOn(here, viewport);
                    }
                  });
                }
                return GestureDetector(
                  // 双击回到 100%。InteractiveViewer 自己不接双击，
                  // 所以这一层不会和拖动/捏合抢手势。
                  onDoubleTap: () => _transform.value = Matrix4.identity(),
                  child: InteractiveViewer(
                    transformationController: _transform,
                    // 不受父级约束：图可以比屏幕大，靠拖动去看。
                    constrained: false,
                    minScale: _minScale,
                    maxScale: _maxScale,
                    // 留出富余，否则缩小之后拖不到边上那几个节点 ——
                    // 而"看得见却拖不过去"比看不见更让人费解。
                    boundaryMargin: const EdgeInsets.all(400),
                    child: SizedBox(
                      width: content.width,
                      height: content.height,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 32, 40),
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: <Widget>[
                            // 连线画在最底下：节点要压在线头上，
                            // 不然箭头会从图标里穿出来。
                            Positioned.fill(
                              child: CustomPaint(
                                painter: _EdgePainter(
                                  nodes: nodes,
                                  line: t.borderPrimary,
                                  active: t.brand,
                                ),
                              ),
                            ),
                            // **只建看得见的那几格**，外加一圈预载。
                            //
                            // 一条聊了几百轮的对话有几百个节点。全部建出来
                            // 是几百个 widget 一次性布局 —— 那就是打开这
                            // 一页时那一下卡顿。而屏幕上同时装得下的从来
                            // 只有十几格。
                            ValueListenableBuilder<Matrix4>(
                              valueListenable: _transform,
                              builder: (_, __, ___) => Stack(
                                clipBehavior: Clip.none,
                                children: <Widget>[
                                  for (final node in _visibleNodes(nodes))
                                    Positioned(
                                      left: node.col * _cellWidth,
                                      top: node.row * _cellHeight,
                                      width: _cellWidth,
                                      height: _cellHeight,
                                      child: _NodeTile(
                                        node: node,
                                        onJump: widget.onJump,
                                        onDelete: widget.onDelete,
                                        onDeleteMessage: widget.onDeleteMessage,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

/// 节点圆心在哪儿。
Offset _center(GraphNode node) => Offset(
      node.col * _cellWidth + _cellWidth / 2,
      node.row * _cellHeight + 8 + _nodeRadius,
    );

/// 父子之间那根线。
///
/// 同一行走直箭头；掉了行的走**折线** —— 先从父亲底下垂下来，到孩子那一行
/// 再拐向右。几个孩子共用同一根竖干，这就是那张图的读法：一根干上挂着的
/// 是同一次分岔的几个选择。
class _EdgePainter extends CustomPainter {
  _EdgePainter({
    required this.nodes,
    required this.line,
    required this.active,
  });

  final List<GraphNode> nodes;
  final Color line;
  final Color active;

  @override
  void paint(Canvas canvas, Size size) {
    final byId = <String, GraphNode>{for (final n in nodes) n.id: n};
    for (final node in nodes) {
      final parentId = node.parentId;
      if (parentId == null) continue;
      final parent = byId[parentId];
      if (parent == null) continue;

      // 活动链上那几段画成品牌色 —— 一眼看出"我是怎么走到当前位置的"。
      final onPath = node.onActivePath && parent.onActivePath;
      final paint = Paint()
        ..color = onPath ? active : line
        ..strokeWidth = onPath ? 1.8 : 1.2
        ..style = PaintingStyle.stroke;

      final from = _center(parent);
      final to = _center(node);
      final startX = from.dx + _nodeRadius + 2;
      final endX = to.dx - _nodeRadius - 5;

      if (node.row == parent.row) {
        canvas.drawLine(Offset(startX, from.dy), Offset(endX, to.dy), paint);
      } else {
        // 竖干走父亲的正下方，拐点留在孩子左边一点，给箭头留地方。
        final trunkX = from.dx;
        final corner = Offset(trunkX, to.dy);
        canvas.drawLine(
            Offset(trunkX, from.dy + _nodeRadius + 2), corner, paint);
        canvas.drawLine(corner, Offset(endX, to.dy), paint);
      }
      _arrow(canvas, Offset(endX, to.dy), paint.color);
    }
  }

  void _arrow(Canvas canvas, Offset tip, Color color) {
    final path = Path()
      ..moveTo(tip.dx + 5, tip.dy)
      ..lineTo(tip.dx - 3, tip.dy - 3.5)
      ..lineTo(tip.dx - 3, tip.dy + 3.5)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_EdgePainter old) =>
      old.nodes != nodes || old.line != line || old.active != active;
}

class _NodeTile extends StatelessWidget {
  const _NodeTile({
    required this.node,
    required this.onJump,
    required this.onDelete,
    required this.onDeleteMessage,
  });

  final GraphNode node;
  final Future<void> Function(String branchId, int index) onJump;
  final Future<void> Function(String branchId, int index) onDelete;
  final Future<void> Function(GraphNode node) onDeleteMessage;

  @override
  Widget build(BuildContext context) {
    final t = context.chat;

    if (node.kind == GraphNodeKind.root) {
      return _Labelled(
        label: node.label,
        color: t.tintTertiary,
        child: Container(
          width: 10,
          height: 10,
          decoration:
              BoxDecoration(color: t.tintTertiary, shape: BoxShape.circle),
        ),
      );
    }

    if (node.kind == GraphNodeKind.more) {
      // 中间省掉的一段。**只省没有岔口的直路**，所以它后面不会藏着分支
      // —— 这一点是那个折叠规则给的保证，不是这里的选择。
      final onPath = node.onActivePath;
      return _Labelled(
        label: node.label,
        color: t.tintTertiary,
        labelLines: 2,
        child: Container(
          width: _nodeRadius * 2,
          height: _nodeRadius * 2,
          decoration: BoxDecoration(
            color: t.bgSecondary,
            shape: BoxShape.circle,
            border: Border.all(
              color: onPath ? t.brand.withValues(alpha: 0.5) : t.borderPrimary,
              width: 1,
            ),
          ),
          child: Icon(Icons.more_horiz, size: 15, color: t.tintTertiary),
        ),
      );
    }

    if (node.kind == GraphNodeKind.here) {
      // 反白的那一块。它答的是打开这张图时最先想问的那句话：我在哪儿。
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Align(
          alignment: Alignment.topCenter,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: t.brand,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(Icons.my_location, size: 16, color: t.bgPrimary),
                const SizedBox(height: 3),
                Text(
                  node.label,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    color: t.bgPrimary,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final onPath = node.onActivePath;
    final accent = onPath ? t.brand : t.tintSecondary;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      // 点旁支上**任意一处**都能跳过去，不用去瞄那个小小的头节点。
      // 主干上的不给点 —— 你已经在上面了，点了什么都不会发生，
      // 而"点了没反应"永远会被当成坏了。
      onTap: node.jumpable ? () => onJump(node.branchId!, node.index) : null,
      // 只剩一版时不给删：那等于删这段对话，是另一个动作。
      // 任何一条消息都能长按：版头管整版，其余管自己那一条。
      onLongPress: () => _menu(context),
      child: _Labelled(
        label: node.label,
        color: node.branchHead ? t.tintWarning : accent,
        detail: node.detail,
        child: Container(
          width: _nodeRadius * 2,
          height: _nodeRadius * 2,
          decoration: BoxDecoration(
            color: onPath ? t.bgBrandSecondary : t.bgSecondary,
            shape: BoxShape.circle,
            border: Border.all(
              // 旁支的头节点描一圈警示色：那一格就是"从这儿分出去的"。
              color: node.branchHead
                  ? t.tintWarning
                  : (onPath ? t.brand : t.borderPrimary),
              width: onPath || node.branchHead ? 1.6 : 1,
            ),
          ),
          child: Icon(
            _roleIcon(node.role),
            size: 14,
            color: onPath ? t.brand : t.tintTertiary,
          ),
        ),
      ),
    );
  }

  static IconData _roleIcon(String role) => switch (role) {
        'user' => Icons.person_outline,
        'assistant' => Icons.chat_bubble_outline,
        'tool' => Icons.terminal,
        _ => Icons.info_outline,
      };

  /// 长按弹出来的那个。
  ///
  /// ## 「删掉整版」只从**版头**进
  ///
  /// 早先随便一个节点长按都能删整版，而中间那些节点的标题是它的角色
  /// （「回复」「命令」）—— 长按第三条看到「删掉回复」，谁都会读成
  /// "删这一条"，按下去却把整支都删了。
  ///
  /// 现在分开：**版头**那一格才管整版（它本来就代表"这一支"），中间那些
  /// 只管自己那一条。想删整版的人会先找到那一支的开头，而那正是他脑子里
  /// "这一版"的样子。
  Future<void> _menu(BuildContext context) async {
    final t = context.chat;
    final version = node.versionLabel;
    final head = node.branchHead && node.total > 1;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: t.bgPrimary,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  version.isEmpty
                      ? node.detail
                      : '$version · 共 ${node.chainLength} 条',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: t.tintSecondary,
                  ),
                ),
              ),
            ),
            if (node.jumpable)
              ListTile(
                leading: const Icon(Icons.my_location),
                title: Text('跳到$version'),
                subtitle:
                    const Text('把对话换成这一版', style: TextStyle(fontSize: 11)),
                onTap: () {
                  Navigator.pop(ctx);
                  onJump(node.branchId!, node.index);
                },
              ),
            if (head)
              ListTile(
                leading: Icon(Icons.delete_sweep_outlined, color: t.tintError),
                title: Text('删掉$version', style: TextStyle(color: t.tintError)),
                subtitle: Text(
                  '这一版的 ${node.chainLength} 条内容会一起删掉',
                  style: const TextStyle(fontSize: 11),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  onDelete(node.branchId!, node.index);
                },
              )
            else
              ListTile(
                leading: Icon(Icons.delete_outline, color: t.tintError),
                title: Text('删除这一条', style: TextStyle(color: t.tintError)),
                subtitle: Text(
                  node.detail.isEmpty ? '只删这一条，别的不动' : node.detail,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  onDeleteMessage(node);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

/// 图标在上、名字在下 —— 和快照管理器一样。名字放旁边的话，一列的宽度会被
/// 最长的那个标题撑开，图就不再是等距的了，而等距正是"这是一张图不是一个
/// 列表"的全部依据。
class _Labelled extends StatelessWidget {
  const _Labelled({
    required this.label,
    required this.color,
    required this.child,
    this.detail = '',
    this.labelLines = 1,
  });

  final String label;
  final Color color;
  final Widget child;
  final String detail;

  /// 岔路口那句问话要两行才装得下，版本名一行就够。
  final int labelLines;

  @override
  Widget build(BuildContext context) {
    final t = context.chat;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const SizedBox(height: 8),
        SizedBox(height: _nodeRadius * 2, child: Center(child: child)),
        const SizedBox(height: 3),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: Text(
            label,
            maxLines: labelLines,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 10.5,
                height: 1.2,
                fontWeight: FontWeight.w600,
                color: color),
          ),
        ),
        if (detail.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              detail,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style:
                  TextStyle(fontSize: 9.5, height: 1.25, color: t.tintTertiary),
            ),
          ),
      ],
    );
  }
}
