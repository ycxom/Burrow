/// 防止截屏。
///
/// 这一组钉的重点是**"没设上"要如实说出来**。一道防护最危险的时刻，是用户
/// 以为它比实际更强的时候 —— 那会改变他往这个会话里放什么。
@TestOn('vm')
library;

import 'package:burrow/src/llm/thinking_effort.dart';
import 'package:burrow/src/net/screen_guard.dart';
import 'package:burrow/src/settings/thread_prefs.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('窗口开关', () {
    setUp(ScreenGuard.resetForTest);

    test('宿主没实现这个通道时如实答 false', () async {
      // 桌面端和测试环境都没有 FLAG_SECURE。谎报成功的话，界面会告诉用户
      // "已保护"，而屏幕其实是敞着的。
      expect(await ScreenGuard.setSecure(true), isFalse);
      expect(ScreenGuard.isOn, isFalse);
    });

    test('设不上就不改本地状态 —— 下次还会再试一遍', () async {
      await ScreenGuard.setSecure(true);
      // 记成"已开"的话，真正进到一个该保护的会话时会被当成"已经是这个值"
      // 而跳过，于是永远不再尝试。
      expect(ScreenGuard.isOn, isFalse);
    });

    test('不支持的平台上一律答 false，开关都不例外', () async {
      // 桌面端根本没有这个窗口标志。答 true 会让"已保护"这句话出现在一个
      // 完全没有保护的地方。
      expect(await ScreenGuard.setSecure(false), isFalse);
      expect(await ScreenGuard.setSecure(true), isFalse);
      expect(ScreenGuard.isOn, isFalse);
    });

    test('同一个值再设一次也要真的打过去，不能短路', () async {
      // native 那边会在 onCreate 里按上次的状态先把窗口遮上（冷启动不漏帧），
      // 所以 Dart 刚起来时本地记的是 false 而窗口可能是遮着的。
      // 短路的话第一次 setSecure(false) 直接返回，窗口就再也撤不掉了。
      ScreenGuard.debugForceSupported = true;
      final sent = <bool>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('com.burrow/system'),
        (call) async {
          if (call.method == 'setSecure') {
            sent.add((call.arguments as Map)['on'] as bool);
          }
          return true;
        },
      );
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
                const MethodChannel('com.burrow/system'), null);
      });

      // 本地记的还是 false，再设一次 false 也必须打过去。
      expect(await ScreenGuard.setSecure(false), isTrue);
      expect(await ScreenGuard.setSecure(true), isTrue);
      expect(await ScreenGuard.setSecure(true), isTrue);
      expect(sent, <bool>[false, true, true]);
      expect(ScreenGuard.isOn, isTrue);
    });

    test('平台说没设上时不改本地记录', () async {
      ScreenGuard.debugForceSupported = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('com.burrow/system'),
        (call) async => false,
      );
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
                const MethodChannel('com.burrow/system'), null);
      });
      expect(await ScreenGuard.setSecure(true), isFalse);
      expect(ScreenGuard.isOn, isFalse);
    });
  });

  group('这个会话要不要防截屏', () {
    // 规则本身在 app.dart 的 `_secureScreen`：设过就听设过的，没设过时
    // 跟着"这个会话上了锁没有"。这里钉的是它依赖的那个字段的行为。

    test('没设过时是 null，不是 false', () {
      // 分得出来才能做到"上了锁的会话默认开"。存成 false 的话，
      // 一个从没碰过这一项的加密会话会被当成"用户明确关掉了"。
      expect(const ThreadPrefs().secureScreen, isNull);
    });

    test('设过的存得住，两个值都存得住', () {
      for (final want in <bool>[true, false]) {
        final prefs = ThreadPrefs(secureScreen: want);
        expect(ThreadPrefs.fromJson(prefs.toJson()).secureScreen, want);
      }
    });

    test('没设过的不写进 JSON', () {
      expect(const ThreadPrefs(model: 'm').toJson().containsKey('secureScreen'),
          isFalse);
    });

    test('只设了这一项也不算空 —— 空了就会被写成 NULL', () {
      // isEmpty 决定这一行落不落库。漏算的话，用户开完防截屏退出去，
      // 再进来又敞着了，而且没有任何报错。
      expect(const ThreadPrefs(secureScreen: true).isEmpty, isFalse);
      expect(const ThreadPrefs(secureScreen: false).isEmpty, isFalse);
    });

    test('坏掉的值当成没设过', () {
      // 落到 false 的话，一个坏字段会把"上了锁默认防截屏"那条规则
      // 悄悄关掉 —— 而用户以为自己还被保护着。
      final prefs =
          ThreadPrefs.fromJson(<String, Object?>{'secureScreen': '要'});
      expect(prefs.secureScreen, isNull);
    });

    test('和别的会话设置互不干扰', () {
      const prefs = ThreadPrefs(
        model: 'gpt-5',
        thinkingEffort: ThinkingEffort.high,
        secureScreen: true,
      );
      final back = ThreadPrefs.fromJson(prefs.toJson());
      expect(back, prefs);
      expect(back.copyWith(model: 'other').secureScreen, isTrue);
    });
  });
}
