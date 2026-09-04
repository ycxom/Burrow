import 'package:burrow/src/context/overflow_manager.dart';
import 'package:burrow/src/ui/message_index.dart';
import 'package:flutter_test/flutter_test.dart';

ChatMessage msg(String role, String content) =>
    ChatMessage(role: role, content: content, at: DateTime(2026));

void main() {
  group('界面下标对回 history', () {
    test('同一批实例时按身份精确命中', () {
      // 会话从数据库读出来时就是这种情况：两个列表装的是同一批对象。
      final user = msg('user', '你好');
      final tool = msg('tool', '[工具结果]');
      final reply = msg('assistant', '你好呀');
      final history = <ChatMessage>[user, tool, reply];
      final visible = <ChatMessage>[user, reply];

      expect(historyIndexOfVisible(visible, history, 0), 0);
      // tool 被滤掉了，所以下标对不上，必须靠查找而不是算偏移。
      expect(historyIndexOfVisible(visible, history, 1), 2);
    });

    test('刚发出去的用户消息：两边不是同一个对象，也要找得到', () {
      // 这就是"编辑对话没反应"的现场。_send 自己 new 一条进 _visible，
      // AgentLoop 又 new 一条进 history（它还要补检查点），内容一样但
      // 不是同一个对象，纯靠身份匹配会返回 -1。
      final visible = <ChatMessage>[
        msg('user', '第一句'),
        msg('assistant', '第一答'),
        msg('user', '第二句'),
      ];
      final history = <ChatMessage>[
        msg('user', '第一句'),
        msg('assistant', '第一答'),
        msg('user', '第二句'),
      ];

      expect(historyIndexOfVisible(visible, history, 0), 0);
      expect(historyIndexOfVisible(visible, history, 2), 2,
          reason: '第二条用户消息要落在 history 的第二条用户消息上');
    });

    test('history 里夹着 tool 和多条助手消息时，用户消息仍然数得准', () {
      // 工具循环：一个回合里 history 有 assistant/tool/assistant 三条，
      // 而界面上只有一条合并后的气泡。
      final visible = <ChatMessage>[
        msg('user', '跑一下测试'),
        msg('assistant', '合并后的正文'),
        msg('user', '再来一次'),
      ];
      final history = <ChatMessage>[
        msg('user', '跑一下测试'),
        msg('assistant', '我先看看'),
        msg('tool', '[工具结果]'),
        msg('assistant', '跑完了'),
        msg('user', '再来一次'),
      ];

      expect(historyIndexOfVisible(visible, history, 2), 4);
    });

    test('助手消息两边条数一致时按序号找得到', () {
      // 没有工具循环的普通一问一答：界面和 history 都是一条助手消息，
      // 序号可信。编辑 AI 回复要靠这条路径把改动写回上下文。
      final visible = <ChatMessage>[
        msg('user', '问'),
        msg('assistant', '答'),
      ];
      final history = <ChatMessage>[
        msg('user', '问'),
        msg('assistant', '答'),
      ];
      expect(historyIndexOfVisible(visible, history, 1), 1);
    });

    test('助手消息被合并过（条数对不上）就返回 -1，不猜', () {
      // 工具循环里 history 有两条助手消息，界面上合成一条。这时按序号
      // 猜必然错位，而错位的后果是把编辑写到别的消息上。
      final visible = <ChatMessage>[
        msg('user', '跑测试'),
        msg('assistant', '合并后的正文'),
      ];
      final history = <ChatMessage>[
        msg('user', '跑测试'),
        msg('assistant', '我先看看'),
        msg('tool', '[工具结果]'),
        msg('assistant', '跑完了'),
      ];
      expect(historyIndexOfVisible(visible, history, 1), -1);
    });

    test('system 消息不参与序号兜底', () {
      final visible = <ChatMessage>[msg('system', '提示')];
      final history = <ChatMessage>[msg('system', '提示')];
      expect(historyIndexOfVisible(visible, history, 0), -1);
    });

    test('越界不崩', () {
      final list = <ChatMessage>[msg('user', 'a')];
      expect(historyIndexOfVisible(list, list, -1), -1);
      expect(historyIndexOfVisible(list, list, 5), -1);
      expect(historyIndexOfVisible(<ChatMessage>[], list, 0), -1);
    });
  });

  group('摘要分隔线的位置', () {
    test('没摘过就不画 —— 返回 0，而不是"画在第 0 条前面"', () {
      // 这条钉的是一个 release 才看得见的 bug：0 被当成位置用，于是列表
      // 最前面插了一条没有对应消息的空行，画的时候取 visible[-1] 抛异常，
      // 而 release 构建把抛异常的 widget 渲染成一块纯灰色方块 ——
      // 表现是「聊天记录上方多出一大片灰色」，看不出和摘要有任何关系。
      final a = msg('user', '你好');
      final b = msg('assistant', '你好呀');
      expect(summaryBoundaryIndex(<ChatMessage>[a, b], <ChatMessage>[a, b], 0),
          0);
    });

    test('线画在被覆盖的最后一条之后', () {
      final all = <ChatMessage>[
        msg('user', '第一句'),
        msg('assistant', '第一答'),
        msg('user', '第二句'),
        msg('assistant', '第二答'),
      ];
      // 前两条被摘要覆盖 → 线画在界面上第 2 条之前。
      expect(summaryBoundaryIndex(all, all, 2), 2);
    });

    test('history 里夹着只给模型看的东西时，位置仍然对得上', () {
      final u1 = msg('user', '第一句');
      final a1 = msg('assistant', '第一答');
      final injected = msg('system', '[检索到的记忆片段]');
      final u2 = msg('user', '第二句');
      // 注入的那条在界面上没有气泡（这里模拟界面把它滤掉的情况）。
      final visible = <ChatMessage>[u1, a1, u2];
      final history = <ChatMessage>[u1, a1, injected, u2];
      // checkpoint 落在注入那条之后 —— 往前退一步才找到界面上有的 a1。
      expect(summaryBoundaryIndex(visible, history, 3), 2);
    });

    test('整段都被覆盖时不画 —— 线下面什么都没有', () {
      final all = <ChatMessage>[msg('user', '就一句'), msg('assistant', '就一答')];
      // 画出来的话，用户看到一条线下面空空如也，只会以为消息没了。
      expect(summaryBoundaryIndex(all, all, 2), 0);
    });

    test('两个列表对不上时宁可不画', () {
      final visible = <ChatMessage>[msg('user', '甲'), msg('assistant', '乙')];
      final history = <ChatMessage>[msg('user', '丙'), msg('assistant', '丁')];
      // 猜一个位置画条线，比不画更糟。
      expect(summaryBoundaryIndex(visible, history, 1), 0);
    });

    test('checkpoint 越界不抛', () {
      final all = <ChatMessage>[msg('user', '甲'), msg('assistant', '乙')];
      expect(summaryBoundaryIndex(all, all, 99), 0);
      expect(summaryBoundaryIndex(<ChatMessage>[], all, 1), 0);
    });
  });
}
