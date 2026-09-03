import 'dart:io';

import 'package:burrow/src/sandbox/interactive_shell.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('burrow_shell_selection_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('Ubuntu interactive terminal selects bash when bash exists', () async {
    final rootfs = Directory('${tmp.path}/rootfs');
    await File('${rootfs.path}/bin/bash').create(recursive: true);

    expect(
      await interactiveShellCommand(rootfs),
      'exec /bin/bash -l',
      reason: 'Ubuntu /bin/sh is dash and treats Tab as whitespace; bash '
          'provides the command and path completion users expect',
    );
  });

  test('a minimal rootfs without bash still falls back to sh', () async {
    final rootfs = Directory('${tmp.path}/rootfs');
    await File('${rootfs.path}/bin/sh').create(recursive: true);

    expect(await interactiveShellCommand(rootfs), 'exec /bin/sh -l');
  });

  test('bash wins over other optional interactive shells', () async {
    final rootfs = Directory('${tmp.path}/rootfs');
    await File('${rootfs.path}/bin/fish').create(recursive: true);
    await File('${rootfs.path}/bin/bash').create(recursive: true);

    expect(await interactiveShellCommand(rootfs), 'exec /bin/bash -l');
  });

  test('Alpine can use ash when bash is absent', () async {
    final rootfs = Directory('${tmp.path}/rootfs');
    await File('${rootfs.path}/bin/ash').create(recursive: true);

    expect(await interactiveShellCommand(rootfs), 'exec /bin/ash -l');
  });

  test('no distro keeps the Android failsafe shell command', () async {
    expect(await interactiveShellCommand(null), 'exec sh');
  });
}
