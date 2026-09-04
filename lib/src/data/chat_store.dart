import 'dart:convert';

import 'package:crypto/crypto.dart';
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

  static Future<ChatStore> open() async =>
      openAt(p.join(await getDatabasesPath(), 'burrow.db'));

  /// 在指定路径开库。单测用它开一个内存库 —— 正式路径要 Android 的
  /// getDatabasesPath()，在纯 Dart 测试环境里取不到。
  static Future<ChatStore> openAt(String path) async {
    final db = await openDatabase(
      path,
      version: 13,
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
            last_read_message_id INTEGER
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
    final summary = rows.first['summary'] as String?;
    final checkpoint = rows.first['summary_checkpoint'] as int?;
    if (summary == null || summary.isEmpty || checkpoint == null) return null;
    return (summary: summary, checkpoint: checkpoint);
  }

  /// 存这个会话的滚动摘要状态。[summary] 为 null = 清掉。
  Future<void> setMemory(String threadId, String? summary, int checkpoint) =>
      _db.update(
        'threads',
        <String, Object?>{
          'summary': summary,
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

  Future<List<ChatMessage>> messages(String threadId) async {
    final rows = await _db.query(
      'messages',
      where: 'thread_id = ?',
      whereArgs: <Object?>[threadId],
      orderBy: 'id ASC',
    );
    return rows
        .map((row) => ChatMessage(
              messageId: row['id']! as int,
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
              branchId: row['branch_id'] as String?,
              toolName: row['tool_name'] as String?,
              toolTitle: row['tool_title'] as String?,
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

    final escaped = keyword
        .replaceAll(r'\', r'\\')
        .replaceAll('%', r'\%')
        .replaceAll('_', r'\_');
    final hits = <ChatMessageSearchHit>[];
    final threadFilter = threadId == null ? '' : 'AND m.thread_id = ? ';
    final rows = await _db.rawQuery(
      'SELECT m.id AS message_id, m.thread_id, m.role, m.content, '
      'm.created_at, t.title AS thread_title '
      'FROM messages m '
      'INNER JOIN threads t ON t.id = m.thread_id '
      "WHERE m.content LIKE ? ESCAPE '\\' "
      '$threadFilter'
      'ORDER BY m.id DESC LIMIT ?',
      <Object?>[
        '%$escaped%',
        if (threadId != null) threadId,
        limit,
      ],
    );
    for (final row in rows) {
      final content = row['content']! as String;
      if (!content.toLowerCase().contains(keyword.toLowerCase())) continue;
      hits.add(ChatMessageSearchHit(
        threadId: row['thread_id']! as String,
        messageId: row['message_id']! as int,
        threadTitle: row['thread_title']! as String,
        role: row['role']! as String,
        message: content,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          row['created_at']! as int,
        ),
      ));
    }
    return hits;
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
      'branch_id': message.branchId,
      'tool_name': message.toolName,
      'tool_title': message.toolTitle,
      'tool_ok': message.toolOk ? 1 : 0,
      'tool_ms': message.toolMs == 0 ? null : message.toolMs,
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
            'messages_json': json,
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
    return _decodeSegment(rows.first['json']! as String);
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
          'branch_id': message.branchId,
          'tool_name': message.toolName,
          'tool_title': message.toolTitle,
          'tool_ok': message.toolOk ? 1 : 0,
          'tool_ms': message.toolMs == 0 ? null : message.toolMs,
        });
        stored.add(message.copyWith(messageId: id));
      }
    });
    return stored;
  }
}
