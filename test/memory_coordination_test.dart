/// 长上下文那几块之间的配合：摘要点、向量缓存、分支、以及摘要走哪条线。
///
/// 这一组里每一条钉的都是**不报错的**故障。摘要点错位只是让窗口变空、
/// 向量缓存串位只是让检索给不相干的结果、摘要模型指派没生效只是账单变贵
/// —— 没有一样会抛异常，全都只能靠测试盯着。
@TestOn('vm')
library;

import 'package:burrow/src/context/memory_retrieval.dart';
import 'package:burrow/src/context/overflow_manager.dart';
import 'package:flutter_test/flutter_test.dart';

ChatMessage msg(String role, String content) =>
    ChatMessage(role: role, content: content, at: DateTime(2026));

List<ChatMessage> history(int n) => <ChatMessage>[
      for (var i = 0; i < n; i++)
        msg(i.isEven ? 'user' : 'assistant', '第 $i 条'),
    ];

void main() {
  group('语料的身份是内容，不是位置', () {
    test('同样的内容在哪个位置都得到同一个键', () {
      // 打开长会话时先只读最后一页，更早的那些在后台补进历史**开头** ——
      // 一补就是几百条，之后每一个下标指的都是别的消息了。
      expect(memoryDocKey('user: 帮我配 nginx'), memoryDocKey('user: 帮我配 nginx'));
    });

    test('内容不一样，键就不一样', () {
      expect(
        memoryDocKey('user: 帮我配 nginx'),
        isNot(memoryDocKey('user: 帮我配 apache')),
      );
    });

    test('键短得能当 map 键，但长到不会撞', () {
      // 用 String.hashCode 会短到几千条就有实打实的碰撞概率，而一次碰撞的
      // 表现是两条不相干的内容共用一个向量 —— 检索不报错，只是一直给错答案。
      final key = memoryDocKey('随便什么');
      expect(key.length, 16);
      final keys = <String>{
        for (var i = 0; i < 5000; i++) memoryDocKey('第 $i 条消息，内容各不相同'),
      };
      expect(keys.length, 5000);
    });
  });

  group('向量缓存', () {
    /// 记下每一批被真的嵌入过的文本。
    late List<List<String>> embedded;

    MemoryRetrieval build({Map<String, List<double>>? seed}) {
      embedded = <List<String>>[];
      return MemoryRetrieval(
        vectorIndex: seed,
        embedder: (texts) async {
          embedded.add(texts);
          return <List<double>>[
            for (var i = 0; i < texts.length; i++) <double>[i.toDouble(), 1],
          ];
        },
      );
    }

    MemoryDoc doc(String text) => MemoryDoc(
          text: text,
          at: DateTime(2026),
          importance: 0.5,
          source: memoryDocKey(text),
        );

    test('同一段内容只嵌入一次', () async {
      final retrieval = build();
      final corpus = <MemoryDoc>[doc('甲'), doc('乙')];
      await retrieval.index(corpus);
      await retrieval.index(corpus);
      expect(embedded.length, 1);
    });

    test('内容换掉之后会重新嵌入，不会拿旧向量顶上', () async {
      // **这一条是那个 bug 的墓碑。** 以前键是 `history:$i`，回退/切分支/
      // 补历史之后，第 i 条已经是另一段内容了，而缓存还认那个键 ——
      // 语义那一路从此一直给不相干的结果，而且不报错。
      final retrieval = build();
      await retrieval.index(<MemoryDoc>[doc('原来那条')]);
      await retrieval.index(<MemoryDoc>[doc('换掉之后这条')]);
      expect(embedded.length, 2);
      expect(embedded.last, <String>['换掉之后这条']);
    });

    test('整段历史往后错开也不会串位', () async {
      // 补历史是把几百条插到**开头**。按位置取键的话，之后每一个键指的都是
      // 别的消息；按内容取键则一条都不受影响。
      final retrieval = build();
      final tail = <MemoryDoc>[doc('尾巴甲'), doc('尾巴乙')];
      await retrieval.index(tail);
      final full = <MemoryDoc>[doc('补进来的头'), ...tail];
      await retrieval.index(full);
      // 只有新补进来的那条要嵌入。
      expect(embedded.last, <String>['补进来的头']);
    });

    test('缓存涨到语料两倍就把用不到的清掉', () async {
      final retrieval = build();
      await retrieval.index(<MemoryDoc>[
        for (var i = 0; i < 10; i++) doc('旧的 $i'),
      ]);
      expect(retrieval.vectorIndex.length, 10);
      // 语料整段换掉（比如切到另一个分支）。
      await retrieval.index(<MemoryDoc>[doc('新的甲'), doc('新的乙')]);
      // 10 + 2 > 2*2，所以清了一次，只留下当前语料这两条。
      expect(retrieval.vectorIndex.length, 2);
    });

    test('语料是空的时候不清 —— 那不代表用不到了', () async {
      final retrieval = build();
      await retrieval.index(<MemoryDoc>[doc('甲')]);
      await retrieval.index(const <MemoryDoc>[]);
      expect(retrieval.vectorIndex.length, 1);
    });
  });

  group('摘要点跟着历史走', () {
    OverflowManager fresh() => OverflowManager(summarize: (_, __) async => '');

    test('删到摘要范围之前：摘要作废，checkpoint 归零', () async {
      // 「删除这条及之后」以前不收 checkpoint（「回到这里」走 AgentLoop
      // 那条路收了）。checkpoint 落在末尾之后时 `history.skip()` 返回空窗口
      // —— 模型当场失忆，而请求照发，没有任何迹象。
      final overflow = fresh();
      overflow.restore(summary: '摘要', checkpoint: 30, historyLength: 50);
      expect(overflow.truncateTo(10), isTrue);
      expect(overflow.checkpoint, 0);
      expect(overflow.buildWindow(history(10)).length, 10);
    });

    test('删在摘要范围之后：窗口还是那一段，摘要还在', () async {
      final overflow = fresh();
      overflow.restore(summary: '摘要', checkpoint: 10, historyLength: 50);
      expect(overflow.truncateTo(30), isFalse);
      final window = overflow.buildWindow(history(30));
      // 一条摘要 + 20 条原文。
      expect(window.length, 21);
      expect(window.first.role, 'system');
    });

    test('checkpoint 越界时窗口不是空的 —— 那是最糟的失败方式', () async {
      // 就算别处漏了收，也不该让模型看到一段只有摘要的上下文。
      final overflow = fresh();
      overflow.restore(summary: '摘要', checkpoint: 999, historyLength: 20);
      expect(overflow.checkpoint, lessThanOrEqualTo(20));
    });
  });
}
