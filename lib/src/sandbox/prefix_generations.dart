/// 发行版 rootfs（包环境）的回滚：代目录 + 原子 rename。
///
/// 这是 `TermuxInstaller` 那套 staging 手法的推广。原版只在首次安装 bootstrap 时
/// 用一次（解压到 `usr-staging`，成功后 `renameTo(usr)`）；我们把它变成
/// **每次装包都走一遍**，于是每一次 `apk add` / `apt install` 都自带一个可回退的代。
///
/// ```
/// apt install foo:
///   1. cp -al rootfs rootfs.staging   hardlink 复制：秒级，几乎不占空间
///   2. 在 rootfs.staging 里跑 apt
///   3. 成功: mv rootfs rootfs.gen/000007 && mv rootfs.staging rootfs  ← 原子切换
///      失败: rm -rf rootfs.staging                                    ← 什么都没发生
/// ```
///
/// 换成发行版基座之后这套机制比原来更合适：整个 rootfs 就是一个普通目录，
/// 没有跨目录的硬编码路径要维护，一次 rename 就能整体换掉。
///
/// ## 为什么这里的 hardlink 是安全的（而 workspace 里不是）
///
/// SnapshotStore 的注释里说过 hardlink 快照会被 in-place 修改穿透。
/// 这里能用 hardlink，靠的是一条**关于 dpkg 的前提**：
///
/// > dpkg/apt 从不 in-place 修改已有文件。它总是把新版本写到临时路径，
/// > 再 `rename()` 覆盖过去 —— 这是 dpkg 保证安装原子性的既有设计。
///
/// rename 会断开 hardlink，所以 `usr.gen/000006` 里那份仍指向旧 inode，内容不变。
/// 普通 shell 命令没有这条保证（`echo >> f` 就穿透了），所以 workspace 必须
/// 用反向增量。**两个地方用两套机制，不是不统一，是前提不同。**
///
/// 前提失效的情况要认：某些包的 postinst 脚本会直接 `sed -i` 改配置文件。
/// 所以 `commit()` 之后对 `etc/` 下的文件额外做一次内容校验（见 [verifyEtc]），
/// 发现穿透就把那一代的受影响文件单独复制成实体文件。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

class PrefixGeneration {
  final int id;
  final DateTime createdAt;

  /// 触发这一代的命令行，例如 `pkg install python`。
  final String reason;

  /// 这一代目录的字节数（只统计非 hardlink 共享的部分，即真实新增占用）。
  final int uniqueBytes;

  const PrefixGeneration({
    required this.id,
    required this.createdAt,
    required this.reason,
    required this.uniqueBytes,
  });

  Map<String, Object?> toJson() => {
        'id': id,
        'created_at': createdAt.toIso8601String(),
        'reason': reason,
        'unique_bytes': uniqueBytes,
      };

  factory PrefixGeneration.fromJson(Map<String, Object?> j) => PrefixGeneration(
        id: j['id']! as int,
        createdAt: DateTime.parse(j['created_at']! as String),
        reason: j['reason']! as String,
        uniqueBytes: j['unique_bytes'] as int? ?? 0,
      );
}

/// 一次「在暂存副本里改环境」的事务。
class PrefixTransaction {
  final Directory staging;
  final PrefixGenerations _owner;
  final String reason;
  var _settled = false;

  PrefixTransaction._(this._owner, this.staging, this.reason);

  /// 事务里的目标目录。命令必须在这个副本上跑，而不是正在用的那份。
  String get stagingPath => staging.path;

  /// 成功：把当前 usr 归档成新的一代，暂存副本顶上。
  Future<PrefixGeneration> commit() => _owner._commit(this);

  /// 失败：直接扔掉暂存副本，真实环境毫发无损。
  Future<void> abort() => _owner._abort(this);
}

class PrefixGenerations {
  /// 被管理的目录的**父目录**。
  /// rename 要求同一文件系统，所以 `<name>` / `<name>.staging` / `<name>.gen`
  /// 三者必须同父。
  ///
  /// 可变：用户可以在运行中装上（或换掉）发行版基座。改它的唯一入口是
  /// [rebind]，因为换目录必须连带重读代索引。
  Directory filesRoot;

  /// 被管理的目录名。
  ///
  /// 换成发行版基座之后这里是 `rootfs`（在 `distros/<id>/` 下）；
  /// 早先的 Termux 方案里是 `usr`。参数化而不是写死，是因为
  /// 「代目录 + 原子 rename」这套机制和被管理的到底是什么无关 ——
  /// 它只要求那是一个可以整体换掉的目录。
  final String name;

  /// 保留多少代。超出的从最老的开始删 —— 手机存储有限，
  /// 而且十代之前的包环境实际上没人会回滚过去。
  final int keepGenerations;

  final List<PrefixGeneration> _generations = [];

  PrefixGenerations({
    required this.filesRoot,
    this.name = 'rootfs',
    this.keepGenerations = 5,
  });

  Directory get prefix => Directory('${filesRoot.path}/$name');
  Directory get _staging => Directory('${filesRoot.path}/$name.staging');
  Directory get _genRoot => Directory('${filesRoot.path}/$name.gen');
  File get _indexFile => File('${_genRoot.path}/index.json');

  List<PrefixGeneration> get generations => List.unmodifiable(_generations);

  Future<void> open() async {
    await _genRoot.create(recursive: true);
    if (await _indexFile.exists()) {
      final raw = jsonDecode(await _indexFile.readAsString()) as List;
      _generations
        ..clear()
        ..addAll(
            raw.cast<Map<String, Object?>>().map(PrefixGeneration.fromJson));
    }
    // 上次崩在事务中间会留下 usr.staging。它一定是不完整的，清掉。
    // （TermuxInstaller 开头也做同一件事，理由相同。）
    if (await _staging.exists()) {
      await _staging.delete(recursive: true);
    }
  }

  /// 改挂到另一个 rootfs 上（用户运行中装好了基座，或切换了发行版）。
  ///
  /// 必须重读代索引：代号是跟着 rootfs 目录走的，不是跟着 app 走的。
  /// 沿用旧列表会让时间线上显示出一批属于另一个发行版的代，
  /// 点回滚会 rename 到一个不存在的目录。
  Future<void> rebind(Directory newRoot) async {
    if (p.equals(newRoot.path, filesRoot.path)) return;
    filesRoot = newRoot;
    _generations.clear();
    await open();
  }

  /// 开一个环境事务。`reason` 会显示在回滚时间线上。
  Future<PrefixTransaction> begin({required String reason}) async {
    if (await _staging.exists()) {
      throw StateError('已有未结束的环境事务，先 commit 或 abort');
    }
    // cp -al：hardlink 递归复制。这一步的代价是 O(inode 数)，
    // 五万个文件在中端机上约 2~4 秒，且几乎不占额外空间。
    final r = await Process.run('cp', ['-al', prefix.path, _staging.path]);
    if (r.exitCode != 0) {
      // 有些文件系统 / SELinux 上下文下 hardlink 会失败，退回真复制。
      // 慢很多（几十秒），但至少事务语义还在。
      if (await _staging.exists()) await _staging.delete(recursive: true);
      final r2 = await Process.run('cp', ['-a', prefix.path, _staging.path]);
      if (r2.exitCode != 0) {
        throw ProcessException('cp', ['-a'], r2.stderr.toString(), r2.exitCode);
      }
    }
    return PrefixTransaction._(this, _staging, reason);
  }

  Future<PrefixGeneration> _commit(PrefixTransaction tx) async {
    if (tx._settled) throw StateError('事务已结束');
    tx._settled = true;

    final id = (_generations.isEmpty ? 0 : _generations.last.id) + 1;
    final archived =
        Directory('${_genRoot.path}/${id.toString().padLeft(6, '0')}');

    // 两次 rename。中间那一瞬间 usr 不存在 —— 如果进程在这里被杀，
    // 下次启动会看到「usr 缺失但 usr.staging 存在」，recover() 负责补上。
    await prefix.rename(archived.path);
    await _staging.rename(prefix.path);

    final gen = PrefixGeneration(
      id: id,
      createdAt: DateTime.now(),
      reason: tx.reason,
      uniqueBytes: await _measureUnique(archived),
    );
    _generations.add(gen);
    await _persist();
    await _prune();
    return gen;
  }

  Future<void> _abort(PrefixTransaction tx) async {
    if (tx._settled) return;
    tx._settled = true;
    if (await _staging.exists()) {
      await _staging.delete(recursive: true);
    }
  }

  /// 回滚到第 [id] 代结束时的环境。
  ///
  /// 同样是两次 rename：当前 usr 先归档成新的一代（这样"回滚"本身也可撤销），
  /// 然后把目标代 rename 回 usr。
  Future<void> rollbackTo(int id) async {
    final target =
        Directory('${_genRoot.path}/${id.toString().padLeft(6, '0')}');
    if (!await target.exists()) {
      throw ArgumentError('第 $id 代不存在或已被清理');
    }

    final newId = (_generations.isEmpty ? 0 : _generations.last.id) + 1;
    final archived =
        Directory('${_genRoot.path}/${newId.toString().padLeft(6, '0')}');

    await prefix.rename(archived.path);
    await target.rename(prefix.path);

    _generations
      ..removeWhere((g) => g.id == id)
      ..add(PrefixGeneration(
        id: newId,
        createdAt: DateTime.now(),
        reason: '回滚到第 $id 代之前的环境',
        uniqueBytes: await _measureUnique(archived),
      ));
    await _persist();
  }

  /// 崩溃恢复。在 [open] 之后、任何事务之前调用。
  ///
  /// 只有一种真正危险的中间态：commit 的两次 rename 之间被杀，
  /// 此时 usr 不存在而 usr.staging 存在。那份 staging 是**已经装完包的完整环境**，
  /// 直接扶正即可 —— 比让用户面对一个没有 usr 的 app 好得多。
  Future<bool> recover() async {
    if (await prefix.exists()) return false;
    if (!await _staging.exists()) return false;
    await _staging.rename(prefix.path);
    return true;
  }

  /// 校验某一代里 `etc/` 下的文件有没有被 hardlink 穿透污染。
  ///
  /// 前提（dpkg 从不 in-place 改文件）对 dpkg 本体成立，对包自带的 postinst
  /// 脚本不成立 —— 有些脚本会 `sed -i` 改 `etc/` 下的配置。校验发现穿透时，
  /// 把受影响的文件从 hardlink 变成实体副本，代价只是那几个小文件。
  ///
  /// 返回被修复的文件路径。
  Future<List<String>> verifyEtc(int generationId) async {
    final gen = Directory(
        '${_genRoot.path}/${generationId.toString().padLeft(6, '0')}/etc');
    if (!await gen.exists()) return const [];

    final fixed = <String>[];
    await for (final e in gen.list(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      final stat = await e.stat();
      // nlink 无法从 Dart 的 FileStat 读到，退回 shell。这条路径不在热路径上，
      // 只在 commit 之后跑一次，几百个文件的 stat 可以接受。
      final r = await Process.run('stat', ['-c', '%h', e.path]);
      final nlink = int.tryParse(r.stdout.toString().trim()) ?? 1;
      if (nlink <= 1) continue; // 已经是独立 inode，没有穿透风险

      // 断链：复制成临时文件再 rename 覆盖。
      final tmp = File('${e.path}.pa-detach');
      await e.copy(tmp.path);
      await tmp.rename(e.path);
      await Process.run(
          'chmod', [(stat.mode & 0xFFF).toRadixString(8), e.path]);
      fixed.add(e.path);
    }
    return fixed;
  }

  Future<void> _prune() async {
    while (_generations.length > keepGenerations) {
      final oldest = _generations.removeAt(0);
      final dir =
          Directory('${_genRoot.path}/${oldest.id.toString().padLeft(6, '0')}');
      if (await dir.exists()) await dir.delete(recursive: true);
    }
    await _persist();
  }

  /// 这一代实际占用的空间：只算 nlink == 1 的文件，
  /// 因为 nlink > 1 的部分是和 usr 共享的，删掉这一代也不会释放。
  ///
  /// 纯展示用途（回滚列表里的「占 xx MB」），所以是 best-effort：
  /// 失败一律返回 0，绝不让一个统计数字挡住 commit。
  ///
  /// 不用 `find -printf` —— 那是 GNU findutils 的扩展，而 Android 上
  /// `find` 通常是 toybox 的，`-printf` 直接报错。`-links 1 -exec` 和
  /// `du` 都是 POSIX 里有的，两条路都试一遍。
  Future<int> _measureUnique(Directory dir) async {
    try {
      final r = await Process.run('sh', [
        '-c',
        'find ${dir.path} -type f -links 1 -exec du -k {} + 2>/dev/null '
            "| awk '{s+=\$1} END {print (s+0)*1024}'",
      ]).timeout(const Duration(seconds: 20));
      final v = int.tryParse(r.stdout.toString().trim());
      if (v != null) return v;
    } catch (_) {
      // 超时或 sh 不可用。统计失败不是错误。
    }
    return 0;
  }

  Future<void> _persist() async {
    await _indexFile.writeAsString(
      jsonEncode(_generations.map((g) => g.toJson()).toList()),
      flush: true,
    );
  }
}
