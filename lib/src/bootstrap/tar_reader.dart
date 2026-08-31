/// 流式 tar 读取。发行版 rootfs（Alpine / Debian / Ubuntu base）都是 tar.gz。
///
/// ## 为什么流式而不是随机访问
///
/// 和 zip 相反：tar 没有中央目录，元数据散在每个条目前面的 512 字节头里，
/// 而且外面还套着一层 gzip —— gzip 流不能随机 seek。所以只能从头顺序读一遍。
/// 好在解压 rootfs 本来就是一次性全量操作，顺序读正合适。
///
/// 代价是**拿不到条目总数**，进度只能按已解压字节数除以归档大小来估。
///
/// ## 必须处理的四类特殊情况
///
/// 真实的发行版 rootfs 里全都有，漏掉任何一个都会得到一个坏掉的环境：
///
///   1. **GNU 长文件名（typeflag 'L'）** —— 经典 tar 头的 name 字段只有 100 字节，
///      超了就先发一个 'L' 条目把真名当内容传。Debian/Ubuntu 的 rootfs 里
///      `usr/share/doc/...` 一堆路径超长。
///   2. **PAX 扩展头（'x' / 'g'）** —— 现代 tar 用它存长路径和大文件尺寸，
///      格式是 `长度 键=值\n`。Ubuntu base 用的就是这个。
///   3. **硬链接（'1'）** —— rootfs 里大量存在（busybox 的几百个命令全是
///      指向同一个 inode 的硬链接）。当成普通文件跳过会丢命令，
///      当成符号链接又会在原文件被删时断掉。
///   4. **设备节点（'3' / '4'）** —— 无 root 时 `mknod` 必然失败。
///      必须**明确跳过并记录**，不能让它抛异常中断整个解压。
///
/// ## base-256 数值
///
/// tar 的数值字段是八进制 ASCII，但超过字段宽度时 GNU 用 base-256 编码
/// （最高位置 1）。大文件（>8GB）和大 uid 会触发。不处理会解析出负数尺寸。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

enum TarEntryType {
  regular,
  directory,
  symlink,
  hardlink,

  /// 设备节点 / fifo / socket —— 无 root 建不了，一律跳过。
  unsupported,
}

class TarEntry {
  final String name;
  final TarEntryType type;
  final int size;
  final int mode;

  /// symlink / hardlink 的目标。
  final String linkTarget;

  const TarEntry({
    required this.name,
    required this.type,
    required this.size,
    required this.mode,
    this.linkTarget = '',
  });
}

class TarFormatException implements Exception {
  final String message;
  const TarFormatException(this.message);
  @override
  String toString() => 'tar 格式错误：$message';
}

/// 把任意分块的字节流重新组织成「按需读 N 字节」。
///
/// gzip 解码器吐出来的块大小完全不可预测，而 tar 要求严格按 512 字节边界读，
/// 中间夹着任意长度的文件数据。没有这一层就得在每个读取点手写跨块拼接。
class _ByteStreamReader {
  final StreamIterator<List<int>> _it;
  final List<int> _buf = [];
  var _done = false;
  var _consumed = 0;

  _ByteStreamReader(Stream<List<int>> stream) : _it = StreamIterator(stream);

  /// 已消费的字节数，用于估算进度。
  int get consumed => _consumed;

  Future<bool> _fill(int need) async {
    while (_buf.length < need) {
      if (_done) return false;
      if (!await _it.moveNext()) {
        _done = true;
        return false;
      }
      _buf.addAll(_it.current);
    }
    return true;
  }

  /// 读 [n] 字节。流已结束且不足 n 时返回 null。
  Future<Uint8List?> read(int n) async {
    if (n == 0) return Uint8List(0);
    if (!await _fill(n)) return null;
    final out = Uint8List.fromList(_buf.sublist(0, n));
    _buf.removeRange(0, n);
    _consumed += n;
    return out;
  }

  /// 跳过 [n] 字节。比 read 少一次拷贝 —— 解压时要跳过大量填充字节。
  Future<void> skip(int n) async {
    var remaining = n;
    while (remaining > 0) {
      if (_buf.isEmpty && !await _fill(1)) return;
      final take = remaining < _buf.length ? remaining : _buf.length;
      _buf.removeRange(0, take);
      remaining -= take;
      _consumed += take;
    }
  }

  Future<void> cancel() => _it.cancel();
}

class TarReader {
  /// 逐条读出 tar 条目。
  ///
  /// [onEntry] 对每个条目调用一次；regular 类型会额外传入内容。
  /// 内容按条目逐个读进内存 —— rootfs 里单个文件通常几 MB 以内，
  /// 而整个归档几百 MB，所以「单文件进内存」和「整包进内存」差着两个数量级。
  ///
  /// 遇到设备节点等建不了的类型时调用 [onSkipped] 而不是抛异常：
  /// 一个 `/dev/null` 建不出来不该让整个发行版解压失败。
  static Future<void> extract(
    Stream<List<int>> inputStream, {
    bool gzipCompressed = true,
    required Future<void> Function(TarEntry entry, Uint8List? content) onEntry,
    void Function(TarEntry entry, String reason)? onSkipped,
    void Function(int bytesRead)? onProgress,
  }) async {
    final reader = _ByteStreamReader(
      gzipCompressed ? inputStream.transform(gzip.decoder) : inputStream,
    );

    // GNU 'L'/'K' 和 PAX 会给**下一个**条目提供覆盖值，读到后暂存在这里。
    String? pendingLongName;
    String? pendingLongLink;
    Map<String, String> pendingPax = {};

    try {
      while (true) {
        final header = await reader.read(512);
        if (header == null) break;

        // 两个连续的全零块 = 归档结束。实践中很多 tar 只写一个，
        // 或者结尾被截断，所以见到一个全零块就收手。
        if (_isAllZero(header)) break;

        final rawName = _str(header, 0, 100);
        final mode = _num(header, 100, 8);
        final size = _num(header, 124, 12);
        final typeflag = header[156];
        final rawLink = _str(header, 157, 100);
        final prefix = _str(header, 345, 155); // ustar 的路径前缀

        final dataBlocks = ((size + 511) ~/ 512) * 512;

        // --- 元数据条目：读完内容后 continue，不产出 TarEntry ---

        if (typeflag == 0x4C) {
          // 'L' GNU long name
          final body = await reader.read(dataBlocks);
          pendingLongName = _cstr(body!.sublist(0, size));
          continue;
        }
        if (typeflag == 0x4B) {
          // 'K' GNU long link
          final body = await reader.read(dataBlocks);
          pendingLongLink = _cstr(body!.sublist(0, size));
          continue;
        }
        if (typeflag == 0x78 || typeflag == 0x67) {
          // 'x' / 'g' PAX
          final body = await reader.read(dataBlocks);
          final pax = _parsePax(body!.sublist(0, size));
          // 'g' 是全局的，'x' 只作用于下一条。这里一律当成只作用于下一条 ——
          // rootfs 归档里没见过真正依赖全局 PAX 的，而按全局处理一旦出错
          // 会污染后面所有条目。
          pendingPax = pax;
          continue;
        }

        // --- 真实条目 ---

        var name = pendingLongName ??
            pendingPax['path'] ??
            (prefix.isEmpty ? rawName : '$prefix/$rawName');
        var link = pendingLongLink ?? pendingPax['linkpath'] ?? rawLink;
        final realSize = int.tryParse(pendingPax['size'] ?? '') ?? size;

        pendingLongName = null;
        pendingLongLink = null;
        pendingPax = {};

        // 归档里的 './' 前缀在 Debian/Ubuntu 的 rootfs 里到处都是。
        // 不剥掉会得到 rootfs/./usr/bin 这种路径，虽然能用但很脏，
        // 而且和后面的路径逃逸检查对不上。
        if (name.startsWith('./')) name = name.substring(2);
        // tar 把目录存成 `sub/`（带尾斜杠）。不剥掉的话同一个目录在
        // 「目录条目」和「它下面文件的父路径」两处拼出来的字符串不一致，
        // 任何以路径为键的去重、比对、白名单都会漏。
        while (name.length > 1 && name.endsWith('/')) {
          name = name.substring(0, name.length - 1);
        }
        if (name.isEmpty || name == '.') {
          await reader.skip(dataBlocks);
          continue;
        }

        final type = switch (typeflag) {
          0x30 ||
          0x00 ||
          0x37 =>
            TarEntryType.regular, // '0', NUL, '7'(contiguous)
          0x31 => TarEntryType.hardlink, // '1'
          0x32 => TarEntryType.symlink, // '2'
          0x35 => TarEntryType.directory, // '5'
          _ => TarEntryType.unsupported, // '3','4','6' 设备/fifo
        };

        final entry = TarEntry(
          name: name,
          type: type,
          size: realSize,
          mode: mode & 0xFFF,
          linkTarget: link,
        );

        if (type == TarEntryType.unsupported) {
          onSkipped?.call(entry, '设备节点或 fifo，无 root 无法创建');
          await reader.skip(dataBlocks);
        } else if (type == TarEntryType.regular) {
          final body = await reader.read(dataBlocks);
          if (body == null) {
            throw TarFormatException('$name 的数据被截断');
          }
          await onEntry(entry, body.sublist(0, realSize));
        } else {
          await onEntry(entry, null);
          await reader.skip(dataBlocks);
        }

        onProgress?.call(reader.consumed);
      }
    } finally {
      await reader.cancel();
    }
  }

  // ---------------------------------------------------------------------

  static bool _isAllZero(Uint8List b) {
    for (final byte in b) {
      if (byte != 0) return false;
    }
    return true;
  }

  /// 读一个以 NUL 或空格结尾的字符串字段。
  static String _str(Uint8List b, int offset, int len) {
    var end = offset;
    final limit = offset + len;
    while (end < limit && b[end] != 0) {
      end++;
    }
    return utf8.decode(b.sublist(offset, end), allowMalformed: true).trim();
  }

  static String _cstr(Uint8List b) {
    var end = b.length;
    while (end > 0 && b[end - 1] == 0) {
      end--;
    }
    return utf8.decode(b.sublist(0, end), allowMalformed: true);
  }

  /// 数值字段：通常是八进制 ASCII，但 GNU 在超宽时改用 base-256
  /// （首字节最高位置 1，其余字节是大端二进制）。
  static int _num(Uint8List b, int offset, int len) {
    if (b[offset] & 0x80 != 0) {
      var v = b[offset] & 0x7F;
      for (var i = offset + 1; i < offset + len; i++) {
        v = (v << 8) | b[i];
      }
      return v;
    }
    final s = _str(b, offset, len).replaceAll(RegExp(r'[^0-7]'), '');
    if (s.isEmpty) return 0;
    return int.parse(s, radix: 8);
  }

  /// PAX 记录格式：`<十进制总长> <键>=<值>\n`，可以有多条。
  /// 总长包含它自己那几位数字和空格 —— 这是个容易写错的地方。
  static Map<String, String> _parsePax(Uint8List body) {
    final out = <String, String>{};
    var i = 0;
    while (i < body.length) {
      var j = i;
      while (j < body.length && body[j] != 0x20) {
        j++;
      }
      if (j >= body.length) break;
      final lenStr = utf8.decode(body.sublist(i, j), allowMalformed: true);
      final recLen = int.tryParse(lenStr);
      if (recLen == null || recLen <= 0 || i + recLen > body.length) break;

      final rec = utf8.decode(body.sublist(j + 1, i + recLen - 1),
          allowMalformed: true);
      final eq = rec.indexOf('=');
      if (eq > 0) out[rec.substring(0, eq)] = rec.substring(eq + 1);
      i += recLen;
    }
    return out;
  }
}
