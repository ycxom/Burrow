/// 输入框上面那条模型快速切换器。
///
/// 取代原来的「对话 / 终端 / 检查点」三格底栏。终端是给模型用的，不该在
/// 用户的主动线上占一格（顶栏右上角保留入口）；而**换模型**才是聊天时真正
/// 会反复做的动作 —— 换个更强的重答一次、换个便宜的接着聊。
///
/// 两个位置：对话模型，和用于记忆检索的嵌入模型。它们通常不是同一个模型，
/// 所以并排放而不是塞进一个下拉里。
///
/// ## 为什么处处标着来源
///
/// 模型名单独拿出来是**认不出花谁的钱的**：同一个模型名同时挂在一个免费
/// 网关和一个计费官方接口上，是最常见的配置，而不是什么边角情况。只显示
/// `gpt-5` 的话，用户以为在走自己的网关，实际每一轮都在扣官方额度 ——
/// 而这种事往往要等到账单出来才发现。
///
/// 所以：芯片上带渠道名，选择器里先选来源再选模型，跨来源挑模型会明说
/// 「这会把渠道一起切过去」。只有一个渠道时这些标注全部收起来 ——
/// 没有第二个来源要区分，那个前缀就只是噪音。
library;

import 'package:flutter/material.dart';

import 'chat_theme.dart';

/// 一个可选的模型来源，对应一个渠道。
class ModelSource {
  final String id;
  final String name;

  /// 地址里的 `host[:port]`。渠道名是用户自己起的，可能叫「测试」「新渠道2」，
  /// 但**花的是谁的额度由地址决定** —— 要确认"发给谁"的地方就得摆出它。
  final String host;

  /// 这个来源缓存下来的模型。空 = 还没拉过，选择器会自动拉一次。
  final List<String> models;

  /// 这个渠道自己配着的模型。
  ///
  /// 拉不动列表的来源（网关关着、地址填错）也得能选中 —— 否则"换回那个
  /// 渠道"这件事就只能绕到渠道管理里去做，而用户是在这里想起来要换的。
  final String configuredModel;

  const ModelSource({
    required this.id,
    required this.name,
    required this.host,
    this.models = const <String>[],
    this.configuredModel = '',
  });
}

/// 选择结果：在**哪个来源**上选了**哪个模型**。
///
/// 两个一起返回而不是只返回模型名：跨来源选中时，调用方要把渠道也切过去，
/// 只给模型名的话它只能安到当前渠道上 —— 那就是选错来源的那个坑本身。
class ModelChoice {
  final String sourceId;

  /// 空串 = 不启用（只有嵌入模型允许）。
  final String model;

  const ModelChoice(this.sourceId, this.model);
}

class ModelSwitchBar extends StatelessWidget {
  /// 当前对话模型。空 = 没配。
  final String model;

  /// 当前嵌入模型。空 = 没启用记忆检索的向量路。
  final String embeddingModel;

  /// 当前渠道名。null = 只有一个渠道，不用标注来源。
  final String? sourceName;

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
    this.sourceName,
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
              source: sourceName,
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
              // 嵌入也走当前渠道、也计费，同样要标来源。关着的时候不标：
              // 没在花钱的东西不需要说明花的是谁的钱。
              source: embeddingModel.isEmpty ? null : sourceName,
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

  /// 渠道名，画在模型名前面。null = 不标。
  final String? source;
  final Color? color;

  /// 功能没开着。画得更淡，但不是禁用 —— 点它就是去开。
  final bool dim;
  final VoidCallback onTap;

  const _ModelChip({
    required this.icon,
    required this.label,
    required this.onTap,
    this.source,
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
                // 一行 RichText 而不是两个 Text：位置不够时被截掉的是模型名，
                // 来源留住。反过来（截掉来源）恰好丢掉最该看见的那半。
                child: Text.rich(
                  TextSpan(children: <InlineSpan>[
                    if (source != null)
                      TextSpan(
                        text: '$source · ',
                        style: TextStyle(
                          color: t.tintTertiary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    TextSpan(text: label),
                  ]),
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
/// 返回选中的来源 + 模型；模型为 `''` 表示「不启用」；返回 null 表示取消。
/// 三种结果必须分开 —— 把"取消"和"不启用"混成一个，用户想关掉嵌入时
/// 反而关不掉。
Future<ModelChoice?> showModelPicker(
  BuildContext context, {
  required String title,
  required String current,
  required List<ModelSource> sources,
  required String? activeSourceId,

  /// 拉某个来源的模型列表。**带来源参数**：拉取期间用户可能已经切到别的
  /// 来源上了，不带的话拉回来的列表会安到错误的来源头上。
  required Future<List<String>> Function(String sourceId) onRefresh,

  /// 允许「不启用」。嵌入模型可以关，对话模型不能。
  bool allowNone = false,
  String noneLabel = '不启用',

  /// 上一次失败的原因。芯片上只写得下「不可用」三个字，
  /// 真正的原因得有个地方看得到 —— 否则用户只知道坏了，不知道为什么。
  String? error,
}) {
  return showModalBottomSheet<ModelChoice>(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.chat.bgPrimary,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => _ModelPickerSheet(
      title: title,
      current: current,
      sources: sources,
      activeSourceId: activeSourceId,
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
  final List<ModelSource> sources;
  final String? activeSourceId;
  final Future<List<String>> Function(String sourceId) onRefresh;
  final bool allowNone;
  final String noneLabel;
  final String? error;

  const _ModelPickerSheet({
    required this.title,
    required this.current,
    required this.sources,
    required this.activeSourceId,
    required this.onRefresh,
    required this.allowNone,
    required this.noneLabel,
    this.error,
  });

  @override
  State<_ModelPickerSheet> createState() => _ModelPickerSheetState();
}

class _ModelPickerSheetState extends State<_ModelPickerSheet> {
  /// 正在看的来源。开局是当前渠道 —— 用户十有八九是来换模型不是来换渠道的。
  late String? _sourceId = widget.activeSourceId ??
      (widget.sources.isEmpty ? null : widget.sources.first.id);

  /// 来源 id → 模型列表。按来源分开存，切回去时不用重拉。
  late final Map<String, List<String>> _models = <String, List<String>>{
    for (final s in widget.sources) s.id: List<String>.from(s.models),
  };

  /// 拉失败的原因，同样按来源分开 —— A 拉不动不代表 B 也拉不动，
  /// 混在一起会让用户以为整个功能坏了。
  final Map<String, String> _errors = <String, String>{};

  final _filter = TextEditingController();
  final Set<String> _loading = <String>{};

  ModelSource? get _source {
    for (final s in widget.sources) {
      if (s.id == _sourceId) return s;
    }
    return null;
  }

  bool get _switchesChannel =>
      _sourceId != null && _sourceId != widget.activeSourceId;

  @override
  void initState() {
    super.initState();
    final id = _sourceId;
    if (widget.error != null && id != null) _errors[id] = widget.error!;
    // 一次都没拉过就自动拉一次。让用户先看见一个空列表、再自己去点刷新，
    // 是把一个能自动做的动作推给了用户。
    if ((_models[id] ?? const <String>[]).isEmpty) _refresh();
  }

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final id = _sourceId;
    if (id == null || _loading.contains(id)) return;
    setState(() {
      _loading.add(id);
      _errors.remove(id);
    });
    try {
      final models = await widget.onRefresh(id);
      // 拉回来时用户可能已经切到别的来源了。按 id 存回去，不看当前选中的是谁。
      if (mounted) setState(() => _models[id] = models);
    } catch (e) {
      // 原样显示。这里的错误信息是精心拼过的（哪个候选端点返回了什么），
      // 换成"获取失败"会把唯一有用的线索丢掉。
      if (mounted) setState(() => _errors[id] = '$e');
    } finally {
      if (mounted) setState(() => _loading.remove(id));
    }
  }

  void _select(String id) {
    if (_sourceId == id) return;
    setState(() => _sourceId = id);
    if ((_models[id] ?? const <String>[]).isEmpty) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.chat;
    final id = _sourceId;
    final keyword = _filter.text.trim().toLowerCase();
    final all = _models[id] ?? const <String>[];
    final visible = keyword.isEmpty
        ? all
        : all.where((m) => m.toLowerCase().contains(keyword)).toList();
    final loading = id != null && _loading.contains(id);
    final error = id == null ? null : _errors[id];

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
                  if (loading)
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
            if (widget.sources.length > 1) _sourceSelector(),
            _endpointLine(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
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
            if (error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Text(
                  error,
                  style: TextStyle(fontSize: 12, color: t.tintError),
                ),
              ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(top: 8, bottom: 24),
                children: <Widget>[
                  // 「不启用」和「当前这个」都只属于当前渠道。翻到别的来源时
                  // 收起来 —— 在 B 的列表里点一个属于 A 的条目，选出来的
                  // 到底是什么，没有一个说得通的答案。
                  if (widget.allowNone && !_switchesChannel)
                    _tile(
                      label: widget.noneLabel,
                      value: '',
                      selected: widget.current.isEmpty,
                      subtitle: '记忆检索只用 BM25 + 覆盖率两路词法',
                    ),
                  // 当前这个不在拉回来的列表里（手填的、或者服务端换了渠道）
                  // 也要能看见自己选的是什么，否则界面上像是没选。
                  if (widget.current.isNotEmpty &&
                      !_switchesChannel &&
                      !visible.contains(widget.current) &&
                      keyword.isEmpty)
                    _tile(
                      label: widget.current,
                      value: widget.current,
                      selected: true,
                      subtitle: '手动填写，不在服务端返回的列表里',
                    ),
                  // 别的来源：把它自己配着的模型摆出来。列表拉不动的渠道
                  // （网关关着、地址填错）否则一个可点的东西都没有，
                  // 「换回那个渠道」就只能绕到渠道管理里去做。
                  if (_switchesChannel &&
                      (_source?.configuredModel.isNotEmpty ?? false) &&
                      !visible.contains(_source!.configuredModel) &&
                      keyword.isEmpty)
                    _tile(
                      label: _source!.configuredModel,
                      value: _source!.configuredModel,
                      selected: false,
                      subtitle: '这个渠道现在配的就是它',
                    ),
                  for (final m in visible)
                    _tile(
                      label: m,
                      value: m,
                      // 别的来源上的同名模型**不是**当前在用的那个，
                      // 打上勾会让人以为"已经是它了"从而放心点下去。
                      selected: !_switchesChannel && m == widget.current,
                    ),
                  if (visible.isEmpty && !loading && error == null)
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Center(
                        child: Text(
                          keyword.isEmpty ? '这个渠道没有返回任何模型' : '没有匹配的模型',
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

  /// 来源选择条。**放在模型列表上面**，而不是做成一个下拉藏起来：
  /// 「在哪个来源上挑」是选模型时一直要看得见的前提，不是一个二级选项。
  Widget _sourceSelector() {
    final t = context.chat;
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: <Widget>[
          for (final s in widget.sources)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(
                selected: s.id == _sourceId,
                onSelected: (_) => _select(s.id),
                visualDensity: VisualDensity.compact,
                // 当前渠道加一个勾。一排芯片里总得看得出哪个是"我现在在用的"，
                // 光靠选中态说不清 —— 选中态表示的是"我正在看"。
                avatar: s.id == widget.activeSourceId
                    ? Icon(Icons.check_circle, size: 15, color: t.brand)
                    : null,
                label: Text(s.name, style: const TextStyle(fontSize: 12.5)),
              ),
            ),
        ],
      ),
    );
  }

  /// 「这次会发给谁」。地址而不是渠道名 —— 名字是用户起的，地址才是账单。
  Widget _endpointLine() {
    final t = context.chat;
    final source = _source;
    if (source == null) return const SizedBox.shrink();

    // 跨来源挑模型会连渠道一起切走，这必须在点下去**之前**说，
    // 而不是切完在状态条上闪一句 —— 那时额度已经开始花了。
    if (_switchesChannel) {
      return Container(
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: t.tintWarning.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(ChatShape.radiusLg),
        ),
        child: Row(
          children: <Widget>[
            Icon(Icons.swap_horiz, size: 16, color: t.tintWarning),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '在这里选模型会把当前渠道一起切到「${source.name}」，'
                '之后的对话都发往 ${source.host}',
                style: TextStyle(fontSize: 11.5, color: t.tintPrimary),
              ),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        children: <Widget>[
          Icon(Icons.north_east, size: 13, color: t.tintTertiary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '发往 ${source.host}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: t.tintTertiary),
            ),
          ),
        ],
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
    final id = _sourceId;
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
      onTap: id == null
          ? null
          : () => Navigator.pop(context, ModelChoice(id, value)),
    );
  }
}
