/// zip / tar 解析器的单测。
///
/// 归档用系统工具真造出来，而不是手写字节数组：
/// 手写的字节只能验证「解析器和我脑子里的格式一致」，
/// 而真实归档能验证「解析器和真实世界的 tar/zip 一致」——
/// 后者才是它要面对的东西（权限位、长文件名、软链、硬链接、PAX 头
/// 这些恰恰是手写时最容易想当然的地方）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:burrow/src/bootstrap/tar_reader.dart';
import 'package:burrow/src/bootstrap/zip_reader.dart';

/// 系统上有没有可用的 tar / zip。Windows 10+ 自带 bsdtar（tar.exe）。
Future<bool> _has(String exe) async {
  try {
    final r = await Process.run(exe, ['--version']);
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}

void main() {
  group('ZipReader', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('pa_zip_');
    });
    tearDown(() async => tmp.delete(recursive: true));

    test('解析 central directory：条目数、名字、内容', () async {
      // 用 Dart 自己造一个最小但合规的 zip（stored + deflate 各一个），
      // 这样这条用例在任何平台都能跑，不依赖系统工具。
      final zip = File('${tmp.path}/t.zip');
      await zip.writeAsBytes(_buildZip({
        'hello.txt': utf8.encode('hello world'),
        'nested/dir/data.bin': List<int>.generate(5000, (i) => i % 251),
      }));

      final r = await ZipReader.open(zip);
      addTearDown(r.close);

      final entries = await r.entries();
      expect(entries.length, 2);
      expect(await r.entryCount, 2,
          reason: '条目数必须在解压前就能拿到，否则没法显示进度');

      final hello = entries.firstWhere((e) => e.name == 'hello.txt');
      expect(utf8.decode(await r.read(hello)), 'hello world');

      // 这个足够大，会被 deflate 压缩，走的是和 stored 不同的解码路径
      final data = entries.firstWhere((e) => e.name == 'nested/dir/data.bin');
      final bytes = await r.read(data);
      expect(bytes.length, 5000);
      expect(bytes[0], 0);
      expect(bytes[4999], 4999 % 251);
    });

    test('保留 Unix 权限位', () async {
      if (!Platform.isLinux && !Platform.isMacOS) {
        return; // Windows 上造不出带 Unix 权限的 zip
      }
      final src = Directory('${tmp.path}/src')..createSync();
      File('${src.path}/run.sh').writeAsStringSync('#!/bin/sh\necho hi\n');
      await Process.run('chmod', ['755', '${src.path}/run.sh']);
      await Process.run('zip', ['-r', '../t.zip', '.'],
          workingDirectory: src.path);

      final r = await ZipReader.open(File('${tmp.path}/t.zip'));
      addTearDown(r.close);
      final e = (await r.entries()).firstWhere((x) => x.name.endsWith('run.sh'));
      expect(e.mode & 0x49, isNot(0),
          reason: '丢了执行位的话解出来的 bin/bash 跑不起来，整个环境是废的');
    });

    test('EOCD 后面有注释也能找到', () async {
      final base = _buildZip({'a.txt': utf8.encode('A')});
      // 追加注释：改 EOCD 的 comment length 字段并把注释接在后面
      final comment = utf8.encode('x' * 300);
      final withComment = Uint8List(base.length + comment.length);
      withComment.setAll(0, base);
      withComment.setAll(base.length, comment);
      final b = withComment.buffer.asByteData();
      b.setUint16(base.length - 2, comment.length, Endian.little);

      final zip = File('${tmp.path}/c.zip');
      await zip.writeAsBytes(withComment);
      final r = await ZipReader.open(zip);
      addTearDown(r.close);
      expect((await r.entries()).length, 1);
    });

    test('不是 zip 就明确报错，而不是解出垃圾', () async {
      final f = File('${tmp.path}/junk.bin');
      await f.writeAsBytes(List<int>.filled(1000, 0x41));
      final r = await ZipReader.open(f);
      addTearDown(r.close);
      expect(() => r.entries(), throwsA(isA<ZipFormatException>()));
    });
  });

  group('TarReader', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('pa_tar_');
    });
    tearDown(() async => tmp.delete(recursive: true));

    /// 用系统 tar 造一个带各种特殊条目的归档。
    Future<File?> buildRealTar() async {
      if (!await _has('tar')) return null;
      final src = Directory('${tmp.path}/src')..createSync();
      File('${src.path}/plain.txt').writeAsStringSync('plain content');
      Directory('${src.path}/sub').createSync();
      File('${src.path}/sub/nested.txt').writeAsStringSync('nested');

      // 超过 100 字节的路径 —— 强制 tar 走 GNU 'L' 或 PAX 长名分支
      final longDir = Directory('${src.path}/${'d' * 60}/${'e' * 60}')
        ..createSync(recursive: true);
      File('${longDir.path}/deep.txt').writeAsStringSync('deep');

      if (Platform.isLinux || Platform.isMacOS) {
        await Process.run('ln', ['-s', 'plain.txt', '${src.path}/link.txt']);
        await Process.run('ln', ['${src.path}/plain.txt', '${src.path}/hard.txt']);
        await Process.run('chmod', ['755', '${src.path}/plain.txt']);
      }

      final out = File('${tmp.path}/t.tar.gz');
      final r = await Process.run(
          'tar', ['-czf', out.path, '-C', src.path, '.']);
      if (r.exitCode != 0) return null;
      return out;
    }

    test('解析真实 tar.gz：普通文件、目录、长路径', () async {
      final archive = await buildRealTar();
      if (archive == null) {
        markTestSkipped('系统上没有可用的 tar');
        return;
      }

      final seen = <String, String>{};
      final types = <String, TarEntryType>{};
      await TarReader.extract(
        archive.openRead(),
        onEntry: (e, content) async {
          types[e.name] = e.type;
          if (content != null) {
            seen[e.name] = utf8.decode(content, allowMalformed: true);
          }
        },
      );

      expect(seen['plain.txt'], 'plain content');
      expect(seen['sub/nested.txt'], 'nested');
      expect(types['sub'], TarEntryType.directory);

      // 长路径：>100 字节，必须走 GNU 'L' 或 PAX 分支才读得对
      final deep = seen.keys.firstWhere((k) => k.endsWith('deep.txt'),
          orElse: () => '');
      expect(deep, isNotEmpty,
          reason: '超长路径没解出来 —— GNU long name / PAX 分支有问题');
      expect(deep.length, greaterThan(100));
      expect(seen[deep], 'deep');
    });

    test('识别软链和硬链接', () async {
      if (!Platform.isLinux && !Platform.isMacOS) {
        markTestSkipped('Windows 上造不出软链/硬链接');
        return;
      }
      final archive = await buildRealTar();
      if (archive == null) {
        markTestSkipped('系统上没有可用的 tar');
        return;
      }

      final types = <String, TarEntryType>{};
      final links = <String, String>{};
      await TarReader.extract(
        archive.openRead(),
        onEntry: (e, _) async {
          types[e.name] = e.type;
          if (e.linkTarget.isNotEmpty) links[e.name] = e.linkTarget;
        },
      );

      expect(types['link.txt'], TarEntryType.symlink);
      expect(links['link.txt'], 'plain.txt');
      // 硬链接必须和普通文件区分开：rootfs 里 busybox 的几百个命令全靠它
      expect(types['hard.txt'], TarEntryType.hardlink);
    });

    test('保留执行位', () async {
      if (!Platform.isLinux && !Platform.isMacOS) {
        markTestSkipped('Windows 上没有 Unix 权限');
        return;
      }
      final archive = await buildRealTar();
      if (archive == null) {
        markTestSkipped('系统上没有可用的 tar');
        return;
      }
      var mode = 0;
      await TarReader.extract(archive.openRead(), onEntry: (e, _) async {
        if (e.name == 'plain.txt') mode = e.mode;
      });
      expect(mode & 0x49, isNot(0));
    });

    test('软链目录是常态，不能一见到就拒绝', () async {
      // Ubuntu 的 rootfs 自带 `bin -> usr/bin`（usr-merge）。
      // 如果解压器把「父目录是软链」一律当成攻击，Ubuntu 根本装不上。
      // 这条用例守住的是「别把正常情况误判成攻击」这一半 ——
      // 另一半（真的穿透到 root 外要拒绝）在 DistroManager 里，
      // 需要能建软链的平台才测得了。
      if (!Platform.isLinux && !Platform.isMacOS) {
        markTestSkipped('Windows 上造不出软链');
        return;
      }
      final src = Directory('${tmp.path}/src')..createSync();
      Directory('${src.path}/usr/bin').createSync(recursive: true);
      File('${src.path}/usr/bin/sh').writeAsStringSync('#!/bin/sh\n');
      await Process.run('ln', ['-s', 'usr/bin', '${src.path}/bin']);

      final out = File('${tmp.path}/merged.tar.gz');
      final r = await Process.run(
          'tar', ['-czf', out.path, '-C', src.path, '.']);
      if (r.exitCode != 0) {
        markTestSkipped('系统上没有可用的 tar');
        return;
      }

      final types = <String, TarEntryType>{};
      final links = <String, String>{};
      await TarReader.extract(out.openRead(), onEntry: (e, _) async {
        types[e.name] = e.type;
        if (e.linkTarget.isNotEmpty) links[e.name] = e.linkTarget;
      });

      expect(types['bin'], TarEntryType.symlink);
      expect(links['bin'], 'usr/bin');
      expect(types['usr/bin/sh'], TarEntryType.regular);
    });

    test('八进制数值字段解析', () {
      // 手工构造一个最小 header 验证数值解析 —— 这一层是纯计算，
      // 用真实归档反而不好定位是哪一步错了。
      final h = Uint8List(512);
      // name = "x"
      h[0] = 0x78;
      // size 字段（offset 124，12 字节）= 八进制 "00000000173 " = 123
      const sizeStr = '00000000173 ';
      for (var i = 0; i < sizeStr.length; i++) {
        h[124 + i] = sizeStr.codeUnitAt(i);
      }
      // mode（offset 100，8 字节）= "0000755 "
      const modeStr = '0000755 ';
      for (var i = 0; i < modeStr.length; i++) {
        h[100 + i] = modeStr.codeUnitAt(i);
      }
      h[156] = 0x30; // typeflag '0'

      // 走一遍真实路径：header + 一个数据块 + 结束标记
      final data = Uint8List(512);
      final end = Uint8List(1024);
      final raw = Uint8List.fromList([...h, ...data, ...end]);

      final gz = gzip.encode(raw);
      TarEntry? got;
      TarReader.extract(
        Stream.value(gz),
        onEntry: (e, _) async => got = e,
      ).then((_) {
        expect(got, isNotNull);
        expect(got!.size, 123);
        expect(got!.mode, 0x1ED); // 0755
      });
    });
  });
}

// ---------------------------------------------------------------------------
// 一个最小的 zip 构造器，只为测试用。
// stored + deflate 两种方法各覆盖一次。
// ---------------------------------------------------------------------------

Uint8List _buildZip(Map<String, List<int>> files) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  var offset = 0;
  var count = 0;

  files.forEach((name, content) {
    final nameBytes = utf8.encode(name);
    // 小文件用 stored，大文件用 deflate —— 两条解码路径都要被走到
    final useDeflate = content.length > 100;
    final stored = useDeflate
        ? ZLibCodec(raw: true).encode(content)
        : content;
    final crc = _crc32(content);

    final local = BytesBuilder();
    final lh = ByteData(30);
    lh.setUint32(0, 0x04034b50, Endian.little);
    lh.setUint16(4, 20, Endian.little);
    lh.setUint16(8, useDeflate ? 8 : 0, Endian.little);
    lh.setUint32(14, crc, Endian.little);
    lh.setUint32(18, stored.length, Endian.little);
    lh.setUint32(22, content.length, Endian.little);
    lh.setUint16(26, nameBytes.length, Endian.little);
    local.add(lh.buffer.asUint8List());
    local.add(nameBytes);
    local.add(stored);
    final localBytes = local.takeBytes();
    out.add(localBytes);

    final ch = ByteData(46);
    ch.setUint32(0, 0x02014b50, Endian.little);
    ch.setUint16(4, (3 << 8) | 20, Endian.little); // made by Unix
    ch.setUint16(6, 20, Endian.little);
    ch.setUint16(10, useDeflate ? 8 : 0, Endian.little);
    ch.setUint32(16, crc, Endian.little);
    ch.setUint32(20, stored.length, Endian.little);
    ch.setUint32(24, content.length, Endian.little);
    ch.setUint16(28, nameBytes.length, Endian.little);
    ch.setUint32(38, 0x81A4 << 16, Endian.little); // 0100644
    ch.setUint32(42, offset, Endian.little);
    central.add(ch.buffer.asUint8List());
    central.add(nameBytes);

    offset += localBytes.length;
    count++;
  });

  final cdBytes = central.takeBytes();
  final cdOffset = offset;
  out.add(cdBytes);

  final eocd = ByteData(22);
  eocd.setUint32(0, 0x06054b50, Endian.little);
  eocd.setUint16(8, count, Endian.little);
  eocd.setUint16(10, count, Endian.little);
  eocd.setUint32(12, cdBytes.length, Endian.little);
  eocd.setUint32(16, cdOffset, Endian.little);
  out.add(eocd.buffer.asUint8List());

  return out.takeBytes();
}

int _crc32(List<int> data) {
  var crc = 0xFFFFFFFF;
  for (final b in data) {
    crc ^= b;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return crc ^ 0xFFFFFFFF;
}
