import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../agent/agent_loop.dart' show TokenUsage;
import '../context/overflow_manager.dart';
import '../settings/thread_lock.dart';
import 'db_cipher.dart';

class ChatThread {
  const ChatThread({
    required this.id,
    required this.title,
    required this.preview,
    required this.updatedAt,
    this.terminalMode = false,
    this.systemPrompt,
  });

  final String id;
  final String title;
  final String preview;
  final DateTime updatedAt;

  /// 这个会话开没开终端模式。跟着会话走而不是全局一个开关：
  /// 「帮我看看这段代码什么意思」和「把这个仓库编出来」是两种对话，
  /// 用同一个全局开关意味着每次切换都要手动拨一下。
  final bool terminalMode;

  /// 这个会话专用的系统提示词。
  ///
  /// **null 和空串不是一回事**：null = 没设过，用全局那份；
  /// 空串 = 这个会话明确不要任何自定义提示词。少了这个区分，
  /// 「把会话提示词清空」就会变成「回退到全局」，而那是另一个意思。
  final String? systemPrompt;
}

/// 一个分支点的现状：一共几个版本、正在看第几个（都从 0 数）。
class BranchState {
  const BranchState({required this.total, required this.active});

  final int total;
  final int active;

  bool get hasChoice => total > 1;
}

/// 一条消息搜索结果。
///
/// [messageId] 对应 `messages.id`，界面用它把列表滚到那条消息；
/// 标题随结果一起带出来，全局结果不需要再按 thread 反查。
class ChatMessageSearchHit {
  const ChatMessageSearchHit({
    required this.threadId,
    required this.messageId,
    required this.threadTitle,
    required this.role,
    required this.message,
    required this.createdAt,
  });

  final String threadId;
  final int messageId;
  final String threadTitle;
  final String role;
  final String message;
  final DateTime createdAt;
}

class ChatStore {
  ChatStore._(this._db);

  final Database _db;

  /// 内容列的加解密。null = 不加密（单测、以及还没设过密码的旧库）。
  ///
  /// 装内容的列全都过它一遍；时间戳、角色、id 这些元数据不动 ——
  /// 它们要参与 WHERE 和 ORDER BY，加了就没法查了。范围和理由见 db_cipher.dart。
  DbCipher? _cipher;

  /// 接上密钥。main 在开库之后、真正用它之前调一次。
  void useCipher(DbCipher? value) => _cipher = value;

  String? _seal(String? plain) => _cipher?.seal(plain) ?? plain;

  /// 读出来的值。没有密钥时原样返回 —— 那时库里本来就是明文。
  ///
  /// **不能写成 `_cipher?.open(x) ?? x`。** 那样会把"解不开"（open 返回 null）
  /// 和"没有密钥"混成一件事，于是密钥不对时界面上显示的是一串 base64 密文
  /// —— 用户看到的不是"打不开"，是消息内容变成了乱码。
  String? _open(String? sealed) {
    final cipher = _cipher;
    if (cipher == null) return sealed;
    return cipher.open(sealed);
  }

  /// 直接查表。**只给测试用** —— 回收干没干净只有直接数行数才看得见，
  /// 而上层 API 一律返回"没有了"，孤儿行恰恰是那种"查询看不见、空间一直
  /// 占着"的东西。
  @visibleForTesting
  Database get raw => _db;

  static Future<ChatStore> open() async =>
      openAt(p.join(await getDatabasesPath(), 'burrow.db'));

  /// 在指定路径开库。单测用它开一个内存库 —— 正式路径要 Android 的
  /// getDatabasesPath()，在纯 Dart 测试环境里取不到。
  static Future<ChatStore> openAt(String path) async {
    final db = await openDatabase(
      path,
      version: 14,
      onUpgrade: (db, from, to) async {
        // 加列而不是重建表 —— 用户的历史对话不该因为加了个字段就被清掉。
        if (from < 2) {
          await db.execute('ALTER TABLE threads '
              'ADD COLUMN terminal_mode INTEGER NOT NULL DEFAULT 0');
        }
        if (from < 3) {
          // 老消息没有检查点记录。它们的「回到这里」只截对话不回滚文件，
          // 并且 UI 会说明这一点 —— 假装能回滚才是危险的。
          await db
              .execute('ALTER TABLE messages ADD COLUMN checkpoint INTEGER');
        }
        if (from < 4) {
          // 老消息不知道自己是谁生成的。留空而不是补上"当前渠道"——
          // 那等于给历史消息盖一个多半是错的章，而这个字段存在的意义
          // 就是让「这条是谁答的」可信。UI 对空值不显示署名。
          await db.execute('ALTER TABLE messages ADD COLUMN source TEXT');
        }
        if (from < 5) {
          // 图片路径的 JSON 数组。老消息没有图，留空。
          await db.execute('ALTER TABLE messages ADD COLUMN images TEXT');
        }
        if (from < 6) {
          // 会话级系统提示词。NULL = 没设过，用全局那份。
          await db.execute('ALTER TABLE threads ADD COLUMN system_prompt TEXT');
        }
        if (from < 7) {
          // token 用量。老消息没有，UI 对 NULL 不显示 —— 补一个估算值会让
          // 一个"服务端口径"的数字里混进估算，而这个字段的价值就在于它是真的。
          await db.execute('ALTER TABLE messages ADD COLUMN tokens_in INTEGER');
          await db
              .execute('ALTER TABLE messages ADD COLUMN tokens_out INTEGER');
          await db
              .execute('ALTER TABLE messages ADD COLUMN tokens_cached INTEGER');
        }
        if (from < 9) {
          // 思考过程。老消息没有 —— 那时候压根没收这个字段，留空即可。
          // UI 对空值不画思考区，所以历史对话看起来和以前一模一样。
          await db.execute('ALTER TABLE messages ADD COLUMN reasoning TEXT');
          await db
              .execute('ALTER TABLE messages ADD COLUMN reasoning_ms INTEGER');
        }
        if (from < 10) {
          // 分支：一条用户消息底下可以挂多个「版本」（编辑重发 / 重新生成）。
          //
          // 老会话一个分支都没有，这三样东西建完就是空的，不影响任何现有
          // 行为 —— 没分支的会话读写路径和以前完全一样。
          await db.execute('ALTER TABLE messages ADD COLUMN branch_id TEXT');
          await db.execute(_createSegments);
          await db.execute(_createBranches);
          await db.execute(_createBranchIndex);
        }
        if (from < 11) {
          // 工具调用在聊天流里画成一张卡片，这四列是画它要的东西。
          //
          // 老会话的 tool 消息没有这些字段：卡片会退化成一行「工具结果」，
          // 点开还能看到正文 —— 比把它们继续藏起来强，藏起来的后果是
          // 助手气泡莫名其妙断成两半，中间什么都没有。
          await db.execute('ALTER TABLE messages ADD COLUMN tool_name TEXT');
          await db.execute('ALTER TABLE messages ADD COLUMN tool_title TEXT');
          await db.execute('ALTER TABLE messages ADD COLUMN tool_ok INTEGER');
          await db.execute('ALTER TABLE messages ADD COLUMN tool_ms INTEGER');
        }
        if (from < 12) {
          // 滚动摘要的状态：那份摘要文本，和它覆盖到第几条。
          //
          // 以前只活在内存里，于是重开 app 或者切走再切回会话就归零 ——
          // 长会话每次打开都要重新全量摘要一遍，而在那次摘要发生之前，
          // **整段历史会原样发出去**，恰恰是最容易撞窗口上限的那一刻。
          //
          // 老会话这两列是空的：读回来就是"还没摘过"，和以前一模一样。
          await db.execute('ALTER TABLE threads ADD COLUMN summary TEXT');
          await db.execute(
              'ALTER TABLE threads ADD COLUMN summary_checkpoint INTEGER');
        }
        if (from < 13) {
          // 上次读到哪一条。NULL = 上次就停在最新那条（或者从没记过），
          // 打开时直接到底 —— 和加这一列之前的行为一样。
          await db.execute(
              'ALTER TABLE threads ADD COLUMN last_read_message_id INTEGER');
        }
        if (from < 14) {
          // 会话锁。NULL = 没加锁，和加这一列之前完全一样。
          await db.execute('ALTER TABLE threads ADD COLUMN lock_json TEXT');
        }
        if (from < 8) {
          // 这一条是不是估算值。1 = 估算。
          //
          // 单独一档而不是并进上面那三列：v7 已经装到设备上跑过了，把四列
          // 合成一个 `from < 8` 的话，那些设备会再执行一次前三条 ALTER，
          // 然后挂在 "duplicate column name" 上 —— 而且是在 app 启动时挂。
          await db.execute(
              'ALTER TABLE messages ADD COLUMN tokens_estimated INTEGER');
        }
      },
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE threads(
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            preview TEXT NOT NULL,
            updated_at INTEGER NOT NULL,
            terminal_mode INTEGER NOT NULL DEFAULT 0,
            system_prompt TEXT,
            summary TEXT,
            summary_checkpoint INTEGER,
            last_read_message_id INTEGER,
            lock_json TEXT
          )
        ''');
        await db.execute('''
          CREATE TABLE messages(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            thread_id TEXT NOT NULL,
            role TEXT NOT NULL,
            content TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            output_ref TEXT,
            checkpoint INTEGER,
            source TEXT,
            images TEXT,
            tokens_in INTEGER,
            tokens_out INTEGER,
            tokens_cached INTEGER,
            tokens_estimated INTEGER,
            reasoning TEXT,
            reasoning_ms INTEGER,
            branch_id TEXT,
            tool_name TEXT,
            tool_title TEXT,
            tool_ok INTEGER,
            tool_ms INTEGER
          )
        ''');
        await db.execute(
          'CREATE INDEX messages_thread ON messages(thread_id, id)',
        );
        await db.execute(_createSegments);
        await db.execute(_createBranches);
        await db.execute(_createBranchIndex);
      },
    );
    return ChatStore._(db);
  }

  /// 按内容寻址的消息段仓库。
  ///
  /// 一个 segment 是「某条用户消息 + 它之后的全部消息」的一整段快照，
  /// 主键是这段内容的 sha256。**同样的内容只存一份** —— 在版本之间来回
  /// 切换时，切走的那份和之前存过的那份字节一致，算出来是同一个 hash，
  /// 直接复用，不会每切一次就多一份副本。
  ///
  /// `ref_count` 是给回收用的：会话删掉时把它引用的每个 segment 减一，
  /// 减到 0 的整行删掉。没有这一步，删掉的会话会把它所有历史版本永久
  /// 留在库里 —— 用户看不见，只是慢慢把手机存储吃掉。
  static const _createSegments = '''
    CREATE TABLE segments(
      hash TEXT PRIMARY KEY,
      messages_json TEXT NOT NULL,
      ref_count INTEGER NOT NULL DEFAULT 0
    )
  ''';

  /// 分支点上的一个版本。指向 segments 里的一段内容，自己只记账。
  ///
  /// 内容和引用分开，正是「拼接」能便宜的原因：把一段对话接到别处去，
  /// 插一行指针就行，不用把内容复制一遍。
  static const _createBranches = '''
    CREATE TABLE branches(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      thread_id TEXT NOT NULL,
      branch_id TEXT NOT NULL,
      variant_index INTEGER NOT NULL,
      is_active INTEGER NOT NULL DEFAULT 0,
      segment_hash TEXT NOT NULL,
      created_at INTEGER NOT NULL
    )
  ''';

  static const _createBranchIndex =
      'CREATE INDEX branches_lookup ON branches(thread_id, branch_id)';

  /// 关掉底层数据库连接。App 正常运行时不需要调它（库跟着进程走），
  /// 但持有资源的类该有一个显式的关闭口子。
  Future<void> close() => _db.close();

  /// 库里存着多少段独立的分支内容。
  ///
  /// 按内容寻址意味着重复的段只占一份，所以这个数会明显小于「版本总数」。
  /// 用来给存储占用做交代，也用来验证回收有没有真的把孤儿段清掉。
  Future<int> segmentCount() async {
    final rows = await _db.rawQuery('SELECT COUNT(*) AS n FROM segments');
    return rows.first['n']! as int;
  }

  Future<List<ChatThread>> threads() async {
    final rows = await _db.query('threads', orderBy: 'updated_at DESC');
    return rows
        .map((row) => ChatThread(
              id: row['id']! as String,
              title: _open(row['title'] as String?) ?? '',
              preview: _open(row['preview'] as String?) ?? '',
              updatedAt: DateTime.fromMillisecondsSinceEpoch(
                row['updated_at']! as int,
              ),
              terminalMode: (row['terminal_mode'] as int? ?? 0) != 0,
              systemPrompt: _open(row['system_prompt'] as String?),
            ))
        .toList();
  }

  /// 单个会话的终端模式。会话还没建（用户一条消息都没发）时返回 null，
  /// 调用方用它区分「这个会话关着」和「还没有这个会话」。
  Future<bool?> terminalModeOf(String threadId) async {
    final rows = await _db.query(
      'threads',
      columns: <String>['terminal_mode'],
      where: 'id = ?',
      whereArgs: <Object?>[threadId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return (rows.first['terminal_mode'] as int? ?? 0) != 0;
  }

  /// 这个会话的系统提示词。会话还没建时返回 null。
  ///
  /// 返回值分三种：会话不存在 / 没设过 / 设过（可能是空串）。前两种都是
  /// null，调用方拿不到区别 —— 但它们的处理方式一样（都用全局那份），
  /// 所以不值得为此多一层包装。
  Future<String?> systemPromptOf(String threadId) async {
    final rows = await _db.query(
      'threads',
      columns: <String>['system_prompt'],
      where: 'id = ?',
      whereArgs: <Object?>[threadId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _open(rows.first['system_prompt'] as String?);
  }

  /// 设这个会话的提示词。null = 清掉，回退到全局。
  Future<void> setSystemPrompt(String threadId, String? prompt) async {
    await _db.update(
      'threads',
      <String, Object?>{'system_prompt': _seal(prompt)},
      where: 'id = ?',
      whereArgs: <Object?>[threadId],
    );
  }

  /// 这个会话上一次的滚动摘要状态。会话不存在、或者从没摘过时返回 null。
  ///
  /// 摘要和 checkpoint 一起取一起存 —— 分开的话中间任何一次失败都会留下
  /// 「摘要是旧的、checkpoint 是新的」这种组合，而那正好是最坏的一种：
  /// 一批消息被摘要覆盖掉，顶上去的却是覆盖不到它们的旧摘要。
  Future<({String summary, int checkpoint})?> memoryOf(String threadId) async {
    final rows = await _db.query(
      'threads',
      columns: <String>['summary', 'summary_checkpoint'],
      where: 'id = ?',
      whereArgs: <Object?>[threadId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final summary = _open(rows.first['summary'] as String?);
    final checkpoint = rows.first['summary_checkpoint'] as int?;
    if (summary == null || summary.isEmpty || checkpoint == null) return null;
    return (summary: summary, checkpoint: checkpoint);
  }

  /// 存这个会话的滚动摘要状态。[summary] 为 null = 清掉。
  Future<void> setMemory(String threadId, String? summary, int checkpoint) =>
      _db.update(
        'threads',
        <String, Object?>{
          'summary': _seal(summary),
          'summary_checkpoint': summary == null ? null : checkpoint,
        },
        where: 'id = ?',
        whereArgs: <Object?>[threadId],
      );

  /// 这个会话上次读到哪一条。null = 上次就在底部，打开时直接到最新。
  ///
  /// 存的是**消息 id 而不是滚动像素**。像素在重新排版之后没有意义 ——
  /// 换个皮肤、调一次字号、换台屏幕，同一个数字指向的就是另一段对话了。
  /// 而"我上次看到这条"是个和排版无关的事实。
  Future<int?> lastReadOf(String threadId) async {
    final rows = await _db.query(
      'threads',
      columns: <String>['last_read_message_id'],
      where: 'id = ?',
      whereArgs: <Object?>[threadId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['last_read_message_id'] as int?;
  }

  /// 记下读到哪一条。[messageId] 为 null = 在底部。
  Future<void> setLastRead(String threadId, int? messageId) => _db.update(
        'threads',
        <String, Object?>{'last_read_message_id': messageId},
        where: 'id = ?',
        whereArgs: <Object?>[threadId],
      );

  /// 这个会话的锁。null = 没加锁。
  Future<ThreadLock?> lockOf(String threadId) async {
    final rows = await _db.query(
      'threads',
      columns: <String>['lock_json'],
      where: 'id = ?',
      whereArgs: <Object?>[threadId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final raw = _open(rows.first['lock_json'] as String?);
    if (raw == null || raw.isEmpty) return null;
    try {
      return ThreadLock.fromJson(jsonDecode(raw));
    } catch (_) {
      // 这一列坏了当成没锁。**故意的** —— 反过来（当成锁着但打不开）会把
      // 用户自己的对话变成一个谁也进不去的黑洞，而这道锁本来就只挡"别人
      // 拿起手机点进来"，不值得用永久锁死来兑现。
      return null;
    }
  }

  /// 哪些会话锁着。列表要用它画那把小锁，一次查完比一条条问快得多。
  Future<Set<String>> lockedThreadIds() async {
    final rows = await _db.query(
      'threads',
      columns: <String>['id'],
      where: "lock_json IS NOT NULL AND lock_json != ''",
    );
    return <String>{for (final row in rows) row['id']! as String};
  }

  /// 设 / 撤这个会话的锁。[lock] 为 null = 撤掉。
  Future<void> setLock(String threadId, ThreadLock? lock) => _db.update(
        'threads',
        <String, Object?>{
          'lock_json':
              lock == null ? null : _seal(jsonEncode(lock.toJson())),
        },
        where: 'id = ?',
        whereArgs: <Object?>[threadId],
      );

  Future<void> setTerminalMode(String threadId, bool on) async {
    await _db.update(
      'threads',
      <String, Object?>{'terminal_mode': on ? 1 : 0},
      where: 'id = ?',
      whereArgs: <Object?>[threadId],
    );
  }

  Future<String> createThread(String firstMessage,
      {String? preferredId, bool terminalMode = false}) async {
    final id =
        preferredId ?? DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final title = firstMessage.length > 28
        ? '${firstMessage.substring(0, 28)}…'
        : firstMessage;
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.insert('threads', <String, Object?>{
      'id': id,
      'title': _seal(title),
      'preview': _seal(firstMessage),
      'updated_at': now,
      'terminal_mode': terminalMode ? 1 : 0,
    });
    return id;
  }

  Future<void> renameThread(String threadId, String title) async {
    await _db.update(
      'threads',
      <String, Object?>{'title': _seal(title)},
      where: 'id = ?',
      whereArgs: <Object?>[threadId],
    );
  }

  /// 删除会话连同它的消息。
  ///
  /// 消息表没有外键级联（sqflite 默认不开 foreign_keys），所以要手动删 ——
  /// 漏掉的话消息会永久留在库里，谁也看不到，只是慢慢把手机存储吃掉。
  Future<void> deleteThread(String threadId) async {
    await _db.transaction((txn) async {
      // 分支引用的内容要跟着一起回收。只删 branches 不减 segments 的话，
      // 那些段会变成谁也引用不到的孤儿，永久占着空间。
      final refs = await txn.query('branches',
          columns: <String>['segment_hash'],
          where: 'thread_id = ?',
          whereArgs: <Object?>[threadId]);
      for (final row in refs) {
        await _releaseSegment(txn, row['segment_hash']! as String);
      }
      await txn.delete('branches',
          where: 'thread_id = ?', whereArgs: <Object?>[threadId]);
      await txn.delete('messages',
          where: 'thread_id = ?', whereArgs: <Object?>[threadId]);
      await txn
          .delete('threads', where: 'id = ?', whereArgs: <Object?>[threadId]);
    });
  }

  /// 现在**还有人要**的全部图片路径。
  ///
  /// 两个来源都要数，缺一不可：
  ///
  ///   - `messages.images` —— 活动路径上那些消息带的图。
  ///   - `segments.messages_json` —— 分支版本里的图。只看消息的话，
  ///     「重新生成」之后切回上一版，那一版的图已经被当成孤儿删掉了 ——
  ///     而用户看到的是一条提到图却没有图的消息。
  ///
  /// **一次数全库，不按会话分。** 内容相同的分支段会被两个会话共用（段是按
  /// 内容哈希存的），那时候 A 的段里可能写着 B 目录下的路径。按会话数的话，
  /// 删 A 会把 B 还在用的图删掉。
  ///
  /// 返回值带一个 [complete]：**有任何一处解析不了，它就是 false**，
  /// 意思是"这份集合不完整，别拿它去删东西"。少了这个标记，一条坏掉的
  /// images 列会让那条消息的图看起来没人引用 —— 然后被删掉。
  Future<({Set<String> paths, bool complete})> referencedImagePaths() async {
    final paths = <String>{};
    var complete = true;

    // 两处的形状不一样：messages 那一列存的是 JSON **字符串**，
    // 而段里已经是解出来的数组。收在一个函数里，免得两边各写一次判空。
    void collect(Object? raw) {
      try {
        final list = raw is String
            ? (raw.isEmpty ? const <Object?>[] : jsonDecode(raw) as List)
            : raw is List
                ? raw
                : const <Object?>[];
        for (final path in list) {
          if (path is String && path.isNotEmpty) paths.add(path);
        }
      } catch (_) {
        // 解析不了 = **不知道这条引用了什么**，而不是"它没引用任何东西"。
        // 当成后者就会把它的图删掉，而那不可恢复。
        complete = false;
      }
    }

    for (final row in await _db.query('messages',
        columns: <String>['images'], where: 'images IS NOT NULL')) {
      collect(row['images']);
    }

    // 段里存的是整段消息的 JSON，图片路径埋在每条消息的 images 字段里。
    for (final row
        in await _db.query('segments', columns: <String>['messages_json'])) {
      final raw = _open(row['messages_json'] as String?);
      if (raw == null) continue;
      try {
        for (final message in jsonDecode(raw) as List) {
          if (message is Map) collect(message['images']);
        }
      } catch (_) {
        complete = false;
      }
    }
    return (paths: paths, complete: complete);
  }

  /// 回收谁也引用不到的分支内容，并把库文件真的缩回去。
  ///
  /// 平时的回收靠引用计数（见 [_releaseSegment]），那条路是够的。这里是**兜底
  /// 加真正的空间回收**，两件平时不发生、但发生了就没人看得见的事：
  ///
  ///   1. **引用计数是重算的，不是信任已有的值。** 计数只要因为任何原因漂过
  ///      一次（改坏的代码、手动改过库、以后新增的删除路径忘了减），那些段就
  ///      永远回收不掉了 —— 而它们在任何一个界面上都看不见。直接按 branches
  ///      数一遍是唯一不会越攒越错的做法。
  ///   2. **SQLite 删行只是把页标成空闲**，文件物理大小不变。删掉一个几万条
  ///      消息的会话之后，用户在系统设置里看到的占用一点没少 —— 那看起来就
  ///      像"删了个寂寞"。VACUUM 才真的把文件缩回去。
  ///
  /// VACUUM 会锁库并整个重写一遍文件，**只能由用户手动触发**，不能挂在启动
  /// 路径或者删除动作后面。
  Future<({int segments, int bytes})> compact() async {
    final file = File(_db.path);
    final before = await file.exists() ? await file.length() : 0;

    await _db.execute(
      'UPDATE segments SET ref_count = '
      '(SELECT COUNT(*) FROM branches WHERE branches.segment_hash = '
      'segments.hash)',
    );
    final swept = await _db.delete('segments', where: 'ref_count <= 0');

    // VACUUM 不能在事务里跑。
    await _db.execute('VACUUM');

    final after = await file.exists() ? await file.length() : 0;
    return (segments: swept, bytes: before - after > 0 ? before - after : 0);
  }

  /// 引用减一，减到 0 就把内容删掉。
  static Future<void> _releaseSegment(DatabaseExecutor txn, String hash) async {
    await txn.rawUpdate(
      'UPDATE segments SET ref_count = ref_count - 1 WHERE hash = ?',
      <Object?>[hash],
    );
    await txn.delete('segments',
        where: 'hash = ? AND ref_count <= 0', whereArgs: <Object?>[hash]);
  }

  /// 图片路径列表 ⇄ JSON。
  ///
  /// 没有图时存 null 而不是 `'[]'`：绝大多数消息都没有图，几万条消息各省
  /// 两个字节是次要的，重要的是**读的时候不用先解析一次 JSON 才知道是空的**。
  static String? _encodeImages(List<String> images) =>
      images.isEmpty ? null : jsonEncode(images);

  static List<String> _decodeImages(String? raw) {
    if (raw == null || raw.isEmpty) return const <String>[];
    try {
      return <String>[
        for (final path in jsonDecode(raw) as List) path as String
      ];
    } catch (_) {
      // 这一列坏了只是丢图，不该让整个会话打不开。
      return const <String>[];
    }
  }

  /// 从**最新那条往回数**，装到 [tokenBudget] 为止的一段。
  ///
  /// 打开会话时先只要这一段：一个聊了几个月的会话有几千条消息，全量读出来
  /// 再造几千个对象、算一遍日期分组，是首屏前唯一那段纯等待。而用户打开会话
  /// 十有八九是接着最近这几句说 —— 更早的等他真往上翻再补。
  ///
  /// **切分用字符数而不是真的估 token**：估 token 要先把 content 读进内存，
  /// 那正是这里想省掉的那一步。`LENGTH()` 在 SQLite 里不用取出内容就能算。
  /// 换算系数取 [TokenCounter] 里最保守的那一档（中文 0.65 字/token），
  /// 于是这一段**只会比预算短，不会更长** —— 宁可多翻一次，也不要首屏还是卡。
  ///
  /// [before] 给了就只看比它更早的消息，用来翻上一页。
  ///
  /// 返回的消息按时间**升序**，和 [messages] 一致。
  /// [messageLimit] 是**条数**上限，和 [tokenBudget] 取先到的那个。
  ///
  /// 光有 token 预算不够用：一页要装多少，日常由"一屏放得下几条"决定，
  /// 而不是由字数决定。Telegram 系客户端首屏取 20 条就是这个道理 ——
  /// 手机上一屏也就五六条，多读的每一条都是首屏之前的纯等待。
  /// token 预算留着管另一头：一条几十 KB 的命令输出，光它自己就该成一页。
  Future<List<ChatMessage>> tailMessages(
    String threadId, {
    required int tokenBudget,
    int? messageLimit,
    int? before,
  }) async {
    const charsPerToken = 0.65;
    final budgetChars = (tokenBudget * charsPerToken).ceil();

    final sizes = await _db.rawQuery(
      'SELECT id, LENGTH(content) AS n FROM messages '
      'WHERE thread_id = ?${before == null ? '' : ' AND id < ?'} '
      'ORDER BY id DESC',
      <Object?>[threadId, if (before != null) before],
    );
    if (sizes.isEmpty) return const <ChatMessage>[];

    var used = 0;
    var taken = 0;
    // 至少给一条。预算再小也不能返回空 —— 空会被上层当成"没有更早的了"，
    // 于是那条超长消息之前的历史就再也翻不出来。
    var cutoff = sizes.first['id']! as int;
    for (final row in sizes) {
      used += (row['n'] as int? ?? 0) + 32;
      taken++;
      cutoff = row['id']! as int;
      if (used >= budgetChars) break;
      if (messageLimit != null && taken >= messageLimit) break;
    }

    return _readMessages(
      where: 'thread_id = ? AND id >= ?'
          '${before == null ? '' : ' AND id < ?'}',
      args: <Object?>[threadId, cutoff, if (before != null) before],
    );
  }

  /// 这个会话一共多少条消息。用来判断"上面还有没有"。
  Future<int> messageCountOf(String threadId) async {
    final rows = await _db.rawQuery(
      'SELECT COUNT(*) AS n FROM messages WHERE thread_id = ?',
      <Object?>[threadId],
    );
    return rows.first['n']! as int;
  }

  Future<List<ChatMessage>> messages(String threadId) =>
      _readMessages(where: 'thread_id = ?', args: <Object?>[threadId]);

  /// 行 → 消息。[tailMessages] 和 [messages] 共用 —— 这张表有二十来列，
  /// 抄第二份的话，以后加一列必然会漏掉其中一处，而漏掉的表现是
  /// 「翻上去之后那几条消息少了点东西」。
  Future<List<ChatMessage>> _readMessages({
    required String where,
    required List<Object?> args,
  }) async {
    final rows = await _db.query(
      'messages',
      where: where,
      whereArgs: args,
      orderBy: 'id ASC',
    );
    return rows
        .map((row) => ChatMessage(
              messageId: row['id']! as int,
              role: row['role']! as String,
              content: _open(row['content'] as String?) ?? '',
              at: DateTime.fromMillisecondsSinceEpoch(
                row['created_at']! as int,
              ),
              outputRef: _open(row['output_ref'] as String?),
              checkpoint: row['checkpoint'] as int?,
              source: _open(row['source'] as String?),
              images: _decodeImages(_open(row['images'] as String?)),
              usage: _decodeUsage(row),
              reasoning: _open(row['reasoning'] as String?) ?? '',
              reasoningMs: row['reasoning_ms'] as int? ?? 0,
              branchId: row['branch_id'] as String?,
              toolName: row['tool_name'] as String?,
              toolTitle: _open(row['tool_title'] as String?),
              // 老消息这一列是 NULL。默认成功 —— 给一条没记过结果的历史
              // 记录画个红叉，比不画更误导。
              toolOk: (row['tool_ok'] as int? ?? 1) == 1,
              toolMs: row['tool_ms'] as int? ?? 0,
            ))
        .toList();
  }

  /// 按关键词搜索消息。[threadId] 非空时只搜这一个会话。
  ///
  /// `LIKE` 先缩小范围，Dart 再按大小写折叠做一次精确筛选：
  /// SQLite 的 `lower()` 只覆盖 ASCII，中文虽然不受影响，但不能把
  /// 这当成所有 Unicode 输入的保证。
  Future<List<ChatMessageSearchHit>> searchMessages(
    String query, {
    String? threadId,
    int limit = 80,
  }) async {
    final keyword = query.trim();
    if (keyword.isEmpty) return const <ChatMessageSearchHit>[];

    final hits = <ChatMessageSearchHit>[];
    final threadFilter = threadId == null ? '' : 'WHERE m.thread_id = ? ';
    // **不能再用 SQL 的 LIKE 了。** 内容是密文，`LIKE '%nginx%'` 匹配的是
    // base64，永远命中不了。所以改成"取出来、解开、在 Dart 里筛"。
    //
    // 代价是要扫过这个范围里的每一行。可接受的理由：搜索是用户主动发起的
    // 偶发动作，而不是每帧都跑的东西；扫的又是本地 sqlite，几千行是毫秒级。
    // 加一个硬上限兜住极端情况 —— 一个攒了几十万条的库不该让搜索卡死。
    final rows = await _db.rawQuery(
      'SELECT m.id AS message_id, m.thread_id, m.role, m.content, '
      'm.created_at, t.title AS thread_title '
      'FROM messages m '
      'INNER JOIN threads t ON t.id = m.thread_id '
      '$threadFilter'
      'ORDER BY m.id DESC LIMIT ?',
      <Object?>[
        if (threadId != null) threadId,
        _searchScanLimit,
      ],
    );
    final needle = keyword.toLowerCase();
    for (final row in rows) {
      if (hits.length >= limit) break;
      final content = _open(row['content'] as String?);
      // 解不开的行跳过，不要当成"内容为空"塞进结果里 —— 一条空搜索结果
      // 点进去什么都没有，比不出现更让人困惑。
      if (content == null) continue;
      if (!content.toLowerCase().contains(needle)) continue;
      hits.add(ChatMessageSearchHit(
        threadId: row['thread_id']! as String,
        messageId: row['message_id']! as int,
        threadTitle: _open(row['thread_title'] as String?) ?? '',
        role: row['role']! as String,
        message: content,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          row['created_at']! as int,
        ),
      ));
    }
    return hits;
  }

  /// 清空全部对话。
  ///
  /// 只在"忘了数据库密码"那一条路上用：那些密文再也解不开了，留着只是占地方
  /// 和让人误以为还有救。**只清对话相关的四张表** —— 渠道、皮肤、设置都在
  /// prefs 里，和这把钥匙无关，不该被连坐。
  Future<void> wipeConversations() async {
    await _db.transaction((txn) async {
      for (final table in const <String>[
        'branches',
        'segments',
        'messages',
        'threads',
      ]) {
        await txn.delete(table);
      }
    });
    // 删完把空间还给文件系统。这一步之后旧密文才真的从磁盘上消失 ——
    // 光删行的话它们还躺在空闲页里。
    await _db.execute('VACUUM');
  }

  /// 一次搜索最多扫多少行。见 [searchMessages]。
  static const _searchScanLimit = 20000;

  /// 把库里还是明文的那些内容列就地加密。
  ///
  /// ## 为什么可以中途断电
  ///
  /// 一行一行走，每行**先看它是不是已经加密过**（[DbCipher.isSealed]），
  /// 是就跳过。所以断在任何一步，库里都是"一部分密文 + 一部分明文"，而
  /// [_open] 对明文原样放行 —— app 照常能读，下次启动接着搬没搬完的那些。
  ///
  /// 没有"迁移完成"这个标记，也不需要：判据是每一行自己的状态，不是一个
  /// 可能和现实对不上的开关。
  ///
  /// 返回改写了多少行。
  Future<int> encryptExisting() async {
    final cipher = _cipher;
    if (cipher == null) return 0;
    var changed = 0;

    Future<void> sweep(
      String table,
      List<String> columns,
      String idColumn,
    ) async {
      final rows = await _db.query(table, columns: <String>[idColumn, ...columns]);
      for (final row in rows) {
        final update = <String, Object?>{};
        for (final column in columns) {
          final raw = row[column];
          // 已经是密文的跳过 —— 再 seal 一次就是双层加密，读出来是一段
          // base64 而不是正文，而且**不可逆地**错下去。
          if (raw is! String || DbCipher.isSealed(raw)) continue;
          update[column] = cipher.seal(raw);
        }
        if (update.isEmpty) continue;
        await _db.update(
          table,
          update,
          where: '$idColumn = ?',
          whereArgs: <Object?>[row[idColumn]],
        );
        changed++;
      }
    }

    await sweep(
      'threads',
      <String>['title', 'preview', 'system_prompt', 'summary', 'lock_json'],
      'id',
    );
    await sweep(
      'messages',
      <String>[
        'content',
        'reasoning',
        'tool_title',
        'images',
        'source',
        'output_ref',
      ],
      'id',
    );
    await sweep('segments', <String>['messages_json'], 'hash');
    return changed;
  }

  /// 三列合成一个 [TokenUsage]。全为 NULL（老消息、或服务端没回报）时返回
  /// null —— 补一个 0 会在界面上显示成"这一轮没花 token"，那是错的。
  static TokenUsage? _decodeUsage(Map<String, Object?> row) {
    final input = row['tokens_in'] as int?;
    final output = row['tokens_out'] as int?;
    if (input == null && output == null) return null;
    return TokenUsage(
      input: input ?? 0,
      output: output ?? 0,
      cached: row['tokens_cached'] as int? ?? 0,
      estimated: (row['tokens_estimated'] as int? ?? 0) == 1,
    );
  }

  Future<void> append(String threadId, ChatMessage message) async {
    await _db.insert('messages', <String, Object?>{
      'thread_id': threadId,
      'role': message.role,
      'content': _seal(message.content),
      'created_at': message.at.millisecondsSinceEpoch,
      'output_ref': _seal(message.outputRef),
      'checkpoint': message.checkpoint,
      'source': _seal(message.source),
      'images': _seal(_encodeImages(message.images)),
      'tokens_in': message.usage?.input,
      'tokens_out': message.usage?.output,
      'tokens_cached': message.usage?.cached,
      'tokens_estimated': (message.usage?.estimated ?? false) ? 1 : 0,
      'reasoning': _seal(message.reasoning.isEmpty ? null : message.reasoning),
      'reasoning_ms': message.reasoningMs == 0 ? null : message.reasoningMs,
      'branch_id': message.branchId,
      'tool_name': message.toolName,
      'tool_title': _seal(message.toolTitle),
      'tool_ok': message.toolOk ? 1 : 0,
      'tool_ms': message.toolMs == 0 ? null : message.toolMs,
    });
    await _db.update(
      'threads',
      <String, Object?>{
        'preview': _seal(message.content),
        'updated_at': message.at.millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: <Object?>[threadId],
    );
  }

  // ---- 分支 ----------------------------------------------------------

  /// 一段消息的规范 JSON。**字段顺序固定**，否则同样的内容会算出不同的
  /// hash，去重就全废了。
  static Map<String, Object?> _messageToJson(ChatMessage m) =>
      <String, Object?>{
        'role': m.role,
        'content': m.content,
        'at': m.at.millisecondsSinceEpoch,
        'outputRef': m.outputRef,
        'checkpoint': m.checkpoint,
        'source': m.source,
        'images': m.images,
        'reasoning': m.reasoning,
        'reasoningMs': m.reasoningMs,
        'branchId': m.branchId,
        'toolName': m.toolName,
        'toolTitle': m.toolTitle,
        'toolOk': m.toolOk,
        'toolMs': m.toolMs,
        'usage': m.usage == null
            ? null
            : <String, Object?>{
                'input': m.usage!.input,
                'output': m.usage!.output,
                'cached': m.usage!.cached,
                'estimated': m.usage!.estimated,
              },
      };

  static ChatMessage _messageFromJson(Map<String, Object?> j) {
    final usage = j['usage'];
    return ChatMessage(
      role: j['role']! as String,
      content: j['content']! as String,
      at: DateTime.fromMillisecondsSinceEpoch(j['at']! as int),
      outputRef: j['outputRef'] as String?,
      checkpoint: j['checkpoint'] as int?,
      source: j['source'] as String?,
      images: <String>[
        for (final path in (j['images'] as List? ?? const <Object?>[]))
          path as String
      ],
      reasoning: j['reasoning'] as String? ?? '',
      reasoningMs: j['reasoningMs'] as int? ?? 0,
      branchId: j['branchId'] as String?,
      toolName: j['toolName'] as String?,
      toolTitle: j['toolTitle'] as String?,
      toolOk: j['toolOk'] as bool? ?? true,
      toolMs: j['toolMs'] as int? ?? 0,
      usage: usage is Map<String, Object?>
          ? TokenUsage(
              input: usage['input'] as int? ?? 0,
              output: usage['output'] as int? ?? 0,
              cached: usage['cached'] as int? ?? 0,
              estimated: usage['estimated'] as bool? ?? false,
            )
          : null,
    );
  }

  static String _encodeSegment(List<ChatMessage> tail) =>
      jsonEncode(<Object?>[for (final m in tail) _messageToJson(m)]);

  static List<ChatMessage> _decodeSegment(String raw) => <ChatMessage>[
        for (final j in jsonDecode(raw) as List)
          _messageFromJson(j as Map<String, Object?>)
      ];

  /// 把 [tail]（分支锚点那条用户消息开始、一直到这个版本结尾）存成该分支点
  /// 的一个版本，返回它的序号。
  ///
  /// **同样的内容不会存第二遍。** 这个分支点下已经有一模一样的一段时，直接
  /// 复用那一份的序号 —— 在几个版本之间来回切换不会让库一直长大。
  Future<int> saveVariant({
    required String threadId,
    required String branchId,
    required List<ChatMessage> tail,
    bool active = true,
  }) async {
    final json = _encodeSegment(tail);
    final hash = sha256.convert(utf8.encode(json)).toString();
    return _db.transaction((txn) async {
      final existing = await txn.query(
        'branches',
        columns: <String>['variant_index'],
        where: 'branch_id = ? AND segment_hash = ?',
        whereArgs: <Object?>[branchId, hash],
        limit: 1,
      );

      final int index;
      if (existing.isNotEmpty) {
        index = existing.first['variant_index']! as int;
      } else {
        // 内容先落地（已经有就只加一次引用），再插指针。
        final known = await txn.query('segments',
            columns: <String>['hash'],
            where: 'hash = ?',
            whereArgs: <Object?>[hash],
            limit: 1);
        if (known.isEmpty) {
          await txn.insert('segments', <String, Object?>{
            'hash': hash,
            'messages_json': _seal(json),
            'ref_count': 1,
          });
        } else {
          await txn.rawUpdate(
            'UPDATE segments SET ref_count = ref_count + 1 WHERE hash = ?',
            <Object?>[hash],
          );
        }
        final rows = await txn.rawQuery(
          'SELECT COALESCE(MAX(variant_index), -1) AS n '
          'FROM branches WHERE branch_id = ?',
          <Object?>[branchId],
        );
        index = (rows.first['n']! as int) + 1;
        await txn.insert('branches', <String, Object?>{
          'thread_id': threadId,
          'branch_id': branchId,
          'variant_index': index,
          'is_active': 0,
          'segment_hash': hash,
          'created_at': DateTime.now().millisecondsSinceEpoch,
        });
      }

      if (active) {
        await txn.update('branches', <String, Object?>{'is_active': 0},
            where: 'branch_id = ?', whereArgs: <Object?>[branchId]);
        await txn.update('branches', <String, Object?>{'is_active': 1},
            where: 'branch_id = ? AND variant_index = ?',
            whereArgs: <Object?>[branchId, index]);
      }
      return index;
    });
  }

  /// 这个分支点现在有几个版本、正在看第几个。没分过支时返回 null。
  Future<BranchState?> branchStateOf(String branchId) async {
    final rows = await _db.query(
      'branches',
      columns: <String>['variant_index', 'is_active'],
      where: 'branch_id = ?',
      whereArgs: <Object?>[branchId],
      orderBy: 'variant_index ASC',
    );
    if (rows.isEmpty) return null;
    var active = 0;
    for (final row in rows) {
      if ((row['is_active'] as int? ?? 0) == 1) {
        active = row['variant_index']! as int;
      }
    }
    return BranchState(total: rows.length, active: active);
  }

  /// 取出某个版本的内容。序号不存在时返回 null。
  Future<List<ChatMessage>?> loadVariant(String branchId, int index) async {
    final rows = await _db.rawQuery(
      'SELECT s.messages_json AS json FROM branches b '
      'JOIN segments s ON s.hash = b.segment_hash '
      'WHERE b.branch_id = ? AND b.variant_index = ? LIMIT 1',
      <Object?>[branchId, index],
    );
    if (rows.isEmpty) return null;
    final json = _open(rows.first['json'] as String?);
    if (json == null || json.isEmpty) return const <ChatMessage>[];
    return _decodeSegment(json);
  }

  /// 把某个版本标成当前正在看的那个。只记账，不动 messages 表 ——
  /// 活动路径永远以 messages 表为准，这里只是让重开 App 后还记得停在哪个版本。
  Future<void> setActiveVariant(String branchId, int index) async {
    await _db.transaction((txn) async {
      await txn.update('branches', <String, Object?>{'is_active': 0},
          where: 'branch_id = ?', whereArgs: <Object?>[branchId]);
      await txn.update('branches', <String, Object?>{'is_active': 1},
          where: 'branch_id = ? AND variant_index = ?',
          whereArgs: <Object?>[branchId, index]);
    });
  }

  Future<List<ChatMessage>> replaceMessages(
    String threadId,
    List<ChatMessage> messages,
  ) async {
    final stored = <ChatMessage>[];
    await _db.transaction((txn) async {
      await txn.delete(
        'messages',
        where: 'thread_id = ?',
        whereArgs: <Object?>[threadId],
      );
      for (final message in messages) {
        final id = await txn.insert('messages', <String, Object?>{
          'thread_id': threadId,
          'role': message.role,
          'content': _seal(message.content),
          'created_at': message.at.millisecondsSinceEpoch,
          'output_ref': _seal(message.outputRef),
          'checkpoint': message.checkpoint,
          'source': _seal(message.source),
          'images': _seal(_encodeImages(message.images)),
          'tokens_in': message.usage?.input,
          'tokens_out': message.usage?.output,
          'tokens_cached': message.usage?.cached,
          'tokens_estimated': (message.usage?.estimated ?? false) ? 1 : 0,
          'reasoning':
              _seal(message.reasoning.isEmpty ? null : message.reasoning),
          'reasoning_ms': message.reasoningMs == 0 ? null : message.reasoningMs,
          'branch_id': message.branchId,
          'tool_name': message.toolName,
          'tool_title': _seal(message.toolTitle),
          'tool_ok': message.toolOk ? 1 : 0,
          'tool_ms': message.toolMs == 0 ? null : message.toolMs,
        });
        stored.add(message.copyWith(messageId: id));
      }
    });
    return stored;
  }
}
