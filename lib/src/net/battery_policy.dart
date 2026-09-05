/// 「别在后台把我冻住」。
///
/// ## 它和前台服务不是一回事
///
/// 前台服务（见 process_guard.dart）挡的是 **Android 标准的那套回收**：
/// 内存紧张时优先杀后台进程。那一条它挡得住。
///
/// 挡不住的是各家 ROM 自己加的那一层 —— 小米的神隐模式、华为的应用启动管理、
/// 三星的「深度睡眠应用」、以及所有厂商都在做的 Doze 加强版。锁屏几分钟之后
/// 它们照样把进程冻住，**前台服务通知还挂着，但里面的代码一行都不跑了**。
/// 那一层唯一的解法是让用户亲手把这个 app 放进白名单。
///
/// 所以这两件事都要有，缺一样都会漏：前台服务负责"系统别杀我"，白名单负责
/// "厂商别冻我"。
///
/// ## 为什么不自动弹
///
/// 这个框问的是"要不要让这个 app 一直在后台耗电"，而多数人打开一个聊天 app
/// 的第一分钟并不想回答这种问题 —— 那时他还不知道自己需不需要。默认不弹，
/// 只在两个地方出现：设置里那一行，以及**用户真的被打断过之后**。
///
/// ## 系统不告诉我们结果
///
/// 那个弹窗没有回调，用户点没点允许我们不知道。所以 [request] 的返回值只
/// 表示"界面弹出来了"，真话要在回到前台之后重新 [isIgnored] 一次。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class BatteryPolicy {
  BatteryPolicy._();

  static const _channel = MethodChannel('com.burrow/system');

  /// 只有 Android 有这套东西。别的平台一律当成"没有限制"。
  static bool get supported => !kIsWeb && Platform.isAndroid;

  /// 这个 app 现在受不受电池优化限制。
  ///
  /// 查不出来时答 true（= 当成不受限）。查不出来的原因通常是宿主没实现这个
  /// 通道（桌面端、测试），那种环境里本来就没有这回事 —— 答 false 会让设置
  /// 页挂一条永远消不掉的警告。
  static Future<bool> isIgnored() async {
    if (!supported) return true;
    try {
      return await _channel.invokeMethod<bool>('batteryOptimizationIgnored') ??
          true;
    } on PlatformException {
      return true;
    } on MissingPluginException {
      return true;
    }
  }

  /// 弹系统那个框。返回 false = 这台设备上两条路都开不了，只能让用户自己
  /// 到系统设置里找。
  static Future<bool> request() async {
    if (!supported) return false;
    try {
      return await _channel
              .invokeMethod<bool>('requestIgnoreBatteryOptimizations') ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
