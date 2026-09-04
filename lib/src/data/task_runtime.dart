import 'dart:io';

import '../sandbox/sandbox_session.dart';
import '../sandbox/snapshot_store.dart';

Directory taskRootFor(Directory sandboxRoot, String taskId) {
  if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(taskId)) {
    throw ArgumentError.value(taskId, 'taskId', '包含不安全字符');
  }
  return Directory('${sandboxRoot.path}/tasks/$taskId');
}

/// 删掉一个会话在磁盘上留下的**附件**：图片和归档的命令输出。
///
/// [tasksRoot] 是 `sandbox/tasks`，[taskId] 对已存盘的会话就是它的 threadId。
///
/// ## 删什么、不删什么
///
/// **不碰 workspace 和检查点。** 删除对话框明确承诺了那两样不受影响，而那个
/// 承诺是对的：workspace 是任务的产物，用户可能还要用里面的文件；想连它一起
/// 清有「默认工作目录」那一页。
///
/// 但图片和归档输出**是聊天记录的一部分**：它们只被消息引用，记录一删就再没
/// 有任何东西指得到它们。留着就是纯粹的占地方 —— 一张手机照片压完也有几百
/// KB，而用户在界面上完全看不到它们还在。
///
/// **不抛。** 删会话是用户已经确认过的动作，不该因为某个文件被占着就整个失败
/// —— 那会让人以为会话没删掉。返回释放了多少字节，0 表示没东西可删。
Future<int> reclaimThreadAttachments(Directory tasksRoot, String taskId) async {
  if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(taskId)) return 0;
  var freed = 0;
  for (final name in const <String>['images', 'outputs']) {
    final dir = Directory('${tasksRoot.path}/$taskId/$name');
    try {
      if (!await dir.exists()) continue;
      await for (final entry in dir.list(recursive: true, followLinks: false)) {
        if (entry is File) freed += await entry.length();
      }
      await dir.delete(recursive: true);
    } catch (_) {
      // 单个目录删不掉不影响另一个，也不影响会话本身已经删掉的事实。
    }
  }
  return freed;
}

/// 删掉没人引用的图片。
///
/// [referenced] 是**全库**还引用得到的图片路径（见
/// `ChatStore.referencedImagePaths`）。它的 `complete` 为 false 时**一张都不
/// 删** —— 那表示库里有一处读不出来，也就不知道它引用了什么，而"不知道"和
/// "没引用"是两回事。[scope] 为空 = 扫全部会话；给了就只扫那几个会话的目录
/// —— 一次编辑重发只会让一个会话产生孤儿，没必要每次都走一遍全部会话的磁盘。
///
/// ## 为什么是"比对集合"而不是引用计数
///
/// 图片按内容哈希命名（见 ImageAttachmentStore），所以"这个文件还有没有人要"
/// 等价于"它的路径还出现在某条消息或某个分支版本里吗" —— 一个可以每次重新
/// 算出来的事实，而不是一个要靠每条增删路径都记得维护、漏一次就永远错下去
/// 的计数器。和 `ChatStore.compact` 重算段引用是同一个取向。
///
/// ## 为什么要接受"多留"，绝不"多删"
///
/// 算错的两个方向代价完全不对等：多留一张图是几百 KB，而多删一张是用户翻回
/// 三个月前那条消息时看到一个裂图 —— 不可恢复。所以任何一处解析不出来、
/// 查不到、拿不准的地方，一律当成"还有人要"。
Future<int> reclaimOrphanImages(
  Directory tasksRoot,
  ({Set<String> paths, bool complete}) referenced, {
  Iterable<String> scope = const <String>[],
}) async {
  if (!referenced.complete) return 0;
  if (!await tasksRoot.exists()) return 0;

  final List<Directory> dirs;
  if (scope.isEmpty) {
    dirs = <Directory>[
      await for (final entry in tasksRoot.list(followLinks: false))
        if (entry is Directory) Directory('${entry.path}/images'),
    ];
  } else {
    dirs = <Directory>[
      for (final id in scope)
        if (RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(id))
          Directory('${tasksRoot.path}/$id/images'),
    ];
  }

  // 两道保险，命中任何一道都当成"还有人要"：
  //
  //   1. **整条路径**（分隔符归一化过）—— 正常情况走这条。库里存的和磁盘上
  //      列出来的本该一模一样，但两边是不同代码拼出来的，混用 `/` 和 `\\`
  //      迟早撞上一次；而撞上的后果是所有图都判成孤儿，一次全删光。
  //   2. **文件名** —— 文件名就是内容哈希，同名即同图。它兜的是"库里存的
  //      绝对路径整体失效"那一类事故（应用数据目录被搬过、从备份恢复过）。
  //      那时候第一道全不命中，而没有第二道就是把用户所有的图删干净。
  //
  // 第二道的代价：同一张图存在两个会话里、只有一个还被引用时，两份都留着。
  // 几百 KB 换一个不可恢复的事故不会发生，这个交换很划算。
  String slash(String path) => path.replaceAll('\\', '/');
  final keepPaths = <String>{
    for (final path in referenced.paths) slash(path),
  };
  final keepNames = <String>{
    for (final path in keepPaths) path.split('/').last,
  };

  var freed = 0;
  for (final dir in dirs) {
    try {
      if (!await dir.exists()) continue;
      await for (final entry in dir.list(followLinks: false)) {
        if (entry is! File) continue;
        final path = slash(entry.path);
        if (keepPaths.contains(path)) continue;
        if (keepNames.contains(path.split('/').last)) continue;
        final size = await entry.length();
        await entry.delete();
        freed += size;
      }
    } catch (_) {
      // 一个目录扫不动不影响别的。这是回收，不是用户在等结果的操作。
    }
  }
  return freed;
}

class TaskRuntime {
  const TaskRuntime({
    required this.id,
    required this.sandbox,
    required this.snapshots,
    required this.root,
  });

  final String id;
  final SandboxSession sandbox;
  final SnapshotStore snapshots;
  final Directory root;
}
