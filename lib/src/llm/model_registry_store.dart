/// 模型能力表的取数：随包快照 → 磁盘缓存 → 联网刷新。
///
/// 三层缺一不可，各自挡住一种场景：
///
///   - **随包快照**挡住"刚装上、还没联网"。手机上第一次配渠道往往就是这个
///     状态，而那正是最需要能力提示的时刻。
///   - **磁盘缓存**挡住"每次启动都重拉"。表有 130KB，天天拉纯属浪费流量，
///     而模型能力是以周计变化的东西。
///   - **联网刷新**挡住"快照过期"。新模型发布后，装着旧版 app 的用户也该
///     认得它。
///
/// 两个源互为备份（抄 AstrBot 的做法）：`models.dev` 打不开就换
/// `models.opencode.ai`，同样的数据格式。两个都打不开就用手上已有的，
/// 静默降级 —— 拉不到能力表不是错误，只是少一个提示。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;

import 'model_registry.dart';

/// 缓存多久算新鲜。模型能力以周计变化，天天拉是白费流量。
const _cacheTtl = Duration(days: 7);

const _snapshotAsset = 'assets/model_registry.json';

/// 两个源，顺序就是优先级。
const modelRegistrySources = <String>[
  'https://models.dev/api.json',
  'https://models.opencode.ai/api.json',
];

/// 能力表的持有者。全局一份，启动时 [load] 一次，之后 [refresh] 在后台跑。
class ModelRegistryStore {
  ModelRegistryStore({required this.cacheFile, http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  final File cacheFile;
  final http.Client _http;

  ModelRegistry _registry = ModelRegistry.empty();
  ModelRegistry get registry => _registry;

  /// 表变了通知一下，界面上那些"官方标注"的提示要跟着刷新。
  final _changed = StreamController<void>.broadcast();
  Stream<void> get changes => _changed.stream;

  /// 缓存新鲜就用缓存，否则先用随包快照顶上。
  ///
  /// **不在这里等网络。** 这是启动路径，为了一个"提示性"的东西多等几秒
  /// 网络是不划算的；刷新交给 [refresh] 在后台做。
  Future<void> load() async {
    final cached = await _readCache();
    if (cached != null) {
      _apply(cached);
      return;
    }
    try {
      _apply(decodeRegistry(await rootBundle.loadString(_snapshotAsset)));
    } catch (_) {
      // 快照读不出来（资源没打进包）不该让 app 起不来，只是没有提示。
    }
  }

  /// 联网刷新。失败就保持现状，不抛。
  ///
  /// [force] 为假时，**手上已经有一份能用的新鲜缓存**才跳过 —— 每次启动
  /// 都拉一遍 130KB 没有意义。
  ///
  /// 判据是"读得出来"而不只是"文件够新"：写到一半断电留下的半个文件同样
  /// 很新，只看时间戳的话，这种坏缓存会把刷新挡整整七天，而那期间能力表
  /// 是空的 —— 一个本该自愈的问题变成了持续一周的静默失效。
  Future<bool> refresh({bool force = false}) async {
    if (!force && await _readCache() != null) return false;

    for (final url in modelRegistrySources) {
      try {
        final response = await _http
            .get(Uri.parse(url))
            .timeout(const Duration(seconds: 20));
        if (response.statusCode != 200) continue;
        // 响应体是 4MB 的 JSON，压平之后只留 130KB。压平放在这里而不是
        // 存原始响应：缓存文件小一个数量级，读的时候也不用每次重算。
        final models =
            flattenModelsDev(jsonDecode(utf8.decode(response.bodyBytes)));
        if (models.isEmpty) continue;
        await _writeCache(models);
        _apply(models);
        return true;
      } catch (_) {
        // 换下一个源。两个都不行就保持现在这份。
      }
    }
    return false;
  }

  void _apply(Map<String, ModelMeta> models) {
    if (models.isEmpty) return;
    _registry = ModelRegistry(models);
    if (!_changed.isClosed) _changed.add(null);
  }

  Future<bool> _cacheIsFresh() async {
    try {
      if (!await cacheFile.exists()) return false;
      final age = DateTime.now().difference(await cacheFile.lastModified());
      return age < _cacheTtl;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, ModelMeta>?> _readCache() async {
    try {
      if (!await _cacheIsFresh()) return null;
      final models = decodeRegistry(await cacheFile.readAsString());
      return models.isEmpty ? null : models;
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeCache(Map<String, ModelMeta> models) async {
    try {
      await cacheFile.parent.create(recursive: true);
      // 先写临时文件再 rename：直接覆盖时断电会留下半个文件，
      // 那种文件解析出来是空的，等于把好好的缓存弄丢了。
      final tmp = File('${cacheFile.path}.tmp');
      await tmp.writeAsString(encodeRegistry(models), flush: true);
      await tmp.rename(cacheFile.path);
    } catch (_) {
      // 写不进去（存储满了）只是下次还得重拉，不影响这次已经拿到的表。
    }
  }

  void dispose() {
    _changed.close();
    _http.close();
  }
}
