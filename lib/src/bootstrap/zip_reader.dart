/// 低内存 zip 读取：走 central directory 随机访问，而不是从头流式扫描。
///
/// ## 为什么不用 package:archive
///
/// bootstrap / rootfs 这类归档有几万个条目、解开几百 MB。`package:archive`
/// 的 `ZipDecoder.decodeBytes` 会把整个归档连同解压结果一起留在内存里，
/// 峰值轻松上几百 MB —— 中低端机直接 OOM。
///
/// ## 为什么走 central directory 而不是顺序读 local header
///
/// 顺序读也能工作，但拿不到两样东西：
///   1. **条目总数** —— 没有它就没法显示解压进度，用户面对一个不动的转圈
///      会以为卡死了（几万个文件要解好几分钟）。
///   2. **Unix 权限位** —— 它在 central directory 的 `externalFileAttributes`
///      高 16 位里，local header 里根本没有。丢了权限位，解出来的
///      `bin/bash` 不可执行，整个环境是废的。
///
/// central directory 在文件末尾，一次 seek 就能拿到全部元数据，
/// 之后按需 seek 到各个条目取数据。内存占用是「最大的单个文件」而不是「整个归档」。
///
/// ## ZIP64
///
/// 必须支持。经典 zip 的条目数字段是 16 位，上限 65535；
/// 一个完整的发行版 rootfs 轻松超过这个数。超了之后经典字段填 0xFFFF，
/// 真实值在 ZIP64 记录里 —— 不解析 ZIP64 的话会静默地只解出一部分文件。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 一条 zip 条目的元数据（不含内容）。
class ZipEntry {
  final String name;

  /// 未压缩大小。
  final int size;

  /// Unix 权限位（`st_mode` 的低 12 位）。0 表示归档里没有权限信息
  /// （Windows 工具打的包常常如此），调用方应自行取默认值。
  final int mode;

  /// 从 `st_mode` 的文件类型位判定。
  final bool isDirectory;
  final bool isSymlink;

  /// 压缩方法：0 = stored，8 = deflate。其它值不支持。
  final int method;

  final int compressedSize;

  /// local header 在文件中的偏移。读内容时从这里开始。
  final int localHeaderOffset;

  const ZipEntry({
    required this.name,
    required this.size,
    required this.mode,
    required this.isDirectory,
    required this.isSymlink,
    required this.method,
    required this.compressedSize,
    required this.localHeaderOffset,
  });
}

class ZipFormatException implements Exception {
  final String message;
  const ZipFormatException(this.message);
  @override
  String toString() => 'zip 格式错误：$message';
}

class ZipReader {
  final RandomAccessFile _file;
  final int _length;
  List<ZipEntry>? _entries;

  ZipReader._(this._file, this._length);

  static Future<ZipReader> open(File f) async {
    final raf = await f.open();
    return ZipReader._(raf, await f.length());
  }

  Future<void> close() => _file.close();

  /// 条目总数。用于进度显示，所以在解压之前就要能拿到。
  Future<int> get entryCount async => (await entries()).length;

  /// 解析 central directory。结果缓存。
  Future<List<ZipEntry>> entries() async {
    if (_entries != null) return _entries!;

    final eocd = await _findEocd();
    var totalEntries = eocd.totalEntries;
    var cdOffset = eocd.cdOffset;

    // 经典字段被 0xFFFF / 0xFFFFFFFF 顶满时，真值在 ZIP64 记录里。
    if (totalEntries == 0xFFFF || cdOffset == 0xFFFFFFFF) {
      final z64 = await _findZip64Eocd(eocd.eocdOffset);
      if (z64 != null) {
        totalEntries = z64.totalEntries;
        cdOffset = z64.cdOffset;
      }
    }

    final result = <ZipEntry>[];
    var offset = cdOffset;

    for (var i = 0; i < totalEntries; i++) {
      final head = await _readAt(offset, 46);
      final b = head.buffer.asByteData();
      if (b.getUint32(0, Endian.little) != 0x02014b50) {
        throw ZipFormatException('第 $i 个 central directory 条目签名不对（偏移 $offset）');
      }

      final versionMadeBy = b.getUint16(4, Endian.little);
      final method = b.getUint16(10, Endian.little);
      var compressedSize = b.getUint32(20, Endian.little);
      var uncompressedSize = b.getUint32(24, Endian.little);
      final nameLen = b.getUint16(28, Endian.little);
      final extraLen = b.getUint16(30, Endian.little);
      final commentLen = b.getUint16(32, Endian.little);
      final externalAttrs = b.getUint32(38, Endian.little);
      var localOffset = b.getUint32(42, Endian.little);

      final varPart = await _readAt(offset + 46, nameLen + extraLen);
      final name = _decodeName(
          varPart.sublist(0, nameLen), b.getUint16(8, Endian.little));

      // ZIP64 extra field：只补那些被 0xFFFFFFFF 顶满的字段，且顺序固定。
      if (uncompressedSize == 0xFFFFFFFF ||
          compressedSize == 0xFFFFFFFF ||
          localOffset == 0xFFFFFFFF) {
        final z = _parseZip64Extra(
          varPart.sublist(nameLen),
          needUncompressed: uncompressedSize == 0xFFFFFFFF,
          needCompressed: compressedSize == 0xFFFFFFFF,
          needOffset: localOffset == 0xFFFFFFFF,
        );
        uncompressedSize = z.uncompressed ?? uncompressedSize;
        compressedSize = z.compressed ?? compressedSize;
        localOffset = z.offset ?? localOffset;
      }

      // Unix 权限在高 16 位，且只有「made by」标明是 Unix (3) 时才有效。
      // 别无条件取高 16 位 —— Windows 打的包那里是 0，会得到 mode 0
      // 也就是谁都不能读的文件。
      final madeByUnix = (versionMadeBy >> 8) == 3;
      final unixMode = madeByUnix ? (externalAttrs >> 16) & 0xFFFF : 0;
      final fileType = unixMode & 0xF000;

      result.add(ZipEntry(
        name: name,
        size: uncompressedSize,
        mode: unixMode & 0xFFF,
        // 目录判定两条都认：Unix 类型位，以及以 / 结尾这个通用约定。
        isDirectory: fileType == 0x4000 || name.endsWith('/'),
        isSymlink: fileType == 0xA000,
        method: method,
        compressedSize: compressedSize,
        localHeaderOffset: localOffset,
      ));

      offset += 46 + nameLen + extraLen + commentLen;
    }

    return _entries = result;
  }

  /// 读一个条目的内容。
  ///
  /// 必须重新解析 local header 才能知道数据从哪开始 ——
  /// local header 的 nameLen/extraLen 和 central directory 里的**可以不同**
  /// （extra field 里的对齐填充只出现在 local header），直接用 CD 的长度算
  /// 会读到偏移错位的垃圾数据。
  Future<Uint8List> read(ZipEntry entry) async {
    final head = await _readAt(entry.localHeaderOffset, 30);
    final b = head.buffer.asByteData();
    if (b.getUint32(0, Endian.little) != 0x04034b50) {
      throw ZipFormatException('${entry.name} 的 local header 签名不对');
    }
    final nameLen = b.getUint16(26, Endian.little);
    final extraLen = b.getUint16(28, Endian.little);
    final dataOffset = entry.localHeaderOffset + 30 + nameLen + extraLen;

    final raw = await _readAt(dataOffset, entry.compressedSize);

    switch (entry.method) {
      case 0:
        return raw;
      case 8:
        // raw: true = 裸 deflate 流，没有 zlib 头。zip 存的就是裸流，
        // 用默认的 ZLibCodec 会因为找不到 zlib 头而报 "invalid argument"。
        return Uint8List.fromList(ZLibCodec(raw: true).decode(raw));
      default:
        throw ZipFormatException('${entry.name} 用了不支持的压缩方法 ${entry.method}'
            '（只支持 0=stored 和 8=deflate）');
    }
  }

  /// 符号链接的目标。zip 把它存成文件内容。
  Future<String> readLinkTarget(ZipEntry entry) async =>
      utf8.decode(await read(entry), allowMalformed: true);

  // ---------------------------------------------------------------------

  Future<Uint8List> _readAt(int offset, int length) async {
    if (length == 0) return Uint8List(0);
    await _file.setPosition(offset);
    final buf = await _file.read(length);
    if (buf.length != length) {
      throw ZipFormatException(
          '偏移 $offset 处要读 $length 字节，只读到 ${buf.length}（文件被截断？）');
    }
    return buf;
  }

  static String _decodeName(Uint8List bytes, int flags) {
    // bit 11 = EFS，表示文件名是 UTF-8。没置位时理论上是 CP437，
    // 但现代工具几乎都写 UTF-8，所以一律按 UTF-8 宽松解码。
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// 从文件末尾往回找 EOCD 签名。
  ///
  /// 不能直接读最后 22 字节 —— EOCD 后面可以跟最多 65535 字节的注释。
  /// 所以最多回扫 64KB+22。
  Future<_Eocd> _findEocd() async {
    const maxComment = 0xFFFF;
    final scanLen = (maxComment + 22).clamp(0, _length);
    final start = _length - scanLen;
    final buf = await _readAt(start, scanLen);

    for (var i = buf.length - 22; i >= 0; i--) {
      if (buf[i] == 0x50 &&
          buf[i + 1] == 0x4b &&
          buf[i + 2] == 0x05 &&
          buf[i + 3] == 0x06) {
        final b = buf.buffer.asByteData(buf.offsetInBytes + i, 22);
        return _Eocd(
          eocdOffset: start + i,
          totalEntries: b.getUint16(10, Endian.little),
          cdOffset: b.getUint32(16, Endian.little),
        );
      }
    }
    throw const ZipFormatException('找不到 EOCD 记录，这不是一个 zip 文件');
  }

  /// ZIP64 EOCD locator 紧挨在经典 EOCD 之前，固定 20 字节。
  Future<_Eocd?> _findZip64Eocd(int eocdOffset) async {
    final locatorOffset = eocdOffset - 20;
    if (locatorOffset < 0) return null;

    final loc = await _readAt(locatorOffset, 20);
    final lb = loc.buffer.asByteData();
    if (lb.getUint32(0, Endian.little) != 0x07064b50) return null;

    final z64Offset = lb.getUint64(8, Endian.little);
    final rec = await _readAt(z64Offset, 56);
    final rb = rec.buffer.asByteData();
    if (rb.getUint32(0, Endian.little) != 0x06064b50) {
      throw const ZipFormatException('ZIP64 EOCD 签名不对');
    }
    return _Eocd(
      eocdOffset: z64Offset,
      totalEntries: rb.getUint64(32, Endian.little),
      cdOffset: rb.getUint64(48, Endian.little),
    );
  }

  /// ZIP64 extra field（header id 0x0001）里的字段**没有独立标记**，
  /// 只按固定顺序出现，且只出现那些在经典字段里被顶满的。
  /// 所以必须把「哪几个需要补」传进来才能正确定位。
  static _Zip64Sizes _parseZip64Extra(
    Uint8List extra, {
    required bool needUncompressed,
    required bool needCompressed,
    required bool needOffset,
  }) {
    var i = 0;
    while (i + 4 <= extra.length) {
      final b = extra.buffer.asByteData(extra.offsetInBytes + i);
      final id = b.getUint16(0, Endian.little);
      final len = b.getUint16(2, Endian.little);
      if (id == 0x0001) {
        final data = extra.buffer.asByteData(extra.offsetInBytes + i + 4, len);
        var p = 0;
        int? uncompressed, compressed, offset;
        if (needUncompressed && p + 8 <= len) {
          uncompressed = data.getUint64(p, Endian.little);
          p += 8;
        }
        if (needCompressed && p + 8 <= len) {
          compressed = data.getUint64(p, Endian.little);
          p += 8;
        }
        if (needOffset && p + 8 <= len) {
          offset = data.getUint64(p, Endian.little);
        }
        return _Zip64Sizes(uncompressed, compressed, offset);
      }
      i += 4 + len;
    }
    return const _Zip64Sizes(null, null, null);
  }
}

class _Eocd {
  final int eocdOffset;
  final int totalEntries;
  final int cdOffset;
  const _Eocd({
    required this.eocdOffset,
    required this.totalEntries,
    required this.cdOffset,
  });
}

class _Zip64Sizes {
  final int? uncompressed;
  final int? compressed;
  final int? offset;
  const _Zip64Sizes(this.uncompressed, this.compressed, this.offset);
}
