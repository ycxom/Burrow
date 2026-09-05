/// 分支树：库里那张平表怎么拼成一棵树，以及「你在这里」落在哪。
///
/// 层级关系不在表里，在**内容里** —— 一个分支点的锚点消息出现在另一版的
/// 内容中，它就长在那一版下面。拼错的表现不是报错，是一棵和实际对话对不上
/// 的图，而用户会照着它去点。
@TestOn('vm')
library;

import 'package:burrow/src/context/overflow_manager.dart';
import 'package:burrow/src/data/chat_store.dart';
import 'package:burrow/src/ui/branch_tree.dart';
import 'package:flutter_test/flutter_test.dart';

ChatMessage msg(String role, String content, {String? branchId}) => ChatMessage(
      role: role,
      content: content,
      at: DateTime(2026),
      branchId: branchId,
    );

BranchVariant variant(
  String branchId,
  int index,
  List<ChatMessage> tail, {
  bool active = false,
}) =>
    BranchVariant(
      branchId: branchId,
      index: index,
      active: active,
      createdAt: DateTime(2026),
      tail: tail,
    );

void main() {
  group('拼树', () {
    test('没有分支时是空的', () {
      expect(
          buildBranchTree(<ChatMessage>[], const <BranchVariant>[]), isEmpty);
    });

    test('一个岔口两版', () {
      final history = <ChatMessage>[msg('user', '配 nginx', branchId: 'b1')];
      final tree = buildBranchTree(history, <BranchVariant>[
        variant('b1', 0, <ChatMessage>[
          msg('user', '配 nginx', branchId: 'b1'),
          msg('assistant', '第一版答'),
        ]),
        variant(
            'b1',
            1,
            <ChatMessage>[
              msg('user', '配 nginx', branchId: 'b1'),
              msg('assistant', '第二版答'),
            ],
            active: true),
      ]);
      expect(tree.length, 1);
      expect(tree.first.anchorText, '配 nginx');
      expect(tree.first.variants.length, 2);
      expect(tree.first.variants[0].summary, '第一版答');
      expect(tree.first.variants[1].summary, '第二版答');
      // 锚点那条不算进条数 —— 它属于岔路口本身，不属于某一版。
      expect(tree.first.variants[0].messageCount, 1);
    });

    test('后来才岔的那一口，长在前一个岔口选中的那一版里', () {
      // **这一条是那张平铺成一排的图的墓碑。**
      //
      // 一个版本存下来的是**那一刻**的快照 —— 后来才产生的岔口，它的锚点
      // 当时还没有 branchId，自然不在那份快照里。只靠翻内容找嵌套的话，
      // 每一个后出现的岔口都会被当成顶层的，整棵树塌成一排平行的枝。
      //
      // 而活动路径上的先后是确定的：先在「甲」上岔过，又在「乙」上岔一次，
      // 那第二个岔口就长在第一个岔口当前选中的那一版里。
      final history = <ChatMessage>[
        msg('user', '甲', branchId: 'b1'),
        msg('assistant', '答甲'),
        msg('user', '乙', branchId: 'b2'),
      ];
      final tree = buildBranchTree(history, <BranchVariant>[
        // b1 的两版都是**在 b2 出现之前**存的，里面没有 b2 的影子。
        variant('b1', 0, <ChatMessage>[
          msg('user', '甲', branchId: 'b1'),
          msg('assistant', '旧答甲'),
        ]),
        variant(
            'b1',
            1,
            <ChatMessage>[
              msg('user', '甲', branchId: 'b1'),
              msg('assistant', '答甲'),
            ],
            active: true),
        variant('b2', 0, <ChatMessage>[msg('user', '乙', branchId: 'b2')]),
        variant('b2', 1, <ChatMessage>[msg('user', '乙', branchId: 'b2')],
            active: true),
      ]);
      expect(tree.length, 1, reason: 'b2 不该是顶层的');
      expect(tree.first.branchId, 'b1');
      // b2 挂在 b1 选中的那一版（版本 2）下面，不是版本 1。
      expect(tree.first.variants[0].children, isEmpty);
      expect(tree.first.variants[1].children.single.branchId, 'b2');
    });

    test('岔套岔：里层那个长在外层某一版下面，不是顶层', () {
      final history = <ChatMessage>[msg('user', '配 nginx', branchId: 'b1')];
      final tree = buildBranchTree(history, <BranchVariant>[
        variant('b1', 0, <ChatMessage>[
          msg('user', '配 nginx', branchId: 'b1'),
          msg('assistant', '第一版答'),
        ]),
        variant(
            'b1',
            1,
            <ChatMessage>[
              msg('user', '配 nginx', branchId: 'b1'),
              msg('assistant', '第二版答'),
              msg('user', '那 caddy 呢', branchId: 'b2'),
            ],
            active: true),
        variant(
            'b2',
            0,
            <ChatMessage>[
              msg('user', '那 caddy 呢', branchId: 'b2'),
              msg('assistant', 'caddy 答'),
            ],
            active: true),
      ]);
      // 顶层只有 b1 —— b2 的锚点长在 b1 的版本 2 里。
      expect(tree.length, 1);
      expect(tree.first.branchId, 'b1');
      expect(tree.first.variants[0].children, isEmpty);
      expect(tree.first.variants[1].children.single.branchId, 'b2');
    });

    test('一版里岔了两次，两个岔口各归各的', () {
      // 摊平成一串版本的话，那两个岔口在树上再也分不出谁是谁。
      final history = <ChatMessage>[msg('user', '甲', branchId: 'b1')];
      final tree = buildBranchTree(history, <BranchVariant>[
        variant(
            'b1',
            0,
            <ChatMessage>[
              msg('user', '甲', branchId: 'b1'),
              msg('user', '乙', branchId: 'b2'),
              msg('user', '丙', branchId: 'b3'),
            ],
            active: true),
        variant('b2', 0, <ChatMessage>[msg('user', '乙', branchId: 'b2')]),
        variant('b3', 0, <ChatMessage>[msg('user', '丙', branchId: 'b3')]),
      ]);
      final children = tree.first.variants.single.children;
      expect(children.length, 2);
      expect(children.map((c) => c.branchId).toSet(), <String>{'b2', 'b3'});
    });
  });

  group('「你在这里」', () {
    test('活动版才在路径上', () {
      final history = <ChatMessage>[msg('user', '甲', branchId: 'b1')];
      final tree = buildBranchTree(history, <BranchVariant>[
        variant('b1', 0, <ChatMessage>[msg('user', '甲', branchId: 'b1')]),
        variant('b1', 1, <ChatMessage>[msg('user', '甲', branchId: 'b1')],
            active: true),
      ]);
      expect(tree.first.variants[0].onActivePath, isFalse);
      expect(tree.first.variants[1].onActivePath, isTrue);
    });

    test('父版本没被选中时，里面的活动版也不算在路径上', () {
      // **这一条是那句"is_active 不等于你在这里"的全部内容。**
      // b2 自己选着版本 0，但它整个长在 b1 的版本 0 里，而 b1 选的是版本 1
      // —— 这条链断在第一环上。不分清的话，树上会同时出现两个「你在这里」。
      final history = <ChatMessage>[msg('user', '甲', branchId: 'b1')];
      final tree = buildBranchTree(history, <BranchVariant>[
        variant('b1', 0, <ChatMessage>[
          msg('user', '甲', branchId: 'b1'),
          msg('user', '乙', branchId: 'b2'),
        ]),
        variant('b1', 1, <ChatMessage>[msg('user', '甲', branchId: 'b1')],
            active: true),
        variant('b2', 0, <ChatMessage>[msg('user', '乙', branchId: 'b2')],
            active: true),
      ]);
      final nested = tree.first.variants[0].children.single;
      expect(nested.variants.single.active, isTrue, reason: '它自己是选中的');
      expect(nested.variants.single.onActivePath, isFalse,
          reason: '但它父亲那一版没被选中，整条链断了');
    });

    test('整棵树里最多一个「你在这里」', () {
      final history = <ChatMessage>[msg('user', '甲', branchId: 'b1')];
      final tree = buildBranchTree(history, <BranchVariant>[
        variant(
            'b1',
            0,
            <ChatMessage>[
              msg('user', '甲', branchId: 'b1'),
              msg('user', '乙', branchId: 'b2'),
            ],
            active: true),
        variant('b1', 1, <ChatMessage>[msg('user', '甲', branchId: 'b1')]),
        variant('b2', 0, <ChatMessage>[msg('user', '乙', branchId: 'b2')]),
        variant('b2', 1, <ChatMessage>[msg('user', '乙', branchId: 'b2')],
            active: true),
      ]);
      var count = 0;
      void walk(List<BranchPoint> points) {
        for (final point in points) {
          for (final node in point.variants) {
            if (node.onActivePath) count++;
            walk(node.children);
          }
        }
      }

      walk(tree);
      // b1 的版本 1 + 它里面 b2 的版本 2 —— 是一条**链**，链上每一环都算，
      // 但同一层不会有两个。
      expect(count, 2);
    });
  });

  group('跳过去要先切哪几层', () {
    List<BranchPoint> sample() {
      final history = <ChatMessage>[msg('user', '甲', branchId: 'b1')];
      return buildBranchTree(history, <BranchVariant>[
        variant('b1', 0, <ChatMessage>[
          msg('user', '甲', branchId: 'b1'),
          msg('user', '乙', branchId: 'b2'),
        ]),
        variant('b1', 1, <ChatMessage>[msg('user', '甲', branchId: 'b1')],
            active: true),
        variant('b2', 0, <ChatMessage>[msg('user', '乙', branchId: 'b2')]),
        variant('b2', 1, <ChatMessage>[msg('user', '乙', branchId: 'b2')],
            active: true),
      ]);
    }

    test('顶层那一版只要切自己', () {
      expect(pathTo(sample(), 'b1', 0), <({String branchId, int index})>[
        (branchId: 'b1', index: 0),
      ]);
    });

    test('里层那一版要从外往里一层层切', () {
      // 只切它自己是不够的：b2 的锚点长在 b1 的版本 0 里，而当前选的是
      // 版本 1 —— 那时候 b2 的锚点压根不在活动路径上，切都无从切起，
      // 表现是"点了没反应"。
      expect(pathTo(sample(), 'b2', 1), <({String branchId, int index})>[
        (branchId: 'b1', index: 0),
        (branchId: 'b2', index: 1),
      ]);
    });

    test('找不到就返回空，让调用方说一句', () {
      expect(pathTo(sample(), 'b9', 0), isEmpty);
      expect(pathTo(sample(), 'b1', 7), isEmpty);
    });
  });

  group('摘一句给人看', () {
    test('只跑了命令、一句话没说时用命令行顶上', () {
      final tree = buildBranchTree(<ChatMessage>[
        msg('user', '甲', branchId: 'b1')
      ], <BranchVariant>[
        variant('b1', 0, <ChatMessage>[
          msg('user', '甲', branchId: 'b1'),
          ChatMessage(
            role: 'tool',
            content: '一堆输出',
            at: DateTime(2026),
            toolTitle: 'df -h',
          ),
        ]),
      ]);
      expect(tree.first.variants.single.summary, 'df -h');
    });

    test('空白折成一个空格，不让树上一行撑成三行', () {
      final tree = buildBranchTree(<ChatMessage>[
        msg('user', '甲', branchId: 'b1')
      ], <BranchVariant>[
        variant('b1', 0, <ChatMessage>[
          msg('user', '甲', branchId: 'b1'),
          msg('assistant', '第一行\n\n第二行'),
        ]),
      ]);
      expect(tree.first.variants.single.summary, '第一行 第二行');
    });
  });

  group('排成流程图', () {
    List<BranchPoint> forkWith(int variants, {int active = 0}) =>
        buildBranchTree(<ChatMessage>[
          msg('user', '甲', branchId: 'b1')
        ], <BranchVariant>[
          for (var i = 0; i < variants; i++)
            variant('b1', i, <ChatMessage>[msg('user', '甲', branchId: 'b1')],
                active: i == active),
        ]);

    test('岔路口自己是一个节点', () {
      // 只画版本的话，一屏「版本 1/3、版本 2/3、版本 1/2……」之间看不出
      // 哪几个是同一次分岔的选择，也看不出这一岔是在问什么的时候岔的 ——
      // 而"在哪儿岔的"正是用户找那一版时唯一记得住的线索。
      final nodes = layoutBranchGraph(forkWith(2));
      final forks = nodes.where((n) => n.kind == GraphNodeKind.fork).toList();
      expect(forks.length, 1);
      expect(forks.single.label, '甲');
      // 根 → 岔路口 → 版本。
      expect(forks.single.col, 1);
      expect(
        nodes
            .where((n) => n.kind == GraphNodeKind.variant)
            .map((n) => n.col)
            .toSet(),
        <int>{2},
      );
    });

    test('没有分支时是一条直线：起点 → 当前位置', () {
      final nodes = layoutBranchGraph(const <BranchPoint>[]);
      expect(nodes.map((n) => n.kind).toList(),
          <GraphNodeKind>[GraphNodeKind.root, GraphNodeKind.here]);
      // 同一行、下一列 —— 画出来就是一条直线，而那正是它本来的样子。
      expect(nodes.last.row, 0);
      expect(nodes.last.col, 1);
    });

    test('第一个孩子接着往右，其余的往下掉', () {
      // 缩进列表做不到这件事：它把每一层都往右推一格，于是一条从来没分过支
      // 的对话看着像岔了很多次。
      final nodes = layoutBranchGraph(forkWith(3));
      final variants =
          nodes.where((n) => n.kind == GraphNodeKind.variant).toList();
      expect(variants.map((n) => n.col).toSet(), <int>{2});
      expect(variants.map((n) => n.row).toList(), <int>[0, 1, 2]);
    });

    test('两支永远不叠在一起', () {
      // 行号是深度优先发的：一支的子树全部排完，下一支才拿新的行。
      final tree = buildBranchTree(<ChatMessage>[
        msg('user', '甲', branchId: 'b1')
      ], <BranchVariant>[
        variant(
            'b1',
            0,
            <ChatMessage>[
              msg('user', '甲', branchId: 'b1'),
              msg('user', '乙', branchId: 'b2'),
            ],
            active: true),
        variant('b1', 1, <ChatMessage>[msg('user', '甲', branchId: 'b1')]),
        variant('b2', 0, <ChatMessage>[msg('user', '乙', branchId: 'b2')],
            active: true),
        variant('b2', 1, <ChatMessage>[msg('user', '乙', branchId: 'b2')]),
      ]);
      final nodes = layoutBranchGraph(tree);
      final cells = <String>{for (final n in nodes) '${n.col},${n.row}'};
      expect(cells.length, nodes.length);
    });

    test('当前位置接在活动链的最深处', () {
      final tree = buildBranchTree(<ChatMessage>[
        msg('user', '甲', branchId: 'b1')
      ], <BranchVariant>[
        variant(
            'b1',
            0,
            <ChatMessage>[
              msg('user', '甲', branchId: 'b1'),
              msg('user', '乙', branchId: 'b2'),
            ],
            active: true),
        variant('b2', 0, <ChatMessage>[msg('user', '乙', branchId: 'b2')],
            active: true),
      ]);
      final nodes = layoutBranchGraph(tree);
      final here = nodes.firstWhere((n) => n.kind == GraphNodeKind.here);
      // 根 → 岔路口b1 → b1#0 → 岔路口b2 → b2#0 → 当前位置。
      expect(here.parentId, 'b2#0');
      expect(here.col, 5);
    });

    test('活动链断在半路时，当前位置就接在断点上', () {
      // b1 选的是版本 2，而 b2 长在版本 1 里 —— 那条链走不下去。
      final tree = buildBranchTree(<ChatMessage>[
        msg('user', '甲', branchId: 'b1')
      ], <BranchVariant>[
        variant('b1', 0, <ChatMessage>[
          msg('user', '甲', branchId: 'b1'),
          msg('user', '乙', branchId: 'b2'),
        ]),
        variant('b1', 1, <ChatMessage>[msg('user', '甲', branchId: 'b1')],
            active: true),
        variant('b2', 0, <ChatMessage>[msg('user', '乙', branchId: 'b2')],
            active: true),
      ]);
      final nodes = layoutBranchGraph(tree);
      final here = nodes.firstWhere((n) => n.kind == GraphNodeKind.here);
      expect(here.parentId, 'b1#1');
    });

    test('活动那一版还有孩子时，当前位置另起一行', () {
      // 两个节点画在同一格上，看起来是一个节点带着别人的标题。
      final tree = buildBranchTree(<ChatMessage>[
        msg('user', '甲', branchId: 'b1')
      ], <BranchVariant>[
        variant(
            'b1',
            0,
            <ChatMessage>[
              msg('user', '甲', branchId: 'b1'),
              msg('user', '乙', branchId: 'b2'),
            ],
            active: true),
        variant('b2', 0, <ChatMessage>[msg('user', '乙', branchId: 'b2')]),
        variant('b2', 1, <ChatMessage>[msg('user', '乙', branchId: 'b2')]),
      ]);
      final nodes = layoutBranchGraph(tree);
      final cells = <String>{for (final n in nodes) '${n.col},${n.row}'};
      expect(cells.length, nodes.length);
    });

    test('每个节点都找得到自己的父亲', () {
      // 连线是按 parentId 找的，找不到就画不出那一段 —— 而缺一段线的图
      // 看起来像是有几个节点凭空飘着。
      final nodes = layoutBranchGraph(forkWith(3));
      final ids = <String>{for (final n in nodes) n.id};
      for (final node in nodes) {
        if (node.parentId == null) continue;
        expect(ids, contains(node.parentId));
      }
    });

    test('已经站在上面的那一版不给点', () {
      final nodes = layoutBranchGraph(forkWith(2, active: 1));
      final variants =
          nodes.where((n) => n.kind == GraphNodeKind.variant).toList();
      expect(variants[0].jumpable, isTrue);
      expect(variants[1].jumpable, isFalse);
    });
  });

  group('画布尺寸', () {
    test('列数行数都从节点里数出来，不靠猜', () {
      // 画布小了会把边上那几个节点裁掉，大了会让"适应屏幕"缩得莫名其妙。
      final tree = buildBranchTree(<ChatMessage>[
        msg('user', '甲', branchId: 'b1')
      ], <BranchVariant>[
        for (var i = 0; i < 4; i++)
          variant('b1', i, <ChatMessage>[msg('user', '甲', branchId: 'b1')],
              active: i == 0),
      ]);
      final nodes = layoutBranchGraph(tree);
      final cols = nodes.fold<int>(0, (m, n) => n.col > m ? n.col : m) + 1;
      final rows = nodes.fold<int>(0, (m, n) => n.row > m ? n.row : m) + 1;
      // 根 → 岔路口 → 版本 → 当前位置。
      expect(cols, 4);
      // 四个版本：第一个跟着岔路口那一行，其余三个各占一行。
      expect(rows, 4);
    });

    test('每个节点都落在画布里', () {
      final tree = buildBranchTree(<ChatMessage>[
        msg('user', '甲', branchId: 'b1'),
        msg('user', '乙', branchId: 'b2'),
      ], <BranchVariant>[
        variant('b1', 0, <ChatMessage>[msg('user', '甲', branchId: 'b1')],
            active: true),
        variant('b1', 1, <ChatMessage>[msg('user', '甲', branchId: 'b1')]),
        variant('b2', 0, <ChatMessage>[msg('user', '乙', branchId: 'b2')],
            active: true),
        variant('b2', 1, <ChatMessage>[msg('user', '乙', branchId: 'b2')]),
      ]);
      final nodes = layoutBranchGraph(tree);
      final cols = nodes.fold<int>(0, (m, n) => n.col > m ? n.col : m) + 1;
      final rows = nodes.fold<int>(0, (m, n) => n.row > m ? n.row : m) + 1;
      for (final node in nodes) {
        expect(node.col, lessThan(cols));
        expect(node.row, lessThan(rows));
        expect(node.col, greaterThanOrEqualTo(0));
        expect(node.row, greaterThanOrEqualTo(0));
      }
    });
  });
}
