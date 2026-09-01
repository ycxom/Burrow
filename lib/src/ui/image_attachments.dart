/// 选图、存图、显示图。
///
/// ## 为什么要拷一份
///
/// `image_picker` 交回来的文件在系统缓存目录里，随时会被清掉；而消息是要
/// 长期存的，界面上那张缩略图得三个月后还能打开。所以选完立刻拷进这个会话
/// 自己的目录 —— 会话删了，图跟着删，不用另做一套引用计数。
///
/// ## 为什么在选的时候就缩
///
/// 手机相机随手一张就是 12MP、4MB。base64 之后 5.3MB，一次请求发出去要
/// 十几秒，而且**每一轮都要重发一次**（历史里的图会跟着上下文一起再传）。
/// 缩到 1600px 长边、JPEG 质量 85，截图和照片都还看得清文字，体积落到
/// 一两百 KB。缩放交给 `image_picker` 的 maxWidth/imageQuality 在平台层做，
/// 不用把原图整个读进 Dart 堆。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'chat_theme.dart';

/// 长边上限。1600 是"截图上的小字还认得出"和"体积可接受"的折中。
const _maxPickDimension = 1600.0;

/// JPEG 质量。85 以下截图里的文字边缘开始出现可见的振铃。
const _pickQuality = 85;

/// 一次最多附几张。
///
/// 不是技术限制，是钱的限制：每张图都会跟着之后的每一轮重新上传。
/// 四张已经足够表达"这几屏是一件事"，再多基本是误操作。
const maxAttachments = 4;

class ImageAttachmentStore {
  ImageAttachmentStore(this.dir);

  /// 这个会话放图的目录。
  final Directory dir;

  final ImagePicker _picker = ImagePicker();

  /// 从相册挑几张。返回**已经拷进会话目录**的绝对路径。
  Future<List<String>> pickFromGallery({int limit = maxAttachments}) async {
    final picked = await _picker.pickMultiImage(
      maxWidth: _maxPickDimension,
      maxHeight: _maxPickDimension,
      imageQuality: _pickQuality,
    );
    if (picked.isEmpty) return const <String>[];
    return _adopt(picked.take(limit));
  }

  /// 现拍一张。
  Future<List<String>> pickFromCamera() async {
    final shot = await _picker.pickImage(
      source: ImageSource.camera,
      maxWidth: _maxPickDimension,
      maxHeight: _maxPickDimension,
      imageQuality: _pickQuality,
    );
    if (shot == null) return const <String>[];
    return _adopt(<XFile>[shot]);
  }

  Future<List<String>> _adopt(Iterable<XFile> files) async {
    await dir.create(recursive: true);
    final out = <String>[];
    for (final file in files) {
      // 用时间戳+序号命名，不用原文件名：相册里的名字可能重复，也可能带
      // 路径分隔符之外的怪字符。这里只需要唯一。
      final stamp = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
      final ext = _extensionOf(file.name);
      final target = File('${dir.path}/img_${stamp}_${out.length}$ext');
      await target.writeAsBytes(await file.readAsBytes());
      out.add(target.path);
    }
    return out;
  }

  static String _extensionOf(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return '.jpg';
    final ext = name.substring(dot).toLowerCase();
    // 只留认识的。缩放之后 image_picker 一律输出 JPEG，
    // 但 HEIC 之类的原扩展名有时会被原样带过来。
    const known = <String>{'.jpg', '.jpeg', '.png', '.gif', '.webp'};
    return known.contains(ext) ? ext : '.jpg';
  }
}

/// 输入框上面那排"待发送"的缩略图。
class AttachmentTray extends StatelessWidget {
  const AttachmentTray({
    super.key,
    required this.paths,
    required this.onRemove,
  });

  final List<String> paths;
  final void Function(String path) onRemove;

  @override
  Widget build(BuildContext context) {
    if (paths.isEmpty) return const SizedBox.shrink();
    final t = context.chat;
    return Container(
      color: t.composerBg,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: SizedBox(
        height: 62,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: paths.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (_, i) => _Thumb(
            path: paths[i],
            onRemove: () => onRemove(paths[i]),
          ),
        ),
      ),
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.path, required this.onRemove});

  final String path;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final t = context.chat;
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.file(
            File(path),
            width: 62,
            height: 62,
            fit: BoxFit.cover,
            // 缩略图只要 62pt，解码到 186px（3x）就够。不给这个参数的话
            // Flutter 会把整张图按原分辨率解进内存，四张就是几十 MB。
            cacheWidth: 186,
            errorBuilder: (_, __, ___) => Container(
              width: 62,
              height: 62,
              color: t.bgSecondary,
              child: Icon(Icons.broken_image_outlined,
                  size: 20, color: t.tintTertiary),
            ),
          ),
        ),
        Positioned(
          top: -6,
          right: -6,
          child: GestureDetector(
            onTap: onRemove,
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: t.bgPrimary,
                shape: BoxShape.circle,
                boxShadow: const <BoxShadow>[
                  BoxShadow(color: Color(0x33000000), blurRadius: 3),
                ],
              ),
              child: Icon(Icons.close, size: 14, color: t.tintSecondary),
            ),
          ),
        ),
      ],
    );
  }
}

/// 气泡里的图。
///
/// 一张时占满气泡宽度，多张时两列网格 —— 和 Telegram 的相册排版同一个思路：
/// 一张图值得看清，四张图是"一组材料"，看清每一张不是重点。
class BubbleImages extends StatelessWidget {
  const BubbleImages({
    super.key,
    required this.paths,
    required this.maxWidth,
  });

  final List<String> paths;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    if (paths.isEmpty) return const SizedBox.shrink();
    final radius = BorderRadius.circular(10);
    if (paths.length == 1) {
      return ClipRRect(
        borderRadius: radius,
        child: _tappable(context, paths.first,
            child: ConstrainedBox(
              // 高度封顶，否则一张长截图会把整屏撑满，
              // 用户要滚很久才看得到自己那句话。
              constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: 320),
              child: _image(context, paths.first, cacheWidth: 900),
            )),
      );
    }

    const gap = 3.0;
    final side = (maxWidth - gap) / 2;
    return Wrap(
      spacing: gap,
      runSpacing: gap,
      children: <Widget>[
        for (final path in paths)
          ClipRRect(
            borderRadius: radius,
            child: _tappable(context, path,
                child: SizedBox(
                  width: side,
                  height: side,
                  child: _image(context, path, cacheWidth: 600, cover: true),
                )),
          ),
      ],
    );
  }

  Widget _tappable(BuildContext context, String path,
          {required Widget child}) =>
      GestureDetector(
        onTap: () => showImageViewer(context, paths, paths.indexOf(path)),
        child: child,
      );

  Widget _image(BuildContext context, String path,
          {required int cacheWidth, bool cover = false}) =>
      Image.file(
        File(path),
        fit: cover ? BoxFit.cover : BoxFit.contain,
        alignment: Alignment.topLeft,
        cacheWidth: cacheWidth,
        errorBuilder: (_, __, ___) => Container(
          height: 80,
          alignment: Alignment.center,
          color: context.chat.bgSecondary,
          child: Text(
            '图片已不在',
            style: TextStyle(fontSize: 12, color: context.chat.tintTertiary),
          ),
        ),
      );
}

/// 点开看大图。可缩放、可左右翻。
Future<void> showImageViewer(
        BuildContext context, List<String> paths, int index) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => _ImageViewer(paths: paths, initial: index),
      ),
    );

class _ImageViewer extends StatefulWidget {
  const _ImageViewer({required this.paths, required this.initial});

  final List<String> paths;
  final int initial;

  @override
  State<_ImageViewer> createState() => _ImageViewerState();
}

class _ImageViewerState extends State<_ImageViewer> {
  late final PageController _pages =
      PageController(initialPage: widget.initial);
  late int _current = widget.initial;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: Text(
            widget.paths.length > 1
                ? '${_current + 1} / ${widget.paths.length}'
                : '',
            style: const TextStyle(fontSize: 15),
          ),
        ),
        body: PageView.builder(
          controller: _pages,
          itemCount: widget.paths.length,
          onPageChanged: (i) => setState(() => _current = i),
          itemBuilder: (_, i) => InteractiveViewer(
            minScale: 1,
            maxScale: 5,
            child: Center(
              child: Image.file(
                File(widget.paths[i]),
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => const Text(
                  '图片已不在',
                  style: TextStyle(color: Colors.white70),
                ),
              ),
            ),
          ),
        ),
      );
}
