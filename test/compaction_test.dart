/// 压缩系统：滚动摘要为什么会「看起来没生效」。
///
/// 这一组钉的三件事都**不会报错**，只会让上下文安静地出问题：
///   - 摘要请求打到一个不存在的端点（协议分派只写了一半）
///   - 摘要失败之后 checkpoint 照样前移 —— 消息被踢出窗口，没有摘要顶上
///   - 摘要状态不落盘 —— 重开会话就归零，整段历史重新原样发出去
library;

import 'package:burrow/src/context/overflow_manager.dart';
import 'package:burrow/src/llm/llm_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

ChatMessage msg(String role, String content) =>
    ChatMessage(role: role, content: content, at: DateTime.now());

List<ChatMessage> history(int n) => <ChatMessage>[
      for (var i = 0; i < n; i++)
        msg(i.isEven ? 'user' : 'assistant', '第 $i 条消息，随便说点什么。'),
    ];

void main() {
  group('摘要请求的协议分派', () {
    /// 记下打到哪个端点，然后一律回 404。各协议真实的响应格式不同，
    /// 这里只关心**地址对不对**。
    (List<String>, http.Client) recorder() {
      final hits = <String>[];
      return (
        hits,
        MockClient((req) async {
          hits.add(req.url.path);
          return http.Response('{"error":"这个端点不存在"}', 404);
        })
      );
    }

    test('Anthropic 渠道打的是 /messages，不是 /chat/completions', () async {
      // 曾经打的是 https://api.anthropic.com/v1/chat/completions —— 404，
      // 然后被 catch 掉返回空串。表现是「滚动摘要一次都不生效」。
      final (hits, client) = recorder();
      final llm = ConfigurableLlmClient(
        config: const LlmConfig(
          apiFormat: 'anthropic',
          baseUrl: 'https://api.anthropic.com',
          apiKey: 'sk-ant',
          model: 'claude-sonnet-4-6',
        ),
        httpClient: client,
      );
      await expectLater(
          llm.summarize('系统', '正文'), throwsA(isA<SummarizeException>()));
      expect(hits.single, contains('/messages'));
      expect(hits.single, isNot(contains('/chat/completions')));
    });

    test('Gemini 原生渠道打的是 :streamGenerateContent', () async {
      final (hits, client) = recorder();
      final llm = ConfigurableLlmClient(
        config: const LlmConfig(
          apiFormat: 'geminiNative',
          baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
          apiKey: 'AIza',
          model: 'gemini-2.5-pro',
        ),
        httpClient: client,
      );
      await expectLater(
          llm.summarize('系统', '正文'), throwsA(isA<SummarizeException>()));
      // 模型名进的是路径而不是请求体 —— 这条路径和 OpenAI 那条毫无相似之处，
      // 手写第二份请求体不可能凑巧对上。
      expect(hits.single, contains(':streamGenerateContent'));
      expect(hits.single, contains('gemini-2.5-pro'));
    });

    test('摘要用的是摘要模型，不是对话模型', () async {
      String? sentModel;
      final client = MockClient((req) async {
        sentModel = RegExp(r'"model":"([^"]+)"').firstMatch(req.body)?.group(1);
        return http.Response(
          '{"choices":[{"message":{"content":"一段摘要"}}]}',
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final llm = ConfigurableLlmClient(
        config: const LlmConfig(
          baseUrl: 'http://gw:3000/v1',
          apiKey: 'k',
          model: 'glm-5',
          summaryModel: 'glm-4-flash',
        ),
        httpClient: client,
      );
      expect(await llm.summarize('系统', '正文'), '一段摘要');
      expect(sentModel, 'glm-4-flash');
    });

    test('失败带着原因抛出来，不是一句空串', () async {
      final llm = ConfigurableLlmClient(
        config: const LlmConfig(
          baseUrl: 'http://gw:3000/v1',
          apiKey: 'k',
          model: 'glm-5',
        ),
        httpClient: MockClient(
            (_) async => http.Response('{"error":"model not found"}', 404)),
      );
      // 「404」和「密钥过期」要做的事完全不同，换成一句"摘要失败"
      // 就等于把唯一的线索丢了。
      await expectLater(
        llm.summarize('系统', '正文'),
        throwsA(predicate((Object? e) => '$e'.contains('404'))),
      );
    });
  });

  group('摘要失败时的降级', () {
    OverflowManager manager(Summarizer summarize) => OverflowManager(
          summarize: summarize,
          trigger: OverflowTrigger.messageCount,
          messageThreshold: 5,
        );

    test('失败不推进 checkpoint —— 宁可不压缩，也不能删了东西不留摘要', () async {
      final overflow =
          manager((_, __) async => throw const SummarizeException('HTTP 404'));
      final log = history(12);

      expect(await overflow.onMessageAdded(log), isFalse);
      expect(overflow.checkpoint, 0);
      // 窗口必须还是完整的。推进了 checkpoint 就是：那批消息被踢出去，
      // 而 hasSummary 为假，没有任何东西顶上。
      expect(overflow.buildWindow(log).length, log.length);
      expect(overflow.lastError, contains('404'));
    });

    test('返回空串和失败同等对待', () async {
      // 摘要模型名填错时就是这样：服务端 200，正文是空的。
      final overflow = manager((_, __) async => '   ');
      final log = history(12);

      expect(await overflow.onMessageAdded(log), isFalse);
      expect(overflow.checkpoint, 0);
      expect(overflow.buildWindow(log).length, log.length);
      expect(overflow.lastError, contains('空'));
    });

    test('失败之后要退避，不是每加一条消息都白打一次请求', () async {
      var calls = 0;
      final overflow = manager((_, __) async {
        calls++;
        throw const SummarizeException('HTTP 404');
      });
      final log = history(12);
      await overflow.onMessageAdded(log);
      expect(calls, 1);

      // 摘要失败通常是配置问题（地址、模型名、协议对不上），重试一百次
      // 也不会自己好 —— 只会又慢又花钱。
      for (var i = 0; i < 4; i++) {
        log.add(msg('user', '再说一句'));
        await overflow.onMessageAdded(log);
      }
      expect(calls, 1);

      // 攒够一个阈值之后才再试一次。
      log.add(msg('user', '再说一句'));
      await overflow.onMessageAdded(log);
      expect(calls, 2);
    });

    test('失败原因只报一次', () async {
      final overflow =
          manager((_, __) async => throw const SummarizeException('HTTP 404'));
      await overflow.onMessageAdded(history(12));
      expect(overflow.takeUnreportedError(), contains('404'));
      // 状态条上把同一句话刷十遍只会把别的状态挤掉。
      expect(overflow.takeUnreportedError(), isNull);
      // 但设置页里那一行仍然要看得见。
      expect(overflow.lastError, contains('404'));
    });

    test('成功之后错误状态清干净', () async {
      var fail = true;
      final overflow = manager((_, __) async {
        if (fail) throw const SummarizeException('HTTP 404');
        return '一段摘要';
      });
      final log = history(12);
      await overflow.onMessageAdded(log);
      expect(overflow.lastError, isNotNull);

      fail = false;
      // 退避期过了才会再试。
      log.addAll(history(5));
      expect(await overflow.onMessageAdded(log), isTrue);
      expect(overflow.lastError, isNull);
      expect(overflow.hasSummary, isTrue);
      expect(overflow.checkpoint, greaterThan(0));
    });
  });

  group('摘要状态的恢复', () {
    test('恢复之后窗口里带着摘要，不用重新摘一遍', () {
      final overflow = OverflowManager(summarize: (_, __) async => '');
      final log = history(40);
      overflow.restore(
          summary: '之前聊过的东西', checkpoint: 20, historyLength: log.length);

      expect(overflow.hasSummary, isTrue);
      expect(overflow.checkpoint, 20);
      final window = overflow.buildWindow(log);
      expect(window.first.role, 'system');
      expect(window.first.content, contains('之前聊过的东西'));
      expect(window.length, 1 + 20);
    });

    test('存下来的 checkpoint 越界时夹回去', () {
      // 编辑重发、回到某条消息、切换分支都会把历史截短，而存下来的那个
      // 下标不知道。越界的话 skip() 会安静地返回空窗口 —— 模型当场失忆。
      final overflow = OverflowManager(summarize: (_, __) async => '');
      final log = history(5);
      overflow.restore(
          summary: '摘要', checkpoint: 40, historyLength: log.length);
      expect(overflow.checkpoint, 5);
      expect(overflow.buildWindow(log), isNotEmpty);
    });

    test('空摘要恢复成「没摘过」，不是一段空白摘要', () {
      final overflow = OverflowManager(summarize: (_, __) async => '');
      overflow.restore(summary: '  ', checkpoint: 3, historyLength: 10);
      expect(overflow.hasSummary, isFalse);
    });

    test('前面补进一段历史时 checkpoint 跟着往后挪', () {
      // 打开会话只先读最后一页，剩下的在后台补进历史**开头**。checkpoint 是
      // 历史的下标 —— 不跟着挪的话，「摘要覆盖到第几条」会指到一段完全不
      // 相干的消息上：窗口里冒出一批本该被摘要盖住的原文，而真正该显示的
      // 那几条反而没了。
      final overflow = OverflowManager(summarize: (_, __) async => '');
      final log = history(10);
      overflow.restore(summary: '摘要', checkpoint: 4, historyLength: log.length);

      overflow.clampTo(30); // 历史变长了，夹不动
      overflow.shiftBy(20);
      expect(overflow.checkpoint, 24);
    });

    test('没摘过的时候不挪 —— 0 不是一个位置', () {
      final overflow = OverflowManager(summarize: (_, __) async => '');
      overflow.shiftBy(20);
      // checkpoint 为 0 表示"一条都没被摘要盖住"。把它挪到 20 就等于凭空
      // 声称前 20 条已经被摘要覆盖了，而摘要压根不存在。
      expect(overflow.checkpoint, 0);
    });

    test('历史被截短后 clampTo 把 checkpoint 拉回来', () {
      final overflow = OverflowManager(summarize: (_, __) async => '');
      overflow.restore(summary: '摘要', checkpoint: 8, historyLength: 20);
      overflow.clampTo(3);
      expect(overflow.checkpoint, 3);
    });
  });
}
