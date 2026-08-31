/// 回滚引擎：content-addressed 反向增量快照。
///
/// ## 为什么不用 hardlink 快照
///
/// `cp -al` / `rsync --link-dest` 是 Linux 上做快照的标准手法，但它在这里是错的：
/// **in-place 修改会穿透 hardlink**。`echo x >> f` 直接改 inode，快照里那份
/// hardlink 的内容跟着变，快照静默失真、且没有任何报错。
/// （`sed -i` 走 rename 所以安全，但你没法要求 LLM 只用 rename 语义的工具。）
/// macOS 的 Time Machine 靠 APFS clonefile 绕开这点，Linux 上没有 per-file COW。
///
/// ## 反向增量
///
/// 工作副本永远是最新的；每一代只保存「**回滚回去所需要的旧内容**」：
///
/// ```
/// gen 3 (HEAD)   工作区当前状态
/// gen 2 .jsonl   {modified, "a.py", old_blob: sha(a.py 在 gen2 时的内容)}
/// gen 1 .jsonl   {created,  "b.py"}          ← 回滚 = 删掉它
/// ```
///
/// 回滚到第 K 代 = 从 HEAD 往回逐代 apply 反向增量。
/// objects 是 content-addressed 的，同一份内容只存一次。
///
/// ## 三条写入路径，代价差三个数量级
///
/// | 路径 | 谁触发 | 怎么记 | 代价 |
/// |---|---|---|---|
/// | 工具层 journal | `write_file`/`apply_patch` | 写之前直接存旧内容 | 微秒，零扫描 |
/// | 扫描式 checkpoint | `exec` 跑任意命令 | 扫 workspace 与上一代 diff | 毫秒~百毫秒 |
/// | prefix 代切换 | `pkg install` | 代目录 + 原子 rename（见 PrefixGenerations） | 秒级 |
///
/// 系统提示词要把 LLM 往第一条路上引 —— 编辑文件用 `apply_patch` 而不是 `sed -i`，
/// 既省 token 又让回滚几乎免费。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// 一次文件级变更。存的是**回滚所需的信息**，不是正向变更。
class ChangeEntry {
  /// created / modified / deleted
  final String op;

  /// 相对 workspace 根的路径。绝不存绝对路径 —— workspace 换位置后仍要能回滚。
  final String path;

  /// 变更**之前**的内容哈希。`created` 时为 null（回滚就是删掉）。
  final String? oldBlob;

  /// 变更之前的 mode。回滚时一并恢复，否则可执行位会丢。
  final int? oldMode;

  const ChangeEntry({
    required this.op,
    required this.path,
    this.oldBlob,
    this.oldMode,
  });

  Map<String, Object?> toJson() => {
        'op': op,
        'path': path,
        if (oldBlob != null) 'old_blob': oldBlob,
        if (oldMode != null) 'old_mode': oldMode,
      };

  factory ChangeEntry.fromJson(Map<String, Object?> j) => ChangeEntry(
        op: j['op']! as String,
        path: j['path']! as String,
        oldBlob: j['old_blob'] as String?,
        oldMode: j['old_mode'] as int?,
      );
}

/// 一个检查点。
class Checkpoint {
  final int generation;
  final DateTime createdAt;

  /// 给人看的一句话。UI 时间线直接显示，理想情况下由 LLM 生成
  /// （"准备重构 auth 模块"），退化情况下是触发它的命令行。
  final String reason;

  final List<ChangeEntry> changes;

  const Checkpoint({
    required this.generation,
    required this.createdAt,
    required this.reason,
    required this.changes,
  });

  bool get isEmpty => changes.isEmpty;

  Map<String, Object?> toJson() => {
        'generation': generation,
        'created_at': createdAt.toIso8601String(),
        'reason': reason,
        'changes': changes.map((c) => c.toJson()).toList(),
      };

  factory Checkpoint.fromJson(Map<String, Object?> j) => Checkpoint(
        generation: j['generation']! as int,
        createdAt: DateTime.parse(j['created_at']! as String),
        reason: j['reason']! as String,
        changes: (j['changes']! as List)
            .cast<Map<String, Object?>>()
            .map(ChangeEntry.fromJson)
            .toList(),
      );
}

/// 上一代的文件清单条目。**不存内容哈希** —— 存哈希意味着每次 checkpoint
/// 都要把整个 workspace 读一遍算 sha256，那正是我们想避免的开销。
/// 用 (size, mtimeMs, mode) 做变更探测，只对**探测到变化的文件**才去算哈希。
class _StatEntry {
  final int size;
  final int mtimeMs;
  final int mode;
  const _StatEntry(this.size, this.mtimeMs, this.mode);

  bool sameAs(_StatEntry o) =>
      size == o.size && mtimeMs == o.mtimeMs && mode == o.mode;

  List<int> toJson() => [size, mtimeMs, mode];
  factory _StatEntry.fromJson(List<dynamic> j) =>
      _StatEntry(j[0] as int, j[1] as int, j[2] as int);
}

class SnapshotStore {
  /// agent 可写的工作区。快照只覆盖这里。
  final Directory workspace;

  /// 元数据根：objects/ + manifest.json + gen.jsonl + HEAD
  final Directory metaRoot;

  /// 扫描时跳过的目录名。`.git` 是重点 —— 它自己就是版本库，
  /// 快照它既慢又没意义，而且 git 的 packfile 变动量很大。
  final Set<String> excludedDirs;

  /// 单文件大小上限。超过就只记 stat 不存内容 —— 回滚时只能提示
  /// "这个文件太大没存，改动无法撤销"。宁可诚实地说不能，
  /// 也不要让一个 2GB 的模型权重把存储撑爆。
  final int maxBlobBytes;

  int _head = 0;
  Map<String, _StatEntry> _manifest = {};
  final List<Checkpoint> _log = [];

  SnapshotStore({
    required this.workspace,
    required this.metaRoot,
    this.excludedDirs = const {'.git', 'node_modules', '__pycache__', '.venv'},
    this.maxBlobBytes = 8 * 1024 * 1024,
  });

  Directory get _objects => Directory('${metaRoot.path}/objects');
  File get _manifestFile => File('${metaRoot.path}/manifest.json');
  File get _logFile => File('${metaRoot.path}/gen.jsonl');
  File get _headFile => File('${metaRoot.path}/HEAD');

  int get head => _head;
  List<Checkpoint> get checkpoints => List.unmodifiable(_log);

  Future<void> open() async {
    await _objects.create(recursive: true);
    await workspace.create(recursive: true);

    if (await _headFile.exists()) {
      _head = int.tryParse((await _headFile.readAsString()).trim()) ?? 0;
    }
    if (await _manifestFile.exists()) {
      final raw = jsonDecode(await _manifestFile.readAsString())
          as Map<String, dynamic>;
      _manifest = raw.map((k, v) =>
          MapEntry(k, _StatEntry.fromJson((v as List).cast<dynamic>())));
    }
    if (await _logFile.exists()) {
      for (final line in await _logFile.readAsLines()) {
        if (line.trim().isEmpty) continue;
        _log.add(Checkpoint.fromJson(jsonDecode(line) as Map<String, Object?>));
      }
    }
    // 首次打开时建立基线，否则第一个 checkpoint 会把整个 workspace
    // 当成「新建」记一遍，然后第一次回滚会把用户已有的文件全删了。
    if (_manifest.isEmpty && _log.isEmpty) {
      _manifest = await _scan();
      await _persistManifest();
    }
  }

  // ---------------------------------------------------------------
  // 路径 1：工具层 journal —— 精确、零扫描
  // ---------------------------------------------------------------

  /// 在 `write_file` / `apply_patch` **动手之前**调用，把旧内容存进 objects。
  ///
  /// 这条路径不需要扫描，因为我们已经知道要动哪个文件。它的开销就是
  /// 读一遍那一个文件 + 写一个 blob。
  ///
  /// 返回的 entry 由调用方攒进本轮的 pending 列表，随下一个 checkpoint 落盘。
  Future<ChangeEntry> recordIntentToWrite(String relPath) async {
    final f = File('${workspace.path}/$relPath');
    if (!await f.exists()) {
      return ChangeEntry(op: 'created', path: relPath);
    }
    final stat = await f.stat();
    final blob = await _storeBlob(f, stat.size);
    return ChangeEntry(
      op: 'modified',
      path: relPath,
      oldBlob: blob,
      oldMode: stat.mode & 0xFFF,
    );
  }

  /// 在删除文件之前调用。
  Future<ChangeEntry> recordIntentToDelete(String relPath) async {
    final f = File('${workspace.path}/$relPath');
    if (!await f.exists()) {
      return ChangeEntry(op: 'created', path: relPath); // 本来就不存在，回滚无操作
    }
    final stat = await f.stat();
    final blob = await _storeBlob(f, stat.size);
    return ChangeEntry(
      op: 'deleted',
      path: relPath,
      oldBlob: blob,
      oldMode: stat.mode & 0xFFF,
    );
  }

  final List<ChangeEntry> _pending = [];

  /// 工具层把 `recordIntentTo*` 的结果交回来，进入待落盘队列。
  void stage(ChangeEntry entry) => _pending.add(entry);

  // ---------------------------------------------------------------
  // 路径 2：扫描式 checkpoint —— 覆盖任意 shell 命令
  // ---------------------------------------------------------------

  /// 打一个检查点。
  ///
  /// 扫描 workspace 与上一代清单 diff，把差异**加上** `_pending` 里工具层
  /// 已经精确记录的那些，一起落成新的一代。
  ///
  /// 没有任何变化时返回 null 且不推进代号 —— 大多数 turn 其实什么都没改，
  /// 让它们免费。这也是 "每个 turn 开始自动 checkpoint" 敢做的前提。
  Future<Checkpoint?> checkpoint({required String reason}) async {
    final current = await _scan();
    final changes = <ChangeEntry>[];

    // 工具层已精确记录的路径，扫描阶段不要重复记 —— 工具层的记录更准
    // （它拿到的是"写之前"那一刻的内容，扫描拿到的是"上一代"的内容，
    //   同一个 turn 内改了两次时后者会丢中间态）。
    final claimed = _pending.map((e) => e.path).toSet();
    changes.addAll(_pending);
    _pending.clear();

    for (final entry in current.entries) {
      if (claimed.contains(entry.key)) continue;
      final old = _manifest[entry.key];
      if (old == null) {
        changes.add(ChangeEntry(op: 'created', path: entry.key));
      } else if (!old.sameAs(entry.value)) {
        // 只对真的变了的文件算哈希 —— 这是扫描能做到毫秒级的关键。
        // 注意这里存的是**当前**内容，因为 manifest 里那份旧内容已经没了：
        // 我们没在上一代保存它。所以扫描式路径只能保证"回滚到上次 checkpoint
        // 之后的第一次改动前"，中间态丢失。要精确就走工具层路径。
        final f = File('${workspace.path}/${entry.key}');
        final blob = await _storeBlob(f, entry.value.size);
        changes.add(ChangeEntry(
          op: 'modified',
          path: entry.key,
          oldBlob: blob,
          oldMode: entry.value.mode,
        ));
      }
    }

    for (final path in _manifest.keys) {
      if (current.containsKey(path) || claimed.contains(path)) continue;
      // 文件被删了，但我们没有它的旧内容（上一代没存）。只能记一笔，
      // 回滚时提示无法恢复。工具层的 delete 走 recordIntentToDelete，不落到这里。
      changes.add(ChangeEntry(op: 'deleted', path: path));
    }

    if (changes.isEmpty) return null;

    _head += 1;
    final cp = Checkpoint(
      generation: _head,
      createdAt: DateTime.now(),
      reason: reason,
      changes: changes,
    );
    _log.add(cp);
    await _logFile.writeAsString('${jsonEncode(cp.toJson())}\n',
        mode: FileMode.append);
    _manifest = current;
    await _persistManifest();
    await _headFile.writeAsString('$_head');
    return cp;
  }

  // ---------------------------------------------------------------
  // 回滚
  // ---------------------------------------------------------------

  /// 回滚到第 [generation] 代结束时的状态。
  ///
  /// 从 HEAD 往回逐代 apply 反向增量。每代内部按**倒序** apply ——
  /// 同一代里同一个文件可能被记了多次（工具层先记 modified，扫描又记了一次），
  /// 倒序保证最早那份旧内容最后写入，也就是最终生效的那份。
  Future<RollbackReport> rollbackTo(int generation) async {
    if (generation > _head) {
      throw ArgumentError('目标代 $generation 在 HEAD($_head) 之后');
    }
    final restored = <String>[];
    final removed = <String>[];
    final unrecoverable = <String>[];

    for (var g = _head; g > generation; g--) {
      final cp = _log.firstWhere((c) => c.generation == g,
          orElse: () => Checkpoint(
              generation: g,
              createdAt: DateTime.now(),
              reason: '',
              changes: const []));

      for (final change in cp.changes.reversed) {
        final f = File('${workspace.path}/${change.path}');
        switch (change.op) {
          case 'created':
            if (await f.exists()) {
              await f.delete();
              removed.add(change.path);
            }
          case 'modified':
          case 'deleted':
            if (change.oldBlob == null) {
              unrecoverable.add(change.path);
              continue;
            }
            final blob = _blobFile(change.oldBlob!);
            if (!await blob.exists()) {
              unrecoverable.add(change.path);
              continue;
            }
            await f.parent.create(recursive: true);
            await blob.copy(f.path);
            if (change.oldMode != null && !Platform.isWindows) {
              // Dart 没有 chmod，交给 shell。可执行位丢了会让回滚"看起来成功
              // 但脚本跑不起来"，比明着失败更难查。
              await Process.run('chmod', [
                change.oldMode!.toRadixString(8).padLeft(3, '0'),
                f.path,
              ]);
            }
            restored.add(change.path);
        }
      }

      _log.removeWhere((c) => c.generation == g);
    }

    _head = generation;
    await _headFile.writeAsString('$_head');
    await _rewriteLog();
    _manifest = await _scan();
    await _persistManifest();
    _pending.clear();

    return RollbackReport(
      targetGeneration: generation,
      restored: restored,
      removed: removed,
      unrecoverable: unrecoverable,
    );
  }

  /// 垃圾回收：删掉不再被任何一代引用的 blob。
  /// 回滚之后该跑一次，否则被丢弃那些代的 blob 会永久占着空间。
  Future<int> gc() async {
    final live = <String>{};
    for (final cp in _log) {
      for (final c in cp.changes) {
        if (c.oldBlob != null) live.add(c.oldBlob!);
      }
    }
    for (final e in _pending) {
      if (e.oldBlob != null) live.add(e.oldBlob!);
    }

    var freed = 0;
    await for (final entity in _objects.list(recursive: true)) {
      if (entity is! File) continue;
      // blob 的路径是 objects/<前2位>/<后62位>，拼回完整 sha256 再比对。
      final name = _basename(entity.path);
      final prefix = _basename(entity.parent.path);
      if (!live.contains('$prefix$name')) {
        freed += (await entity.stat()).size;
        await entity.delete();
      }
    }
    return freed;
  }

  // ---------------------------------------------------------------
  // 内部
  // ---------------------------------------------------------------

  Future<Map<String, _StatEntry>> _scan() async {
    final result = <String, _StatEntry>{};
    final rootLen = workspace.path.length + 1;

    Future<void> walk(Directory dir) async {
      await for (final entity in dir.list(followLinks: false)) {
        final name = _basename(entity.path);
        if (entity is Directory) {
          if (excludedDirs.contains(name)) continue;
          await walk(entity);
        } else if (entity is File) {
          final stat = await entity.stat();
          result[entity.path.substring(rootLen).replaceAll(r'\', '/')] =
              _StatEntry(
            stat.size,
            stat.modified.millisecondsSinceEpoch,
            stat.mode & 0xFFF,
          );
        }
        // 符号链接跳过：它的"内容"是目标路径，恢复语义和普通文件不同，
        // 而 workspace 里出现 symlink 本身就少见。需要时单独加一类 op。
      }
    }

    if (await workspace.exists()) await walk(workspace);
    return result;
  }

  /// 取路径最后一段。不用 `Uri.pathSegments` —— 目标平台是 Android（`/`），
  /// 但单测跑在 Windows 上（`\`），Uri 解析在后者上会把整条路径当成一段。
  static String _basename(String path) {
    final i = path.lastIndexOf(RegExp(r'[/\\]'));
    return i < 0 ? path : path.substring(i + 1);
  }

  File _blobFile(String hash) =>
      File('${_objects.path}/${hash.substring(0, 2)}/${hash.substring(2)}');

  /// 存一份内容，返回其 sha256。已存在则直接复用（去重）。
  Future<String?> _storeBlob(File f, int size) async {
    if (size > maxBlobBytes) return null;
    final bytes = await f.readAsBytes();
    final hash = sha256.convert(bytes).toString();
    final target = _blobFile(hash);
    if (!await target.exists()) {
      await target.parent.create(recursive: true);
      await target.writeAsBytes(bytes, flush: true);
    }
    return hash;
  }

  Future<void> _persistManifest() async {
    final json = _manifest.map((k, v) => MapEntry(k, v.toJson()));
    await _manifestFile.writeAsString(jsonEncode(json), flush: true);
  }

  Future<void> _rewriteLog() async {
    final sink = StringBuffer();
    for (final cp in _log) {
      sink.writeln(jsonEncode(cp.toJson()));
    }
    await _logFile.writeAsString(sink.toString(), flush: true);
  }
}

class RollbackReport {
  final int targetGeneration;
  final List<String> restored;
  final List<String> removed;

  /// 旧内容没存下来（超过 maxBlobBytes，或是扫描式路径记的删除）的文件。
  /// **必须**展示给用户 —— 一次"部分成功"的回滚如果被报告成成功，
  /// 用户会基于错误的前提继续操作。
  final List<String> unrecoverable;

  const RollbackReport({
    required this.targetGeneration,
    required this.restored,
    required this.removed,
    required this.unrecoverable,
  });

  bool get isClean => unrecoverable.isEmpty;

  @override
  String toString() {
    final b = StringBuffer('回滚到第 $targetGeneration 代：');
    b.write('恢复 ${restored.length} 个文件，删除 ${removed.length} 个新建文件');
    if (unrecoverable.isNotEmpty) {
      b.write('；${unrecoverable.length} 个文件无法恢复（旧内容未保存）：');
      b.write(unrecoverable.take(5).join(', '));
    }
    return b.toString();
  }
}
