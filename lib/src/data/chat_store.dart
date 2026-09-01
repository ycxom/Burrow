import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../context/overflow_manager.dart';

class ChatThread {
  const ChatThread({
    required this.id,
    required this.title,
    required this.preview,
    required this.updatedAt,
    this.terminalMode = false,
  });

  final String id;
  final String title;
  final String preview;
  final DateTime updatedAt;

  /// 这个会话开没开终端模式。跟着会话走而不是全局一个开关：
  /// 「帮我看看这段代码什么意思」和「把这个仓库编出来」是两种对话，
  /// 用同一个全局开关意味着每次切换都要手动拨一下。
  final bool terminalMode;
}

class ChatStore {
  ChatStore._(this._db);

  final Database _db;

  static Future<ChatStore> open() async {
    final path = p.join(await getDatabasesPath(), 'burrow.db');
    final db = await openDatabase(
      path,
      version: 4,
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
      },
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE threads(
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            preview TEXT NOT NULL,
            updated_at INTEGER NOT NULL,
            terminal_mode INTEGER NOT NULL DEFAULT 0
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
            source TEXT
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
            ))
        .toList();
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
        });
      }
    });
  }
}
