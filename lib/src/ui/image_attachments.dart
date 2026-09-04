/// 选图、存图、显示图。
///
/// ## 为什么要拷一份
///
/// `image_picker` 交回来的文件在系统缓存目录里，随时会被清掉；而消息是要
/// 长期存的，界面上那张缩略图得三个月后还能打开。所以选完立刻拷进这个会话
/// 自己的目录 —— 会话删了，图跟着删（见 `reclaimThreadAttachments`）。
///
/// ## 为什么按内容哈希命名
///
/// 同一张图只占一份，而且**"还有没有人要"变成一个可判定的问题**：文件名就是
/// 内容，那么"这个文件还被引用吗"等价于"这个路径还出现在某条消息或某个分支
/// 版本里吗"。回收因此不需要一个会漂的计数器，只要比对两个集合 ——
/// 见 [reclaimOrphanImages]。
///
/// ## 为什么在选的时候就缩、就转格式
///
/// 手机相机随手一张就是 12MP、4MB，而且**每一轮都要重发一次**（历史里的图
/// 会跟着上下文一起再传）。缩到 1600px 长边之后体积落到能接受的范围，
/// 而且这件事只做一次。
///
/// 格式同理：统一成 PNG（见 image_transcode.dart），后面就不用每次发送前
/// 再解码编码一遍。
///
/// **缩放和编码都自己做，不用 `image_picker` 的 `maxWidth`/`imageQuality`。**
/// 那两个参数会让平台层重新编码，而重新编码会把 GIF 拍成一张静态 JPEG ——
/// 动图就这么没了，且看不出来。
library;

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'chat_theme.dart';
import 'image_transcode.dart';

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

  /// 从相册挑几张。返回**已经转好格式、拷进会话目录**的绝对路径。
  Future<List<String>> pickFromGallery({int limit = maxAttachments}) async {
    // 不传 maxWidth/imageQuality：要的是原图，缩放和编码自己做。
    final picked = await _picker.pickMultiImage();
    if (picked.isEmpty) return const <String>[];
    return _adopt(picked.take(limit));
  }

  /// 现拍一张。
  Future<List<String>> pickFromCamera() async {
    final shot = await _picker.pickImage(source: ImageSource.camera);
    if (shot == null) return const <String>[];
    return _adopt(<XFile>[shot]);
  }

  /// 拷进会话目录，**按内容哈希命名**。
  ///
  /// 不用原文件名（相册里的名字会重复，也可能带怪字符），也不用时间戳 ——
  /// 时间戳只保证唯一，而这里要的是**同一张图只占一份**：
  ///
  ///   - 同一张截图发两次（很常见：先问一遍、答得不对再问一遍），
  ///     时间戳命名会在磁盘上留两份一模一样的几百 KB。
  ///   - 「编辑重发」会把同一条消息连同它的图重新走一遍这条路；
  ///     没有内容寻址的话，每编辑一次就多一份。
  ///
  /// 而且哈希名让回收变得可判定：一个文件还有没有人要，等价于"它的路径
  /// 还出现在某条消息或某个分支版本里吗"。见 [reclaimOrphanImages]。
  Future<List<String>> _adopt(Iterable<XFile> files) async {
    await dir.create(recursive: true);
    final out = <String>[];
    for (final file in files) {
      final transcoded = await transcodeForUpload(await file.readAsBytes());
      final digest = sha256.convert(transcoded.bytes).toString();
      final target = File('${dir.path}/$digest${transcoded.extension}');
      // 已经有了就不重写。内容一样，路径也就一样 —— 去重是这个命名方式的
      // 附赠品，不是另做的一件事。
      if (!await target.exists()) {
        await target.writeAsBytes(transcoded.bytes);
      }
      // 同一批里挑了两张一样的图时路径会重复。去掉重复的那条 ——
      // 让同一张图在一条消息里出现两次没有意义，只会多发一次。
      if (!out.contains(target.path)) out.add(target.path);
    }
    return out;
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
    final t = context.chat;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      transitionBuilder: (child, animation) {
        return SizeTransition(
          sizeFactor: animation,
          axisAlignment: -1,
          child: FadeTransition(opacity: animation, child: child),
        );
      },
      child: paths.isEmpty
          ? const SizedBox.shrink()
          : Container(
              key: const ValueKey('attachment_tray'),
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
