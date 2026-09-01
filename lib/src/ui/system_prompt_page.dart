/// 系统提示词编辑页。全局和会话级共用一页。
///
/// 两级的关系是**覆盖**而不是叠加：全局那份是"我一般想要的样子"，
/// 会话那份是"这一次不一样"。叠加的话，用户想让某个会话彻底换个人格时，
/// 全局那份还在前面顶着，怎么写都盖不掉。
///
/// 「没设过」和「设成空」必须分开：清空输入框的意思是"这个会话不要任何
/// 自定义提示词"，而不是"回退到全局"。回退是另一个动作，给了单独的按钮。
library;

import 'package:flutter/material.dart';

import 'chat_theme.dart';

class SystemPromptPage extends StatefulWidget {
  const SystemPromptPage({
    super.key,
    required this.title,
    required this.initial,
    required this.onSave,
    this.globalPreview,
    this.onRevertToGlobal,
    this.terminalMode = false,
  });

  final String title;

  /// 当前值。null = 没设过（只有会话级才可能）。
  final String? initial;

  final Future<void> Function(String value) onSave;

  /// 会话级编辑时，把全局那份摆出来给用户看 —— 否则"回退到全局"
  /// 是个盲选：用户不知道退回去之后是什么。
  final String? globalPreview;

  /// 会话级才有：清掉这个会话的设定，回到全局那份。
  final Future<void> Function()? onRevertToGlobal;

  /// 终端模式下内置提示词覆盖不掉，说明文案要跟着变。
  final bool terminalMode;

  @override
  State<SystemPromptPage> createState() => _SystemPromptPageState();
}

class _SystemPromptPageState extends State<SystemPromptPage> {
  late final TextEditingController _text =
      TextEditingController(text: widget.initial ?? '');

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await widget.onSave(_text.text);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _revert() async {
    await widget.onRevertToGlobal!();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.chat;
    final usingGlobal = widget.initial == null;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: <Widget>[
          TextButton(onPressed: _save, child: const Text('保存')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: <Widget>[
          if (widget.onRevertToGlobal != null)
            Card(
              margin: EdgeInsets.zero,
              child: ListTile(
                leading: Icon(
                  usingGlobal ? Icons.public : Icons.person_outline,
                  color: usingGlobal ? t.tintTertiary : t.brand,
                ),
                title: Text(usingGlobal ? '正在用全局提示词' : '这个会话有自己的提示词'),
                subtitle: Text(
                  usingGlobal ? '在下面写点什么，就只对这个会话生效' : '全局那份对这个会话不起作用',
                  style: TextStyle(fontSize: 11, color: t.tintTertiary),
                ),
                trailing: usingGlobal
                    ? null
                    : TextButton(
                        onPressed: _revert,
                        child: const Text('回到全局'),
                      ),
              ),
            ),
          const SizedBox(height: 12),
          TextField(
            controller: _text,
            minLines: 8,
            maxLines: 20,
            autofocus: true,
            textAlignVertical: TextAlignVertical.top,
            decoration: const InputDecoration(
              hintText: '例如：你是一个严谨的代码审查者，只说问题，不夸奖。',
              border: OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            // 这两句的差别是真的，不是措辞问题 —— 终端模式下内置提示词里
            // 装着工具契约，覆盖掉模型就会用错工具。
            widget.terminalMode
                ? '终端模式下，你写的这段会**接在**内置提示词后面。'
                    '内置那份装着工具用法和沙箱规则（改文件用哪个工具、默认断网等），'
                    '覆盖掉模型就会干错事，所以它一直在。'
                : '聊天模式下，你写的这段**取代**内置人格。'
                    '只有一句"你没有工具"会留着 —— 它防的是模型假装自己执行了命令。',
            style: TextStyle(fontSize: 12, height: 1.5, color: t.tintSecondary),
          ),
          if (widget.globalPreview != null &&
              widget.globalPreview!.trim().isNotEmpty) ...<Widget>[
            const SizedBox(height: 20),
            Text('全局提示词（回到全局时用的就是它）',
                style: TextStyle(fontSize: 12, color: t.tintTertiary)),
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: t.bgSecondary,
                borderRadius: BorderRadius.circular(ChatShape.radiusLg),
              ),
              child: Text(
                widget.globalPreview!,
                style: TextStyle(
                    fontSize: 12, height: 1.5, color: t.tintSecondary),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
