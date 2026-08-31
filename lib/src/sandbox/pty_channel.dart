/// [NativePtySpawner] 的 Flutter 实现。对接 PtyBridge.kt。
library;

import 'dart:async';

import 'package:flutter/services.dart';

import 'sandbox_session.dart';

class PtyChannel implements NativePtySpawner {
  static const _method = MethodChannel('burrow/pty');
  static const _events = EventChannel('burrow/pty/events');

  /// 所有会话共用一条 EventChannel，这里按 sessionId 分发。
  /// 每个会话开一条 channel 的话，Agent 场景（每条命令一个会话）会不停地
  /// 创建销毁 channel，那个开销比分发本身大得多。
  final Map<int, _PtyHandleImpl> _sessions = {};
  StreamSubscription<dynamic>? _sub;

  PtyChannel() {
    _sub = _events.receiveBroadcastStream().listen(_dispatch);
  }

  void _dispatch(dynamic event) {
    final map = (event as Map).cast<String, Object?>();
    final handle = _sessions[map['session'] as int];
    if (handle == null) return;

    switch (map['type'] as String) {
      case 'data':
        handle._output.add(map['bytes'] as List<int>);
      case 'exit':
        handle._exit.complete(map['code'] as int);
        handle._output.close();
        _sessions.remove(handle.sessionId);
    }
  }

  /// 告诉原生 burrow-launch 装在哪，probeSandbox 要用。
  static Future<void> setLauncher(String path) =>
      _method.invokeMethod('setLauncher', {'path': path});

  /// APK 解出来的 .so 目录。BootstrapInstaller 要靠它找到 libburrow-launch.so。
  static Future<String?> nativeLibraryDir() =>
      _method.invokeMethod<String>('nativeLibraryDir');

  /// 设备主 ABI。决定下哪个发行版的 rootfs —— 拿错了会下到跑不起来的二进制。
  /// Dart 侧没有可靠途径拿它（`Platform.version` 里没有），只能问原生。
  static Future<String?> abi() => _method.invokeMethod<String>('abi');

  static Future<Map<String, Object?>> probeSandbox() async {
    final r = await _method.invokeMethod<Map<Object?, Object?>>('probeSandbox');
    return (r ?? {}).cast<String, Object?>();
  }

  @override
  Future<PtyHandle> spawn({
    required List<String> argv,
    required Map<String, String> env,
    required String cwd,
    int rows = 24,
    int cols = 80,
  }) async {
    final id = await _method.invokeMethod<int>('spawn', {
      'argv': argv,
      'env': env,
      'cwd': cwd,
      'rows': rows,
      'cols': cols,
    });
    if (id == null) throw StateError('pty spawn 未返回 session id');
    final handle = _PtyHandleImpl(id);
    _sessions[id] = handle;
    return handle;
  }

  void dispose() {
    _sub?.cancel();
    for (final h in _sessions.values) {
      h.killGroup();
    }
    _sessions.clear();
  }
}

class _PtyHandleImpl implements PtyHandle {
  final int sessionId;
  final _output = StreamController<List<int>>();
  final _exit = Completer<int>();

  _PtyHandleImpl(this.sessionId);

  @override
  Stream<List<int>> get output => _output.stream;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  void write(List<int> data) {
    PtyChannel._method.invokeMethod('write', {
      'session': sessionId,
      'bytes': Uint8List.fromList(data),
    });
  }

  @override
  void resize(int rows, int cols) {
    PtyChannel._method
        .invokeMethod('resize', {'session': sessionId, 'rows': rows, 'cols': cols});
  }

  @override
  void killGroup() {
    PtyChannel._method
        .invokeMethod('kill', {'session': sessionId, 'graceMs': 500});
  }
}
