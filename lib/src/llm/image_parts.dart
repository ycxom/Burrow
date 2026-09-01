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

/// 这张图是不是 **APNG**（会动的 PNG）。
///
/// 判据是 PNG 签名之后、第一个 `IDAT` 之前出现过一个 `acTL` 块 ——
/// 这是规范定的顺序，写在 IDAT 后面的 acTL 按规范应当被忽略。
///
/// 要单独认它，是因为**它和普通 PNG 的文件头一模一样**。当成静态 PNG
/// 重新编码一遍，动画就没了，而文件还是 `image/png`、还能正常显示，
/// 谁也看不出丢了东西。
bool isAnimatedPng(List<int> bytes) {
  const signature = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  if (bytes.length < signature.length) return false;
  for (var i = 0; i < signature.length; i++) {
    if (bytes[i] != signature[i]) return false;
  }

  var offset = signature.length;
  while (offset + 8 <= bytes.length) {
    // 块头：4 字节长度（大端）+ 4 字节类型。
    final length = (bytes[offset] << 24) |
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];
    if (length < 0) return false;
    final type = String.fromCharCodes(bytes, offset + 4, offset + 8);
    if (type == 'acTL') return true;
    // IDAT 之后再出现的 acTL 不算数，直接收工。
    if (type == 'IDAT' || type == 'IEND') return false;
    // 块长 + 长度字段 + 类型字段 + CRC。
    offset += length + 12;
  }
  return false;
}

/// 一张图在发出去之前该被怎么处理。
enum ImageDisposition {
  /// 原始字节一个都不动。
  keep,

  /// 缩放后重新编码成 JPEG。
  toJpeg,

  /// 缩放后重新编码成 PNG。
  toPng,
}

/// 决定怎么处理这张图。**纯函数，三条规则的唯一出处。**
///
/// 1. **会动的原样留着**：GIF 和 APNG 一旦被重新编码（转格式也好、缩放也好）
///    就变成一张静止的图，而结果看起来完全正常 —— 还是一张能显示的图，
///    谁也看不出丢了东西。这是最该避免的那类静默损失，所以宁可放弃缩放
///    带来的体积收益。
/// 2. **JPEG 保持 JPEG**：三家 API 和几乎所有网关都收 JPEG，没有转格式的
///    理由；而转成 PNG 会让一张照片**变大接近一倍**（实测 1.5MB → 2.6MB），
///    还要每轮重传。尺寸没超上限时连重编码都省掉 —— 二次压缩是纯损失。
/// 3. **其余一律转 PNG**：各家网关对格式的容忍度差别很大，PNG 是唯一一个
///    "填进去基本不会被拒"的；WebP 一半的自建网关不认，HEIC（现在手机默认
///    存这个）几乎没有云端认。而不认的时候未必报错 —— 实测见过网关把不认识
///    的字节当损坏图片解出一张花屏，然后模型一本正经地描述那张花屏。
///    认不出类型的（HEIC 就是这一类）也走这条，交给平台解码器试一次。
ImageDisposition dispositionFor({
  required String? mediaType,
  required List<int> bytes,
  required int longestSide,
  required int maxSide,
}) {
  if (isAnimated(mediaType, bytes)) return ImageDisposition.keep;
  if (mediaType == 'image/jpeg') {
    return longestSide > maxSide
        ? ImageDisposition.toJpeg
        : ImageDisposition.keep;
  }
  return ImageDisposition.toPng;
}

/// 会动吗。**和尺寸无关**，所以能在读图头之前就问。
///
/// 单独拎出来是因为踩过一次：调用方为了"先把会动的挡掉"而用一个假的
/// `longestSide: 0` 去问 [dispositionFor]，结果**每一张 JPEG 都因为
/// `0 > maxSide` 不成立而走了 keep** —— 大图再也不缩了，而且完全没有报错，
/// 只有去翻磁盘上的文件大小才看得出来。判断依据不同的两件事就不该共用
/// 同一个入口。
bool isAnimated(String? mediaType, List<int> bytes) =>
    mediaType == 'image/gif' ||
    (mediaType == 'image/png' && isAnimatedPng(bytes));

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
