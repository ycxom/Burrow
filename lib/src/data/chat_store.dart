import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../agent/agent_loop.dart' show TokenUsage;
import '../context/overflow_manager.dart';

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

class ChatStore {
  ChatStore._(this._db);

  final Database _db;

  static Future<ChatStore> open() async {
    final path = p.join(await getDatabasesPath(), 'burrow.db');
    final db = await openDatabase(
      path,
      version: 9,
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
          await db.execute(
              'ALTER TABLE messages ADD COLUMN tokens_cached INTEGER');
        }
        if (from < 9) {
          // 思考过程。老消息没有 —— 那时候压根没收这个字段，留空即可。
          // UI 对空值不画思考区，所以历史对话看起来和以前一模一样。
          await db.execute('ALTER TABLE messages ADD COLUMN reasoning TEXT');
          await db.execute(
              'ALTER TABLE messages ADD COLUMN reasoning_ms INTEGER');
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
            system_prompt TEXT
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
            reasoning_ms INTEGER
          )
        ''');
        await db.execute(
          'CREATE INDEX messages_thread ON messages(thread_id, id)',
        );
      },
    );
    return ChatStore._(db);
  }

  Future<List<ChatThread>> threads() async {
    final rows = await _db.query('threads', orderBy: 'updated_at DESC');
    return rows
        .map((row) => ChatThread(
              id: row['id']! as String,
              title: row['title']! as String,
              preview: row['preview']! as String,
              updatedAt: DateTime.fromMillisecondsSinceEpoch(
                row['updated_at']! as int,
              ),
              terminalMode: (row['terminal_mode'] as int? ?? 0) != 0,
              systemPrompt: row['system_prompt'] as String?,
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
    return rows.first['system_prompt'] as String?;
  }

  /// 设这个会话的提示词。null = 清掉，回退到全局。
  Future<void> setSystemPrompt(String threadId, String? prompt) async {
    await _db.update(
      'threads',
      <String, Object?>{'system_prompt': prompt},
      where: 'id = ?',
      whereArgs: <Object?>[threadId],
    );
  }

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
      'title': title,
      'preview': firstMessage,
      'updated_at': now,
      'terminal_mode': terminalMode ? 1 : 0,
    });
    return id;
  }

  Future<void> renameThread(String threadId, String title) async {
    await _db.update(
      'threads',
      <String, Object?>{'title': title},
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
      await txn.delete('messages',
          where: 'thread_id = ?', whereArgs: <Object?>[threadId]);
      await txn
          .delete('threads', where: 'id = ?', whereArgs: <Object?>[threadId]);
    });
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

  Future<List<ChatMessage>> messages(String threadId) async {
    final rows = await _db.query(
      'messages',
      where: 'thread_id = ?',
      whereArgs: <Object?>[threadId],
      orderBy: 'id ASC',
    );
    return rows
        .map((row) => ChatMessage(
              role: row['role']! as String,
              content: row['content']! as String,
              at: DateTime.fromMillisecondsSinceEpoch(
                row['created_at']! as int,
              ),
              outputRef: row['output_ref'] as String?,
              checkpoint: row['checkpoint'] as int?,
              source: row['source'] as String?,
              images: _decodeImages(row['images'] as String?),
              usage: _decodeUsage(row),
              reasoning: row['reasoning'] as String? ?? '',
              reasoningMs: row['reasoning_ms'] as int? ?? 0,
            ))
        .toList();
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
      'content': message.content,
      'created_at': message.at.millisecondsSinceEpoch,
      'output_ref': message.outputRef,
      'checkpoint': message.checkpoint,
      'source': message.source,
      'images': _encodeImages(message.images),
      'tokens_in': message.usage?.input,
      'tokens_out': message.usage?.output,
      'tokens_cached': message.usage?.cached,
      'tokens_estimated': (message.usage?.estimated ?? false) ? 1 : 0,
      'reasoning': message.reasoning.isEmpty ? null : message.reasoning,
      'reasoning_ms': message.reasoningMs == 0 ? null : message.reasoningMs,
    });
    await _db.update(
      'threads',
      <String, Object?>{
        'preview': message.content,
        'updated_at': message.at.millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: <Object?>[threadId],
    );
  }

  Future<void> replaceMessages(
    String threadId,
    List<ChatMessage> messages,
  ) async {
    await _db.transaction((txn) async {
      await txn.delete(
        'messages',
        where: 'thread_id = ?',
        whereArgs: <Object?>[threadId],
      );
      for (final message in messages) {
        await txn.insert('messages', <String, Object?>{
          'thread_id': threadId,
          'role': message.role,
          'content': message.content,
          'created_at': message.at.millisecondsSinceEpoch,
          'output_ref': message.outputRef,
          'checkpoint': message.checkpoint,
          'source': message.source,
          'images': _encodeImages(message.images),
          'tokens_in': message.usage?.input,
          'tokens_out': message.usage?.output,
          'tokens_cached': message.usage?.cached,
          'tokens_estimated': (message.usage?.estimated ?? false) ? 1 : 0,
          'reasoning': message.reasoning.isEmpty ? null : message.reasoning,
          'reasoning_ms': message.reasoningMs == 0 ? null : message.reasoningMs,
        });
      }
    });
  }
}
