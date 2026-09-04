/// 加了密钥之后整个 ChatStore 还得照常用，而**文件里不能有明文**。
///
/// 上一组（db_cipher_test）钉的是密码学那一层；这一组钉的是"每一列都真的
/// 过了那一层"——漏掉任何一列都不会报错，只会让那一列一直裸着，
/// 而没有任何界面能看出来。
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:burrow/src/context/overflow_manager.dart';
import 'package:burrow/src/data/chat_store.dart';
import 'package:burrow/src/data/db_cipher.dart';
import 'package:burrow/src/settings/thread_lock.dart';
import 'package:burrow/src/settings/thread_prefs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

ChatMessage user(String text, {List<String> images = const <String>[]}) =>
    ChatMessage(
      role: 'user',
      content: text,
      at: DateTime.fromMillisecondsSinceEpoch(1000),
      images: images,
    );

ChatMessage reply(String text, {String? source, String reasoning = ''}) =>
    ChatMessage(
      role: 'assistant',
      content: text,
      at: DateTime.fromMillisecondsSinceEpoch(2000),
      source: source,
      reasoning: reasoning,
    );

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory tmp;
  late String path;
  final cipher = DbCipher(DbCipher.deriveKey('hunter2', 'salt'));

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('burrow_enc');
    path = '${tmp.path}/enc.db';
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  /// 文件里有没有这段话。**按字节找**。
  ///
  /// 一开始写成了 `String.fromCharCodes(bytes).contains(secret)` —— 那是错的：
  /// 中文在文件里是 UTF-8 多字节，逐字节转成 String 之后根本不可能和源码里
  /// 那个中文字符串相等。于是"文件里没有明文"这条断言对所有中文**恒成立**，
  /// 测试通过而什么都没证明。
  ///
  /// 两边都压成 latin1 就对齐了：把文件字节按 latin1 解一遍，
  /// 把要找的话先编成 UTF-8 再按 latin1 解一遍，然后比。
  Future<bool> fileContains(String secret) async {
    final haystack =
        latin1.decode(await File(path).readAsBytes(), allowInvalid: true);
    return haystack.contains(latin1.decode(utf8.encode(secret)));
  }

  test('存进去读出来一模一样', () async {
    final store = await ChatStore.openAt(path);
    store.useCipher(cipher);

    final id = await store.createThread('配 nginx 反代');
    await store.append(id, user('帮我看看负载', images: <String>['/a/b.jpg']));
    await store.append(
        id, reply('负载很低', source: 'bencom · glm-4.6', reasoning: '先看 uptime'));
    await store.setSystemPrompt(id, '一个话很少的运维助手');
    await store.setMemory(id, '聊过 nginx 和负载', 2);
    await store.saveVariant(
      threadId: id,
      branchId: 'b1',
      tail: <ChatMessage>[user('帮我看看负载'), reply('另一个答法')],
    );

    final messages = await store.messages(id);
    expect(messages[0].content, '帮我看看负载');
    expect(messages[0].images, <String>['/a/b.jpg']);
    expect(messages[1].content, '负载很低');
    expect(messages[1].source, 'bencom · glm-4.6');
    expect(messages[1].reasoning, '先看 uptime');
    expect(await store.systemPromptOf(id), '一个话很少的运维助手');
    expect((await store.memoryOf(id))!.summary, '聊过 nginx 和负载');
    expect((await store.threads()).single.title, '配 nginx 反代');
    expect((await store.loadVariant('b1', 0))!.last.content, '另一个答法');

    await store.close();
  });

  test('文件里翻不到任何一句正文', () async {
    final store = await ChatStore.openAt(path);
    store.useCipher(cipher);

    final id = await store.createThread('一个不该被看到的标题');
    await store.append(id, user('密码是 Qwe23@@##'));
    await store.append(id, reply('好的', reasoning: '用户给了凭据'));
    await store.setSystemPrompt(id, '扮演一个私人助理');
    await store.setMemory(id, '聊过一些私事', 1);
    await store.saveVariant(
      threadId: id,
      branchId: 'b1',
      tail: <ChatMessage>[user('密码是 Qwe23@@##')],
    );
    await store.setLock(
      id,
      const ThreadLock(
        salt: 'x',
        hash: 'y',
        challenges: <LockChallenge>[
          LockChallenge.custom(prompt: '那台机器叫什么', answer: 'rack-01'),
        ],
      ),
    );
    await store.setPrefs(
      id,
      const ThreadPrefs(channelId: 'ch-私人小号', model: 'moonshot-v9'),
    );
    await store.close();

    // 每一条都对应一列。漏掉哪一列，哪一列就一直裸着 ——
    // 而没有任何界面能看出来。
    for (final secret in <String>[
      '一个不该被看到的标题', // threads.title / preview
      '密码是 Qwe23@@##', // messages.content + segments.messages_json
      '用户给了凭据', // messages.reasoning
      '扮演一个私人助理', // threads.system_prompt
      '聊过一些私事', // threads.summary
      'rack-01', // threads.lock_json 里的自定义答案
      'ch-私人小号', // threads.model_prefs 里的渠道
    ]) {
      expect(await fileContains(secret), isFalse, reason: '「$secret」还是明文');
    }
  });

  test('搜索照常能搜到 —— LIKE 换成解开再筛', () async {
    final store = await ChatStore.openAt(path);
    store.useCipher(cipher);
    final id = await store.createThread('甲');
    await store.append(id, user('帮我配一下 nginx 反向代理'));
    await store.append(id, reply('好的'));

    // 密文上跑 LIKE '%nginx%' 永远命中不了，所以这条路改成了取出来解开再筛。
    final hits = await store.searchMessages('nginx');
    expect(hits, hasLength(1));
    expect(hits.single.message, contains('nginx'));
    expect(hits.single.threadTitle, '甲');

    expect(await store.searchMessages('这句话没说过'), isEmpty);
    await store.close();
  });

  test('密码不对时读不出内容，但 app 打得开', () async {
    final store = await ChatStore.openAt(path);
    store.useCipher(cipher);
    final id = await store.createThread('甲');
    await store.append(id, user('机密'));
    await store.close();

    final wrong = await ChatStore.openAt(path);
    wrong.useCipher(DbCipher(DbCipher.deriveKey('nope', 'salt')));
    // 一条读不出来的消息不该让整个会话打不开 —— 内容为空，但查询本身正常。
    final messages = await wrong.messages(id);
    expect(messages.single.content, isEmpty);
    await wrong.close();
  });

  group('就地迁移', () {
    test('把明文库搬成密文，内容一个不少', () async {
      // 先造一个没加密的库 —— 那就是用户现在机器上的样子。
      final plain = await ChatStore.openAt(path);
      final id = await plain.createThread('老会话');
      await plain.append(id, user('这是加密之前就存在的一句话'));
      await plain.setSystemPrompt(id, '老的人格设定');
      await plain.setPrefs(id, const ThreadPrefs(channelId: 'ch-老渠道'));
      await plain.close();

      // 先确认这条断言本身是有效的：加密前文件里确实找得到这句话。
      expect(await fileContains('这是加密之前就存在的一句话'), isTrue);

      final store = await ChatStore.openAt(path);
      store.useCipher(cipher);
      final changed = await store.encryptExisting();
      expect(changed, greaterThan(0));

      // 内容还在。
      expect((await store.messages(id)).single.content, '这是加密之前就存在的一句话');
      expect(await store.systemPromptOf(id), '老的人格设定');
      expect((await store.prefsOf(id)).channelId, 'ch-老渠道');
      await store.close();

      expect(await fileContains('这是加密之前就存在的一句话'), isFalse);
      expect(await fileContains('老的人格设定'), isFalse);
      expect(await fileContains('ch-老渠道'), isFalse);
    });

    test('再跑一次不会把密文又加密一遍', () async {
      final plain = await ChatStore.openAt(path);
      final id = await plain.createThread('老会话');
      await plain.append(id, user('原话'));
      await plain.close();

      final store = await ChatStore.openAt(path);
      store.useCipher(cipher);
      await store.encryptExisting();
      // 第二遍该是空跑。双层加密读出来是一段 base64，而且**不可逆地**错下去。
      expect(await store.encryptExisting(), 0);
      expect((await store.messages(id)).single.content, '原话');
      await store.close();
    });

    test('搬到一半断电：明文和密文并存时照样读得出来', () async {
      final plain = await ChatStore.openAt(path);
      final id = await plain.createThread('甲');
      await plain.append(id, user('第一句'));
      await plain.append(id, user('第二句'));
      await plain.close();

      // 手动只加密其中一条，模拟迁移搬到一半。
      final half = await ChatStore.openAt(path);
      final rows = await half.raw.query('messages', columns: <String>['id']);
      await half.raw.update(
        'messages',
        <String, Object?>{'content': cipher.seal('第一句')},
        where: 'id = ?',
        whereArgs: <Object?>[rows.first['id']],
      );
      half.useCipher(cipher);

      final messages = await half.messages(id);
      // 明文那条原样放行 —— 当成坏掉的密文扔掉的话，用户看到的是"消息没了"。
      expect(messages.map((m) => m.content), <String>['第一句', '第二句']);

      // 接着搬完。
      await half.encryptExisting();
      expect((await half.messages(id)).map((m) => m.content),
          <String>['第一句', '第二句']);
      await half.close();
    });
  });
}
