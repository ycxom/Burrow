/// 唤起**手机自己的锁屏验证**（PIN / 图案 / 指纹 / 人脸）。
///
/// 只在两个地方用：忘了会话密码走找回，和删除一个锁着的会话。日常进会话
/// 用的是 app 自己那道密码 —— 那是刻意的：手机锁屏是"这台机器是我的"，
/// 而会话锁要挡的恰恰是"手机确实是你的、你也解开了，但这段对话你不该看"。
/// 两者用同一把钥匙的话，这道锁就等于不存在。
///
/// 走 `KeyguardManager.createConfirmDeviceCredentialIntent` 而不是加一个
/// 生物识别插件：那类插件要求宿主 Activity 是 FragmentActivity，而这个 app
/// 的 MainActivity 是 FlutterActivity，换基类会牵动 pty 那一整套 activity
/// result 的分发。系统这个 Intent 在 FlutterActivity 上就能用。
library;

import 'package:flutter/services.dart';

/// 验证的结果。
enum DeviceAuthResult {
  /// 过了。
  ok,

  /// 用户取消或者验证失败。
  refused,

  /// 这台机器压根没设锁屏。
  ///
  /// 单独一档而不是并进 [refused]：一个没设锁屏的用户永远过不了这一关，
  /// 界面上得说清楚"去系统设置里加一个锁屏"，而不是让他对着一句
  /// "验证失败"反复试。
  unavailable,
}

class DeviceAuth {
  const DeviceAuth._();

  static const _channel = MethodChannel('com.burrow/system');

  /// 弹系统的锁屏验证。[reason] 会显示在系统那个界面上。
  static Future<DeviceAuthResult> confirm(String reason) async {
    try {
      final result = await _channel.invokeMethod<String>(
        'confirmDeviceCredential',
        <String, Object?>{'reason': reason},
      );
      return switch (result) {
        'ok' => DeviceAuthResult.ok,
        'unavailable' => DeviceAuthResult.unavailable,
        _ => DeviceAuthResult.refused,
      };
    } on PlatformException {
      // 桌面调试、或者这一版原生侧还没有这个方法。当成"没有锁屏可验"
      // 而不是"验证失败" —— 后者会让人以为自己输错了。
      return DeviceAuthResult.unavailable;
    } on MissingPluginException {
      return DeviceAuthResult.unavailable;
    }
  }
}
