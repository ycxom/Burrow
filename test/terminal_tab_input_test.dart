import 'package:burrow/src/sandbox/pty_channel.dart';
import 'package:burrow/src/ui/terminal_extra_keys.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const ptyMethods = MethodChannel('burrow/pty');
  const ptyEvents = MethodChannel('burrow/pty/events');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> nativeCalls;

  setUp(() {
    nativeCalls = <MethodCall>[];
    messenger.setMockMethodCallHandler(ptyMethods, (call) async {
      nativeCalls.add(call);
      if (call.method == 'spawn') return 41;
      return null;
    });
    // PtyChannel subscribes eagerly. The event stream itself is irrelevant to
    // this input-direction regression, but its listen handshake must succeed.
    messenger.setMockMethodCallHandler(ptyEvents, (_) async => null);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(ptyMethods, null);
    messenger.setMockMethodCallHandler(ptyEvents, null);
  });

  testWidgets('Tab extra key writes one HT byte to the native PTY',
      (tester) async {
    final pty = PtyChannel();
    addTearDown(pty.dispose);
    final shell = await pty.spawn(
      argv: const <String>['/bin/sh', '-l'],
      env: const <String, String>{'TERM': 'xterm-256color'},
      cwd: '/workspace',
    );
    final terminal = Terminal(
      onOutput: (data) => shell.write(data.codeUnits),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TerminalExtraKeysBar(terminal: terminal)),
      ),
    );
    await tester.tap(find.text('Tab'));
    await tester.pump();

    final writes = nativeCalls.where((call) => call.method == 'write').toList();
    expect(writes, hasLength(1));
    final arguments = (writes.single.arguments as Map).cast<String, Object?>();
    expect(arguments['session'], 41);
    expect((arguments['bytes'] as Uint8List).toList(), const <int>[0x09],
        reason: 'shell completion requires one horizontal-tab byte');
  });
}
