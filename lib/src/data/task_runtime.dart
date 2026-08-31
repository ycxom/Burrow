import 'dart:io';

import '../sandbox/sandbox_session.dart';
import '../sandbox/snapshot_store.dart';

Directory taskRootFor(Directory sandboxRoot, String taskId) {
  if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(taskId)) {
    throw ArgumentError.value(taskId, 'taskId', '包含不安全字符');
  }
  return Directory('${sandboxRoot.path}/tasks/$taskId');
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
