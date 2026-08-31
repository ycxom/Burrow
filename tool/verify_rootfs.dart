/// 拿真实的发行版 rootfs 压一遍 TarReader。
///
/// 单测里那个 tar 是我们自己造的，只能验证「解析器和我脑子里的格式一致」。
/// 真实 rootfs 里有单测造不出来的东西：几百个指向 busybox 的硬链接、
/// 设备节点、超长的 doc 路径、以及各家 tar 工具的方言差异。
/// 那些才是解压 Ubuntu base 时真正会遇到的。
///
///     dart run tool/verify_rootfs.dart <path-to-rootfs.tar.gz> [解压目标目录]
///
/// 不带解压目录时只统计不落盘。
library;

// 这是命令行脚本，stdout 就是它的产品。
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:burrow/src/bootstrap/tar_reader.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('用法: dart run tool/verify_rootfs.dart <rootfs.tar.gz> [目标目录]');
    exit(2);
  }

  final archive = File(args[0]);
  if (!await archive.exists()) {
    stderr.writeln('找不到 ${archive.path}');
    exit(2);
  }

  final outDir = args.length > 1 ? Directory(args[1]) : null;
  if (outDir != null) {
    if (await outDir.exists()) await outDir.delete(recursive: true);
    await outDir.create(recursive: true);
  }

  final size = await archive.length();
  final digest = sha256.convert(await archive.readAsBytes());
  print('归档   : ${archive.path}');
  print('大小   : ${(size / 1024 / 1024).toStringAsFixed(2)} MB');
  print('sha256 : $digest');
  print('');

  final counts = <TarEntryType, int>{};
  final skipped = <String>[];
  var longestPath = '';
  var totalBytes = 0;
  final sampleLinks = <String>[];
  final sampleHard = <String>[];

  final sw = Stopwatch()..start();

  await TarReader.extract(
    archive.openRead(),
    onEntry: (e, content) async {
      counts[e.type] = (counts[e.type] ?? 0) + 1;
      if (e.name.length > longestPath.length) longestPath = e.name;
      if (content != null) totalBytes += content.length;
      if (e.type == TarEntryType.symlink && sampleLinks.length < 5) {
        sampleLinks.add('${e.name} -> ${e.linkTarget}');
      }
      if (e.type == TarEntryType.hardlink && sampleHard.length < 5) {
        sampleHard.add('${e.name} => ${e.linkTarget}');
      }
      if (outDir != null) await _write(outDir, e, content);
    },
    onSkipped: (e, reason) => skipped.add('${e.name}  ($reason)'),
  );

  sw.stop();

  print('耗时     : ${sw.elapsedMilliseconds} ms');
  print('普通文件 : ${counts[TarEntryType.regular] ?? 0}');
  print('目录     : ${counts[TarEntryType.directory] ?? 0}');
  print('符号链接 : ${counts[TarEntryType.symlink] ?? 0}');
  print('硬链接   : ${counts[TarEntryType.hardlink] ?? 0}');
  print('跳过     : ${skipped.length}');
  print('解开总量 : ${(totalBytes / 1024 / 1024).toStringAsFixed(2)} MB');
  print('最长路径 : ${longestPath.length} 字节  $longestPath');
  print('');

  if (sampleLinks.isNotEmpty) {
    print('符号链接样本:');
    for (final l in sampleLinks) {
      print('  $l');
    }
  }
  if (sampleHard.isNotEmpty) {
    print('硬链接样本:');
    for (final l in sampleHard) {
      print('  $l');
    }
  }
  if (skipped.isNotEmpty) {
    print('跳过的条目:');
    for (final l in skipped.take(10)) {
      print('  $l');
    }
  }

  // 健全性检查：rootfs 里必须有 /bin/sh —— 它是 SandboxSession 写死的入口，
  // 缺了整个沙箱起不来。
  //
  // 不能只看 `<root>/bin/sh` 是否存在：Ubuntu 用 usr-merge，`bin` 本身是
  // 指向 `usr/bin` 的软链，真正的 sh 在 `usr/bin/sh`。而在 Windows 上
  // 建不了软链（本脚本会静默跳过），那条路径根本不存在。
  // 所以两处都认，任一命中即可。
  if (outDir != null) {
    final candidates = ['bin/sh', 'usr/bin/sh', 'bin/busybox', 'usr/bin/busybox'];
    final found = <String>[];
    for (final c in candidates) {
      if (await File('${outDir.path}/$c').exists() ||
          await Link('${outDir.path}/$c').exists()) {
        found.add(c);
      }
    }
    print('');
    print('sh 入口 : ${found.isEmpty ? '【找不到】' : found.join(', ')}');
    if (found.isEmpty) {
      stderr.writeln('【失败】解开的 rootfs 里找不到 sh，沙箱起不来');
      exit(1);
    }
  }
}

Future<void> _write(Directory root, TarEntry e, List<int>? content) async {
  final full = '${root.path}/${e.name}';
  switch (e.type) {
    case TarEntryType.directory:
      await Directory(full).create(recursive: true);
    case TarEntryType.regular:
      final f = File(full);
      await f.parent.create(recursive: true);
      await f.writeAsBytes(content ?? const []);
    case TarEntryType.symlink:
      final l = Link(full);
      await l.parent.create(recursive: true);
      if (await l.exists()) await l.delete();
      try {
        await l.create(e.linkTarget);
      } catch (_) {
        // Windows 上没有开发者模式时建不了软链。统计仍然有效。
      }
    case TarEntryType.hardlink:
      final src = File('${root.path}/${e.linkTarget}');
      if (await src.exists()) {
        await File(full).parent.create(recursive: true);
        await src.copy(full);
      }
    case TarEntryType.unsupported:
      break;
  }
}
