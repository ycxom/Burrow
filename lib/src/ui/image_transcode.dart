/// 选图时的**前置格式转换**。三条规则见 [dispositionFor]，这里只管落实。
///
/// ## 为什么在选图时做，不在发送时做
///
/// 历史里的图**每一轮都会跟着上下文重新上传**。发送时转的话，同一张图会被
/// 反复解码编码几十次。选完存成最终形态，后面一直用那一份。
///
/// ## 为什么解码走 `dart:ui`
///
/// 平台解码器认得 **HEIC**（现在手机默认存这个格式），纯 Dart 的图像库不认。
/// 而且它是硬件加速的，缩放能直接在解码阶段做（`targetWidth`），比先把整图
/// 解出来再缩省一大截内存 —— 一张 12MP 的图全解出来是 48MB 的 RGBA。
///
/// 编码分两条路：PNG 用 `dart:ui` 自带的编码器（原生、快）；JPEG 它不支持，
/// 只能用 `package:image` 从原始 RGBA 编。
///
/// ## 一个坑
///
/// **不能用 `image_picker` 的 `maxWidth`/`imageQuality`**：那两个参数会让
/// 平台层重新编码，GIF 进去出来就是一张静态 JPEG —— 动图在我们拿到它之前
/// 就已经没了。必须让 picker 交回原图。
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image/image.dart' as img;

import '../llm/image_parts.dart';

/// 转换结果。
class TranscodedImage {
  /// 最终要落盘的字节。
  final Uint8List bytes;

  /// `image/png` 之类。和 [bytes] 一致。
  final String mediaType;

  /// 文件扩展名，带点。
  final String extension;

  /// 真的重新编码过（false = 原样留下）。
  final bool converted;

  const TranscodedImage({
    required this.bytes,
    required this.mediaType,
    required this.extension,
    required this.converted,
  });
}

/// 长边上限。1600 是"截图上的小字还认得出"和"体积可接受"的折中。
const maxImageDimension = 1600;

/// 重新编码 JPEG 时的质量。
///
/// 85 以下截图里的文字边缘开始出现可见的振铃 —— 而截图恰好是这个 app 里
/// 最常发的一类图，图里那几行报错正是要看清的东西。
const jpegQuality = 85;

/// 把一张图变成可以直接发出去的样子。
Future<TranscodedImage> transcodeForUpload(Uint8List original) async {
  final mediaType = sniffMediaType(original);

  TranscodedImage keep() => TranscodedImage(
        bytes: original,
        mediaType: mediaType ?? 'application/octet-stream',
        extension: _extensionFor(mediaType),
        converted: false,
      );

  // 会动的先挡掉：连图头都不用读 —— 无论多大都不动它。
  //
  // 这里问的是 [isAnimated] 而不是 [dispositionFor]：后者要尺寸才答得准，
  // 拿一个假尺寸去问，JPEG 会被误判成 keep（真机上踩过）。
  if (isAnimated(mediaType, original)) return keep();

  try {
    final descriptor = await ui.ImageDescriptor.encoded(
      await ui.ImmutableBuffer.fromUint8List(original),
    );
    final longest = descriptor.width > descriptor.height
        ? descriptor.width
        : descriptor.height;

    final disposition = dispositionFor(
      mediaType: mediaType,
      bytes: original,
      longestSide: longest,
      maxSide: maxImageDimension,
    );
    // 尺寸够小的 JPEG 到这里才判得出来 —— 省掉一次纯亏的二次压缩。
    if (disposition == ImageDisposition.keep) {
      descriptor.dispose();
      return keep();
    }

    final image = await _decode(descriptor, longest);
    try {
      if (disposition == ImageDisposition.toJpeg) {
        return TranscodedImage(
          bytes: await _encodeJpeg(image),
          mediaType: 'image/jpeg',
          extension: '.jpg',
          converted: true,
        );
      }
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw StateError('PNG 编码返回空');
      return TranscodedImage(
        bytes: data.buffer.asUint8List(),
        mediaType: 'image/png',
        extension: '.png',
        converted: true,
      );
    } finally {
      image.dispose();
    }
  } catch (_) {
    // 转不了就原样留着。这时多半是个我们不认识、平台也解不开的格式，
    // 而**原样发出去至少能拿到服务端的报错**；在这里失败掉的话，
    // 用户只知道"这张图加不进来"，没有任何下一步线索。
    return keep();
  }
}

/// 解码，顺便在解码阶段就缩到上限以内。
Future<ui.Image> _decode(ui.ImageDescriptor descriptor, int longest) async {
  ui.Codec codec;
  if (longest > maxImageDimension) {
    final scale = maxImageDimension / longest;
    codec = await descriptor.instantiateCodec(
      targetWidth: (descriptor.width * scale).round().clamp(1, 1 << 16),
      targetHeight: (descriptor.height * scale).round().clamp(1, 1 << 16),
    );
  } else {
    codec = await descriptor.instantiateCodec();
  }
  try {
    final frame = await codec.getNextFrame();
    return frame.image;
  } finally {
    codec.dispose();
    descriptor.dispose();
  }
}

/// `dart:ui` 只会编 PNG，JPEG 得自己来。
Future<Uint8List> _encodeJpeg(ui.Image image) async {
  final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (rgba == null) throw StateError('取原始像素失败');
  final buffer = img.Image.fromBytes(
    width: image.width,
    height: image.height,
    bytes: rgba.buffer,
    numChannels: 4,
  );
  return img.encodeJpg(buffer, quality: jpegQuality);
}

String _extensionFor(String? mediaType) => switch (mediaType) {
      'image/jpeg' => '.jpg',
      'image/png' => '.png',
      'image/gif' => '.gif',
      'image/webp' => '.webp',
      _ => '.bin',
    };
