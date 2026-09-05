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

  group('排成图：一句话一个节点', () {
    List<GraphNode> graph(List<ChatMessage> history,
            [List<BranchVariant> variants = const <BranchVariant>[]]) =>
        layoutBranchGraph(history, variants);

    test('没岔过的对话是一条直线', () {
      final nodes = graph(<ChatMessage>[
        msg('user', '你好'),
        msg('assistant', '你好呀'),
      ]);
      expect(nodes.map((n) => n.kind).toList(), <GraphNodeKind>[
        GraphNodeKind.root,
        GraphNodeKind.message,
        GraphNodeKind.message,
        GraphNodeKind.here,
      ]);
      // 全在同一行 —— 缩进列表做不到这件事。
      expect(nodes.map((n) => n.row).toSet(), <int>{0});
      expect(nodes.map((n) => n.col).toList(), <int>[0, 1, 2, 3]);
    });

    test('重新生成：问话只画一遍，各版本从它下面平铺出去', () {
      // 各版本的第一条完全相同，真正分岔的是它后面那条回答。不区分的话
      // 会把同一句问话画两遍，看着像用户问了两次。
      final history = <ChatMessage>[
        msg('user', '配 nginx', branchId: 'b1'),
        msg('assistant', '第二版答'),
      ];
      final nodes = graph(history, <BranchVariant>[
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
      final asked = nodes.where((n) => n.detail == '配 nginx').toList();
      expect(asked.length, 1, reason: '同一句问话不该画两遍');
      for (final entry
          in <String, String>{'第一版答': '版本 1', '第二版答': '版本 2'}.entries) {
        final node = nodes.firstWhere((n) => n.detail == entry.key);
        expect(node.parentId, asked.single.id);
        expect(node.branchHead, isTrue);
        expect(node.label, entry.value);
      }
      // 两支各占一行，谁也没被叠上去。
      expect(
        nodes.firstWhere((n) => n.detail == '第一版答').row,
        isNot(nodes.firstWhere((n) => n.detail == '第二版答').row),
      );
    });

    test('**位置只由版本号决定，和现在选的是哪一版无关**', () {
      // 早先是"当前走的那一版接着主干往右，其余往下掉"。那样每切一次版本
      // 整张图就重排一次：刚才还在下面的那一支被提到主干上，原来主干上的
      // 掉了下去 —— 对话一个字没动，图却面目全非。
      List<GraphNode> withActive(int which) => graph(<ChatMessage>[
            msg('user', '甲', branchId: 'b1'),
            msg('assistant', '答$which'),
          ], <BranchVariant>[
            for (var i = 0; i < 3; i++)
              variant(
                  'b1',
                  i,
                  <ChatMessage>[
                    msg('user', '甲', branchId: 'b1'),
                    msg('assistant', '答$i'),
                  ],
                  active: i == which),
          ]);

      Map<String, String> cells(List<GraphNode> nodes) => <String, String>{
            for (final n in nodes)
              if (n.detail.isNotEmpty) n.detail: '${n.col},${n.row}',
          };

      final a = cells(withActive(0));
      final b = cells(withActive(2));
      expect(a, b, reason: '切了版本，每一格还得在原地');
    });

    test('编辑并重发：连问话一起变了，就挂在它前面那条下面', () {
      final history = <ChatMessage>[
        msg('assistant', '在的'),
        msg('user', '改过的问法', branchId: 'b1'),
        msg('assistant', '新答'),
      ];
      final nodes = graph(history, <BranchVariant>[
        variant('b1', 0, <ChatMessage>[
          msg('user', '原来的问法', branchId: 'b1'),
          msg('assistant', '旧答'),
        ]),
        variant(
            'b1',
            1,
            <ChatMessage>[
              msg('user', '改过的问法', branchId: 'b1'),
              msg('assistant', '新答'),
            ],
            active: true),
      ]);
      final before = nodes.firstWhere((n) => n.detail == '在的');
      final head = nodes.firstWhere((n) => n.detail == '原来的问法');
      expect(head.parentId, before.id);
      expect(head.branchHead, isTrue);
    });

    test('旁支上每一条都能点，不只是头节点', () {
      final history = <ChatMessage>[
        msg('user', '甲', branchId: 'b1'),
        msg('assistant', '答二'),
      ];
      final nodes = graph(history, <BranchVariant>[
        variant('b1', 0, <ChatMessage>[
          msg('user', '甲', branchId: 'b1'),
          msg('assistant', '答一'),
          msg('assistant', '还有一句'),
        ]),
        variant(
            'b1',
            1,
            <ChatMessage>[
              msg('user', '甲', branchId: 'b1'),
              msg('assistant', '答二'),
            ],
            active: true),
      ]);
      for (final text in <String>['答一', '还有一句']) {
        final node = nodes.firstWhere((n) => n.detail == text);
        expect(node.jumpable, isTrue, reason: text);
        expect(node.branchId, 'b1');
        expect(node.index, 0);
      }
      // 主干上的不给点：你已经在上面了。
      expect(nodes.firstWhere((n) => n.detail == '答二').jumpable, isFalse);
    });

    test('两支永远不叠在一起', () {
      final history = <ChatMessage>[
        msg('user', '甲', branchId: 'b1'),
        msg('assistant', '答三'),
      ];
      final nodes = graph(history, <BranchVariant>[
        variant('b1', 0, <ChatMessage>[
          msg('user', '甲', branchId: 'b1'),
          msg('assistant', '答一'),
        ]),
        variant('b1', 1, <ChatMessage>[
          msg('user', '甲', branchId: 'b1'),
          msg('assistant', '答二'),
        ]),
        variant(
            'b1',
            2,
            <ChatMessage>[
              msg('user', '甲', branchId: 'b1'),
              msg('assistant', '答三'),
            ],
            active: true),
      ]);
      final cells = <String>{for (final n in nodes) '${n.col},${n.row}'};
      expect(cells.length, nodes.length);
    });

    test('长对话整条画完，只把没岔口的直路折起来', () {
      // 早先是掐头：只画最后 60 条。那样长会话里**早期的岔口整个看不见**
      // —— 而这一页存在的全部理由就是让人找到那些岔口。
      final history = <ChatMessage>[
        msg('user', '很早的那一问', branchId: 'b1'),
        msg('assistant', '第二版答'),
        for (var i = 0; i < 200; i++) msg('user', '后来第 $i 条'),
      ];
      final nodes = graph(history, <BranchVariant>[
        variant('b1', 0, <ChatMessage>[
          msg('user', '很早的那一问', branchId: 'b1'),
          msg('assistant', '第一版答'),
        ]),
        variant(
            'b1',
            1,
            <ChatMessage>[
              msg('user', '很早的那一问', branchId: 'b1'),
              msg('assistant', '第二版答'),
            ],
            active: true),
      ]);
      // 200 条之前那个岔口一个都没少。
      expect(nodes.where((n) => n.detail == '第一版答').length, 1);
      expect(nodes.where((n) => n.detail == '第二版答').length, 1);
      // 中间那段直路折起来了，节点数不随对话长度涨。
      final more = nodes.where((n) => n.kind == GraphNodeKind.more).toList();
      expect(more.length, 1);
      expect(more.single.label, '省略 195 条');
      expect(nodes.length, lessThan(20));
    });

    test('折起来的那一段头尾都留着', () {
      // 留着才看得出这一段是从哪儿到哪儿。
      final nodes = graph(<ChatMessage>[
        for (var i = 0; i < 30; i++) msg('user', '第 $i 条'),
      ]);
      for (final text in <String>['第 0 条', '第 2 条', '第 27 条', '第 29 条']) {
        expect(nodes.where((n) => n.detail == text).length, 1, reason: text);
      }
      expect(nodes.where((n) => n.detail == '第 10 条'), isEmpty);
    });

    test('短的直路不折', () {
      final nodes = graph(<ChatMessage>[
        for (var i = 0; i < 8; i++) msg('user', '第 $i 条'),
      ]);
      expect(nodes.where((n) => n.kind == GraphNodeKind.more), isEmpty);
      expect(nodes.where((n) => n.kind == GraphNodeKind.message).length, 8);
    });

    test('岔口之间每一段各折各的', () {
      // 折叠是按"两个岔口之间那一段"算的，不是全局掐一刀。
      final history = <ChatMessage>[
        msg('user', '甲', branchId: 'b1'),
        for (var i = 0; i < 30; i++) msg('assistant', '甲后第 $i 条'),
      ];
      final nodes = graph(history, <BranchVariant>[
        variant('b1', 0, <ChatMessage>[
          msg('user', '甲', branchId: 'b1'),
          for (var i = 0; i < 30; i++) msg('assistant', '旧第 $i 条'),
        ]),
        variant(
            'b1',
            1,
            <ChatMessage>[
              msg('user', '甲', branchId: 'b1'),
              for (var i = 0; i < 30; i++) msg('assistant', '甲后第 $i 条'),
            ],
            active: true),
      ]);
      // 两支各自折了一次。
      expect(nodes.where((n) => n.kind == GraphNodeKind.more).length, 2);
    });

    test('岔完之后又聊的那些，一条都不能少', () {
      // **这一条是"过长的聊天渲染不完全"的墓碑。**
      //
      // 活动那一版的快照只在切版本/重新生成时才重写一次；在那之后又聊的
      // 每一句都只在 history 上。照快照画的话，图会在最后一次分岔那里
      // 戛然而止 —— 后面聊了多少句一句都不显示。
      final history = <ChatMessage>[
        msg('user', '岔在这儿', branchId: 'b1'),
        msg('assistant', '第二版答'),
        msg('user', '后来又问的'),
        msg('assistant', '后来又答的'),
      ];
      final nodes = graph(history, <BranchVariant>[
        variant('b1', 0, <ChatMessage>[
          msg('user', '岔在这儿', branchId: 'b1'),
          msg('assistant', '第一版答'),
        ]),
        // 快照停在分岔那一刻，后面两句它不知道。
        variant(
            'b1',
            1,
            <ChatMessage>[
              msg('user', '岔在这儿', branchId: 'b1'),
              msg('assistant', '第二版答'),
            ],
            active: true),
      ]);
      for (final text in <String>['后来又问的', '后来又答的']) {
        expect(nodes.where((n) => n.detail == text).length, 1, reason: text);
      }
      // 「当前位置」接在最后一句后面，不是接在分岔那儿。
      final here = nodes.firstWhere((n) => n.kind == GraphNodeKind.here);
      expect(here.parentId, nodes.firstWhere((n) => n.detail == '后来又答的').id);
    });

    test('刚重新生成完还没说话：当前位置接在那一版上', () {
      final history = <ChatMessage>[
        msg('user', '岔在这儿', branchId: 'b1'),
        msg('assistant', '第二版答'),
      ];
      final nodes = graph(history, <BranchVariant>[
        variant('b1', 0, <ChatMessage>[
          msg('user', '岔在这儿', branchId: 'b1'),
          msg('assistant', '第一版答'),
        ]),
        variant(
            'b1',
            1,
            <ChatMessage>[
              msg('user', '岔在这儿', branchId: 'b1'),
              msg('assistant', '第二版答'),
            ],
            active: true),
      ]);
      final here = nodes.firstWhere((n) => n.kind == GraphNodeKind.here);
      expect(here.parentId, nodes.firstWhere((n) => n.detail == '第二版答').id);
    });

    test('每个节点都找得到自己的父亲', () {
      // 连线是按 parentId 找的，找不到就少画一段 —— 而缺一段线的图看起来
      // 像是有几个节点凭空飘着。
      final nodes = graph(<ChatMessage>[
        msg('user', '甲', branchId: 'b1'),
        msg('assistant', '答二'),
      ], <BranchVariant>[
        variant('b1', 0, <ChatMessage>[
          msg('user', '甲', branchId: 'b1'),
          msg('assistant', '答一'),
        ]),
        variant(
            'b1',
            1,
            <ChatMessage>[
              msg('user', '甲', branchId: 'b1'),
              msg('assistant', '答二'),
            ],
            active: true),
      ]);
      final ids = <String>{for (final n in nodes) n.id};
      for (final node in nodes) {
        if (node.parentId == null) continue;
        expect(ids, contains(node.parentId));
      }
    });

    test('当前位置接在主干最后一条后面', () {
      final nodes = graph(<ChatMessage>[
        msg('user', '甲'),
        msg('assistant', '乙'),
      ]);
      final here = nodes.firstWhere((n) => n.kind == GraphNodeKind.here);
      final last = nodes.firstWhere((n) => n.detail == '乙');
      expect(here.parentId, last.id);
      expect(here.row, last.row);
    });
  });
}
