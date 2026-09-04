/// 每个聊天室自己的模型策略。
///
/// 这一组钉的是「改一个会话不会动到别的会话」。以前模型、思考强度、温度全是
/// 全局的：在一个会话里为了一段代码换成高思考的大模型，另外二十个会话
/// （包括那个只用来跑命令的本地小模型会话）跟着一起换，而且没有任何提示。
@TestOn('vm')
library;

import 'dart:io';

import 'package:burrow/src/data/chat_store.dart';
import 'package:burrow/src/llm/sampling.dart';
import 'package:burrow/src/llm/thinking_effort.dart';
import 'package:burrow/src/settings/thread_prefs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('ThreadPrefs 的序列化', () {
    test('设过的原样回来', () {
      const prefs = ThreadPrefs(
        channelId: 'ch-a',
        model: 'gpt-5',
        thinkingEffort: ThinkingEffort.high,
        temperature: 1.4,
      );
      expect(ThreadPrefs.fromJson(prefs.toJson()), prefs);
    });

    test('没设过的字段不写进 JSON', () {
      // 写 null 进去的话，读回来分不出"设成空"和"没设过" —— 而这两件事
      // 在这里是不同的意思（null = 跟全局）。
      const prefs = ThreadPrefs(model: 'gpt-5');
      expect(prefs.toJson().keys, <String>['model']);
      expect(ThreadPrefs.fromJson(prefs.toJson()).temperature, isNull);
    });

    test('认不出来的思考档位当成没设过，而不是落到「自动」', () {
      // 落到「自动」会把用户明确调过的高思考悄悄关掉；当成没设过，
      // 至少还跟着全局那份走。
      final prefs = ThreadPrefs.fromJson(<String, Object?>{'thinking': '???'});
      expect(prefs.thinkingEffort, isNull);
    });

    test('整个字段不是 Map 时给一份空的', () {
      expect(ThreadPrefs.fromJson('坏了').isEmpty, isTrue);
      expect(ThreadPrefs.fromJson(null).isEmpty, isTrue);
    });

    test('极客设置整块跟着走', () {
      const prefs = ThreadPrefs(
        model: 'gpt-5',
        sampling: SamplingParams(topP: 0.9, stopSequences: <String>['END']),
      );
      expect(ThreadPrefs.fromJson(prefs.toJson()), prefs);
    });

    test('一项极客设置都没有时，JSON 里连 sampling 这个键都没有', () {
      expect(const ThreadPrefs(model: 'x').toJson().containsKey('sampling'),
          isFalse);
    });

    test('只设了极客设置也不算空 —— 空了就会被写成 NULL', () {
      // isEmpty 决定这一行落不落库。漏算 sampling 的话，用户设完退出去，
      // 再进来全没了，而且没有任何报错。
      expect(
        const ThreadPrefs(sampling: SamplingParams(seed: 7)).isEmpty,
        isFalse,
      );
    });

    test('整数温度也认', () {
      // JSON 里 1.0 会被写成 1，读回来是 int。按 num 收，不然温度会丢。
      final prefs = ThreadPrefs.fromJson(<String, Object?>{'temperature': 1});
      expect(prefs.temperature, 1.0);
    });
  });

  group('落库', () {
    late ChatStore store;

    setUp(() async {
      store = await ChatStore.openAt(inMemoryDatabasePath);
    });

    tearDown(() => store.close());

    test('没设过的会话读出来是空的', () async {
      final id = await store.createThread('新对话');
      expect((await store.prefsOf(id)).isEmpty, isTrue);
    });

    test('存进去再读出来', () async {
      final id = await store.createThread('新对话');
      const prefs = ThreadPrefs(
        channelId: 'ch-b',
        model: 'claude-opus-5',
        thinkingEffort: ThinkingEffort.low,
        temperature: 0.2,
      );
      await store.setPrefs(id, prefs);
      expect(await store.prefsOf(id), prefs);
    });

    test('两个会话互不影响', () async {
      // 这一条就是整个改动的理由。
      // 明写 id：createThread 的默认 id 是微秒时间戳，两条挨着建会撞。
      final a = await store.createThread('写代码', preferredId: 'a');
      final b = await store.createThread('闲聊', preferredId: 'b');
      await store.setPrefs(
          a, const ThreadPrefs(model: 'opus', temperature: 0.1));
      await store.setPrefs(
          b, const ThreadPrefs(model: 'haiku', temperature: 1.6));
      expect((await store.prefsOf(a)).model, 'opus');
      expect((await store.prefsOf(a)).temperature, 0.1);
      expect((await store.prefsOf(b)).model, 'haiku');
      expect((await store.prefsOf(b)).temperature, 1.6);
    });

    test('清空之后那一列是 NULL，不是 {}', () async {
      // 留一个 `{}` 在库里读出来和"没设过"没区别，但会让人以为设过。
      final id = await store.createThread('新对话');
      await store.setPrefs(id, const ThreadPrefs(model: 'x'));
      await store.setPrefs(id, const ThreadPrefs());
      final rows = await store.raw.query('threads',
          columns: <String>['model_prefs'], where: 'id = ?', whereArgs: [id]);
      expect(rows.single['model_prefs'], isNull);
    });

    test('这一列坏了就退回跟全局，而不是打不开这个会话', () async {
      final id = await store.createThread('新对话');
      await store.raw.update('threads', <String, Object?>{'model_prefs': '{'},
          where: 'id = ?', whereArgs: [id]);
      expect((await store.prefsOf(id)).isEmpty, isTrue);
    });

    test('极客设置存得住', () async {
      final id = await store.createThread('新对话');
      const prefs = ThreadPrefs(
        sampling: SamplingParams(
          topP: 0.85,
          maxTokens: 2048,
          stopSequences: <String>['END'],
        ),
      );
      await store.setPrefs(id, prefs);
      expect(await store.prefsOf(id), prefs);
    });

    test('v14 的库升到 v15：老会话都是跟全局的', () async {
      // 这一条钉的是"升级路径上真的建了这一列"。没建的话每次读写都会在
      // "no such column: model_prefs" 上炸，而且是在打开会话的那一刻。
      final dir = await Directory.systemTemp.createTemp('burrow_migrate15');
      final path = '${dir.path}/old.db';
      final old = await databaseFactory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 14,
          onCreate: (db, _) async {
            await db.execute('''
              CREATE TABLE threads(
                id TEXT PRIMARY KEY, title TEXT NOT NULL, preview TEXT NOT NULL,
                updated_at INTEGER NOT NULL,
                terminal_mode INTEGER NOT NULL DEFAULT 0, system_prompt TEXT,
                summary TEXT, summary_checkpoint INTEGER,
                last_read_message_id INTEGER, lock_json TEXT)
            ''');
            await db.execute('''
              CREATE TABLE messages(
                id INTEGER PRIMARY KEY AUTOINCREMENT, thread_id TEXT NOT NULL,
                role TEXT NOT NULL, content TEXT NOT NULL,
                created_at INTEGER NOT NULL, output_ref TEXT, checkpoint INTEGER,
                source TEXT, images TEXT, tokens_in INTEGER, tokens_out INTEGER,
                tokens_cached INTEGER, tokens_estimated INTEGER,
                reasoning TEXT, reasoning_ms INTEGER, branch_id TEXT,
                tool_name TEXT, tool_title TEXT, tool_ok INTEGER,
                tool_ms INTEGER)
            ''');
            await db.insert('threads', <String, Object?>{
              'id': 't1',
              'title': '老会话',
              'preview': '老消息',
              'updated_at': 1000,
            });
          },
        ),
      );
      await old.close();

      final upgraded = await ChatStore.openAt(path);
      expect((await upgraded.prefsOf('t1')).isEmpty, isTrue);
      // 新列真的建出来了才写得进去。
      await upgraded.setPrefs('t1', const ThreadPrefs(model: 'gpt-5'));
      expect((await upgraded.prefsOf('t1')).model, 'gpt-5');

      await upgraded.close();
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('删了会话，那一行连同策略一起没了', () async {
      final id = await store.createThread('新对话');
      await store.setPrefs(id, const ThreadPrefs(model: 'x'));
      await store.deleteThread(id);
      expect((await store.prefsOf(id)).isEmpty, isTrue);
    });
  });
}
