/// 把一个网址交给系统浏览器。
///
/// 只为 OAuth 回跳登录存在。设备码流程用不上它 —— 那个流程里用户是自己
/// 找一台设备打开网页的，我们连他用哪台机器都不知道。
///
/// ## 为什么是自己写通道而不是引 url_launcher
///
/// url_launcher 是个好包，但它带的东西远超这里要的：deep link、邮件、电话、
/// 各平台的一堆分支。这里要的是**一个 ACTION_VIEW**。项目里连 zip 和 tar 都是
/// 自己写的解析器，为一行 Intent 引一个插件不合这个房子的规矩。
///
/// ## 为什么必须是外部浏览器
///
/// 回跳目标是 `http://127.0.0.1:<port>`。这个地址只有**发起授权的那台设备上的
/// 浏览器**能访问到 —— 换句话说，用 WebView 内嵌也行，用外部浏览器也行，
/// 但不能让用户拿另一台设备去开。
///
/// 选外部浏览器而不是内嵌 WebView，是因为 Google 明确拒绝在 WebView 里完成
/// OAuth（`disallowed_useragent`），理由是 WebView 里 app 能读到用户的密码。
/// 这条规则是对的，而且绕不过去。
library;

import 'package:flutter/services.dart';

class SystemBrowser {
  SystemBrowser._();

  static const _channel = MethodChannel('com.burrow/system');

  /// 打开一个网址。返回 false 表示设备上没有可用的浏览器。
  ///
  /// 不抛异常：打不开浏览器时登录页要退回"手动复制这个网址"，那是一条
  /// 正常的降级路径，不是错误。
  static Future<bool> open(String url) async {
    try {
      final ok = await _channel.invokeMethod<bool>('openUrl', <String, String>{
        'url': url,
      });
      return ok ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      // 桌面预览和 widget test 里没有这个通道。
      return false;
    }
  }
}
