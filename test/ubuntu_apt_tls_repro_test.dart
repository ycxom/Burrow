/// Regression harness for an already-installed Ubuntu rootfs at app startup.
///
/// Burrow starts by calling [DistroManager.listInstalled] and immediately
/// attaches the first result. These tests persist the certificate-relevant
/// shape observed on-device, then exercise that same startup seam without a
/// network or a full 130 MB rootfs.
library;

import 'dart:convert';
import 'dart:io';

import 'package:burrow/src/bootstrap/distro.dart';
import 'package:burrow/src/sandbox/sandbox_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const cases = <_AptConfigCase>[
    _AptConfigCase(
      label: 'legacy sources.list',
      relativePath: 'etc/apt/sources.list',
      content: 'deb https://mirror.invalid/ubuntu noble main\n',
    ),
    _AptConfigCase(
      label: 'deb822 ubuntu.sources',
      relativePath: 'etc/apt/sources.list.d/ubuntu.sources',
      content: 'Types: deb\n'
          'URIs: https://mirror.invalid/ubuntu\n'
          'Suites: noble\n'
          'Components: main\n',
    ),
  ];

  for (final aptCase in cases) {
    test('startup repairs ${aptCase.label} when the installed rootfs has no CA',
        () async {
      final tmp =
          await Directory.systemTemp.createTemp('burrow_existing_ubuntu_tls_');
      try {
        final distroRoot = Directory('${tmp.path}/distros');
        final installRoot =
            Directory('${distroRoot.path}/${DistroCatalog.ubuntu.id}');
        final rootfs = Directory('${installRoot.path}/rootfs');

        await _writeFixture(rootfs, aptCase);
        await File('${installRoot.path}/.installed').writeAsString(jsonEncode({
          'id': DistroCatalog.ubuntu.id,
          'abi': 'x86_64',
          'source': 'ubuntu-ustc',
        }));

        final manager = DistroManager(
          root: distroRoot,
          abi: 'x86_64',
          fetch: (_) async =>
              throw StateError('startup migration must not download a rootfs'),
        );

        // This is the exact cold-start seam used by lib/main.dart.
        final installed = await manager.listInstalled();
        expect(installed, hasLength(1));
        expect(installed.single.distro.id, DistroCatalog.ubuntu.id);

        final sandbox = _sandboxFor(installed.single, tmp);
        await _expectAptCertificateReady(installed.single.rootfs, sandbox);
      } finally {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {
          // Do not let Windows temp-file retention hide the readiness verdict.
        }
      }
    });
  }
}

Future<void> _writeFixture(Directory rootfs, _AptConfigCase aptCase) async {
  final source = File('${rootfs.path}/${aptCase.relativePath}');
  await source.parent.create(recursive: true);
  await source.writeAsString(aptCase.content);

  // These conditions were green in the device repro. Keeping them green makes
  // a red verdict specific to certificate trust rather than DNS or transport.
  final resolv = File('${rootfs.path}/etc/resolv.conf');
  await resolv.parent.create(recursive: true);
  await resolv.writeAsString('nameserver 8.8.8.8\n');
  final httpsMethod = File('${rootfs.path}/usr/lib/apt/methods/https');
  await httpsMethod.parent.create(recursive: true);
  await httpsMethod.writeAsString('present\n');

  // Deliberately do not create etc/ssl/certs/ca-certificates.crt. This is the
  // on-device Ubuntu Base state that emits "No system certificates available".
}

SandboxSession _sandboxFor(InstalledDistro installed, Directory tmp) =>
    SandboxSession(
      rootfsPath: installed.rootfs.path,
      workspacePath: '${tmp.path}/workspace',
      caps: const SandboxCapabilities(
        proot: true,
        seccomp: true,
        landlockAbi: 0,
        rlimit: true,
      ),
      spawner: _UnusedSpawner(),
      prootPath: '/host/libproot.so',
      tmpPath: '${tmp.path}/proot-tmp',
      distroLabel: installed.distro.displayName,
      packageManager: installed.distro.packageManager,
    );

Future<void> _expectAptCertificateReady(
    Directory rootfs, SandboxSession sandbox) async {
  final resolv = await File('${rootfs.path}/etc/resolv.conf').readAsString();
  expect(resolv, contains(RegExp(r'^nameserver\s+\S+', multiLine: true)),
      reason: 'DNS must be initialized so this reaches the TLS failure');
  expect(
    await File('${rootfs.path}/usr/lib/apt/methods/https').exists(),
    isTrue,
    reason: 'APT HTTPS transport must exist so this reaches certificate trust',
  );

  final argv = sandbox.buildArgv(
    'apt update',
    SandboxLevel.workspaceWriteNetwork,
  );
  expect(argv, containsAllInOrder(['/host/libproot.so', '-r', rootfs.path]));
  expect(argv, containsAllInOrder(['/bin/sh', '-lc', 'apt update']));
  expect(argv.join(' '), isNot(contains('faketime')),
      reason: 'The sandbox inherits the Android kernel clock');

  final httpsSources = await _enabledHttpsAptSources(rootfs);
  final env = sandbox.buildEnv(SandboxLevel.workspaceWriteNetwork);
  final caPath = env['SSL_CERT_FILE'] ?? '/etc/ssl/certs/ca-certificates.crt';
  final caBundle = File(_insideRootfs(rootfs, caPath));
  final hasReadableCa = await caBundle.exists() && await caBundle.length() > 0;

  if (httpsSources.isNotEmpty && !hasReadableCa) {
    fail(
      'APT_HTTPS_CERT_FAILURE: startup left enabled HTTPS APT source(s) '
      '${httpsSources.join(', ')} but sandbox CA path $caPath is absent or '
      'empty. Device `apt update` reports "No system certificates available" '
      'and an unknown certificate issuer.',
    );
  }
}

Future<List<String>> _enabledHttpsAptSources(Directory rootfs) async {
  final apt = Directory('${rootfs.path}/etc/apt');
  final files = <File>[File('${apt.path}/sources.list')];
  final fragments = Directory('${apt.path}/sources.list.d');
  if (await fragments.exists()) {
    await for (final entity in fragments.list()) {
      if (entity is File &&
          (entity.path.endsWith('.list') || entity.path.endsWith('.sources'))) {
        files.add(entity);
      }
    }
  }

  final found = <String>[];
  final https = RegExp(r'https://[^\s#]+', caseSensitive: false);
  for (final file in files) {
    if (!await file.exists()) continue;
    for (final line
        in const LineSplitter().convert(await file.readAsString())) {
      final active = line.split('#').first;
      found.addAll(https.allMatches(active).map((m) => m.group(0)!));
    }
  }
  return found;
}

String _insideRootfs(Directory rootfs, String absolutePath) =>
    '${rootfs.path}/${absolutePath.replaceFirst(RegExp(r'^[/\\]+'), '')}';

class _AptConfigCase {
  final String label;
  final String relativePath;
  final String content;

  const _AptConfigCase({
    required this.label,
    required this.relativePath,
    required this.content,
  });
}

class _UnusedSpawner implements NativePtySpawner {
  @override
  Future<PtyHandle> spawn({
    required List<String> argv,
    required Map<String, String> env,
    required String cwd,
    int rows = 24,
    int cols = 80,
  }) =>
      throw UnsupportedError('The repro only inspects argv/env');
}
