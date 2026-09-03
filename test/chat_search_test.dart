@TestOn('vm')
library;

import 'dart:io';

import 'package:burrow/src/context/overflow_manager.dart';
import 'package:burrow/src/data/chat_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

ChatMessage message(
  String role,
  String text, {
  int timestamp = 1000,
}) =>
    ChatMessage(
      role: role,
      content: text,
      at: DateTime.fromMillisecondsSinceEpoch(timestamp),
    );

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late ChatStore store;
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('burrow_search');
    store = await ChatStore.openAt('${temp.path}/search.db');
  });

  tearDown(() async {
    await store.close();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('current search only returns hits from the requested thread', () async {
    final first = await store.createThread('First');
    final second = await store.createThread('Second');
    await store.append(first, message('user', 'flutter layout'));
    await store.append(first, message('assistant', 'Use constraints'));
    await store.append(second, message('user', 'flutter painting'));

    final hits = await store.searchMessages('flutter', threadId: first);

    expect(hits, hasLength(1));
    expect(hits.single.threadId, first);
    expect(hits.single.message, 'flutter layout');
  });

  test('global search returns newest hits across threads', () async {
    final first = await store.createThread('First');
    final second = await store.createThread('Second');
    await store.append(
      first,
      message('user', 'old needle', timestamp: 1000),
    );
    await store.append(
      second,
      message('assistant', 'new needle', timestamp: 2000),
    );

    final hits = await store.searchMessages('needle');

    expect(hits.map((hit) => hit.message), ['new needle', 'old needle']);
    expect(hits.first.threadId, second);
  });

  test('LIKE wildcards are literal and returned ids match persisted rows',
      () async {
    final thread = await store.createThread('First');
    await store.append(thread, message('user', '100% done'));
    await store.append(thread, message('assistant', '100 percent done'));

    final hits = await store.searchMessages('100%');

    expect(hits, hasLength(1));
    expect(hits.single.message, '100% done');
    expect(hits.single.messageId, isPositive);
    expect(
        (await store.messages(thread)).first.messageId, hits.single.messageId);
  });
}
