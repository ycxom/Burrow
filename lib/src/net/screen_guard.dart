/// 防止截屏。
///
/// ## 它挡得住什么
///
/// 底下就是 Android 的 `FLAG_SECURE` 一个开关，挡住的是**屏幕内容离开这台
/// 设备的那几条路**：
///
///   - 系统截屏、第三方截屏工具
///   - 录屏、投屏到不安全的显示设备
///   - `adb shell screencap` / `adb exec-out screenrecord`
///   - 最近任务里那张缩略图（切出去之后旁边的人看不到你在聊什么）
///
/// ## 它挡不住什么 —— 这部分必须说清楚
///
/// **它保护的是屏幕，不是文件。** 图片本身以普通文件躺在 app 私有目录里，
/// 没有加密（加密的是数据库里的文字，见 data/db_cipher.dart）。所以：
///
///   - root 过的设备、或者厂商自带的文件管理器有特权时，照样读得到；
///   - 拿另一台设备**对着屏幕拍照**，没有任何软件挡得住。
///
/// 会话锁那边写过同一句话：一道锁能挡住的和它挡不住的，都要在设它的时候
/// 就说明白 —— 不然用户会按一个不存在的保证来决定往里面放什么。
///
/// ## 为什么是全窗口的
///
/// `FLAG_SECURE` 是**窗口**的属性，不是某个页面的。所以开关跟着"当前打开的
/// 是哪个会话"走：进到一个开了这一项的会话就加上，切走就撤掉。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class ScreenGuard {
  ScreenGuard._();

  static const _channel = MethodChannel('com.burrow/system');

  /// 只有 Android 有这个开关。
  static bool get supported =>
      debugForceSupported || (!kIsWeb && Platform.isAndroid);

  /// 让测试能走到真正那条路上。
  ///
  /// 没有这个口子的话，"不短路"这条契约在桌面上根本执行不到 ——
  /// 而一个永远走不到被测代码的测试，比没有测试更糟：它会让人以为这件事
  /// 已经钉住了。
  @visibleForTesting
  static bool debugForceSupported = false;

  /// 最后一次**设成功**的值。只用来观察，不用来省调用。
  static bool _on = false;

  @visibleForTesting
  static bool get isOn => _on;

  @visibleForTesting
  static void resetForTest() {
    _on = false;
    debugForceSupported = false;
  }

  /// 开或关。返回 false = 这台设备上没设上。
  ///
  /// **失败要如实返回。** 界面得照着它说"这台设备上没生效"，
  /// 而不是让用户以为自己被保护着 —— 那比没有这个功能更糟。
  ///
  /// **不做"值没变就不调"的短路。** native 那边会在 `onCreate` 里按上次的
  /// 状态先把窗口保护起来（不然冷启动会漏一帧），所以 Dart 这边刚起来时
  /// `_on` 是 false 而窗口可能是保护着的 —— 短路会让第一次
  /// `setSecure(false)` 直接返回，窗口就再也撤不掉了。一次 channel 调用
  /// 比这种对不上的状态便宜得多。
  static Future<bool> setSecure(bool on) async {
    if (!supported) return false;
    try {
      final ok =
          await _channel.invokeMethod<bool>('setSecure', <String, Object?>{
                'on': on,
              }) ??
              false;
      if (ok) _on = on;
      return ok;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
