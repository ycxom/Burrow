import 'dart:io';

import 'package:burrow/src/data/task_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('不同任务映射到不同的隔离目录', () {
    final root = Directory('/app/sandbox');
    expect(
      taskRootFor(root, 'task_a').path,
      isNot(taskRootFor(root, 'task_b').path),
    );
    expect(taskRootFor(root, 'task_a').path, contains('tasks'));
  });

  test('任务 id 不能逃逸任务目录', () {
    expect(
      () => taskRootFor(Directory('/app/sandbox'), '../outside'),
      throwsArgumentError,
    );
  });
}
