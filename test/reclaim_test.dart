/// 删掉一个会话之后，磁盘和库里到底还剩什么。
///
/// 这一组钉的东西**在任何界面上都看不见**：删完会话，图片还躺在会话目录里、
/// 没人引用的分支内容还占着库、而库文件的物理大小一点没缩。用户能看到的只有
/// 系统设置里那个越来越大的占用数字，和一句"我明明删干净了"。
@TestOn('vm')
library;

import 'dart:io';

import 'package:burrow/src/data/chat_store.dart';
import 'package:burrow/src/data/task_runtime.dart';
import 'package:burrow/src/context/overflow_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

ChatMessage user(String text) =>
    ChatMessage(role: 'user', content: text, at: DateTime(2026));

ChatMessage reply(String text) =>
    ChatMessage(role: 'assistant', content: text, at: DateTime(2026));

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('会话附件的回收', () {
    late Directory tmp;
    late Directory tasks;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('burrow_reclaim');
      tasks = Directory('${tmp.path}/tasks');
      await tasks.create(recursive: true);
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    /// 造一个会话目录：workspace + 检查点元数据 + 图片 + 归档输出。
    Future<void> seed(String id) async {
      for (final rel in const <String>[
        'workspace/main.py',
        'meta/snapshots.json',
        'images/a.jpg',
        'images/b.jpg',
        'outputs/tool-1.txt',
      ]) {
        final file = File('${tasks.path}/$id/$rel');
        await file.parent.create(recursive: true);
        await file.writeAsString('x' * 1024);
      }
    }

    test('图片和归档输出删掉，workspace 和检查点留着', () async {
      await seed('t1');

      final freed = await reclaimThreadAttachments(tasks, 't1');

      // 三个文件各 1KB。
      expect(freed, 3 * 1024);
      expect(await Directory('${tasks.path}/t1/images').exists(), isFalse);
      expect(await Directory('${tasks.path}/t1/outputs').exists(), isFalse);
      // 删除对话框明确承诺了这两样不受影响，而那个承诺是对的：workspace 是
      // 任务的产物，用户可能还要用里面的文件。
      expect(await File('${tasks.path}/t1/workspace/main.py').exists(), isTrue);
      expect(
          await File('${tasks.path}/t1/meta/snapshots.json').exists(), isTrue);
    });

    test('只动指定的那个会话', () async {
      await seed('t1');
      await seed('t2');

      await reclaimThreadAttachments(tasks, 't1');

      expect(await File('${tasks.path}/t2/images/a.jpg').exists(), isTrue);
    });

    test('目录不存在时安静地返回 0，不抛', () async {
      // 删会话是用户已经确认过的动作，不该因为某个目录不在就整个失败 ——
      // 那会让人以为会话没删掉。
      expect(await reclaimThreadAttachments(tasks, 'never-existed'), 0);
    });

    test('id 里有不安全字符时什么都不删', () async {
      await seed('t1');
      // 拼路径的地方收到 `../` 就是在删别人的东西。
      expect(await reclaimThreadAttachments(tasks, '../t1'), 0);
      expect(await File('${tasks.path}/t1/images/a.jpg').exists(), isTrue);
    });
  });

  group('聊天库的整理', () {
    late Directory tmp;
    late ChatStore store;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('burrow_compact');
      store = await ChatStore.openAt('${tmp.path}/chat.db');
    });

    tearDown(() async {
      await store.close();
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    Future<int> segments() async {
      final r = await store.raw.rawQuery('SELECT COUNT(*) AS n FROM segments');
      return r.first['n']! as int;
    }

    test('引用计数漂了也能收干净 —— 按 branches 重算，不信旧值', () async {
      final id = await store.createThread('甲');
      await store.saveVariant(
        threadId: id,
        branchId: 'b1',
        tail: <ChatMessage>[user('甲'), reply('乙')],
      );
      expect(await segments(), 1);

      // 模拟计数漂掉：把 branches 那行直接删了，段却留着一个正数的计数。
      // 平时的引用计数回收对这种情况**永远无能为力** —— 而它在任何一个
      // 界面上都看不见。
      await store.raw.delete('branches');
      expect(await segments(), 1);

      final result = await store.compact();
      expect(result.segments, 1);
      expect(await segments(), 0);
    });

    test('还有人引用的段不会被收走', () async {
      final id = await store.createThread('甲');
      await store.saveVariant(
        threadId: id,
        branchId: 'b1',
        tail: <ChatMessage>[user('甲'), reply('乙')],
      );

      final result = await store.compact();
      expect(result.segments, 0);
      expect(await segments(), 1);
    });

    test('删掉大量消息之后，库文件真的缩回去', () async {
      final id = await store.createThread('甲');
      for (var i = 0; i < 300; i++) {
        await store.append(id, user('这是一条挺长的消息 ${'内容' * 200} #$i'));
      }
      final file = File(store.raw.path);
      final grown = await file.length();

      await store.deleteThread(id);
      // SQLite 删行只是把页标成空闲，文件物理大小不变 —— 用户在系统设置里
      // 看到的占用一点没少，那看起来就像"删了个寂寞"。
      expect(await file.length(), grown);

      final result = await store.compact();
      expect(result.bytes, greaterThan(0));
      expect(await file.length(), lessThan(grown));
    });

    test('没什么可收的时候两个数都是 0', () async {
      final result = await store.compact();
      expect(result.segments, 0);
    });
  });

  group('没人要的图片', () {
    late Directory tmp;
    late Directory tasks;
    late ChatStore store;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('burrow_orphan');
      tasks = Directory('${tmp.path}/tasks');
      await tasks.create(recursive: true);
      store = await ChatStore.openAt('${tmp.path}/chat.db');
    });

    tearDown(() async {
      await store.close();
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    /// 造一张"图"。名字按内容哈希来 —— 和 ImageAttachmentStore 一样。
    Future<String> image(String threadId, String content) async {
      final file = File('${tasks.path}/$threadId/images/$content.jpg');
      await file.parent.create(recursive: true);
      await file.writeAsString(content * 512);
      return file.path;
    }

    ChatMessage withImages(String text, List<String> paths) => ChatMessage(
          role: 'user',
          content: text,
          at: DateTime(2026),
          images: paths,
        );

    test('消息还在的图留着，被编辑掉的图删掉', () async {
      final id = await store.createThread('甲');
      final kept = await image(id, 'kept');
      final orphan = await image(id, 'orphan');
      await store.append(id, withImages('还在的那条', <String>[kept]));

      final freed = await reclaimOrphanImages(
        tasks,
        await store.referencedImagePaths(),
      );

      expect(freed, greaterThan(0));
      expect(await File(kept).exists(), isTrue);
      expect(await File(orphan).exists(), isFalse);
    });

    test('只被旧分支版本引用的图**不能**删', () async {
      // 这条是整组里最要紧的一个。只看 messages 的话，「重新生成」之后
      // 切回上一版，那一版的图已经被当成孤儿删了 —— 用户看到的是一条
      // 提到图却没有图的消息，而且不可恢复。
      final id = await store.createThread('甲');
      final inVariant = await image(id, 'variant');
      await store.append(id, withImages('当前这版没有图', const <String>[]));
      await store.saveVariant(
        threadId: id,
        branchId: 'b1',
        tail: <ChatMessage>[
          withImages('上一版带着图', <String>[inVariant])
        ],
      );

      await reclaimOrphanImages(tasks, await store.referencedImagePaths());

      expect(await File(inVariant).exists(), isTrue);
    });

    test('scope 只扫指定的会话', () async {
      final a = await store.createThread('甲');
      final b = await store.createThread('乙');
      final inA = await image(a, 'a-orphan');
      final inB = await image(b, 'b-orphan');

      // 一次编辑重发只会在一个会话里留下孤儿，没必要走一遍全部会话的磁盘。
      await reclaimOrphanImages(
        tasks,
        await store.referencedImagePaths(),
        scope: <String>[a],
      );

      expect(await File(inA).exists(), isFalse);
      expect(await File(inB).exists(), isTrue);
    });

    test('引用集合是全库算的 —— 别的会话还在用就不能删', () async {
      final a = await store.createThread('甲');
      final b = await store.createThread('乙');
      final shared = await image(a, 'shared');
      // 图在 A 的目录下，引用它的消息却在 B 里（内容相同的分支段会被两个
      // 会话共用，那时候就是这个形状）。按会话算引用的话，扫 A 会把它删掉。
      await store.append(b, withImages('乙引用着甲目录下那张', <String>[shared]));

      await reclaimOrphanImages(
        tasks,
        await store.referencedImagePaths(),
        scope: <String>[a],
      );

      expect(await File(shared).exists(), isTrue);
    });

    test('images 那一列坏掉时宁可多留，绝不多删', () async {
      final id = await store.createThread('甲');
      final path = await image(id, 'x');
      await store.append(id, withImages('一条', <String>[path]));
      // 把那一列改成解析不了的东西。
      await store.raw
          .update('messages', <String, Object?>{'images': '不是 JSON'});

      await reclaimOrphanImages(tasks, await store.referencedImagePaths());

      // 多留一张图是几百 KB，多删一张是用户翻回三个月前看到一个裂图。
      // 两个方向的代价完全不对等，所以拿不准时一律当成"还有人要"。
      expect(await File(path).exists(), isTrue);
    });

    test('没有 images 目录时安静地返回 0', () async {
      expect(
        await reclaimOrphanImages(
            tasks, (paths: const <String>{}, complete: true)),
        0,
      );
    });
  });
}
