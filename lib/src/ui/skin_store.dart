/// 已安装皮肤包的磁盘层。
///
/// ## 装在哪：app 私有目录，**不是** rootfs
///
/// Skill 装进 rootfs 是因为模型要在沙箱里执行它。皮肤是纯宿主 UI，装进 rootfs
/// 会踩两个坑：rootfs 会被「代目录 + 原子 rename」整个换掉，用户换个发行版皮肤
/// 就没了；而且没装发行版时（降级模式）根本没有 rootfs，那样连主题都起不来。
///
/// ```
/// <appSupport>/skins/<sanitized-id>/skin.json
/// <appSupport>/skins/<sanitized-id>/assets/...
/// ```
///
/// ## 没有索引文件
///
/// [SkillStore] 需要索引是因为它要记住"这个 skill 来自哪个仓库、开没开"这些
/// 磁盘上没有的信息。皮肤包没有这类状态 —— 目录在就是装了，当前选中哪个存在
/// SharedPreferences 里。所以直接扫目录，**索引和磁盘不可能不一致**，因为
/// 根本没有索引。
///
/// ## 启动时机
///
/// [open] 必须在 `runApp` 之前 await 完。异步在首帧之后加载会闪一下默认主题，
/// 而主题闪烁是那种"看着就很廉价"的 bug。代价是启动时多读几个小 JSON。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../bootstrap/zip_reader.dart';
import 'chat_skin.dart';
import 'skin_manifest.dart';

class SkinInstallException implements Exception {
  const SkinInstallException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 一个装不上或装坏了的皮肤包。留着是为了在外观页把原因说出来 ——
/// 静默消失会让作者以为是自己文件放错了地方。
@immutable
class BrokenSkin {
  const BrokenSkin({required this.directory, required this.reasons});
  final String directory;
  final List<String> reasons;
}

class ChatSkinStore extends ChangeNotifier {
  ChatSkinStore({required this.root});

  /// `<appSupport>/skins`。
  final Directory root;

  final List<ChatSkinPack> _packs = <ChatSkinPack>[];
  final List<BrokenSkin> _broken = <BrokenSkin>[];

  List<ChatSkinPack> get packs => List<ChatSkinPack>.unmodifiable(_packs);
  List<BrokenSkin> get broken => List<BrokenSkin>.unmodifiable(_broken);

  static const _manifestName = 'skin.json';

  /// manifest 本身的上限。一个纯数据的 JSON 到不了这个量级 ——
  /// 到了说明它不是 manifest。
  static const _maxManifestBytes = 256 * 1024;
  static const _maxAssetBytes = 8 * 1024 * 1024;
  static const _maxPackBytes = 20 * 1024 * 1024;
  static const _maxAssets = 16;

  Future<void> open() async {
    _packs.clear();
    _broken.clear();
    if (!await root.exists()) return;

    await for (final entity in root.list()) {
      if (entity is! Directory) continue;
      // 安装过程中断留下的代目录，跳过并顺手清掉。
      if (entity.path.endsWith('.staging')) {
        await entity.delete(recursive: true).catchError((_) => entity);
        continue;
      }
      final result = await _load(entity);
      if (result != null) _packs.add(result);
    }
    _packs.sort((a, b) => a.name.compareTo(b.name));
    notifyListeners();
  }

  Future<ChatSkinPack?> _load(Directory dir) async {
    final name = p.basename(dir.path);
    final file = File(p.join(dir.path, _manifestName));
    if (!await file.exists()) {
      _broken.add(BrokenSkin(
        directory: name,
        reasons: const <String>['缺少 $_manifestName'],
      ));
      return null;
    }
    try {
      if (await file.length() > _maxManifestBytes) {
        _broken.add(BrokenSkin(
          directory: name,
          reasons: const <String>['$_manifestName 过大'],
        ));
        return null;
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) {
        _broken.add(BrokenSkin(
          directory: name,
          reasons: const <String>['$_manifestName 的顶层必须是一个对象'],
        ));
        return null;
      }
      final result = SkinManifest.parse(
        decoded.cast<String, Object?>(),
        assetRoot: dir.path,
      );
      if (!result.ok) {
        _broken.add(BrokenSkin(directory: name, reasons: result.errors));
        return null;
      }
      return result.pack;
    } on FormatException catch (e) {
      _broken.add(BrokenSkin(
        directory: name,
        reasons: <String>['$_manifestName 不是合法 JSON：${e.message}'],
      ));
      return null;
    } on FileSystemException catch (e) {
      _broken.add(BrokenSkin(directory: name, reasons: <String>['读取失败：${e.message}']));
      return null;
    }
  }

  /// 从一段 JSON 文本安装。剪贴板导入走这条 —— 纯令牌的皮肤包就是一段文本，
  /// 让"分享一个皮肤"的门槛从"打包"降到"发一段字"。
  Future<ChatSkinPack> installFromJson(String text) async {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException catch (e) {
      throw SkinInstallException('不是合法的 JSON：${e.message}');
    }
    if (decoded is! Map) {
      throw const SkinInstallException('皮肤包的顶层必须是一个 JSON 对象');
    }
    final map = decoded.cast<String, Object?>();

    // 先按"没有随行资源"解析一次做校验。这一遍的 assetRoot 为 null，
    // 所以包里如果引用了图片会被丢掉 —— 纯文本导入本来就带不了图片。
    final check = SkinManifest.parse(map);
    if (!check.ok) throw SkinInstallException(check.errors.join('\n'));

    final target = await _prepare(check.pack!.id);
    await File(p.join(target.path, _manifestName)).writeAsString(text);
    return _finish(target);
  }

  /// 从一个 `.json` 或 `.zip` 文件安装。
  Future<ChatSkinPack> installFromFile(File file) async {
    if (!await file.exists()) {
      throw const SkinInstallException('文件不存在');
    }
    final extension = p.extension(file.path).toLowerCase();
    if (extension == '.json') {
      if (await file.length() > _maxManifestBytes) {
        throw const SkinInstallException('皮肤包描述文件过大');
      }
      return installFromJson(await file.readAsString());
    }
    if (extension != '.zip' && extension != '.burrowskin') {
      throw const SkinInstallException('只支持 .json 或 .zip 皮肤包');
    }
    if (await file.length() > _maxPackBytes) {
      throw const SkinInstallException('皮肤包不能超过 20 MB');
    }
    return _installZip(file);
  }

  Future<ChatSkinPack> _installZip(File file) async {
    final zip = await ZipReader.open(file);
    try {
      final entries = await zip.entries();

      // manifest 可以在根目录，也可以在单层子目录下 —— 大多数人是把一个
      // 文件夹右键"压缩"，那样出来的 zip 天然多一层。
      ZipEntry? manifest;
      for (final entry in entries) {
        final name = entry.name.replaceAll('\\', '/');
        if (name == _manifestName || name.endsWith('/$_manifestName')) {
          if (manifest == null ||
              '/'.allMatches(name).length <
                  '/'.allMatches(manifest.name).length) {
            manifest = entry;
          }
        }
      }
      if (manifest == null) {
        throw const SkinInstallException('压缩包里找不到 skin.json');
      }

      final prefix = manifest.name.substring(
        0,
        manifest.name.length - _manifestName.length,
      );
      final text = utf8.decode(await zip.read(manifest), allowMalformed: true);
      final Object? decoded;
      try {
        decoded = jsonDecode(text);
      } on FormatException catch (e) {
        throw SkinInstallException('skin.json 不是合法 JSON：${e.message}');
      }
      if (decoded is! Map) {
        throw const SkinInstallException('skin.json 的顶层必须是一个对象');
      }
      final map = decoded.cast<String, Object?>();
      final check = SkinManifest.parse(map);
      if (!check.ok) throw SkinInstallException(check.errors.join('\n'));

      final target = await _prepare(check.pack!.id);
      final staging = Directory('${target.path}.staging');
      if (await staging.exists()) await staging.delete(recursive: true);
      await staging.create(recursive: true);

      try {
        await File(p.join(staging.path, _manifestName)).writeAsString(text);

        var assets = 0;
        var bytes = 0;
        for (final entry in entries) {
          if (identical(entry, manifest)) continue;
          final name = entry.name.replaceAll('\\', '/');
          if (!name.startsWith(prefix)) continue;
          final relative = name.substring(prefix.length);
          if (relative.isEmpty || relative.endsWith('/')) continue;
          if (relative == _manifestName) continue;

          // 路径逃逸检查。归档内容完全由第三方控制，一个 `../../` 条目就能
          // 写到私有目录里任何地方。静默跳过而不是中止 —— 一个坏条目不该让
          // 整个皮肤装不上，而放它进去等于把私有目录交出去。
          final out = File(p.normalize(p.join(staging.path, relative)));
          if (!p.isWithin(staging.path, out.path)) continue;

          if (++assets > _maxAssets) continue;
          final data = await zip.read(entry);
          if (data.length > _maxAssetBytes) continue;
          bytes += data.length;
          if (bytes > _maxPackBytes) {
            throw const SkinInstallException('皮肤包解开后过大');
          }
          await out.parent.create(recursive: true);
          await out.writeAsBytes(data);
        }

        // 解到代目录再原子 rename，和发行版安装用的是同一招：中途失败等于
        // 什么都没发生，绝不留下半个皮肤包。
        if (await target.exists()) await target.delete(recursive: true);
        await staging.rename(target.path);
      } catch (_) {
        if (await staging.exists()) await staging.delete(recursive: true);
        rethrow;
      }

      return await _finish(target);
    } finally {
      await zip.close();
    }
  }

  Future<Directory> _prepare(String id) async {
    final target = Directory(p.join(root.path, _sanitize(id)));
    await target.create(recursive: true);
    return target;
  }

  /// 装完重新读一遍磁盘，返回真正被装上的那个包。
  ///
  /// 不直接返回校验时解析出来的对象：那一份的 assetRoot 是 null，图片引用
  /// 全被丢掉了。以磁盘为准才是用户接下来会看到的东西。
  Future<ChatSkinPack> _finish(Directory target) async {
    final pack = await _load(target);
    if (pack == null) {
      await target.delete(recursive: true).catchError((_) => target);
      throw const SkinInstallException('皮肤包写入后无法读回');
    }
    _packs.removeWhere((p) => p.id == pack.id);
    _packs
      ..add(pack)
      ..sort((a, b) => a.name.compareTo(b.name));
    _broken.removeWhere((b) => b.directory == p.basename(target.path));
    notifyListeners();
    return pack;
  }

  Future<void> uninstall(String id) async {
    final dir = Directory(p.join(root.path, _sanitize(id)));
    if (await dir.exists()) await dir.delete(recursive: true);
    _packs.removeWhere((pack) => pack.id == id);
    _broken.removeWhere((b) => b.directory == _sanitize(id));
    notifyListeners();
  }

  Future<void> removeBroken(String directory) async {
    final dir = Directory(p.join(root.path, directory));
    if (await dir.exists()) await dir.delete(recursive: true);
    _broken.removeWhere((b) => b.directory == directory);
    notifyListeners();
  }

  /// ID 里的 `/` 换成 `.`，其余非法字符换成 `_`。
  ///
  /// 直接拿 ID 当目录名的话，`作者/皮肤` 会变成一层嵌套目录，扫描时就找不到
  /// 它的 skin.json 了。
  static String _sanitize(String id) =>
      id.replaceAll('/', '.').replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
}
