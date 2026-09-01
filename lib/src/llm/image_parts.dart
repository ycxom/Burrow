/// 把磁盘上的图片变成各家协议要的那种"内容块"。
///
/// 三家的形状都不一样，而且**都只接受 base64 内联**（本地文件没有 URL
/// 可给），所以这一层做三件事：读字节、认类型、按协议拼块。
///
/// 认类型靠**文件头而不是扩展名**。相机存出来的 `.jpg` 其实是 HEIC、
/// 截图工具存的 `.jpg` 其实是 PNG，都很常见；而 Anthropic 会对
/// `media_type` 和实际字节不符的请求直接返回 400，OpenAI 那边则更糟 ——
/// 有些网关照单全收，然后模型看到的是一张花屏。
library;

import 'dart:convert';
import 'dart:io';

/// 「能把图说成话」的东西。
///
/// 抽成接口只为一件事：让前置多模态的**挑选和容灾**逻辑能脱离网络测。
/// 那段逻辑（随机挑、失败换下一个、全挂了怎么报）恰好是最容易写错、
/// 又最难在真机上复现的部分 —— 得让它能在单测里跑。
abstract class ImageDescriber {
  Future<String> describeImages({
    required List<String> imagePaths,
    required String prompt,
  });

  /// 用完就收。一次性客户端不收的话会把连接池撑住。
  void cancel();
}

/// 一张已经读进内存、可以直接塞进请求体的图。
class InlineImage {
  final String path;

  /// `image/jpeg` 这种。跟着文件头走。
  final String mediaType;
  final String base64Data;
  final int bytes;

  const InlineImage({
    required this.path,
    required this.mediaType,
    required this.base64Data,
    required this.bytes,
  });
}

/// 单张图的字节上限。
///
/// 超了直接不发而不是硬发：各家的限制在 5–20MB 不等，而**超限的报错通常
/// 很难认**（有的返回 413 没有正文，有的返回一句 "invalid image"）。
/// 在这里挡掉至少能说清是哪张、多大。选图那一步已经缩过，正常走不到这里。
const maxInlineImageBytes = 8 * 1024 * 1024;

class ImageLoadException implements Exception {
  final String message;
  const ImageLoadException(this.message);
  @override
  String toString() => message;
}

/// 从文件头认图片类型。认不出来返回 null。
///
/// 只认这四种：三家 API 公认支持的就是这几个。认不出的类型宁可报错，
/// 也不要瞎填一个 `image/jpeg` —— 那会变成前面说的"花屏"那类失败。
String? sniffMediaType(List<int> head) {
  bool startsWith(List<int> magic, {int offset = 0}) {
    if (head.length < offset + magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (head[offset + i] != magic[i]) return false;
    }
    return true;
  }

  if (startsWith(<int>[0xFF, 0xD8, 0xFF])) return 'image/jpeg';
  if (startsWith(<int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
    return 'image/png';
  }
  if (startsWith(<int>[0x47, 0x49, 0x46, 0x38])) return 'image/gif';
  // WebP：RIFF....WEBP
  if (startsWith(<int>[0x52, 0x49, 0x46, 0x46]) &&
      startsWith(<int>[0x57, 0x45, 0x42, 0x50], offset: 8)) {
    return 'image/webp';
  }
  return null;
}

/// 读一张图。文件不在、太大、类型不认识都抛 [ImageLoadException]。
Future<InlineImage> loadInlineImage(String path) async {
  // 每一条报错都带上文件名。附了四张图、其中一张不行的时候，
  // 「认不出这个图片格式」而不说是哪张，等于让用户自己一张张试。
  final name = path.split('/').last.split(r'\').last;
  final file = File(path);
  if (!await file.exists()) {
    throw ImageLoadException('$name：图片已经不在了');
  }
  final bytes = await file.readAsBytes();
  if (bytes.isEmpty) {
    throw ImageLoadException('$name：是个空文件');
  }
  if (bytes.length > maxInlineImageBytes) {
    final mb = (bytes.length / 1024 / 1024).toStringAsFixed(1);
    throw ImageLoadException('$name：太大了（${mb}MB），超过 '
        '${maxInlineImageBytes ~/ 1024 ~/ 1024}MB 上限');
  }
  final mediaType = sniffMediaType(bytes);
  if (mediaType == null) {
    throw ImageLoadException('$name：认不出格式，只支持 JPEG / PNG / GIF / WebP');
  }
  return InlineImage(
    path: path,
    mediaType: mediaType,
    base64Data: base64Encode(bytes),
    bytes: bytes.length,
  );
}

/// 批量读。读不出来的那张**记下原因继续**，不连累其它图。
///
/// 一张图坏了就整条消息发不出去是不合理的：用户看到的会是一条
/// "发送失败"，而他压根不知道是哪张图的问题。
Future<(Map<String, InlineImage>, List<String>)> loadInlineImages(
    Iterable<String> paths) async {
  final loaded = <String, InlineImage>{};
  final failures = <String>[];
  for (final path in paths.toSet()) {
    try {
      loaded[path] = await loadInlineImage(path);
    } on ImageLoadException catch (e) {
      failures.add(e.message);
    } catch (e) {
      failures.add('$path：$e');
    }
  }
  return (loaded, failures);
}

/// `data:` URI。OpenAI 系和 Responses API 都用这个形状。
String dataUri(InlineImage image) =>
    'data:${image.mediaType};base64,${image.base64Data}';

/// OpenAI `/chat/completions` 的多模态 content 数组。
List<Map<String, Object?>> openAiContentParts(
  String text,
  List<InlineImage> images,
) =>
    <Map<String, Object?>>[
      // 图在前、文字在后。多数实现对顺序不敏感，但**提问跟在图后面**读起来
      // 更接近人的表达顺序，实测对"这张图里的 X 是什么"这类问题更稳。
      for (final image in images)
        <String, Object?>{
          'type': 'image_url',
          'image_url': <String, Object?>{'url': dataUri(image)},
        },
      if (text.isNotEmpty) <String, Object?>{'type': 'text', 'text': text},
    ];

/// Anthropic `/messages` 的 content 数组。
List<Map<String, Object?>> anthropicContentParts(
  String text,
  List<InlineImage> images,
) =>
    <Map<String, Object?>>[
      for (final image in images)
        <String, Object?>{
          'type': 'image',
          'source': <String, Object?>{
            'type': 'base64',
            'media_type': image.mediaType,
            'data': image.base64Data,
          },
        },
      if (text.isNotEmpty) <String, Object?>{'type': 'text', 'text': text},
    ];

/// OpenAI Responses API（Codex / ChatGPT 订阅那条路）的 input 数组。
///
/// 块的名字和 `/chat/completions` 不一样：`input_text` / `input_image`，
/// 而且图片是平铺的 `image_url` 字符串，不是嵌套对象。
List<Map<String, Object?>> responsesContentParts(
  String text,
  List<InlineImage> images,
) =>
    <Map<String, Object?>>[
      for (final image in images)
        <String, Object?>{
          'type': 'input_image',
          'image_url': dataUri(image),
        },
      if (text.isNotEmpty)
        <String, Object?>{'type': 'input_text', 'text': text},
    ];
