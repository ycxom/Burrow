/// 工具定义与只读/写入工具的实现。
///
/// 工具集的取舍原则：**能走工具层的就别走 shell**。
/// 每一个从 `exec` 挪到专用工具的操作，都换来一次精确的、零扫描的回滚记录
/// （见 SnapshotStore 的三条写入路径）。所以 `write_file` / `apply_patch`
/// 不是 `exec` 的便利包装，它们是回滚机制的一部分。
library;

import 'dart:convert';
import 'dart:io';

import '../sandbox/snapshot_store.dart';

class ToolSpec {
  final String name;
  final String description;
  final Map<String, Object?> parameters; // JSON Schema
  const ToolSpec(this.name, this.description, this.parameters);

  Map<String, Object?> toOpenAiJson() => {
        'type': 'function',
        'function': {
          'name': name,
          'description': description,
          'parameters': parameters,
        },
      };
}

class ToolCall {
  final String id;
  final String name;
  final Map<String, Object?> args;
  const ToolCall({required this.id, required this.name, required this.args});
}

class ToolResult {
  final String content;
  final String? outputRef;
  final bool rejected;

  const ToolResult.ok(this.content, {this.outputRef}) : rejected = false;
  const ToolResult.rejected(this.content)
      : outputRef = null,
        rejected = true;
}

const readOnlyTools = {'read_file', 'list_dir', 'grep', 'grep_output', 'recall_memory'};

// ---------------------------------------------------------------------------
// 定义
// ---------------------------------------------------------------------------

Map<String, Object?> _obj(Map<String, Object?> props, List<String> required) =>
    {'type': 'object', 'properties': props, 'required': required};

Map<String, Object?> _str(String desc) => {'type': 'string', 'description': desc};
Map<String, Object?> _int(String desc) => {'type': 'integer', 'description': desc};

final allToolSpecs = <ToolSpec>[
  ToolSpec(
    'exec',
    '在沙箱内执行一条 shell 命令。输出会被自动压缩后返回，'
        '需要完整输出时用 grep_output 按 ref 检索。'
        '优先用 read_file / write_file / apply_patch 而不是 cat / echo > / sed -i —— '
        '专用工具的改动可以被精确回滚，shell 里的不行。',
    _obj({
      'command': _str('要执行的命令行'),
      'timeout': _int('超时秒数，默认 300'),
    }, ['command']),
  ),

  ToolSpec('read_file', '读取 workspace 内的文件',
      _obj({'path': _str('相对 workspace 的路径'), 'offset': _int('起始行，从 1 开始'), 'limit': _int('读多少行，默认 2000')}, ['path'])),

  ToolSpec('list_dir', '列出目录内容',
      _obj({'path': _str('相对 workspace 的路径，默认 .')}, [])),

  ToolSpec('grep', '在 workspace 内按正则搜索文件内容',
      _obj({'pattern': _str('正则'), 'path': _str('搜索起点，默认 .'), 'glob': _str('文件名过滤，如 *.dart')}, ['pattern'])),

  ToolSpec(
    'write_file',
    '写入文件（覆盖）。旧内容会在写入前自动存档，可精确回滚。',
    _obj({'path': _str('相对 workspace 的路径'), 'content': _str('完整内容')}, ['path', 'content']),
  ),

  ToolSpec(
    'apply_patch',
    '对已有文件做精确替换。old 必须在文件中唯一出现，否则报错 —— '
        '这是刻意的：不唯一说明你对文件内容的理解有偏差，盲目替换会改错地方。',
    _obj({'path': _str('相对 workspace 的路径'), 'old': _str('要被替换的原文'), 'new': _str('替换成的内容')},
        ['path', 'old', 'new']),
  ),

  ToolSpec('checkpoint', '创建一个检查点。动手做有风险的改动之前调用它。',
      _obj({'reason': _str('一句话说明这个检查点对应什么阶段')}, [])),

  ToolSpec('list_checkpoints', '列出可回滚的检查点', _obj({}, [])),

  ToolSpec(
    'rollback',
    '回滚 workspace 到指定检查点。'
        '搞砸了就用它 —— 回滚很便宜，不要因为怕丢工作而在坏状态上继续修补。',
    _obj({'generation': _int('目标检查点编号')}, ['generation']),
  ),

  ToolSpec('grep_output', '在某次命令的完整输出里按正则检索（输出被压缩后用这个看细节）',
      _obj({'ref': _str('命令返回里的 ref'), 'pattern': _str('正则')}, ['ref', 'pattern'])),

  ToolSpec('recall_memory', '检索被摘要挤出上下文的早期对话记录',
      _obj({'query': _str('检索关键词')}, ['query'])),
];

// ---------------------------------------------------------------------------
// 只读工具
// ---------------------------------------------------------------------------

Future<ToolResult> runReadOnlyTool(ToolCall call, String workspace) async {
  String resolve(String? rel) {
    final p = rel ?? '.';
    // 路径逃逸检查。proot 已经挡了一层，但只读工具不走 proot（直接在 Dart 里
    // 读文件），所以这层必须自己做 —— 否则 `../../../../data/data/xxx` 就出去了。
    final full = File('$workspace/$p').absolute.path;
    final root = Directory(workspace).absolute.path;
    if (!full.startsWith(root)) {
      throw ArgumentError('路径 $p 超出 workspace 范围');
    }
    return full;
  }

  try {
    switch (call.name) {
      case 'read_file':
        final f = File(resolve(call.args['path'] as String?));
        if (!await f.exists()) return ToolResult.ok('文件不存在：${call.args['path']}');
        final lines = await f.readAsLines();
        final offset = ((call.args['offset'] as num?)?.toInt() ?? 1) - 1;
        final limit = (call.args['limit'] as num?)?.toInt() ?? 2000;
        final slice = lines.skip(offset).take(limit).toList();
        final b = StringBuffer();
        for (var i = 0; i < slice.length; i++) {
          b.writeln('${offset + i + 1}\t${slice[i]}');
        }
        if (offset + slice.length < lines.length) {
          b.writeln('… 共 ${lines.length} 行，已显示到第 ${offset + slice.length} 行');
        }
        return ToolResult.ok(b.toString());

      case 'list_dir':
        final d = Directory(resolve(call.args['path'] as String?));
        if (!await d.exists()) return const ToolResult.ok('目录不存在');
        final entries = <String>[];
        await for (final e in d.list(followLinks: false)) {
          final name = e.path.split(Platform.pathSeparator).last;
          entries.add(e is Directory ? '$name/' : name);
        }
        entries.sort();
        return ToolResult.ok(entries.isEmpty ? '(空目录)' : entries.join('\n'));

      case 'grep':
        // 交给 rg/grep 而不是在 Dart 里遍历：几万个文件时差着数量级，
        // 而且 rg 自带 .gitignore 处理。
        final args = [
          '--line-number', '--no-heading', '--color=never',
          if (call.args['glob'] != null) ...['--glob', call.args['glob'] as String],
          call.args['pattern'] as String,
          resolve(call.args['path'] as String?),
        ];
        final r = await Process.run('rg', args);
        final out = r.stdout.toString();
        if (out.isEmpty) return const ToolResult.ok('无匹配');
        final lines = const LineSplitter().convert(out);
        if (lines.length > 200) {
          return ToolResult.ok(
              '${lines.take(200).join('\n')}\n… 共 ${lines.length} 处匹配，请用更具体的正则');
        }
        return ToolResult.ok(out);

      default:
        return ToolResult.rejected('未实现的只读工具：${call.name}');
    }
  } catch (e) {
    return ToolResult.ok('工具执行出错：$e');
  }
}

// ---------------------------------------------------------------------------
// 写入工具 —— 走 SnapshotStore 的精确路径
// ---------------------------------------------------------------------------

Future<ToolResult> runWriteTool(
  ToolCall call,
  String workspace,
  SnapshotStore snapshots,
) async {
  final rel = call.args['path'] as String?;
  if (rel == null) return const ToolResult.rejected('缺少 path 参数');

  final full = File('$workspace/$rel').absolute.path;
  if (!full.startsWith(Directory(workspace).absolute.path)) {
    return ToolResult.rejected('路径 $rel 超出 workspace 范围');
  }
  final f = File(full);

  try {
    switch (call.name) {
      case 'write_file':
        // 关键顺序：**先存旧内容，再写**。反过来的话旧内容就没了。
        snapshots.stage(await snapshots.recordIntentToWrite(rel));
        await f.parent.create(recursive: true);
        final content = call.args['content'] as String? ?? '';
        await f.writeAsString(content, flush: true);
        return ToolResult.ok(
            '已写入 $rel（${content.split('\n').length} 行）。旧内容已存档，可回滚。');

      case 'apply_patch':
        if (!await f.exists()) return ToolResult.rejected('文件不存在：$rel');
        final old = call.args['old'] as String? ?? '';
        final neu = call.args['new'] as String? ?? '';
        final text = await f.readAsString();

        final count = old.allMatches(text).length;
        if (count == 0) {
          return ToolResult.rejected('在 $rel 中找不到要替换的内容。'
              '先用 read_file 确认原文（注意空白和缩进）。');
        }
        if (count > 1) {
          // 报错而不是替换第一个。替换第一个在多数情况下是对的，
          // 但错的那少数情况会静默改错地方 —— 而模型不会去验证。
          return ToolResult.rejected('在 $rel 中匹配到 $count 处。'
              '请扩大 old 的范围使其唯一。');
        }

        snapshots.stage(await snapshots.recordIntentToWrite(rel));
        await f.writeAsString(text.replaceFirst(old, neu), flush: true);
        return ToolResult.ok('已修改 $rel。旧内容已存档，可回滚。');

      default:
        return ToolResult.rejected('未实现的写入工具：${call.name}');
    }
  } catch (e) {
    return ToolResult.ok('工具执行出错：$e');
  }
}
