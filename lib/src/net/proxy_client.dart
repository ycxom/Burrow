/// 带代理的 HTTP 客户端。
///
/// 代理是**每个渠道各自的设置**，不是全局的：一个渠道走公司内网直连、
/// 另一个走梯子，是很常见的组合。全局代理会把前者也拖进代理里。
library;

import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// 把用户填的东西规整成 `host:port`。
///
/// 接受 `1.2.3.4:8080`、`http://1.2.3.4:8080`、`http://1.2.3.4:8080/` 这几种写法
/// —— 用户从别处抄代理地址时带不带 scheme 完全看心情，为此报错不值得。
/// 认不出来返回 null，调用方按"没配代理"处理。
String? normalizeProxy(String? raw) {
  final s = raw?.trim() ?? '';
  if (s.isEmpty) return null;

  var body = s;
  for (final scheme in const ['http://', 'https://']) {
    if (body.toLowerCase().startsWith(scheme)) {
      body = body.substring(scheme.length);
      break;
    }
  }
  body = body.split('/').first.trim();
  if (body.isEmpty) return null;

  // 必须带端口。没端口的话 Dart 会默认 1080，而用户多半是漏写了，
  // 默默连到一个错端口比直接当没配更难查。
  final colon = body.lastIndexOf(':');
  if (colon <= 0 || colon == body.length - 1) return null;
  if (int.tryParse(body.substring(colon + 1)) == null) return null;
  return body;
}

/// 按代理设置造一个客户端。[proxy] 为空则是直连的普通客户端。
///
/// 只支持 HTTP CONNECT 代理。SOCKS 需要额外的包，而绝大多数本地代理工具
/// 都同时开着一个 HTTP 端口 —— 为 SOCKS 引一个依赖不划算。
http.Client buildHttpClient({String? proxy}) {
  final target = normalizeProxy(proxy);
  if (target == null) return http.Client();
  final io = HttpClient()..findProxy = (_) => 'PROXY $target';
  return IOClient(io);
}
