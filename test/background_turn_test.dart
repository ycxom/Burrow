/// 「用着用着就退回新对话」和「切走一下回答就没了」这两件事。
///
/// 两件事底下是同一句话：**这一轮生成活在哪儿。** 以前它活在一个会被随手
/// 拆掉的 widget 里，而那个 widget 上面还压着一个会被系统随手回收的进程。
@TestOn('vm')
library;

import 'package:burrow/src/data/chat_store.dart';
import 'package:burrow/src/net/battery_policy.dart';
import 'package:burrow/src/net/process_guard.dart';
import 'package:burrow/src/settings/settings_store.dart';
import 'package:burrow/src/settings/thread_lock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('记住上次待在哪间屋子', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    test('没记过的时候是 null —— 从新对话开始', () async {
      final store = await SettingsStore.load();
      expect(store.lastThreadId, isNull);
    });

    test('存了就读得回来', () async {
      // 这一条就是"用着用着自己退出去了"的全部修复：进程被系统收掉之后，
      // 靠它把用户送回原来那间屋子。
      final store = await SettingsStore.load();
      await store.setLastThreadId('t-42');
      expect(store.lastThreadId, 't-42');

      // 重新 load 一次 = 重启一次 app。
      final again = await SettingsStore.load();
      expect(again.lastThreadId, 't-42');
    });

    test('回到新对话时清掉', () async {
      final store = await SettingsStore.load();
      await store.setLastThreadId('t-42');
      await store.setLastThreadId(null);
      expect(store.lastThreadId, isNull);
      expect((await SettingsStore.load()).lastThreadId, isNull);
    });

    test('记的会话被删了 —— 恢复要能发现', () async {
      // 恢复那一步靠 threads() 里找不到来判断。找不到还硬开的话，
      // 用户会进到一间空屋子里，而抽屉里根本没有这一条。
      final chats = await ChatStore.openAt(inMemoryDatabasePath);
      final id = await chats.createThread('甲', preferredId: 't1');
      await chats.deleteThread(id);
      final alive = (await chats.threads()).where((t) => t.id == id);
      expect(alive, isEmpty);
      await chats.close();
    });

    test('上锁的会话不该被恢复', () async {
      // 那道锁是在抽屉里过的。直接把它摆到屏幕上等于绕过去了。
      final chats = await ChatStore.openAt(inMemoryDatabasePath);
      final id = await chats.createThread('私密', preferredId: 't1');
      await chats.setLock(
        id,
        const ThreadLock(
          salt: 'x',
          hash: 'y',
          challenges: <LockChallenge>[],
        ),
      );
      expect(await chats.lockedThreadIds(), contains(id));
      await chats.close();
    });
  });

  group('后台运行的放行提示', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    test('默认没说过', () async {
      expect((await SettingsStore.load()).batteryHintShown, isFalse);
    });

    test('说过一次就记住 —— 重启也不再问', () async {
      // 它问的是"要不要让这个 app 一直在后台耗电"，反复问只会把人逼到
      // 把整个 app 的权限一起关掉。
      final store = await SettingsStore.load();
      await store.markBatteryHintShown();
      expect(store.batteryHintShown, isTrue);
      expect((await SettingsStore.load()).batteryHintShown, isTrue);
    });
  });

  group('电池优化白名单', () {
    test('查不出来时当成"不受限"', () async {
      // 宿主没实现这个通道（桌面端、测试）时本来就没有这回事。
      // 答 false 会让设置页挂一条永远消不掉的警告。
      expect(await BatteryPolicy.isIgnored(), isTrue);
    });

    test('非 Android 上 request 直接答 false，不抛', () async {
      // 生成不该因为这件事失败。
      expect(await BatteryPolicy.request(), isFalse);
    });
  });

  group('生成期间把进程钉住', () {
    setUp(ProcessGuard.resetForTest);

    test('第一间开始、最后一间结束', () async {
      // 用引用计数而不是一个布尔：好几间屋子可能同时在生成（切走的那间
      // 会留在后台继续跑）。用布尔的话，先结束的那间会把还在跑的那几间的
      // 保护一起撤掉 —— 而撤掉的表现是"偶尔切出去回来就没了"。
      await ProcessGuard.acquire();
      expect(ProcessGuard.holders, 1);
      await ProcessGuard.acquire();
      expect(ProcessGuard.holders, 2);
      await ProcessGuard.release();
      expect(ProcessGuard.holders, 1);
      await ProcessGuard.release();
      expect(ProcessGuard.holders, 0);
    });

    test('多还几次不会数成负的', () async {
      // 数成负数之后，下一次 acquire 从 -1 加到 0，服务永远起不来。
      await ProcessGuard.release();
      await ProcessGuard.release();
      expect(ProcessGuard.holders, 0);
      await ProcessGuard.acquire();
      expect(ProcessGuard.holders, 1);
    });

    test('宿主没实现这个通道时安静地过去', () async {
      // 测试环境和桌面端都没有那个前台服务。生成不该因为它失败 ——
      // 起不来的后果只是"退到后台可能被杀"。
      await expectLater(ProcessGuard.acquire(text: '甲'), completes);
      await expectLater(ProcessGuard.release(), completes);
    });
  });
}
