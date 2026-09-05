/// 生成期间别让系统把进程收了。
///
/// ## 这解决的是哪件事
///
/// 「返回桌面回来发现回答没了」。Android 对退到后台的普通进程没有任何承诺 ——
/// 按一下 Home 键，几秒到几分钟之内进程就可能被回收，正在跑的那一轮请求随之
/// 消失，已经付过钱的 token 一起没了。
///
/// **这不是 Dart 侧能小心解决的事**：进程都不在了，代码写在哪儿都一样。
/// 系统唯一认的那句"我这会儿真的在干活"是前台服务，代价是一条用户看得见的
/// 通知。那个交换是对的 —— 后台偷偷跑活儿本来就该被看见。
///
/// ## 引用计数
///
/// 可能有好几间聊天室同时在生成（切走的那间会留在后台继续跑）。所以这里数
/// 的是"还有几间在跑"，最后一间结束才停服务；用一个布尔的话，先结束的那间
/// 会把还在跑的那几间的保护一起撤掉。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class ProcessGuard {
  ProcessGuard._();

  static const _channel = MethodChannel('com.burrow/system');

  static int _holders = 0;

  /// 现在有几间屋子在生成。测试用。
  @visibleForTesting
  static int get holders => _holders;

  @visibleForTesting
  static void resetForTest() => _holders = 0;

  /// 只有 Android 有这套东西。桌面端进程不会被这么收走，调用是空操作。
  static bool get _supported => !kIsWeb && Platform.isAndroid;

  /// 开始一轮生成。
  ///
  /// 幂等地累计：谁开的谁负责调一次 [release]。
  static Future<void> acquire({String? text}) async {
    _holders++;
    if (_holders != 1 || !_supported) return;
    await _invoke('keepAliveStart', <String, Object?>{'text': text});
  }

  /// 一轮生成结束。最后一个撤走时才真的停掉服务。
  static Future<void> release() async {
    if (_holders > 0) _holders--;
    if (_holders != 0 || !_supported) return;
    await _invoke('keepAliveStop', const <String, Object?>{});
  }

  /// 通道出问题不该让这一轮对话失败。
  ///
  /// 起不来的后果只是"退到后台可能被杀"，而把异常抛上去会变成一条用户
  /// 完全看不懂的报错气泡 —— 后者更糟。
  static Future<void> _invoke(String method, Map<String, Object?> args) async {
    try {
      await _channel.invokeMethod<bool>(method, args);
    } on PlatformException {
      // 忽略。
    } on MissingPluginException {
      // 宿主没实现（比如跑在测试或桌面上）。
    }
  }
}
