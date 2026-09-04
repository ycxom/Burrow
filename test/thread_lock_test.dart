/// 会话锁：密码派生、从会话里取答案的安全问题、以及这次运行的开锁状态。
///
/// 这一组里每一条错了都不会报错，只会让一道**本该挡住别人的门**变成摆设，
/// 或者把主人自己关在外面。两种都要钉死。
@TestOn('vm')
library;

import 'dart:math';

import 'package:burrow/src/settings/thread_lock.dart';
import 'package:flutter_test/flutter_test.dart';

ThreadLock lockWith(String password, List<LockChallenge> challenges) {
  const salt = 'fixedsaltforthetest';
  return ThreadLock(
    salt: salt,
    hash: derivePasscode(password, salt),
    challenges: challenges,
  );
}

const facts = ThreadFacts(
  model: 'glm-4.6',
  title: '配 nginx 反代',
  persona: '一个话很少的运维助手',
  opening: '帮我看看这台机器的负载',
  spoken: <String>[
    '帮我看看这台机器的负载',
    '负载 0.01，几乎空闲',
    '再帮我配一下 nginx 反向代理',
  ],
);

void main() {
  group('密码', () {
    test('对的开得了，错的开不了', () {
      final lock = lockWith('hunter2', const <LockChallenge>[]);
      expect(checkPasscode(lock, 'hunter2'), isTrue);
      expect(checkPasscode(lock, 'hunter3'), isFalse);
      expect(checkPasscode(lock, ''), isFalse);
      // 密码不做归一化 —— 那是安全问题才有的宽松。
      expect(checkPasscode(lock, 'Hunter2'), isFalse);
      expect(checkPasscode(lock, ' hunter2'), isFalse);
    });

    test('密码本身不落在锁里', () {
      final lock = lockWith('hunter2', const <LockChallenge>[]);
      expect(lock.toJson().toString(), isNot(contains('hunter2')));
    });

    test('盐不一样，同一个密码派生出来也不一样', () {
      expect(derivePasscode('same', 'salt-a'),
          isNot(derivePasscode('same', 'salt-b')));
    });

    test('每次生成的盐都不一样', () {
      expect(<String>{for (var i = 0; i < 50; i++) newSalt()}, hasLength(50));
    });
  });

  group('题目的存法', () {
    test('内置题只存"选了哪道"，答案不落盘', () {
      final lock = lockWith('pw', <LockChallenge>[
        const LockChallenge.builtIn(LockQuestion.persona),
      ]);
      // 答案现从会话里取。存一份的话既多一个泄露面，又会和被删过的消息对不上。
      final json = lock.toJson().toString();
      expect(json, isNot(contains('运维助手')));
      expect(json, contains('persona'));
    });

    test('自定义题的题面和答案都要存', () {
      final lock = lockWith('pw', <LockChallenge>[
        const LockChallenge.custom(prompt: '那台机器叫什么', answer: 'rack-01'),
      ]);
      final back = ThreadLock.fromJson(lock.toJson())!;
      expect(back.challenges.single.prompt, '那台机器叫什么');
      expect(back.challenges.single.answer, 'rack-01');
      expect(back.challenges.single.isCustom, isTrue);
    });

    test('json 往返之后还开得了', () {
      final lock = lockWith('pw', <LockChallenge>[
        const LockChallenge.builtIn(LockQuestion.model),
      ]);
      final back = ThreadLock.fromJson(lock.toJson())!;
      expect(checkPasscode(back, 'pw'), isTrue);
      expect(back.challenges.single.question, LockQuestion.model);
    });

    test('坏掉的 json 读出来是 null，不是一把打不开的锁', () {
      // 当成"锁着但打不开"会把用户自己的对话变成谁也进不去的黑洞。
      expect(ThreadLock.fromJson('不是对象'), isNull);
      expect(ThreadLock.fromJson(<String, Object?>{'salt': 's'}), isNull);
    });
  });

  group('哪些题答得上', () {
    test('只提供有标准答案的题', () {
      expect(facts.available, containsAll(LockQuestion.values));

      const noPersona = ThreadFacts(model: 'glm-4.6', title: '甲');
      // 没设过人格就不该出现这道题 —— 一道"标准答案是空"的题，
      // 任何人留空都能过。
      expect(noPersona.available, isNot(contains(LockQuestion.persona)));
      expect(noPersona.available, isNot(contains(LockQuestion.opening)));
      expect(noPersona.available, contains(LockQuestion.model));
    });

    test('真出现了空答案的题也一律不放行', () {
      const empty = ThreadFacts();
      expect(
        challengeMatches(
            const LockChallenge.builtIn(LockQuestion.persona), empty, ''),
        isFalse,
      );
    });
  });

  group('答案怎么算对', () {
    test('从会话里取标准答案，不用用户当初填', () {
      expect(
        challengeMatches(const LockChallenge.builtIn(LockQuestion.persona),
            facts, '话很少的运维助手'),
        isTrue,
      );
      expect(
        challengeMatches(
            const LockChallenge.builtIn(LockQuestion.title), facts, 'nginx 反代'),
        isTrue,
      );
    });

    test('「聊过什么」说中任意一句就算', () {
      // 用户记得的是"我在这儿聊过 nginx"，不是第几条消息。
      const topic = LockChallenge.builtIn(LockQuestion.topic);
      expect(challengeMatches(topic, facts, 'nginx 反向代理'), isTrue);
      expect(challengeMatches(topic, facts, '看看机器负载'), isTrue);
      expect(challengeMatches(topic, facts, '聊了做菜'), isFalse);
      // 留空不算 —— 否则这道题等于没有。
      expect(challengeMatches(topic, facts, ''), isFalse);
    });

    test('标点、空格、大小写都不算数', () {
      const model = LockChallenge.builtIn(LockQuestion.model);
      expect(challengeMatches(model, facts, 'GLM 4.6'), isTrue);
      expect(challengeMatches(model, facts, 'glm-4.6。'), isTrue);
      expect(challengeMatches(model, facts, 'gpt-5'), isFalse);
    });

    test('自定义题用存下来的那个答案', () {
      const custom =
          LockChallenge.custom(prompt: '那台机器叫什么', answer: 'rack-01');
      expect(challengeMatches(custom, facts, 'RACK 01'), isTrue);
      expect(challengeMatches(custom, facts, 'rack-02'), isFalse);
    });

    test('三道必须全对', () {
      final lock = lockWith('pw', <LockChallenge>[
        const LockChallenge.builtIn(LockQuestion.model),
        const LockChallenge.builtIn(LockQuestion.topic),
        const LockChallenge.custom(prompt: '机器名', answer: 'rack-01'),
      ]);

      expect(
        challengesMatch(lock, facts, <int, String>{
          0: 'glm-4.6',
          1: 'nginx',
          2: 'rack-01',
        }),
        isTrue,
      );
      // 对两道就放行等于把门槛降到两道 —— 而选三道的理由就是要三道。
      expect(
        challengesMatch(lock, facts, <int, String>{
          0: 'glm-4.6',
          1: 'nginx',
          2: '不知道',
        }),
        isFalse,
      );
      // 少答一道也不行。
      expect(challengesMatch(lock, facts, <int, String>{0: 'glm-4.6'}), isFalse);
    });

    test('一道题都没设的锁，找回这条路走不通', () {
      final lock = lockWith('pw', const <LockChallenge>[]);
      // 空题目表如果判成"全对"，等于任何人点两下就能重设密码。
      expect(challengesMatch(lock, facts, const <int, String>{}), isFalse);
    });
  });

  group('模型那道选择题', () {
    test('正确答案一定在里面，而且只有一个', () {
      final choices = modelChoices(
        'glm-4.6',
        const <String>['gpt-5', 'claude-sonnet-4-6', 'gemini-2.5-pro'],
        random: Random(1),
      );
      expect(choices, contains('glm-4.6'));
      expect(choices.where((c) => c == 'glm-4.6'), hasLength(1));
    });

    test('干扰项不够时用内置的补满', () {
      // 选项只有两三个的话，蒙对太容易。
      final choices =
          modelChoices('glm-4.6', const <String>['gpt-5'], random: Random(2));
      expect(choices, hasLength(6));
      expect(choices.toSet(), hasLength(6), reason: '有重复选项');
    });

    test('和正确答案重名的不会混进干扰项', () {
      final choices = modelChoices(
        'glm-4.6',
        const <String>['GLM 4.6', 'glm-4.6', 'gpt-5'],
        random: Random(3),
      );
      // 两个看起来一样的选项，用户选哪个都对 —— 那道题就废了。
      expect(choices.where((c) => normalizeAnswer(c) == normalizeAnswer('glm-4.6')),
          hasLength(1));
    });

    test('顺序是打乱的，不是永远第一个', () {
      final positions = <int>{
        for (var seed = 0; seed < 12; seed++)
          modelChoices('glm-4.6', const <String>[], random: Random(seed))
              .indexOf('glm-4.6'),
      };
      expect(positions.length, greaterThan(1), reason: '正确答案总在同一个位置');
    });
  });

  group('这次运行的开锁状态', () {
    test('开过之后算开着，回后台全部锁回去', () {
      final session = ThreadUnlockSession();
      expect(session.isUnlocked('t1'), isFalse);

      session.unlock('t1');
      session.unlock('t2');
      expect(session.isUnlocked('t1'), isTrue);

      // 把手机递给别人之前，用户唯一会做的动作就是切出去或者息屏。
      session.lockAll();
      expect(session.isUnlocked('t1'), isFalse);
      expect(session.isUnlocked('t2'), isFalse);
    });

    test('单独锁回去一个不影响别的', () {
      final session = ThreadUnlockSession();
      session.unlock('t1');
      session.unlock('t2');
      session.lock('t1');
      expect(session.isUnlocked('t1'), isFalse);
      expect(session.isUnlocked('t2'), isTrue);
    });

    test('状态没变就不通知', () {
      final session = ThreadUnlockSession();
      var notified = 0;
      session.addListener(() => notified++);

      session.unlock('t1');
      expect(notified, 1);
      // 白通知会让抽屉整列重建。
      session.unlock('t1');
      expect(notified, 1);
      session.lockAll();
      expect(notified, 2);
      session.lockAll();
      expect(notified, 2);
    });
  });
}
