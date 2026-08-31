/// DistroManager 的安装流程测试。
///
/// 重点是**越界检查不能误伤**。这一层有两个方向的失败，两个都致命：
///   - 漏放行：正常的发行版装不上（用户看到「可能是恶意归档」，一头雾水）
///   - 漏拦截：恶意归档穿透软链写到 app 目录外
/// 所以两个方向都要有用例守着。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:burrow/src/bootstrap/distro.dart';

/// 造一个测试用的发行版条目。sha256 留空 = 开发期路径，只告警不拦截。
Distro _testDistro(String url) => Distro(
      id: 'test-distro',
      displayName: 'Test',
      description: '',
      rootfsUrls: {'x86_64': url},
      sha256: const {},
      approxInstalledBytes: 1024,
      packageManager: 'apk',
    );

DistroManager _manager(Directory root, File archive) => DistroManager(
      root: root,
      abi: 'x86_64',
      // 不去 CDN 拉，直接喂本地文件 —— 这正是 fetch 做成可注入的理由。
      fetch: (_) async => archive.openRead(),
    );

Future<bool> _hasTar() async {
  try {
    return (await Process.run('tar', ['--version'])).exitCode == 0;
  } catch (_) {
    return false;
  }
}

void main() {
  late Directory tmp;

  setUp(() async => tmp = await Directory.systemTemp.createTemp('pa_distro_'));
  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {
      // Windows 上软链/占用偶尔删不掉，不该让清理失败盖过真正的断言结果。
    }
  });

  /// 造一个像真发行版的最小 rootfs 归档：
  /// 有 tmp 目录、有 usr-merge 风格的软链、有普通文件。
  Future<File?> buildRootfsArchive() async {
    if (!await _hasTar()) return null;
    final src = Directory('${tmp.path}/src')..createSync();
    Directory('${src.path}/tmp').createSync();
    Directory('${src.path}/usr/bin').createSync(recursive: true);
    File('${src.path}/usr/bin/busybox').writeAsStringSync('#!/bin/sh\n');
    File('${src.path}/etc/hosts')
      ..createSync(recursive: true)
      ..writeAsStringSync('127.0.0.1 localhost\n');
    if (Platform.isLinux || Platform.isMacOS) {
      // Alpine / Ubuntu 的 rootfs 里都有这类软链，解压器必须放行
      await Process.run('ln', ['-s', 'usr/bin', '${src.path}/bin']);
      await Process.run('ln', ['-s', '/bin/busybox', '${src.path}/usr/bin/sh']);
    }
    final out = File('${tmp.path}/rootfs.tar.gz');
    final r = await Process.run('tar', ['-czf', out.path, '-C', src.path, '.']);
    return r.exitCode == 0 ? out : null;
  }

  test('根目录本身经软链可达时也能装（Android 的 /data/user/0）', () async {
    if (!Platform.isLinux && !Platform.isMacOS) {
      markTestSkipped('Windows 上造不出软链，复现不了这个场景');
      return;
    }
    final archive = await buildRootfsArchive();
    if (archive == null) {
      markTestSkipped('系统上没有可用的 tar');
      return;
    }

    // 复现 Android 的真实布局：getApplicationSupportDirectory() 返回
    // /data/user/0/<pkg>/…，而 /data/user/0 本身是指向 /data/data 的软链。
    // 于是「字面路径」和「解析后的路径」前缀不同 ——
    // 拿解析后的子路径去比未解析的根，第一个条目就会被误判成恶意归档。
    final real = Directory('${tmp.path}/real')..createSync();
    await Process.run('ln', ['-s', real.path, '${tmp.path}/via_link']);
    final rootViaLink = Directory('${tmp.path}/via_link/distros');

    final mgr = _manager(rootViaLink, archive);
    final d = _testDistro('file://ignored');

    await for (final _ in mgr.install(d)) {
      // 消费完整个流；抛异常就是这条用例失败
    }

    expect(await mgr.isInstalled(d), isTrue, reason: '根路径经软链可达不该被当成越界');
    final rootfs = mgr.rootfsDirFor(d);
    expect(await Directory('${rootfs.path}/tmp').exists(), isTrue);
    expect(await File('${rootfs.path}/usr/bin/busybox').exists(), isTrue);
    expect(await Link('${rootfs.path}/bin').exists(), isTrue,
        reason: 'usr-merge 风格的软链必须原样保留');
  });

  test('穿透软链写到 rootfs 之外要被拦下', () async {
    if (!Platform.isLinux && !Platform.isMacOS) {
      markTestSkipped('Windows 上建不了软链，解压这个归档必然失败，测不出所以然');
      return;
    }

    final outside = Directory('${tmp.path}/outside')..createSync();

    // 这个归档必须手工造：恶意布局是「软链条目 + 它下面的文件条目」并存，
    // 而 tar walk 目录时**不会跟着软链下去**，用系统 tar 打包根本产生不了
    // 这种结构。手写 512 字节头才能精确表达要防的东西。
    final archive = File('${tmp.path}/evil.tar.gz');
    await archive.writeAsBytes(gzip.encode(_buildTar([
      _TarSpec.symlink('escape', outside.path),
      const _TarSpec.file('escape/pwned', 'owned'),
    ])));

    final mgr = _manager(Directory('${tmp.path}/distros'), archive);
    final d = _testDistro('file://ignored');

    await expectLater(
      mgr.install(d).drain<void>(),
      throwsA(isA<DistroInstallException>()),
    );
    expect(await File('${outside.path}/pwned').exists(), isFalse,
        reason: '文件绝不能落到 rootfs 之外');
  });

  test('装完会写下哨兵文件，半成品不算装好', () async {
    final archive = await buildRootfsArchive();
    if (archive == null) {
      markTestSkipped('系统上没有可用的 tar');
      return;
    }
    final mgr = _manager(Directory('${tmp.path}/distros'), archive);
    final d = _testDistro('file://ignored');

    expect(await mgr.isInstalled(d), isFalse);
    await mgr.install(d).drain<void>();
    expect(await mgr.isInstalled(d), isTrue);

    // 哨兵存的是安装事实，不是目录存在这个表象
    final stamp = File('${tmp.path}/distros/${d.id}/.installed');
    final meta = jsonDecode(await stamp.readAsString()) as Map<String, Object?>;
    expect(meta['abi'], 'x86_64');
    expect(meta['files'], greaterThan(0));
  });

  test('Debian 已启用 XZ rootfs 并固定校验和', () {
    expect(DistroCatalog.debian.isAvailableOn('arm64-v8a'), isTrue);
    expect(DistroCatalog.debian.rootfsUrls['arm64-v8a'], endsWith('.tar.xz'));
    expect(DistroCatalog.debian.sha256['arm64-v8a'], hasLength(64));
  });

  test('每个可安装基座同时提供大陆和国际来源', () {
    for (final distro in DistroCatalog.installableFor('arm64-v8a')) {
      expect(distro.sources.any((s) => s.region == MirrorRegion.china), isTrue,
          reason: '${distro.displayName} 缺少中国大陆来源');
      expect(distro.sources.any((s) => s.region == MirrorRegion.international),
          isTrue,
          reason: '${distro.displayName} 缺少国际来源');
      expect(
          distro.sources.any((s) =>
              s.region == MirrorRegion.international &&
              s.displayName.contains('官方')),
          isTrue,
          reason: '${distro.displayName} 缺少明确标注的官方来源');
    }
  });

  test('tar.xz 会先流式解码再沿用安全 tar 解包流程', () async {
    if (!await _hasTar()) {
      markTestSkipped('系统上没有可用的 tar');
      return;
    }
    final src = Directory('${tmp.path}/xz-src')..createSync();
    File('${src.path}/hello').writeAsStringSync('debian-ready');
    final archive = File('${tmp.path}/rootfs.tar.xz');
    final made =
        await Process.run('tar', ['-cJf', archive.path, '-C', src.path, '.']);
    if (made.exitCode != 0) {
      markTestSkipped('当前系统 tar 不支持 xz');
      return;
    }

    final mgr = _manager(Directory('${tmp.path}/xz-distros'), archive);
    final d = _testDistro('https://example.invalid/rootfs.tar.xz');
    await mgr.install(d).drain<void>();
    expect(await File('${mgr.rootfsDirFor(d).path}/hello').readAsString(),
        'debian-ready');
  });

  test('按 ABI 屏蔽：同一个发行版可以只在某些架构上不可用', () {
    // Alpine 在 x86_64 上装不了（musl 用裸 fork，被 Android 的 seccomp 拦），
    // 但 arm64 完全正常。一刀切标成不可用会白白挡掉真机上能用的选项。
    const alpine = DistroCatalog.alpine;
    expect(alpine.isAvailableOn('arm64-v8a'), isTrue);
    expect(alpine.isAvailableOn('x86_64'), isFalse);
    expect(alpine.blockedReasonFor('x86_64'), contains('fork'));
    expect(alpine.blockedReasonFor('arm64-v8a'), isNull);

    expect(DistroCatalog.debian.isAvailableOn('arm64-v8a'), isTrue);

    // 每个受支持的架构都必须至少剩一个能装的，否则用户会看到一个空列表
    for (final abi in ['arm64-v8a', 'x86_64']) {
      expect(DistroCatalog.installableFor(abi), isNotEmpty,
          reason: '$abi 上一个可装的发行版都没有');
    }
  });
}

// ---------------------------------------------------------------------------
// 最小 tar 写入器。只为造出系统 tar 造不出来的布局。
// ---------------------------------------------------------------------------

class _TarSpec {
  final String name;
  final int typeflag; // '0' 普通文件, '2' 软链
  final String linkTarget;
  final String content;

  const _TarSpec.file(this.name, this.content)
      : typeflag = 0x30,
        linkTarget = '';
  const _TarSpec.symlink(this.name, this.linkTarget)
      : typeflag = 0x32,
        content = '';
}

List<int> _buildTar(List<_TarSpec> entries) {
  final out = <int>[];
  for (final e in entries) {
    final body = utf8.encode(e.content);
    final h = List<int>.filled(512, 0);

    void put(String v, int off, int len) {
      final b = utf8.encode(v);
      for (var i = 0; i < b.length && i < len; i++) {
        h[off + i] = b[i];
      }
    }

    void putOctal(int v, int off, int len) =>
        put(v.toRadixString(8).padLeft(len - 1, '0'), off, len);

    put(e.name, 0, 100);
    putOctal(0x1A4, 100, 8); // mode 0644
    putOctal(0, 108, 8); // uid
    putOctal(0, 116, 8); // gid
    putOctal(body.length, 124, 12);
    putOctal(0, 136, 12); // mtime
    h[156] = e.typeflag;
    put(e.linkTarget, 157, 100);
    put('ustar', 257, 6);
    h[263] = 0x30;
    h[264] = 0x30; // version "00"

    // 校验和字段先填空格再算总和 —— 这是 tar 格式的规定顺序，
    // 顺序反了算出来的值永远对不上。
    for (var i = 148; i < 156; i++) {
      h[i] = 0x20;
    }
    var sum = 0;
    for (final b in h) {
      sum += b;
    }
    put('${sum.toRadixString(8).padLeft(6, '0')}\u0000 ', 148, 8);

    out.addAll(h);
    out.addAll(body);
    final pad = (512 - body.length % 512) % 512;
    out.addAll(List<int>.filled(pad, 0));
  }
  out.addAll(List<int>.filled(1024, 0)); // 结束标记
  return out;
}
