/// 输入框上面那条模型快速切换器。
///
/// 取代原来的「对话 / 终端 / 检查点」三格底栏。终端是给模型用的，不该在
/// 用户的主动线上占一格（顶栏右上角保留入口）；而**换模型**才是聊天时真正
/// 会反复做的动作 —— 换个更强的重答一次、换个便宜的接着聊。
///
/// 两个位置：对话模型，和用于记忆检索的嵌入模型。它们通常不是同一个模型，
/// 所以并排放而不是塞进一个下拉里。
library;

import 'package:flutter/material.dart';

import 'chat_theme.dart';

class ModelSwitchBar extends StatelessWidget {
  /// 当前对话模型。空 = 没配。
  final String model;

  /// 当前嵌入模型。空 = 没启用记忆检索的向量路。
  final String embeddingModel;

  /// 嵌入后端上一次失败的原因。非空时那颗芯片变成警告色 ——
  /// 「配了但用不了」和「没配」是两回事，看起来不能一样。
  final String? embeddingError;

  final VoidCallback onPickModel;
  final VoidCallback onPickEmbedding;

  const ModelSwitchBar({
    super.key,
    required this.model,
    required this.embeddingModel,
    required this.onPickModel,
    required this.onPickEmbedding,
    this.embeddingError,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.chat;
    return Container(
      color: t.composerBg,
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
      child: Row(
        children: <Widget>[
          Expanded(
            child: _ModelChip(
              icon: Icons.auto_awesome,
              label: model.isEmpty ? '未配置模型' : model,
              // 没配模型是"这个 app 现在不能用"，值得抢眼。
              color: model.isEmpty ? t.tintWarning : null,
              onTap: onPickModel,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: _ModelChip(
              icon: Icons.hub_outlined,
              label: embeddingError != null
                  ? '嵌入不可用'
                  : embeddingModel.isEmpty
                      ? '嵌入：关'
                      : embeddingModel,
              color: embeddingError != null ? t.tintError : null,
              dim: embeddingError == null && embeddingModel.isEmpty,
              onTap: onPickEmbedding,
            ),
          ),
        ],
      ),
    );
  }
}

class _ModelChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? color;

  /// 功能没开着。画得更淡，但不是禁用 —— 点它就是去开。
  final bool dim;
  final VoidCallback onTap;

  const _ModelChip({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
    this.dim = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.chat;
    final fg = color ?? (dim ? t.tintTertiary : t.tintSecondary);
    return Material(
      color: t.composerField,
      borderRadius: BorderRadius.circular(ChatShape.composerRadius),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(ChatShape.composerRadius),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 15, color: fg),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: fg),
                ),
              ),
              Icon(Icons.expand_less, size: 15, color: t.tintTertiary),
            ],
          ),
        ),
      ),
    );
  }
}

/// 模型选择弹层。
///
/// 返回选中的 id；返回 `''` 表示「不启用」；返回 null 表示用户取消了。
/// 三种结果必须分开 —— 把"取消"和"不启用"混成一个，用户想关掉嵌入时
/// 反而关不掉。
Future<String?> showModelPicker(
  BuildContext context, {
  required String title,
  required String current,
  required List<String> models,
  required Future<List<String>> Function() onRefresh,

  /// 允许「不启用」。嵌入模型可以关，对话模型不能。
  bool allowNone = false,
  String noneLabel = '不启用',

  /// 上一次失败的原因。芯片上只写得下「不可用」三个字，
  /// 真正的原因得有个地方看得到 —— 否则用户只知道坏了，不知道为什么。
  String? error,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.chat.bgPrimary,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => _ModelPickerSheet(
      title: title,
      current: current,
      models: models,
      onRefresh: onRefresh,
      allowNone: allowNone,
      noneLabel: noneLabel,
      error: error,
    ),
  );
}

class _ModelPickerSheet extends StatefulWidget {
  final String title;
  final String current;
  final List<String> models;
  final Future<List<String>> Function() onRefresh;
  final bool allowNone;
  final String noneLabel;
  final String? error;

  const _ModelPickerSheet({
    required this.title,
    required this.current,
    required this.models,
    required this.onRefresh,
    required this.allowNone,
    required this.noneLabel,
    this.error,
  });

  @override
  State<_ModelPickerSheet> createState() => _ModelPickerSheetState();
}

class _ModelPickerSheetState extends State<_ModelPickerSheet> {
  late List<String> _models = widget.models;
  final _filter = TextEditingController();
  bool _loading = false;
  late String? _error = widget.error;

  @override
  void initState() {
    super.initState();
    // 一次都没拉过就自动拉一次。让用户先看见一个空列表、再自己去点刷新，
    // 是把一个能自动做的动作推给了用户。
    if (_models.isEmpty) _refresh();
  }

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final models = await widget.onRefresh();
      if (mounted) setState(() => _models = models);
    } catch (e) {
      // 原样显示。这里的错误信息是精心拼过的（哪个候选端点返回了什么），
      // 换成"获取失败"会把唯一有用的线索丢掉。
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.chat;
    final keyword = _filter.text.trim().toLowerCase();
    final visible = keyword.isEmpty
        ? _models
        : _models.where((m) => m.toLowerCase().contains(keyword)).toList();

    return Padding(
      // 键盘弹起来时列表要跟着上移，否则搜索框会被自己的键盘盖住。
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.7,
        child: Column(
          children: <Widget>[
            const SizedBox(height: 8),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: t.tintTertiary,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      widget.title,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: t.tintPrimary,
                      ),
                    ),
                  ),
                  if (_loading)
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  else
                    IconButton(
                      tooltip: '从服务端重新获取',
                      onPressed: _refresh,
                      icon: const Icon(Icons.refresh),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _filter,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search, size: 20),
                  hintText: '搜索模型',
                  filled: true,
                  fillColor: t.bgSecondary,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(ChatShape.radiusLg),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Text(
                  _error!,
                  style: TextStyle(fontSize: 12, color: t.tintError),
                ),
              ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(top: 8, bottom: 24),
                children: <Widget>[
                  if (widget.allowNone)
                    _tile(
                      label: widget.noneLabel,
                      value: '',
                      selected: widget.current.isEmpty,
                      subtitle: '记忆检索只用 BM25 + 覆盖率两路词法',
                    ),
                  // 当前这个不在拉回来的列表里（手填的、或者服务端换了渠道）
                  // 也要能看见自己选的是什么，否则界面上像是没选。
                  if (widget.current.isNotEmpty &&
                      !visible.contains(widget.current) &&
                      keyword.isEmpty)
                    _tile(
                      label: widget.current,
                      value: widget.current,
                      selected: true,
                      subtitle: '手动填写，不在服务端返回的列表里',
                    ),
                  for (final m in visible)
                    _tile(
                      label: m,
                      value: m,
                      selected: m == widget.current,
                    ),
                  if (visible.isEmpty && !_loading && _error == null)
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Center(
                        child: Text(
                          keyword.isEmpty ? '服务端没有返回任何模型' : '没有匹配的模型',
                          style: TextStyle(color: t.tintTertiary),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tile({
    required String label,
    required String value,
    required bool selected,
    String? subtitle,
  }) {
    final t = context.chat;
    return ListTile(
      dense: true,
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        size: 20,
        color: selected ? t.brand : t.tintTertiary,
      ),
      title: Text(
        label,
        style: TextStyle(
          fontSize: 14,
          color: t.tintPrimary,
          fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
      subtitle: subtitle == null
          ? null
          : Text(subtitle,
              style: TextStyle(fontSize: 11, color: t.tintTertiary)),
      onTap: () => Navigator.pop(context, value),
    );
  }
}
