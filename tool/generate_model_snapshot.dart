/// 生成随包分发的模型能力快照。
///
///     dart run tool/generate_model_snapshot.dart
///
/// 产物是 `assets/model_registry.json`（约 230KB）。
///
/// ## 为什么要带快照
///
/// 手机上第一次配渠道时多半还没来得及联网拉 registry，而那恰恰是最需要
/// 能力信息的时刻 —— 用户正在对着一排开关发愣。没有快照的话，第一次配
/// 出来的渠道全是手动勾的，registry 拉回来也不会去改用户已经勾过的
/// （手动优先），等于这个功能对新用户完全不生效。
///
/// ## 为什么用 Dart 写而不是脚本语言
///
/// 压平那一步有多数决逻辑（见 flattenModelsDev）。用另一门语言重写一遍
/// 意味着两份实现要一直保持一致，而它们不一致时的表现是「快照里的能力
/// 和联网拉到的不一样」—— 没有任何人会去核对这个。共用同一个函数，
/// 快照就是可证明地等于一次真实拉取的结果。
library;

import 'dart:convert';
import 'dart:io';

import 'package:burrow/src/llm/model_registry.dart';

/// 和运行时用的是同一份地址表，顺序也一样。
const _sources = <String>[
  'https://models.dev/api.json',
  'https://models.opencode.ai/api.json',
];

Future<void> main(List<String> args) async {
  final out = File('assets/model_registry.json');

  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  Object? decoded;
  for (final url in _sources) {
    try {
      stdout.writeln('拉取 $url …');
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode != 200) {
        stderr.writeln('  HTTP ${response.statusCode}，换下一个');
        continue;
      }
      decoded = jsonDecode(await response.transform(utf8.decoder).join());
      break;
    } catch (e) {
      stderr.writeln('  失败：$e，换下一个');
    }
  }
  client.close();

  if (decoded == null) {
    stderr.writeln('两个源都拉不到，快照没有更新。');
    exitCode = 1;
    return;
  }

  final models = flattenModelsDev(decoded);
  if (models.isEmpty) {
    stderr.writeln('拉到了但一个模型都没解析出来，八成是上游改了结构。');
    exitCode = 1;
    return;
  }

  // 按 id 排序再写：不排的话每次生成的字节顺序都可能不同，
  // 一个内容没变的快照会在 git 里显示成一大坨 diff。
  final sorted = <String, ModelMeta>{
    for (final key in models.keys.toList()..sort()) key: models[key]!,
  };

  await out.parent.create(recursive: true);
  await out.writeAsString(encodeRegistry(sorted));
  final kb = (await out.length()) / 1024;
  stdout.writeln('写入 ${out.path}：${sorted.length} 个模型，'
      '${kb.toStringAsFixed(0)} KB');
}
